import 'dart:convert';
import 'dart:io';

import '../models/customer.dart';
import '../models/invoice.dart';
import '../models/mobile_access.dart';
import '../models/payment.dart';
import 'godown_stock_store.dart';
import 'mobile_sync_store.dart';
import 'storage.dart';

class ServerSyncResult {
  final int customerCount;
  final int invoiceCount;
  final int paymentCount;
  final int orderCount;

  const ServerSyncResult({
    required this.customerCount,
    required this.invoiceCount,
    required this.paymentCount,
    this.orderCount = 0,
  });
}

class ServerDraftSubmitResult {
  final String draftCode;

  const ServerDraftSubmitResult({required this.draftCode});
}

class ServerOrderSaveResult {
  final MobileOrder order;

  const ServerOrderSaveResult({required this.order});
}

class ServerAuthResult {
  final String token;
  final AppUser user;

  const ServerAuthResult({
    required this.token,
    required this.user,
  });
}

class ServerSyncClient {
  static Future<void> testConnection(String baseUrl) async {
    final uri = Uri.parse('${_normalizeBaseUrl(baseUrl)}/health');
    final response = await _requestJson(uri);
    if (response['ok'] != true) {
      throw const ServerSyncException('Laptop server health check failed.');
    }
  }

  static Future<ServerSyncResult> syncReadOnlyData({
    required String baseUrl,
    required String username,
    required String passcode,
    bool forceFull = false,
  }) async {
    final auth = await authenticateUser(
      baseUrl: baseUrl,
      username: username,
      passcode: passcode,
    );
    final normalized = _normalizeBaseUrl(baseUrl);
    final config = await MobileAccessStore.loadServerConfig();
    final lastSyncAt = config.lastSyncAt;

    if (!forceFull && lastSyncAt != null && lastSyncAt.trim().isNotEmpty) {
      final result = await _syncChanges(
        normalized: normalized,
        token: auth.token,
        since: lastSyncAt,
      );
      if (result != null) return result;
    }

    final syncUri = Uri.parse('$normalized/sync/read-only');
    final data = await _requestJson(
      syncUri,
      headers: {HttpHeaders.authorizationHeader: 'Bearer ${auth.token}'},
    );

    final customers = ((data['customers'] as List?) ?? const [])
        .map((e) => Customer.fromJson(e as Map<String, dynamic>))
        .toList();
    final invoices = ((data['invoices'] as List?) ?? const [])
        .map((e) => Invoice.fromJson(e as Map<String, dynamic>))
        .toList();
    final payments = ((data['payments'] as List?) ?? const [])
        .map((e) => PaymentEntry.fromJson(e as Map<String, dynamic>))
        .toList();
    final orders = ((data['orders'] as List?) ?? const [])
        .map((e) => MobileOrder.fromJson(e as Map<String, dynamic>))
        .toList();
    final surjaniTrucks = _parseSurjaniTrucks(data);
    final factoryTrucks = _parseFactoryTrucks(data);
    final godownConfig = data['godownConfig'] is Map<String, dynamic>
        ? GodownConfig.fromJson(data['godownConfig'] as Map<String, dynamic>)
        : GodownConfig.defaults();

    customers.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    invoices.sort((a, b) => a.sNo.compareTo(b.sNo));
    payments.sort((a, b) => a.id.compareTo(b.id));

    await CustomerStore.saveAll(customers);
    await Store.saveAll(invoices);
    await PaymentStore.saveAll(payments);
    await MobileAccessStore.saveOrders(orders, mergeExisting: false);
    if (surjaniTrucks != null) {
      await MobileAccessStore.saveSurjaniTrucks(surjaniTrucks);
    }
    if (factoryTrucks != null) {
      await MobileAccessStore.saveFactoryTrucks(factoryTrucks);
    }
    await GodownStockStore.saveConfig(godownConfig);

    await MobileAccessStore.saveServerConfig(
      config.copyWith(
        baseUrl: normalized,
        enabled: true,
        lastSyncAt: (data['serverTime'] ?? '').toString().trim().isEmpty
            ? DateTime.now().toIso8601String()
            : (data['serverTime'] ?? '').toString(),
        lastStatus:
            'Full synced ${customers.length} laptop customers, ${invoices.length} laptop invoices, ${payments.length} laptop payments, ${orders.length} orders.',
      ),
    );

    return ServerSyncResult(
      customerCount: customers.length,
      invoiceCount: invoices.length,
      paymentCount: payments.length,
      orderCount: orders.length,
    );
  }

