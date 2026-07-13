import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:open_filex/open_filex.dart';
import 'package:share_plus/share_plus.dart';

import '../core/constants.dart';
import '../core/app_bus.dart';
import '../models/customer.dart';
import '../models/invoice.dart';
import '../models/mobile_access.dart';
import '../models/payment.dart';
import '../services/mobile_sync_store.dart';
import '../services/server_sync_client.dart';
import '../services/storage.dart';
import '../services/excel_service.dart';
import '../services/godown_stock_store.dart';
import '../services/pdf_builder.dart';
import '../services/paths.dart';
import '../utils/date.dart';
import '../utils/format.dart';
import '../utils/snackbar.dart';
import '../utils/file_io.dart';
import '../widgets/app_panels.dart';

/* ------------------------------- INVOICE CREATE SCREEN ------------------------------ */
class InvoiceScreen extends StatefulWidget {
  final Invoice? initialInvoice;
  final bool editing;
  final bool pdfOnlyShare;
  final bool makeupInvoiceMode;
  final bool startReturnFlow;
  final AppUser? draftUser;

  const InvoiceScreen({
    super.key,
    this.initialInvoice,
    this.editing = false,
    this.pdfOnlyShare = false,
    this.makeupInvoiceMode = false,
    this.startReturnFlow = false,
    this.draftUser,
  });
  @override
  State<InvoiceScreen> createState() => _InvoiceScreenState();
}

