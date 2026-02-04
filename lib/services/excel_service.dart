import 'dart:io';
import 'package:excel/excel.dart' hide Border;
import 'package:intl/intl.dart';
import '../core/constants.dart';
import '../models/payment.dart';
import '../models/invoice.dart';
import '../models/customer.dart';
import '../models/surjani_ledger_entry.dart';
import '../services/storage.dart';
import 'surjani_ledger_store.dart';
import '../utils/date.dart';
import '../utils/format.dart';
import 'paths.dart';

class InvoiceAggregates {
  final Map<String,double> total;
  final Map<String,double> paid;
  final Map<String,double> remaining;
  const InvoiceAggregates(this.total, this.paid, this.remaining);
}

InvoiceAggregates aggregateInvoiceSums(List<Invoice> invoices, String Function(Invoice) keyOf){
  final totals = <String,double>{};
  final paids  = <String,double>{};
  final rems   = <String,double>{};
  for (final inv in invoices){
    String key;
    try { key = keyOf(inv); if (key.isEmpty) continue; } catch (_) { continue; }
    final remaining = (inv.balance - inv.paid).clamp(0, double.infinity);
    totals[key] = (totals[key] ?? 0) + inv.total;
    paids[key]  = (paids[key]  ?? 0) + inv.paid;
    rems[key]   = (rems[key]   ?? 0) + remaining;
  }
  return InvoiceAggregates(totals, paids, rems);
}

void _styleHeaderRow(Sheet sheet, List<String> headers) {
  for (int c = 0; c < headers.length; c++) {
    final cell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: 0));
    cell.value = TextCellValue(headers[c].toUpperCase());
    cell.cellStyle = CellStyle(bold: true, horizontalAlign: HorizontalAlign.Center, verticalAlign: VerticalAlign.Center);
  }
}

void _autoSizeColumns(Sheet sheet, List<List<dynamic>> data, int minWidth) {
  final rows = [for (var r in data) r.map((e) => e?.toString() ?? '').toList()];
  final colCount = rows.isNotEmpty ? rows[0].length : 0;
  for (int c = 0; c < colCount; c++) {
    int maxLen = 0;
    for (int r = 0; r < rows.length; r++) {
      final s = r < rows.length && c < rows[r].length ? rows[r][c] : '';
      if (s.length > maxLen) {
        maxLen = s.length;
      }
    }
    final width = (maxLen + 2);
    final w = width.toDouble().clamp(minWidth.toDouble(), 40.0);
    try { (sheet as dynamic).setColumnWidth(c, w); } catch (_) {
      try { (sheet as dynamic).setColWidth(c, w); } catch (_) {}
    }
  }
}

void _cleanupSheetsAndSetDefault(Excel excel, String dataSheetName) {
  try { excel.setDefaultSheet(dataSheetName); } catch (_) {}
}

void _ensureDefaultSheetRenamed(Excel excel, String newName) {
  final def = excel.getDefaultSheet();
  if (def == null) {
    final _ = excel[newName];
    try { excel.setDefaultSheet(newName); } catch (_) {}
    return;
  }
  if (def == newName) {
    try { excel.setDefaultSheet(newName); } catch (_) {}
    return;
  }
  if (excel.sheets.containsKey(newName)) {
    try { excel.rename(def, '${newName}_1'); excel.setDefaultSheet('${newName}_1'); } catch (_) {}
  } else {
    try { excel.rename(def, newName); excel.setDefaultSheet(newName); } catch (_) {}
  }
}

List<String> excelDisplayTriple(List<ItemLine> lines, String type) {
  final same = lines.where((l) => l.typeLabel == type && l.qty > 0).toList();
  if (same.isEmpty) return ['', '0', '0'];
  final brands = <String>[]; final qtys = <String>[]; final rates = <String>[];
  for (final l in same) {
    final b = l.brand.trim(); if (b.isNotEmpty) brands.add(b);
    qtys.add('${l.qty}');
    rates.add(fmt0(l.rate));
  }
  return [brands.join(' + '), qtys.join(' + '), rates.join(' + ')];
}

String saleShortSummary(Invoice inv) {
  final parts = <String>[];
  for (final t in kItemTypes) {
    final same = inv.lines.where((l) => l.typeLabel == t && l.qty > 0).toList();
    if (same.isEmpty) continue;
    int qty = 0;
    double amt = 0.0;
    for (final l in same) {
      qty += l.qty;
      amt += l.qty * l.rate;
    }
    final rate = qty > 0 ? amt / qty : 0.0;
    parts.add('$t $qty ${fmt0(rate)}');
  }
  return parts.join(' | ');
}

