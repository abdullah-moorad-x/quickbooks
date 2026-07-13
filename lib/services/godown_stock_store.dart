import 'dart:convert';
import 'dart:io';

import '../core/app_bus.dart';
import '../core/constants.dart';
import '../utils/date.dart';
import 'paths.dart';
import 'storage.dart';

class GodownSku {
  final String name;
  final String category;
  final List<String> aliases;
  final double openingBags;

  const GodownSku({
    required this.name,
    required this.category,
    required this.aliases,
    required this.openingBags,
  });

  GodownSku copyWith({
    String? name,
    String? category,
    List<String>? aliases,
    double? openingBags,
  }) {
    return GodownSku(
      name: name ?? this.name,
      category: category ?? this.category,
      aliases: aliases ?? this.aliases,
      openingBags: openingBags ?? this.openingBags,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'category': category,
        'aliases': aliases,
        'openingBags': openingBags,
      };

  static GodownSku fromJson(Map<String, dynamic> json) {
    final name = (json['name'] ?? '').toString().trim();
    final rawCategory = (json['category'] ?? '').toString().trim();
    final category = kItemTypes.contains(rawCategory) ? rawCategory : '';
    final aliasesRaw = (json['aliases'] as List?) ?? const [];
    final aliases = aliasesRaw
        .map((e) => e.toString().trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final openingBags = (json['openingBags'] as num?)?.toDouble() ?? 0.0;
    return GodownSku(
        name: name,
        category: category,
        aliases: aliases,
        openingBags: openingBags);
  }
}

class GodownConfig {
  final String openingDate;
  final List<GodownSku> skus;
  final List<GodownStockInEntry> stockIns;

  const GodownConfig({
    required this.openingDate,
    required this.skus,
    required this.stockIns,
  });

  factory GodownConfig.defaults() {
    return GodownConfig(
      openingDate: formatInvoiceDate(DateTime.now()),
      skus: const [],
      stockIns: const [],
    );
  }

  Map<String, dynamic> toJson() => {
        'openingDate': openingDate,
        'skus': skus.map((e) => e.toJson()).toList(),
        'stockIns': stockIns.map((e) => e.toJson()).toList(),
      };

  static GodownConfig fromJson(Map<String, dynamic> json) {
    final hasLegacyOpening =
        json.containsKey('openingBags') || json.containsKey('openingDate');
    if (hasLegacyOpening && !json.containsKey('skus')) {
      final legacyDate = (json['openingDate'] ?? '').toString().trim();
      final safeDate =
          legacyDate.isEmpty ? formatInvoiceDate(DateTime.now()) : legacyDate;
      final legacyBags = (json['openingBags'] as num?)?.toDouble() ?? 0.0;
      final sku = legacyBags.abs() > 0.0001
          ? [
              GodownSku(
                  name: 'GENERAL',
                  category: '',
                  aliases: const ['ALL'],
                  openingBags: legacyBags)
            ]
          : const <GodownSku>[];
      return GodownConfig(openingDate: safeDate, skus: sku, stockIns: const []);
    }

    final rawDate = (json['openingDate'] ?? '').toString().trim();
    final safeDate =
        rawDate.isEmpty ? formatInvoiceDate(DateTime.now()) : rawDate;
    final rawSkus = (json['skus'] as List?) ?? const [];
    final skus = rawSkus
        .whereType<Map>()
        .map((e) => GodownSku.fromJson(Map<String, dynamic>.from(e)))
        .where((e) => e.name.isNotEmpty)
        .toList();
    final rawStockIns = (json['stockIns'] as List?) ?? const [];
    final stockIns = rawStockIns
        .whereType<Map>()
        .map((e) => GodownStockInEntry.fromJson(Map<String, dynamic>.from(e)))
        .where((e) => e.sku.isNotEmpty && e.qty > 0)
        .toList()
      ..sort((a, b) {
        int d;
        try {
          d = parseInvoiceDate(a.date).compareTo(parseInvoiceDate(b.date));
        } catch (_) {
          d = a.date.compareTo(b.date);
        }
        if (d != 0) return d;
        return a.id.compareTo(b.id);
      });
    return GodownConfig(openingDate: safeDate, skus: skus, stockIns: stockIns);
  }
}

class GodownStockInEntry {
  final String id;
  final String date;
  final String truckNo;
  final String category;
  final String sku;
  final double qty;
  final String? note;

  const GodownStockInEntry({
    required this.id,
    required this.date,
    required this.truckNo,
    required this.category,
    required this.sku,
    required this.qty,
    this.note,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date,
        'truckNo': truckNo,
        'category': category,
        'sku': sku,
        'qty': qty,
        'note': note,
      };

  static GodownStockInEntry fromJson(Map<String, dynamic> json) {
    return GodownStockInEntry(
      id: (json['id'] ?? '').toString(),
      date: (json['date'] ?? '').toString(),
      truckNo: (json['truckNo'] ?? '').toString(),
      category: (json['category'] ?? '').toString(),
      sku: (json['sku'] ?? '').toString(),
      qty: (json['qty'] as num?)?.toDouble() ?? 0.0,
      note: (json['note'] ?? '').toString().trim().isEmpty
          ? null
          : (json['note'] ?? '').toString(),
    );
  }
}

class GodownSkuBalance {
  final String sku;
  final String category;
  final double openingBags;
  final double stockedTillDate;
  final double soldTillDate;
  final double remainingBags;

  const GodownSkuBalance({
    required this.sku,
    required this.category,
    required this.openingBags,
    required this.stockedTillDate,
    required this.soldTillDate,
    required this.remainingBags,
  });
}

class GodownDailySkuRow {
  final DateTime date;
  final String sku;
  final String category;
  final double stockedToday;
  final double stockedTillDate;
  final double soldToday;
  final double soldTillDate;
  final double remainingBags;

  const GodownDailySkuRow({
    required this.date,
    required this.sku,
    required this.category,
    required this.stockedToday,
    required this.stockedTillDate,
    required this.soldToday,
    required this.soldTillDate,
    required this.remainingBags,
  });
}

class GodownUnmappedLine {
  final DateTime date;
  final int invoiceNo;
  final String typeLabel;
  final String brandText;
  final double qty;

  const GodownUnmappedLine({
    required this.date,
    required this.invoiceNo,
    required this.typeLabel,
    required this.brandText,
    required this.qty,
  });
}

class GodownStockReport {
  final GodownConfig config;
  final List<GodownSkuBalance> balances;
  final List<GodownDailySkuRow> dailyRows;
  final List<GodownUnmappedLine> unmapped;

  const GodownStockReport({
    required this.config,
    required this.balances,
    required this.dailyRows,
    required this.unmapped,
  });

  double get totalOpening =>
      balances.fold<double>(0, (s, e) => s + e.openingBags);
  double get totalStocked =>
      balances.fold<double>(0, (s, e) => s + e.stockedTillDate);
  double get totalSold =>
      balances.fold<double>(0, (s, e) => s + e.soldTillDate);
  double get totalRemaining =>
      balances.fold<double>(0, (s, e) => s + e.remainingBags);
}

class GodownStockStore {
  static String _skuKey(String name, String category) =>
      '${_norm(name)}|${_norm(category)}';
  static Future<File> _file() async {
    final base = await baseDir();
    return File('${base.path}${Platform.pathSeparator}godown_stock.json');
  }

  static Future<GodownConfig> loadConfig() async {
    try {
      final f = await _file();
      if (!await f.exists()) return GodownConfig.defaults();
      final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final cfg = GodownConfig.fromJson(json);
      cfg.skus
          .sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return cfg;
    } catch (_) {
      return GodownConfig.defaults();
    }
  }

  static Future<void> saveConfig(GodownConfig config) async {
    final f = await _file();
    await f.writeAsString(jsonEncode(config.toJson()));
    AppBus.bump();
  }

  static Future<void> saveOpeningDate(String openingDate) async {
    final cfg = await loadConfig();
    await saveConfig(GodownConfig(
        openingDate: openingDate, skus: cfg.skus, stockIns: cfg.stockIns));
  }

  static Future<void> upsertSku({
    required String name,
    required String category,
    required double openingBags,
    List<String> aliases = const [],
  }) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty) return;
    final cleanCategory = category.trim();
    if (!kItemTypes.contains(cleanCategory)) return;
    final cfg = await loadConfig();
    final key = _skuKey(cleanName, cleanCategory);

    final cleanedAliases = aliases
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    final list = <GodownSku>[];
    var replaced = false;
    for (final sku in cfg.skus) {
      if (_skuKey(sku.name, sku.category) == key) {
        list.add(sku.copyWith(
          name: cleanName,
          category: cleanCategory,
          openingBags: openingBags,
          aliases: cleanedAliases,
        ));
        replaced = true;
      } else {
        list.add(sku);
      }
    }
    if (!replaced) {
      list.add(GodownSku(
          name: cleanName,
          category: cleanCategory,
          aliases: cleanedAliases,
          openingBags: openingBags));
    }
    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    await saveConfig(GodownConfig(
        openingDate: cfg.openingDate, skus: list, stockIns: cfg.stockIns));
  }

  static Future<void> deleteSku(String name, String category) async {
    final cfg = await loadConfig();
    final key = _skuKey(name, category);
    final list =
        cfg.skus.where((e) => _skuKey(e.name, e.category) != key).toList();
    await saveConfig(GodownConfig(
        openingDate: cfg.openingDate, skus: list, stockIns: cfg.stockIns));
  }

  static Future<String> nextStockInId([DateTime? when]) async {
    final base = when ?? DateTime.now();
    final ymd =
        '${base.year.toString().padLeft(4, '0')}${base.month.toString().padLeft(2, '0')}${base.day.toString().padLeft(2, '0')}';
    final cfg = await loadConfig();
    int maxNum = 0;
    for (final e in cfg.stockIns.where((x) => x.id.startsWith('GIN-$ymd-'))) {
      final parts = e.id.split('-');
      if (parts.length >= 3) {
        final n = int.tryParse(parts.last) ?? 0;
        if (n > maxNum) maxNum = n;
      }
    }
    return 'GIN-$ymd-${(maxNum + 1).toString().padLeft(3, '0')}';
  }

  static Future<void> addStockIn({
    required String date,
    required String truckNo,
    required String category,
    required String sku,
    required double qty,
    String? note,
  }) async {
    final cfg = await loadConfig();
    final skuDef = cfg.skus.firstWhere(
      (e) =>
          _norm(e.name) == _norm(sku) && (_norm(e.category) == _norm(category)),
      orElse: () =>
          const GodownSku(name: '', category: '', aliases: [], openingBags: 0),
    );
    if (skuDef.name.isEmpty) return;
    if (skuDef.category.isNotEmpty && skuDef.category != category.trim()) {
      return;
    }
    final id = await nextStockInId(parseInvoiceDate(date));
    final list = [...cfg.stockIns];
    list.add(
      GodownStockInEntry(
        id: id,
        date: date,
        truckNo: truckNo.trim(),
        category: category.trim(),
        sku: sku.trim(),
        qty: qty,
        note: note?.trim().isEmpty ?? true ? null : note!.trim(),
      ),
    );
    list.sort((a, b) {
      int d;
      try {
        d = parseInvoiceDate(a.date).compareTo(parseInvoiceDate(b.date));
      } catch (_) {
        d = a.date.compareTo(b.date);
      }
      if (d != 0) return d;
      return a.id.compareTo(b.id);
    });
    await saveConfig(GodownConfig(
        openingDate: cfg.openingDate, skus: cfg.skus, stockIns: list));
  }

  static Future<void> ensureSku({
    required String name,
    required String category,
  }) async {
    final cleanName = name.trim();
    final cleanCategory = category.trim();
    if (cleanName.isEmpty || !kItemTypes.contains(cleanCategory)) return;
    final cfg = await loadConfig();
    final exists = cfg.skus.any((sku) =>
        _skuKey(sku.name, sku.category) == _skuKey(cleanName, cleanCategory));
    if (exists) return;
    await saveConfig(
      GodownConfig(
        openingDate: cfg.openingDate,
        skus: [
          ...cfg.skus,
          GodownSku(
            name: cleanName,
            category: cleanCategory,
            aliases: const [],
            openingBags: 0,
          ),
        ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())),
        stockIns: cfg.stockIns,
      ),
    );
  }

