import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'dart:io';

import '../core/app_bus.dart';
import '../core/enums.dart';
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
  @override State<PaymentsScreen> createState()=>_PaymentsScreenState();
}

class _PaymentsScreenState extends State<PaymentsScreen> with AutomaticKeepAliveClientMixin {
  List<Invoice> _invoices = [];
  final TextEditingController _q = TextEditingController();
  // Sorting state for payments tab
  SortMode _sortPayments = SortMode.newestFirst;
  final FocusNode _sortFocusPayments = FocusNode(skipTraversal: true, canRequestFocus: false);
  // Custom payments filter state
  PaymentsFilter _paymentsFilter = PaymentsFilter.all;
  final TextEditingController _filterQtyCtrl = TextEditingController(text: '1');
  TimeUnit _filterUnit = TimeUnit.months; // default 1 month
  // Expanded and forms state
  final Set<int> _expanded = <int>{};
  final Map<int, bool> _showAddForm = {};
  final Map<int, _AddPaymentFormState> _forms = {};
  Map<int, List<PaymentEntry>> _paymentsByInvoice = {};

  // Open payments subfolders from UI
  Future<void> _openPaymentDir(String leaf) async {
    try {
      final payRoot = await subdir('payments');
      final dir = Directory('${payRoot.path}${Platform.pathSeparator}$leaf');
      if (!await dir.exists()) { await dir.create(recursive: true); }
      await OpenFilex.open(dir.path);
    } catch (_) {
      if (!mounted) return; showErr(context, 'Unable to open folder');
    }
  }

  @override void initState(){
    super.initState();
    _load();
    AppBus.dataTick.addListener(_onDataTick);
  }
  void _onDataTick(){ if(mounted) { _load(); } }

  @override void dispose(){
    _q.dispose();
    _sortFocusPayments.dispose();
    _filterQtyCtrl.dispose();
    AppBus.dataTick.removeListener(_onDataTick);
    super.dispose();
  }
  @override bool get wantKeepAlive => true;

  Future<void> _load() async {
    await syncInvoicesPaidFromPayments();
    final list = await Store.loadAll(); list.sort((a,b)=>b.sNo.compareTo(a.sNo));
    // Load all payments once and group by invoice
    final entries = await PaymentStore.loadAll();
    final byInv = <int, List<PaymentEntry>>{};
    for (final e in entries) { (byInv[e.invoiceNo] ??= []).add(e); }
    if (!mounted) return;
    setState((){ _invoices=list; _paymentsByInvoice = byInv; });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_invoices.isEmpty) return const Center(child: Text('No invoices yet'));
    final isDesktop = !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
    final q = _q.text.trim().toLowerCase();
    var filtered = _invoices.where((inv){
      if (q.isEmpty) return true;
      final byName = inv.customer.toLowerCase().contains(q);
      final byId = inv.sNo.toString()==q || inv.sNo.toString().contains(q);
      return byName || byId;
    }).toList();
    // Apply custom filter if selected
    if (_paymentsFilter == PaymentsFilter.notPaidSince) {
      final days = _filterDays;
      filtered = filtered.where((inv) => _isNotPaidSinceDays(inv, days)).toList();
    }

    // Apply sort
    switch (_sortPayments) {
      case SortMode.newestFirst: filtered.sort((a,b)=>b.sNo.compareTo(a.sNo)); break;
      case SortMode.oldestFirst: filtered.sort((a,b)=>a.sNo.compareTo(b.sNo)); break;
      case SortMode.mostUnpaid: filtered.sort((a,b)=>((b.balance-b.paid).compareTo(a.balance-a.paid))); break;
      case SortMode.mostPaid: filtered.sort((a,b)=>b.paid.compareTo(a.paid)); break;
      case SortMode.mostSales:
      case SortMode.leastSales:
        break;
    }

