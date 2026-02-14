import 'package:flutter/material.dart';
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
  final _dateCtrl = TextEditingController(text: formatInvoiceDate(DateTime.now()));
  final _partCtrl = TextEditingController();
  final _qtyCtrl = TextEditingController(text: '0');
  final _rateCtrl = TextEditingController(text: '0');
  final _debitCtrl = TextEditingController(text: '0');
  final _creditCtrl = TextEditingController(text: '0');
  final _noteCtrl = TextEditingController();
  final _openingCtrl = TextEditingController(text: '0');
  final _openingDateCtrl = TextEditingController(text: formatInvoiceDate(DateTime.now()));
  bool _autoDebit = true;
  bool _loading = true;
  List<SurjaniLedgerEntry> _rows = [];
  List<String> _particularSuggestions = [];
  final FocusNode _partFocus = FocusNode();

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
    _partFocus.dispose();
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;

  Future<void> _load() async {
    final list = await SurjaniLedgerStore.loadAll();
    final seen = <String>{};
    final suggestions = <String>[];
    for (final e in list.reversed) {
      final p = e.particulars.trim();
      if (p.isEmpty || p.toLowerCase() == 'opening balance') continue;
      final key = p.toLowerCase();
      if (seen.add(key)) suggestions.add(p);
    }
    setState(() {
      _rows = list;
      _particularSuggestions = suggestions;
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
      try {
        return formatInvoiceDate(parseInvoiceDate(_rows.first.date));
      } catch (_) {
        return _rows.first.date;
      }
    }
    return formatInvoiceDate(DateTime.now());
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
      initialDate: _clampDate(parseInvoiceDate(_dateCtrl.text.isNotEmpty ? _dateCtrl.text : formatInvoiceDate(now)), first),
      firstDate: first,
      lastDate: DateTime(now.year + 5),
    );
    if (picked != null) {
      _dateCtrl.text = formatInvoiceDate(picked);
    }
  }

  Future<void> _saveOpening() async {
    final opening = _parseDouble(_openingCtrl);
    final openingDate = _openingDateCtrl.text.trim().isEmpty
        ? formatInvoiceDate(DateTime.now())
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

  bool _isOpeningEntry(SurjaniLedgerEntry e) =>
      e.id == 'SL-OPEN' || e.particulars.toLowerCase() == 'opening balance';

  Future<void> _editEntry(SurjaniLedgerEntry e) async {
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
          title: const Text('Edit Surjani Entry'),
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
                          initialDate: _clampDate(parseInvoiceDate(dateCtrl.text.isNotEmpty ? dateCtrl.text : formatInvoiceDate(now)), first),
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
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
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
        await SurjaniLedgerStore.upsert(updated);
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

  Future<void> _deleteEntry(SurjaniLedgerEntry e) async {
    final label = e.particulars.trim().isEmpty ? e.id : e.particulars;
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Entry'),
        content: Text('Delete "$label"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await SurjaniLedgerStore.delete(e.id);
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
      initialDate: _clampDate(parseInvoiceDate(controller.text.isNotEmpty ? controller.text : formatInvoiceDate(now)), first),
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
    return Card(
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
      backgroundColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
    );
  }

  Widget _particularField(TextEditingController c, {required FocusNode focusNode, double width = 260}) {
    return SizedBox(
      width: width,
      child: RawAutocomplete<String>(
        textEditingController: c,
        focusNode: focusNode,
        optionsBuilder: (textEditingValue) {
          final q = textEditingValue.text.trim().toLowerCase();
          if (q.isEmpty) return const Iterable<String>.empty();
          return _particularSuggestions.where((s) => s.toLowerCase().contains(q));
        },
        onSelected: (v) => c.text = v,
        fieldViewBuilder: (context, controller, node, onFieldSubmitted) {
          return TextField(
            controller: controller,
            focusNode: node,
            decoration: const InputDecoration(labelText: 'Source / Particulars'),
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
                constraints: const BoxConstraints(maxHeight: 220, maxWidth: 320),
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
            DataColumn(label: Text('Actions')),
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
                      icon: const Icon(Icons.delete_outline, size: 18, color: Color(0xFFB71C1C)),
                      onPressed: () => _deleteEntry(e),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}
