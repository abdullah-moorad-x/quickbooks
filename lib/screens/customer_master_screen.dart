import 'dart:io';
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
import '../widgets/app_panels.dart';
import '../widgets/customer_summary_card.dart';
import 'package:open_filex/open_filex.dart';
import 'package:intl/intl.dart';

class CustomerMasterScreen extends StatefulWidget {
  const CustomerMasterScreen({super.key});
  @override
  State<CustomerMasterScreen> createState() => _CustomerMasterScreenState();
}

class _CustomerMasterScreenState extends State<CustomerMasterScreen>
    with AutomaticKeepAliveClientMixin {
  List<Customer> _customers = [];
  final _q = TextEditingController();
  List<Invoice> _allInvoices = [];
  SortMode _sortCustomers = SortMode.mostSales;
  Map<String, DateTime> _customerCreatedAt = {};
  final FocusNode _sortFocusCustomers =
      FocusNode(skipTraversal: true, canRequestFocus: false);
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
    AppBus.dataTick.addListener(_load);
  }

  @override
  void dispose() {
    _q.dispose();
    _sortFocusCustomers.dispose();
    AppBus.dataTick.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    final list = await CustomerStore.loadAll();
    final invs = await Store.loadAll();
    list.sort((a, b) => a.id.toLowerCase().compareTo(b.id.toLowerCase()));
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
    setState(() {
      _customers = list;
      _allInvoices = invs;
      _customerCreatedAt = createdAt;
      _customerPaymentsCache = null;
    });
  }

  String _keyOf(Customer c) => (c.id.isNotEmpty ? c.id : c.name).trim();
  double _sumSalesForKey(String key) {
    double s = 0;
    for (final inv in _allInvoices) {
      final k =
          (inv.customerId.isNotEmpty ? inv.customerId : inv.customer).trim();
      if (k.toLowerCase() == key.toLowerCase()) {
        s += inv.total;
      }
    }
    return s;
  }

  double _sumPaidForKey(String key) {
    double s = 0;
    for (final inv in _allInvoices) {
      final k =
          (inv.customerId.isNotEmpty ? inv.customerId : inv.customer).trim();
      if (k.toLowerCase() == key.toLowerCase()) {
        s += inv.paid;
      }
    }
    return s;
  }

  double _sumRemainForKey(String key) {
    double s = 0;
    for (final inv in _allInvoices) {
      final k =
          (inv.customerId.isNotEmpty ? inv.customerId : inv.customer).trim();
      if (k.toLowerCase() == key.toLowerCase()) {
        s += inv.remaining;
      }
    }
    return s;
  }

  Widget _customerActionButton({
    required String tooltip,
    required Widget icon,
    required VoidCallback onPressed,
    Color borderColor = const Color(0xFFE1E7EF),
    Color backgroundColor = Colors.white,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onPressed,
        child: Container(
          width: 40,
          height: 40,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor),
          ),
          child: icon,
        ),
      ),
    );
  }

  List<_AddressBagSummary> _addressBagSummaries({String? customerKey}) {
    final map = <String, _AddressBagSummary>{};
    final filterKey = customerKey?.trim().toLowerCase();
    for (final inv in _allInvoices) {
      if (filterKey != null && filterKey.isNotEmpty) {
        final invKey =
            (inv.customerId.isNotEmpty ? inv.customerId : inv.customer)
                .trim()
                .toLowerCase();
        if (invKey != filterKey) continue;
      }
      final addr = inv.address.trim();
      if (addr.isEmpty) continue;
      final bags =
          inv.lines.fold<int>(0, (s, l) => s + (l.qty > 0 ? l.qty : 0));
      final key = addr.toLowerCase();
      final prev = map[key];
      if (prev == null) {
        map[key] = _AddressBagSummary(
          address: addr,
          bags: bags,
          amount: inv.total,
          invoices: 1,
        );
      } else {
        map[key] = _AddressBagSummary(
          address: prev.address,
          bags: prev.bags + bags,
          amount: prev.amount + inv.total,
          invoices: prev.invoices + 1,
        );
      }
    }
    final out = map.values.toList()..sort((a, b) => b.bags.compareTo(a.bags));
    return out;
  }

  List<_AddressOrderDetail> _addressOrderDetails(String address,
      {String? customerKey}) {
    final out = <_AddressOrderDetail>[];
    final addrKey = address.trim().toLowerCase();
    final filterKey = customerKey?.trim().toLowerCase();
    for (final inv in _allInvoices) {
      if (filterKey != null && filterKey.isNotEmpty) {
        final invKey =
            (inv.customerId.isNotEmpty ? inv.customerId : inv.customer)
                .trim()
                .toLowerCase();
        if (invKey != filterKey) continue;
      }
      if (inv.address.trim().toLowerCase() != addrKey) continue;
      final bags =
          inv.lines.fold<int>(0, (s, l) => s + (l.qty > 0 ? l.qty : 0));
      DateTime d;
      try {
        d = parseInvoiceDate(inv.date);
      } catch (_) {
        d = DateTime.now();
      }
      out.add(_AddressOrderDetail(
        date: d,
        invoiceNo: inv.sNo,
        customerName: inv.customer,
        bags: bags,
        amount: inv.total,
      ));
    }
    out.sort((a, b) {
      final d = b.date.compareTo(a.date);
      if (d != 0) return d;
      return b.invoiceNo.compareTo(a.invoiceNo);
    });
    return out;
  }

  Future<void> _showAddressDetailsDialog(String address,
      {String? customerKey}) async {
    final details = _addressOrderDetails(address, customerKey: customerKey);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Orders for $address'),
        content: SizedBox(
          width: 620,
          child: details.isEmpty
              ? const Text('No orders found for this address.')
              : SizedBox(
                  height: 440,
                  child: ListView.separated(
                    itemCount: details.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final d = details[i];
                      return ListTile(
                        dense: true,
                        title: Text(
                            '${dfDay.format(d.date)}  |  #${d.invoiceNo}  |  ${d.customerName}'),
                        subtitle:
                            Text('Amount: Rs ${d.amount.toStringAsFixed(0)}'),
                        trailing: Text(
                          '${d.bags} bags',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      );
                    },
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddressBagsDialog({Customer? customer}) async {
    final key = customer == null ? null : _keyOf(customer);
    final rows = _addressBagSummaries(customerKey: key);
    if (!mounted) return;
    String q = '';
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final filtered = q.trim().isEmpty
              ? rows
              : rows
                  .where((r) =>
                      r.address.toLowerCase().contains(q.trim().toLowerCase()))
                  .toList();
          return AlertDialog(
            title: Text(
              customer == null
                  ? 'Address-wise bags'
                  : 'Address-wise bags - ${customer.name}',
            ),
            content: SizedBox(
              width: 560,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      labelText: 'Search address / plot',
                    ),
                    onChanged: (v) => setDialogState(() => q = v),
                  ),
                  const SizedBox(height: 10),
                  if (rows.isEmpty)
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('No address data available.'),
                    )
                  else
                    SizedBox(
                      height: 420,
                      child: filtered.isEmpty
                          ? const Center(child: Text('No matching address.'))
                          : ListView.separated(
                              itemCount: filtered.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1),
                              itemBuilder: (_, i) {
                                final r = filtered[i];
                                return ListTile(
                                  dense: true,
                                  title: Text(r.address),
                                  subtitle: Text(
                                      'Invoices: ${r.invoices} | Amount: Rs ${r.amount.toStringAsFixed(0)}'),
                                  trailing: Text(
                                    '${r.bags} bags',
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w700),
                                  ),
                                  onTap: () => _showAddressDetailsDialog(
                                    r.address,
                                    customerKey: key,
                                  ),
                                );
                              },
                            ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
            ],
          );
        },
      ),
    );
  }

  double _sumOpeningForKey(String key) {
    double opening = 0.0;
    if (_customerPaymentsCache != null) {
      for (final p in _customerPayments) {
        final pKey = (p.customerId.isNotEmpty ? p.customerId : p.customer)
            .trim()
            .toLowerCase();
        if (pKey != key.toLowerCase()) continue;
        if ((p.note ?? '').toLowerCase().contains('opening balance')) {
          // Opening balance stored as negative payment (customer owes -> negative payment).
          opening += p.effectiveAmount;
        }
      }
    }
    return opening;
  }

  DateTime _latestDateForKey(String key) {
    final k = key.toLowerCase();
    final fromFile = _customerCreatedAt[k];
    if (fromFile != null) return fromFile;
    DateTime latest = DateTime.fromMillisecondsSinceEpoch(0);
    for (final inv in _allInvoices) {
      final invKey =
          (inv.customerId.isNotEmpty ? inv.customerId : inv.customer).trim();
      if (invKey.toLowerCase() == k) {
        final d = parseInvoiceDate(inv.date);
        if (d.isAfter(latest)) latest = d;
      }
    }
    return latest;
  }

  Future<void> _addDialog() async {
    final idCtrl =
        TextEditingController(text: await CustomerStore.nextCustomerId());
    final nameCtrl = TextEditingController();
    final displayNameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final openingCtrl = TextEditingController(text: '0');
    DateTime openingDate = DateTime.now();
    if (!mounted) return;
    // ignore: use_build_context_synchronously
    final ok = await showDialog<bool>(
        context: context,
        builder: (_) {
          return StatefulBuilder(builder: (ctx, setDialogState) {
            return AlertDialog(
              title: const Text('Add Customer'),
              content: SizedBox(
                  width: 420,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: idCtrl,
                        enabled: false,
                        decoration:
                            const InputDecoration(labelText: 'Customer ID')),
                    const SizedBox(height: 8),
                    TextField(
                        controller: nameCtrl,
                        decoration: const InputDecoration(labelText: 'Name')),
                    const SizedBox(height: 8),
                    TextField(
                        controller: displayNameCtrl,
                        decoration: const InputDecoration(
                            labelText:
                                'Customer-facing name (invoice/ledger)')),
                    const SizedBox(height: 8),
                    TextField(
                        controller: phoneCtrl,
                        decoration: const InputDecoration(
                            labelText: 'Phone (optional)')),
                    const SizedBox(height: 8),
                    TextField(
                      controller: openingCtrl,
                      decoration: const InputDecoration(
                          labelText:
                              'Opening Balance (positive = customer owes, negative = credit)'),
                      keyboardType: TextInputType.number,
                    ),
                    const SizedBox(height: 8),
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
                        decoration: const InputDecoration(
                            labelText: 'Opening balance date'),
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
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Add'))
              ],
            );
          });
        });
    if (!mounted) return;
    if (ok == true) {
      final id = idCtrl.text.trim();
      final name = nameCtrl.text.trim();
      final displayName = (displayNameCtrl.text.trim().isEmpty
          ? name
          : displayNameCtrl.text.trim());
      final phone = phoneCtrl.text.trim();
      final opening = double.tryParse(openingCtrl.text.trim()) ?? 0.0;
      await CustomerStore.addCustomer(id, name, phone,
          displayName: displayName);
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
    if (!mounted) return;
    final openingPayment = _openingPaymentFor(c);
    double openingVal = 0.0;
    DateTime openingDate = DateTime.now();
    if (openingPayment != null) {
      openingVal = -(openingPayment.effectiveAmount);
      try {
        openingDate = parseInvoiceDate(openingPayment.date);
      } catch (_) {}
    }
    final nameCtrl = TextEditingController(text: c.name),
        displayNameCtrl = TextEditingController(text: c.displayName),
        phoneCtrl = TextEditingController(text: c.contact);
    final openingCtrl =
        TextEditingController(text: openingVal.toStringAsFixed(0));
    final ok = await showDialog<bool>(
        context: context,
        builder: (_) => StatefulBuilder(builder: (ctx, setDialogState) {
              return AlertDialog(
                title: const Text('Edit Customer'),
                content: SizedBox(
                    width: 420,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      TextField(
                          enabled: false,
                          decoration: InputDecoration(
                              labelText: 'Customer ID', hintText: c.id)),
                      const SizedBox(height: 8),
                      TextField(
                          controller: nameCtrl,
                          decoration: const InputDecoration(labelText: 'Name')),
                      const SizedBox(height: 8),
                      TextField(
                          controller: displayNameCtrl,
                          decoration: const InputDecoration(
                              labelText:
                                  'Customer-facing name (invoice/ledger)')),
                      const SizedBox(height: 8),
                      TextField(
                          controller: phoneCtrl,
                          decoration: const InputDecoration(
                              labelText: 'Phone (optional)')),
                      const SizedBox(height: 8),
                      TextField(
                        controller: openingCtrl,
                        decoration: const InputDecoration(
                            labelText:
                                'Opening Balance (positive = customer owes, negative = credit)'),
                        keyboardType: TextInputType.number,
                      ),
                      const SizedBox(height: 8),
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
                          decoration: const InputDecoration(
                              labelText: 'Opening balance date'),
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
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Save'))
                ],
              );
            }));
    if (!mounted) return;
    if (ok == true) {
      final updatedName = nameCtrl.text.trim();
      final updatedDisplay = displayNameCtrl.text.trim().isEmpty
          ? updatedName
          : displayNameCtrl.text.trim();
      final updatedPhone = phoneCtrl.text.trim();
      final opening = double.tryParse(openingCtrl.text.trim()) ?? 0.0;
      final okEdit = await CustomerStore.updateNamePhone(
        c.id,
        updatedName,
        updatedPhone,
        displayName: updatedDisplay,
      );
      if (okEdit) {
        await _saveOpeningBalance(
            Customer(
                id: c.id,
                name: updatedName,
                displayName: updatedDisplay,
                contact: updatedPhone,
                active: c.active),
            opening,
            openingDate);
        await _load();
      }
    }
  }

  Future<void> _deleteCustomer(Customer c) async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
              title: const Text('Deactivate Customer?'),
              content: Text(
                  'Remove "${c.id} - ${c.name}" from master. This does NOT delete old invoices.'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Deactivate'))
              ],
            ));
    if (!mounted) return;
    if (ok == true) {
      await CustomerStore.deleteById(c.id);
      await _load();
    }
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

  List<String> _locationsOfInvoice(Invoice inv) {
    final addr = inv.address.trim();
    if (addr.isEmpty) return const <String>[];
    return <String>[addr];
  }

  List<Map<String, dynamic>> _salesRows(
      Customer c, DateTime from, DateTime to, String? selectedAddr) {
    final nf = NumberFormat.decimalPattern();
    final key = _keyOf(c).toLowerCase();
    final rows = <Map<String, dynamic>>[];
    for (final inv in _allInvoices) {
      final invKey = (inv.customerId.isNotEmpty ? inv.customerId : inv.customer)
          .trim()
          .toLowerCase();
      if (invKey != key) continue;
      final d = parseInvoiceDate(inv.date);
      if (d.isBefore(from) || d.isAfter(to)) continue;
      final dStr = DateFormat('dd/MM/yyyy').format(d);
      final locations = _locationsOfInvoice(inv);
      if (selectedAddr != null &&
          selectedAddr.isNotEmpty &&
          !locations.contains(selectedAddr)) {
        continue;
      }
      final addr = locations.join(', ');
      final addrPart = addr.isNotEmpty ? ' | $addr' : '';
      for (final line in inv.lines) {
        if (line.qty <= 0) continue;
        final brand = line.brand.trim();
        final type = line.typeLabel.trim();
        final amt = line.amount;
        final brandPart = brand.isNotEmpty ? brand : type;
        final typePart = type.isNotEmpty ? type : 'Sale';
        rows.add({
          'date': d,
          'text':
              '$dStr â€“ ${line.qty} bags $brandPart â†’ $typePart â†’ Rs ${nf.format(amt)}$addrPart'
        });
      }
    }
    return rows;
  }

  List<PaymentEntry> get _customerPayments =>
      _customerPaymentsCache ?? const <PaymentEntry>[];
  List<PaymentEntry>? _customerPaymentsCache;

  Future<void> _ensurePaymentsLoaded() async {
    _customerPaymentsCache ??= await PaymentStore.loadAll();
  }

  PaymentEntry? _openingPaymentFor(Customer c) {
    final key = _keyOf(c).toLowerCase();
    for (final p in _customerPayments) {
      final pKey = (p.customerId.isNotEmpty ? p.customerId : p.customer)
          .trim()
          .toLowerCase();
      if (pKey == key &&
          (p.note ?? '').toLowerCase().contains('opening balance')) {
        return p;
      }
    }
    return null;
  }

  Future<void> _saveOpeningBalance(
      Customer c, double opening, DateTime date) async {
    final pays = await PaymentStore.loadAll();
    final key = _keyOf(c).toLowerCase();
    int idx = -1;
    PaymentEntry? existing;
    for (var i = 0; i < pays.length; i++) {
      final p = pays[i];
      final pKey = (p.customerId.isNotEmpty ? p.customerId : p.customer)
          .trim()
          .toLowerCase();
      if (pKey == key &&
          (p.note ?? '').toLowerCase().contains('opening balance')) {
        idx = i;
        existing = p;
        break;
      }
    }
    DateTime? oldDate;
    if (existing != null) {
      try {
        oldDate = parseInvoiceDate(existing.date);
      } catch (_) {}
    }

    if (opening.abs() < 0.0001) {
      if (idx >= 0) {
        pays.removeAt(idx);
        await PaymentStore.saveAll(pays);
        await syncInvoicesPaidFromPayments();
        if (oldDate != null) {
          await rebuildMonthlyPaymentsExcels(
              DateTime(oldDate.year, oldDate.month));
          try {
            await exportMonthlyLedger(DateTime(oldDate.year, oldDate.month));
          } catch (_) {}
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
    if (oldDate != null &&
        (oldDate.year != date.year || oldDate.month != date.month)) {
      months.add(DateTime(oldDate.year, oldDate.month));
    }
    for (final m in months) {
      await rebuildMonthlyPaymentsExcels(m);
      try {
        await exportMonthlyLedger(m);
      } catch (_) {}
    }
    try {
      await refreshReportsForInvoices(<int>{});
    } catch (_) {}
    _customerPaymentsCache = null;
  }

  Future<void> _pickAndSendLedgerImage(Customer c) async {
    final phone = c.contact.trim();
    DateTime from = DateTime.now().subtract(const Duration(days: 30));
    DateTime to = DateTime.now();
    final addrOptions = _allInvoices
        .where((inv) =>
            (inv.customerId.isNotEmpty ? inv.customerId : inv.customer)
                .trim()
                .toLowerCase() ==
            _keyOf(c).toLowerCase())
        .expand((inv) => _locationsOfInvoice(inv))
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
                      initialValue: selectedAddr,
                      items: [
                        const DropdownMenuItem<String?>(
                            value: null, child: Text('All addresses')),
                        ...addrOptions.map((a) => DropdownMenuItem<String?>(
                            value: a, child: Text(a))),
                      ],
                      onChanged: (v) => setStateDialog(() => selectedAddr = v),
                      decoration: const InputDecoration(
                          labelText: 'Filter by address / plot'),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel')),
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
        showErr(context,
            'No sales found from ${dfDay.format(from)} to ${dfDay.format(to)}.');
        return;
      }
      rows.sort(
          (a, b) => (a['date'] as DateTime).compareTo(b['date'] as DateTime));
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
      try {
        await OpenFilex.open(url);
      } catch (_) {
        if (Platform.isWindows) {
          try {
            await Process.run('cmd', ['/c', 'start', url]);
          } catch (_) {}
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
        .where((inv) =>
            (inv.customerId.isNotEmpty ? inv.customerId : inv.customer)
                .trim()
                .toLowerCase() ==
            _keyOf(c).toLowerCase())
        .expand((inv) => _locationsOfInvoice(inv))
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
                      initialValue: selectedAddr,
                      items: [
                        const DropdownMenuItem<String?>(
                            value: null, child: Text('All addresses')),
                        ...addrOptions.map((a) => DropdownMenuItem<String?>(
                            value: a, child: Text(a))),
                      ],
                      onChanged: (v) => setStateDialog(() => selectedAddr = v),
                      decoration: const InputDecoration(
                          labelText: 'Filter by address / plot'),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel')),
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
        showErr(context,
            'No sales found from ${dfDay.format(from)} to ${dfDay.format(to)}.');
        return;
      }
      rows.sort(
          (a, b) => (a['date'] as DateTime).compareTo(b['date'] as DateTime));
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
    final q = _q.text.trim().toLowerCase();
    var filtered = q.isEmpty
        ? _customers
        : _customers
            .where((c) => customerSummarySearchText(c).contains(q))
            .toList();

    // Apply sorting based on selected mode
    int cmpNumDesc(num a, num b) => b.compareTo(a);
    int cmpNumAsc(num a, num b) => a.compareTo(b);
    switch (_sortCustomers) {
      case SortMode.mostUnpaid:
        filtered.sort((a, b) => cmpNumDesc(
            _sumRemainForKey(_keyOf(a)), _sumRemainForKey(_keyOf(b))));
        break;
      case SortMode.mostPaid:
        filtered.sort((a, b) =>
            cmpNumDesc(_sumPaidForKey(_keyOf(a)), _sumPaidForKey(_keyOf(b))));
        break;
      case SortMode.mostSales:
        filtered.sort((a, b) =>
            cmpNumDesc(_sumSalesForKey(_keyOf(a)), _sumSalesForKey(_keyOf(b))));
        break;
      case SortMode.leastSales:
        filtered.sort((a, b) =>
            cmpNumAsc(_sumSalesForKey(_keyOf(a)), _sumSalesForKey(_keyOf(b))));
        break;
      case SortMode.newestFirst:
        filtered.sort((a, b) => _latestDateForKey(_keyOf(b))
            .compareTo(_latestDateForKey(_keyOf(a))));
        break;
      case SortMode.oldestFirst:
        filtered.sort((a, b) => _latestDateForKey(_keyOf(a))
            .compareTo(_latestDateForKey(_keyOf(b))));
        break;
    }
    String sortLabel(SortMode mode) {
      switch (mode) {
        case SortMode.mostUnpaid:
          return 'Most Unpaid';
        case SortMode.mostPaid:
          return 'Most Paid';
        case SortMode.mostSales:
          return 'Most Sales';
        case SortMode.leastSales:
          return 'Least Sales';
        case SortMode.newestFirst:
          return 'Newest First';
        case SortMode.oldestFirst:
          return 'Oldest First';
      }
    }

    return Column(children: [
      LayoutBuilder(
        builder: (context, constraints) {
          final isNarrow = constraints.maxWidth < 980;
          final searchField = TextField(
            controller: _q,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search ID/Name/Phone',
            ),
            onChanged: (_) => setState(() {}),
          );
          final sortControl = Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFFDCE5EE))),
            ),
            child: DropdownButton<SortMode>(
              focusNode: _sortFocusCustomers,
              value: _sortCustomers,
              underline: const SizedBox.shrink(),
              onChanged: (v) {
                if (v != null) {
                  setState(() => _sortCustomers = v);
                  FocusScope.of(context).unfocus();
                  _sortFocusCustomers.unfocus();
                  FocusManager.instance.primaryFocus?.unfocus();
                }
              },
              items: const [
                DropdownMenuItem(
                    value: SortMode.mostUnpaid, child: Text('Most Unpaid')),
                DropdownMenuItem(
                    value: SortMode.mostPaid, child: Text('Most Paid')),
                DropdownMenuItem(
                    value: SortMode.mostSales, child: Text('Most Sales')),
                DropdownMenuItem(
                    value: SortMode.leastSales, child: Text('Least Sales')),
                DropdownMenuItem(
                    value: SortMode.newestFirst, child: Text('Newest First')),
                DropdownMenuItem(
                    value: SortMode.oldestFirst, child: Text('Oldest First')),
              ],
            ),
          );
          final addressButton = OutlinedButton.icon(
            style: appGreenOutlineButtonStyle(context),
            onPressed: () => _showAddressBagsDialog(),
            icon: const Icon(Icons.pin_drop_outlined),
            label: const Text('Address Bags'),
          );
          final addButton = FilledButton.icon(
            style: appGreenButtonStyle(context),
            onPressed: _addDialog,
            icon: const Icon(Icons.add),
            label: const Text('Add Customer'),
          );

          if (!isNarrow) {
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(width: 440, child: searchField),
                sortControl,
                addressButton,
                addButton,
              ],
            );
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              searchField,
              const SizedBox(height: 12),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  sortControl,
                  addressButton,
                  SizedBox(width: 170, child: addButton),
                ],
              ),
            ],
          );
        },
      ),
      const SizedBox(height: 12),
      Expanded(
          child: ListView.separated(
        physics: const ClampingScrollPhysics(),
        padding: EdgeInsets.zero,
        itemCount: filtered.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, i) {
          final c = filtered[i];
          final key = _keyOf(c);
          final opening = _sumOpeningForKey(key);
          final sales = _sumSalesForKey(key);
          final paid = _sumPaidForKey(key);
          final remaining = (opening + sales - paid);
          final totalSalesWithOpening = opening + sales;
          return CustomerSummaryCard(
            customer: c,
            sortLabel: sortLabel(_sortCustomers),
            total: totalSalesWithOpening,
            paid: paid,
            remaining: remaining,
            actions: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _customerActionButton(
                  tooltip: 'Open',
                  icon: const Icon(Icons.open_in_new,
                      size: 19, color: Color(0xFF273247)),
                  onPressed: () async {
                    final file = await customerWorkbookFileFromKey(c.id);
                    final exists = await file.exists();
                    if (!mounted) return;
                    if (exists) {
                      await OpenFilex.open(file.path);
                    } else {
                      showErr(context, 'Customer Excel not found.');
                    }
                  },
                ),
                _customerActionButton(
                  tooltip: 'Ledger',
                  icon: const Icon(Icons.account_balance_wallet_outlined,
                      size: 19, color: Color(0xFF273247)),
                  onPressed: () async {
                    final file = await exportCustomerLedger(c.id);
                    if (!mounted) return;
                    await OpenFilex.open(file.path);
                  },
                ),
                if (c.contact.trim().isNotEmpty)
                  _customerActionButton(
                    tooltip: 'WhatsApp',
                    icon: const FaIcon(FontAwesomeIcons.whatsapp,
                        size: 18, color: Color(0xFF25D366)),
                    onPressed: () => _pickAndSendLedgerImage(c),
                  ),
                _customerActionButton(
                  tooltip: 'Copy Sales',
                  icon: const Icon(Icons.copy,
                      size: 19, color: Color(0xFF273247)),
                  onPressed: () => _pickAndCopySales(c),
                ),
                _customerActionButton(
                  tooltip: 'Address Bags',
                  icon: const Icon(Icons.pin_drop_outlined,
                      size: 19, color: Color(0xFF273247)),
                  onPressed: () => _showAddressBagsDialog(customer: c),
                ),
                _customerActionButton(
                  tooltip: 'Edit',
                  icon: const Icon(Icons.edit,
                      size: 19, color: Color(0xFF273247)),
                  onPressed: () => _editDialog(c),
                ),
                _customerActionButton(
                  tooltip: c.active ? 'Deactivate' : 'Activate',
                  icon: Icon(
                    c.active
                        ? Icons.delete_outline
                        : Icons.check_circle_outline,
                    size: 19,
                    color: c.active
                        ? const Color(0xFFB42318)
                        : const Color(0xFF00838F),
                  ),
                  borderColor: c.active
                      ? const Color(0xFFF0C7C2)
                      : const Color(0xFFB9DBD7),
                  onPressed: () => _deleteCustomer(c),
                ),
              ],
            ),
          );
        },
      )),
      const SizedBox(height: 8),
      const Text(
          'Note: Editing master updates customer name in invoices, payments, and search suggestions.'),
    ]);
  }
}

class _AddressBagSummary {
  final String address;
  final int bags;
  final double amount;
  final int invoices;

  const _AddressBagSummary({
    required this.address,
    required this.bags,
    required this.amount,
    required this.invoices,
  });
}

class _AddressOrderDetail {
  final DateTime date;
  final int invoiceNo;
  final String customerName;
  final int bags;
  final double amount;

  const _AddressOrderDetail({
    required this.date,
    required this.invoiceNo,
    required this.customerName,
    required this.bags,
    required this.amount,
  });
}
