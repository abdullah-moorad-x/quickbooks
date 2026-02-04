import 'dart:convert';
import 'dart:io';
import 'package:intl/intl.dart';

import '../core/app_bus.dart';
import '../utils/date.dart';
import 'paths.dart';
import '../models/surjani_ledger_entry.dart';

class SurjaniLedgerStore {
  static Future<File> _file() async {
    final base = await baseDir();
    return File('${base.path}${Platform.pathSeparator}surjani_ledger.json');
  }

  static Future<List<SurjaniLedgerEntry>> loadAll() async {
    try {
      final f = await _file();
      if (!await f.exists()) return [];
      final list = jsonDecode(await f.readAsString()) as List;
      final entries = list.map((e) => SurjaniLedgerEntry.fromJson(e as Map<String, dynamic>)).toList();
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

  static Future<void> saveAll(List<SurjaniLedgerEntry> entries) async {
    final f = await _file();
    await f.writeAsString(jsonEncode(entries.map((e) => e.toJson()).toList()));
    AppBus.bump();
  }

  static Future<String> nextId([DateTime? when]) async {
    final base = when ?? DateTime.now();
    final ymd = DateFormat('yyyyMMdd').format(base);
    final all = await loadAll();
    final sameDay = all.where((e) => e.id.startsWith('SL-$ymd-')).toList();
    var maxNum = 0;
    for (final e in sameDay) {
      final parts = e.id.split('-');
      if (parts.length >= 3) {
        final n = int.tryParse(parts.last) ?? 0;
        if (n > maxNum) maxNum = n;
      }
    }
    return 'SL-$ymd-${(maxNum + 1).toString().padLeft(3, '0')}';
  }

  static Future<void> add(SurjaniLedgerEntry entry) async {
    final all = await loadAll();
    all.add(entry);
    await saveAll(all);
  }

  static Future<void> upsert(SurjaniLedgerEntry entry) async {
    final all = await loadAll();
    final idx = all.indexWhere((e) => e.id == entry.id);
    if (idx >= 0) {
      all[idx] = entry;
    } else {
      all.add(entry);
    }
    await saveAll(all);
  }

  static Future<void> delete(String id) async {
    final all = await loadAll();
    all.removeWhere((e) => e.id == id);
    await saveAll(all);
  }

  static Future<void> clearAll() async {
    final f = await _file();
    if (await f.exists()) await f.delete();
    AppBus.bump();
  }
}
