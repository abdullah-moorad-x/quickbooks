import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import '../core/enums.dart';
import '../core/app_bus.dart';
import '../models/customer.dart';
import '../models/payment.dart';
import '../models/invoice.dart';
import '../services/excel_service.dart';
import '../services/storage.dart';
import '../utils/date.dart';
import '../utils/snackbar.dart';
import 'package:open_filex/open_filex.dart';
import 'package:intl/intl.dart';

class CustomerMasterScreen extends StatefulWidget {
  const CustomerMasterScreen({super.key});
  @override State<CustomerMasterScreen> createState()=>_CustomerMasterScreenState();
}

class _CustomerMasterScreenState extends State<CustomerMasterScreen> with AutomaticKeepAliveClientMixin {
  List<Customer> _customers = []; final _q = TextEditingController();
  List<Invoice> _allInvoices = [];
  SortMode _sortCustomers = SortMode.mostSales;
  Map<String, DateTime> _customerCreatedAt = {};
  final FocusNode _sortFocusCustomers = FocusNode(skipTraversal: true, canRequestFocus: false);
  @override bool get wantKeepAlive => true;

  @override void initState(){
    super.initState();
    _load();
    AppBus.dataTick.addListener(_load);
  }
  @override void dispose() { _q.dispose(); _sortFocusCustomers.dispose(); AppBus.dataTick.removeListener(_load); super.dispose(); }