  static Future<ServerSyncResult?> _syncChanges({
    required String normalized,
    required String token,
    required String since,
  }) async {
    final changesUri = Uri.parse('$normalized/sync/changes').replace(
      queryParameters: {'since': since},
    );
    final data = await _requestJson(
      changesUri,
      headers: {HttpHeaders.authorizationHeader: 'Bearer $token'},
    );
    if (data['fullRequired'] == true) return null;

    final customers = ((data['customers'] as List?) ?? const [])
        .map((e) => Customer.fromJson(e as Map<String, dynamic>))
        .toList();
    final invoices = ((data['invoices'] as List?) ?? const [])
        .map((e) => Invoice.fromJson(e as Map<String, dynamic>))
        .toList();
    final payments = ((data['payments'] as List?) ?? const [])
        .map((e) => PaymentEntry.fromJson(e as Map<String, dynamic>))
        .toList();
    final orders = ((data['orders'] as List?) ?? const [])
        .map((e) => MobileOrder.fromJson(e as Map<String, dynamic>))
        .toList();
    final surjaniTrucks = _parseSurjaniTrucks(data);
    final factoryTrucks = _parseFactoryTrucks(data);
    final deletedCustomers = ((data['deletedCustomers'] as List?) ?? const [])
        .map((e) => e.toString())
        .toSet();
    final deletedInvoices = ((data['deletedInvoices'] as List?) ?? const [])
        .map((e) => e.toString())
        .toSet();
    final deletedPayments = ((data['deletedPayments'] as List?) ?? const [])
        .map((e) => e.toString())
        .toSet();
    final godownConfig = data['godownConfig'] is Map<String, dynamic>
        ? GodownConfig.fromJson(data['godownConfig'] as Map<String, dynamic>)
        : null;

    final mergedCustomers = _applyCustomerChanges(
      await CustomerStore.loadAll(),
      customers,
      deletedCustomers,
    );
    final mergedInvoices = _applyInvoiceChanges(
      await Store.loadAll(),
      invoices,
      deletedInvoices,
    );
    final mergedPayments = _applyPaymentChanges(
      await PaymentStore.loadAll(),
      payments,
      deletedPayments,
    );

    await CustomerStore.saveAll(mergedCustomers);
    await Store.saveAll(mergedInvoices);
    await PaymentStore.saveAll(mergedPayments);
    await MobileAccessStore.saveOrders(orders, mergeExisting: false);
    if (surjaniTrucks != null) {
      await MobileAccessStore.saveSurjaniTrucks(surjaniTrucks);
    }
    if (factoryTrucks != null) {
      await MobileAccessStore.saveFactoryTrucks(factoryTrucks);
    }
    if (godownConfig != null) {
      await GodownStockStore.saveConfig(godownConfig);
    }

    final serverTime = (data['serverTime'] ?? '').toString().trim().isEmpty
        ? DateTime.now().toIso8601String()
        : (data['serverTime'] ?? '').toString();
    final config = await MobileAccessStore.loadServerConfig();
    await MobileAccessStore.saveServerConfig(
      config.copyWith(
        baseUrl: normalized,
        enabled: true,
        lastSyncAt: serverTime,
        lastStatus:
            'Synced changes: ${customers.length} customers, ${invoices.length} invoices, ${payments.length} payments, ${orders.length} orders.',
      ),
    );

    return ServerSyncResult(
      customerCount: customers.length,
      invoiceCount: invoices.length,
      paymentCount: payments.length,
      orderCount: orders.length,
    );
  }