List<CellValue?> _cellsFromRow(List<String> headers, List<dynamic> row, Set<String> numericHeaders) {
  final out = <CellValue?>[];
  for (int i = 0; i < headers.length; i++) {
    final h = headers[i].toUpperCase();
    final dynamic v = i < row.length ? row[i] : '';
    if (numericHeaders.contains(h)) {
      if (v is num) {
        out.add(DoubleCellValue(v.toDouble()));
      } else if (v is String) {
        final s = v.replaceAll(',', '').trim();
        final d = double.tryParse(s);
        if (d != null) { out.add(DoubleCellValue(d)); } else { out.add(TextCellValue(v)); }
      } else { out.add(TextCellValue(v?.toString() ?? '')); }
    } else {
      out.add(TextCellValue(v?.toString() ?? ''));
    }
  }
  return out;
}

Set<String> _numericHeadersForSales(List<String> headers) {
  return {'SNO','CARTAGE','TOTAL'};
}

String _safeName(String s) => s.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

Future<File> customerWorkbookFileFromKey(String key) async {
  final base = await baseDir();
  final custDir = Directory('${base.path}${Platform.pathSeparator}customers');
  if (!await custDir.exists()) await custDir.create(recursive: true);

  String id = '';
  String name = '';
  String phone = '';
  try {
    final all = await CustomerStore.loadAll();
    final byId = all.firstWhere(
      (c) => c.id.trim().toLowerCase() == key.trim().toLowerCase(),
      orElse: () => Customer(id: '', name: '', contact: '', active: true),
    );
    if (byId.id.isNotEmpty) {
      id = byId.id.trim(); name = byId.name.trim(); phone = byId.contact.trim();
    } else {
      final byName = all.firstWhere(
        (c) => c.name.trim().toLowerCase() == key.trim().toLowerCase(),
        orElse: () => Customer(id: '', name: '', contact: '', active: true),
      );
      if (byName.id.isNotEmpty || byName.name.isNotEmpty) {
        id = byName.id.trim(); name = byName.name.trim(); phone = byName.contact.trim();
      }
    }
  } catch (_) {}
  if (id.isEmpty && name.isEmpty) { id = key.trim(); }
  final pieces = <String>[];
  if (id.isNotEmpty) pieces.add(id);
  if (name.isNotEmpty) pieces.add(name);
  if (phone.isNotEmpty) pieces.add(phone);
  final display = pieces.isEmpty ? _safeName(key) : _safeName(pieces.join(' - '));
  return File('${custDir.path}${Platform.pathSeparator}$display.xlsx');
}

Future<File> customerLedgerFileFromKey(String key) async {
  final base = await baseDir();
  final custDir = Directory('${base.path}${Platform.pathSeparator}customers');
  if (!await custDir.exists()) await custDir.create(recursive: true);
  final file = await customerWorkbookFileFromKey(key);
  final path = file.path.replaceAll('.xlsx', '_ledger.xlsx');
  return File(path);
}

Future<File> rebuildCustomerWorkbookForKey(String key) async {
  final all = await Store.loadAll();
  final custInvs = all.where((i) => (i.customerId.isNotEmpty ? i.customerId : i.customer).trim().toLowerCase() == key.trim().toLowerCase()).toList()
    ..sort((a,b)=>a.sNo.compareTo(b.sNo));
  final file = await customerWorkbookFileFromKey(key);
  final excel = Excel.createExcel();

  const types = kItemTypes;
  final headers = <String>[
    'SNO','DATE','CUSTOMER ID','CUSTOMER NAME','CONTACT','ADDRESS','SHIPMENT SITE','NOTE',
    ...types.expand((t)=>['$t BRAND','$t QTY','$t RATE']),
    'CARTAGE','TOTAL'
  ];

  final byYear = <String, List<Invoice>>{};
  for (final inv in custInvs) {
    final y = parseInvoiceDate(inv.date).year.toString();
    byYear.putIfAbsent(y, () => []).add(inv);
  }
  if (byYear.isNotEmpty) {
    final firstYear = byYear.keys.first;
    _ensureDefaultSheetRenamed(excel, firstYear);
  }
  for (final entry in byYear.entries) {
    final y = entry.key;
    final sheet = excel[y];
    entry.value.sort((a,b)=>a.sNo.compareTo(b.sNo));
    sheet.appendRow(headers.map<CellValue?>((s) => TextCellValue(s)).toList());
    _styleHeaderRow(sheet, headers);
    final dataRows = <List<dynamic>>[];
    for (final inv in entry.value) {
      final perType = <dynamic>[];
      for (final t in types) {
        final disp = excelDisplayTriple(inv.lines, t);
        perType.addAll([disp[0], disp[1], disp[2]]);
      }
      final row = [
        inv.sNo, inv.date, inv.customerId, inv.customer, inv.contact, inv.address, inv.site, saleShortSummary(inv),
        ...perType, inv.cartage.round(), inv.total.round()
      ];
      final numericCols = _numericHeadersForSales(headers);
      sheet.appendRow(_cellsFromRow(headers, row, numericCols));
      dataRows.add(row);
    }
    for (int r = 0; r < dataRows.length; r++) {
      final row = dataRows[r];
      for (int c = 0; c < row.length; c++) {
        final cell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r + 1));
        cell.cellStyle = CellStyle(horizontalAlign: HorizontalAlign.Left, verticalAlign: VerticalAlign.Center);
      }
    }
    _appendSummaryBlock(sheet, headers, dataRows);
    _autoSizeColumns(sheet, [headers, ...dataRows.take(50)], 12);
    _cleanupSheetsAndSetDefault(excel, y);
  }
  await file.writeAsBytes(excel.encode()!, flush: true);
  return file;
}

