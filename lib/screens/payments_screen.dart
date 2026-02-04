import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';

import '../core/app_bus.dart';
import '../core/enums.dart';
import '../models/customer.dart';
import '../models/invoice.dart';
import '../models/payment.dart';
import '../services/excel_service.dart';
import '../services/storage.dart';
import '../services/paths.dart';
import '../utils/date.dart';
import '../utils/format.dart';
import '../utils/snackbar.dart';

class PaymentsScreen extends StatefulWidget {
  const PaymentsScreen({super.key});
  @override
  State<PaymentsScreen> createState() => _PaymentsScreenState();
}

class _PaymentsScreenState extends State<PaymentsScreen> with AutomaticKeepAliveClientMixin {
  final TextEditingController _q = TextEditingController();
  SortMode _sortPayments = SortMode.mostUnpaid;
  final FocusNode _sortFocusPayments = FocusNode(skipTraversal: true, canRequestFocus: false);
  final Map<String, _AddPaymentFormState> _forms = {};

  List<_KhataRow> _rows = [];
  Map<String, List<PaymentEntry>> _ledgerByCustomer = {};
  List<String> _noteSuggestions = [];

  @override
  void initState() {
    super.initState();
    _load();
    AppBus.dataTick.addListener(_onDataTick);
  }

  void _onDataTick() {
    if (mounted) {
      _load();
    }
  }