  static Future<List<MobileOrder>> fetchOrders({
    required String baseUrl,
    required String username,
    required String passcode,
  }) async {
    final auth = await authenticateUser(
      baseUrl: baseUrl,
      username: username,
      passcode: passcode,
    );
    final normalized = _normalizeBaseUrl(baseUrl);
    final Map<String, dynamic> data;
    try {
      data = await _requestJson(
        Uri.parse('$normalized/orders'),
        headers: {HttpHeaders.authorizationHeader: 'Bearer ${auth.token}'},
      );
    } on ServerSyncException catch (e) {
      if (_isRouteNotFound(e)) {
        throw const ServerSyncException(
          'Orders are not available on this laptop server yet. Restart the laptop server after updating the desktop app.',
        );
      }
      rethrow;
    }
    final orders = ((data['orders'] as List?) ?? const [])
        .map((e) => MobileOrder.fromJson(e as Map<String, dynamic>))
        .toList();
    final surjaniTrucks = _parseSurjaniTrucks(data);
    final factoryTrucks = _parseFactoryTrucks(data);
    await MobileAccessStore.saveOrders(orders, mergeExisting: false);
    if (surjaniTrucks != null) {
      await MobileAccessStore.saveSurjaniTrucks(surjaniTrucks);
    }
    if (factoryTrucks != null) {
      await MobileAccessStore.saveFactoryTrucks(factoryTrucks);
    }
    return MobileAccessStore.loadOrders();
  }

  static List<MobileTruck>? _parseTruckList(
    Map<String, dynamic> data,
    String key,
  ) {
    final raw = data[key];
    if (raw is! List) return null;
    return raw
        .map((e) => MobileTruck.fromJson(e as Map<String, dynamic>))
        .where((truck) =>
            truck.id.trim().isNotEmpty &&
            truck.number.trim().isNotEmpty &&
            truck.capacity > 0)
        .toList();
  }

  static List<MobileTruck>? _parseSurjaniTrucks(Map<String, dynamic> data) {
    return _parseTruckList(data, 'surjaniTrucks');
  }

  static List<MobileTruck>? _parseFactoryTrucks(Map<String, dynamic> data) {
    return _parseTruckList(data, 'factoryTrucks');
  }

  static Future<List<MobileTruck>> saveSurjaniTrucks({
    required String baseUrl,
    required String username,
    required String passcode,
    required List<MobileTruck> trucks,
  }) async {
    final auth = await authenticateUser(
      baseUrl: baseUrl,
      username: username,
      passcode: passcode,
    );
    final normalized = _normalizeBaseUrl(baseUrl);
    final Map<String, dynamic> response;
    try {
      response = await _requestJson(
        Uri.parse('$normalized/surjani-trucks'),
        method: 'POST',
        headers: {HttpHeaders.authorizationHeader: 'Bearer ${auth.token}'},
        body: {'trucks': trucks.map((truck) => truck.toJson()).toList()},
      );
    } on ServerSyncException catch (e) {
      if (_isRouteNotFound(e)) {
        throw const ServerSyncException(
          'Surjani truck sync is not available on this laptop server yet. Restart the laptop app after updating it.',
        );
      }
      rethrow;
    }
    final saved = _parseSurjaniTrucks(response) ?? trucks;
    await MobileAccessStore.saveSurjaniTrucks(saved);
    return saved;
  }