  static Future<void> upsertStockInEntry(GodownStockInEntry entry) async {
    if (entry.id.trim().isEmpty ||
        entry.date.trim().isEmpty ||
        entry.truckNo.trim().isEmpty ||
        entry.category.trim().isEmpty ||
        entry.sku.trim().isEmpty ||
        entry.qty <= 0) {
      return;
    }
    await ensureSku(name: entry.sku, category: entry.category);
    final cfg = await loadConfig();
    final list = [
      for (final existing in cfg.stockIns)
        if (existing.id != entry.id) existing,
      entry,
    ];
    list.sort((a, b) {
      int d;
      try {
        d = parseInvoiceDate(a.date).compareTo(parseInvoiceDate(b.date));
      } catch (_) {
        d = a.date.compareTo(b.date);
      }
      if (d != 0) return d;
      return a.id.compareTo(b.id);
    });
    await saveConfig(
      GodownConfig(
        openingDate: cfg.openingDate,
        skus: cfg.skus,
        stockIns: list,
      ),
    );
  }

  static Future<void> deleteStockIn(String id) async {
    final cfg = await loadConfig();
    final list = cfg.stockIns.where((e) => e.id != id).toList();
    await saveConfig(GodownConfig(
        openingDate: cfg.openingDate, skus: cfg.skus, stockIns: list));
  }