  @override
  void dispose() {
    _q.dispose();
    _sortFocusPayments.dispose();
    for (final f in _forms.values) {
      f.dispose();
    }
    AppBus.dataTick.removeListener(_onDataTick);
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;

  Future<void> _load() async {
    await syncInvoicesPaidFromPayments();
    final invoices = await Store.loadAll();
    final ledger = await PaymentStore.loadAll();
    final customers = await CustomerStore.loadAll();
    final activeCustomers = customers.where((c) => c.active).toList();
    final inactiveKeys = customers.where((c) => !c.active).map((c) => _customerKey(c.id, c.name)).toSet();

    final ledgerByCustomer = <String, List<PaymentEntry>>{};
    for (final p in ledger) {
      final key = _customerKey(p.customerId, p.customer);
      if (inactiveKeys.contains(key)) continue;
      (ledgerByCustomer[key] ??= []).add(p);
    }
    final noteSeen = <String>{};
    final noteSuggestions = <String>[];
    for (final p in ledger.reversed) {
      final note = (p.note ?? '').trim();
      if (note.isEmpty) continue;
      final key = note.toLowerCase();
      if (noteSeen.add(key)) {
        noteSuggestions.add(note);
      }
    }
    for (final list in ledgerByCustomer.values) {
      list.sort((a, b) => a.date.compareTo(b.date));
    }

    final rowBuilders = <String, _KhataRowBuilder>{};
    Customer? findCustomer(String key) {
      try {
        return activeCustomers.firstWhere((c) => _customerKey(c.id, c.name) == key);
      } catch (_) {
        return null;
      }
    }

    for (final inv in invoices) {
      if (inv.walkIn) continue;
      final key = _customerKey(inv.customerId, inv.customer);
      if (inactiveKeys.contains(key)) continue;
      final existing = rowBuilders.putIfAbsent(key, () => _KhataRowBuilder());
      existing.name ??= inv.customer;
      existing.id ??= inv.customerId;
      existing.sales += inv.balance;
      existing.lastSale = _maxDate(existing.lastSale, parseInvoiceDate(inv.date));
    }

    for (final p in ledger) {
      final key = _customerKey(p.customerId, p.customer);
      if (inactiveKeys.contains(key)) continue;
      final existing = rowBuilders.putIfAbsent(key, () => _KhataRowBuilder());
      existing.name ??= p.customer;
      existing.id ??= p.customerId;
      existing.payments += p.effectiveAmount;
      existing.lastPayment = _maxDate(existing.lastPayment, parseInvoiceDate(p.date));
    }

    // Fill contact info from customer master
    for (final entry in rowBuilders.entries) {
      final cust = findCustomer(entry.key);
      if (cust != null) {
        entry.value.name ??= cust.name;
        entry.value.id ??= cust.id;
        entry.value.contact ??= cust.contact;
      }
    }

    // Ensure every customer from master appears even if zero sales/payments
    for (final cust in activeCustomers) {
      final key = _customerKey(cust.id, cust.name);
      final existing = rowBuilders.putIfAbsent(key, () => _KhataRowBuilder());
      existing.name ??= cust.name;
      existing.id ??= cust.id;
      existing.contact ??= cust.contact;
    }

    final rows = <_KhataRow>[];
    for (final entry in rowBuilders.entries) {
      final b = entry.value;
      rows.add(_KhataRow(
        key: entry.key,
        id: b.id ?? '',
        name: b.name ?? entry.key,
        contact: b.contact ?? '',
        sales: b.sales,
        payments: b.payments,
        lastActivity: _latestOf(b.lastSale, b.lastPayment),
      ));
    }

    if (!mounted) return;
    setState(() {
      _rows = rows;
      _ledgerByCustomer = ledgerByCustomer;
      _noteSuggestions = noteSuggestions;
    });
  }

  DateTime? _maxDate(DateTime? a, DateTime b) {
    if (a == null) return b;
    return a.isAfter(b) ? a : b;
  }

  DateTime? _latestOf(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

  String _customerKey(String id, String name) => (id.trim().isNotEmpty ? id : name).trim().toLowerCase();

  // Open payments subfolders from UI
  Future<void> _openPaymentDir(String leaf) async {
    try {
      final payRoot = await subdir('payments');
      final dir = Directory('${payRoot.path}${Platform.pathSeparator}$leaf');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      await OpenFilex.open(dir.path);
    } catch (_) {
      if (!mounted) return;
      showErr(context, 'Unable to open folder');
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_rows.isEmpty) return const Center(child: Text('No customers yet'));
    final isDesktop = !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
    final q = _q.text.trim().toLowerCase();
    var filtered = _rows.where((row) {
      if (q.isEmpty) return true;
      final byName = row.name.toLowerCase().contains(q);
      final byId = row.id.toLowerCase().contains(q);
      return byName || byId;
    }).toList();

    switch (_sortPayments) {
      case SortMode.mostUnpaid:
        filtered.sort((a, b) => b.net.compareTo(a.net));
        break;
      case SortMode.mostPaid:
        filtered.sort((a, b) => a.net.compareTo(b.net));
        break;
      case SortMode.newestFirst:
        filtered.sort((a, b) => (b.lastActivity ?? DateTime(1900)).compareTo(a.lastActivity ?? DateTime(1900)));
        break;
      case SortMode.oldestFirst:
        filtered.sort((a, b) => (a.lastActivity ?? DateTime(1900)).compareTo(b.lastActivity ?? DateTime(1900)));
        break;
      case SortMode.mostSales:
      case SortMode.leastSales:
        break;
    }

    final listView = ListView.builder(
      physics: const ClampingScrollPhysics(),
      itemCount: filtered.length,
      itemBuilder: (_, i) {
        final row = filtered[i];
        final Color cardBg = row.net > 1e-6
            ? const Color(0xFFFFEBEE)
            : const Color(0xFFE8F5E9); // both credit and settled shown in green

        return Card(
          color: cardBg,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        row.displayTitle,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(_activityLabel(row), style: const TextStyle(color: Colors.black54)),
                  ],
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _kv('Sales', row.sales),
                    _kv('Payments', row.payments),
                    _kv('Net (Plus)', row.net),
                    _netBadge(row.net),
                    if (row.contact.isNotEmpty) Text('Contact: ${row.contact}'),
                    TextButton.icon(
                      onPressed: () => _openCustomerDetail(row),
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Open'),
                    ),
                  ],
                ),
                const Divider(height: 24),
              ],
            ),
          ),
        );
      },
    );

    return Column(
      children: [
        // Quick access to monthly payment exports folders
        Padding(
          padding: const EdgeInsets.only(left: 12, right: 12, bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Wrap(
                  alignment: WrapAlignment.start,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                        onPressed: () => _openPaymentDir('payment_details'),
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Open Payment Details Folder')),
                    OutlinedButton.icon(
                        onPressed: () => _openPaymentDir('payment_summary'),
                        icon: const Icon(Icons.folder_open),
                        label: const Text('Open Payment Summary Folder')),
                    OutlinedButton.icon(
                        onPressed: _rebuildAllReports,
                        icon: const Icon(Icons.refresh),
                        label: const Text('Rebuild All Reports')),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              DropdownButton<SortMode>(
                focusNode: _sortFocusPayments,
                value: _sortPayments,
                onChanged: (v) {
                  if (v == null) return;
                  setState(() => _sortPayments = v);
                  _sortFocusPayments.unfocus();
                },
                items: const [
                  DropdownMenuItem(value: SortMode.mostUnpaid, child: Text('Most Unpaid')),
                  DropdownMenuItem(value: SortMode.mostPaid, child: Text('Most Paid/Credit')),
                  DropdownMenuItem(value: SortMode.newestFirst, child: Text('Latest Activity')),
                  DropdownMenuItem(value: SortMode.oldestFirst, child: Text('Oldest Activity')),
                ],
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 12, right: 12, bottom: 8),
          child: TextField(
              controller: _q,
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search by name or customer ID'),
              onChanged: (_) => setState(() {})),
        ),
        Expanded(child: isDesktop ? listView : RefreshIndicator(onRefresh: _load, child: listView)),
      ],
    );
  }

  String _activityLabel(_KhataRow row) {
    final d = row.lastActivity;
    if (d == null) return 'No activity';
    return dfDay.format(d);
  }

  Future<void> _rebuildAllReports() async {
    if (!mounted) return;
    showOk(context, 'Rebuilding reports in background...');
    try {
      await rebuildAllReportsLedgerBased();
      if (!mounted) return;
      showOk(context, 'Reports rebuilt');
    } catch (err) {
      if (!mounted) return;
      showErr(context, 'Failed to rebuild: $err');
    }
  }

  Future<void> _openCustomerDetail(_KhataRow row) async {
    final form = _forms.putIfAbsent(row.key, () => _AddPaymentFormState());
    var ledger = await _loadLedgerFor(row.key);
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) {
      return StatefulBuilder(builder: (ctx, setPageState) {
        return Scaffold(
          appBar: AppBar(
            title: Text(row.displayTitle),
            leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.pop(ctx)),
          ),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 16,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _kv('Sales', row.sales),
                      _kv('Payments', row.payments),
                      _kv('Net (Plus)', row.net),
                      _netBadge(row.net),
                      if (row.contact.isNotEmpty) Text('Contact: ${row.contact}'),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _ledgerList(ledger, onChanged: () async {
                    _loadLedgerFor(row.key).then((v) {
                      ledger = v;
                      setPageState(() {});
                    });
                  }),
                  const SizedBox(height: 12),
                  TextButton.icon(
                    onPressed: () => setPageState(() {}),
                    icon: const Icon(Icons.add),
                    label: const Text('Add Payment'),
                  ),
                  _addPaymentForm(
                    row,
                    setStateFn: setPageState,
                    onChanged: () {
                      _loadLedgerFor(row.key).then((v) {
                        ledger = v;
                        setPageState(() {});
                      });
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      });
    }));
    _forms.remove(row.key)?.dispose();
    await _load();
  }

  Future<List<PaymentEntry>> _loadLedgerFor(String customerKey) async {
    final all = await PaymentStore.loadAll();
    return all.where((e) => _customerKey(e.customerId, e.customer) == customerKey).toList()
      ..sort((a, b) => a.date.compareTo(b.date));
  }

  Widget _kv(String label, double value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label: '),
        Text(fmt0(value), style: numStyle(weight: FontWeight.w600)),
      ],
    );
  }

  Widget _netBadge(double net) {
    if (net > 1e-6) {
      return _statusChip(label: 'Customer owes', fg: const Color(0xFFB71C1C), bg: const Color(0xFFFFCDD2));
    } else if (net < -1e-6) {
      return _statusChip(label: 'In credit', fg: const Color(0xFF1B5E20), bg: const Color(0xFFC8E6C9));
    }
    return _statusChip(label: 'Settled', fg: const Color(0xFF1B5E20), bg: const Color(0xFFC8E6C9));
  }

  Widget _statusChip({required String label, required Color fg, required Color bg}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
      child: Text(label, style: TextStyle(color: fg, fontWeight: FontWeight.w600)),
    );
  }

  Widget _ledgerList(List<PaymentEntry> entries, {VoidCallback? onChanged}) {
    if (entries.isEmpty) return const Text('No payments recorded');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.centerLeft,
          child: const Row(children: [
            SizedBox(width: 110, child: Text('Date', style: TextStyle(fontWeight: FontWeight.w600))),
            Expanded(child: Text('Type / Note', style: TextStyle(fontWeight: FontWeight.w600))),
            SizedBox(width: 120, child: Align(alignment: Alignment.centerRight, child: Text('Amount', style: TextStyle(fontWeight: FontWeight.w600)))),
            SizedBox(width: 48, child: Text('')),
          ]),
        ),
        ...entries.map((e) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              child: Row(children: [
                SizedBox(width: 110, child: Text(e.date)),
                Expanded(
                    child: Text(
                  _entryDetails(e),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.black87),
                )),
                SizedBox(width: 120, child: Text(fmt0(e.effectiveAmount), textAlign: TextAlign.right, style: numStyle(weight: FontWeight.w600))),
                SizedBox(
                    width: 48,
                    child: IconButton(
                        tooltip: 'Delete payment',
                        icon: const Icon(Icons.remove_circle_outline, color: Color(0xFFB71C1C)),
                        onPressed: () => _confirmDeletePayment(e, onChanged: onChanged))),
              ]),
            )),
      ],
    );
  }

  String _entryDetails(PaymentEntry e) {
    final details = <String>[];
    details.add(paymentTypeLabel(e.type));
    if ((e.note ?? '').isNotEmpty) details.add(e.note!);
    if (e.type == PaymentType.cheque) {
      if ((e.bank ?? '').isNotEmpty) details.add(e.bank!);
      if ((e.chequeNo ?? '').isNotEmpty) details.add('Chq ${e.chequeNo}');
    } else if (e.type == PaymentType.bank) {
      if ((e.bankMode ?? '').isNotEmpty) details.add(e.bankMode!);
      if ((e.bank ?? '').isNotEmpty) details.add(e.bank!);
      if ((e.txnId ?? '').isNotEmpty) details.add(e.txnId!);
    }
    if (e.discount.abs() > 0.0001) details.add('Discount ${fmt0(e.discount)}');
    return details.isEmpty ? '-' : details.join(' / ');
  }

  Widget _addPaymentForm(_KhataRow row, {required StateSetter setStateFn, VoidCallback? onChanged}) {
    final f = _forms.putIfAbsent(row.key, () => _AddPaymentFormState());
    return Card(
      elevation: 0,
      color: const Color(0xFFFAFAFA),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                    label: const Text('Cash'),
                    selected: f.type == PaymentType.cash,
                    onSelected: (_) => setStateFn(() => f.type = PaymentType.cash),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    side: BorderSide(color: f.type == PaymentType.cash ? Colors.transparent : const Color(0x33000000)),
                    labelPadding: const EdgeInsets.symmetric(horizontal: 12),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact),
                ChoiceChip(
                    label: const Text('Cheque'),
                    selected: f.type == PaymentType.cheque,
                    onSelected: (_) => setStateFn(() => f.type = PaymentType.cheque),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    side: BorderSide(color: f.type == PaymentType.cheque ? Colors.transparent : const Color(0x33000000)),
                    labelPadding: const EdgeInsets.symmetric(horizontal: 12),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact),
                ChoiceChip(
                    label: const Text('Bank'),
                    selected: f.type == PaymentType.bank,
                    onSelected: (_) => setStateFn(() => f.type = PaymentType.bank),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    side: BorderSide(color: f.type == PaymentType.bank ? Colors.transparent : const Color(0x33000000)),
                    labelPadding: const EdgeInsets.symmetric(horizontal: 12),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact),
              ],
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: InkWell(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: f.date,
                      firstDate: DateTime(2000),
                      lastDate: DateTime(2100),
                    );
                    if (picked != null) {
                      setStateFn(() => f.date = picked);
                    }
                  },
                  child: InputDecorator(
                    decoration: const InputDecoration(labelText: 'Payment date'),
                    child: Row(
                      children: [
                        const Icon(Icons.calendar_today, size: 18),
                        const SizedBox(width: 8),
                        Text(dfDay.format(f.date)),
                      ],
                    ),
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                  child: TextField(
                      controller: f.amount,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))],
                      decoration: const InputDecoration(labelText: 'Amount'))),
              const SizedBox(width: 12),
              Expanded(
                  child: TextField(
                controller: f.discount,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))],
                decoration: const InputDecoration(labelText: 'Discount (optional)'),
              )),
              const SizedBox(width: 12),
              Expanded(
                  child: RawAutocomplete<String>(
                textEditingController: f.note,
                focusNode: f.noteFocus,
                optionsBuilder: (textEditingValue) {
                  if (_noteSuggestions.isEmpty) return const Iterable<String>.empty();
                  final q = textEditingValue.text.trim().toLowerCase();
                  if (q.isEmpty) return _noteSuggestions;
                  return _noteSuggestions.where((n) => n.toLowerCase().contains(q));
                },
                onSelected: (v) => f.note.text = v,
                fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                  return TextField(
                    controller: controller,
                    focusNode: focusNode,
                    decoration: const InputDecoration(labelText: 'Note'),
                    onSubmitted: (_) => onFieldSubmitted(),
                    onTap: () {
                      // Force options to show on tap even when text is empty.
                      controller.value = controller.value;
                    },
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
                        constraints: const BoxConstraints(maxHeight: 200, minWidth: 200),
                        child: ListView.builder(
                          padding: EdgeInsets.zero,
                          itemCount: options.length,
                          itemBuilder: (_, i) {
                            final opt = options.elementAt(i);
                            return ListTile(
                              dense: true,
                              title: Text(opt),
                              onTap: () => onSelected(opt),
                            );
                          },
                        ),
                      ),
                    ),
                  );
                },
              )),
            ]),
            if (f.type == PaymentType.cheque) ...[
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: TextField(controller: f.bank, decoration: const InputDecoration(labelText: 'Bank'))),
                const SizedBox(width: 12),
                Expanded(child: TextField(controller: f.chequeNo, decoration: const InputDecoration(labelText: 'Cheque No'))),
              ]),
            ] else if (f.type == PaymentType.bank) ...[
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: TextField(controller: f.bank, decoration: const InputDecoration(labelText: 'Bank'))),
                const SizedBox(width: 12),
                Expanded(child: TextField(controller: f.txnId, decoration: const InputDecoration(labelText: 'Txn ID'))),
                const SizedBox(width: 12),
                SizedBox(
                  width: 180,
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('mode-${f.bankMode}-${row.key}'),
                    value: f.bankMode,
                    items: const [
                      DropdownMenuItem(value: 'Deposit', child: Text('Deposit')),
                      DropdownMenuItem(value: 'Transfer', child: Text('Transfer')),
                    ],
                    onChanged: (v) => setStateFn(() => f.bankMode = v ?? 'Deposit'),
                    decoration: const InputDecoration(labelText: 'Mode'),
                  ),
                ),
              ]),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.icon(
                    onPressed: () => _savePayment(row, onChanged: () { setStateFn(() {}); onChanged?.call(); }),
                    icon: const Icon(Icons.save),
                    label: const Text('Save Payment')),
                TextButton(
                    onPressed: () {
                      setStateFn(() {
                        f.clear();
                      });
                    },
                    child: const Text('Cancel')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _savePayment(_KhataRow row, {VoidCallback? onChanged}) async {
    final f = _forms.putIfAbsent(row.key, () => _AddPaymentFormState());
    final amt = double.tryParse(f.amount.text.trim()) ?? 0.0;
    final disc = double.tryParse(f.discount.text.trim()) ?? 0.0;
    if (amt <= 0 && disc <= 0) {
      showErr(context, 'Enter an amount or discount');
      return;
    }
    try {
        await addPaymentForCustomer(
          customerId: row.id,
          customerName: row.name,
          type: f.type,
          date: f.date,
          amount: amt,
          discount: disc,
          chequeNo: f.chequeNo.text.trim().isEmpty ? null : f.chequeNo.text.trim(),
          bank: f.bank.text.trim().isEmpty ? null : f.bank.text.trim(),
          txnId: f.txnId.text.trim().isEmpty ? null : f.txnId.text.trim(),
        bankMode: f.type == PaymentType.bank ? (f.bankMode) : null,
        note: f.note.text.trim().isEmpty ? null : f.note.text.trim(),
      );
      if (!mounted) return;
      showOk(context, 'Payment saved');
      setState(() {
        f.clear();
      });
      await _load();
      onChanged?.call();
    } catch (err) {
      if (!mounted) return;
      showErr(context, err.toString());
    }
  }

  Future<void> _confirmDeletePayment(PaymentEntry e, {VoidCallback? onChanged}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Payment'),
        content: Text('Delete ${paymentTypeLabel(e.type)} of ${fmt0(e.effectiveAmount)}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) {
      return;
    }
    try {
      final removed = await PaymentStore.deleteById(e.id);
      if (!removed) {
        if (!mounted) return;
        showErr(context, 'Entry not found');
        return;
      }
      await syncInvoicesPaidFromPayments();
      try {
        await rebuildMonthlyPaymentsExcels(parseInvoiceDate(e.date));
      } catch (_) {}
      try {
        await refreshReportsForInvoices(<int>{});
      } catch (_) {}
      if (!mounted) return;
      showOk(context, 'Payment deleted');
      await _load();
      onChanged?.call();
    } catch (err) {
      if (!mounted) return;
      showErr(context, 'Failed to delete: $err');
    }
  }
}