Future<File> upsertCustomerWorkbook(Invoice inv) async {
  final key = (inv.customerId.isNotEmpty ? inv.customerId : inv.customer).trim();
  return rebuildCustomerWorkbookForKey(key);
}

void _appendSummaryBlock(Sheet sheet, List<String> headers, List<List<dynamic>> dataRows) {
  final iTotal   = headers.indexOf('TOTAL');
  final iCartage = headers.indexOf('CARTAGE');
  double sumAt(int col) {
    if (col < 0) return 0.0;
    double s = 0.0;
    for (final row in dataRows) {
      if (col < row.length) {
        final v = row[col];
        if (v is num) {
          s += v.toDouble();
        } else if (v is String) {
          final d = double.tryParse(v.replaceAll(',', ''));
          if (d != null) s += d;
        }
      }
    }
    return s;
  }
  final totalSum   = sumAt(iTotal);
  final cartageSum = sumAt(iCartage);
  final startRow = dataRows.length + 2;
  final rows = <List<dynamic>>[
    ['DAILY SUMMARY', ''],
    ['Total Sales (Rs)',            totalSum],
    ['Total Cartage (Rs)',          cartageSum],
  ];
  for (int i = 0; i < rows.length; i++) {
    final r = startRow + i;
    final cLabel = sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: r));
    cLabel.value = TextCellValue(rows[i][0].toString());
    cLabel.cellStyle = CellStyle(bold: i == 0, horizontalAlign: HorizontalAlign.Left, verticalAlign: VerticalAlign.Center);
    final v = rows[i][1];
    final cVal = sheet.cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: r));
    if (v is num) {
      cVal.value = DoubleCellValue(v.toDouble());
      cVal.cellStyle = CellStyle(bold: true, horizontalAlign: HorizontalAlign.Right, verticalAlign: VerticalAlign.Center);
    } else {
      cVal.value = TextCellValue(v.toString());
      cVal.cellStyle = CellStyle(horizontalAlign: HorizontalAlign.Left, verticalAlign: VerticalAlign.Center);
    }
  }
}

Future<File> exportDailySalesExcel(DateTime day) async {
  final all = await Store.loadAll();
  final ymd = formatInvoiceDate(day);
  final rows = all.where((i) {
    try { final d = parseInvoiceDate(i.date); return d.year == day.year && d.month == day.month && d.day == day.day; } catch (_) { return false; }
  }).toList()..sort((a,b)=>a.sNo.compareTo(b.sNo));
  final excel = Excel.createExcel();
  final sheetName = 'SALES $ymd';
  _ensureDefaultSheetRenamed(excel, sheetName);
  final sheet = excel[sheetName];
  const types = kItemTypes;
  final headers = <String>[
    'SNO','DATE','CUSTOMER ID','CUSTOMER NAME','CONTACT','ADDRESS','SHIPMENT SITE','NOTE',
    ...types.expand((t)=>['$t BRAND','$t QTY','$t RATE']),
    'CARTAGE','TOTAL'
  ];
  sheet.appendRow(headers.map<CellValue?>((s) => TextCellValue(s)).toList());
  _styleHeaderRow(sheet, headers);
  final dataRows = <List<dynamic>>[];
  for (final inv in rows) {
    final perType = <dynamic>[];
    for (final t in types) { final disp = excelDisplayTriple(inv.lines, t); perType.addAll([disp[0], disp[1], disp[2]]); }
    final row = [
      inv.sNo, inv.date, inv.customerId, inv.customer, inv.contact, inv.address, inv.site, saleShortSummary(inv),
      ...perType, inv.cartage.round(), inv.total.round()
    ];
    final numericCols = _numericHeadersForSales(headers);
    sheet.appendRow(_cellsFromRow(headers, row, numericCols));
    dataRows.add(row);
  }
  for (int r = 0; r < dataRows.length; r++) {
    final row = dataRows[r];
    for (int c = 0; c < row.length; c++) {
      final cell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r + 1));
      cell.cellStyle = CellStyle(horizontalAlign: HorizontalAlign.Left, verticalAlign: VerticalAlign.Center);
    }
  }
  _appendSummaryBlock(sheet, headers, dataRows);
  _autoSizeColumns(sheet, [headers, ...dataRows.take(80)], 12);
  _cleanupSheetsAndSetDefault(excel, sheetName);
  final dir = await subdir('daily_sales');
  final out = File('${dir.path}${Platform.pathSeparator}Sales_$ymd.xlsx');
  await out.writeAsBytes(excel.encode()!, flush: true);
  return out;
}

