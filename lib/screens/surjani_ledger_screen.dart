import 'dart:io';
import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';

import '../services/excel_service.dart';
import '../models/ledger_entry.dart';
import '../services/ledger_catalog_store.dart';
import '../services/ledger_store.dart';
import '../utils/date.dart';
import '../utils/snackbar.dart';
import '../widgets/app_panels.dart';
import '../widgets/skeleton_loader.dart';

class SurjaniLedgerScreen extends StatefulWidget {
  const SurjaniLedgerScreen({super.key});
  @override
  State<SurjaniLedgerScreen> createState() => _SurjaniLedgerScreenState();
}

class _SurjaniLedgerScreenState extends State<SurjaniLedgerScreen>
    with AutomaticKeepAliveClientMixin {
  final _dateCtrl =
      TextEditingController(text: formatInvoiceDate(DateTime.now()));
  final _partCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController(text: '0');
  final _rateCtrl = TextEditingController(text: '0');
  final _debitCtrl = TextEditingController(text: '0');
  final _creditCtrl = TextEditingController(text: '0');
  final _noteCtrl = TextEditingController();
  final _openingCtrl = TextEditingController(text: '0');
  final _openingDateCtrl =
      TextEditingController(text: formatInvoiceDate(DateTime.now()));
  bool _autoDebit = true;
  bool _loading = true;
  bool _locked = true;
  String _selectedLedger = LedgerCatalogStore.surjaniLedger;
  List<LedgerCatalogItem> _catalog = const [];
  List<LedgerEntry> _rows = [];
  List<String> _particularSuggestions = [];
  final FocusNode _partFocus = FocusNode();
  final ScrollController _verticalTableScroll = ScrollController();
  final ScrollController _horizontalTableScroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _initialize();
    _qtyCtrl.addListener(_maybeAutoDebit);
    _rateCtrl.addListener(_maybeAutoDebit);
  }

  @override
  void dispose() {
    _dateCtrl.dispose();
    _partCtrl.dispose();
    _qtyCtrl.dispose();
    _rateCtrl.dispose();
    _debitCtrl.dispose();
    _creditCtrl.dispose();
    _noteCtrl.dispose();
    _openingCtrl.dispose();
    _openingDateCtrl.dispose();
    _partFocus.dispose();
    _verticalTableScroll.dispose();
    _horizontalTableScroll.dispose();
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;

  String _normLedger(String name) => name.trim().toLowerCase();

  Future<void> _initialize() async {
    final list = await LedgerCatalogStore.loadAll();
    final preferred = list.firstWhere(
      (e) =>
          _normLedger(e.name) == _normLedger(LedgerCatalogStore.surjaniLedger),
      orElse: () => list.first,
    );
    if (!mounted) return;
    setState(() {
      _catalog = list;
      _selectedLedger = preferred.name;
      _locked = true;
      _loading = false;
    });
  }

  Future<void> _loadCatalog() async {
    final list = await LedgerCatalogStore.loadAll();
    if (!mounted) return;
    setState(() {
      _catalog = list;
    });
  }

  Future<void> _load() async {
    final list = await LedgerStore.loadAll(_selectedLedger);
    final seen = <String>{};
    final suggestions = <String>[];
    for (final e in list.reversed) {
      final p = e.particulars.trim();
      if (p.isEmpty || p.toLowerCase() == 'opening balance') continue;
      final key = p.toLowerCase();
      if (seen.add(key)) suggestions.add(p);
    }
    if (!mounted) return;
    setState(() {
      _rows = list;
      _particularSuggestions = suggestions;
      _loading = false;
      _locked = false;
      _openingCtrl.text = _openingBalance().toStringAsFixed(0);
      _openingDateCtrl.text = _openingDate();
    });
  }

  double _openingBalance() {
    if (_rows.isEmpty) return 0;
    final first = _rows.first;
    if (first.particulars.toLowerCase() == 'opening balance') {
      return first.debit - first.credit;
    }
    return 0;
  }

  String _openingDate() {
    if (_rows.isNotEmpty &&
        _rows.first.particulars.toLowerCase() == 'opening balance') {
      try {
        return formatInvoiceDate(parseInvoiceDate(_rows.first.date));
      } catch (_) {
        return _rows.first.date;
      }
    }
    return formatInvoiceDate(DateTime.now());
  }

  double _parseDouble(TextEditingController c) =>
      double.tryParse(c.text.replaceAll(',', '')) ?? 0.0;

  void _maybeAutoDebit() {
    if (!_autoDebit) return;
    final q = _parseDouble(_qtyCtrl);
    final r = _parseDouble(_rateCtrl);
    _debitCtrl.text = (q * r).toStringAsFixed(0);
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final first = DateTime(2000, 1, 1);
    final picked = await showDatePicker(
      context: context,
      initialDate: _clampDate(
          parseInvoiceDate(_dateCtrl.text.isNotEmpty
              ? _dateCtrl.text
              : formatInvoiceDate(now)),
          first),
      firstDate: first,
      lastDate: DateTime(now.year + 5),
    );
    if (picked != null) {
      _dateCtrl.text = formatInvoiceDate(picked);
    }
  }

  Future<void> _selectLedger(String? ledgerName) async {
    if (ledgerName == null ||
        _normLedger(ledgerName) == _normLedger(_selectedLedger)) {
      return;
    }
    setState(() {
      _selectedLedger = ledgerName;
      _locked = true;
      _rows = [];
      _particularSuggestions = [];
    });
  }

  Future<void> _unlockCurrentLedger() async {
    setState(() => _loading = true);
    final ok = await _ensureLedgerUnlocked(_selectedLedger);
    if (ok) {
      await _load();
      return;
    }
    if (!mounted) return;
    setState(() => _loading = false);
  }

  void _lockCurrentLedger() {
    setState(() {
      _locked = true;
      _rows = [];
      _particularSuggestions = [];
    });
  }

  Future<bool> _ensureLedgerUnlocked(String ledgerName) async {
    final savedPassword = await LedgerCatalogStore.getPassword(ledgerName);
    if (savedPassword == null || savedPassword.isEmpty) {
      return true;
    }

    final entered = await _showEnterPasswordDialog(ledgerName);
    if (entered == null) return false;
    if (entered != savedPassword) {
      if (!mounted) return false;
      showErr(context, 'Incorrect password');
      return false;
    }
    return true;
  }

  Future<String?> _showEnterPasswordDialog(String ledgerName) async {
    final p = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Enter Password - $ledgerName'),
        content: SizedBox(
          width: 320,
          child: TextField(
            controller: p,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Password'),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, p.text),
              child: const Text('Unlock')),
        ],
      ),
    );
    p.dispose();
    return result;
  }

  Future<void> _changePassword() async {
    final oldSaved = await LedgerCatalogStore.getPassword(_selectedLedger);
    if (!mounted) return;
    final oldCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final confCtrl = TextEditingController();
    bool removePassword = false;
    String? error;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('Change Password - $_selectedLedger'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (oldSaved != null && oldSaved.isNotEmpty) ...[
                  TextField(
                    controller: oldCtrl,
                    obscureText: true,
                    decoration:
                        const InputDecoration(labelText: 'Current Password'),
                  ),
                  const SizedBox(height: 10),
                ],
                CheckboxListTile(
                  value: removePassword,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Remove password'),
                  onChanged: (v) => setDialogState(() {
                    removePassword = v ?? false;
                    error = null;
                  }),
                ),
                const SizedBox(height: 4),
                TextField(
                  controller: newCtrl,
                  obscureText: true,
                  enabled: !removePassword,
                  decoration: const InputDecoration(
                    labelText: 'New Password (optional)',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: confCtrl,
                  obscureText: true,
                  enabled: !removePassword,
                  decoration:
                      const InputDecoration(labelText: 'Confirm New Password'),
                ),
                if (error != null) ...[
                  const SizedBox(height: 10),
                  Text(error!, style: const TextStyle(color: Colors.red)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                final oldValue = oldCtrl.text.trim();
                final newValue = newCtrl.text.trim();
                final confirmValue = confCtrl.text.trim();
                if (oldSaved != null &&
                    oldSaved.isNotEmpty &&
                    oldValue != oldSaved) {
                  setDialogState(() => error = 'Current password is incorrect');
                  return;
                }
                if (removePassword) {
                  Navigator.pop(ctx, true);
                  return;
                }
                if (newValue.isEmpty && confirmValue.isEmpty) {
                  Navigator.pop(ctx, true);
                  return;
                }
                if (newValue.isEmpty) {
                  setDialogState(
                      () => error = 'Enter a new password or remove it');
                  return;
                }
                if (confirmValue != newValue) {
                  setDialogState(() => error = 'Passwords do not match');
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('Update'),
            ),
          ],
        ),
      ),
    );

    if (ok != true) {
      oldCtrl.dispose();
      newCtrl.dispose();
      confCtrl.dispose();
      return;
    }
    final newPass = removePassword ? null : newCtrl.text.trim();
    oldCtrl.dispose();
    newCtrl.dispose();
    confCtrl.dispose();

    await LedgerCatalogStore.setPassword(_selectedLedger, newPass);
    await _loadCatalog();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(
        newPass == null || newPass.isEmpty
            ? 'Ledger password removed'
            : 'Ledger password updated',
      ),
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<void> _addNewLedger() async {
    final nameCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    final confCtrl = TextEditingController();
    bool setPasswordNow = false;
    bool excludeFromProfitLoss = false;
    String? error;

    final created = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Add New Ledger'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: 'Ledger Name'),
                ),
                const SizedBox(height: 8),
                CheckboxListTile(
                  value: setPasswordNow,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Set password now'),
                  onChanged: (v) =>
                      setDialogState(() => setPasswordNow = v ?? false),
                ),
                CheckboxListTile(
                  value: excludeFromProfitLoss,
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Keep separate from P&L'),
                  subtitle: const Text(
                    'This ledger will not be counted in monthly profit/loss.',
                  ),
                  onChanged: (v) => setDialogState(
                    () => excludeFromProfitLoss = v ?? false,
                  ),
                ),
                if (setPasswordNow) ...[
                  TextField(
                    controller: passCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Password'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: confCtrl,
                    obscureText: true,
                    decoration:
                        const InputDecoration(labelText: 'Confirm Password'),
                  ),
                ],
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: const TextStyle(color: Colors.red)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                final name = nameCtrl.text.trim();
                final password = setPasswordNow ? passCtrl.text : null;
                final confirm = confCtrl.text;
                if (name.isEmpty) {
                  setDialogState(() => error = 'Ledger name is required');
                  return;
                }
                final exists = _catalog
                    .any((e) => _normLedger(e.name) == _normLedger(name));
                if (exists) {
                  setDialogState(() => error = 'Ledger already exists');
                  return;
                }
                if (setPasswordNow) {
                  if (password == null || password.trim().isEmpty) {
                    setDialogState(() => error = 'Password is required');
                    return;
                  }
                  if (password != confirm) {
                    setDialogState(() => error = 'Passwords do not match');
                    return;
                  }
                }
                await LedgerCatalogStore.addLedger(
                  name,
                  password: password,
                  excludeFromProfitLoss: excludeFromProfitLoss,
                );
                if (!ctx.mounted) return;
                Navigator.pop(ctx, name);
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );

    nameCtrl.dispose();
    passCtrl.dispose();
    confCtrl.dispose();

    if (created == null || created.trim().isEmpty) return;
    await _loadCatalog();
    if (!mounted) return;
    setState(() {
      _selectedLedger = created.trim();
      _locked = true;
      _rows = [];
      _particularSuggestions = [];
    });
  }

  Future<void> _saveOpening() async {
    final opening = _parseDouble(_openingCtrl);
    final openingDate = _openingDateCtrl.text.trim().isEmpty
        ? formatInvoiceDate(DateTime.now())
        : _openingDateCtrl.text.trim();
    final others = _rows
        .where((e) => e.particulars.toLowerCase() != 'opening balance')
        .toList();
    if (opening.abs() < 0.0001) {
      await LedgerStore.saveAll(_selectedLedger, others);
      await _load();
      return;
    }
    final obEntry = LedgerEntry(
      id: LedgerStore.openingIdFor(_selectedLedger),
      date: openingDate,
      particulars: 'Opening Balance',
      qty: 0,
      rate: 0,
      debit: opening >= 0 ? opening : 0,
      credit: opening < 0 ? opening.abs() : 0,
      note: null,
    );
    others.insert(0, obEntry);
    await LedgerStore.saveAll(_selectedLedger, others);
    await _load();
  }

  Future<void> _addEntry() async {
    final dateStr = _dateCtrl.text.trim();
    final particulars = _partCtrl.text.trim();
    if (dateStr.isEmpty || particulars.isEmpty) {
      if (!mounted) return;
      showErr(context, 'Date and particulars are required');
      return;
    }
    final entry = LedgerEntry(
      id: await LedgerStore.nextId(_selectedLedger, parseInvoiceDate(dateStr)),
      date: dateStr,
      particulars: particulars,
      qty: _parseDouble(_qtyCtrl),
      rate: _parseDouble(_rateCtrl),
      debit: _parseDouble(_debitCtrl),
      credit: _parseDouble(_creditCtrl),
      note: _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
    );
    await LedgerStore.add(_selectedLedger, entry);
    _partCtrl.clear();
    _qtyCtrl.text = '0';
    _rateCtrl.text = '0';
    _creditCtrl.text = '0';
    _noteCtrl.clear();
    _maybeAutoDebit();
    await _load();
  }

  Future<void> _export() async {
    try {
      final file = await exportNamedLedger(_selectedLedger);
      await OpenFilex.open(file.path);
    } catch (_) {
      if (!mounted) return;
      showErr(context, 'Export failed');
    }
  }

  Future<void> _importLedgerFromXlsx() async {
    final unlocked =
        _locked ? await _ensureLedgerUnlocked(_selectedLedger) : true;
    if (!unlocked) return;

    final picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['xlsx'],
      allowMultiple: false,
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return;

    final file = picked.files.single;
    final bytes = file.bytes ??
        ((file.path == null || file.path!.isEmpty)
            ? null
            : await File(file.path!).readAsBytes());
    if (bytes == null || bytes.isEmpty) {
      if (!mounted) return;
      showErr(context, 'Could not read the selected Excel file');
      return;
    }

    setState(() => _loading = true);
    _LedgerImportPreview preview;
    try {
      preview = _parseLedgerWorkbook(
        bytes,
        file.name,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showErr(context, 'Import failed: $e');
      return;
    }

    if (!mounted) return;
    setState(() => _loading = false);

    if (preview.rows.isEmpty) {
      showErr(context, 'No valid rows found in the Excel sheet');
      return;
    }

    final mode = await _showLedgerImportPreviewDialog(preview);
    if (mode == null) return;

    setState(() => _loading = true);
    try {
      final existing = mode == _LedgerImportMode.replace
          ? <LedgerEntry>[]
          : List<LedgerEntry>.from(await LedgerStore.loadAll(_selectedLedger));
      final imported = _buildImportedEntries(preview.rows, existing);
      final combined = [...existing, ...imported]..sort((a, b) {
          final d =
              parseInvoiceDate(a.date).compareTo(parseInvoiceDate(b.date));
          return d != 0 ? d : a.id.compareTo(b.id);
        });
      await LedgerStore.saveAll(_selectedLedger, combined);
      await _load();
      if (!mounted) return;
      showOk(
        context,
        'Imported ${imported.length} rows into $_selectedLedger',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      showErr(context, 'Import failed: $e');
    }
  }

  _LedgerImportPreview _parseLedgerWorkbook(
    Uint8List bytes,
    String fileName,
  ) {
    final workbook = Excel.decodeBytes(bytes);
    if (workbook.tables.isEmpty) {
      throw const FormatException('No sheet found in the Excel file');
    }

    Sheet? sheet;
    String? sheetName;
    for (final entry in workbook.tables.entries) {
      final rows = entry.value.rows;
      final hasAnyValue = rows.any(
        (row) => row.any((cell) => _readCellText(cell).trim().isNotEmpty),
      );
      if (hasAnyValue) {
        sheet = entry.value;
        sheetName = entry.key;
        break;
      }
    }
    sheet ??= workbook.tables.values.first;
    sheetName ??= workbook.tables.keys.first;

    final rows = sheet.rows;
    var headerRowIndex = -1;
    for (int i = 0; i < rows.length; i++) {
      final values = rows[i].map((cell) => _readCellText(cell).trim()).toList();
      if (values.any((v) => v.isNotEmpty)) {
        headerRowIndex = i;
        break;
      }
    }
    if (headerRowIndex < 0) {
      throw const FormatException('No header row found');
    }

    final headerRow = rows[headerRowIndex];
    int? dateCol;
    int? particularCol;
    int? debitCol;
    int? creditCol;
    for (int i = 0; i < headerRow.length; i++) {
      final key = _normalizeImportHeader(_readCellText(headerRow[i]));
      if (key.isEmpty) continue;
      if (dateCol == null && key.contains('date')) {
        dateCol = i;
        continue;
      }
      if (particularCol == null &&
          (key.contains('particular') || key.contains('source'))) {
        particularCol = i;
        continue;
      }
      if (debitCol == null &&
          (key.contains('debit') || key.contains('purchase'))) {
        debitCol = i;
        continue;
      }
      if (creditCol == null &&
          (key.contains('credit') || key.contains('payment'))) {
        creditCol = i;
        continue;
      }
    }

    if (dateCol == null ||
        particularCol == null ||
        debitCol == null ||
        creditCol == null) {
      throw const FormatException(
        'Required columns not found. Need Date, Particular, Debit/Purchase, Credit/Payment',
      );
    }

    final parsed = <_ParsedLedgerRow>[];
    var skippedRows = 0;
    for (int i = headerRowIndex + 1; i < rows.length; i++) {
      final row = rows[i];
      final date = _readImportedDate(_cellAt(row, dateCol));
      final particular = _readCellText(_cellAt(row, particularCol)).trim();
      final debit = _readCellNumber(_cellAt(row, debitCol)) ?? 0.0;
      final credit = _readCellNumber(_cellAt(row, creditCol)) ?? 0.0;

      final isBlank = date == null &&
          particular.isEmpty &&
          debit.abs() < 0.0001 &&
          credit.abs() < 0.0001;
      if (isBlank) continue;

      if (date == null || particular.isEmpty) {
        skippedRows++;
        continue;
      }

      parsed.add(
        _ParsedLedgerRow(
          sourceRow: i + 1,
          date: formatInvoiceDate(date),
          particulars: particular,
          debit: debit,
          credit: credit,
        ),
      );
    }

    return _LedgerImportPreview(
      fileName: fileName,
      sheetName: sheetName,
      rows: parsed,
      skippedRows: skippedRows,
    );
  }

  Future<_LedgerImportMode?> _showLedgerImportPreviewDialog(
    _LedgerImportPreview preview,
  ) async {
    return showDialog<_LedgerImportMode>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Import Ledger - $_selectedLedger'),
        content: SizedBox(
          width: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('File: ${preview.fileName}'),
              const SizedBox(height: 8),
              Text('Sheet: ${preview.sheetName}'),
              const SizedBox(height: 8),
              Text('Valid rows: ${preview.rows.length}'),
              Text('Skipped rows: ${preview.skippedRows}'),
              const SizedBox(height: 12),
              const Text(
                'Balance column will be ignored. The software will recalculate balance itself.',
              ),
              const SizedBox(height: 8),
              Text(
                'Replace will remove the current $_selectedLedger data and load only imported rows.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          OutlinedButton(
            onPressed: () => Navigator.pop(ctx, _LedgerImportMode.append),
            child: const Text('Append'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, _LedgerImportMode.replace),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
  }

  List<LedgerEntry> _buildImportedEntries(
    List<_ParsedLedgerRow> rows,
    List<LedgerEntry> existing,
  ) {
    final prefix = LedgerStore.openingIdFor(_selectedLedger).replaceFirst(
      '-OPEN',
      '',
    );
    final counters = <String, int>{};
    for (final entry in existing) {
      final id = entry.id;
      if (!id.startsWith('$prefix-')) continue;
      final parts = id.split('-');
      if (parts.length < 3) continue;
      final dateKey = parts[1];
      final n = int.tryParse(parts.last);
      if (n == null) continue;
      final current = counters[dateKey] ?? 0;
      if (n > current) counters[dateKey] = n;
    }

    final imported = <LedgerEntry>[];
    for (final row in rows) {
      final dt = parseInvoiceDate(row.date);
      final dayKey =
          '${dt.year.toString().padLeft(4, '0')}${dt.month.toString().padLeft(2, '0')}${dt.day.toString().padLeft(2, '0')}';
      final next = (counters[dayKey] ?? 0) + 1;
      counters[dayKey] = next;
      imported.add(
        LedgerEntry(
          id: '$prefix-$dayKey-${next.toString().padLeft(3, '0')}',
          date: row.date,
          particulars: row.particulars,
          qty: 0,
          rate: 0,
          debit: row.debit,
          credit: row.credit,
          note: 'Imported from Excel row ${row.sourceRow}',
        ),
      );
    }
    return imported;
  }

  Data? _cellAt(List<Data?> row, int? index) {
    if (index == null || index < 0 || index >= row.length) return null;
    return row[index];
  }

  String _normalizeImportHeader(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');
  }

  String _readCellText(Data? cell) {
    final value = cell?.value;
    switch (value) {
      case null:
        return '';
      case TextCellValue():
        return (value.value.text ?? '').trim();
      case IntCellValue():
        return value.value.toString();
      case DoubleCellValue():
        return value.value.toString();
      case DateCellValue():
        return formatInvoiceDate(value.asDateTimeLocal());
      case DateTimeCellValue():
        return formatInvoiceDate(value.asDateTimeLocal());
      case BoolCellValue():
        return value.value.toString();
      case FormulaCellValue():
        return value.formula;
      case TimeCellValue():
        return value.toString();
    }
  }

  double? _readCellNumber(Data? cell) {
    final value = cell?.value;
    switch (value) {
      case null:
        return null;
      case IntCellValue():
        return value.value.toDouble();
      case DoubleCellValue():
        return value.value;
      default:
        final text = _readCellText(cell).replaceAll(',', '').trim();
        if (text.isEmpty) return null;
        return double.tryParse(text);
    }
  }

  DateTime? _readImportedDate(Data? cell) {
    final value = cell?.value;
    switch (value) {
      case null:
        return null;
      case DateCellValue():
        return value.asDateTimeLocal();
      case DateTimeCellValue():
        return value.asDateTimeLocal();
      default:
        final raw = _readCellText(cell).trim();
        if (raw.isEmpty) return null;
        for (final fmt in [
          'dd/MM/yyyy',
          'd/M/yyyy',
          'dd-MM-yyyy',
          'd-M-yyyy',
          'dd.MM.yyyy',
          'd.M.yyyy',
          'yyyy-MM-dd',
          'yyyy/MM/dd',
          'dd MMM yyyy',
          'd MMM yyyy',
        ]) {
          try {
            return DateFormat(fmt).parseStrict(raw);
          } catch (_) {}
        }
        try {
          return parseInvoiceDate(raw);
        } catch (_) {
          return null;
        }
    }
  }

  bool _isOpeningEntry(LedgerEntry e) =>
      e.id == LedgerStore.openingIdFor(_selectedLedger) ||
      e.particulars.toLowerCase() == 'opening balance';

  Future<void> _editEntry(LedgerEntry e) async {
    if (_isOpeningEntry(e)) {
      if (!mounted) return;
      showErr(context, 'Edit opening balance from the Opening Balance section');
      return;
    }

    String editDate = e.date;
    try {
      editDate = formatInvoiceDate(parseInvoiceDate(e.date));
    } catch (_) {}
    final dateCtrl = TextEditingController(text: editDate);
    final partCtrl = TextEditingController(text: e.particulars);
    final qtyCtrl = TextEditingController(text: e.qty.toStringAsFixed(2));
    final rateCtrl = TextEditingController(text: e.rate.toStringAsFixed(2));
    final debitCtrl = TextEditingController(text: e.debit.toStringAsFixed(0));
    final creditCtrl = TextEditingController(text: e.credit.toStringAsFixed(0));
    final noteCtrl = TextEditingController(text: e.note ?? '');
    final partFocus = FocusNode();
    bool autoDebit = (e.debit - (e.qty * e.rate)).abs() < 0.0001;

    void maybeAutoDebit() {
      if (!autoDebit) return;
      final q = double.tryParse(qtyCtrl.text.replaceAll(',', '')) ?? 0.0;
      final r = double.tryParse(rateCtrl.text.replaceAll(',', '')) ?? 0.0;
      debitCtrl.text = (q * r).toStringAsFixed(0);
    }

    qtyCtrl.addListener(maybeAutoDebit);
    rateCtrl.addListener(maybeAutoDebit);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text('Edit Entry - $_selectedLedger'),
          content: SizedBox(
            width: 860,
            child: SingleChildScrollView(
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.end,
                children: [
                  SizedBox(
                    width: 150,
                    child: TextField(
                      controller: dateCtrl,
                      readOnly: true,
                      onTap: () async {
                        final now = DateTime.now();
                        final first = DateTime(2000, 1, 1);
                        final picked = await showDatePicker(
                          context: ctx,
                          initialDate: _clampDate(
                              parseInvoiceDate(dateCtrl.text.isNotEmpty
                                  ? dateCtrl.text
                                  : formatInvoiceDate(now)),
                              first),
                          firstDate: first,
                          lastDate: DateTime(now.year + 5),
                        );
                        if (picked != null) {
                          dateCtrl.text = formatInvoiceDate(picked);
                        }
                      },
                      decoration: const InputDecoration(
                        labelText: 'Date',
                        suffixIcon: Icon(Icons.calendar_today, size: 18),
                      ),
                    ),
                  ),
                  _particularField(partCtrl, focusNode: partFocus, width: 260),
                  _numberField(qtyCtrl, 'Qty', width: 90),
                  _numberField(rateCtrl, 'Rate', width: 90),
                  _numberField(debitCtrl, 'Debit', width: 110),
                  _numberField(creditCtrl, 'Credit', width: 110),
                  _textField(noteCtrl, 'Note', width: 200),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        value: autoDebit,
                        onChanged: (v) => setDialogState(() {
                          autoDebit = v ?? true;
                          maybeAutoDebit();
                        }),
                      ),
                      const Text('Auto debit = qty x rate'),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            ElevatedButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Save')),
          ],
        ),
      ),
    );

    if (ok == true) {
      final dateStr = dateCtrl.text.trim();
      final particulars = partCtrl.text.trim();
      if (dateStr.isEmpty || particulars.isEmpty) {
        if (!mounted) return;
        showErr(context, 'Date and particulars are required');
      } else {
        final updated = e.copyWith(
          date: dateStr,
          particulars: particulars,
          qty: double.tryParse(qtyCtrl.text.replaceAll(',', '')) ?? 0,
          rate: double.tryParse(rateCtrl.text.replaceAll(',', '')) ?? 0,
          debit: double.tryParse(debitCtrl.text.replaceAll(',', '')) ?? 0,
          credit: double.tryParse(creditCtrl.text.replaceAll(',', '')) ?? 0,
          note: noteCtrl.text.trim().isEmpty ? null : noteCtrl.text.trim(),
        );
        await LedgerStore.upsert(_selectedLedger, updated);
        await _load();
      }
    }

    qtyCtrl.removeListener(maybeAutoDebit);
    rateCtrl.removeListener(maybeAutoDebit);
    dateCtrl.dispose();
    partCtrl.dispose();
    qtyCtrl.dispose();
    rateCtrl.dispose();
    debitCtrl.dispose();
    creditCtrl.dispose();
    noteCtrl.dispose();
    partFocus.dispose();
  }

  Future<void> _deleteEntry(LedgerEntry e) async {
    final label = e.particulars.trim().isEmpty ? e.id : e.particulars;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Entry'),
        content: Text('Delete "$label"?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await LedgerStore.delete(_selectedLedger, e.id);
    await _load();
  }

  double _runningBalanceAt(int idx) {
    double running = 0;
    for (int i = 0; i <= idx; i++) {
      running += (_rows[i].debit - _rows[i].credit);
    }
    return running;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const AppSkeletonLoader();
    final totalDebit = _rows.fold<double>(0, (s, e) => s + e.debit);
    final totalCredit = _rows.fold<double>(0, (s, e) => s + e.credit);
    final balance = totalDebit - totalCredit;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compactHeight = constraints.maxHeight < 760;
        final content = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ledgerHeader(),
            const SizedBox(height: 12),
            if (_locked)
              _lockedView()
            else ...[
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  _chip('Total Debit', totalDebit),
                  _chip('Total Credit', totalCredit),
                  _chip('Balance', balance),
                ],
              ),
              const SizedBox(height: 12),
              _openingBalanceCard(),
              const SizedBox(height: 12),
              _entryForm(),
              const SizedBox(height: 12),
              Row(
                children: [
                  FilledButton.tonalIcon(
                    style: appGreenButtonStyle(context),
                    onPressed: _addEntry,
                    icon: const Icon(Icons.add),
                    label: const Text('Add Entry'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.tonalIcon(
                    style: appGreenButtonStyle(context),
                    onPressed: _export,
                    icon: const Icon(Icons.file_download),
                    label: const Text('Export Excel'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (compactHeight)
                _table(shrinkWrap: true)
              else
                Expanded(child: _table()),
            ],
          ],
        );
        if (!compactHeight) {
          return content;
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.only(bottom: 12),
          child: content,
        );
      },
    );
  }

  Widget _ledgerHeader() {
    return AppSoftCard(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: [
            SizedBox(
              width: 280,
              child: DropdownButtonFormField<String>(
                initialValue: _selectedLedger,
                decoration: const InputDecoration(labelText: 'Ledger'),
                items: _catalog
                    .map((e) => DropdownMenuItem<String>(
                        value: e.name, child: Text(e.name)))
                    .toList(),
                onChanged: (v) => _selectLedger(v),
              ),
            ),
            FilledButton.tonalIcon(
              style: appGreenButtonStyle(context),
              onPressed: _locked ? _unlockCurrentLedger : _lockCurrentLedger,
              icon: Icon(_locked ? Icons.lock_open : Icons.lock_outline),
              label: Text(_locked ? 'Unlock Ledger' : 'Lock Ledger'),
            ),
            FilledButton.tonalIcon(
              style: appGreenButtonStyle(context),
              onPressed: _changePassword,
              icon: const Icon(Icons.password),
              label: const Text('Change Password'),
            ),
            FilledButton.tonalIcon(
              style: appGreenButtonStyle(context),
              onPressed: _importLedgerFromXlsx,
              icon: const Icon(Icons.upload_file),
              label: const Text('Import XLSX'),
            ),
            FilledButton.tonalIcon(
              style: appGreenButtonStyle(context),
              onPressed: _addNewLedger,
              icon: const Icon(Icons.add),
              label: const Text('Add New Ledger'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _lockedView() {
    return AppSoftCard(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.lock_outline),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                  '$_selectedLedger is locked. Click "Unlock Ledger" to access entries.'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _openingBalanceCard() {
    return AppSoftCard(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Text('Opening Balance'),
            const SizedBox(width: 12),
            SizedBox(
              width: 150,
              child: TextField(
                controller: _openingDateCtrl,
                readOnly: true,
                onTap: () => _pickDateGeneric(_openingDateCtrl),
                decoration: const InputDecoration(
                  labelText: 'Date',
                  suffixIcon: Icon(Icons.calendar_today, size: 18),
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 140,
              child: TextField(
                controller: _openingCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Amount'),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton.tonal(
              style: appGreenButtonStyle(context),
              onPressed: _saveOpening,
              child: const Text('Save Opening'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickDateGeneric(TextEditingController controller) async {
    final now = DateTime.now();
    final first = DateTime(2000, 1, 1);
    final picked = await showDatePicker(
      context: context,
      initialDate: _clampDate(
          parseInvoiceDate(controller.text.isNotEmpty
              ? controller.text
              : formatInvoiceDate(now)),
          first),
      firstDate: first,
      lastDate: DateTime(now.year + 5),
    );
    if (picked != null) {
      controller.text = formatInvoiceDate(picked);
    }
  }

  DateTime _clampDate(DateTime value, DateTime min) {
    if (value.isBefore(min)) return min;
    return value;
  }

  Widget _entryForm() {
    return AppSoftCard(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: [
            _dateField(),
            _particularField(_partCtrl, focusNode: _partFocus, width: 260),
            _numberField(_qtyCtrl, 'Qty', width: 90),
            _numberField(_rateCtrl, 'Rate', width: 90),
            _numberField(_debitCtrl, 'Debit', width: 110),
            _numberField(_creditCtrl, 'Credit', width: 110),
            _textField(_noteCtrl, 'Note', width: 200),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Checkbox(
                value: _autoDebit,
                onChanged: (v) => setState(() {
                  _autoDebit = v ?? true;
                  _maybeAutoDebit();
                }),
              ),
              const Text('Auto debit = qty × rate'),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _dateField() {
    return SizedBox(
      width: 150,
      child: TextField(
        controller: _dateCtrl,
        readOnly: true,
        onTap: _pickDate,
        decoration: const InputDecoration(
          labelText: 'Date',
          suffixIcon: Icon(Icons.calendar_today, size: 18),
        ),
      ),
    );
  }

  Widget _numberField(TextEditingController c, String label,
      {double width = 120}) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: c,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: label),
      ),
    );
  }

  Widget _textField(TextEditingController c, String label,
      {double width = 200}) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: c,
        decoration: InputDecoration(labelText: label),
      ),
    );
  }

  Widget _chip(String label, double value) {
    return AppMetaChip(
      text: '$label: ${value.toStringAsFixed(0)}',
      backgroundColor: const Color(0xFFF8FAFC),
      borderColor: const Color(0xFFDCE5EE),
      foregroundColor: const Color(0xFF273247),
    );
  }

  Widget _particularField(TextEditingController c,
      {required FocusNode focusNode, double width = 260}) {
    return SizedBox(
      width: width,
      child: RawAutocomplete<String>(
        textEditingController: c,
        focusNode: focusNode,
        optionsBuilder: (textEditingValue) {
          final q = textEditingValue.text.trim().toLowerCase();
          if (q.isEmpty) return const Iterable<String>.empty();
          return _particularSuggestions
              .where((s) => s.toLowerCase().contains(q));
        },
        onSelected: (v) => c.text = v,
        fieldViewBuilder: (context, controller, node, onFieldSubmitted) {
          return TextField(
            controller: controller,
            focusNode: node,
            decoration:
                const InputDecoration(labelText: 'Source / Particulars'),
            onSubmitted: (_) => onFieldSubmitted(),
          );
        },
        optionsViewBuilder: (context, onSelected, options) {
          if (options.isEmpty) return const SizedBox.shrink();
          return Align(
            alignment: Alignment.topLeft,
            child: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(8),
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(maxHeight: 220, maxWidth: 320),
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  itemCount: options.length,
                  itemBuilder: (context, index) {
                    final option = options.elementAt(index);
                    return ListTile(
                      dense: true,
                      title: Text(option),
                      onTap: () => onSelected(option),
                    );
                  },
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _table({bool shrinkWrap = false}) {
    if (_rows.isEmpty) {
      return const Center(child: Text('No entries yet'));
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (shrinkWrap) {
          return _ledgerTableSurface();
        }
        return _ledgerTableSurface(
          verticalController: _verticalTableScroll,
          horizontalController: _horizontalTableScroll,
          showScrollbars: true,
        );
      },
    );
  }

  Widget _ledgerTableSurface({
    ScrollController? verticalController,
    ScrollController? horizontalController,
    bool showScrollbars = false,
  }) {
    final table = DataTable(
      headingRowHeight: 52,
      dataRowMinHeight: 46,
      dataRowMaxHeight: 52,
      columnSpacing: 28,
      headingTextStyle: const TextStyle(
        fontWeight: FontWeight.w700,
        color: Color(0xFF22304A),
        fontSize: 15,
      ),
      dataTextStyle: const TextStyle(
        color: Color(0xFF384357),
        fontSize: 14,
      ),
      columns: const [
        DataColumn(label: Text('Date')),
        DataColumn(label: Text('Particulars')),
        DataColumn(label: Text('Qty')),
        DataColumn(label: Text('Rate')),
        DataColumn(label: Text('Debit')),
        DataColumn(label: Text('Credit')),
        DataColumn(label: Text('Balance')),
        DataColumn(label: Text('Note')),
        DataColumn(label: Text('Actions')),
      ],
      rows: [
        for (int i = 0; i < _rows.length; i++)
          _buildRow(_rows[i], _runningBalanceAt(i)),
      ],
    );

    final horizontal = SingleChildScrollView(
      controller: horizontalController,
      scrollDirection: Axis.horizontal,
      child: table,
    );

    if (!showScrollbars) {
      return horizontal;
    }

    return Card(
      child: Scrollbar(
        controller: verticalController,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: verticalController,
          child: Scrollbar(
            controller: horizontalController,
            thumbVisibility: true,
            notificationPredicate: (notification) =>
                notification.metrics.axis == Axis.horizontal,
            child: horizontal,
          ),
        ),
      ),
    );
  }

  DataRow _buildRow(LedgerEntry e, double running) {
    String displayDate = e.date;
    try {
      displayDate = formatInvoiceDate(parseInvoiceDate(e.date));
    } catch (_) {}
    return DataRow(
      cells: [
        DataCell(Text(displayDate)),
        DataCell(Text(e.particulars)),
        DataCell(Text(e.qty.toStringAsFixed(2))),
        DataCell(Text(e.rate.toStringAsFixed(2))),
        DataCell(Text(e.debit.toStringAsFixed(0))),
        DataCell(Text(e.credit.toStringAsFixed(0))),
        DataCell(Text(running.toStringAsFixed(0))),
        DataCell(Text(e.note ?? '')),
        DataCell(
          _isOpeningEntry(e)
              ? const Text('-')
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Edit entry',
                      icon: const Icon(Icons.edit, size: 18),
                      onPressed: () => _editEntry(e),
                    ),
                    IconButton(
                      tooltip: 'Delete entry',
                      icon: const Icon(Icons.delete_outline,
                          size: 18, color: Color(0xFFB71C1C)),
                      onPressed: () => _deleteEntry(e),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

enum _LedgerImportMode { append, replace }

class _LedgerImportPreview {
  final String fileName;
  final String sheetName;
  final List<_ParsedLedgerRow> rows;
  final int skippedRows;

  const _LedgerImportPreview({
    required this.fileName,
    required this.sheetName,
    required this.rows,
    required this.skippedRows,
  });
}

class _ParsedLedgerRow {
  final int sourceRow;
  final String date;
  final String particulars;
  final double debit;
  final double credit;

  const _ParsedLedgerRow({
    required this.sourceRow,
    required this.date,
    required this.particulars,
    required this.debit,
    required this.credit,
  });
}