  static Future<String?> resolveCanonicalSku(String input,
      {String? category}) async {
    final cfg = await loadConfig();
    return resolveCanonicalSkuFromConfig(cfg, input, category: category);
  }

  static String? resolveCanonicalSkuFromConfig(
      GodownConfig config, String input,
      {String? category}) {
    final q = _norm(input);
    if (q.isEmpty) return null;
    bool categoryMatches(GodownSku sku) {
      final c = (category ?? '').trim();
      if (c.isEmpty) return true;
      if (sku.category.isEmpty) return true;
      return sku.category == c;
    }

    for (final sku in config.skus) {
      if (!categoryMatches(sku)) continue;
      if (_norm(sku.name) == q) return sku.name;
    }
    for (final sku in config.skus) {
      if (!categoryMatches(sku)) continue;
      for (final a in sku.aliases) {
        if (_norm(a) == q) return sku.name;
      }
    }
    return null;
  }

  static Future<GodownStockReport> buildReport({DateTime? until}) async {
    final cfg = await loadConfig();
    DateTime openingDate;
    try {
      openingDate = _dateOnly(parseInvoiceDate(cfg.openingDate));
    } catch (_) {
      openingDate = _dateOnly(DateTime.now());
    }

    final invoices = await Store.loadAll();
    final soldByDateSku = <DateTime, Map<String, double>>{};
    final stockInByDateSku = <DateTime, Map<String, double>>{};
    final soldTotals = <String, double>{
      for (final s in cfg.skus) _skuKey(s.name, s.category): 0.0
    };
    final stockedTotals = <String, double>{
      for (final s in cfg.skus) _skuKey(s.name, s.category): 0.0
    };
    final unmapped = <GodownUnmappedLine>[];
    var maxDate = openingDate;

    for (final inEntry in cfg.stockIns) {
      DateTime d;
      try {
        d = _dateOnly(parseInvoiceDate(inEntry.date));
      } catch (_) {
        continue;
      }
      if (d.isAfter(maxDate)) maxDate = d;
      if (d.isBefore(openingDate)) continue;
      if (inEntry.qty <= 0) continue;
      final key = _skuKey(inEntry.sku, inEntry.category);
      stockedTotals[key] = (stockedTotals[key] ?? 0) + inEntry.qty;
      final dayMap = stockInByDateSku.putIfAbsent(d, () => <String, double>{});
      dayMap[key] = (dayMap[key] ?? 0) + inEntry.qty;
    }

    for (final inv in invoices) {
      if (inv.site.trim().toLowerCase() != 'godown') continue;
      DateTime d;
      try {
        d = _dateOnly(parseInvoiceDate(inv.date));
      } catch (_) {
        continue;
      }
      if (d.isAfter(maxDate)) maxDate = d;
      if (d.isBefore(openingDate)) continue;

      for (final line in inv.lines) {
        if (line.qty == 0) continue;
        final brand = line.brand.trim();
        if (brand.isEmpty) continue;
        final canonical =
            resolveCanonicalSkuFromConfig(cfg, brand, category: line.typeLabel);
        if (canonical == null) {
          unmapped.add(
            GodownUnmappedLine(
              date: d,
              invoiceNo: inv.sNo,
              typeLabel: line.typeLabel,
              brandText: brand,
              qty: line.qty.toDouble(),
            ),
          );
          continue;
        }
        final key = _skuKey(canonical, line.typeLabel);
        soldTotals[key] = (soldTotals[key] ?? 0) + line.qty.toDouble();
        final dayMap = soldByDateSku.putIfAbsent(d, () => <String, double>{});
        dayMap[key] = (dayMap[key] ?? 0) + line.qty.toDouble();
      }
    }

    final cap = _dateOnly(until ?? DateTime.now());
    if (cap.isAfter(maxDate)) maxDate = cap;
    if (maxDate.isBefore(openingDate)) maxDate = openingDate;

    final runningSold = <String, double>{
      for (final s in cfg.skus) _skuKey(s.name, s.category): 0.0
    };
    final runningStockIn = <String, double>{
      for (final s in cfg.skus) _skuKey(s.name, s.category): 0.0
    };
    final dailyRows = <GodownDailySkuRow>[];
    for (DateTime d = openingDate;
        !d.isAfter(maxDate);
        d = d.add(const Duration(days: 1))) {
      final soldDayMap = soldByDateSku[d] ?? const <String, double>{};
      final stockDayMap = stockInByDateSku[d] ?? const <String, double>{};
      for (final sku in cfg.skus) {
        final key = _skuKey(sku.name, sku.category);
        final soldToday = soldDayMap[key] ?? 0.0;
        final stockedToday = stockDayMap[key] ?? 0.0;
        runningSold[key] = (runningSold[key] ?? 0) + soldToday;
        runningStockIn[key] = (runningStockIn[key] ?? 0) + stockedToday;
        dailyRows.add(
          GodownDailySkuRow(
            date: d,
            sku: sku.name,
            category: sku.category,
            stockedToday: stockedToday,
            stockedTillDate: runningStockIn[key] ?? 0,
            soldToday: soldToday,
            soldTillDate: runningSold[key] ?? 0,
            remainingBags: sku.openingBags +
                (runningStockIn[key] ?? 0) -
                (runningSold[key] ?? 0),
          ),
        );
      }
    }

    final balances = cfg.skus
        .map(
          (s) => GodownSkuBalance(
            sku: s.name,
            category: s.category,
            openingBags: s.openingBags,
            stockedTillDate: stockedTotals[_skuKey(s.name, s.category)] ?? 0,
            soldTillDate: soldTotals[_skuKey(s.name, s.category)] ?? 0,
            remainingBags: s.openingBags +
                (stockedTotals[_skuKey(s.name, s.category)] ?? 0) -
                (soldTotals[_skuKey(s.name, s.category)] ?? 0),
          ),
        )
        .toList()
      ..sort((a, b) => a.sku.toLowerCase().compareTo(b.sku.toLowerCase()));

    unmapped.sort((a, b) {
      final d = b.date.compareTo(a.date);
      if (d != 0) return d;
      return b.invoiceNo.compareTo(a.invoiceNo);
    });

    return GodownStockReport(
      config: cfg,
      balances: balances,
      dailyRows: dailyRows,
      unmapped: unmapped,
    );
  }

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  static String _norm(String s) {
    final lower = s.toLowerCase().trim();
    final cleaned = lower.replaceAll(RegExp(r'[^a-z0-9]+'), ' ');
    return cleaned.replaceAll(RegExp(r'\s+'), ' ').trim();
  }
}
