import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/app_bus.dart';
import '../models/mobile_access.dart';
import '../models/payment.dart';
import 'paths.dart';

String _nowIso() => DateTime.now().toIso8601String();

List<dynamic> _decodeJsonList(String source) => jsonDecode(source) as List;

Map<String, dynamic> _decodeJsonMap(String source) =>
    jsonDecode(source) as Map<String, dynamic>;

String _encodeJson(Object value) => jsonEncode(value);

Future<void> _writeJson(File file, Object value) async {
  final encoded = await compute(_encodeJson, value);
  await file.writeAsString(encoded);
}

Future<List<dynamic>> _readJsonList(File f) async {
  return compute(_decodeJsonList, await f.readAsString());
}

Future<Map<String, dynamic>> _readJsonMap(File f) async {
  return compute(_decodeJsonMap, await f.readAsString());
}

String _slug(String value) {
  final cleaned = value.trim().toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9]+'),
    '-',
  );
  return cleaned.replaceAll(RegExp(r'^-+|-+$'), '');
}

class MobileAccessStore {
  static List<AppUser>? _usersCache;
  static List<MobileDevice>? _devicesCache;
  static List<PaymentEntry>? _outgoingPaymentsCache;
  static List<String>? _outgoingPaymentDeletesCache;
  static List<MobileOrder>? _ordersCache;
  static List<MobileTruck>? _surjaniTrucksCache;
  static List<MobileTruck>? _factoryTrucksCache;
  static List<SyncLogEntry>? _syncLogsCache;
  static ServerSyncConfig? _serverConfigCache;
  static List<MobileUserLocation>? _locationsCache;
  static String? _locationMonitorPinCache;
  static BiometricLoginConfig? _biometricLoginConfigCache;

  static Future<File> _file(String name) async {
    final b = await baseDir();
    return File('${b.path}${Platform.pathSeparator}$name');
  }

  static Future<List<AppUser>> loadUsers() async {
    final cached = _usersCache;
    if (cached != null) return List<AppUser>.from(cached);
    try {
      final f = await _file('mobile_users.json');
      if (!await f.exists()) {
        final seeded = await _seedDefaultAdmin();
        _usersCache = seeded;
        return List<AppUser>.from(seeded);
      }
      final raw = await _readJsonList(f);
      final loaded = raw
          .map((e) => AppUser.fromJson(e as Map<String, dynamic>))
          .toList();
      if (loaded.isEmpty) {
        final seeded = await _seedDefaultAdmin();
        _usersCache = seeded;
        return List<AppUser>.from(seeded);
      }
      _usersCache = loaded;
      return List<AppUser>.from(loaded);
    } catch (_) {
      final seeded = await _seedDefaultAdmin();
      _usersCache = seeded;
      return List<AppUser>.from(seeded);
    }
  }

  static Future<void> saveUsers(List<AppUser> users) async {
    final f = await _file('mobile_users.json');
    _usersCache = List<AppUser>.from(users);
    await _writeJson(f, _usersCache!.map((e) => e.toJson()).toList());
    AppBus.bump();
  }

  static Future<AppUser> upsertUser(AppUser user) async {
    final users = await loadUsers();
    final now = _nowIso();
    final incoming = user.copyWith(
      updatedAt: now,
      createdAt: user.createdAt.isEmpty ? now : user.createdAt,
    );
    final index = users.indexWhere((e) => e.id == incoming.id);
    if (index >= 0) {
      users[index] = incoming;
    } else {
      users.add(incoming);
    }
    await saveUsers(users);
    return incoming;
  }

  static Future<List<MobileDevice>> loadDevices() async {
    final cached = _devicesCache;
    if (cached != null) return List<MobileDevice>.from(cached);
    try {
      final f = await _file('mobile_devices.json');
      if (!await f.exists()) {
        _devicesCache = <MobileDevice>[];
        return [];
      }
      final raw = await _readJsonList(f);
      final loaded = raw
          .map((e) => MobileDevice.fromJson(e as Map<String, dynamic>))
          .toList();
      _devicesCache = loaded;
      return List<MobileDevice>.from(loaded);
    } catch (_) {
      _devicesCache = <MobileDevice>[];
      return [];
    }
  }