class _KhataRow {
  final String key;
  final String id;
  final String name;
  final String contact;
  final double sales;
  final double payments;
  final DateTime? lastActivity;
  const _KhataRow({
    required this.key,
    required this.id,
    required this.name,
    required this.contact,
    required this.sales,
    required this.payments,
    required this.lastActivity,
  });
  double get net => (sales - payments);
  String get displayTitle => id.isNotEmpty ? '$name  ($id)' : name;
}

class _KhataRowBuilder {
  String? id;
  String? name;
  String? contact;
  double sales = 0.0;
  double payments = 0.0;
  DateTime? lastSale;
  DateTime? lastPayment;
}

class _AddPaymentFormState {
  PaymentType type = PaymentType.cash;
  DateTime date = DateTime.now();
  final TextEditingController amount = TextEditingController();
  final TextEditingController note = TextEditingController();
  final FocusNode noteFocus = FocusNode();
  final TextEditingController chequeNo = TextEditingController();
  final TextEditingController bank = TextEditingController();
  final TextEditingController txnId = TextEditingController();
  final TextEditingController discount = TextEditingController();
  String bankMode = 'Deposit';
  void clear() {
    date = DateTime.now();
    amount.clear();
    note.clear();
    chequeNo.clear();
    bank.clear();
    txnId.clear();
    discount.clear();
    bankMode = 'Deposit';
    type = PaymentType.cash;
  }

  void dispose() {
    amount.dispose();
    note.dispose();
    noteFocus.dispose();
    chequeNo.dispose();
    bank.dispose();
    txnId.dispose();
    discount.dispose();
  }
}