  static Future<List<MobileTruck>> deleteSurjaniTruck({
    required String baseUrl,
    required String username,
    required String passcode,
    required String truckId,
  }) async {
    final auth = await authenticateUser(
      baseUrl: baseUrl,
      username: username,
      passcode: passcode,
    );
    final normalized = _normalizeBaseUrl(baseUrl);
    final encodedId = Uri.encodeComponent(truckId);
    final Map<String, dynamic> response;
    try {
      response = await _requestJson(
        Uri.parse('$normalized/surjani-trucks/$encodedId'),
        method: 'DELETE',
        headers: {HttpHeaders.authorizationHeader: 'Bearer ${auth.token}'},
      );
    } on ServerSyncException catch (e) {
      if (_isRouteNotFound(e)) {
        throw const ServerSyncException(
          'Surjani truck sync is not available on this laptop server yet. Restart the laptop app after updating it.',
        );
      }
      rethrow;
    }
    final saved = _parseSurjaniTrucks(response) ?? <MobileTruck>[];
    await MobileAccessStore.saveSurjaniTrucks(saved);
    return saved;
  }

  static Future<List<MobileTruck>> saveFactoryTrucks({
    required String baseUrl,
    required String username,
    required String passcode,
    required List<MobileTruck> trucks,
  }) async {
    final auth = await authenticateUser(
      baseUrl: baseUrl,
      username: username,
      passcode: passcode,
    );
    final normalized = _normalizeBaseUrl(baseUrl);
    final Map<String, dynamic> response;
    try {
      response = await _requestJson(
        Uri.parse('$normalized/factory-trucks'),
        method: 'POST',
        headers: {HttpHeaders.authorizationHeader: 'Bearer ${auth.token}'},
        body: {'trucks': trucks.map((truck) => truck.toJson()).toList()},
      );
    } on ServerSyncException catch (e) {
      if (_isRouteNotFound(e)) {
        throw const ServerSyncException(
          'Factory truck sync is not available on this laptop server yet. Restart the laptop app after updating it.',
        );
      }
      rethrow;
    }
    final saved = _parseFactoryTrucks(response) ?? trucks;
    await MobileAccessStore.saveFactoryTrucks(saved);
    return saved;
  }

  static Future<List<MobileTruck>> deleteFactoryTruck({
    required String baseUrl,
    required String username,
    required String passcode,
    required String truckId,
  }) async {
    final auth = await authenticateUser(
      baseUrl: baseUrl,
      username: username,
      passcode: passcode,
    );
    final normalized = _normalizeBaseUrl(baseUrl);
    final encodedId = Uri.encodeComponent(truckId);
    final Map<String, dynamic> response;
    try {
      response = await _requestJson(
        Uri.parse('$normalized/factory-trucks/$encodedId'),
        method: 'DELETE',
        headers: {HttpHeaders.authorizationHeader: 'Bearer ${auth.token}'},
      );
    } on ServerSyncException catch (e) {
      if (_isRouteNotFound(e)) {
        throw const ServerSyncException(
          'Factory truck sync is not available on this laptop server yet. Restart the laptop app after updating it.',
        );
      }
      rethrow;
    }
    final saved = _parseFactoryTrucks(response) ?? <MobileTruck>[];
    await MobileAccessStore.saveFactoryTrucks(saved);
    return saved;
  }

  static Future<GodownConfig> moveTruckBalanceToGodown({
    required String baseUrl,
    required String username,
    required String passcode,
    required String sourceSite,
    required String sourceTruckId,
    required String truckNo,
    required String date,
    required Map<String, int> typeBags,
    required List<Map<String, dynamic>> stockLines,
  }) async {
    final auth = await authenticateUser(
      baseUrl: baseUrl,
      username: username,
      passcode: passcode,
    );
    final normalized = _normalizeBaseUrl(baseUrl);
    final Map<String, dynamic> response;
    try {
      response = await _requestJson(
        Uri.parse('$normalized/godown/truck-balance'),
        method: 'POST',
        headers: {HttpHeaders.authorizationHeader: 'Bearer ${auth.token}'},
        body: {
          'sourceSite': sourceSite,
          'sourceTruckId': sourceTruckId,
          'truckNo': truckNo,
          'date': date,
          'typeBags': typeBags,
          'stockLines': stockLines,
        },
      );
    } on ServerSyncException catch (e) {
      if (_isRouteNotFound(e)) {
        throw const ServerSyncException(
          'Godown balance move is not available on this laptop server yet. Restart the laptop app after updating it.',
        );
      }
      rethrow;
    }
    final configJson = response['godownConfig'] is Map<String, dynamic>
        ? response['godownConfig'] as Map<String, dynamic>
        : const <String, dynamic>{};
    final config = GodownConfig.fromJson(configJson);
    await GodownStockStore.saveConfig(config);
    return config;
  }