  static Future<void> saveDevices(List<MobileDevice> devices) async {
    final f = await _file('mobile_devices.json');
    _devicesCache = List<MobileDevice>.from(devices);
    await _writeJson(f, _devicesCache!.map((e) => e.toJson()).toList());
    AppBus.bump();
  }

  static Future<List<PaymentEntry>> loadOutgoingPayments() async {
    final cached = _outgoingPaymentsCache;
    if (cached != null) return List<PaymentEntry>.from(cached);
    try {
      final f = await _file('outgoing_mobile_payments.json');
      if (!await f.exists()) {
        _outgoingPaymentsCache = <PaymentEntry>[];
        return [];
      }
      final raw = await _readJsonList(f);
      final loaded = raw
          .map((e) => PaymentEntry.fromJson(e as Map<String, dynamic>))
          .toList();
      _outgoingPaymentsCache = loaded;
      return List<PaymentEntry>.from(loaded);
    } catch (_) {
      _outgoingPaymentsCache = <PaymentEntry>[];
      return [];
    }
  }

  static Future<void> saveOutgoingPayments(List<PaymentEntry> payments) async {
    final f = await _file('outgoing_mobile_payments.json');
    _outgoingPaymentsCache = List<PaymentEntry>.from(payments);
    await _writeJson(
      f,
      _outgoingPaymentsCache!.map((e) => e.toJson()).toList(),
    );
    AppBus.bump();
  }

  static Future<void> queueOutgoingPayment(PaymentEntry payment) async {
    final payments = await loadOutgoingPayments();
    final index = payments.indexWhere((e) => e.id == payment.id);
    if (index >= 0) {
      payments[index] = payment;
    } else {
      payments.add(payment);
    }
    await saveOutgoingPayments(payments);
  }

  static Future<void> removeOutgoingPayment(String paymentId) async {
    final payments = await loadOutgoingPayments();
    payments.removeWhere((e) => e.id == paymentId);
    await saveOutgoingPayments(payments);
  }

  static Future<List<String>> loadOutgoingPaymentDeletes() async {
    final cached = _outgoingPaymentDeletesCache;
    if (cached != null) return List<String>.from(cached);
    try {
      final f = await _file('outgoing_mobile_payment_deletes.json');
      if (!await f.exists()) {
        _outgoingPaymentDeletesCache = <String>[];
        return [];
      }
      final raw = await _readJsonList(f);
      final loaded = raw
          .map((e) => e.toString().trim())
          .where((e) => e.isNotEmpty)
          .toSet()
          .toList();
      _outgoingPaymentDeletesCache = loaded;
      return List<String>.from(loaded);
    } catch (_) {
      _outgoingPaymentDeletesCache = <String>[];
      return [];
    }
  }

  static Future<void> saveOutgoingPaymentDeletes(
    List<String> paymentIds,
  ) async {
    final f = await _file('outgoing_mobile_payment_deletes.json');
    _outgoingPaymentDeletesCache = paymentIds
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    await _writeJson(f, _outgoingPaymentDeletesCache!);
    AppBus.bump();
  }

  static Future<void> queueOutgoingPaymentDelete(String paymentId) async {
    final id = paymentId.trim();
    if (id.isEmpty) return;
    await removeOutgoingPayment(id);
    final ids = await loadOutgoingPaymentDeletes();
    if (!ids.contains(id)) ids.add(id);
    await saveOutgoingPaymentDeletes(ids);
  }

  static Future<void> removeOutgoingPaymentDelete(String paymentId) async {
    final ids = await loadOutgoingPaymentDeletes();
    ids.removeWhere((e) => e == paymentId);
    await saveOutgoingPaymentDeletes(ids);
  }

  static Future<List<MobileOrder>> loadOrders() async {
    final cached = _ordersCache;
    if (cached != null) return List<MobileOrder>.from(cached);
    try {
      final f = await _file('mobile_orders.json');
      if (!await f.exists()) {
        _ordersCache = <MobileOrder>[];
        return [];
      }
      final raw = await _readJsonList(f);
      final loaded =
          raw
              .map((e) => MobileOrder.fromJson(e as Map<String, dynamic>))
              .toList()
            ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      _ordersCache = loaded;
      return List<MobileOrder>.from(loaded);
    } catch (_) {
      _ordersCache = <MobileOrder>[];
      return [];
    }
  }

