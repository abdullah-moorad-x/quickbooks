import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:open_filex/open_filex.dart';

import '../core/constants.dart';
import '../core/app_bus.dart';
import '../models/customer.dart';
import '../models/invoice.dart';
import '../models/payment.dart';
import '../services/storage.dart';
import '../services/excel_service.dart';
import '../services/pdf_builder.dart';
import '../services/paths.dart';
import '../utils/date.dart';
import '../utils/format.dart';
import '../utils/snackbar.dart';
import '../utils/file_io.dart';

/* ------------------------------- INVOICE CREATE SCREEN ------------------------------ */
class InvoiceScreen extends StatefulWidget {
  final Invoice? initialInvoice;
  final bool editing;
  const InvoiceScreen({super.key, this.initialInvoice, this.editing = false});
  @override
  State<InvoiceScreen> createState() => _InvoiceScreenState();
}

class _InvoiceScreenState extends State<InvoiceScreen>
    with AutomaticKeepAliveClientMixin {
  Invoice? _originalInvoice;
  bool get _isEditing => widget.editing && widget.initialInvoice != null;
  final _customerId = TextEditingController();
  final _customer = TextEditingController();
  final _contact = TextEditingController();
  final _address = TextEditingController();
  final _date = TextEditingController(text: formatInvoiceDate(DateTime.now()));
  final _cartageCtrl = TextEditingController(text: '0');

  int _sNo = 1;
  String _site = kShipmentSites.first;

  List<Customer> _customers = [];
  List<String> _ids = [], _names = [], _phones = [], _unified = [];
  bool _customerLocked = false;

  List<String> _brandSuggestions = [];
  List<String> _addressSuggestions = [];
  List<String> _noteSuggestions = [];
  // Customer-id/name -> item type -> list of recent rates (most recent first, unique)
  Map<String, Map<String, List<String>>> _rateSuggestionsById = {};
  Map<String, Map<String, List<String>>> _rateSuggestionsByName = {};

  final _lines = <ItemLine>[
    ItemLine('OPC'),
    ItemLine('SRC'),
    ItemLine('WHITE CEMENT'),
    ItemLine('BOUND'),
    ItemLine('BLOCK'),
  ];
  bool _isWalkIn = false;
  PaymentType _walkInType = PaymentType.cash;
  String _walkInBankMode = 'Deposit';
  final _walkInNote = TextEditingController();
  final FocusNode _walkInNoteFocus = FocusNode();
  final _walkInBank = TextEditingController();
  final _walkInCheque = TextEditingController();
  final _walkInTxn = TextEditingController();

  void _resetFormToDefaults({int? nextSerial}) {
    for (final l in _lines) {
      l.dispose();
    }
    _lines
      ..clear()
      ..addAll(kItemTypes.map((t) => ItemLine(t)));
    _customerId.clear();
    _customer.clear();
    _contact.clear();
    _address.clear();
    _customerLocked = false;
    _date.text = formatInvoiceDate(DateTime.now());
    _cartageCtrl.text = '0';
    _site = kShipmentSites.first;
    _isWalkIn = false;
    _clearWalkInPaymentFields();
    if (nextSerial != null) _sNo = nextSerial;
  }

  void _applyInvoice(Invoice inv) {
    for (final l in _lines) {
      l.dispose();
    }
    _lines
      ..clear()
      ..addAll(inv.lines
          .map((l) => ItemLine(l.typeLabel, brand: l.brand, qty: l.qty, rate: l.rate)));
    _sNo = inv.sNo;
    _date.text = inv.date;
    _customerId.text = inv.customerId;
    _customer.text = inv.customer;
    _contact.text = inv.contact;
    _address.text = inv.address;
    _site = inv.site;
    _cartageCtrl.text = inv.cartage == 0 ? '0' : inv.cartage.toStringAsFixed(0);
    _isWalkIn = inv.walkIn;
    _walkInType = inv.walkInPaymentType ?? PaymentType.cash;
    _walkInBankMode = inv.walkInBankMode ?? 'Deposit';
    _walkInNote.text = inv.walkInPaymentNote ?? '';
    _walkInBank.text = inv.walkInBank ?? '';
    _walkInCheque.text = inv.walkInChequeNo ?? '';
    _walkInTxn.text = inv.walkInTxnId ?? '';
    _customerLocked = false;
  }

  Future<void> _pickDate() async {
    DateTime initial;
    try {
      initial = parseInvoiceDate(_date.text.trim());
    } catch (_) {
      initial = DateTime.now();
    }
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _date.text = formatInvoiceDate(picked));
  }

  @override
  void initState() {
    super.initState();
    if (_isEditing) {
      _originalInvoice = widget.initialInvoice;
      _applyInvoice(_originalInvoice!);
    } else {
      Store.nextSerial().then((n) => setState(() => _sNo = n));
    }
    _loadSuggestions();
    AppBus.dataTick.addListener(_onDataTick);
  }

  @override
  void dispose() {
    AppBus.dataTick.removeListener(_onDataTick);
    _customerId.dispose();
    _customer.dispose();
    _contact.dispose();
    _address.dispose();
    _date.dispose();
    _cartageCtrl.dispose();
    _walkInNote.dispose();
    _walkInNoteFocus.dispose();
    _walkInBank.dispose();
    _walkInCheque.dispose();
    _walkInTxn.dispose();
    for (final l in _lines) {
      l.dispose();
    }
    super.dispose();
  }

  void _onDataTick() {
    if (!mounted) return;
    _loadSuggestions();
    if (_isEditing) return;
    Store.nextSerial().then((n) {
      if (mounted) setState(() => _sNo = n);
    });
  }

  Future<void> _loadSuggestions() async {
    _customers = await CustomerStore.loadActive();
    _ids = _customers
        .map((c) => c.id)
        .where((s) => s.trim().isNotEmpty)
        .toSet()
        .toList()
        .cast<String>();
    _names = _customers
        .map((c) => c.name)
        .where((s) => s.trim().isNotEmpty)
        .toSet()
        .toList()
        .cast<String>();
    _phones = _customers
        .map((c) => c.contact)
        .where((s) => s.trim().isNotEmpty)
        .toSet()
        .toList()
        .cast<String>();
    _unified = _customers
        .map((c) {
          final parts = <String>[];
          if (c.id.trim().isNotEmpty) parts.add(c.id);
          if (c.name.trim().isNotEmpty) parts.add(c.name);
          if (c.contact.trim().isNotEmpty) parts.add(c.contact);
          return parts.join(' - ');
        })
        .toList()
        .cast<String>();

    final invs = await Store.loadAll();
    _brandSuggestions = invs
        .expand((inv) => inv.lines.map((l) => l.brand.trim()))
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList()
        .cast<String>();
    _addressSuggestions = invs
        .map((inv) => inv.address.trim())
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList()
        .cast<String>();
    final payments = await PaymentStore.loadAll();
    final noteSeen = <String>{};
    _noteSuggestions = [];
    for (final p in payments.reversed) {
      final note = (p.note ?? '').trim();
      if (note.isEmpty) continue;
      final key = note.toLowerCase();
      if (noteSeen.add(key)) {
        _noteSuggestions.add(note);
      }
    }
    final invsSorted = List<Invoice>.from(invs)
      ..sort((a, b) => parseInvoiceDate(b.date).compareTo(parseInvoiceDate(a.date)));
    final rateById = <String, Map<String, List<String>>>{};
    final rateByName = <String, Map<String, List<String>>>{};
    for (final inv in invsSorted) {
      final idKey = inv.customerId.trim().toLowerCase();
      final nameKey = inv.customer.trim().toLowerCase();
      for (final line in inv.lines) {
        if (line.rate <= 0) continue;
        final type = line.typeLabel;
        final rateStr = line.rate.toStringAsFixed(0);
        if (idKey.isNotEmpty) {
          final custMap = rateById.putIfAbsent(idKey, () => <String, List<String>>{});
          final list = custMap.putIfAbsent(type, () => <String>[]);
          if (!list.contains(rateStr)) list.add(rateStr);
        }
        if (nameKey.isNotEmpty) {
          final custMap = rateByName.putIfAbsent(nameKey, () => <String, List<String>>{});
          final list = custMap.putIfAbsent(type, () => <String>[]);
          if (!list.contains(rateStr)) list.add(rateStr);
        }
      }
    }
    _rateSuggestionsById = rateById;
    _rateSuggestionsByName = rateByName;
    if (mounted) setState(() {});
  }

  void _lockCustomer(Customer c) {
    setState(() {
      _customerId.text = c.id;
      _customer.text = c.name;
      _contact.text = c.contact;
      _customerLocked = true;
    });
  }

  void _clearCustomer() {
    setState(() {
      _customerId.clear();
      _customer.clear();
      _contact.clear();
      _customerLocked = false;
    });
    FocusScope.of(context).unfocus();
  }

  void _clearWalkInPaymentFields() {
    _walkInType = PaymentType.cash;
    _walkInBankMode = 'Deposit';
    _walkInNote.clear();
    _walkInBank.clear();
    _walkInCheque.clear();
    _walkInTxn.clear();
  }

  List<String> _rateOptionsFor(String typeLabel) {
    if (_isWalkIn) return const [];
    final idKey = _customerId.text.trim().toLowerCase();
    final nameKey = _customer.text.trim().toLowerCase();
    if (idKey.isNotEmpty) {
      final list = _rateSuggestionsById[idKey]?[typeLabel];
      if (list != null) return list;
    }
    if (nameKey.isNotEmpty) {
      final list = _rateSuggestionsByName[nameKey]?[typeLabel];
      if (list != null) return list;
    }
    return const [];
  }

  double get _total => _lines.fold(0.0, (s, it) => s + it.amount);
  double get _cartageVal => double.tryParse(_cartageCtrl.text) ?? 0;
  double get _balance => (_total + _cartageVal).clamp(0, double.infinity);

  Future<void> _persistInvoice(Invoice inv) async {
    final previous = _originalInvoice;
    final all = await Store.loadAll();
    final idx = all.indexWhere((x) => x.sNo == inv.sNo);
    if (idx >= 0) {
      all[idx] = inv;
    } else {
      all.add(inv);
    }
    await Store.saveAll(all);
    if (!inv.walkIn) {
      await CustomerStore.upsertFixed(Customer(
        id: inv.customerId,
        name: inv.customer,
        displayName: inv.customerDisplay ?? inv.customer,
        contact: inv.contact,
      ));
      await upsertCustomerWorkbook(inv);
    }

    DateTime? safeDate(String raw) {
      try {
        return parseInvoiceDate(raw);
      } catch (_) {
        return null;
      }
    }

    final dates = <DateTime>{};
    final currentDate = safeDate(inv.date);
    if (currentDate != null) dates.add(currentDate);
    final prevDate = previous == null ? null : safeDate(previous.date);
    if (prevDate != null) dates.add(prevDate);

    final months = <DateTime>{};
    for (final d in dates) {
      months.add(DateTime(d.year, d.month));
    }

    final customerKeys = <String>{};
    final keyNow = (inv.customerId.isNotEmpty ? inv.customerId : inv.customer).trim();
    if (keyNow.isNotEmpty) customerKeys.add(keyNow);
    if (previous != null) {
      final keyPrev = (previous.customerId.isNotEmpty ? previous.customerId : previous.customer).trim();
      if (keyPrev.isNotEmpty) customerKeys.add(keyPrev);
    }

    for (final d in dates) {
      await exportDailySalesExcel(d);
      try {
        await exportDailyLedger(d);
      } catch (_) {}
    }
    for (final m in months) {
      await exportMonthlySalesExcel(DateTime(m.year, m.month));
      try {
        await exportMonthlyLedger(DateTime(m.year, m.month));
      } catch (_) {}
    }
    for (final k in customerKeys) {
      try { await rebuildCustomerWorkbookForKey(k); } catch (_) {}
    }
    _originalInvoice = inv;
  }

  bool _validateInvoiceInputs() {
    final name = _customer.text.trim();
    if (name.isEmpty) {
      showErr(context, 'Customer name is required.');
      return false;
    }
    final hasCompleteItem = _lines.any((l) {
      final brandOk = l.brand.trim().isNotEmpty;
      final qtyOk = int.tryParse(l.qtyCtrl.text.trim()) != null &&
          int.parse(l.qtyCtrl.text.trim()) > 0;
      final rateOk = double.tryParse(l.rateCtrl.text.trim()) != null &&
          double.parse(l.rateCtrl.text.trim()) > 0;
      return brandOk && qtyOk && rateOk;
    });
    if (!hasCompleteItem) {
      showErr(context,
          'Add at least 1 item with Company, Quantity (>0) and Rate (>0).');
      return false;
    }
    return true;
  }

  Future<void> _saveInvoice() async {
    if (!_validateInvoiceInputs()) return;
    final snapshotLines = _lines
        .map((l) =>
            ItemLine(l.typeLabel, brand: l.brand, qty: l.qty, rate: l.rate))
        .toList();
    Customer? selected;
    if (!_isWalkIn && _customerId.text.trim().isEmpty) {
      final newId = await CustomerStore.nextCustomerId();
      _customerId.text = newId;
      await CustomerStore.addCustomer(
          newId, _customer.text.trim(), _contact.text.trim(), displayName: _customer.text.trim());
      _customerLocked = true;
    } else {
      selected = await CustomerStore.findById(_customerId.text.trim());
      selected ??= await CustomerStore.findByName(_customer.text.trim());
    }
    final displayName = selected?.displayName ?? _customer.text.trim();
    final inv = Invoice(
      sNo: _sNo,
      date: _date.text.trim(),
      customer: _customer.text.trim(),
      customerDisplay: displayName,
      customerId: _customerId.text.trim().isNotEmpty
          ? _customerId.text.trim()
          : _customer.text.trim(),
      contact: _contact.text.trim(),
      address: _address.text.trim(),
      site: _site,
      lines: snapshotLines,
      cartage: _cartageVal,
      paid: _isWalkIn ? _balance : 0,
      walkIn: _isWalkIn,
      walkInPaymentType: _isWalkIn ? _walkInType : null,
      walkInPaymentNote: _isWalkIn && _walkInNote.text.trim().isNotEmpty
          ? _walkInNote.text.trim()
          : null,
      walkInBank: _isWalkIn &&
              (_walkInType == PaymentType.cheque ||
                  _walkInType == PaymentType.bank) &&
              _walkInBank.text.trim().isNotEmpty
          ? _walkInBank.text.trim()
          : null,
      walkInChequeNo: _isWalkIn &&
              _walkInType == PaymentType.cheque &&
              _walkInCheque.text.trim().isNotEmpty
          ? _walkInCheque.text.trim()
          : null,
      walkInTxnId: _isWalkIn &&
              _walkInType == PaymentType.bank &&
              _walkInTxn.text.trim().isNotEmpty
          ? _walkInTxn.text.trim()
          : null,
      walkInBankMode:
          _isWalkIn && _walkInType == PaymentType.bank ? _walkInBankMode : null,
    );
    await _persistInvoice(inv);
    final pdfBytes = await PdfBuilder.build(inv);
    final invDir = await subdir('invoices');
    final pdfFile =
        File('${invDir.path}${Platform.pathSeparator}invoice_${inv.sNo}.pdf');
    final written = await safeWriteBytes(pdfFile, pdfBytes);
    await OpenFilex.open(written.path);
    if (!mounted) return;
    if (_isEditing) {
      showOk(context, 'Updated invoice #${inv.sNo}');
      Navigator.of(context).pop(inv);
      return;
    }
    showOk(context, 'Saved invoice #${inv.sNo}');
    final next = await Store.nextSerial();
    setState(() {
      _resetFormToDefaults(nextSerial: next);
    });
    await _loadSuggestions();
  }

  Future<void> _saveAndWhatsapp() async {
    try {
      if (!_validateInvoiceInputs()) return;
      if (_contact.text.trim().isEmpty) {
        showErr(context, 'Add a phone number to send via WhatsApp. You can still use "Save PDF" without a number.');
        return;
      }
      final snapshotLines = _lines
          .map((l) =>
              ItemLine(l.typeLabel, brand: l.brand, qty: l.qty, rate: l.rate))
          .toList();
      Customer? selected;
      if (!_isWalkIn && _customerId.text.trim().isEmpty) {
        final newId = await CustomerStore.nextCustomerId();
        _customerId.text = newId;
        await CustomerStore.addCustomer(
            newId, _customer.text.trim(), _contact.text.trim(), displayName: _customer.text.trim());
        _customerLocked = true;
      } else {
        selected = await CustomerStore.findById(_customerId.text.trim());
        selected ??= await CustomerStore.findByName(_customer.text.trim());
      }
      final displayName = selected?.displayName ?? _customer.text.trim();
      final inv = Invoice(
        sNo: _sNo,
        date: _date.text.trim(),
        customer: _customer.text.trim(),
        customerDisplay: displayName,
        customerId: _customerId.text.trim().isNotEmpty
            ? _customerId.text.trim()
            : _customer.text.trim(),
        contact: _contact.text.trim(),
        address: _address.text.trim(),
        site: _site,
        lines: snapshotLines,
        cartage: _cartageVal,
        paid: _isWalkIn ? _balance : 0,
        walkIn: _isWalkIn,
        walkInPaymentType: _isWalkIn ? _walkInType : null,
        walkInPaymentNote: _isWalkIn && _walkInNote.text.trim().isNotEmpty
            ? _walkInNote.text.trim()
            : null,
        walkInBank: _isWalkIn &&
                (_walkInType == PaymentType.cheque ||
                    _walkInType == PaymentType.bank) &&
                _walkInBank.text.trim().isNotEmpty
            ? _walkInBank.text.trim()
            : null,
        walkInChequeNo: _isWalkIn &&
                _walkInType == PaymentType.cheque &&
                _walkInCheque.text.trim().isNotEmpty
            ? _walkInCheque.text.trim()
            : null,
        walkInTxnId: _isWalkIn &&
                _walkInType == PaymentType.bank &&
                _walkInTxn.text.trim().isNotEmpty
            ? _walkInTxn.text.trim()
            : null,
      walkInBankMode:
          _isWalkIn && _walkInType == PaymentType.bank ? _walkInBankMode : null,
      );
      await _persistInvoice(inv);

      final pdfBytes = await PdfBuilder.build(inv);
      final invDir = await subdir('invoices');
      final pdfFile =
          File('${invDir.path}${Platform.pathSeparator}invoice_${inv.sNo}.pdf');
      await safeWriteBytes(pdfFile, pdfBytes);

      try {
        await OpenFilex.open(invDir.path);
      } catch (_) {
        if (Platform.isWindows) {
          try {
            await Process.run('explorer', [invDir.path]);
          } catch (_) {}
        }
      }

      var raw = _contact.text.trim();
      var digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
      if (digits.startsWith('0092')) {
        digits = digits.substring(2);
      } else if (digits.startsWith('0')) {
        digits = '92${digits.substring(1)}';
      } else if (!digits.startsWith('92')) {
        digits = '92$digits';
      }
      final msg =
          'Invoice #${inv.sNo}, Date ${inv.date}. Total Rs ${fmt0(inv.total)}, Cartage Rs ${fmt0(inv.cartage)}, Balance Rs ${fmt0(inv.balance)}. Thank you.';
      final url = 'https://wa.me/$digits?text=${Uri.encodeComponent(msg)}';

      if (Platform.isWindows) {
        try {
          final esc = pdfFile.path.replaceAll("'", "''");
          await Process.run('powershell',
              ['-NoProfile', '-Command', "Set-Clipboard -Path '$esc'"]);
        } catch (_) {}
      }
      try {
        await OpenFilex.open(url);
      } catch (_) {
        if (Platform.isWindows) {
          try {
            await Process.run('cmd', ['/c', 'start', url]);
          } catch (_) {}
        }
      }
      if (Platform.isWindows) {
        try {
          await Future.delayed(const Duration(seconds: 2));
          const ps =
              "\$wshell = New-Object -ComObject wscript.shell; Start-Sleep -Milliseconds 100; \$null = \$wshell.AppActivate('WhatsApp'); Start-Sleep -Milliseconds 200; \$wshell.SendKeys('^v')";
          await Process.run('powershell', ['-NoProfile', '-Command', ps]);
        } catch (_) {}
      }

      if (!mounted) return;
      if (_isEditing) {
        showOk(context, 'Updated invoice #${inv.sNo} and prepared WhatsApp.');
        Navigator.of(context).pop(inv);
        return;
      }
      showOk(context, 'Saved invoice #${inv.sNo} and prepared WhatsApp.');
      final next = await Store.nextSerial();
      setState(() {
        _resetFormToDefaults(nextSerial: next);
      });
      await _loadSuggestions();
    } catch (_) {
      if (!mounted) return;
      showErr(context, 'Could not save or open WhatsApp.');
    }
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      extendBodyBehindAppBar: false,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: _isEditing
          ? AppBar(
              titleSpacing: 0,
              title: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text('Edit Invoice #$_sNo'),
              ),
              leading: IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('Cancel', style: TextStyle(color: Colors.white)),
                ),
              ],
            )
          : null,
      body: LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 900;
        final gridCols = isNarrow ? 1 : 2;
        final gridAspect = isNarrow ? 1.15 : 1.8;
        final formFields = Column(children: [
            Row(children: [
              Expanded(child: Text('S.No: $_sNo', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
              SizedBox(
                width: 220,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Date', style: Theme.of(context).textTheme.labelSmall),
                    const SizedBox(height: 6),
                    SizedBox(
                      height: 44,
                      child: TextField(
                        controller: _date,
                        readOnly: true,
                        onTap: _pickDate,
                        textAlignVertical: TextAlignVertical.center,
                        decoration: const InputDecoration(
                          hintText: 'DD-MM-YYYY',
                          suffixIcon: Icon(Icons.calendar_month),
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ]),
            const SizedBox(height: 8),
            Autocomplete<String>(
              key: ValueKey('unified-$_customerLocked-${_customerId.text}-${_customer.text}-${_contact.text}'),
              optionsBuilder: (t){ final q=t.text.toLowerCase(); return _unified.where((s)=>s.toLowerCase().contains(q)); },
              onSelected: (v) async { final id=v.split(' - ').first; final c=await CustomerStore.findById(id); if (c!=null) _lockCustomer(c); },
              fieldViewBuilder: (context, controller, focus, onSubmit) => TextField(
                controller: controller, focusNode: focus, enabled: !_customerLocked,
                decoration: const InputDecoration(labelText: 'Customer (search by ID / Name / Phone)'),
                onSubmitted: (v) async {
                  final c = await CustomerStore.findById(v) ?? await CustomerStore.findByName(v) ?? await CustomerStore.findByContact(v);
                  if (c!=null) _lockCustomer(c);
                },
              ),
            ),
            const SizedBox(height: 8),
            Autocomplete<String>(
              key: ValueKey('id-$_customerLocked-${_customerId.text}'),
              optionsBuilder: (t){ final q=t.text.toLowerCase(); return _ids.where((s)=>s.toLowerCase().contains(q)); },
              onSelected: (v) async { final c=await CustomerStore.findById(v); if (c!=null) _lockCustomer(c); },
              fieldViewBuilder: (_, controller, focus, __) {
                controller.text=_customerId.text; controller.addListener(()=>_customerId.text = controller.text);
                return TextField(controller: controller, focusNode: focus, readOnly:true, enabled:false, decoration: const InputDecoration(labelText:'Customer ID'));
              },
            ),
            const SizedBox(height: 8),
            Autocomplete<String>(
              key: ValueKey('name-$_customerLocked-${_customer.text}'),
              optionsBuilder: (t){ final q=t.text.toLowerCase(); return _names.where((s)=>s.toLowerCase().contains(q)); },
              onSelected: (v) async { final c=await CustomerStore.findByName(v); if (c!=null) _lockCustomer(c); },
              fieldViewBuilder: (_, controller, focus, __) {
                controller.text=_customer.text; controller.addListener(()=>_customer.text = controller.text);
                return TextField(controller: controller, focusNode: focus, readOnly:_customerLocked, enabled: !_customerLocked, decoration: const InputDecoration(labelText:'Customer Name'));
              },
            ),
            const SizedBox(height: 8),
            Autocomplete<String>(
              key: ValueKey('phone-$_customerLocked-${_contact.text}'),
              optionsBuilder: (t){ final q=t.text.toLowerCase(); return _phones.where((s)=>s.toLowerCase().contains(q)); },
              onSelected: (v) async { final c=await CustomerStore.findByContact(v); if (c!=null) _lockCustomer(c); },
              fieldViewBuilder: (_, controller, focus, __) {
                controller.text=_contact.text; controller.addListener(()=>_contact.text = controller.text);
                return TextField(controller: controller, focusNode: focus, readOnly:_customerLocked, enabled: !_customerLocked,
                  decoration: const InputDecoration(labelText:'Phone (optional)'), keyboardType: TextInputType.phone,
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9+]'))]);
              },
            ),
            if (_customerLocked) ...[
              const SizedBox(height: 8),
              Align(alignment: Alignment.centerLeft, child:
                OutlinedButton.icon(onPressed: _clearCustomer, icon: const Icon(Icons.person_off), label: const Text('Clear customer (ID + Name + Phone)'))),
            ],
            const SizedBox(height: 8),
            Autocomplete<String>(optionsBuilder: (t){ final q=t.text.toLowerCase(); return _addressSuggestions.where((s)=>s.toLowerCase().contains(q)); }, onSelected: (v)=>setState(()=>_address.text=v), fieldViewBuilder: (_, controller, focus, __) { controller.text=_address.text; controller.selection=TextSelection.fromPosition(TextPosition(offset: controller.text.length)); controller.addListener(()=>_address.text=controller.text); return TextField(controller: controller, focusNode: focus, decoration: const InputDecoration(labelText:'Address (optional)')); }),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              key: ValueKey('site-$_site'),
              initialValue: _site,
              items: kShipmentSites
                  .map((s) => DropdownMenuItem<String>(value: s, child: Text(s)))
                  .toList(),
              onChanged: (v) => setState(() => _site = v ?? kShipmentSites.first),
              decoration: const InputDecoration(labelText: 'Shipment Site'),
            ),
            const SizedBox(height: 12),
            SwitchListTile.adaptive(
              value: _isWalkIn,
              onChanged: (v) => setState(() {
                _isWalkIn = v;
                if (!v) _clearWalkInPaymentFields();
                if (v && _customer.text.trim().isEmpty) {
                  // Autofill a placeholder name for walk-in customers while keeping the field editable.
                  _customer.text = 'Unknown';
                }
              }),
              contentPadding: EdgeInsets.zero,
              title: const Text('Walk-in customer'),
              subtitle: const Text('Record sale + payment now without creating Khata or Customer Master entry.'),
            ),
            if (_isWalkIn) ...[
              const SizedBox(height: 8),
              _walkInPaymentCard(),
            ],
          ]);
        final totalsCard = SizedBox(
          width: isNarrow ? double.infinity : 320,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(children: [
                      const Expanded(child: Text('Cartage (courier fee)', style: TextStyle(fontWeight: FontWeight.w600))),
                      SizedBox(width: 120, child: TextField(controller: _cartageCtrl, keyboardType: TextInputType.number,
                        onChanged: (_)=>setState((){}), inputFormatters:[FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))], decoration: const InputDecoration(hintText:'0'))),
                    ]),
                    const SizedBox(height: 8),
                    Row(children: [ const Expanded(child: Text('Total', style: TextStyle(fontWeight: FontWeight.bold))), Text(fmt0(_total), style: numStyle(weight: FontWeight.w600)) ]),
                    const SizedBox(height: 4),
                    Row(children: [ const Expanded(child: Text('Balance (Total + Cartage)', style: TextStyle(fontWeight: FontWeight.bold))), Text(fmt0(_balance), style: numStyle(weight: FontWeight.w600)) ]),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(
                        child: Tooltip(
                          message: 'Save invoice, export PDF and open it',
                          child: FilledButton.icon(
                            onPressed: _saveInvoice,
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(0, 46),
                              shape: const StadiumBorder(),
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            ),
                            icon: const Icon(Icons.picture_as_pdf_rounded),
                            label: const Text('Save PDF', overflow: TextOverflow.ellipsis),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Tooltip(
                          message: 'Auto-save, open folder and WhatsApp',
                          child: FilledButton.tonalIcon(
                            onPressed: _saveAndWhatsapp,
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(0, 46),
                              shape: const StadiumBorder(),
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            ),
                            icon: const FaIcon(FontAwesomeIcons.whatsapp, color: Color(0xFF25D366)),
                            label: const Text('WhatsApp + Folder', overflow: TextOverflow.ellipsis),
                          ),
                        ),
                      ),
                    ]),
                  ],
                ),
              ),
            ),
          ),
        );

        final topSection = isNarrow
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  formFields,
                  const SizedBox(height: 12),
                  totalsCard,
                ],
              )
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: formFields),
                  const SizedBox(width: 16),
                  totalsCard,
                ],
              );

        return SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                child: SingleChildScrollView(
                  physics: const ClampingScrollPhysics(),
                  child: Column(children: [
                    topSection,
                    const SizedBox(height: 16),
                    Align(alignment: Alignment.centerLeft, child: Text('Items', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold))),
                    const SizedBox(height: 8),
                    GridView.count(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), crossAxisCount: gridCols, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: gridAspect,
                      children: _lines.map((l)=>_itemCard(l)).toList() ),
                  ]),
                ),
              ),
            ),
          ),
        );
      },
    ),
    );
  }

  Widget _walkInPaymentCard() {
    return Card(
      elevation: 0,
      color: const Color(0xFFF7F7F7),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Walk-in payment', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            const Text('Marks this invoice as paid now and keeps it out of Khata/Customer Master.'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Cash'),
                  selected: _walkInType == PaymentType.cash,
                  onSelected: (_) => setState(() => _walkInType = PaymentType.cash),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  labelPadding: const EdgeInsets.symmetric(horizontal: 12),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  side: BorderSide(color: _walkInType == PaymentType.cash ? Colors.transparent : const Color(0x33000000)),
                ),
                ChoiceChip(
                  label: const Text('Cheque'),
                  selected: _walkInType == PaymentType.cheque,
                  onSelected: (_) => setState(() => _walkInType = PaymentType.cheque),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  labelPadding: const EdgeInsets.symmetric(horizontal: 12),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  side: BorderSide(color: _walkInType == PaymentType.cheque ? Colors.transparent : const Color(0x33000000)),
                ),
                ChoiceChip(
                  label: const Text('Bank'),
                  selected: _walkInType == PaymentType.bank,
                  onSelected: (_) => setState(() => _walkInType = PaymentType.bank),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  labelPadding: const EdgeInsets.symmetric(horizontal: 12),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  side: BorderSide(color: _walkInType == PaymentType.bank ? Colors.transparent : const Color(0x33000000)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.payments_outlined, size: 18),
                const SizedBox(width: 6),
                Text('Collect now: Rs ${fmt0(_balance)}', style: const TextStyle(fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 8),
            RawAutocomplete<String>(
              textEditingController: _walkInNote,
              focusNode: _walkInNoteFocus,
              optionsBuilder: (textEditingValue) {
                if (_noteSuggestions.isEmpty) return const Iterable<String>.empty();
                final q = textEditingValue.text.trim().toLowerCase();
                if (q.isEmpty) return _noteSuggestions;
                return _noteSuggestions.where((n) => n.toLowerCase().contains(q));
              },
              onSelected: (v) => _walkInNote.text = v,
              fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
                return TextField(
                  controller: controller,
                  focusNode: focusNode,
                  decoration: const InputDecoration(labelText: 'Payment note (optional)'),
                  onSubmitted: (_) => onFieldSubmitted(),
                  onTap: () {
                    // Force options list to appear on tap even when empty string.
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
            ),
            if (_walkInType == PaymentType.cheque) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                      child: TextField(
                    controller: _walkInBank,
                    decoration: const InputDecoration(labelText: 'Bank (optional)'),
                  )),
                  const SizedBox(width: 12),
                  Expanded(
                      child: TextField(
                    controller: _walkInCheque,
                    decoration: const InputDecoration(labelText: 'Cheque No (optional)'),
                  )),
                ],
              ),
            ] else if (_walkInType == PaymentType.bank) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                      child: TextField(
                    controller: _walkInBank,
                    decoration: const InputDecoration(labelText: 'Bank (optional)'),
                  )),
                  const SizedBox(width: 12),
                  Expanded(
                      child: TextField(
                    controller: _walkInTxn,
                    decoration: const InputDecoration(labelText: 'Txn ID (optional)'),
                  )),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 180,
                    child: DropdownButtonFormField<String>(
                      key: ValueKey('walkin-mode-$_walkInBankMode'),
                      value: _walkInBankMode,
                      items: const [
                        DropdownMenuItem(value: 'Deposit', child: Text('Deposit')),
                        DropdownMenuItem(value: 'Transfer', child: Text('Transfer')),
                      ],
                      onChanged: (v) => setState(() => _walkInBankMode = v ?? 'Deposit'),
                      decoration: const InputDecoration(labelText: 'Mode'),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _itemCard(ItemLine l) {
    return Card(key: ValueKey('line-${identityHashCode(l)}'), child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(l.typeLabel, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
          IconButton(
            tooltip: 'Add another ${l.typeLabel}',
            icon: const Icon(Icons.add),
            onPressed: () {
              setState(() {
                final idx = _lines.indexOf(l);
                _lines.insert(idx + 1, ItemLine(l.typeLabel));
              });
            },
          ),
          Builder(builder: (_) {
            final sameCount = _lines.where((x) => x.typeLabel == l.typeLabel).length;
            final canDelete = sameCount > 1;
            return IconButton(
              tooltip: canDelete ? 'Remove this ${l.typeLabel}' : 'Cannot remove the last ${l.typeLabel}',
              icon: const Icon(Icons.delete_outline),
              onPressed: canDelete
                  ? () {
                      setState(() {
                        l.dispose();
                        _lines.remove(l);
                      });
                    }
                  : null,
            );
          }),
        ]),
        const SizedBox(height: 8),
        Autocomplete<String>(
          key: ValueKey('brand-${l.typeLabel}-${identityHashCode(l)}-${_lines.indexOf(l)}'),
          optionsBuilder: (t){ final q=t.text.toLowerCase(); return _brandSuggestions.where((s)=>s.toLowerCase().contains(q)); },
          onSelected: (v)=>setState(()=>l.brand=v),
          fieldViewBuilder: (_, controller, focus, __) {
            controller.text=l.brand; controller.selection=TextSelection.fromPosition(TextPosition(offset: controller.text.length));
            controller.addListener(()=>l.brand=controller.text);
            return TextField(controller: controller, focusNode: focus, decoration: const InputDecoration(labelText:'Brand / company'));
          },
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: TextField(controller: l.qtyCtrl, keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))],
            decoration: const InputDecoration(labelText:'Qty'),
            onChanged: (v){ final n=int.tryParse(v)??0; if(n!=l.qty) setState(()=>l.qty=n); },
          )),
          const SizedBox(width: 8),
          Expanded(child: RawAutocomplete<String>(
            textEditingController: l.rateCtrl,
            focusNode: l.rateFocus,
            optionsBuilder: (textEditingValue) {
              final opts = _rateOptionsFor(l.typeLabel);
              if (opts.isEmpty) return const Iterable<String>.empty();
              final q = textEditingValue.text.trim();
              if (q.isEmpty) return opts;
              return opts.where((r) => r.contains(q));
            },
            onSelected: (v) {
              l.rateCtrl.text = v;
              final n = double.tryParse(v) ?? 0;
              if (n != l.rate) setState(() => l.rate = n);
            },
            fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
              return TextField(
                controller: controller,
                focusNode: focusNode,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))],
                decoration: const InputDecoration(labelText:'Rate'),
                onChanged: (v){ final n=double.tryParse(v)??0; if(n!=l.rate) setState(()=>l.rate=n); },
                onSubmitted: (_) => onFieldSubmitted(),
                onTap: () { controller.value = controller.value; },
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
                    constraints: const BoxConstraints(maxHeight: 180, minWidth: 140),
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
          const SizedBox(width: 8),
          Text(fmt0(l.amount), style: numStyle(weight: FontWeight.w600)),
        ]),
      ]),
    ));
  }
}
