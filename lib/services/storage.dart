import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../core/app_bus.dart';
import '../models/invoice.dart';
import '../models/customer.dart';
import '../models/payment.dart';
import 'paths.dart';
import 'sync_change_log_store.dart';
import 'package:intl/intl.dart';
import '../utils/date.dart';

String _stableJson(Map<String, dynamic> json) => jsonEncode(json);

List<dynamic> _decodeJsonList(String source) => jsonDecode(source) as List;

String _encodeJson(Object value) => jsonEncode(value);

Future<void> _writeJson(File file, Object value) async {
  final encoded = await compute(_encodeJson, value);
  await file.writeAsString(encoded);
}

Future<List<dynamic>> _readJsonList(File f) async {
  return compute(_decodeJsonList, await f.readAsString());
}

Future<List<Invoice>> _readInvoicesFromDisk(File f) async {
  try {
    if (!await f.exists()) return <Invoice>[];
    final list = await _readJsonList(f);
    return list
        .map((e) => Invoice.fromJson(e as Map<String, dynamic>))
        .toList();
  } catch (_) {
    return <Invoice>[];
  }
}

Future<List<Customer>> _readCustomersFromDisk(File f) async {
  try {
    if (!await f.exists()) return <Customer>[];
    final list = await _readJsonList(f);
    return list
        .map((e) => Customer.fromJson(e as Map<String, dynamic>))
        .toList();
  } catch (_) {
    return <Customer>[];
  }
}