  static Future<void> saveOrders(
    List<MobileOrder> orders, {
    bool mergeExisting = true,
  }) async {
    final f = await _file('mobile_orders.json');
    final List<MobileOrder> next;
    if (mergeExisting) {
      final existing = await loadOrders();
      final mergedById = {for (final order in existing) order.id: order};
      for (final order in orders) {
        final current = mergedById[order.id];
        final incoming = current == null
            ? order
            : _preserveLocalOrderFields(order, current);
        mergedById[order.id] = current == null
            ? incoming
            : (_isOrderNewer(incoming, current) ? incoming : current);
      }
      next = mergedById.values.toList();
    } else {
      next = List<MobileOrder>.from(orders);
    }
    final sorted = next..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _ordersCache = sorted;
    await _writeJson(f, _ordersCache!.map((e) => e.toJson()).toList());
    AppBus.bump();
  }

  static Future<void> deleteOrder(String orderId) async {
    final orders = await loadOrders();
    orders.removeWhere((order) => order.id == orderId);
    await saveOrders(orders, mergeExisting: false);
  }

  static bool _isOrderNewer(MobileOrder incoming, MobileOrder current) {
    if (incoming.status != current.status) {
      final incomingStatusAt = DateTime.tryParse(incoming.statusUpdatedAt);
      final currentStatusAt = DateTime.tryParse(current.statusUpdatedAt);
      if (incomingStatusAt != null && currentStatusAt != null) {
        final statusCompare = incomingStatusAt.compareTo(currentStatusAt);
        if (statusCompare != 0) return statusCompare > 0;
      }
    }

    final incomingUpdatedAt = DateTime.tryParse(incoming.updatedAt);
    final currentUpdatedAt = DateTime.tryParse(current.updatedAt);
    if (incomingUpdatedAt != null && currentUpdatedAt != null) {
      if (incomingUpdatedAt.isAtSameMomentAs(currentUpdatedAt)) {
        return incoming.toJson().toString() != current.toJson().toString();
      }
      return incomingUpdatedAt.isAfter(currentUpdatedAt);
    }
    return true;
  }

  static MobileOrder _preserveLocalOrderFields(
    MobileOrder incoming,
    MobileOrder current,
  ) {
    var merged = incoming;
    if (_shouldPreserveLocalTruck(incoming, current)) {
      merged = merged.copyWith(
        assignedTruckId: current.assignedTruckId,
        assignedTruckNo: current.assignedTruckNo,
      );
    }
    if (incoming.note.trim().isEmpty && current.note.trim().isNotEmpty) {
      merged = merged.copyWith(note: current.note);
    }
    return merged;
  }

  static bool _shouldPreserveLocalTruck(
    MobileOrder incoming,
    MobileOrder current,
  ) {
    if (incoming.assignedTruckId.trim().isNotEmpty ||
        current.assignedTruckId.trim().isEmpty) {
      return false;
    }
    if (incoming.orderSite.trim().toLowerCase() != 'surjani' ||
        current.orderSite.trim().toLowerCase() != 'surjani') {
      return false;
    }
    if (incoming.orderDate != current.orderDate) {
      return false;
    }
    return true;
  }

  static Future<MobileOrder> upsertOrder(
    MobileOrder order, {
    bool preserveLocalFields = true,
  }) async {
    final orders = await loadOrders();
    final index = orders.indexWhere((e) => e.id == order.id);
    final incoming = index >= 0 && preserveLocalFields
        ? _preserveLocalOrderFields(order, orders[index])
        : order;
    if (index >= 0) {
      orders[index] = incoming;
    } else {
      orders.add(incoming);
    }
    final sorted = List<MobileOrder>.from(orders)
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _ordersCache = sorted;
    final f = await _file('mobile_orders.json');
    await _writeJson(f, sorted.map((e) => e.toJson()).toList());
    AppBus.bump();
    return incoming;
  }

