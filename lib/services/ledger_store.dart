import 'dart:convert';
import 'dart:io';
import 'package:intl/intl.dart';

import '../core/app_bus.dart';
import '../models/ledger_entry.dart';
import '../utils/date.dart';
import 'paths.dart';

class LedgerStore {
  static String _norm(String name) => name.trim().toLowerCase();

  static String _slug(String name) {
    final s = name.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
    return s.replaceAll(RegExp(r'^_+|_+$'), '').replaceAll(RegExp(r'_+'), '_');
  }

  static String _idPrefix(String ledgerName) {
    final n = _norm(ledgerName);
    if (n == 'surjani ledger') return 'SL';
    if (n == 'factory ledger') return 'FL';
    final words = ledgerName.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return 'LG';
    final initials = words.map((w) => w[0]).join().toUpperCase();
    return (initials.length >= 3 ? initials.substring(0, 3) : initials).padRight(2, 'G');
  }

  static String openingIdFor(String ledgerName) => '${_idPrefix(ledgerName)}-OPEN';

  static Future<File> _file(String ledgerName) async {
    final base = await baseDir();
    if (_norm(ledgerName) == 'surjani ledger') {
      // Keep legacy file for backward compatibility.
      return File('${base.path}${Platform.pathSeparator}surjani_ledger.json');
    }
    final slug = _slug(ledgerName);
    final safeSlug = slug.isEmpty ? 'ledger' : slug;
    return File('${base.path}${Platform.pathSeparator}ledger_$safeSlug.json');
  }

  static Future<List<LedgerEntry>> loadAll(String ledgerName) async {
    try {
      final f = await _file(ledgerName);
      if (!await f.exists()) return [];
      final list = jsonDecode(await f.readAsString()) as List;
      final entries = list.map((e) => LedgerEntry.fromJson(e as Map<String, dynamic>)).toList();
      entries.sort((a, b) {
        final da = parseInvoiceDate(a.date);
        final db = parseInvoiceDate(b.date);
        final c = da.compareTo(db);
        return c != 0 ? c : a.id.compareTo(b.id);
      });
      return entries;
    } catch (_) {
      return [];
    }
  }

  static Future<void> saveAll(String ledgerName, List<LedgerEntry> entries) async {
    final f = await _file(ledgerName);
    await f.writeAsString(jsonEncode(entries.map((e) => e.toJson()).toList()));
    AppBus.bump();
  }

  static Future<String> nextId(String ledgerName, [DateTime? when]) async {
    final base = when ?? DateTime.now();
    final ymd = DateFormat('yyyyMMdd').format(base);
    final prefix = _idPrefix(ledgerName);
    final all = await loadAll(ledgerName);
    final sameDay = all.where((e) => e.id.startsWith('$prefix-$ymd-')).toList();
    var maxNum = 0;
    for (final e in sameDay) {
      final parts = e.id.split('-');
      if (parts.length >= 3) {
        final n = int.tryParse(parts.last) ?? 0;
        if (n > maxNum) maxNum = n;
      }
    }
    return '$prefix-$ymd-${(maxNum + 1).toString().padLeft(3, '0')}';
  }

  static Future<void> add(String ledgerName, LedgerEntry entry) async {
    final all = await loadAll(ledgerName);
    all.add(entry);
    await saveAll(ledgerName, all);
  }

  static Future<void> upsert(String ledgerName, LedgerEntry entry) async {
    final all = await loadAll(ledgerName);
    final idx = all.indexWhere((e) => e.id == entry.id);
    if (idx >= 0) {
      all[idx] = entry;
    } else {
      all.add(entry);
    }
    await saveAll(ledgerName, all);
  }

  static Future<void> delete(String ledgerName, String id) async {
    final all = await loadAll(ledgerName);
    all.removeWhere((e) => e.id == id);
    await saveAll(ledgerName, all);
  }
}