class _InvoiceScreenState extends State<InvoiceScreen>
    with AutomaticKeepAliveClientMixin {
  Invoice? _originalInvoice;
  bool get _isEditing => widget.editing && widget.initialInvoice != null;
  bool get _isPdfOnlyShare =>
      widget.pdfOnlyShare && widget.initialInvoice != null;
  bool get _isMakeupInvoice => widget.makeupInvoiceMode;
  bool get _isPdfSendOnly => _isPdfOnlyShare || _isMakeupInvoice;
  final _customerId = TextEditingController();
  final _customer = TextEditingController();
  final _contact = TextEditingController();
  final _address = TextEditingController();
  final _customerLookup = TextEditingController();
  final _customerLookupFocus = FocusNode();
  final _customerFocus = FocusNode();
  final _contactFocus = FocusNode();
  final _addressFocus = FocusNode();
  final _date = TextEditingController(text: formatInvoiceDate(DateTime.now()));
  final _cartageCtrl = TextEditingController(text: '0');

  int _sNo = 1;
  String _site = kShipmentSites.first;

  List<Customer> _customers = [];
  List<String> _names = [], _phones = [], _unified = [];
  bool _customerLocked = false;

  List<String> _brandSuggestions = [];
  List<GodownSku> _godownSkus = [];
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
  bool _recordPaymentNow = false;
  PaymentType _invoicePaymentType = PaymentType.cash;
  DateTime _invoicePaymentDate = DateTime.now();
  String _invoicePaymentBankMode = 'Transfer';
  final _invoicePaymentDiscount = TextEditingController();
  final _invoicePaymentNote = TextEditingController();
  final FocusNode _invoicePaymentNoteFocus = FocusNode();
  final _invoicePaymentBank = TextEditingController();
  final _invoicePaymentCheque = TextEditingController();
  final _invoicePaymentTxn = TextEditingController();
  void _bumpMobileDraftTick() {
    if (mounted) setState(() {});
  }

  void _replaceLines(List<ItemLine> nextLines) {
    final oldLines = List<ItemLine>.from(_lines);
    _lines
      ..clear()
      ..addAll(nextLines);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final line in oldLines) {
        line.dispose();
      }
    });
  }

  void _resetFormToDefaults({int? nextSerial}) {
    _replaceLines(kItemTypes.map((t) => ItemLine(t)).toList());
    _customerId.clear();
    _customer.clear();
    _contact.clear();
    _address.clear();
    _customerLookup.clear();
    _customerLocked = false;
    _date.text = formatInvoiceDate(DateTime.now());
    _cartageCtrl.text = '0';
    _site = kShipmentSites.first;
    _isWalkIn = false;
    _clearWalkInPaymentFields();
    _clearInvoicePaymentFields();
    if (nextSerial != null) _sNo = nextSerial;
  }

  void _applyInvoice(Invoice inv) {
    final remaining = List<ItemLine>.from(inv.lines);
    final nextLines = <ItemLine>[];
    for (final type in kItemTypes) {
      final index = remaining.indexWhere((line) => line.typeLabel == type);
      if (index >= 0) {
        final line = remaining.removeAt(index);
        nextLines.add(
          ItemLine(type, brand: line.brand, qty: line.qty, rate: line.rate),
        );
      } else {
        nextLines.add(ItemLine(type));
      }
    }
    for (final extra in remaining) {
      nextLines.add(ItemLine(
        extra.typeLabel,
        brand: extra.brand,
        qty: extra.qty,
        rate: extra.rate,
      ));
    }
    _replaceLines(nextLines);
    _sNo = inv.sNo;
    _date.text = inv.date;
    _customerId.text = inv.customerId;
    _customer.text = inv.customer;
    _contact.text = inv.contact;
    _address.text = inv.address;
    final lookupParts = <String>[
      if (inv.customerId.trim().isNotEmpty) inv.customerId.trim(),
      if (inv.customer.trim().isNotEmpty) inv.customer.trim(),
      if ((inv.customerDisplay ?? '').trim().isNotEmpty &&
          (inv.customerDisplay ?? '').trim() != inv.customer.trim())
        (inv.customerDisplay ?? '').trim(),
      if (inv.contact.trim().isNotEmpty) inv.contact.trim(),
    ];
    _customerLookup.text = lookupParts.join(' - ');
    _site = inv.site;
    _cartageCtrl.text = inv.cartage == 0 ? '0' : inv.cartage.toStringAsFixed(0);
    _isWalkIn = inv.walkIn;
    _walkInType = inv.walkInPaymentType ?? PaymentType.cash;
    _walkInBankMode = inv.walkInBankMode ?? 'Deposit';
    _walkInNote.text = inv.walkInPaymentNote ?? '';
    _walkInBank.text = inv.walkInBank ?? '';
    _walkInCheque.text = inv.walkInChequeNo ?? '';
    _walkInTxn.text = inv.walkInTxnId ?? '';
    _clearInvoicePaymentFields();
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
      if (widget.startReturnFlow && !(_originalInvoice?.isReturn ?? false)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _recordReturnFromInvoice();
        });
      }
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
    _customerLookup.dispose();
    _customerLookupFocus.dispose();
    _customerFocus.dispose();
    _contactFocus.dispose();
    _addressFocus.dispose();
    _date.dispose();
    _cartageCtrl.dispose();
    _walkInNote.dispose();
    _walkInNoteFocus.dispose();
    _walkInBank.dispose();
    _walkInCheque.dispose();
    _walkInTxn.dispose();
    _invoicePaymentDiscount.dispose();
    _invoicePaymentNote.dispose();
    _invoicePaymentNoteFocus.dispose();
    _invoicePaymentBank.dispose();
    _invoicePaymentCheque.dispose();
    _invoicePaymentTxn.dispose();
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
    final results = await Future.wait<dynamic>([
      CustomerStore.loadActive(),
      Store.loadAll(),
      GodownStockStore.loadConfig(),
      PaymentStore.loadAll(),
    ]);
    _customers = results[0] as List<Customer>;
    final invs = results[1] as List<Invoice>;
    final godownCfg = results[2] as GodownConfig;
    final payments = results[3] as List<PaymentEntry>;

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
    _brandSuggestions = invs
        .expand((inv) => inv.lines.map((l) => l.brand.trim()))
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList()
        .cast<String>();
    _godownSkus = godownCfg.skus;
    _addressSuggestions = invs
        .map((inv) => inv.address.trim())
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList()
        .cast<String>();
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
      ..sort((a, b) =>
          parseInvoiceDate(b.date).compareTo(parseInvoiceDate(a.date)));
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
          final custMap =
              rateById.putIfAbsent(idKey, () => <String, List<String>>{});
          final list = custMap.putIfAbsent(type, () => <String>[]);
          if (!list.contains(rateStr)) list.add(rateStr);
        }
        if (nameKey.isNotEmpty) {
          final custMap =
              rateByName.putIfAbsent(nameKey, () => <String, List<String>>{});
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
      final lookupParts = <String>[
        if (c.id.trim().isNotEmpty) c.id.trim(),
        if (c.name.trim().isNotEmpty) c.name.trim(),
        if (c.displayName.trim().isNotEmpty &&
            c.displayName.trim() != c.name.trim())
          c.displayName.trim(),
        if (c.contact.trim().isNotEmpty) c.contact.trim(),
      ];
      _customerLookup.text = lookupParts.join(' - ');
      _customerLocked = true;
    });
  }

  void _clearCustomer() {
    setState(() {
      _customerId.clear();
      _customer.clear();
      _contact.clear();
      _customerLookup.clear();
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

  void _clearInvoicePaymentFields() {
    _recordPaymentNow = false;
    _invoicePaymentType = PaymentType.cash;
    _invoicePaymentDate = DateTime.now();
    _invoicePaymentBankMode = 'Transfer';
    _invoicePaymentDiscount.clear();
    _invoicePaymentNote.clear();
    _invoicePaymentBank.clear();
    _invoicePaymentCheque.clear();
    _invoicePaymentTxn.clear();
  }

  DateTime _safeInvoiceDate() {
    try {
      return parseInvoiceDate(_date.text.trim());
    } catch (_) {
      return DateTime.now();
    }
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

  Widget _stringOptionsView(
    BuildContext context,
    AutocompleteOnSelected<String> onSelected,
    Iterable<String> options,
  ) {
    return Align(
      alignment: Alignment.topLeft,
      child: Material(
        elevation: 4,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 240, minWidth: 280),
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
  }

  Iterable<String> _brandOptionsForLine(ItemLine line, String query) {
    final q = query.toLowerCase();
    final source = _site.trim().toLowerCase() == 'godown'
        ? _godownSkus
            .where((s) => s.category.isEmpty || s.category == line.typeLabel)
            .map((s) => s.name)
            .toList()
        : _brandSuggestions;
    if (q.isEmpty) return source;
    return source.where((s) => s.toLowerCase().contains(q));
  }

  Future<void> _persistInvoice(Invoice inv) async {
    final previous = _originalInvoice;
    await Store.upsertInvoice(inv);
    if (!inv.walkIn) {
      await CustomerStore.upsertFixed(Customer(
        id: inv.customerId,
        name: inv.customer,
        displayName: inv.customerDisplay ?? inv.customer,
        contact: inv.contact,
      ));
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
    final keyNow =
        (inv.customerId.isNotEmpty ? inv.customerId : inv.customer).trim();
    if (keyNow.isNotEmpty) customerKeys.add(keyNow);
    if (previous != null) {
      final keyPrev = (previous.customerId.isNotEmpty
              ? previous.customerId
              : previous.customer)
          .trim();
      if (keyPrev.isNotEmpty) customerKeys.add(keyPrev);
    }

    queueInvoiceReportRefresh(
      dates: dates,
      months: months,
      customerKeys: customerKeys,
    );
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

  Future<List<ItemLine>?> _snapshotLinesForSave() async {
    final snapshotLines = _lines
        .map((l) =>
            ItemLine(l.typeLabel, brand: l.brand, qty: l.qty, rate: l.rate))
        .toList();

    if (_site.trim().toLowerCase() != 'godown') {
      return snapshotLines;
    }

    for (final l in snapshotLines) {
      if (l.qty <= 0) continue;
      final rawBrand = l.brand.trim();
      if (rawBrand.isEmpty) continue;
      final canonical = await GodownStockStore.resolveCanonicalSku(
        rawBrand,
        category: l.typeLabel,
      );
      if (canonical == null) {
        if (!mounted) return null;
        showErr(
          context,
          'Godown SKU "$rawBrand" not found for category ${l.typeLabel}. Add SKU/alias in Godown Hisaab.',
        );
        return null;
      }
      l.brand = canonical;
      l.brandCtrl.text = canonical;
    }
    return snapshotLines;
  }

  Future<void> _saveInvoice() async {
    if (!_validateInvoiceInputs()) return;
    final snapshotLines = await _snapshotLinesForSave();
    if (snapshotLines == null) return;
    Customer? selected;
    if (!_isWalkIn && _customerId.text.trim().isEmpty) {
      final newId = await CustomerStore.nextCustomerId();
      _customerId.text = newId;
      await CustomerStore.addCustomer(
          newId, _customer.text.trim(), _contact.text.trim(),
          displayName: _customer.text.trim());
      _customerLocked = true;
    } else {
      selected = await CustomerStore.findById(_customerId.text.trim());
      selected ??= await CustomerStore.findByName(_customer.text.trim());
    }
    final displayName = selected?.displayName ?? _customer.text.trim();
    final internalName = selected?.name ?? _customer.text.trim();
    final inv = Invoice(
      sNo: _sNo,
      date: _date.text.trim(),
      customer: internalName,
      customerDisplay: displayName,
      customerId: _customerId.text.trim().isNotEmpty
          ? _customerId.text.trim()
          : internalName,
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
    await _savePaymentFromInvoiceIfNeeded(inv);
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
        showErr(context,
            'Add a phone number to send via WhatsApp. You can still save the invoice without a number.');
        return;
      }
      final snapshotLines = await _snapshotLinesForSave();
      if (snapshotLines == null) return;
      Customer? selected;
      if (!_isWalkIn && _customerId.text.trim().isEmpty) {
        final newId = await CustomerStore.nextCustomerId();
        _customerId.text = newId;
        await CustomerStore.addCustomer(
            newId, _customer.text.trim(), _contact.text.trim(),
            displayName: _customer.text.trim());
        _customerLocked = true;
      } else {
        selected = await CustomerStore.findById(_customerId.text.trim());
        selected ??= await CustomerStore.findByName(_customer.text.trim());
      }
      final displayName = selected?.displayName ?? _customer.text.trim();
      final internalName = selected?.name ?? _customer.text.trim();
      final inv = Invoice(
        sNo: _sNo,
        date: _date.text.trim(),
        customer: internalName,
        customerDisplay: displayName,
        customerId: _customerId.text.trim().isNotEmpty
            ? _customerId.text.trim()
            : internalName,
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
        walkInBankMode: _isWalkIn && _walkInType == PaymentType.bank
            ? _walkInBankMode
            : null,
      );
      await _persistInvoice(inv);
      await _savePaymentFromInvoiceIfNeeded(inv);

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

  Future<void> _sharePdfOnly() async {
    try {
      if (!_validateInvoiceInputs()) return;
      final snapshotLines = await _snapshotLinesForSave();
      if (snapshotLines == null) return;
      final base = widget.initialInvoice;
      final customerName = _customer.text.trim();
      final inv = Invoice(
        sNo: _sNo,
        date: _date.text.trim(),
        customer: base?.customer ?? customerName,
        customerDisplay: customerName,
        customerId: base?.customerId ??
            (_customerId.text.trim().isNotEmpty
                ? _customerId.text.trim()
                : customerName),
        contact: _contact.text.trim(),
        address: _address.text.trim(),
        site: _site,
        lines: snapshotLines,
        cartage: _cartageVal,
        paid: base?.paid ?? 0,
        walkIn: base?.walkIn ?? false,
        walkInPaymentType: base?.walkInPaymentType,
        walkInPaymentNote: base?.walkInPaymentNote,
        walkInBank: base?.walkInBank,
        walkInChequeNo: base?.walkInChequeNo,
        walkInTxnId: base?.walkInTxnId,
        walkInBankMode: base?.walkInBankMode,
      );
      final pdfBytes = await PdfBuilder.build(inv);
      final invDir = await subdir('invoices');
      final pdfFile =
          File('${invDir.path}${Platform.pathSeparator}invoice_${inv.sNo}.pdf');
      final written = await safeWriteBytes(pdfFile, pdfBytes);
      await Share.shareXFiles(
        [XFile(written.path)],
        text: 'Invoice #${inv.sNo}',
      );
      if (!mounted) return;
      Navigator.of(context).pop(inv);
    } catch (_) {
      if (!mounted) return;
      showErr(context, 'Could not create PDF.');
    }
  }

  Future<void> _savePaymentFromInvoiceIfNeeded(Invoice inv) async {
    if (_isWalkIn || !_recordPaymentNow) return;
    final amount = inv.balance;
    final discount =
        double.tryParse(_invoicePaymentDiscount.text.trim()) ?? 0.0;
    if (amount <= 0 && discount <= 0) return;

    await addPaymentForCustomer(
      customerId: inv.customerId,
      customerName: inv.customer,
      type: _invoicePaymentType,
      date: _invoicePaymentDate,
      amount: amount,
      discount: discount,
      note: _invoicePaymentNote.text.trim().isEmpty
          ? null
          : _invoicePaymentNote.text.trim(),
      bank: (_invoicePaymentType == PaymentType.cheque ||
              _invoicePaymentType == PaymentType.bank)
          ? (_invoicePaymentBank.text.trim().isEmpty
              ? null
              : _invoicePaymentBank.text.trim())
          : null,
      chequeNo: _invoicePaymentType == PaymentType.cheque
          ? (_invoicePaymentCheque.text.trim().isEmpty
              ? null
              : _invoicePaymentCheque.text.trim())
          : null,
      txnId: _invoicePaymentType == PaymentType.bank
          ? (_invoicePaymentTxn.text.trim().isEmpty
              ? null
              : _invoicePaymentTxn.text.trim())
          : null,
      bankMode: _invoicePaymentType == PaymentType.bank
          ? _invoicePaymentBankMode
          : null,
    );
  }

  List<ItemLine> _returnableLines(Invoice inv) {
    return inv.lines.where((line) => line.qty > 0).toList();
  }

  Future<void> _recordReturnFromInvoice() async {
    final source = _originalInvoice ?? widget.initialInvoice;
    if (!_isEditing || source == null || source.isReturn) return;
    final returnLines = _returnableLines(source);
    if (returnLines.isEmpty) {
      showErr(context, 'No returnable quantity found on this invoice.');
      return;
    }

    final result = await showDialog<_ReturnInvoiceResult>(
      context: context,
      builder: (_) => _ReturnInvoiceDialog(
        invoiceNo: source.sNo,
        lines: returnLines,
      ),
    );

    if (!mounted || result == null) return;

    final selectedLines = <ItemLine>[];
    for (final line in returnLines) {
      final qty = result.quantities[line] ?? 0;
      if (qty == 0) continue;
      selectedLines.add(ItemLine(
        line.typeLabel,
        brand: line.brand,
        qty: -qty,
        rate: line.rate,
      ));
    }

    final Invoice returnInvoice;
    final mobileUser = widget.draftUser;
    if (mobileUser != null) {
      try {
        final config = await MobileAccessStore.loadServerConfig();
        returnInvoice = await ServerSyncClient.recordInvoiceReturn(
          baseUrl: config.baseUrl,
          username: mobileUser.username,
          passcode: mobileUser.passcode,
          sourceInvoiceNo: source.sNo,
          returnDate: formatInvoiceDate(result.date),
          lines: selectedLines,
        );
      } on ServerSyncException catch (error) {
        if (!mounted) return;
        showErr(context, error.message);
        return;
      }
    } else {
      returnInvoice = Invoice(
        sNo: await Store.nextSerial(),
        date: formatInvoiceDate(result.date),
        customer: source.customer,
        customerDisplay: source.customerDisplay,
        customerId: source.customerId,
        contact: source.contact,
        address: source.address,
        site: source.site,
        lines: selectedLines,
        cartage: 0,
        paid: 0,
        walkIn: false,
        isReturn: true,
        returnOfInvoiceNo: source.sNo,
      );
      await _persistInvoice(returnInvoice);
      await syncInvoicesPaidFromPayments();
    }
    if (!mounted) return;
    showOk(context, 'Return #${returnInvoice.sNo} recorded');
    Navigator.of(context).pop(returnInvoice);
  }

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final pageBody = LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 900;
        final gridCols = isNarrow ? 1 : 2;
        final gridAspect = isNarrow ? 1.15 : 1.8;
        final formFields = AppSoftCard(
          child: Column(children: [
            Row(children: [
              Expanded(
                child: AppSectionTitle(
                  title: _isMakeupInvoice ? 'Makeup Invoice' : 'S.No: $_sNo',
                ),
              ),
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
                          contentPadding: EdgeInsets.symmetric(
                              horizontal: 12, vertical: 12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ]),
            const SizedBox(height: 8),
            RawAutocomplete<String>(
              textEditingController: _customerLookup,
              focusNode: _customerLookupFocus,
              optionsViewBuilder: _stringOptionsView,
              optionsBuilder: (t) {
                final q = t.text.toLowerCase();
                return _unified.where((s) => s.toLowerCase().contains(q));
              },
              onSelected: (v) async {
                final id = v.split(' - ').first;
                final c = await CustomerStore.findById(id);
                if (c != null) _lockCustomer(c);
              },
              fieldViewBuilder: (context, controller, focus, onSubmit) =>
                  TextField(
                controller: controller,
                focusNode: focus,
                enabled: !_customerLocked,
                decoration: const InputDecoration(
                    labelText: 'Customer (search by ID / Name / Phone)'),
                onSubmitted: (v) async {
                  final c = await CustomerStore.findById(v) ??
                      await CustomerStore.findByName(v) ??
                      await CustomerStore.findByContact(v);
                  if (c != null) _lockCustomer(c);
                },
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _customerId,
              readOnly: true,
              enabled: false,
              decoration: const InputDecoration(labelText: 'Customer ID'),
            ),
            const SizedBox(height: 8),
            RawAutocomplete<String>(
              textEditingController: _customer,
              focusNode: _customerFocus,
              optionsViewBuilder: _stringOptionsView,
              optionsBuilder: (t) {
                final q = t.text.toLowerCase();
                return _names.where((s) => s.toLowerCase().contains(q));
              },
              onSelected: (v) async {
                final c = await CustomerStore.findByName(v);
                if (c != null) _lockCustomer(c);
              },
              fieldViewBuilder: (_, controller, focus, __) {
                return TextField(
                    controller: controller,
                    focusNode: focus,
                    readOnly: _customerLocked,
                    enabled: !_customerLocked,
                    decoration:
                        const InputDecoration(labelText: 'Customer Name'));
              },
            ),
            const SizedBox(height: 8),
            RawAutocomplete<String>(
              textEditingController: _contact,
              focusNode: _contactFocus,
              optionsViewBuilder: _stringOptionsView,
              optionsBuilder: (t) {
                final q = t.text.toLowerCase();
                return _phones.where((s) => s.toLowerCase().contains(q));
              },
              onSelected: (v) async {
                final c = await CustomerStore.findByContact(v);
                if (c != null) _lockCustomer(c);
              },
              fieldViewBuilder: (_, controller, focus, __) {
                return TextField(
                    controller: controller,
                    focusNode: focus,
                    readOnly: _customerLocked,
                    enabled: !_customerLocked,
                    decoration:
                        const InputDecoration(labelText: 'Phone (optional)'),
                    keyboardType: TextInputType.phone,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9+]'))
                    ]);
              },
            ),
            if (_customerLocked) ...[
              const SizedBox(height: 8),
              Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                      onPressed: _clearCustomer,
                      icon: const Icon(Icons.person_off),
                      label: const Text('Clear customer (ID + Name + Phone)'))),
            ],
            const SizedBox(height: 8),
            RawAutocomplete<String>(
                textEditingController: _address,
                focusNode: _addressFocus,
                optionsViewBuilder: _stringOptionsView,
                optionsBuilder: (t) {
                  final q = t.text.toLowerCase();
                  return _addressSuggestions
                      .where((s) => s.toLowerCase().contains(q));
                },
                onSelected: (v) => _address.text = v,
                fieldViewBuilder: (_, controller, focus, __) {
                  return TextField(
                      controller: controller,
                      focusNode: focus,
                      decoration: const InputDecoration(
                          labelText: 'Address (optional)'));
                }),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              key: ValueKey('site-$_site'),
              initialValue: _site,
              items: kShipmentSites
                  .map(
                      (s) => DropdownMenuItem<String>(value: s, child: Text(s)))
                  .toList(),
              onChanged: (v) =>
                  setState(() => _site = v ?? kShipmentSites.first),
              decoration: const InputDecoration(labelText: 'Shipment Site'),
            ),
            if (_isMakeupInvoice) ...[
              const SizedBox(height: 12),
              const Text(
                'Use this to prepare and send a PDF only. It will not be saved in records.',
              ),
            ] else ...[
              const SizedBox(height: 12),
              AppSoftCard(
                backgroundColor: Colors.white,
                child: SwitchListTile.adaptive(
                  value: _isWalkIn,
                  onChanged: (v) => setState(() {
                    _isWalkIn = v;
                    if (!v) _clearWalkInPaymentFields();
                    if (v) _clearInvoicePaymentFields();
                    if (v && _customer.text.trim().isEmpty) {
                      _customer.text = 'Unknown';
                    }
                  }),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Walk-in customer'),
                  subtitle: const Text(
                      'Record sale + payment now without creating Khata or Customer Master entry.'),
                ),
              ),
              if (_isWalkIn) ...[
                const SizedBox(height: 8),
                _walkInPaymentCard(),
              ] else ...[
                const SizedBox(height: 12),
                AppSoftCard(
                  backgroundColor: Colors.white,
                  child: SwitchListTile.adaptive(
                    value: _recordPaymentNow,
                    onChanged: (v) => setState(() {
                      _recordPaymentNow = v;
                      if (v) {
                        _invoicePaymentDate = _safeInvoiceDate();
                      } else {
                        _clearInvoicePaymentFields();
                      }
                    }),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Record payment now'),
                    subtitle: const Text(
                        'Save payment directly with invoice (same as Payments tab).'),
                  ),
                ),
                if (_recordPaymentNow) ...[
                  const SizedBox(height: 8),
                  _invoicePaymentCard(),
                ],
              ],
            ],
          ]),
        );
        final totalsCardContent = SizedBox(
          width: isNarrow ? double.infinity : 320,
          child: AppSoftCard(
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(children: [
                      const Expanded(child: Text('Cartage (courier fee)')),
                      SizedBox(
                          width: 120,
                          child: TextField(
                              controller: _cartageCtrl,
                              keyboardType: TextInputType.number,
                              onChanged: (_) => _bumpMobileDraftTick(),
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(
                                    RegExp(r'[0-9]'))
                              ],
                              decoration:
                                  const InputDecoration(hintText: '0'))),
                    ]),
                    const SizedBox(height: 8),
                    Row(children: [
                      const Expanded(child: Text('Total')),
                      Text(fmt0(_total),
                          style: numStyle(weight: FontWeight.w600))
                    ]),
                    const SizedBox(height: 4),
                    Row(children: [
                      const Expanded(child: Text('Balance (Total + Cartage)')),
                      Text(fmt0(_balance),
                          style: numStyle(weight: FontWeight.w600))
                    ]),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(
                        child: Tooltip(
                          message: _isPdfSendOnly
                              ? 'Create and share a PDF without changing records'
                              : 'Save invoice without generating a PDF',
                          child: FilledButton.icon(
                            onPressed:
                                _isPdfSendOnly ? _sharePdfOnly : _saveInvoice,
                            style: appGreenButtonStyle(context),
                            icon: Icon(_isPdfSendOnly
                                ? Icons.picture_as_pdf_outlined
                                : Icons.save_outlined),
                            label: Text(
                                _isPdfSendOnly ? 'Send PDF' : 'Save Invoice',
                                overflow: TextOverflow.ellipsis),
                          ),
                        ),
                      ),
                      if (!_isPdfSendOnly) ...[
                        const SizedBox(width: 10),
                        Expanded(
                          child: Tooltip(
                            message: 'Auto-save, open folder and WhatsApp',
                            child: FilledButton.tonalIcon(
                              onPressed: _saveAndWhatsapp,
                              style: appGreenOutlineButtonStyle(context),
                              icon: const FaIcon(FontAwesomeIcons.whatsapp,
                                  color: Color(0xFF25D366)),
                              label: const Text('WhatsApp + Folder',
                                  overflow: TextOverflow.ellipsis),
                            ),
                          ),
                        ),
                      ],
                    ]),
                  ],
                ),
              ),
            ),
          ),
        );
        final totalsCard = totalsCardContent;

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
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                child: SingleChildScrollView(
                  physics: const ClampingScrollPhysics(),
                  child: Column(children: [
                    topSection,
                    const SizedBox(height: 16),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: AppSectionTitle(title: 'Items'),
                    ),
                    const SizedBox(height: 8),
                    GridView.count(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      crossAxisCount: gridCols,
                      mainAxisSpacing: 10,
                      crossAxisSpacing: 10,
                      childAspectRatio: gridAspect,
                      children: _lines.map((l) => _itemCard(l)).toList(),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        );
      },
    );
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
                if (_isEditing && !(widget.initialInvoice?.isReturn ?? false))
                  TextButton.icon(
                    onPressed: _recordReturnFromInvoice,
                    icon: const Icon(Icons.assignment_return_outlined,
                        color: Colors.white),
                    label: const Text('Return',
                        style: TextStyle(color: Colors.white)),
                  ),
                TextButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: const Text('Cancel',
                      style: TextStyle(color: Colors.white)),
                ),
              ],
            )
          : null,
      body: pageBody,
    );
  }

  Widget _walkInPaymentCard() {
    return AppSoftCard(
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AppSectionTitle(
              title: 'Walk-in payment',
              subtitle:
                  'Marks this invoice as paid now and keeps it out of Khata/Customer Master.',
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  label: const Text('Cash'),
                  selected: _walkInType == PaymentType.cash,
                  onSelected: (_) =>
                      setState(() => _walkInType = PaymentType.cash),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  labelPadding: const EdgeInsets.symmetric(horizontal: 12),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  side: BorderSide(
                      color: _walkInType == PaymentType.cash
                          ? Colors.transparent
                          : const Color(0x33000000)),
                ),
                ChoiceChip(
                  label: const Text('Cheque'),
                  selected: _walkInType == PaymentType.cheque,
                  onSelected: (_) =>
                      setState(() => _walkInType = PaymentType.cheque),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  labelPadding: const EdgeInsets.symmetric(horizontal: 12),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  side: BorderSide(
                      color: _walkInType == PaymentType.cheque
                          ? Colors.transparent
                          : const Color(0x33000000)),
                ),
                ChoiceChip(
                  label: const Text('Bank'),
                  selected: _walkInType == PaymentType.bank,
                  onSelected: (_) =>
                      setState(() => _walkInType = PaymentType.bank),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  labelPadding: const EdgeInsets.symmetric(horizontal: 12),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  side: BorderSide(
                      color: _walkInType == PaymentType.bank
                          ? Colors.transparent
                          : const Color(0x33000000)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.payments_outlined, size: 18),
                const SizedBox(width: 6),
                Text('Collect now: Rs ${fmt0(_balance)}',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        )),
              ],
            ),
            const SizedBox(height: 8),
            RawAutocomplete<String>(
              textEditingController: _walkInNote,
              focusNode: _walkInNoteFocus,
              optionsBuilder: (textEditingValue) {
                if (_noteSuggestions.isEmpty) {
                  return const Iterable<String>.empty();
                }
                final q = textEditingValue.text.trim().toLowerCase();
                if (q.isEmpty) return _noteSuggestions;
                return _noteSuggestions
                    .where((n) => n.toLowerCase().contains(q));
              },
              onSelected: (v) => _walkInNote.text = v,
              fieldViewBuilder:
                  (context, controller, focusNode, onFieldSubmitted) {
                return TextField(
                  controller: controller,
                  focusNode: focusNode,
                  decoration: const InputDecoration(
                      labelText: 'Payment note (optional)'),
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
                      constraints:
                          const BoxConstraints(maxHeight: 200, minWidth: 200),
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
                    decoration:
                        const InputDecoration(labelText: 'Bank (optional)'),
                  )),
                  const SizedBox(width: 12),
                  Expanded(
                      child: TextField(
                    controller: _walkInCheque,
                    decoration: const InputDecoration(
                        labelText: 'Cheque No (optional)'),
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
                    decoration:
                        const InputDecoration(labelText: 'Bank (optional)'),
                  )),
                  const SizedBox(width: 12),
                  Expanded(
                      child: TextField(
                    controller: _walkInTxn,
                    decoration:
                        const InputDecoration(labelText: 'Txn ID (optional)'),
                  )),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 180,
                    child: DropdownButtonFormField<String>(
                      key: ValueKey('walkin-mode-$_walkInBankMode'),
                      initialValue: _walkInBankMode,
                      items: const [
                        DropdownMenuItem(
                            value: 'Deposit', child: Text('Deposit')),
                        DropdownMenuItem(
                            value: 'Transfer', child: Text('Transfer')),
                      ],
                      onChanged: (v) =>
                          setState(() => _walkInBankMode = v ?? 'Deposit'),
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

  Widget _invoicePaymentCard() {
    return AppSoftCard(
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const AppSectionTitle(title: 'Payment details'),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                    label: const Text('Cash'),
                    selected: _invoicePaymentType == PaymentType.cash,
                    onSelected: (_) =>
                        setState(() => _invoicePaymentType = PaymentType.cash),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    side: BorderSide(
                        color: _invoicePaymentType == PaymentType.cash
                            ? Colors.transparent
                            : const Color(0x33000000)),
                    labelPadding: const EdgeInsets.symmetric(horizontal: 12),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact),
                ChoiceChip(
                    label: const Text('Cheque'),
                    selected: _invoicePaymentType == PaymentType.cheque,
                    onSelected: (_) => setState(
                        () => _invoicePaymentType = PaymentType.cheque),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    side: BorderSide(
                        color: _invoicePaymentType == PaymentType.cheque
                            ? Colors.transparent
                            : const Color(0x33000000)),
                    labelPadding: const EdgeInsets.symmetric(horizontal: 12),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact),
                ChoiceChip(
                    label: const Text('Bank'),
                    selected: _invoicePaymentType == PaymentType.bank,
                    onSelected: (_) =>
                        setState(() => _invoicePaymentType = PaymentType.bank),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    side: BorderSide(
                        color: _invoicePaymentType == PaymentType.bank
                            ? Colors.transparent
                            : const Color(0x33000000)),
                    labelPadding: const EdgeInsets.symmetric(horizontal: 12),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    visualDensity: VisualDensity.compact),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                const Icon(Icons.payments_outlined, size: 18),
                const SizedBox(width: 6),
                Text('Amount (auto from invoice): Rs ${fmt0(_balance)}',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        )),
              ],
            ),
            const SizedBox(height: 8),
            InkWell(
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _invoicePaymentDate,
                  firstDate: DateTime(2000),
                  lastDate: DateTime(2100),
                );
                if (picked != null) {
                  setState(() => _invoicePaymentDate = picked);
                }
              },
              child: InputDecorator(
                decoration: const InputDecoration(labelText: 'Payment date'),
                child: Row(
                  children: [
                    const Icon(Icons.calendar_today, size: 18),
                    const SizedBox(width: 8),
                    Text(dfDay.format(_invoicePaymentDate)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                  child: TextField(
                controller: _invoicePaymentDiscount,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))
                ],
                decoration:
                    const InputDecoration(labelText: 'Discount (optional)'),
              )),
              const SizedBox(width: 12),
              Expanded(
                  child: RawAutocomplete<String>(
                textEditingController: _invoicePaymentNote,
                focusNode: _invoicePaymentNoteFocus,
                optionsBuilder: (textEditingValue) {
                  if (_noteSuggestions.isEmpty) {
                    return const Iterable<String>.empty();
                  }
                  final q = textEditingValue.text.trim().toLowerCase();
                  if (q.isEmpty) return _noteSuggestions;
                  return _noteSuggestions
                      .where((n) => n.toLowerCase().contains(q));
                },
                onSelected: (v) => _invoicePaymentNote.text = v,
                fieldViewBuilder:
                    (context, controller, focusNode, onFieldSubmitted) {
                  return TextField(
                    controller: controller,
                    focusNode: focusNode,
                    decoration:
                        const InputDecoration(labelText: 'Note (optional)'),
                    onSubmitted: (_) => onFieldSubmitted(),
                    onTap: () {
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
                        constraints:
                            const BoxConstraints(maxHeight: 200, minWidth: 200),
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
            if (_invoicePaymentType == PaymentType.cheque) ...[
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                    child: TextField(
                        controller: _invoicePaymentBank,
                        decoration: const InputDecoration(labelText: 'Bank'))),
                const SizedBox(width: 12),
                Expanded(
                    child: TextField(
                        controller: _invoicePaymentCheque,
                        decoration:
                            const InputDecoration(labelText: 'Cheque No'))),
              ]),
            ] else if (_invoicePaymentType == PaymentType.bank) ...[
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                    child: TextField(
                        controller: _invoicePaymentBank,
                        decoration: const InputDecoration(labelText: 'Bank'))),
                const SizedBox(width: 12),
                Expanded(
                    child: TextField(
                        controller: _invoicePaymentTxn,
                        decoration:
                            const InputDecoration(labelText: 'Txn ID'))),
                const SizedBox(width: 12),
                SizedBox(
                  width: 180,
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('invoice-pay-mode-$_invoicePaymentBankMode'),
                    initialValue: _invoicePaymentBankMode,
                    items: const [
                      DropdownMenuItem(
                          value: 'Deposit', child: Text('Deposit')),
                      DropdownMenuItem(
                          value: 'Transfer', child: Text('Transfer')),
                    ],
                    onChanged: (v) => setState(
                        () => _invoicePaymentBankMode = v ?? 'Transfer'),
                    decoration: const InputDecoration(labelText: 'Mode'),
                  ),
                ),
              ]),
            ],
          ],
        ),
      ),
    );
  }

  Widget _itemCard(ItemLine l) {
    Widget buildCard(StateSetter rowSetState) => AppSoftCard(
        key: ValueKey('line-${identityHashCode(l)}'),
        backgroundColor: Colors.white,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                  child: Text(l.typeLabel,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: const Color(0xFF172033),
                          ))),
              IconButton(
                tooltip: 'Add another ${l.typeLabel}',
                icon: const Icon(Icons.add),
                onPressed: () {
                  setState(() {
                    final idx = _lines.indexOf(l);
                    _lines.insert(idx + 1, ItemLine(l.typeLabel));
                  });
                  _bumpMobileDraftTick();
                },
              ),
              Builder(builder: (_) {
                final sameCount =
                    _lines.where((x) => x.typeLabel == l.typeLabel).length;
                final canDelete = sameCount > 1;
                return IconButton(
                  tooltip: canDelete
                      ? 'Remove this ${l.typeLabel}'
                      : 'Cannot remove the last ${l.typeLabel}',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: canDelete
                      ? () {
                          setState(() {
                            _lines.remove(l);
                          });
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            l.dispose();
                          });
                          _bumpMobileDraftTick();
                        }
                      : null,
                );
              }),
            ]),
            const SizedBox(height: 8),
            RawAutocomplete<String>(
              key: ValueKey(
                  'brand-${l.typeLabel}-${identityHashCode(l)}-${_lines.indexOf(l)}'),
              textEditingController: l.brandCtrl,
              focusNode: l.brandFocus,
              optionsViewBuilder: _stringOptionsView,
              optionsBuilder: (t) => _brandOptionsForLine(l, t.text),
              onSelected: (v) {
                rowSetState(() {
                  l.brand = v;
                  l.brandCtrl.text = v;
                });
                _bumpMobileDraftTick();
              },
              fieldViewBuilder: (_, controller, focus, __) {
                return TextField(
                    controller: controller,
                    focusNode: focus,
                    decoration:
                        const InputDecoration(labelText: 'Brand / company'),
                    onChanged: (v) {
                      l.brand = v;
                      _bumpMobileDraftTick();
                    });
              },
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                  child: TextField(
                controller: l.qtyCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))
                ],
                decoration: const InputDecoration(labelText: 'Qty'),
                onChanged: (v) {
                  final n = int.tryParse(v) ?? 0;
                  if (n != l.qty) {
                    rowSetState(() => l.qty = n);
                    _bumpMobileDraftTick();
                  }
                },
              )),
              const SizedBox(width: 8),
              Expanded(
                  child: RawAutocomplete<String>(
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
                  if (n != l.rate) {
                    rowSetState(() => l.rate = n);
                    _bumpMobileDraftTick();
                  }
                },
                fieldViewBuilder:
                    (context, controller, focusNode, onFieldSubmitted) {
                  return TextField(
                    controller: controller,
                    focusNode: focusNode,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9]'))
                    ],
                    decoration: const InputDecoration(labelText: 'Rate'),
                    onChanged: (v) {
                      final n = double.tryParse(v) ?? 0;
                      if (n != l.rate) {
                        rowSetState(() => l.rate = n);
                        _bumpMobileDraftTick();
                      }
                    },
                    onSubmitted: (_) => onFieldSubmitted(),
                    onTap: () {
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
                        constraints:
                            const BoxConstraints(maxHeight: 180, minWidth: 140),
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
              AppMetaChip(
                text: 'Rs ${fmt0(l.amount)}',
                backgroundColor: const Color(0xFFF3F6FA),
                borderColor: const Color(0xFFDCE5EE),
                foregroundColor: const Color(0xFF51607A),
              ),
            ]),
          ]),
        ));
    return buildCard((fn) => setState(fn));
  }
}