Future<File> exportMonthlySalesExcel([DateTime? month]) async {
  final all = await Store.loadAll();
  final base = month ?? DateTime.now();
  final ym = dfMonth.format(base);
  final rows = all.where((i) {
    try { final d = parseInvoiceDate(i.date); return d.year == base.year && d.month == base.month; } catch (_) { return false; }
  }).toList()..sort((a,b)=>a.sNo.compareTo(b.sNo));
  final excel = Excel.createExcel();
  final sheetName = 'SALES $ym';
  _ensureDefaultSheetRenamed(excel, sheetName);
  final sheet = excel[sheetName];
  const types = kItemTypes;
  final headers = <String>[
    'SNO','DATE','CUSTOMER ID','CUSTOMER NAME','CONTACT','ADDRESS','SHIPMENT SITE','NOTE',
    ...types.expand((t)=>['$t BRAND','$t QTY','$t RATE']),
    'CARTAGE','TOTAL'
  ];
  sheet.appendRow(headers.map<CellValue?>((s) => TextCellValue(s)).toList());
  _styleHeaderRow(sheet, headers);
  final dataRows = <List<dynamic>>[];
  for (final inv in rows) {
    final perType = <dynamic>[];
    for (final t in types) { final disp = excelDisplayTriple(inv.lines, t); perType.addAll([disp[0], disp[1], disp[2]]); }
    final row = [
      inv.sNo, inv.date, inv.customerId, inv.customer, inv.contact, inv.address, inv.site, saleShortSummary(inv),
      ...perType, inv.cartage.round(), inv.total.round()
    ];
    final numericCols = _numericHeadersForSales(headers);
    sheet.appendRow(_cellsFromRow(headers, row, numericCols));
    dataRows.add(row);
  }
  for (int r = 0; r < dataRows.length; r++) {
    final row = dataRows[r];
    for (int c = 0; c < row.length; c++) {
      final cell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r + 1));
      cell.cellStyle = CellStyle(horizontalAlign: HorizontalAlign.Left, verticalAlign: VerticalAlign.Center);
    }
  }
  _appendSummaryBlock(sheet, headers, dataRows);
  _autoSizeColumns(sheet, [headers, ...dataRows.take(120)], 12);
  _cleanupSheetsAndSetDefault(excel, sheetName);
  final dir = await subdir('monthly_sales');
  final out = File('${dir.path}${Platform.pathSeparator}Sales_$ym.xlsx');
  await out.writeAsBytes(excel.encode()!, flush: true);
  return out;
}

Future<void> refreshReportsForInvoices(Set<int> invoiceNos) async {
  if (invoiceNos.isEmpty) return;
  final all = await Store.loadAll();
  final affected = all.where((i) => invoiceNos.contains(i.sNo)).toList();
  if (affected.isEmpty) return;
  final dayKeys = <String>{};
  final monthKeys = <String>{};
  final customers = <String>{};
  for (final inv in affected) {
    try { final d = parseInvoiceDate(inv.date); dayKeys.add(formatInvoiceDate(d)); monthKeys.add(DateFormat('yyyy-MM').format(d)); } catch (_) {}
    final key = (inv.customerId.isNotEmpty ? inv.customerId : inv.customer).trim();
    if (key.isNotEmpty) customers.add(key);
  }
  for (final k in dayKeys) { try { await exportDailySalesExcel(parseInvoiceDate(k)); } catch (_) {} }
  for (final m in monthKeys) { try { await exportMonthlySalesExcel(DateTime.parse('$m-01')); } catch (_) {} }
  for (final c in customers) { try { await rebuildCustomerWorkbookForKey(c); } catch (_) {} }
}

Future<List<FileSystemEntity>> listDailyReports() async {
  final dir = await subdir('daily_sales');
  final list = await dir.list().toList();
  list.sort((a,b)=>b.path.compareTo(a.path));
  return list.where((e)=>e.path.toLowerCase().endsWith('.xlsx')).toList();
}

Future<List<FileSystemEntity>> listMonthlyReports() async {
  final dir = await subdir('monthly_sales');
  final list = await dir.list().toList();
  list.sort((a,b)=>b.path.compareTo(a.path));
  return list.where((e)=>e.path.toLowerCase().endsWith('.xlsx')).toList();
}