Future<List<PaymentEntry>> _readPaymentsFromDisk(File f) async {
  try {
    if (!await f.exists()) return <PaymentEntry>[];
    final list = await _readJsonList(f);
    if (list.any((e) => e is Map && e.containsKey('invoiceNo'))) {
      return <PaymentEntry>[];
    }
    return list
        .map((e) => PaymentEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  } catch (_) {
    return <PaymentEntry>[];
  }
}

List<ItemLine> _cloneLines(List<ItemLine> lines) {
  return lines
      .map(
        (l) => ItemLine(l.typeLabel, brand: l.brand, qty: l.qty, rate: l.rate),
      )
      .toList();
}

List<Invoice> _cloneInvoices(List<Invoice> invoices) {
  return invoices
      .map(
        (inv) => Invoice(
          sNo: inv.sNo,
          date: inv.date,
          customer: inv.customer,
          customerDisplay: inv.customerDisplay,
          customerId: inv.customerId,
          contact: inv.contact,
          address: inv.address,
          site: inv.site,
          lines: _cloneLines(inv.lines),
          cartage: inv.cartage,
          paid: inv.paid,
          walkIn: inv.walkIn,
          isReturn: inv.isReturn,
          returnOfInvoiceNo: inv.returnOfInvoiceNo,
          sourceOrderId: inv.sourceOrderId,
          sourceReturnId: inv.sourceReturnId,
          walkInPaymentType: inv.walkInPaymentType,
          walkInPaymentNote: inv.walkInPaymentNote,
          walkInBank: inv.walkInBank,
          walkInChequeNo: inv.walkInChequeNo,
          walkInTxnId: inv.walkInTxnId,
          walkInBankMode: inv.walkInBankMode,
        ),
      )
      .toList();
}

List<Customer> _cloneCustomers(List<Customer> customers) {
  return customers
      .map(
        (c) => Customer(
          id: c.id,
          name: c.name,
          displayName: c.displayName,
          contact: c.contact,
          active: c.active,
        ),
      )
      .toList();
}

List<PaymentEntry> _clonePayments(List<PaymentEntry> entries) {
  return entries
      .map(
        (e) => PaymentEntry(
          id: e.id,
          date: e.date,
          customerId: e.customerId,
          customer: e.customer,
          type: e.type,
          amount: e.amount,
          discount: e.discount,
          note: e.note,
          chequeNo: e.chequeNo,
          bank: e.bank,
          txnId: e.txnId,
          bankMode: e.bankMode,
        ),
      )
      .toList();
}

class Store {
  static List<Invoice>? _cache;

  static Future<File> _file() async {
    final b = await baseDir();
    return File('${b.path}${Platform.pathSeparator}invoices.json');
  }

  static Future<List<Invoice>> loadAll() async {
    final cached = _cache;
    if (cached != null) return _cloneInvoices(cached);
    try {
      final f = await _file();
      if (!await f.exists()) {
        _cache = <Invoice>[];
        return [];
      }
      final list = await _readJsonList(f);
      final loaded = list.map((e) => Invoice.fromJson(e)).toList();
      _cache = _cloneInvoices(loaded);
      return _cloneInvoices(_cache!);
    } catch (_) {
      _cache = <Invoice>[];
      return [];
    }
  }

  static Future<void> saveAll(List<Invoice> invs) async {
    final f = await _file();
    final previous = _cache == null ? await _readInvoicesFromDisk(f) : _cache!;
    _cache = _cloneInvoices(invs);
    await _writeJson(f, _cache!.map((e) => e.toJson()).toList());
    await SyncChangeLogStore.recordDiff(
      entityType: 'invoice',
      previous: {
        for (final invoice in previous)
          invoice.sNo.toString(): _stableJson(invoice.toJson()),
      },
      next: {
        for (final invoice in _cache!)
          invoice.sNo.toString(): _stableJson(invoice.toJson()),
      },
    );
    AppBus.bump();
  }

  static Future<void> upsertInvoice(Invoice inv) async {
    final f = await _file();
    final current = _cache == null ? await _readInvoicesFromDisk(f) : _cache!;
    final next = _cloneInvoices(current);
    final idx = next.indexWhere((x) => x.sNo == inv.sNo);
    final previousJson = idx >= 0 ? _stableJson(next[idx].toJson()) : null;
    final nextJson = _stableJson(inv.toJson());
    if (previousJson == nextJson) return;
    final saved = Invoice(
      sNo: inv.sNo,
      date: inv.date,
      customer: inv.customer,
      customerDisplay: inv.customerDisplay,
      customerId: inv.customerId,
      contact: inv.contact,
      address: inv.address,
      site: inv.site,
      lines: _cloneLines(inv.lines),
      cartage: inv.cartage,
      paid: inv.paid,
      walkIn: inv.walkIn,
      isReturn: inv.isReturn,
      returnOfInvoiceNo: inv.returnOfInvoiceNo,
      sourceOrderId: inv.sourceOrderId,
      sourceReturnId: inv.sourceReturnId,
      walkInPaymentType: inv.walkInPaymentType,
      walkInPaymentNote: inv.walkInPaymentNote,
      walkInBank: inv.walkInBank,
      walkInChequeNo: inv.walkInChequeNo,
      walkInTxnId: inv.walkInTxnId,
      walkInBankMode: inv.walkInBankMode,
    );
    if (idx >= 0) {
      next[idx] = saved;
    } else {
      next.add(saved);
    }
    _cache = next;
    await _writeJson(f, _cache!.map((e) => e.toJson()).toList());
    await SyncChangeLogStore.recordChange(
      entityType: 'invoice',
      entityId: inv.sNo.toString(),
      action: 'upsert',
    );
    AppBus.bump();
  }

  static Future<int> nextSerial() async {
    final all = await loadAll();
    if (all.isEmpty) return 1;
    var maxSNo = 0;
    for (final e in all) {
      if (e.sNo > maxSNo) maxSNo = e.sNo;
    }
    return maxSNo + 1;
  }

  static Future<void> updatePaid(int sNo, double paid) async {
    final all = await loadAll();
    final idx = all.indexWhere((e) => e.sNo == sNo);
    if (idx >= 0) {
      all[idx].paid = all[idx].balance <= 0
          ? 0
          : paid.clamp(0, all[idx].balance);
      await saveAll(all);
    }
  }

  static Future<Invoice?> deleteInvoice(int sNo) async {
    final all = await loadAll();
    final idx = all.indexWhere((e) => e.sNo == sNo);
    if (idx < 0) return null;
    final removed = all.removeAt(idx);
    await saveAll(all);
    return removed;
  }
}

class CustomerStore {
  static List<Customer>? _cache;

  static Future<File> _file() async {
    final b = await baseDir();
    return File('${b.path}${Platform.pathSeparator}customers.json');
  }

  static Future<List<Customer>> loadAll() async {
    final cached = _cache;
    if (cached != null) return _cloneCustomers(cached);
    try {
      final f = await _file();
      if (!await f.exists()) {
        _cache = <Customer>[];
        return [];
      }
      final list = await _readJsonList(f);
      final loaded = list
          .map((e) => Customer.fromJson(e as Map<String, dynamic>))
          .toList();
      _cache = _cloneCustomers(loaded);
      return _cloneCustomers(_cache!);
    } catch (_) {
      _cache = <Customer>[];
      return [];
    }
  }

  static Future<void> saveAll(List<Customer> cs) async {
    final f = await _file();
    final previous = _cache == null ? await _readCustomersFromDisk(f) : _cache!;
    _cache = _cloneCustomers(cs);
    await _writeJson(f, _cache!.map((e) => e.toJson()).toList());
    await SyncChangeLogStore.recordDiff(
      entityType: 'customer',
      previous: {
        for (final customer in previous)
          _customerSyncId(customer): _stableJson(customer.toJson()),
      },
      next: {
        for (final customer in _cache!)
          _customerSyncId(customer): _stableJson(customer.toJson()),
      },
    );
    AppBus.bump();
  }

  static String _customerSyncId(Customer customer) {
    final id = customer.id.trim();
    if (id.isNotEmpty) return id;
    return customer.name.trim().toLowerCase();
  }

  static Future<List<Customer>> loadActive() async =>
      (await loadAll()).where((c) => c.active).toList();
  static Future<bool> setActive(String id, bool active) async {
    final all = await loadAll();
    final idx = all.indexWhere(
      (x) => x.id.trim().toLowerCase() == id.trim().toLowerCase(),
    );
    if (idx < 0) return false;
    all[idx].active = active;
    await saveAll(all);
    return true;
  }

  static Future<Customer?> findById(String id) async {
    final all = await loadAll();
    try {
      return all.firstWhere(
        (c) => c.id.trim().toLowerCase() == id.trim().toLowerCase(),
      );
    } catch (_) {
      return null;
    }
  }

  static Future<Customer?> findByName(String name) async {
    final all = await loadAll();
    final needle = name.trim().toLowerCase();
    try {
      return all.firstWhere((c) {
        final internal = c.name.trim().toLowerCase();
        final visible = c.displayName.trim().toLowerCase();
        return internal == needle || visible == needle;
      });
    } catch (_) {
      return null;
    }
  }

  static Future<Customer?> findByContact(String contact) async {
    final all = await loadAll();
    try {
      return all.firstWhere((c) => c.contact.trim() == contact.trim());
    } catch (_) {
      return null;
    }
  }

  static Future<String> nextCustomerId() async {
    final all = await loadAll();
    final re = RegExp(r'^CS(\d+)$');
    var maxNum = 0;
    for (final c in all) {
      final m = re.firstMatch(c.id.trim());
      if (m != null) {
        final n = int.tryParse(m.group(1)!) ?? 0;
        if (n > maxNum) maxNum = n;
      }
    }
    final next = maxNum + 1;
    return 'CS${next.toString().padLeft(5, '0')}';
  }

  static Future<bool> addCustomer(
    String id,
    String name,
    String phone, {
    String? displayName,
  }) async {
    id = id.trim();
    name = name.trim();
    phone = phone.trim();
    displayName = (displayName ?? name).trim();
    if (id.isEmpty || name.isEmpty) return false;
    final all = await loadAll();
    final idx = all.indexWhere(
      (x) => x.id.trim().toLowerCase() == id.trim().toLowerCase(),
    );
    if (idx >= 0) {
      all[idx].name = name;
      all[idx].displayName = displayName;
      all[idx].contact = phone;
      await saveAll(all);
      return false;
    }
    all.add(
      Customer(
        id: id,
        name: name,
        displayName: displayName,
        contact: phone,
        active: true,
      ),
    );
    await saveAll(all);
    return true;
  }

  static Future<bool> updateNamePhone(
    String id,
    String name,
    String phone, {
    String? displayName,
  }) async {
    final all = await loadAll();
    final idx = all.indexWhere(
      (x) => x.id.trim().toLowerCase() == id.trim().toLowerCase(),
    );
    if (idx < 0) return false;
    final updatedId = all[idx].id.trim();
    final updatedIdNorm = updatedId.toLowerCase();
    final oldNameNorm = all[idx].name.trim().toLowerCase();
    final updatedName = name.trim();
    final updatedDisplay = (displayName ?? name).trim();
    final updatedPhone = phone.trim();

    all[idx].name = updatedName;
    all[idx].displayName = updatedDisplay;
    all[idx].contact = updatedPhone;
    await saveAll(all);

    final invoices = await Store.loadAll();
    bool invoicesChanged = false;
    for (final inv in invoices) {
      final invIdNorm = inv.customerId.trim().toLowerCase();
      final invNameNorm = inv.customer.trim().toLowerCase();
      final matches =
          (invIdNorm.isNotEmpty && invIdNorm == updatedIdNorm) ||
          (invIdNorm.isEmpty &&
              oldNameNorm.isNotEmpty &&
              invNameNorm == oldNameNorm);
      if (!matches) continue;

      final nextId = inv.customerId.trim().isEmpty ? updatedId : inv.customerId;
      if (inv.customer != updatedName ||
          (inv.customerDisplay ?? '') != updatedDisplay ||
          inv.contact != updatedPhone ||
          inv.customerId != nextId) {
        inv.customer = updatedName;
        inv.customerDisplay = updatedDisplay;
        inv.contact = updatedPhone;
        inv.customerId = nextId;
        invoicesChanged = true;
      }
    }
    if (invoicesChanged) {
      await Store.saveAll(invoices);
    }

    final payments = await PaymentStore.loadAll();
    bool paymentsChanged = false;
    final updatedPayments = <PaymentEntry>[];
    for (final p in payments) {
      final pIdNorm = p.customerId.trim().toLowerCase();
      final pNameNorm = p.customer.trim().toLowerCase();
      final matches =
          (pIdNorm.isNotEmpty && pIdNorm == updatedIdNorm) ||
          (pIdNorm.isEmpty &&
              oldNameNorm.isNotEmpty &&
              pNameNorm == oldNameNorm);
      if (!matches) {
        updatedPayments.add(p);
        continue;
      }

      final nextId = p.customerId.trim().isEmpty ? updatedId : p.customerId;
      if (p.customer == updatedName && p.customerId == nextId) {
        updatedPayments.add(p);
        continue;
      }
      paymentsChanged = true;
      updatedPayments.add(
        PaymentEntry(
          id: p.id,
          date: p.date,
          customerId: nextId,
          customer: updatedName,
          type: p.type,
          amount: p.amount,
          discount: p.discount,
          note: p.note,
          chequeNo: p.chequeNo,
          bank: p.bank,
          txnId: p.txnId,
          bankMode: p.bankMode,
        ),
      );
    }
    if (paymentsChanged) {
      await PaymentStore.saveAll(updatedPayments);
    }
    return true;
  }

  static Future<void> upsertFixed(Customer c) async {
    final all = await loadAll();
    final idx = all.indexWhere(
      (x) => x.id.trim().toLowerCase() == c.id.trim().toLowerCase(),
    );
    if (idx >= 0) {
      c.active = all[idx].active;
      all[idx] = c;
      await saveAll(all);
      return;
    }
    all.add(
      Customer(
        id: c.id,
        name: c.name,
        displayName: c.displayName,
        contact: c.contact,
        active: true,
      ),
    );
    await saveAll(all);
  }

  static Future<void> deleteById(String id) async {
    await setActive(id, false);
  }
}

class PaymentStore {
  static List<PaymentEntry>? _cache;

  static Future<File> _file() async {
    final b = await baseDir();
    return File('${b.path}${Platform.pathSeparator}payments.json');
  }

  static Future<List<PaymentEntry>> loadAll() async {
    final cached = _cache;
    if (cached != null) return _clonePayments(cached);
    try {
      final f = await _file();
      if (!await f.exists()) {
        _cache = <PaymentEntry>[];
        return [];
      }
      final list = await _readJsonList(f);
      final hasLegacy = list.any((e) => e is Map && e.containsKey('invoiceNo'));
      if (hasLegacy) {
        final migrated = await _migrateLegacy(list);
        await saveAll(migrated);
        return _clonePayments(_cache ?? migrated);
      }
      final entries = list
          .map((e) => PaymentEntry.fromJson(e as Map<String, dynamic>))
          .toList();
      final fixedCust = await _fillMissingCustomerIds(entries);
      final afterCust = fixedCust ?? entries;
      final fixedIds = await _fixPaymentIds(afterCust);
      final finalList = fixedIds ?? afterCust;
      if (!identical(finalList, entries)) {
        await saveAll(finalList);
        return _clonePayments(_cache ?? finalList);
      }
      _cache = _clonePayments(finalList);
      return _clonePayments(_cache!);
    } catch (_) {
      _cache = <PaymentEntry>[];
      return [];
    }
  }

  static Future<void> saveAll(List<PaymentEntry> entries) async {
    final f = await _file();
    final previous = _cache == null ? await _readPaymentsFromDisk(f) : _cache!;
    _cache = _clonePayments(entries);
    await _writeJson(f, _cache!.map((e) => e.toJson()).toList());
    await SyncChangeLogStore.recordDiff(
      entityType: 'payment',
      previous: {
        for (final payment in previous)
          _paymentSyncId(payment): _stableJson(payment.toJson()),
      },
      next: {
        for (final payment in _cache!)
          _paymentSyncId(payment): _stableJson(payment.toJson()),
      },
    );
    AppBus.bump();
  }

  static String _paymentSyncId(PaymentEntry payment) {
    final id = payment.id.trim();
    if (id.isNotEmpty) return id;
    return '${payment.date}|${payment.customerId}|${payment.customer}|${payment.amount}|${payment.type.name}';
  }

  static Future<String> nextPaymentId([DateTime? when]) async {
    final base = when ?? DateTime.now();
    final all = await loadAll();
    final ymd = DateFormat('yyyyMMdd').format(base);
    final sameDay = all.where((e) => e.id.startsWith('PAY-$ymd-')).toList();
    int maxNum = 0;
    for (final e in sameDay) {
      final parts = e.id.split('-');
      if (parts.length >= 3) {
        final n = int.tryParse(parts.last) ?? 0;
        if (n > maxNum) maxNum = n;
      }
    }
    return 'PAY-$ymd-${(maxNum + 1).toString().padLeft(3, '0')}';
  }

  static Future<void> add(PaymentEntry entry) async {
    final all = await loadAll();
    all.add(entry);
    await saveAll(all);
  }

  static Future<List<PaymentEntry>> entriesForCustomer(String key) async {
    final all = await loadAll();
    final norm = _normalizeCustomerKey(key);
    return all
        .where(
          (e) =>
              _normalizeCustomerKey(
                e.customerId.isNotEmpty ? e.customerId : e.customer,
              ) ==
              norm,
        )
        .toList();
  }

  static Future<double> totalForCustomer(String key) async {
    final list = await entriesForCustomer(key);
    return list
        .map((e) => e.effectiveAmount)
        .fold<double>(0.0, (s, a) => s + a);
  }

  static Future<bool> deleteById(String id) async {
    final all = await loadAll();
    final before = all.length;
    all.removeWhere((e) => e.id == id);
    final changed = all.length != before;
    if (changed) {
      await saveAll(all);
    }
    return changed;
  }

  // Compatibility: no-op for invoice-based deletions (legacy API)
  static Future<List<PaymentEntry>> deleteForInvoice(int invoiceNo) async {
    return const <PaymentEntry>[];
  }

  static String _normalizeCustomerKey(String s) => s.trim().toLowerCase();

  static Future<List<PaymentEntry>?> _fillMissingCustomerIds(
    List<PaymentEntry> entries,
  ) async {
    try {
      final invoices = await Store.loadAll();
      if (invoices.isEmpty) return null;
      final byName = <String, String>{};
      for (final inv in invoices) {
        final key = inv.customer.trim().toLowerCase();
        if (key.isEmpty) continue;
        if ((inv.customerId).trim().isNotEmpty) {
          byName.putIfAbsent(key, () => inv.customerId.trim());
        }
      }
      bool changed = false;
      final fixed = <PaymentEntry>[];
      for (final e in entries) {
        if (e.customerId.trim().isNotEmpty) {
          fixed.add(e);
          continue;
        }
        final k = e.customer.trim().toLowerCase();
        final cid = byName[k];
        if (cid != null && cid.isNotEmpty) {
          changed = true;
          fixed.add(_copyWithCustomer(e, cid, e.customer));
        } else {
          fixed.add(e);
        }
      }
      return changed ? fixed : null;
    } catch (_) {
      return null;
    }
  }

  static PaymentEntry _copyWithCustomer(
    PaymentEntry e,
    String customerId,
    String customerName,
  ) {
    return PaymentEntry(
      id: e.id,
      date: e.date,
      customerId: customerId,
      customer: customerName,
      type: e.type,
      amount: e.amount,
      discount: e.discount,
      note: e.note,
      chequeNo: e.chequeNo,
      bank: e.bank,
      txnId: e.txnId,
      bankMode: e.bankMode,
    );
  }

  static PaymentEntry _copyWithId(PaymentEntry e, String id) {
    return PaymentEntry(
      id: id,
      date: e.date,
      customerId: e.customerId,
      customer: e.customer,
      type: e.type,
      amount: e.amount,
      discount: e.discount,
      note: e.note,
      chequeNo: e.chequeNo,
      bank: e.bank,
      txnId: e.txnId,
      bankMode: e.bankMode,
    );
  }

  static Future<List<PaymentEntry>?> _fixPaymentIds(
    List<PaymentEntry> entries,
  ) async {
    // Ensure unique, formatted IDs per date (PAY-yyyymmdd-###).
    bool changed = false;
    final counters = <String, int>{}; // per-date max seq
    final seenSeq = <String, Set<int>>{};
    final sorted = [...entries];
    sorted.sort((a, b) {
      int cmp;
      try {
        cmp = parseInvoiceDate(a.date).compareTo(parseInvoiceDate(b.date));
      } catch (_) {
        cmp = a.date.compareTo(b.date);
      }
      if (cmp != 0) return cmp;
      return a.id.compareTo(b.id);
    });

    final fixed = <PaymentEntry>[];
    for (final e in sorted) {
      DateTime d;
      try {
        d = parseInvoiceDate(e.date);
      } catch (_) {
        d = DateTime.now();
      }
      final ymd = DateFormat('yyyyMMdd').format(d);

      int? seq;
      final m = RegExp(r'^PAY-(\d{8})-(\d+)$').firstMatch(e.id.trim());
      if (m != null && m.group(1) == ymd) {
        seq = int.tryParse(m.group(2)!);
      }
      final seen = seenSeq.putIfAbsent(ymd, () => <int>{});
      int next = counters[ymd] ?? 0;

      String idToUse = e.id;
      if (seq != null && !seen.contains(seq)) {
        // keep but update counter
        seen.add(seq);
        if (seq > next) next = seq;
      } else {
        // assign new sequence
        next += 1;
        seen.add(next);
        idToUse = 'PAY-$ymd-${next.toString().padLeft(3, '0')}';
        changed = true;
      }
      counters[ymd] = next;

      if (idToUse != e.id) {
        fixed.add(_copyWithId(e, idToUse));
      } else {
        fixed.add(e);
      }
    }
    return changed ? fixed : null;
  }

  static Future<List<PaymentEntry>> _migrateLegacy(List list) async {
    final entries = <PaymentEntry>[];
    final invoices = await Store.loadAll();
    final invMap = {for (final i in invoices) i.sNo: i};

    for (final raw in list) {
      if (raw is! Map<String, dynamic>) continue;
      try {
        final legacy = LegacyPaymentEntry.fromJson(raw);
        if (legacy.status != LegacyPaymentStatus.cleared) continue;
        final inv = invMap[legacy.invoiceNo];
        final custId = (inv?.customerId ?? '').toString();
        final custName = (inv?.customer ?? legacy.customer).toString();
        entries.add(
          PaymentEntry(
            id: legacy.id.isNotEmpty
                ? legacy.id
                : '${DateTime.now().microsecondsSinceEpoch}-${legacy.invoiceNo}',
            date: legacy.date,
            customerId: custId,
            customer: custName,
            type: legacy.type,
            amount: legacy.amount,
            chequeNo: legacy.chequeNo,
            bank: legacy.bank,
            txnId: legacy.txnId,
            bankMode: legacy.bankMode,
            note: 'Migrated from invoice payments',
          ),
        );
      } catch (_) {}
    }
    return entries;
  }
}

Future<void> syncInvoicesPaidFromPayments() async {
  final invoices = await Store.loadAll();
  if (invoices.isEmpty) return;
  bool changed = false;
  final allPayments = await PaymentStore.loadAll();

  // Walk-in invoices are always treated as fully paid on the spot and do not participate in khata allocations.
  for (final inv in invoices) {
    if (!inv.walkIn) continue;
    if (inv.balance <= 0) continue;
    final paidNow = inv.balance;
    if ((inv.paid - paidNow).abs() > 0.0001) {
      inv.paid = paidNow;
      changed = true;
    }
  }

  // Group payments by customer (id preferred, fallback to name)
  String keyOf(String id, String name) => id.trim().isNotEmpty
      ? id.trim().toLowerCase()
      : name.trim().toLowerCase();
  final byCustomer = <String, List<PaymentEntry>>{};
  for (final p in allPayments) {
    final k = keyOf(p.customerId, p.customer);
    (byCustomer[k] ??= []).add(p);
  }
  for (final list in byCustomer.values) {
    list.sort((a, b) => a.date.compareTo(b.date));
  }

  final invoicesByCustomer = <String, List<Invoice>>{};
  for (final inv in invoices) {
    if (inv.walkIn) continue;
    if (inv.balance <= 0) continue;
    final k = keyOf(inv.customerId, inv.customer);
    (invoicesByCustomer[k] ??= []).add(inv);
  }
  for (final list in invoicesByCustomer.values) {
    list.sort((a, b) {
      final d1 = a.date.compareTo(b.date);
      if (d1 != 0) return d1;
      return a.sNo.compareTo(b.sNo);
    });
  }

  for (final entry in byCustomer.entries) {
    final customerKey = entry.key;
    final payments = entry.value;
    final invs = invoicesByCustomer[customerKey] ?? const <Invoice>[];
    double available = payments
        .map((e) => e.effectiveAmount)
        .fold<double>(0.0, (s, a) => s + a);
    for (final inv in invs) {
      if (available <= 0) {
        if (inv.paid != 0) {
          inv.paid = 0;
          changed = true;
        }
        continue;
      }
      final alloc = available >= inv.balance ? inv.balance : available;
      if ((alloc - inv.paid).abs() > 0.0001) {
        inv.paid = alloc;
        changed = true;
      }
      available -= alloc;
    }
    // If payments exceed total balance, remaining stays unallocated; invoices already capped.
  }

  // Zero out paid for customers with no payments
  if (byCustomer.isEmpty) {
    for (final inv in invoices) {
      if (inv.walkIn) continue;
      if (inv.paid != 0) {
        inv.paid = 0;
        changed = true;
      }
    }
  } else {
    final customersWithPayments = byCustomer.keys.toSet();
    for (final entry in invoicesByCustomer.entries) {
      if (!customersWithPayments.contains(entry.key)) {
        for (final inv in entry.value) {
          if (inv.paid != 0) {
            inv.paid = 0;
            changed = true;
          }
        }
      }
    }
  }
  if (changed) await Store.saveAll(invoices);
}
