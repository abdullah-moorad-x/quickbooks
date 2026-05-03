import 'dart:convert';
import 'dart:io';

import 'paths.dart';

class LedgerCatalogItem {
  final String name;
  final String? password;
  final bool excludeFromProfitLoss;

  const LedgerCatalogItem({
    required this.name,
    this.password,
    this.excludeFromProfitLoss = false,
  });

  LedgerCatalogItem copyWith({
    String? name,
    String? password,
    bool clearPassword = false,
    bool? excludeFromProfitLoss,
  }) {
    return LedgerCatalogItem(
      name: name ?? this.name,
      password: clearPassword ? null : (password ?? this.password),
      excludeFromProfitLoss:
          excludeFromProfitLoss ?? this.excludeFromProfitLoss,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'password': password,
        'excludeFromProfitLoss': excludeFromProfitLoss,
      };

  static LedgerCatalogItem fromJson(Map<String, dynamic> json) {
    return LedgerCatalogItem(
      name: (json['name'] ?? '').toString(),
      password: (json['password'] ?? '').toString().trim().isEmpty
          ? null
          : (json['password'] ?? '').toString(),
      excludeFromProfitLoss: json['excludeFromProfitLoss'] == true,
    );
  }
}

class LedgerCatalogStore {
  static const String surjaniLedger = 'Surjani Ledger';
  static const String factoryLedger = 'Factory Ledger';

  static String _norm(String value) => value.trim().toLowerCase();

  static Future<File> _file() async {
    final base = await baseDir();
    return File('${base.path}${Platform.pathSeparator}ledger_catalog.json');
  }

  static List<LedgerCatalogItem> _withDefaults(List<LedgerCatalogItem> list) {
    final byName = <String, LedgerCatalogItem>{};
    for (final item in list) {
      final key = _norm(item.name);
      if (key.isEmpty) continue;
      byName[key] = LedgerCatalogItem(
        name: item.name.trim(),
        password: item.password,
        excludeFromProfitLoss: item.excludeFromProfitLoss,
      );
    }
    byName.putIfAbsent(_norm(surjaniLedger),
        () => const LedgerCatalogItem(name: surjaniLedger));
    byName.putIfAbsent(_norm(factoryLedger),
        () => const LedgerCatalogItem(name: factoryLedger));
    return byName.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  static Future<List<LedgerCatalogItem>> loadAll() async {
    try {
      final f = await _file();
      if (!await f.exists()) {
        final defaults = _withDefaults(const []);
        await saveAll(defaults);
        return defaults;
      }
      final raw = jsonDecode(await f.readAsString()) as List;
      final list = raw
          .map((e) => LedgerCatalogItem.fromJson(e as Map<String, dynamic>))
          .toList();
      final withDefaults = _withDefaults(list);
      if (withDefaults.length != list.length) {
        await saveAll(withDefaults);
      }
      return withDefaults;
    } catch (_) {
      final defaults = _withDefaults(const []);
      await saveAll(defaults);
      return defaults;
    }
  }

  static Future<void> saveAll(List<LedgerCatalogItem> list) async {
    final f = await _file();
    final data = _withDefaults(list);
    await f.writeAsString(jsonEncode(data.map((e) => e.toJson()).toList()));
  }

  static Future<void> addLedger(
    String name, {
    String? password,
    bool excludeFromProfitLoss = false,
  }) async {
    final clean = name.trim();
    if (clean.isEmpty) return;
    final all = await loadAll();
    final idx = all.indexWhere((e) => _norm(e.name) == _norm(clean));
    if (idx >= 0) return;
    all.add(
      LedgerCatalogItem(
        name: clean,
        password: password,
        excludeFromProfitLoss: excludeFromProfitLoss,
      ),
    );
    await saveAll(all);
  }

  static Future<String?> getPassword(String ledgerName) async {
    final all = await loadAll();
    final hit = all.where((e) => _norm(e.name) == _norm(ledgerName)).toList();
    if (hit.isEmpty) return null;
    return hit.first.password;
  }

  static Future<void> setPassword(String ledgerName, String? password) async {
    final cleanPassword =
        password == null || password.trim().isEmpty ? null : password;
    final all = await loadAll();
    final idx = all.indexWhere((e) => _norm(e.name) == _norm(ledgerName));
    if (idx >= 0) {
      all[idx] = LedgerCatalogItem(
        name: all[idx].name,
        password: cleanPassword,
        excludeFromProfitLoss: all[idx].excludeFromProfitLoss,
      );
    } else {
      all.add(
        LedgerCatalogItem(name: ledgerName.trim(), password: cleanPassword),
      );
    }
    await saveAll(all);
  }
}