/// Build monthly Payments Summary and Detail Excel files.
Future<List<File>> rebuildMonthlyPaymentsExcels([DateTime? month]) async {
  final dt = month ?? DateTime.now();
  final ym = DateFormat('yyyy-MM').format(dt);
  final all = await PaymentStore.loadAll();
  final monthEntries = all.where((e) {
    try { final d = parseInvoiceDate(e.date); return d.year == dt.year && d.month == dt.month; } catch (_) { return false; }
  }).toList()..sort((a,b)=>a.date.compareTo(b.date));

  final detail = Excel.createExcel();
  final dName = 'DETAIL $ym'; _ensureDefaultSheetRenamed(detail, dName); final dSheet = detail[dName];
  final dHeaders = <String>['DATE','CUSTOMER ID','CUSTOMER NAME','PAYMENT TYPE','AMOUNT','NOTE','CHEQUE NO','BANK','MODE','TXN ID'];
  dSheet.appendRow(dHeaders.map<CellValue?>((s) => TextCellValue(s)).toList()); _styleHeaderRow(dSheet, dHeaders);
  final dRows = <List<dynamic>>[];
  String asciiSafe(String s) {
    final sb = StringBuffer();
    for (final r in s.runes) {
      switch (r) {
        case 0x2022: case 0x2013: case 0x2014: sb.write('-'); break;
        case 0x2018: case 0x2019: sb.write("'"); break;
        default:
          if (r < 0x20 && r != 0x09 && r != 0x0A && r != 0x0D) {
          } else { sb.write(String.fromCharCode(r)); }
      }
    }
    return sb.toString();
  }
  List<dynamic> sanitizeRow(List<dynamic> row) => row.map((v) => v is String ? asciiSafe(v) : v).toList();
  List<CellValue?> asCellsPaymentsDetail(List<dynamic> row) { const numericCols = {'AMOUNT'}; return _cellsFromRow(dHeaders, row, numericCols); }
  for (final e in monthEntries) {
    final noteParts = <String>[];
    if ((e.note ?? '').isNotEmpty) noteParts.add(e.note!);
    if (e.discount.abs() > 0.0001) noteParts.add('Discount ${fmt0(e.discount)}');
    final combinedNote = noteParts.join(' | ');
    final row = [ e.date, e.customerId, e.customer, paymentTypeLabel(e.type), e.effectiveAmount, combinedNote, e.chequeNo ?? '', e.bank ?? '', (e.type == PaymentType.bank ? (e.bankMode ?? '') : ''), e.txnId ?? '' ];
    dSheet.appendRow(asCellsPaymentsDetail(sanitizeRow(row))); dRows.add(row);
  }
  _autoSizeColumns(dSheet, [dHeaders, ...dRows.take(200)], 10); _cleanupSheetsAndSetDefault(detail, dName);
  final payDir = await subdir('payments'); final detailsDir = Directory('${payDir.path}${Platform.pathSeparator}payment_details'); if (!await detailsDir.exists()) { await detailsDir.create(recursive: true); }
  final detailFile = File('${detailsDir.path}${Platform.pathSeparator}Payments_Detail_$ym.xlsx'); await detailFile.writeAsBytes(detail.encode()!, flush: true);

  final summary = Excel.createExcel(); final sName = 'SUMMARY $ym'; _ensureDefaultSheetRenamed(summary, sName); final sSheet = summary[sName];
  final sHeaders = <String>['CUSTOMER ID','CUSTOMER NAME','PAYMENTS (MONTH)','ENTRIES'];
  sSheet.appendRow(sHeaders.map<CellValue?>((s) => TextCellValue(s)).toList()); _styleHeaderRow(sSheet, sHeaders);
  final byCustomer = <String, List<PaymentEntry>>{};
  for (final e in monthEntries) {
    final key = (e.customerId.isNotEmpty ? e.customerId : e.customer).trim().toLowerCase();
    (byCustomer[key] ??= []).add(e);
  }
  final sRows = <List<dynamic>>[];
  for (final entry in byCustomer.entries) {
    final list = entry.value;
    if (list.isEmpty) continue;
    final sample = list.first;
    final custId = sample.customerId;
    final custName = sample.customer;
    final total = list.map((e) => e.effectiveAmount).fold<double>(0.0, (s, a) => s + a);
    final row = [custId, custName, total, list.length];
    const numericCols = {'PAYMENTS (MONTH)','ENTRIES'};
    sSheet.appendRow(_cellsFromRow(sHeaders, sanitizeRow(row), numericCols)); sRows.add(row);
  }
  _autoSizeColumns(sSheet, [sHeaders, ...sRows.take(200)], 10); _cleanupSheetsAndSetDefault(summary, sName);
  final summaryDir = Directory('${payDir.path}${Platform.pathSeparator}payment_summary'); if (!await summaryDir.exists()) { await summaryDir.create(recursive: true); }
  final summaryFile = File('${summaryDir.path}${Platform.pathSeparator}Payments_Summary_$ym.xlsx'); await summaryFile.writeAsBytes(summary.encode()!, flush: true);
  return [summaryFile, detailFile];
}

