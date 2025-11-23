import 'dart:convert';
import 'dart:io';
import '../core/app_bus.dart';
import 'package:intl/intl.dart';
import '../models/invoice.dart';
import '../models/customer.dart';
import '../models/payment.dart';
import 'paths.dart';

class Store {
  static Future<File> _file() async {
    final b = await baseDir();
    return File('${b.path}${Platform.pathSeparator}invoices.json');
  }
  static Future<List<Invoice>> loadAll() async {
    try {
      final f = await _file();
      if (!await f.exists()) return [];
      final list = jsonDecode(await f.readAsString()) as List;
      return list.map((e) => Invoice.fromJson(e)).toList();
    } catch (_) { return []; }
  }
  static Future<void> saveAll(List<Invoice> invs) async {
    final f = await _file();
    await f.writeAsString(jsonEncode(invs.map((e) => e.toJson()).toList()));
    AppBus.bump();
  }
  static Future<int> nextSerial() async {
    final all = await loadAll();
    if (all.isEmpty) return 1;
    final used = all.map((e) => e.sNo).toSet();
    int n = 1;
    while (used.contains(n)) { n++; }
    return n;
  }
  static Future<void> updatePaid(int sNo, double paid) async {
    final all = await loadAll();
    final idx = all.indexWhere((e) => e.sNo == sNo);
    if (idx >= 0) { all[idx].paid = paid.clamp(0, all[idx].balance); await saveAll(all); }
  }
  static Future<Invoice?> deleteInvoice(int sNo) async {
    final all = await loadAll();
    final idx = all.indexWhere((e) => e.sNo == sNo);
    if (idx < 0) return null;
    final removed = all.removeAt(idx);
    await saveAll(all);
    AppBus.bump();
    return removed;
  }
}