    final listView = ListView.builder(
      physics: const ClampingScrollPhysics(),
      itemCount: filtered.length,
      itemBuilder: (_, i){
        final inv=filtered[i];
        // Color-code by payment state
        final bool fullyPaid = inv.remaining <= 1e-6;
        final bool fullyUnpaid = inv.paid <= 1e-6;
        final Color cardBg = fullyPaid
            ? const Color(0xFFE8F5E9)
            : (fullyUnpaid ? const Color(0xFFFFEBEE) : const Color(0xFFFFFDE7));
        final entries = _paymentsByInvoice[inv.sNo] ?? const <PaymentEntry>[];
        final pending = entries.where((e)=>e.status==PaymentStatus.pending).map((e)=>e.amount).fold<double>(0.0,(s,a)=>s+a);
        final bounced = entries.where((e)=>e.status==PaymentStatus.bounced).map((e)=>e.amount).fold<double>(0.0,(s,a)=>s+a);

        return Card(color: cardBg, child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(
                (){ final addr=inv.address.trim(); return addr.isNotEmpty? '#${inv.sNo}  ${inv.customer}  -  $addr' : '#${inv.sNo}  ${inv.customer}'; }(),
                style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
              Text(inv.date, style: const TextStyle(color: Colors.black54)),
            ]),
            const SizedBox(height:6),
            Wrap(spacing:16, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              _kv('Balance', inv.balance),
              _kv('Paid (Cleared)', inv.paid),
              _kv('Pending', pending),
              if (bounced > 0) _kv('Bounced', bounced),
              _kv('Remaining', (inv.balance - inv.paid).clamp(0.0, double.infinity).toDouble()),
              Text('Methods: ${_methodsSummary(entries)}'),
              TextButton.icon(
                onPressed: () {
                  setState(() {
                    if (_expanded.contains(inv.sNo)) {
                      _expanded.remove(inv.sNo);
                    } else {
                      _expanded.add(inv.sNo);
                    }
                  });
                },
                icon: Icon(_expanded.contains(inv.sNo)? Icons.expand_less : Icons.expand_more),
                label: const Text('Method'),
              ),
            ]),
            if (_expanded.contains(inv.sNo)) ...[
              const SizedBox(height:8),
              _paymentBreakdown(entries: entries),
              const SizedBox(height:8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: (){ setState(()=>_showAddForm[inv.sNo] = !(_showAddForm[inv.sNo] ?? false)); },
                  icon: const Icon(Icons.add),
                  label: const Text('Add Payment Method'),
                ),
              ),
              if (_showAddForm[inv.sNo] ?? false) _addMethodForm(inv),
              const Divider(height: 24),
            ],
          ]),
        ));
      },
    );

    return Column(children: [
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
                  OutlinedButton.icon(onPressed: () => _openPaymentDir('payment_details'), icon: const Icon(Icons.folder_open), label: const Text('Open Payment Details Folder')),
                  OutlinedButton.icon(onPressed: () => _openPaymentDir('payment_summary'), icon: const Icon(Icons.folder_open), label: const Text('Open Payment Summary Folder')),
                ],
              ),
            ),
            const SizedBox(width: 12),
            DropdownButton<PaymentsFilter>(
              value: _paymentsFilter,
              onChanged: (v) { if (v==null) return; setState(() => _paymentsFilter = v); },
              items: const [
                DropdownMenuItem(value: PaymentsFilter.all, child: Text('All Invoices')),
                DropdownMenuItem(value: PaymentsFilter.notPaidSince, child: Text('Not paid since.')),
              ],
            ),
            if (_paymentsFilter == PaymentsFilter.notPaidSince) ...[
              const SizedBox(width: 8),
              SizedBox(width: 64, child: TextField(controller: _filterQtyCtrl, decoration: const InputDecoration(hintText: 'Qty'), inputFormatters: [FilteringTextInputFormatter.digitsOnly], onChanged: (_)=>setState((){}))),
              const SizedBox(width: 8),
              DropdownButton<TimeUnit>(
                value: _filterUnit,
                onChanged: (u) { if (u!=null) setState(()=>_filterUnit=u); },
                items: const [
                  DropdownMenuItem(value: TimeUnit.days, child: Text('Days')),
                  DropdownMenuItem(value: TimeUnit.weeks, child: Text('Weeks')),
                  DropdownMenuItem(value: TimeUnit.months, child: Text('Months')),
                ],
              ),
            ],
            const SizedBox(width: 12),
            DropdownButton<SortMode>(
              focusNode: _sortFocusPayments,
              value: _sortPayments,
              onChanged: (v) { if (v == null) return; setState(() => _sortPayments = v); _sortFocusPayments.unfocus(); },
              items: const [
                DropdownMenuItem(value: SortMode.mostUnpaid, child: Text('Most Unpaid')),
                DropdownMenuItem(value: SortMode.mostPaid, child: Text('Most Paid')),
                DropdownMenuItem(value: SortMode.newestFirst, child: Text('Newest First')),
                DropdownMenuItem(value: SortMode.oldestFirst, child: Text('Oldest First')),
              ],
            ),
          ],
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(left: 12, right: 12, bottom: 8),
        child: TextField(controller: _q, decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search by name or invoice #'), onChanged: (_)=>setState((){})),
      ),
      Expanded(child: isDesktop ? listView : RefreshIndicator(onRefresh: _load, child: listView)),
    ]);
  }

  // Helpers for UI
  Widget _kv(String label, double value) {
    return Row(mainAxisSize: MainAxisSize.min, children: [ Text('$label: '), Text(fmt0(value), style: numStyle(weight: FontWeight.w600)), ]);
  }

  String _methodsSummary(List<PaymentEntry> entries) {
    if (entries.isEmpty) return '-';
    double cash = 0, chq = 0, bank = 0; double chqPending = 0, bankPending = 0;
    for (final e in entries) {
      switch (e.type) {
        case PaymentType.cash: cash += e.amount; break;
        case PaymentType.cheque: chq += e.amount; if (e.status == PaymentStatus.pending) chqPending += e.amount; break;
        case PaymentType.bank: bank += e.amount; if (e.status == PaymentStatus.pending) bankPending += e.amount; break;
      }
    }
    final parts = <String>[];
    if (cash > 0) parts.add('Cash (${cash.toStringAsFixed(0)})');
    if (chq > 0) parts.add('Cheque (${chq.toStringAsFixed(0)}${chqPending>0 ? ' Pending' : ''})');
    if (bank > 0) parts.add('Bank (${bank.toStringAsFixed(0)}${bankPending>0 ? ' Pending' : ''})');
    return parts.isEmpty ? '-' : parts.join(' + ');
  }

  Widget _statusChip(PaymentStatus s, {String? text}) {
    Color bg; String label; Color fg;
    switch (s) {
      case PaymentStatus.cleared: bg = const Color(0xFFE8F5E9); fg = const Color(0xFF1B5E20); label = 'Cleared'; break;
      case PaymentStatus.pending: bg = const Color(0xFFFFF8E1); fg = const Color(0xFFEF6C00); label = 'Pending'; break;
      case PaymentStatus.bounced: bg = const Color(0xFFFFEBEE); fg = const Color(0xFFB71C1C); label = 'Bounced'; break;
    }
    return Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)), child: Text(text ?? label, style: TextStyle(color: fg, fontWeight: FontWeight.w600)));
  }
  Widget _statusChipForEntry(PaymentEntry e) { final lbl = statusTextForEntry(e); return _statusChip(e.status, text: lbl); }

  Widget _vsep([double w=12]) => SizedBox(width: w);

  Widget _paymentBreakdown({required List<PaymentEntry> entries}) {
    if (entries.isEmpty) return const Text('No payments recorded');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        alignment: Alignment.centerLeft,
        child: const Row(children: [
          Expanded(child: Text('Method', style: TextStyle(fontWeight: FontWeight.w600))),
          SizedBox(width: 120, child: Align(alignment: Alignment.centerRight, child: Text('Amount', style: TextStyle(fontWeight: FontWeight.w600)))),
          SizedBox(width: 18),
          Expanded(child: Padding(padding: EdgeInsets.only(left: 12), child: Text('Details', style: TextStyle(fontWeight: FontWeight.w600)))),
          SizedBox(width: 140, child: Text('Status', style: TextStyle(fontWeight: FontWeight.w600))),
          SizedBox(width: 48, child: Text('')),
        ]),
      ),
      ...entries.map((e) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        child: Row(children: [
          Expanded(child: Text(paymentTypeLabel(e.type))),
          SizedBox(width: 120, child: Text(fmt0(e.amount), textAlign: TextAlign.right, style: numStyle(weight: FontWeight.w600))),
          _vsep(),
          Expanded(child: Padding(padding: const EdgeInsets.only(left: 12), child: Text(_entryDetails(e), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.black87)))),
          SizedBox(width: 140, child: Align(alignment: Alignment.centerLeft, child:
            (e.type == PaymentType.cash)
              ? _statusChipForEntry(e)
              : PopupMenuButton<PaymentStatus>(
                  tooltip: 'Change status',
                  onSelected: (v) { if (v != e.status) { _updatePaymentStatus(e, v); } },
                  itemBuilder: (ctx) => <PopupMenuEntry<PaymentStatus>>[
                    const PopupMenuItem(value: PaymentStatus.cleared, child: Text('Cleared')),
                    const PopupMenuItem(value: PaymentStatus.pending, child: Text('Pending')),
                    PopupMenuItem(value: PaymentStatus.bounced, child: Text(e.type == PaymentType.bank ? 'Returned' : 'Bounced')),
                  ],
                  child: _statusChipForEntry(e),
                ),
          )),
          SizedBox(width: 48, child: IconButton(tooltip: 'Delete payment', icon: const Icon(Icons.remove_circle_outline, color: Color(0xFFB71C1C)), onPressed: () => _confirmDeletePayment(e))),
        ]),
      )),
    ]);
  }

  String _entryDetails(PaymentEntry e) {
    if (e.type == PaymentType.cash) return '-';
    if (e.type == PaymentType.cheque) {
      final parts = <String>[]; if ((e.bank ?? '').isNotEmpty) parts.add(e.bank!); if ((e.chequeNo ?? '').isNotEmpty) parts.add(e.chequeNo!); return parts.isEmpty ? '-' : parts.join(' / ');
    }
    final parts = <String>[]; if ((e.bankMode ?? '').isNotEmpty) parts.add(e.bankMode!); if ((e.bank ?? '').isNotEmpty) parts.add(e.bank!); if ((e.txnId ?? '').isNotEmpty) parts.add(e.txnId!); return parts.isEmpty ? '-' : parts.join(' / ');
  }

  Widget _addMethodForm(Invoice inv) {
    final f = _forms.putIfAbsent(inv.sNo, () => _AddPaymentFormState());
    if (f.type == PaymentType.cash && f.status != PaymentStatus.cleared) f.status = PaymentStatus.cleared;
    return Card(
      elevation: 0, color: const Color(0xFFFAFAFA),
      child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 8, children: [
          ChoiceChip(label: const Text('Cash'), selected: f.type == PaymentType.cash, onSelected: (_)=>setState(()=>f.type = PaymentType.cash), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), side: BorderSide(color: f.type == PaymentType.cash ? Colors.transparent : const Color(0x33000000)), labelPadding: const EdgeInsets.symmetric(horizontal: 12), materialTapTargetSize: MaterialTapTargetSize.shrinkWrap, visualDensity: VisualDensity.compact),
          ChoiceChip(label: const Text('Cheque'), selected: f.type == PaymentType.cheque, onSelected: (_)=>setState(()=>f.type = PaymentType.cheque), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), side: BorderSide(color: f.type == PaymentType.cheque ? Colors.transparent : const Color(0x33000000)), labelPadding: const EdgeInsets.symmetric(horizontal: 12), materialTapTargetSize: MaterialTapTargetSize.shrinkWrap, visualDensity: VisualDensity.compact),
          ChoiceChip(label: const Text('Bank'), selected: f.type == PaymentType.bank, onSelected: (_)=>setState(()=>f.type = PaymentType.bank), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), side: BorderSide(color: f.type == PaymentType.bank ? Colors.transparent : const Color(0x33000000)), labelPadding: const EdgeInsets.symmetric(horizontal: 12), materialTapTargetSize: MaterialTapTargetSize.shrinkWrap, visualDensity: VisualDensity.compact),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: TextField(controller: f.amount, keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))], decoration: const InputDecoration(labelText: 'Amount'))),
          const SizedBox(width: 12),
          SizedBox(width: 200, child: DropdownButtonFormField<PaymentStatus>(
            key: ValueKey('status-${f.type}-${f.status}-${inv.sNo}'),
            initialValue: f.type == PaymentType.cash ? PaymentStatus.cleared : f.status,
            items: (){
              if (f.type == PaymentType.cash) {
                return const [DropdownMenuItem(value: PaymentStatus.cleared, child: Text('Cleared'))];
              }
              if (f.type == PaymentType.bank) {
                return const [
                  DropdownMenuItem(value: PaymentStatus.cleared, child: Text('Cleared')),
                  DropdownMenuItem(value: PaymentStatus.pending, child: Text('Pending')),
                  DropdownMenuItem(value: PaymentStatus.bounced, child: Text('Returned')),
                ];
              }
              return const [
                DropdownMenuItem(value: PaymentStatus.cleared, child: Text('Cleared')),
                DropdownMenuItem(value: PaymentStatus.pending, child: Text('Pending')),
                DropdownMenuItem(value: PaymentStatus.bounced, child: Text('Bounced')),
              ];
            }(),
            onChanged: (v){ if (f.type != PaymentType.cash) setState(()=>f.status = v ?? f.status); },
            decoration: const InputDecoration(labelText: 'Status'),
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
            SizedBox(width: 180, child: DropdownButtonFormField<String>(
              key: ValueKey('mode-${f.bankMode}-${inv.sNo}'),
              initialValue: f.bankMode,
              items: const [
                DropdownMenuItem(value: 'Deposit', child: Text('Deposit')),
                DropdownMenuItem(value: 'Transfer', child: Text('Transfer')),
              ],
              onChanged: (v){ setState(()=> f.bankMode = v ?? 'Deposit'); },
              decoration: const InputDecoration(labelText: 'Mode'),
            )),
          ]),
        ],
        const SizedBox(height: 12),
        Wrap(spacing: 8, children: [
          FilledButton.icon(onPressed: () => _saveInlinePayment(inv), icon: const Icon(Icons.save), label: const Text('Save Payment')),
          TextButton(onPressed: (){ setState((){ _forms[inv.sNo]?.clear(); _showAddForm[inv.sNo] = false; }); }, child: const Text('Cancel')),
        ]),
      ])),
    );
  }

  Future<void> _saveInlinePayment(Invoice inv) async {
    final f = _forms[inv.sNo] ?? _AddPaymentFormState();
    final amt = double.tryParse(f.amount.text.trim()) ?? 0.0;
    if (amt <= 0) { showErr(context, 'Enter a valid amount'); return; }
    try {
      await addPaymentForInvoices(
        type: f.type,
        date: parseInvoiceDate(inv.date),
        invoiceToAmount: {inv.sNo: amt},
        chequeNo: f.chequeNo.text.trim().isEmpty ? null : f.chequeNo.text.trim(),
        bank: f.bank.text.trim().isEmpty ? null : f.bank.text.trim(),
        txnId: f.txnId.text.trim().isEmpty ? null : f.txnId.text.trim(),
        bankMode: f.type == PaymentType.bank ? (f.bankMode) : null,
        status: f.status,
      );
      if (!mounted) return;
      showOk(context, 'Payment saved');
      setState((){ _forms[inv.sNo]?.clear(); _showAddForm[inv.sNo] = false; });
      await _load();
    } catch (err) {
      if (!mounted) return; showErr(context, err.toString());
    }
  }

  Future<void> _updatePaymentStatus(PaymentEntry e, PaymentStatus s) async {
    try {
      await PaymentStore.updateStatusForGroup(e.groupId, s);
      await syncInvoicesPaidFromPayments();
      try { await rebuildMonthlyPaymentsExcels(parseInvoiceDate(e.date)); } catch (_) {}
      try {
        final all = await PaymentStore.loadAll();
        final sNos = all.where((x)=>x.groupId==e.groupId).map((x)=>x.invoiceNo).toSet();
        await refreshReportsForInvoices(sNos);
      } catch (_) {}
      if (!mounted) return;
      final label = (e.type == PaymentType.bank && s == PaymentStatus.bounced) ? 'Returned' : paymentStatusLabel(s);
      showOk(context, 'Status updated to $label');
      await _load();
    } catch (err) { if (!mounted) return; showErr(context, 'Failed to update: $err'); }
  }

  Future<void> _confirmDeletePayment(PaymentEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Payment'),
        content: Text('Delete ${paymentTypeLabel(e.type)} of ${fmt0(e.amount)}?'),
        actions: [
          TextButton(onPressed: ()=>Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: ()=>Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) { return; }
    try {
      final removed = await PaymentStore.deleteById(e.id);
      if (!removed) {
        if (!mounted) return;
        showErr(context, 'Entry not found');
        return;
      }
      await syncInvoicesPaidFromPayments();
      try { await rebuildMonthlyPaymentsExcels(parseInvoiceDate(e.date)); } catch (_) {}
      try { await refreshReportsForInvoices({e.invoiceNo}.toSet()); } catch (_) {}
      if (!mounted) return;
      showOk(context, 'Payment deleted');
      await _load();
    } catch (err) { if (!mounted) return; showErr(context, 'Failed to delete: $err'); }
  }

  // Compute threshold days from user inputs
  int get _filterDays {
    final n = int.tryParse(_filterQtyCtrl.text.trim()) ?? 1;
    final qty = n <= 0 ? 1 : n;
    int perUnit;
    if (_filterUnit == TimeUnit.days) {
      perUnit = 1;
    } else if (_filterUnit == TimeUnit.weeks) {
      perUnit = 7;
    } else {
      perUnit = 30;
    }
    return qty * perUnit;
  }
  bool _isNotPaidSinceDays(Invoice inv, int days) {
    final remaining = (inv.balance - inv.paid).clamp(0.0, double.infinity);
    if (remaining <= 0) return false; // fully cleared
    final entries = _paymentsByInvoice[inv.sNo] ?? const <PaymentEntry>[];
    DateTime? lastCleared;
    for (final e in entries) {
      if (e.status == PaymentStatus.cleared) {
        try { final d = parseInvoiceDate(e.date); if (lastCleared == null || d.isAfter(lastCleared)) lastCleared = d; } catch (_) {}
      }
    }
    final baseline = lastCleared ?? parseInvoiceDate(inv.date);
    final now = DateTime.now();
    final diffDays = now.difference(DateTime(baseline.year, baseline.month, baseline.day)).inDays;
    return diffDays >= days;
  }
}

class _AddPaymentFormState {
  PaymentType type = PaymentType.cash;
  PaymentStatus status = PaymentStatus.cleared;
  final TextEditingController amount = TextEditingController();
  final TextEditingController chequeNo = TextEditingController();
  final TextEditingController bank = TextEditingController();
  final TextEditingController txnId = TextEditingController();
  String bankMode = 'Deposit';
  void clear(){ amount.clear(); chequeNo.clear(); bank.clear(); txnId.clear(); bankMode = 'Deposit'; type = PaymentType.cash; status = PaymentStatus.cleared; }
  void dispose(){ amount.dispose(); chequeNo.dispose(); bank.dispose(); txnId.dispose(); }
}