  Future<void> _load() async {
    final list=await CustomerStore.loadAll(); final invs=await Store.loadAll();
    list.sort((a,b)=>a.id.toLowerCase().compareTo(b.id.toLowerCase()));
    final createdAt = <String, DateTime>{};
    for (final c in list) {
      try {
        final file = await customerWorkbookFileFromKey(c.id);
        if (await file.exists()) {
          final stat = await file.stat();
          createdAt[_keyOf(c).toLowerCase()] = stat.changed;
        }
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() { _customers = list; _allInvoices = invs; _customerCreatedAt = createdAt; _customerPaymentsCache = null; });
  }

  String _keyOf(Customer c)=> (c.id.isNotEmpty?c.id:c.name).trim();
  double _sumSalesForKey(String key){
    double s=0;
    for(final inv in _allInvoices){
      final k=(inv.customerId.isNotEmpty?inv.customerId:inv.customer).trim();
      if(k.toLowerCase()==key.toLowerCase()){ s+=inv.total; }
    }
    return s;
  }
  double _sumPaidForKey(String key){
    double s=0;
    for(final inv in _allInvoices){
      final k=(inv.customerId.isNotEmpty?inv.customerId:inv.customer).trim();
      if(k.toLowerCase()==key.toLowerCase()){ s+=inv.paid; }
    }
    return s;
  }
  double _sumRemainForKey(String key){
    double s=0;
    for(final inv in _allInvoices){
      final k=(inv.customerId.isNotEmpty?inv.customerId:inv.customer).trim();
      if(k.toLowerCase()==key.toLowerCase()){ s+=inv.remaining; }
    }
    return s;
  }

  double _sumOpeningForKey(String key){
    double opening = 0.0;
    if (_customerPaymentsCache != null) {
      for (final p in _customerPayments) {
        final pKey = (p.customerId.isNotEmpty ? p.customerId : p.customer).trim().toLowerCase();
        if (pKey != key.toLowerCase()) continue;
        if ((p.note ?? '').toLowerCase().contains('opening balance')) {
          // Opening balance stored as negative payment (customer owes -> negative payment).
          opening += p.effectiveAmount;
        }
      }
    }
    return opening;
  }
  DateTime _latestDateForKey(String key){
    final k = key.toLowerCase();
    final fromFile = _customerCreatedAt[k];
    if (fromFile != null) return fromFile;
    DateTime latest = DateTime.fromMillisecondsSinceEpoch(0);
    for (final inv in _allInvoices) {
      final invKey = (inv.customerId.isNotEmpty ? inv.customerId : inv.customer).trim();
      if (invKey.toLowerCase() == k) {
        final d = parseInvoiceDate(inv.date);
        if (d.isAfter(latest)) latest = d;
      }
    }
    return latest;
  }

  Future<void> _addDialog() async {
    final idCtrl = TextEditingController(text: await CustomerStore.nextCustomerId());
    final nameCtrl = TextEditingController();
    final displayNameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final openingCtrl = TextEditingController(text: '0');
    DateTime openingDate = DateTime.now();
    if (!mounted) return;
    // ignore: use_build_context_synchronously
    final ok = await showDialog<bool>(context: context, builder: (_){
      return StatefulBuilder(builder: (ctx, setDialogState) {
        return AlertDialog(
          title: const Text('Add Customer'),
          content: SizedBox(width:420, child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: idCtrl, enabled:false, decoration: const InputDecoration(labelText:'Customer ID')),
            const SizedBox(height:8),
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText:'Name')),
            const SizedBox(height:8),
            TextField(controller: displayNameCtrl, decoration: const InputDecoration(labelText:'Customer-facing name (invoice/ledger)')),
            const SizedBox(height:8),
            TextField(controller: phoneCtrl, decoration: const InputDecoration(labelText:'Phone (optional)')),
            const SizedBox(height:8),
            TextField(
              controller: openingCtrl,
              decoration: const InputDecoration(labelText: 'Opening Balance (positive = customer owes, negative = credit)'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height:8),
            InkWell(
              onTap: () async {
                final picked = await showDatePicker(
                  context: ctx,
                  initialDate: openingDate,
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                );
                if (picked != null) {
                  setDialogState(() => openingDate = picked);
                }
              },
              child: InputDecorator(
                decoration: const InputDecoration(labelText: 'Opening balance date'),
                child: Row(
                  children: [
                    const Icon(Icons.calendar_today, size: 18),
                    const SizedBox(width: 8),
                    Text(dfDay.format(openingDate)),
                  ],
                ),
              ),
            ),
          ])),
          actions: [ TextButton(onPressed: ()=>Navigator.pop(ctx,false), child: const Text('Cancel')),
            FilledButton(onPressed: ()=>Navigator.pop(ctx,true), child: const Text('Add')) ],
        );
      });
    });
    if (!mounted) return;
    if (ok==true){
      final id = idCtrl.text.trim();
      final name = nameCtrl.text.trim();
      final displayName = (displayNameCtrl.text.trim().isEmpty ? name : displayNameCtrl.text.trim());
      final phone = phoneCtrl.text.trim();
      final opening = double.tryParse(openingCtrl.text.trim()) ?? 0.0;
      await CustomerStore.addCustomer(id, name, phone, displayName: displayName);
      if (opening.abs() > 0.0001) {
        // Positive opening means customer owes us => store as negative payment to increase net owed.
        await addPaymentForCustomer(
          customerId: id,
          customerName: name,
          type: PaymentType.cash,
          date: openingDate,
          amount: -opening,
          note: 'Opening balance',
        );
      }
      await _load();
    }
  }

  Future<void> _editDialog(Customer c) async {
    await _ensurePaymentsLoaded();
    final openingPayment = _openingPaymentFor(c);
    double openingVal = 0.0;
    DateTime openingDate = DateTime.now();
    if (openingPayment != null) {
      openingVal = -(openingPayment.effectiveAmount);
      try { openingDate = parseInvoiceDate(openingPayment.date); } catch (_) {}
    }
    final nameCtrl=TextEditingController(text:c.name), displayNameCtrl=TextEditingController(text:c.displayName), phoneCtrl=TextEditingController(text:c.contact);
    final openingCtrl = TextEditingController(text: openingVal.toStringAsFixed(0));
    final ok = await showDialog<bool>(context: context, builder: (_)=>StatefulBuilder(builder: (ctx, setDialogState) {
      return AlertDialog(
        title: const Text('Edit Customer'),
        content: SizedBox(width:420, child: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(enabled:false, decoration: InputDecoration(labelText:'Customer ID', hintText:c.id)),
          const SizedBox(height:8),
          TextField(controller: nameCtrl, decoration: const InputDecoration(labelText:'Name')),
          const SizedBox(height:8),
          TextField(controller: displayNameCtrl, decoration: const InputDecoration(labelText:'Customer-facing name (invoice/ledger)')),
          const SizedBox(height:8),
          TextField(controller: phoneCtrl, decoration: const InputDecoration(labelText:'Phone (optional)')),
          const SizedBox(height:8),
          TextField(
            controller: openingCtrl,
            decoration: const InputDecoration(labelText: 'Opening Balance (positive = customer owes, negative = credit)'),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height:8),
          InkWell(
            onTap: () async {
              final picked = await showDatePicker(
                context: ctx,
                initialDate: openingDate,
                firstDate: DateTime(2000),
                lastDate: DateTime(2100),
              );
              if (picked != null) {
                setDialogState(() => openingDate = picked);
              }
            },
            child: InputDecorator(
              decoration: const InputDecoration(labelText: 'Opening balance date'),
              child: Row(
                children: [
                  const Icon(Icons.calendar_today, size: 18),
                  const SizedBox(width: 8),
                  Text(dfDay.format(openingDate)),
                ],
              ),
            ),
          ),
        ])),
        actions: [ TextButton(onPressed: ()=>Navigator.pop(ctx,false), child: const Text('Cancel')),
          FilledButton(onPressed: ()=>Navigator.pop(ctx,true), child: const Text('Save')) ],
      );
    }));
    if (!mounted) return;
    if (ok==true){
      final updatedName = nameCtrl.text.trim();
      final updatedDisplay = displayNameCtrl.text.trim().isEmpty ? updatedName : displayNameCtrl.text.trim();
      final updatedPhone = phoneCtrl.text.trim();
      final opening = double.tryParse(openingCtrl.text.trim()) ?? 0.0;
      final okEdit = await CustomerStore.updateNamePhone(
        c.id,
        updatedName,
        updatedPhone,
        displayName: updatedDisplay,
      );
      if(okEdit) {
        await _saveOpeningBalance(Customer(id: c.id, name: updatedName, displayName: updatedDisplay, contact: updatedPhone, active: c.active), opening, openingDate);
        await _load();
      }
    }
  }

  Future<void> _deleteCustomer(Customer c) async {
    final ok = await showDialog<bool>(context: context, builder: (_)=>AlertDialog(
      title: const Text('Deactivate Customer?'),
      content: Text('Remove "${c.id} - ${c.name}" from master. This does NOT delete old invoices.'),
      actions: [ TextButton(onPressed: ()=>Navigator.pop(context,false), child: const Text('Cancel')),
        FilledButton(onPressed: ()=>Navigator.pop(context,true), child: const Text('Deactivate')) ],
    ));
    if (!mounted) return;
    if (ok == true) { await CustomerStore.deleteById(c.id); await _load(); }
  }

  String _normalizedPhone(String raw) {
    var digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.startsWith('0092')) {
      digits = digits.substring(2);
    } else if (digits.startsWith('0')) {
      digits = '92${digits.substring(1)}';
    } else if (!digits.startsWith('92')) {
      digits = '92$digits';
    }
    return digits;
  }

  Future<List<_LedgerImageEntry>> _ledgerEntriesForRange(Customer c, DateTime from, DateTime to) async {
    DateTime normalize(DateTime d) => DateTime(d.year, d.month, d.day);
    await _ensurePaymentsLoaded();
    final invs = _allInvoices.where((inv) {
      final k = _keyOf(c).toLowerCase();
      final invKey = (inv.customerId.isNotEmpty ? inv.customerId : inv.customer).trim().toLowerCase();
      if (invKey != k) return false;
      final d = parseInvoiceDate(inv.date);
      final nd = normalize(d);
      return !nd.isBefore(normalize(from)) && !nd.isAfter(normalize(to));
    }).toList();
    final pays = <PaymentEntry>[];
    for (final p in _customerPayments) {
      final pKey = (p.customerId.isNotEmpty ? p.customerId : p.customer).trim().toLowerCase();
      if (pKey == _keyOf(c).toLowerCase()) {
        final d = parseInvoiceDate(p.date);
        final nd = normalize(d);
        if (!nd.isBefore(normalize(from)) && !nd.isAfter(normalize(to))) {
          pays.add(p);
        }
      }
    }

    final rows = <_LedgerImageEntry>[];
    for (final inv in invs) {
      rows.add(_LedgerImageEntry(
        date: parseInvoiceDate(inv.date),
        type: 'Sale',
        ref: 'Invoice ${inv.sNo}',
        note: _saleNoteSummary(inv),
        debit: inv.balance,
        credit: 0.0,
      ));
    }
    for (final p in pays) {
      rows.add(_LedgerImageEntry(
        date: parseInvoiceDate(p.date),
        type: 'Payment',
        ref: p.id,
        note: _ledgerNoteForPaymentImg(p),
        debit: 0.0,
        credit: p.effectiveAmount,
      ));
    }
    rows.sort((a, b) {
      final d = a.date.compareTo(b.date);
      if (d != 0) return d;
      return a.type.compareTo(b.type);
    });
    return rows;
  }

  String _locationOfInvoice(Invoice inv) {
    return inv.address.trim();
  }

  List<Map<String, dynamic>> _salesRows(Customer c, DateTime from, DateTime to, String? selectedAddr) {
    final nf = NumberFormat.decimalPattern();
    final key = _keyOf(c).toLowerCase();
    final rows = <Map<String, dynamic>>[];
    for (final inv in _allInvoices) {
      final invKey = (inv.customerId.isNotEmpty ? inv.customerId : inv.customer).trim().toLowerCase();
      if (invKey != key) continue;
      final d = parseInvoiceDate(inv.date);
      if (d.isBefore(from) || d.isAfter(to)) continue;
      final dStr = DateFormat('dd/MM/yyyy').format(d);
      final addr = _locationOfInvoice(inv);
      if (selectedAddr != null && selectedAddr.isNotEmpty && addr != selectedAddr) continue;
      final addrPart = addr.isNotEmpty ? ' | $addr' : '';
      for (final line in inv.lines) {
        if (line.qty <= 0) continue;
        final brand = line.brand.trim();
        final type = line.typeLabel.trim();
        final amt = line.amount;
        final brandPart = brand.isNotEmpty ? brand : type;
        final typePart = type.isNotEmpty ? type : 'Sale';
        rows.add({'date': d, 'text': '$dStr – ${line.qty} bags $brandPart → $typePart → Rs ${nf.format(amt)}$addrPart'});
      }
    }
    return rows;
  }

  String _saleNoteSummary(Invoice inv) {
    final items = <String>[];
    for (final l in inv.lines) {
      if (l.qty > 0) {
        items.add('${l.typeLabel} ${l.qty}');
      }
    }
    final parts = <String>[];
    if (items.isNotEmpty) parts.add(items.join(', '));
    final addr = inv.address.trim();
    if (addr.isNotEmpty) parts.add(addr);
    return parts.isEmpty ? '' : parts.join(' | ');
  }

  String _ledgerNoteForPaymentImg(PaymentEntry e) {
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
    if (e.discount.abs() > 0.0001) parts.add('Discount ${e.discount.toStringAsFixed(0)}');
    if (parts.isEmpty) return paymentTypeLabel(e.type);
    return '${paymentTypeLabel(e.type)} - ${parts.join(' / ')}';
  }

  List<PaymentEntry> get _customerPayments => _customerPaymentsCache ?? const <PaymentEntry>[];
  List<PaymentEntry>? _customerPaymentsCache;

  Future<void> _ensurePaymentsLoaded() async {
    if (_customerPaymentsCache == null) {
      _customerPaymentsCache = await PaymentStore.loadAll();
    }
  }
  PaymentEntry? _openingPaymentFor(Customer c) {
    final key = _keyOf(c).toLowerCase();
    for (final p in _customerPayments) {
      final pKey = (p.customerId.isNotEmpty ? p.customerId : p.customer).trim().toLowerCase();
      if (pKey == key && (p.note ?? '').toLowerCase().contains('opening balance')) {
        return p;
      }
    }
    return null;
  }

  Future<void> _saveOpeningBalance(Customer c, double opening, DateTime date) async {
    final pays = await PaymentStore.loadAll();
    final key = _keyOf(c).toLowerCase();
    int idx = -1; PaymentEntry? existing;
    for (var i = 0; i < pays.length; i++) {
      final p = pays[i];
      final pKey = (p.customerId.isNotEmpty ? p.customerId : p.customer).trim().toLowerCase();
      if (pKey == key && (p.note ?? '').toLowerCase().contains('opening balance')) {
        idx = i; existing = p; break;
      }
    }
    DateTime? oldDate;
    if (existing != null) {
      try { oldDate = parseInvoiceDate(existing.date); } catch (_) {}
    }

    if (opening.abs() < 0.0001) {
      if (idx >= 0) {
        pays.removeAt(idx);
        await PaymentStore.saveAll(pays);
        await syncInvoicesPaidFromPayments();
        if (oldDate != null) {
          await rebuildMonthlyPaymentsExcels(DateTime(oldDate.year, oldDate.month));
          try { await exportMonthlyLedger(DateTime(oldDate.year, oldDate.month)); } catch (_) {}
        }
      }
      _customerPaymentsCache = null;
      return;
    }

    final updated = PaymentEntry(
      id: existing?.id ?? await PaymentStore.nextPaymentId(date),
      date: formatInvoiceDate(date),
      customerId: c.id,
      customer: c.name,
      type: PaymentType.cash,
      amount: -opening,
      discount: existing?.discount ?? 0.0,
      note: 'Opening balance',
      chequeNo: existing?.chequeNo,
      bank: existing?.bank,
      txnId: existing?.txnId,
      bankMode: existing?.bankMode,
    );
    if (idx >= 0) {
      pays[idx] = updated;
    } else {
      pays.add(updated);
    }
    await PaymentStore.saveAll(pays);
    await syncInvoicesPaidFromPayments();
    final months = <DateTime>{DateTime(date.year, date.month)};
    if (oldDate != null && (oldDate.year != date.year || oldDate.month != date.month)) {
      months.add(DateTime(oldDate.year, oldDate.month));
    }
    for (final m in months) {
      await rebuildMonthlyPaymentsExcels(m);
      try { await exportMonthlyLedger(m); } catch (_) {}
    }
    try { await refreshReportsForInvoices(<int>{}); } catch (_) {}
    _customerPaymentsCache = null;
  }

  Future<double> _openingBalanceForRange(Customer c, DateTime from) async {
    await _ensurePaymentsLoaded();
    final key = _keyOf(c).toLowerCase();
    double debitBefore = 0.0;
    double creditBefore = 0.0;
    for (final inv in _allInvoices) {
      final invKey = (inv.customerId.isNotEmpty ? inv.customerId : inv.customer).trim().toLowerCase();
      if (invKey != key) continue;
      final d = parseInvoiceDate(inv.date);
      if (d.isBefore(DateTime(from.year, from.month, from.day))) {
        debitBefore += inv.balance;
      }
    }
    for (final p in _customerPayments) {
      final pKey = (p.customerId.isNotEmpty ? p.customerId : p.customer).trim().toLowerCase();
      if (pKey != key) continue;
      final d = parseInvoiceDate(p.date);
      if (d.isBefore(DateTime(from.year, from.month, from.day))) {
        creditBefore += p.effectiveAmount;
      }
    }
    return debitBefore - creditBefore;
  }

  Future<File> _generateLedgerImageFile(Customer c, DateTime from, DateTime to) async {
    await _ensurePaymentsLoaded();
    final entries = await _ledgerEntriesForRange(c, from, to);
    final opening = await _openingBalanceForRange(c, from);

    final safeFrom = DateTime(from.year, from.month, from.day);
    final safeTo = DateTime(to.year, to.month, to.day);

    final fileBase = await customerLedgerFileFromKey(c.id);
    final pngPath = fileBase.path.replaceAll('.xlsx', '_${dfDay.format(safeFrom)}_${dfDay.format(safeTo)}.png');
    final width = 1200.0;
    const rowH = 28.0;
    const headerH = 34.0;
    const padding = 14.0;
    final rowsCount = entries.length + 1; // opening row
    final height = (padding * 2) + headerH + (rowsCount * rowH) + 40;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, width, height));
    final bg = Paint()..color = const ui.Color(0xFFFFFFFF);
    canvas.drawRect(Rect.fromLTWH(0, 0, width, height), bg);

    double x = padding;
    double y = padding;

    final titleStyle = const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: Color(0xFF0D47A1));
    final subStyle = const TextStyle(fontSize: 13, color: Color(0xFF455A64));

    void drawText(String text, double dx, double dy, double maxW, {TextStyle? style, TextAlign align = TextAlign.left}) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: style ?? const TextStyle(fontSize: 13, color: Colors.black87)),
        textDirection: ui.TextDirection.ltr,
        textAlign: align,
        maxLines: 2,
        ellipsis: '…',
      )..layout(maxWidth: maxW);
      tp.paint(canvas, Offset(dx, dy));
    }

    final faceName = (c.displayName.trim().isNotEmpty ? c.displayName : c.name);
    drawText('Ledger: $faceName (${c.id})', x, y, width - 2 * padding, style: titleStyle);
    y += 22;
    drawText('Range: ${dfDay.format(safeFrom)}  to  ${dfDay.format(safeTo)}', x, y, width - 2 * padding, style: subStyle);
    y += 24;

    final cols = <double>[120, 100, 200, 450, 120, 120, 140];
    final headers = ['Date', 'Type', 'Reference', 'Note', 'Debit', 'Credit', 'Balance'];
    final headerStyle = const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white);
    final headerBg = Paint()..color = const ui.Color(0xFF1565C0);
    final rowAlt = Paint()..color = const ui.Color(0xFFF5F5F5);

    double colX = x;
    canvas.drawRect(Rect.fromLTWH(x, y, cols.reduce((a, b) => a + b), headerH), headerBg);
    for (int i = 0; i < headers.length; i++) {
      drawText(headers[i], colX + 8, y + 8, cols[i] - 16, style: headerStyle);
      colX += cols[i];
    }
    y += headerH;

    double running = opening;
    // Opening row
    {
      final rowBg = Paint()..color = const ui.Color(0xFFE3F2FD);
      canvas.drawRect(Rect.fromLTWH(x, y, cols.reduce((a, b) => a + b), rowH), rowBg);
      colX = x;
      final cells = [
        'Opening',
        '',
        '',
        'Balance before ${dfDay.format(safeFrom)}',
        '',
        '',
        opening.toStringAsFixed(0),
      ];
      for (int i = 0; i < cells.length; i++) {
        final align = i >= 4 ? TextAlign.right : TextAlign.left;
        drawText(cells[i], colX + 8, y + 6, cols[i] - 16, align: align);
        colX += cols[i];
      }
      y += rowH;
    }

    for (int idx = 0; idx < entries.length; idx++) {
      final e = entries[idx];
      running += e.debit - e.credit;
      if (idx.isEven) {
        canvas.drawRect(Rect.fromLTWH(x, y, cols.reduce((a, b) => a + b), rowH), rowAlt);
      }
      colX = x;
      final cells = [
        dfDay.format(e.date),
        e.type,
        e.ref,
        e.note,
        e.debit.abs() < 0.0001 ? '' : e.debit.toStringAsFixed(0),
        e.credit.abs() < 0.0001 ? '' : e.credit.toStringAsFixed(0),
        running.toStringAsFixed(0),
      ];
      for (int i = 0; i < cells.length; i++) {
        final align = i >= 4 ? TextAlign.right : TextAlign.left;
        drawText(cells[i], colX + 8, y + 6, cols[i] - 16, align: align);
        colX += cols[i];
      }
      y += rowH;
    }

    final picture = recorder.endRecording();
    final img = await picture.toImage(width.toInt(), height.toInt());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    final file = File(pngPath);
    await file.writeAsBytes(data!.buffer.asUint8List(), flush: true);
    return file;
  }

  Future<void> _pickAndSendLedgerImage(Customer c) async {
    final phone = c.contact.trim();
    DateTime from = DateTime.now().subtract(const Duration(days: 30));
    DateTime to = DateTime.now();
    final addrOptions = _allInvoices
        .where((inv) => (inv.customerId.isNotEmpty ? inv.customerId : inv.customer).trim().toLowerCase() == _keyOf(c).toLowerCase())
        .map((inv) => _locationOfInvoice(inv))
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    String? selectedAddr = addrOptions.isNotEmpty ? addrOptions.first : null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setStateDialog) {
            Future<void> pickDate(bool isFrom) async {
              final initial = isFrom ? from : to;
              final picked = await showDatePicker(
                context: ctx,
                initialDate: initial,
                firstDate: DateTime(2000),
                lastDate: DateTime(2100),
              );
              if (picked != null) {
                setStateDialog(() {
                  if (isFrom) {
                    from = picked;
                    if (from.isAfter(to)) to = from;
                  } else {
                    to = picked;
                    if (to.isBefore(from)) from = to;
                  }
                });
              }
            }

            return AlertDialog(
              title: Text('Send sales to ${c.name}'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Choose date range for the sales message.'),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => pickDate(true),
                          child: Text('From: ${dfDay.format(from)}'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => pickDate(false),
                          child: Text('To: ${dfDay.format(to)}'),
                        ),
                      ),
                    ],
                  ),
                  if (addrOptions.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String?>(
                      value: selectedAddr,
                      items: [
                        const DropdownMenuItem<String?>(value: null, child: Text('All addresses')),
                        ...addrOptions.map((a) => DropdownMenuItem<String?>(value: a, child: Text(a))),
                      ],
                      onChanged: (v) => setStateDialog(() => selectedAddr = v),
                      decoration: const InputDecoration(labelText: 'Filter by address / plot'),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                FilledButton.icon(
                  onPressed: () => Navigator.pop(ctx, true),
                  icon: const Icon(Icons.send),
                  label: const Text('Send'),
                ),
              ],
            );
          },
        );
      },
    );
    if (ok != true) return;
    try {
      final rows = _salesRows(c, from, to, selectedAddr);
      if (rows.isEmpty) {
        if (!mounted) return;
        showErr(context, 'No sales found from ${dfDay.format(from)} to ${dfDay.format(to)}.');
        return;
      }
      rows.sort((a, b) => (a['date'] as DateTime).compareTo(b['date'] as DateTime));
      final lines = rows.map((e) => e['text'] as String).toList();
      final header = 'Sales from ${dfDay.format(from)} to ${dfDay.format(to)}:';
      final message = '$header\n${lines.join('\n')}';
      await Clipboard.setData(ClipboardData(text: message));
      if (!mounted) return;
      if (phone.isEmpty) {
        showOk(context, 'Copied sales to clipboard.');
        return;
      }
      final digits = _normalizedPhone(phone);
      final url = 'https://wa.me/$digits?text=${Uri.encodeComponent(message)}';
      try { await OpenFilex.open(url); } catch (_) {
        if (Platform.isWindows) {
          try { await Process.run('cmd', ['/c', 'start', url]); } catch (_) {}
        }
      }
      if (!mounted) return;
      showOk(context, 'Copied sales to clipboard and opened WhatsApp.');
    } catch (err) {
      if (!mounted) return;
      showErr(context, 'Could not prepare sales message: $err');
    }
  }

  Future<void> _pickAndCopySales(Customer c) async {
    DateTime from = DateTime.now().subtract(const Duration(days: 30));
    DateTime to = DateTime.now();
    final addrOptions = _allInvoices
        .where((inv) => (inv.customerId.isNotEmpty ? inv.customerId : inv.customer).trim().toLowerCase() == _keyOf(c).toLowerCase())
        .map((inv) => _locationOfInvoice(inv))
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    String? selectedAddr = addrOptions.isNotEmpty ? addrOptions.first : null;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setStateDialog) {
            Future<void> pickDate(bool isFrom) async {
              final initial = isFrom ? from : to;
              final picked = await showDatePicker(
                context: ctx,
                initialDate: initial,
                firstDate: DateTime(2000),
                lastDate: DateTime(2100),
              );
              if (picked != null) {
                setStateDialog(() {
                  if (isFrom) {
                    from = picked;
                    if (from.isAfter(to)) to = from;
                  } else {
                    to = picked;
                    if (to.isBefore(from)) from = to;
                  }
                });
              }
            }

            return AlertDialog(
              title: Text('Copy sales for ${c.name}'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Choose date range for the sales message.'),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => pickDate(true),
                          child: Text('From: ${dfDay.format(from)}'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => pickDate(false),
                          child: Text('To: ${dfDay.format(to)}'),
                        ),
                      ),
                    ],
                  ),
                  if (addrOptions.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String?>(
                      value: selectedAddr,
                      items: [
                        const DropdownMenuItem<String?>(value: null, child: Text('All addresses')),
                        ...addrOptions.map((a) => DropdownMenuItem<String?>(value: a, child: Text(a))),
                      ],
                      onChanged: (v) => setStateDialog(() => selectedAddr = v),
                      decoration: const InputDecoration(labelText: 'Filter by address / plot'),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                FilledButton.icon(
                  onPressed: () => Navigator.pop(ctx, true),
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy'),
                ),
              ],
            );
          },
        );
      },
    );
    if (ok != true) return;
    try {
      final rows = _salesRows(c, from, to, selectedAddr);
      if (rows.isEmpty) {
        if (!mounted) return;
        showErr(context, 'No sales found from ${dfDay.format(from)} to ${dfDay.format(to)}.');
        return;
      }
      rows.sort((a, b) => (a['date'] as DateTime).compareTo(b['date'] as DateTime));
      final lines = rows.map((e) => e['text'] as String).toList();
      final header = 'Sales from ${dfDay.format(from)} to ${dfDay.format(to)}:';
      final message = '$header\n${lines.join('\n')}';
      await Clipboard.setData(ClipboardData(text: message));
      if (!mounted) return;
      showOk(context, 'Copied sales to clipboard.');
    } catch (err) {
      if (!mounted) return;
      showErr(context, 'Could not prepare sales message: $err');
    }
  }

  @override

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final q=_q.text.trim().toLowerCase();
    var filtered = q.isEmpty ? _customers : _customers.where((c)=>c.id.toLowerCase().contains(q) || c.name.toLowerCase().contains(q) || c.contact.toLowerCase().contains(q)).toList();

    // Apply sorting based on selected mode
    int cmpNumDesc(num a, num b) => b.compareTo(a);
    int cmpNumAsc(num a, num b) => a.compareTo(b);
    switch (_sortCustomers) {
      case SortMode.mostUnpaid:
        filtered.sort((a,b)=>cmpNumDesc(_sumRemainForKey(_keyOf(a)), _sumRemainForKey(_keyOf(b))));
        break;
      case SortMode.mostPaid:
        filtered.sort((a,b)=>cmpNumDesc(_sumPaidForKey(_keyOf(a)), _sumPaidForKey(_keyOf(b))));
        break;
      case SortMode.mostSales:
        filtered.sort((a,b)=>cmpNumDesc(_sumSalesForKey(_keyOf(a)), _sumSalesForKey(_keyOf(b))));
        break;
      case SortMode.leastSales:
        filtered.sort((a,b)=>cmpNumAsc(_sumSalesForKey(_keyOf(a)), _sumSalesForKey(_keyOf(b))));
        break;
      case SortMode.newestFirst:
        filtered.sort((a,b)=>_latestDateForKey(_keyOf(b)).compareTo(_latestDateForKey(_keyOf(a))));
        break;
      case SortMode.oldestFirst:
        filtered.sort((a,b)=>_latestDateForKey(_keyOf(a)).compareTo(_latestDateForKey(_keyOf(b))));
        break;
    }
    return Column(children: [
      Row(children: [
        Expanded(child: TextField(controller:_q, decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search ID/Name/Phone'), onChanged: (_)=>setState((){}))),
        const SizedBox(width:12),
        DropdownButton<SortMode>(
          focusNode: _sortFocusCustomers,
          value: _sortCustomers,
          onChanged: (v){ if(v!=null){ setState(()=>_sortCustomers=v); FocusScope.of(context).unfocus(); _sortFocusCustomers.unfocus(); FocusManager.instance.primaryFocus?.unfocus(); } },
          items: const [
            DropdownMenuItem(value: SortMode.mostUnpaid, child: Text('Most Unpaid')),
            DropdownMenuItem(value: SortMode.mostPaid, child: Text('Most Paid')),
            DropdownMenuItem(value: SortMode.mostSales, child: Text('Most Sales')),
            DropdownMenuItem(value: SortMode.leastSales, child: Text('Least Sales')),
            DropdownMenuItem(value: SortMode.newestFirst, child: Text('Newest First')),
            DropdownMenuItem(value: SortMode.oldestFirst, child: Text('Oldest First')),
          ],
        ),
        const SizedBox(width:12),
        FilledButton.icon(onPressed: _addDialog, icon: const Icon(Icons.add), label: const Text('Add Customer')),
      ]),
      const SizedBox(height: 12),
      Expanded(child: Card(child: ListView.separated(
        physics: const ClampingScrollPhysics(),
        itemCount: filtered.length, separatorBuilder: (_, __)=>const Divider(height:1),
        itemBuilder: (_, i){ final c=filtered[i]; return ListTile(
          title: Text('${c.id} - ${c.name}'),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(c.contact),
              if (c.displayName.trim().isNotEmpty && c.displayName.trim() != c.name.trim())
                Text('Invoice name: ${c.displayName}', style: const TextStyle(fontSize: 12, color: Colors.black54)),
              const SizedBox(height: 2),
              Builder(builder: (_){
                final key = _keyOf(c);
                final opening = _sumOpeningForKey(key);
                final sales = _sumSalesForKey(key);
                final paid = _sumPaidForKey(key);
                final remaining = (opening + sales - paid);
                final totalSalesWithOpening = opening + sales;
                return Text(
                  'Total (with opening): Rs ${totalSalesWithOpening.toStringAsFixed(0)}   |   Paid: Rs ${paid.toStringAsFixed(0)}   |   Remaining: Rs ${remaining.toStringAsFixed(0)}',
                  style: const TextStyle(fontSize: 12, color: Colors.black87),
                );
              }),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () async {
                      final file = await customerWorkbookFileFromKey(c.id);
                      final exists = await file.exists();
                      if (!mounted) return;
                      if (exists) { await OpenFilex.open(file.path); } else {
                        // ignore: use_build_context_synchronously
                        showErr(context, 'Customer Excel not found.');
                      }
                    },
                    icon: const Icon(Icons.open_in_new, size:16),
                    label: const Text('Open'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final file = await exportCustomerLedger(c.id);
                      if (!mounted) return;
                      await OpenFilex.open(file.path);
                    },
                    icon: const Icon(Icons.account_balance_wallet_outlined, size:16),
                    label: const Text('Ledger'),
                  ),
                  if (c.contact.trim().isNotEmpty)
                    OutlinedButton.icon(
                      onPressed: () => _pickAndSendLedgerImage(c),
                      icon: const FaIcon(FontAwesomeIcons.whatsapp, size:16, color: Color(0xFF25D366)),
                      label: const Text('WhatsApp'),
                    ),
                  OutlinedButton.icon(
                    onPressed: () => _pickAndCopySales(c),
                    icon: const Icon(Icons.copy, size:16),
                    label: const Text('Copy Sales'),
                  ),
                  OutlinedButton.icon(onPressed: ()=>_editDialog(c), icon: const Icon(Icons.edit, size:16), label: const Text('Edit')),
                  OutlinedButton.icon(onPressed: ()=>_deleteCustomer(c), icon: const Icon(Icons.delete_outline, size:16), label: const Text('Deactivate')),
                ],
              ),
            ],
          ),
          isThreeLine: true,
        ); },
      ))),
      const SizedBox(height:8),
      const Text('Note: Editing master updates future invoices/search. Old invoices are kept unchanged.'),
    ]);
  }

}

class _LedgerImageEntry {
  final DateTime date;
  final String type;
  final String ref;
  final String note;
  final double debit;
  final double credit;
  _LedgerImageEntry({
    required this.date,
    required this.type,
    required this.ref,
    required this.note,
    required this.debit,
    required this.credit,
  });
}