class CustomerStore {
  static Future<File> _file() async {
    final b = await baseDir();
    return File('${b.path}${Platform.pathSeparator}customers.json');
  }
  static Future<List<Customer>> loadAll() async {
    try {
      final f = await _file();
      if (!await f.exists()) return [];
      final list = jsonDecode(await f.readAsString()) as List;
      return list.map((e) => Customer.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) { return []; }
  }
  static Future<void> saveAll(List<Customer> cs) async {
    final f = await _file();
    await f.writeAsString(jsonEncode(cs.map((e) => e.toJson()).toList()));
    AppBus.bump();
  }
  static Future<List<Customer>> loadActive() async => (await loadAll()).where((c) => c.active).toList();
  static Future<bool> setActive(String id, bool active) async {
    final all = await loadAll();
    final idx = all.indexWhere((x) => x.id.trim().toLowerCase() == id.trim().toLowerCase());
    if (idx < 0) return false;
    all[idx].active = active;
    await saveAll(all);
    return true;
  }
  static Future<Customer?> findById(String id) async {
    final all = await loadAll();
    try { return all.firstWhere((c) => c.id.trim().toLowerCase() == id.trim().toLowerCase()); } catch (_) { return null; }
  }
  static Future<Customer?> findByName(String name) async {
    final all = await loadAll();
    try { return all.firstWhere((c) => c.name.trim().toLowerCase() == name.trim().toLowerCase()); } catch (_) { return null; }
  }
  static Future<Customer?> findByContact(String contact) async {
    final all = await loadAll();
    try { return all.firstWhere((c) => c.contact.trim() == contact.trim()); } catch (_) { return null; }
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
  static Future<bool> addCustomer(String id, String name, String phone) async {
    id = id.trim(); name = name.trim(); phone = phone.trim();
    if (id.isEmpty || name.isEmpty) return false;
    final all = await loadAll();
    final idx = all.indexWhere((x) => x.id.trim().toLowerCase() == id.trim().toLowerCase());
    if (idx >= 0) {
      all[idx].name = name; all[idx].contact = phone; await saveAll(all); return false;
    }
    all.add(Customer(id: id, name: name, contact: phone, active: true));
    await saveAll(all);
    return true;
  }
  static Future<bool> updateNamePhone(String id, String name, String phone) async {
    final all = await loadAll();
    final idx = all.indexWhere((x) => x.id.trim().toLowerCase() == id.trim().toLowerCase());
    if (idx < 0) return false;
    all[idx].name = name.trim(); all[idx].contact = phone.trim(); await saveAll(all); return true;
  }
  static Future<void> upsertFixed(Customer c) async {
    final all = await loadAll();
    final idx = all.indexWhere((x) => x.id.trim().toLowerCase() == c.id.trim().toLowerCase());
    if (idx >= 0) { c.active = all[idx].active; all[idx] = c; await saveAll(all); return; }
    all.add(Customer(id: c.id, name: c.name, contact: c.contact, active: true)); await saveAll(all);
  }
  static Future<void> deleteById(String id) async { await setActive(id, false); }
}

class PaymentStore {
  static Future<File> _file() async {
    final b = await baseDir();
    return File('${b.path}${Platform.pathSeparator}payments.json');
  }
  static Future<List<PaymentEntry>> loadAll() async {
    try {
      final f = await _file();
      if (!await f.exists()) return [];
      final list = jsonDecode(await f.readAsString()) as List;
      return list.map((e) => PaymentEntry.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) { return []; }
  }
  static Future<void> saveAll(List<PaymentEntry> entries) async {
    final f = await _file();
    await f.writeAsString(jsonEncode(entries.map((e) => e.toJson()).toList()));
    AppBus.bump();
  }
  static Future<void> addAll(List<PaymentEntry> entries) async {
    final all = await loadAll();
    all.addAll(entries);
    await saveAll(all);
    AppBus.bump();
  }
  static Future<List<PaymentEntry>> forInvoice(int invoiceNo) async {
    final all = await loadAll();
    return all.where((e) => e.invoiceNo == invoiceNo).toList();
  }
  static Future<double> clearedSumForInvoice(int invoiceNo) async {
    final list = await forInvoice(invoiceNo);
    return list.where((e) => e.status == PaymentStatus.cleared).map((e) => e.amount).fold<double>(0.0, (s, a) => s + a);
  }
  static Future<void> updateStatusForGroup(String groupId, PaymentStatus status) async {
    final all = await loadAll();
    bool changed = false;
    for (final e in all) {
      if (e.groupId == groupId && e.status != status) { e.status = status; changed = true; }
    }
    if (changed) { await saveAll(all); AppBus.bump(); }
  }
  static Future<bool> deleteById(String id) async {
    final all = await loadAll();
    final before = all.length;
    all.removeWhere((e) => e.id == id);
    final changed = all.length != before;
    if (changed) { await saveAll(all); AppBus.bump(); }
    return changed;
  }
  static Future<List<PaymentEntry>> deleteForInvoice(int invoiceNo) async {
    final all = await loadAll();
    final removed = all.where((e) => e.invoiceNo == invoiceNo).toList();
    if (removed.isEmpty) return const <PaymentEntry>[];
    all.removeWhere((e) => e.invoiceNo == invoiceNo);
    await saveAll(all);
    AppBus.bump();
    return removed;
  }
  static Future<String> nextGroupId([DateTime? when]) async {
    final base = when ?? DateTime.now();
    final all = await loadAll();
    final ymd = DateFormat('yyyyMMdd').format(base);
    final today = all.where((e) => e.groupId.startsWith('G-$ymd-')).toList();
    int maxNum = 0;
    for (final e in today) {
      final parts = e.groupId.split('-');
      if (parts.length >= 3) {
        final n = int.tryParse(parts.last) ?? 0;
        if (n > maxNum) maxNum = n;
      }
    }
    return 'G-$ymd-${(maxNum + 1).toString().padLeft(2, '0')}';
  }
  static Future<String> nextBatchId([DateTime? when]) async {
    final base = when ?? DateTime.now();
    final all = await loadAll();
    final ymd = DateFormat('yyyyMMdd').format(base);
    final today = all.where((e) => e.batchId.startsWith('$ymd-')).toList();
    int maxNum = 0;
    for (final e in today) {
      final parts = e.batchId.split('-');
      if (parts.length >= 2) {
        final n = int.tryParse(parts.last) ?? 0;
        if (n > maxNum) maxNum = n;
      }
    }
    return '$ymd-${(maxNum + 1).toString().padLeft(2, '0')}';
  }
}

Future<void> syncInvoicesPaidFromPayments() async {
  final invoices = await Store.loadAll();
  if (invoices.isEmpty) return;
  bool changed = false;
  final allPayments = await PaymentStore.loadAll();
  for (int i = 0; i < invoices.length; i++) {
    final inv = invoices[i];
    final cleared = allPayments
        .where((e) => e.invoiceNo == inv.sNo && e.status == PaymentStatus.cleared)
        .map((e) => e.amount)
        .fold<double>(0.0, (s, a) => s + a);
    final newPaid = cleared.clamp(0.0, inv.balance).toDouble();
    if ((newPaid - inv.paid).abs() > 0.0001) { invoices[i].paid = newPaid; changed = true; }
  }
  if (changed) await Store.saveAll(invoices);
}