  static Future<ServerOrderSaveResult> saveOrder({
    required String baseUrl,
    required String username,
    required String passcode,
    required Map<String, dynamic> payload,
  }) async {
    final auth = await authenticateUser(
      baseUrl: baseUrl,
      username: username,
      passcode: passcode,
    );
    final normalized = _normalizeBaseUrl(baseUrl);
    final Map<String, dynamic> response;
    try {
      response = await _requestJson(
        Uri.parse('$normalized/orders'),
        method: 'POST',
        headers: {HttpHeaders.authorizationHeader: 'Bearer ${auth.token}'},
        body: payload,
      );
    } on ServerSyncException catch (e) {
      if (_isRouteNotFound(e)) {
        throw const ServerSyncException(
          'Orders are not available on this laptop server yet. Restart the laptop server after updating the desktop app.',
        );
      }
      rethrow;
    }
    final orderJson = response['order'] is Map<String, dynamic>
        ? response['order'] as Map<String, dynamic>
        : const <String, dynamic>{};
    final order = _applyOrderPayload(
      MobileOrder.fromJson(orderJson),
      payload,
    );
    if (order.id.trim().isEmpty) {
      throw const ServerSyncException('Server did not return order.');
    }
    final saved = await MobileAccessStore.upsertOrder(
      order,
      preserveLocalFields: false,
    );
    return ServerOrderSaveResult(order: saved);
  }

  static Future<ServerOrderSaveResult> updateOrderStatus({
    required String baseUrl,
    required String username,
    required String passcode,
    required String orderId,
    required MobileOrderStatus status,
  }) async {
    final auth = await authenticateUser(
      baseUrl: baseUrl,
      username: username,
      passcode: passcode,
    );
    final normalized = _normalizeBaseUrl(baseUrl);
    final Map<String, dynamic> response;
    try {
      response = await _requestJson(
        Uri.parse('$normalized/orders/status'),
        method: 'POST',
        headers: {HttpHeaders.authorizationHeader: 'Bearer ${auth.token}'},
        body: {
          'id': orderId,
          'status': status.name,
        },
      );
    } on ServerSyncException catch (e) {
      if (_isRouteNotFound(e)) {
        throw const ServerSyncException(
          'Order status updates are not available on this laptop server yet. Restart the laptop app after updating it.',
        );
      }
      rethrow;
    }
    final orderJson = response['order'] is Map<String, dynamic>
        ? response['order'] as Map<String, dynamic>
        : const <String, dynamic>{};
    final order = MobileOrder.fromJson(orderJson);
    if (order.id.trim().isEmpty) {
      throw const ServerSyncException('Server did not return order.');
    }
    final saved = await MobileAccessStore.upsertOrder(order);
    return ServerOrderSaveResult(order: saved);
  }