class _ReturnInvoiceResult {
  final DateTime date;
  final Map<ItemLine, int> quantities;

  const _ReturnInvoiceResult({
    required this.date,
    required this.quantities,
  });
}

class _ReturnInvoiceDialog extends StatefulWidget {
  final int invoiceNo;
  final List<ItemLine> lines;

  const _ReturnInvoiceDialog({
    required this.invoiceNo,
    required this.lines,
  });

  @override
  State<_ReturnInvoiceDialog> createState() => _ReturnInvoiceDialogState();
}

class _ReturnInvoiceDialogState extends State<_ReturnInvoiceDialog> {
  late DateTime _returnDate;
  late final TextEditingController _dateController;
  late final Map<ItemLine, TextEditingController> _quantityControllers;

  @override
  void initState() {
    super.initState();
    _returnDate = DateTime.now();
    _dateController = TextEditingController(
      text: formatInvoiceDate(_returnDate),
    );
    _quantityControllers = {
      for (final line in widget.lines) line: TextEditingController(),
    };
  }

  @override
  void dispose() {
    _dateController.dispose();
    for (final controller in _quantityControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _returnDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _returnDate = picked;
      _dateController.text = formatInvoiceDate(picked);
    });
  }

  void _submit() {
    final quantities = <ItemLine, int>{};
    for (final line in widget.lines) {
      final quantity =
          int.tryParse(_quantityControllers[line]?.text.trim() ?? '') ?? 0;
      if (quantity < 0 || quantity > line.qty) {
        showErr(
          context,
          'Return quantity for ${line.typeLabel} must be 1 to ${line.qty}.',
        );
        return;
      }
      if (quantity > 0) quantities[line] = quantity;
    }
    if (quantities.isEmpty) {
      showErr(context, 'Enter at least one returned quantity.');
      return;
    }
    Navigator.of(context).pop(
      _ReturnInvoiceResult(date: _returnDate, quantities: quantities),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Return Invoice #${widget.invoiceNo}'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _dateController,
                readOnly: true,
                decoration: const InputDecoration(
                  labelText: 'Return date',
                  suffixIcon: Icon(Icons.calendar_today_outlined),
                ),
                onTap: _pickDate,
              ),
              const SizedBox(height: 12),
              for (final line in widget.lines) ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        [
                          line.typeLabel,
                          if (line.brand.trim().isNotEmpty) line.brand.trim(),
                          'sold ${line.qty}',
                        ].join(' - '),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      width: 110,
                      child: TextField(
                        controller: _quantityControllers[line],
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9]')),
                        ],
                        decoration: const InputDecoration(
                          labelText: 'Return qty',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          icon: const Icon(Icons.assignment_return_outlined),
          onPressed: _submit,
          label: const Text('Save return'),
        ),
      ],
    );
  }
}