Future<File> exportDailyLedger(DateTime day) async {
  final invoices = await Store.loadAll();
  final payments = await PaymentStore.loadAll();
  final rows = <_LedgerRow>[];

  for (final inv in invoices) {
    try {
      final d = parseInvoiceDate(inv.date);
      if (d.year == day.year && d.month == day.month && d.day == day.day) {
        rows.add(_LedgerRow(
          date: d,
          type: 'Sale',
          customer: inv.customer,
          ref: 'Invoice ${inv.sNo}',
          note: _saleNote(inv),
          debit: inv.balance,
          credit: 0.0,
        ));
      }
    } catch (_) {}
  }
  for (final p in payments) {
    try {
      final d = parseInvoiceDate(p.date);
      if (d.year == day.year && d.month == day.month && d.day == day.day) {
        rows.add(_LedgerRow(
          date: d,
          type: 'Payment',
          customer: p.customer,
          ref: p.id,
          note: _ledgerNoteForPayment(p),
          debit: 0.0,
          credit: p.effectiveAmount,
        ));
      }
    } catch (_) {}
  }
  final dir = await subdir('ledgers_daily');
  return _writeLedgerExcel(rows, 'LEDGER ${formatInvoiceDate(day)}', dir.path, 'Ledger_${formatInvoiceDate(day)}.xlsx');
}

Future<File> exportMonthlyLedger([DateTime? month]) async {
  final base = month ?? DateTime.now();
  final invoices = await Store.loadAll();
  final payments = await PaymentStore.loadAll();
  final rows = <_LedgerRow>[];

  for (final inv in invoices) {
    try {
      final d = parseInvoiceDate(inv.date);
      if (d.year == base.year && d.month == base.month) {
        rows.add(_LedgerRow(
          date: d,
          type: 'Sale',
          customer: inv.customer,
          ref: 'Invoice ${inv.sNo}',
          note: _saleNote(inv),
          debit: inv.balance,
          credit: 0.0,
        ));
      }
    } catch (_) {}
  }
  for (final p in payments) {
    try {
      final d = parseInvoiceDate(p.date);
      if (d.year == base.year && d.month == base.month) {
        rows.add(_LedgerRow(
          date: d,
          type: 'Payment',
          customer: p.customer,
          ref: p.id,
          note: _ledgerNoteForPayment(p),
          debit: 0.0,
          credit: p.effectiveAmount,
        ));
      }
    } catch (_) {}
  }
  final ym = DateFormat('yyyy-MM').format(base);
  final dir = await subdir('ledgers_monthly');
  return _writeLedgerExcel(rows, 'LEDGER $ym', dir.path, 'Ledger_$ym.xlsx');
}

Future<File> exportCustomerLedger(String key) async {
  final invoices = await Store.loadAll();
  final payments = await PaymentStore.loadAll();
  String norm(String s) => s.trim().toLowerCase();
  final ledgerKey = norm(key);
  final invs = invoices.where((i) => norm(i.customerId.isNotEmpty ? i.customerId : i.customer) == ledgerKey).toList();
  final pays = payments.where((p) => norm(p.customerId.isNotEmpty ? p.customerId : p.customer) == ledgerKey).toList();

  String customerId = '';
  String customerName = '';
  try {
    final c = await CustomerStore.findById(key);
    if (c != null) { customerId = c.id; customerName = c.name; }
  } catch (_) {}
  if (customerId.isEmpty && customerName.isEmpty) {
    if (invs.isNotEmpty) { customerId = invs.first.customerId; customerName = invs.first.customer; }
    else if (pays.isNotEmpty) { customerId = pays.first.customerId; customerName = pays.first.customer; }
    else { customerId = key; }
  }
  final file = await customerLedgerFileFromKey(customerId.isNotEmpty ? customerId : customerName);
  final excel = Excel.createExcel();
  const sheetName = 'LEDGER';
  _ensureDefaultSheetRenamed(excel, sheetName);
  final sheet = excel[sheetName];
  final headers = <String>['DATE','TYPE','REFERENCE','NOTE','DEBIT','CREDIT','RUNNING BALANCE'];
  sheet.appendRow(headers.map<CellValue?>((s) => TextCellValue(s)).toList());
  _styleHeaderRow(sheet, headers);

  final rows = <Map<String, dynamic>>[];
  // Move opening balance (if any) to the very top of the ledger.
  double openingBalance = 0.0;
  DateTime? openingDate;
  final openingEntries = <PaymentEntry>[];
  pays.removeWhere((p) {
    final isOpening = (p.note ?? '').toLowerCase().contains('opening balance');
    if (isOpening) {
      openingEntries.add(p);
      openingBalance += p.effectiveAmount;
      try {
        final d = parseInvoiceDate(p.date);
        if (openingDate == null || d.isBefore(openingDate!)) {
          openingDate = d;
        }
      } catch (_) {}
    }
    return isOpening;
  });
  if (openingBalance.abs() > 0.0001) {
    rows.add({
      'date': openingDate ?? DateTime.now(),
      'type': 'Opening',
      'ref': 'Opening Balance',
      'note': 'Opening Balance',
      'debit': 0.0,
      'credit': openingBalance,
    });
  }
  for (final inv in invs) {
    rows.add({
      'date': parseInvoiceDate(inv.date),
      'type': 'Sale',
      'ref': 'Invoice ${inv.sNo}',
      'note': _saleNote(inv),
      'debit': inv.balance,
      'credit': 0.0,
    });
  }
  for (final p in pays) {
    rows.add({
      'date': parseInvoiceDate(p.date),
      'type': 'Payment',
      'ref': p.id,
      'note': _ledgerNoteForPayment(p),
      'debit': 0.0,
      'credit': p.effectiveAmount,
    });
  }
  rows.sort((a, b) => (a['date'] as DateTime).compareTo(b['date'] as DateTime));

  double running = 0.0;
  final dataRows = <List<dynamic>>[];
  for (final r in rows) {
    running += (r['debit'] as double) - (r['credit'] as double);
    final row = [
      dfDay.format(r['date'] as DateTime),
      r['type'],
      r['ref'],
      r['note'] ?? '',
      (r['debit'] as double).round(),
      (r['credit'] as double).round(),
      running.round(),
    ];
    const numericCols = {'DEBIT','CREDIT','RUNNING BALANCE'};
    sheet.appendRow(_cellsFromRow(headers, row, numericCols));
    dataRows.add(row);
  }

  _autoSizeColumns(sheet, [headers, ...dataRows.take(200)], 10);
  _cleanupSheetsAndSetDefault(excel, sheetName);
  await file.writeAsBytes(excel.encode()!, flush: true);
  return file;
}