  static Future<ServerOrderSaveResult> recordOrderInvoice({
    required String baseUrl,
    required String username,
    required String passcode,
    required String orderId,
    double? rate,
    double? cartage,
    String? customerName,
    String? customerContact,
  }) async {
    final auth = await authenticateUser(
      baseUrl: baseUrl,
      username: username,
      passcode: passcode,
    );
    final normalized = _normalizeBaseUrl(baseUrl);
    final body = <String, dynamic>{'id': orderId};
    if (rate != null) body['rate'] = rate;
    if (cartage != null) body['cartage'] = cartage;
    if ((customerName ?? '').trim().isNotEmpty) {
      body['customerName'] = customerName!.trim();
    }
    if ((customerContact ?? '').trim().isNotEmpty) {
      body['customerContact'] = customerContact!.trim();
    }
    final Map<String, dynamic> response;
    try {
      response = await _requestJson(
        Uri.parse('$normalized/orders/record-invoice'),
        method: 'POST',
        headers: {HttpHeaders.authorizationHeader: 'Bearer ${auth.token}'},
        body: body,
      );
    } on ServerSyncException catch (e) {
      if (_isRouteNotFound(e)) {
        throw const ServerSyncException(
          'Order invoice recording is not available on this laptop server yet. Restart the laptop app after updating it.',
        );
      }
      rethrow;
    }
    final orderJson = response['order'] is Map<String, dynamic>
        ? response['order'] as Map<String, dynamic>
        : const <String, dynamic>{};
    final order = MobileOrder.fromJson(orderJson);
    if (order.id.trim().isEmpty) {
      throw const ServerSyncException('Server did not return order.');
    }
    final saved = await MobileAccessStore.upsertOrder(
      order,
      preserveLocalFields: false,
    );
    return ServerOrderSaveResult(order: saved);
  }

  static Future<void> deleteOrder({
    required String baseUrl,
    required String username,
    required String passcode,
    required String orderId,
  }) async {
    final auth = await authenticateUser(
      baseUrl: baseUrl,
      username: username,
      passcode: passcode,
    );
    final normalized = _normalizeBaseUrl(baseUrl);
    final encodedId = Uri.encodeComponent(orderId);
    try {
      await _requestJson(
        Uri.parse('$normalized/orders/$encodedId'),
        method: 'DELETE',
        headers: {HttpHeaders.authorizationHeader: 'Bearer ${auth.token}'},
      );
    } on ServerSyncException catch (e) {
      if (_isRouteNotFound(e)) {
        throw const ServerSyncException(
          'Order delete is not available on this laptop server yet. Restart the laptop app after updating it.',
        );
      }
      rethrow;
    }
    await MobileAccessStore.deleteOrder(orderId);
  }

  static MobileOrder _applyOrderPayload(
    MobileOrder order,
    Map<String, dynamic> payload,
  ) {
    return order.copyWith(
      orderDate: payload.containsKey('orderDate')
          ? (payload['orderDate'] ?? '').toString()
          : null,
      customerName: payload.containsKey('customerName')
          ? (payload['customerName'] ?? '').toString()
          : null,
      plotNo: payload.containsKey('plotNo')
          ? (payload['plotNo'] ?? '').toString()
          : null,
      bagsQuantity: payload.containsKey('bagsQuantity')
          ? ((payload['bagsQuantity'] as num?)?.toInt() ??
              int.tryParse((payload['bagsQuantity'] ?? '').toString()) ??
              order.bagsQuantity)
          : null,
      bagsType: payload.containsKey('bagsType')
          ? (payload['bagsType'] ?? '').toString()
          : null,
      bagsBrand: payload.containsKey('bagsBrand')
          ? (payload['bagsBrand'] ?? '').toString()
          : null,
      orderSite: payload.containsKey('orderSite')
          ? (payload['orderSite'] ?? '').toString()
          : null,
      assignedTruckId: payload.containsKey('assignedTruckId')
          ? (payload['assignedTruckId'] ?? '').toString()
          : null,
      assignedTruckNo: payload.containsKey('assignedTruckNo')
          ? (payload['assignedTruckNo'] ?? '').toString()
          : null,
      note: payload.containsKey('note')
          ? (payload['note'] ?? '').toString()
          : null,
      status: payload.containsKey('status')
          ? mobileOrderStatusFromString((payload['status'] ?? '').toString())
          : null,
    );
  }

