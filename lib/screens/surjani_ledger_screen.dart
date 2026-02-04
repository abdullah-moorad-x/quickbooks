import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';

import '../services/surjani_ledger_store.dart';
import '../services/excel_service.dart';
import '../models/surjani_ledger_entry.dart';
import '../utils/date.dart';
import '../utils/snackbar.dart';

class SurjaniLedgerScreen extends StatefulWidget {
  const SurjaniLedgerScreen({super.key});
  @override
  State<SurjaniLedgerScreen> createState() => _SurjaniLedgerScreenState();
}

class _SurjaniLedgerScreenState extends State<SurjaniLedgerScreen> with AutomaticKeepAliveClientMixin {
  final _dateCtrl = TextEditingController(text: DateFormat('yyyy-MM-dd').format(DateTime.now()));
  final _partCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController(text: '0');
  final _rateCtrl = TextEditingController(text: '0');
  final _debitCtrl = TextEditingController(text: '0');
  final _creditCtrl = TextEditingController(text: '0');
  final _noteCtrl = TextEditingController();
  final _openingCtrl = TextEditingController(text: '0');
  final _openingDateCtrl = TextEditingController(text: DateFormat('yyyy-MM-dd').format(DateTime.now()));
  bool _autoDebit = true;
  bool _loading = true;
  List<SurjaniLedgerEntry> _rows = [];

  @override
  void initState() {
    super.initState();
    _load();
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
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;

  Future<void> _load() async {
    final list = await SurjaniLedgerStore.loadAll();
    setState(() {
      _rows = list;
      _loading = false;
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
    if (_rows.isNotEmpty && _rows.first.particulars.toLowerCase() == 'opening balance') {
      return _rows.first.date;
    }
    return DateFormat('yyyy-MM-dd').format(DateTime.now());
  }

  double _parseDouble(TextEditingController c) => double.tryParse(c.text.replaceAll(',', '')) ?? 0.0;

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
      initialDate: _clampDate(parseInvoiceDate(_dateCtrl.text.isNotEmpty ? _dateCtrl.text : DateFormat('yyyy-MM-dd').format(now)), first),
      firstDate: first,
      lastDate: DateTime(now.year + 5),
    );
    if (picked != null) {
      _dateCtrl.text = DateFormat('yyyy-MM-dd').format(picked);
    }
  }

  Future<void> _saveOpening() async {
    final opening = _parseDouble(_openingCtrl);
    final openingDate = _openingDateCtrl.text.trim().isEmpty
        ? DateFormat('yyyy-MM-dd').format(DateTime.now())
        : _openingDateCtrl.text.trim();
    final others = _rows.where((e) => e.particulars.toLowerCase() != 'opening balance').toList();
    if (opening.abs() < 0.0001) {
      // remove opening row if zero
      await SurjaniLedgerStore.saveAll(others);
      await _load();
      return;
    }
    final obEntry = SurjaniLedgerEntry(
      id: 'SL-OPEN',
      date: openingDate,
      particulars: 'Opening Balance',
      qty: 0,
      rate: 0,
      debit: opening >= 0 ? opening : 0,
      credit: opening < 0 ? opening.abs() : 0,
      note: null,
    );
    others.insert(0, obEntry);
    await SurjaniLedgerStore.saveAll(others);
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
    final entry = SurjaniLedgerEntry(
      id: await SurjaniLedgerStore.nextId(parseInvoiceDate(dateStr)),
      date: dateStr,
      particulars: particulars,
      qty: _parseDouble(_qtyCtrl),
      rate: _parseDouble(_rateCtrl),
      debit: _parseDouble(_debitCtrl),
      credit: _parseDouble(_creditCtrl),
      note: _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
    );
    await SurjaniLedgerStore.add(entry);
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
      final file = await exportSurjaniLedger();
      await OpenFilex.open(file.path);
    } catch (_) {
      if (!mounted) return;
      showErr(context, 'Export failed');
    }
  }

  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Clear Surjani Ledger?'),
        content: const Text('This will delete all Surjani ledger entries.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Clear')),
        ],
      ),
    );
    if (ok == true) {
      await SurjaniLedgerStore.clearAll();
      await _load();
    }
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
    if (_loading) return const Center(child: CircularProgressIndicator());
    final totalDebit = _rows.fold<double>(0, (s, e) => s + e.debit);
    final totalCredit = _rows.fold<double>(0, (s, e) => s + e.credit);
    final balance = totalDebit - totalCredit;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
            ElevatedButton.icon(onPressed: _addEntry, icon: const Icon(Icons.add), label: const Text('Add Entry')),
            const SizedBox(width: 8),
            OutlinedButton.icon(onPressed: _export, icon: const Icon(Icons.file_download), label: const Text('Export Excel')),
            const SizedBox(width: 8),
            TextButton.icon(onPressed: _clearAll, icon: const Icon(Icons.delete_outline), label: const Text('Clear All')),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(child: _table()),
      ],
    );
  }

  Widget _openingBalanceCard() {
    return Card(
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
            ElevatedButton(onPressed: _saveOpening, child: const Text('Save Opening')),
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
      initialDate: _clampDate(parseInvoiceDate(controller.text.isNotEmpty ? controller.text : DateFormat('yyyy-MM-dd').format(now)), first),
      firstDate: first,
      lastDate: DateTime(now.year + 5),
    );
    if (picked != null) {
      controller.text = DateFormat('yyyy-MM-dd').format(picked);
    }
  }

  DateTime _clampDate(DateTime value, DateTime min) {
    if (value.isBefore(min)) return min;
    return value;
  }

  Widget _entryForm() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: [
            _dateField(),
            _textField(_partCtrl, 'Source / Particulars', width: 260),
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

  Widget _numberField(TextEditingController c, String label, {double width = 120}) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: c,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: label),
      ),
    );
  }

  Widget _textField(TextEditingController c, String label, {double width = 200}) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: c,
        decoration: InputDecoration(labelText: label),
      ),
    );
  }

  Widget _chip(String label, double value) {
    return Chip(
      label: Text('$label: ${value.toStringAsFixed(0)}'),
      backgroundColor: Theme.of(context).colorScheme.primary.withOpacity(0.08),
    );
  }

  Widget _table() {
    if (_rows.isEmpty) {
      return const Center(child: Text('No entries yet'));
    }
    return Card(
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columns: const [
            DataColumn(label: Text('Date')),
            DataColumn(label: Text('Particulars')),
            DataColumn(label: Text('Qty')),
            DataColumn(label: Text('Rate')),
            DataColumn(label: Text('Debit')),
            DataColumn(label: Text('Credit')),
            DataColumn(label: Text('Balance')),
            DataColumn(label: Text('Note')),
          ],
          rows: [
            for (int i = 0; i < _rows.length; i++)
              _buildRow(_rows[i], _runningBalanceAt(i)),
          ],
        ),
      ),
    );
  }

  DataRow _buildRow(SurjaniLedgerEntry e, double running) {
    return DataRow(
      cells: [
        DataCell(Text(e.date)),
        DataCell(Text(e.particulars)),
        DataCell(Text(e.qty.toStringAsFixed(2))),
        DataCell(Text(e.rate.toStringAsFixed(2))),
        DataCell(Text(e.debit.toStringAsFixed(0))),
        DataCell(Text(e.credit.toStringAsFixed(0))),
        DataCell(Text(running.toStringAsFixed(0))),
        DataCell(Text(e.note ?? '')),
      ],
    );
  }
}