String _ledgerNoteForPayment(PaymentEntry e) {
  final parts = <String>[];
  if ((e.note ?? '').isNotEmpty) parts.add(e.note!);
  if (e.type == PaymentType.cheque) {
    if ((e.bank ?? '').isNotEmpty) parts.add(e.bank!);
    if ((e.chequeNo ?? '').isNotEmpty) parts.add('Chq ${e.chequeNo}');
  } else if (e.type == PaymentType.bank) {
    if ((e.bankMode ?? '').isNotEmpty) parts.add(e.bankMode!);
    if ((e.bank ?? '').isNotEmpty) parts.add(e.bank!);
    if ((e.txnId ?? '').isNotEmpty) parts.add(e.txnId!);
  }
  if (e.discount.abs() > 0.0001) parts.add('Discount ${fmt0(e.discount)}');
  if (parts.isEmpty) return paymentTypeLabel(e.type);
  return '${paymentTypeLabel(e.type)} - ${parts.join(' / ')}';
}

String _saleNote(Invoice inv) {
  final items = <String>[];
  for (final line in inv.lines) {
    if (line.qty > 0) {
      items.add('${line.typeLabel} ${line.qty}');
    }
  }
  final parts = <String>[];
  if (items.isNotEmpty) parts.add('Items: ${items.join(', ')}');
  final addr = inv.address.trim();
  if (addr.isNotEmpty) parts.add('Address: $addr');
  return parts.isEmpty ? '' : parts.join(' | ');
}

class _LedgerRow {
  final DateTime date;
  final String type;
  final String customer;
  final String ref;
  final String note;
  final double debit;
  final double credit;
  _LedgerRow({
    required this.date,
    required this.type,
    required this.customer,
    required this.ref,
    required this.note,
    required this.debit,
    required this.credit,
  });
}

Future<File> _writeLedgerExcel(List<_LedgerRow> rows, String sheetName, String dirPath, String fileName) async {
  final excel = Excel.createExcel();
  _ensureDefaultSheetRenamed(excel, sheetName);
  final sheet = excel[sheetName];
  final headers = <String>['DATE','TYPE','CUSTOMER','REFERENCE','NOTE','DEBIT','CREDIT','RUNNING BALANCE'];
  sheet.appendRow(headers.map<CellValue?>((s) => TextCellValue(s)).toList());
  _styleHeaderRow(sheet, headers);

  rows.sort((a, b) {
    final d = a.date.compareTo(b.date);
    if (d != 0) return d;
    return a.type.compareTo(b.type);
  });

  double running = 0.0;
  final dataRows = <List<dynamic>>[];
  for (final r in rows) {
    running += (r.debit) - (r.credit);
    final row = [
      dfDay.format(r.date),
      r.type,
      r.customer,
      r.ref,
      r.note,
      r.debit.round(),
      r.credit.round(),
      running.round(),
    ];
    const numericCols = {'DEBIT','CREDIT','RUNNING BALANCE'};
    sheet.appendRow(_cellsFromRow(headers, row, numericCols));
    dataRows.add(row);
  }

  _autoSizeColumns(sheet, [headers, ...dataRows.take(200)], 10);
  _cleanupSheetsAndSetDefault(excel, sheetName);
  final dir = Directory(dirPath);
  if (!await dir.exists()) { await dir.create(recursive: true); }
  final file = File('${dir.path}${Platform.pathSeparator}$fileName');
  await file.writeAsBytes(excel.encode()!, flush: true);
  return file;
}