  static Future<List<MobileTruck>> loadSurjaniTrucks() async {
    final cached = _surjaniTrucksCache;
    if (cached != null) return List<MobileTruck>.from(cached);
    try {
      final f = await _file('surjani_trucks.json');
      if (!await f.exists()) {
        _surjaniTrucksCache = <MobileTruck>[];
        return [];
      }
      final raw = await _readJsonList(f);
      final loaded = raw
          .map((e) => MobileTruck.fromJson(e as Map<String, dynamic>))
          .where((truck) => truck.id.trim().isNotEmpty)
          .toList();
      _surjaniTrucksCache = loaded;
      return List<MobileTruck>.from(loaded);
    } catch (_) {
      _surjaniTrucksCache = <MobileTruck>[];
      return [];
    }
  }

  static Future<void> saveSurjaniTrucks(List<MobileTruck> trucks) async {
    final normalized = List<MobileTruck>.from(trucks)
      ..sort((a, b) => a.id.compareTo(b.id));
    final current = _surjaniTrucksCache == null
        ? null
        : (List<MobileTruck>.from(_surjaniTrucksCache!)
            ..sort((a, b) => a.id.compareTo(b.id)));
    if (current != null &&
        current.length == normalized.length &&
        List.generate(current.length, (index) {
          final a = current[index];
          final b = normalized[index];
          return a.id == b.id &&
              a.number == b.number &&
              a.capacity == b.capacity &&
              a.orderDate == b.orderDate &&
              _sameTruckTypeBags(a.typeBags, b.typeBags);
        }).every((same) => same)) {
      return;
    }
    final f = await _file('surjani_trucks.json');
    _surjaniTrucksCache = List<MobileTruck>.from(trucks);
    await _writeJson(f, _surjaniTrucksCache!.map((e) => e.toJson()).toList());
    AppBus.bump();
  }

  static Future<List<MobileTruck>> loadSurjaniTrucksForDate(
    String orderDate,
  ) async {
    final date = orderDate.trim();
    final trucks = await loadSurjaniTrucks();
    return trucks.where((truck) => truck.orderDate == date).toList();
  }

  static Future<void> saveSurjaniTrucksForDate(
    String orderDate,
    List<MobileTruck> trucks,
  ) async {
    final date = orderDate.trim();
    final existing = await loadSurjaniTrucks();
    final dated = trucks
        .map((truck) => truck.copyWith(orderDate: date))
        .where((truck) => truck.id.trim().isNotEmpty)
        .toList();
    await saveSurjaniTrucks([
      for (final truck in existing)
        if (truck.orderDate != date) truck,
      ...dated,
    ]);
  }

  static Future<List<MobileTruck>> loadFactoryTrucks() async {
    final cached = _factoryTrucksCache;
    if (cached != null) return List<MobileTruck>.from(cached);
    try {
      final f = await _file('factory_trucks.json');
      if (!await f.exists()) {
        _factoryTrucksCache = <MobileTruck>[];
        return [];
      }
      final raw = await _readJsonList(f);
      final loaded = raw
          .map((e) => MobileTruck.fromJson(e as Map<String, dynamic>))
          .where((truck) => truck.id.trim().isNotEmpty)
          .toList();
      _factoryTrucksCache = loaded;
      return List<MobileTruck>.from(loaded);
    } catch (_) {
      _factoryTrucksCache = <MobileTruck>[];
      return [];
    }
  }

  static Future<void> saveFactoryTrucks(List<MobileTruck> trucks) async {
    final normalized = List<MobileTruck>.from(trucks)
      ..sort((a, b) => a.id.compareTo(b.id));
    final current = _factoryTrucksCache == null
        ? null
        : (List<MobileTruck>.from(_factoryTrucksCache!)
            ..sort((a, b) => a.id.compareTo(b.id)));
    if (current != null &&
        current.length == normalized.length &&
        List.generate(current.length, (index) {
          final a = current[index];
          final b = normalized[index];
          return a.id == b.id &&
              a.number == b.number &&
              a.capacity == b.capacity &&
              a.orderDate == b.orderDate &&
              _sameTruckTypeBags(a.typeBags, b.typeBags);
        }).every((same) => same)) {
      return;
    }
    final f = await _file('factory_trucks.json');
    _factoryTrucksCache = List<MobileTruck>.from(trucks);
    await _writeJson(f, _factoryTrucksCache!.map((e) => e.toJson()).toList());
    AppBus.bump();
  }