  static Future<ServerDraftSubmitResult> submitDraftInvoice({
    required String baseUrl,
    required String username,
    required String passcode,
    required Map<String, dynamic> payload,
  }) async {
    final auth = await authenticateUser(
      baseUrl: baseUrl,
      username: username,
      passcode: passcode,
    );
    final normalized = _normalizeBaseUrl(baseUrl);
    final submitUri = Uri.parse('$normalized/pending-invoices');
    final response = await _requestJson(
      submitUri,
      method: 'POST',
      headers: {HttpHeaders.authorizationHeader: 'Bearer ${auth.token}'},
      body: payload,
    );
    final draftCode = (response['draftCode'] ?? '').toString();
    if (draftCode.isEmpty) {
      throw const ServerSyncException('Server did not return draft code.');
    }
    return ServerDraftSubmitResult(draftCode: draftCode);
  }

  static Future<void> submitPayment({
    required String baseUrl,
    required String username,
    required String passcode,
    required PaymentEntry payment,
  }) async {
    final auth = await authenticateUser(
      baseUrl: baseUrl,
      username: username,
      passcode: passcode,
    );
    final normalized = _normalizeBaseUrl(baseUrl);
    final submitUri = Uri.parse('$normalized/payments');
    await _requestJson(
      submitUri,
      method: 'POST',
      headers: {HttpHeaders.authorizationHeader: 'Bearer ${auth.token}'},
      body: payment.toJson(),
    );
  }

  static Future<void> deletePayment({
    required String baseUrl,
    required String username,
    required String passcode,
    required String paymentId,
  }) async {
    final auth = await authenticateUser(
      baseUrl: baseUrl,
      username: username,
      passcode: passcode,
    );
    final normalized = _normalizeBaseUrl(baseUrl);
    final encodedId = Uri.encodeComponent(paymentId);
    final submitUri = Uri.parse('$normalized/payments/$encodedId');
    await _requestJson(
      submitUri,
      method: 'DELETE',
      headers: {HttpHeaders.authorizationHeader: 'Bearer ${auth.token}'},
    );
  }

  static Future<void> submitLocation({
    required String baseUrl,
    required String username,
    required String passcode,
    required double latitude,
    required double longitude,
    required double? accuracyMeters,
    required String capturedAt,
    required String deviceId,
  }) async {
    final auth = await authenticateUser(
      baseUrl: baseUrl,
      username: username,
      passcode: passcode,
    );
    final normalized = _normalizeBaseUrl(baseUrl);
    await _requestJson(
      Uri.parse('$normalized/locations'),
      method: 'POST',
      headers: {HttpHeaders.authorizationHeader: 'Bearer ${auth.token}'},
      body: {
        'sharingEnabled': true,
        'latitude': latitude,
        'longitude': longitude,
        'accuracyMeters': accuracyMeters,
        'capturedAt': capturedAt,
        'deviceId': deviceId,
      },
    );
  }