Future<File> exportSurjaniLedger([List<SurjaniLedgerEntry>? preset]) async {
  final rows = preset ?? await SurjaniLedgerStore.loadAll();
  final excel = Excel.createExcel();
  const sheetName = 'Surjani Ledger';
  _ensureDefaultSheetRenamed(excel, sheetName);
  final sheet = excel[sheetName];
  final headers = <String>['DATE','SOURCE/PARTICULARS','QTY','RATE','DEBIT','CREDIT','BALANCE'];
  sheet.appendRow(headers.map<CellValue?>((s) => TextCellValue(s)).toList());
  _styleHeaderRow(sheet, headers);

  rows.sort((a, b) {
    final d = parseInvoiceDate(a.date).compareTo(parseInvoiceDate(b.date));
    return d != 0 ? d : a.id.compareTo(b.id);
  });

  double running = 0.0;
  final dataRows = <List<dynamic>>[];
  for (final r in rows) {
    running += (r.debit) - (r.credit);
    final row = [
      dfDay.format(parseInvoiceDate(r.date)),
      r.particulars,
      r.qty,
      r.rate,
      r.debit,
      r.credit,
      running,
    ];
    const numericCols = {'QTY','RATE','DEBIT','CREDIT','BALANCE'};
    sheet.appendRow(_cellsFromRow(headers, row, numericCols));
    dataRows.add(row);
  }

  _autoSizeColumns(sheet, [headers, ...dataRows.take(200)], 10);
  _cleanupSheetsAndSetDefault(excel, sheetName);
  final dir = await subdir('surjani');
  final file = File('${dir.path}${Platform.pathSeparator}Surjani_Ledger.xlsx');
  await file.writeAsBytes(excel.encode()!, flush: true);
  return file;
}

Future<PaymentEntry> addPaymentForCustomer({
  required String customerId,
  required String customerName,
  required PaymentType type,
  required DateTime date,
  required double amount,
  double discount = 0.0,
  String? chequeNo,
  String? bank,
  String? txnId,
  String? bankMode,
  String? note,
}) async {
  final ymd = formatInvoiceDate(date);
  final entry = PaymentEntry(
    id: await PaymentStore.nextPaymentId(date),
    date: ymd,
    customerId: customerId,
    customer: customerName,
    type: type,
    amount: amount,
    discount: discount,
    chequeNo: chequeNo,
    bank: bank,
    txnId: txnId,
    bankMode: bankMode,
    note: note,
  );
  await PaymentStore.add(entry);
  await syncInvoicesPaidFromPayments();
  await rebuildMonthlyPaymentsExcels(date);
  try {
    await refreshReportsForInvoices(<int>{});
    try { await exportDailyLedger(date); } catch (_) {}
    try { await exportMonthlyLedger(DateTime(date.year, date.month)); } catch (_) {}
  } catch (_) {}
  return entry;
}

Future<void> rebuildAllReportsLedgerBased() async {
  final invoices = await Store.loadAll();
  final payments = await PaymentStore.loadAll();
  final dayKeys = <String>{};
  final monthKeys = <String>{};
  final customers = <String>{};
  final payMonthKeys = <String>{};

  for (final inv in invoices) {
    try {
      final d = parseInvoiceDate(inv.date);
      dayKeys.add(formatInvoiceDate(d));
      monthKeys.add(DateFormat('yyyy-MM').format(d));
    } catch (_) {}
    final key = (inv.customerId.isNotEmpty ? inv.customerId : inv.customer).trim();
    if (key.isNotEmpty) customers.add(key);
  }
  for (final p in payments) {
    try {
      final d = parseInvoiceDate(p.date);
      payMonthKeys.add(DateFormat('yyyy-MM').format(d));
    } catch (_) {}
    final key = (p.customerId.isNotEmpty ? p.customerId : p.customer).trim();
    if (key.isNotEmpty) customers.add(key);
  }

  for (final d in dayKeys) {
    try { await exportDailySalesExcel(parseInvoiceDate(d)); } catch (_) {}
    try { await exportDailyLedger(parseInvoiceDate(d)); } catch (_) {}
  }
  for (final m in monthKeys) {
    try { await exportMonthlySalesExcel(DateTime.parse('$m-01')); } catch (_) {}
    try { await exportMonthlyLedger(DateTime.parse('$m-01')); } catch (_) {}
  }
  for (final c in customers) {
    try { await rebuildCustomerWorkbookForKey(c); } catch (_) {}
    try { await exportCustomerLedger(c); } catch (_) {}
  }
  for (final m in payMonthKeys) {
    try { await rebuildMonthlyPaymentsExcels(DateTime.parse('$m-01')); } catch (_) {}
  }
}