  static Future<List<MobileTruck>> loadFactoryTrucksForDate(
    String orderDate,
  ) async {
    final date = orderDate.trim();
    final trucks = await loadFactoryTrucks();
    return trucks.where((truck) => truck.orderDate == date).toList();
  }

  static Future<void> saveFactoryTrucksForDate(
    String orderDate,
    List<MobileTruck> trucks,
  ) async {
    final date = orderDate.trim();
    final existing = await loadFactoryTrucks();
    final dated = trucks
        .map((truck) => truck.copyWith(orderDate: date))
        .where((truck) => truck.id.trim().isNotEmpty)
        .toList();
    await saveFactoryTrucks([
      for (final truck in existing)
        if (truck.orderDate != date) truck,
      ...dated,
    ]);
  }

  static bool _sameTruckTypeBags(Map<String, int> a, Map<String, int> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  static Future<List<SyncLogEntry>> loadSyncLogs() async {
    final cached = _syncLogsCache;
    if (cached != null) return List<SyncLogEntry>.from(cached);
    try {
      final f = await _file('sync_logs.json');
      if (!await f.exists()) {
        _syncLogsCache = <SyncLogEntry>[];
        return [];
      }
      final raw = await _readJsonList(f);
      final loaded =
          raw
              .map((e) => SyncLogEntry.fromJson(e as Map<String, dynamic>))
              .toList()
            ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      _syncLogsCache = loaded;
      return List<SyncLogEntry>.from(loaded);
    } catch (_) {
      _syncLogsCache = <SyncLogEntry>[];
      return [];
    }
  }

  static Future<void> saveSyncLogs(List<SyncLogEntry> logs) async {
    final f = await _file('sync_logs.json');
    final limited = List<SyncLogEntry>.from(logs)
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    if (limited.length > 300) {
      limited.removeRange(300, limited.length);
    }
    _syncLogsCache = limited;
    await _writeJson(f, _syncLogsCache!.map((e) => e.toJson()).toList());
    AppBus.bump();
  }

  static Future<void> addSyncLog(SyncLogEntry entry) async {
    final logs = await loadSyncLogs();
    logs.insert(0, entry);
    await saveSyncLogs(logs);
  }

  static Future<List<MobileUserLocation>> loadUserLocations() async {
    final cached = _locationsCache;
    if (cached != null) return List<MobileUserLocation>.from(cached);
    try {
      final f = await _file('mobile_user_locations.json');
      if (!await f.exists()) {
        _locationsCache = <MobileUserLocation>[];
        return [];
      }
      final raw = await _readJsonList(f);
      final loaded =
          raw
              .map(
                (e) => MobileUserLocation.fromJson(e as Map<String, dynamic>),
              )
              .where((e) => e.userId.trim().isNotEmpty)
              .toList()
            ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
      _locationsCache = loaded;
      return List<MobileUserLocation>.from(loaded);
    } catch (_) {
      _locationsCache = <MobileUserLocation>[];
      return [];
    }
  }

  static Future<void> saveUserLocations(
    List<MobileUserLocation> locations,
  ) async {
    final byUser = <String, MobileUserLocation>{};
    for (final location in locations) {
      final key = location.userId.trim().isNotEmpty
          ? location.userId.trim()
          : location.username.trim().toLowerCase();
      if (key.isEmpty) continue;
      final current = byUser[key];
      if (current == null ||
          location.receivedAt.compareTo(current.receivedAt) >= 0) {
        byUser[key] = location;
      }
    }
    final sorted = byUser.values.toList()
      ..sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    _locationsCache = sorted;
    final f = await _file('mobile_user_locations.json');
    await _writeJson(f, sorted.map((e) => e.toJson()).toList());
    AppBus.bump();
  }

  static Future<void> upsertUserLocation(MobileUserLocation location) async {
    final locations = await loadUserLocations();
    final key = location.userId.trim().isNotEmpty
        ? location.userId.trim()
        : location.username.trim().toLowerCase();
    final index = locations.indexWhere((existing) {
      final existingKey = existing.userId.trim().isNotEmpty
          ? existing.userId.trim()
          : existing.username.trim().toLowerCase();
      return existingKey == key;
    });
    if (index >= 0) {
      locations[index] = location;
    } else {
      locations.add(location);
    }
    await saveUserLocations(locations);
  }

  static Future<String?> loadLocationMonitorPin() async {
    if (_locationMonitorPinCache != null) return _locationMonitorPinCache;
    try {
      final f = await _file('location_monitor_pin.json');
      if (!await f.exists()) return null;
      final raw = await _readJsonMap(f);
      final pin = (raw['pin'] ?? '').toString().trim();
      _locationMonitorPinCache = pin.isEmpty ? null : pin;
      return _locationMonitorPinCache;
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveLocationMonitorPin(String pin) async {
    final clean = pin.trim();
    final f = await _file('location_monitor_pin.json');
    if (clean.isEmpty) {
      _locationMonitorPinCache = null;
      if (await f.exists()) await f.delete();
      return;
    }
    _locationMonitorPinCache = clean;
    await _writeJson(f, {'pin': clean});
  }

  static Future<ServerSyncConfig> loadServerConfig() async {
    final cached = _serverConfigCache;
    if (cached != null) return cached;
    try {
      final f = await _file('server_sync_config.json');
      if (!await f.exists()) {
        _serverConfigCache = const ServerSyncConfig();
        return _serverConfigCache!;
      }
      final raw = await _readJsonMap(f);
      _serverConfigCache = ServerSyncConfig.fromJson(raw);
      return _serverConfigCache!;
    } catch (_) {
      _serverConfigCache = const ServerSyncConfig();
      return _serverConfigCache!;
    }
  }

  static Future<void> saveServerConfig(ServerSyncConfig config) async {
    final f = await _file('server_sync_config.json');
    _serverConfigCache = config;
    await _writeJson(f, config.toJson());
    AppBus.bump();
  }

  static Future<BiometricLoginConfig> loadBiometricLoginConfig() async {
    final cached = _biometricLoginConfigCache;
    if (cached != null) return cached;
    try {
      final f = await _file('biometric_login_config.json');
      if (!await f.exists()) {
        _biometricLoginConfigCache = const BiometricLoginConfig();
        return _biometricLoginConfigCache!;
      }
      final raw = await _readJsonMap(f);
      _biometricLoginConfigCache = BiometricLoginConfig.fromJson(raw);
      return _biometricLoginConfigCache!;
    } catch (_) {
      _biometricLoginConfigCache = const BiometricLoginConfig();
      return _biometricLoginConfigCache!;
    }
  }

  static Future<void> saveBiometricLoginConfig(
    BiometricLoginConfig config,
  ) async {
    final f = await _file('biometric_login_config.json');
    _biometricLoginConfigCache = config;
    await _writeJson(f, config.toJson());
    AppBus.bump();
  }

  static Future<List<AppUser>> _seedDefaultAdmin() async {
    final now = _nowIso();
    final user = AppUser(
      id: 'usr-owner',
      username: 'owner',
      displayName: 'Owner',
      passcode: '1234',
      role: UserRole.admin,
      createdAt: now,
      updatedAt: now,
    );
    await saveUsers([user]);
    await addSyncLog(
      SyncLogEntry(
        id: 'log-${DateTime.now().microsecondsSinceEpoch}',
        createdAt: now,
        direction: SyncLogDirection.local,
        status: SyncLogStatus.info,
        entityType: 'users',
        entityId: user.id,
        summary: 'Seeded default mobile admin account',
        details: 'Username: owner, passcode: 1234',
      ),
    );
    return [user];
  }

  static String nextUserId(String displayName) =>
      'usr-${_slug(displayName).isEmpty ? DateTime.now().millisecondsSinceEpoch : _slug(displayName)}';

  static String nextDeviceId(String label) =>
      'dev-${_slug(label).isEmpty ? DateTime.now().millisecondsSinceEpoch : _slug(label)}';

  static String nextOrderId() => 'ord-${DateTime.now().microsecondsSinceEpoch}';

  static String nextSyncLogId() =>
      'log-${DateTime.now().microsecondsSinceEpoch}';
}