  static Future<ServerAuthResult> authenticateUser({
    required String baseUrl,
    required String username,
    required String passcode,
  }) async {
    final normalized = _normalizeBaseUrl(baseUrl);
    final loginUri = Uri.parse('$normalized/auth/login');
    final loginResponse = await _requestJson(
      loginUri,
      method: 'POST',
      body: {'username': username, 'passcode': passcode},
    );
    final token = (loginResponse['token'] ?? '').toString();
    if (token.isEmpty) {
      throw const ServerSyncException('Server login failed.');
    }
    final userJson = loginResponse['user'] is Map<String, dynamic>
        ? loginResponse['user'] as Map<String, dynamic>
        : const <String, dynamic>{};
    final now = DateTime.now().toIso8601String();
    return ServerAuthResult(
      token: token,
      user: AppUser(
        id: (userJson['id'] ?? '').toString(),
        username: (userJson['username'] ?? username).toString(),
        displayName: (userJson['displayName'] ?? username).toString(),
        passcode: passcode,
        role: userRoleFromString((userJson['role'] ?? '').toString()),
        active: true,
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  static Future<Map<String, dynamic>> _requestJson(
    Uri uri, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String>? headers,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final HttpClientRequest request;
      if (method == 'POST') {
        request = await client.postUrl(uri);
      } else if (method == 'DELETE') {
        request = await client.deleteUrl(uri);
      } else {
        request = await client.getUrl(uri);
      }
      headers?.forEach(request.headers.set);
      if (body != null) {
        request.headers.contentType =
            ContentType('application', 'json', charset: 'utf-8');
        request.write(jsonEncode(body));
      }
      final response = await request.close();
      final text = await utf8.decodeStream(response);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        try {
          final decoded = jsonDecode(text);
          if (decoded is Map<String, dynamic> &&
              (decoded['error'] ?? '').toString().trim().isNotEmpty) {
            throw ServerSyncException((decoded['error'] ?? '').toString());
          }
        } on FormatException {
          // Fall through to the raw response text below.
        }
        throw ServerSyncException(
          text.isEmpty ? 'Server request failed.' : text,
        );
      }
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        throw const ServerSyncException('Server returned invalid JSON.');
      }
      if ((decoded['error'] ?? '').toString().trim().isNotEmpty) {
        throw ServerSyncException((decoded['error'] ?? '').toString());
      }
      return decoded;
    } on SocketException {
      throw const ServerSyncException('Laptop server is not reachable.');
    } finally {
      client.close(force: true);
    }
  }

  static String _normalizeBaseUrl(String baseUrl) {
    final trimmed = baseUrl.trim();
    if (trimmed.isEmpty) {
      throw const ServerSyncException('Server URL is required.');
    }
    return trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
  }

  static bool _isRouteNotFound(ServerSyncException e) {
    return e.message.toLowerCase().contains('route not found');
  }

  static List<Customer> _applyCustomerChanges(
    List<Customer> local,
    List<Customer> changed,
    Set<String> deleted,
  ) {
    final byId = {for (final item in local) _customerSyncId(item): item};
    for (final id in deleted) {
      byId.remove(id);
    }
    for (final item in changed) {
      byId[_customerSyncId(item)] = item;
    }
    final values = byId.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return values;
  }

  static List<Invoice> _applyInvoiceChanges(
    List<Invoice> local,
    List<Invoice> changed,
    Set<String> deleted,
  ) {
    final byId = {for (final item in local) item.sNo.toString(): item};
    for (final id in deleted) {
      byId.remove(id);
    }
    for (final item in changed) {
      byId[item.sNo.toString()] = item;
    }
    final values = byId.values.toList()..sort((a, b) => a.sNo.compareTo(b.sNo));
    return values;
  }

  static List<PaymentEntry> _applyPaymentChanges(
    List<PaymentEntry> local,
    List<PaymentEntry> changed,
    Set<String> deleted,
  ) {
    final byId = {for (final item in local) _paymentSyncId(item): item};
    for (final id in deleted) {
      byId.remove(id);
    }
    for (final item in changed) {
      byId[_paymentSyncId(item)] = item;
    }
    final values = byId.values.toList()..sort((a, b) => a.id.compareTo(b.id));
    return values;
  }

  static String _customerSyncId(Customer item) {
    final id = item.id.trim();
    if (id.isNotEmpty) return id;
    return item.name.trim().toLowerCase();
  }

  static String _paymentSyncId(PaymentEntry item) {
    final id = item.id.trim();
    if (id.isNotEmpty) return id;
    return '${item.date}|${item.customerId}|${item.customer}|${item.amount}|${item.type.name}';
  }
}

class ServerSyncException implements Exception {
  final String message;

  const ServerSyncException(this.message);

  @override
  String toString() => message;
}
