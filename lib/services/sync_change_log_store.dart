import 'dart:convert';
import 'dart:io';

import 'paths.dart';

class SyncChangeEntry {
  final String id;
  final String entityType;
  final String entityId;
  final String action;
  final String changedAt;

  const SyncChangeEntry({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.action,
    required this.changedAt,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'entityType': entityType,
        'entityId': entityId,
        'action': action,
        'changedAt': changedAt,
      };

  static SyncChangeEntry fromJson(Map<String, dynamic> json) => SyncChangeEntry(
        id: (json['id'] ?? '').toString(),
        entityType: (json['entityType'] ?? '').toString(),
        entityId: (json['entityId'] ?? '').toString(),
        action: (json['action'] ?? '').toString(),
        changedAt: (json['changedAt'] ?? '').toString(),
      );
}

class SyncChangeLogStore {
  static const int _maxEntries = 10000;
  static List<SyncChangeEntry>? _cache;

  static Future<File> _file() async {
    final b = await baseDir();
    return File('${b.path}${Platform.pathSeparator}sync_changes.json');
  }

  static Future<List<SyncChangeEntry>> loadAll() async {
    final cached = _cache;
    if (cached != null) return List<SyncChangeEntry>.from(cached);
    try {
      final f = await _file();
      if (!await f.exists()) {
        _cache = <SyncChangeEntry>[];
        return <SyncChangeEntry>[];
      }
      final list = jsonDecode(await f.readAsString()) as List;
      final loaded = list
          .map((e) => SyncChangeEntry.fromJson(e as Map<String, dynamic>))
          .where((e) =>
              e.entityType.trim().isNotEmpty &&
              e.entityId.trim().isNotEmpty &&
              e.action.trim().isNotEmpty &&
              e.changedAt.trim().isNotEmpty)
          .toList();
      _cache = loaded;
      return List<SyncChangeEntry>.from(loaded);
    } catch (_) {
      _cache = <SyncChangeEntry>[];
      return <SyncChangeEntry>[];
    }
  }

  static Future<void> saveAll(List<SyncChangeEntry> entries) async {
    final f = await _file();
    final limited = entries.length > _maxEntries
        ? entries.sublist(entries.length - _maxEntries)
        : List<SyncChangeEntry>.from(entries);
    _cache = limited;
    await f.writeAsString(
      jsonEncode(limited.map((e) => e.toJson()).toList()),
    );
  }

  static Future<List<SyncChangeEntry>> loadSince(String? since) async {
    final sinceTime = DateTime.tryParse((since ?? '').trim());
    if (sinceTime == null) return const <SyncChangeEntry>[];
    final entries = await loadAll();
    return entries.where((entry) {
      final changedAt = DateTime.tryParse(entry.changedAt);
      return changedAt != null && changedAt.isAfter(sinceTime);
    }).toList();
  }

  static Future<void> recordDiff({
    required String entityType,
    required Map<String, String> previous,
    required Map<String, String> next,
  }) async {
    final changes = <SyncChangeEntry>[];
    final now = DateTime.now().toIso8601String();

    for (final entry in next.entries) {
      if (previous[entry.key] == entry.value) continue;
      changes.add(_entry(entityType, entry.key, 'upsert', now));
    }
    for (final id in previous.keys) {
      if (next.containsKey(id)) continue;
      changes.add(_entry(entityType, id, 'delete', now));
    }

    if (changes.isEmpty) return;
    final all = await loadAll();
    all.addAll(changes);
    await saveAll(all);
  }

  static SyncChangeEntry _entry(
    String entityType,
    String entityId,
    String action,
    String changedAt,
  ) {
    return SyncChangeEntry(
      id: 'SYNC-${DateTime.now().microsecondsSinceEpoch}-$entityType-$entityId-$action',
      entityType: entityType,
      entityId: entityId,
      action: action,
      changedAt: changedAt,
    );
  }
}
