import 'dart:async';
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

class _CachedServerAuth {
  final String baseUrl;
  final String username;
  final String passcode;
  final ServerAuthResult result;
  final DateTime expiresAt;

  const _CachedServerAuth({
    required this.baseUrl,
    required this.username,
    required this.passcode,
    required this.result,
    required this.expiresAt,
  });
}

class ServerSyncClient {
  static const _authLifetime = Duration(minutes: 30);
  static final HttpClient _httpClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    ..idleTimeout = const Duration(seconds: 30)
    ..maxConnectionsPerHost = 6;
  static final Map<String, _CachedServerAuth> _authByKey = {};
  static final Map<String, _CachedServerAuth> _authByToken = {};
  static final Map<String, Future<ServerAuthResult>> _authInFlight = {};

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

  static Future<Invoice> recordWalkInInvoice({
    required String baseUrl,
    required String username,
    required String passcode,
    required String invoiceDate,
    required String customer,
    required String contact,
    required String address,
    required String site,
    required List<ItemLine> lines,
    required double cartage,
    required PaymentType paymentType,
    required String orderId,
    String? paymentNote,
    String? bank,
    String? chequeNo,
    String? txnId,
    String? bankMode,
  }) async {
    final auth = await authenticateUser(
      baseUrl: baseUrl,
      username: username,
      passcode: passcode,
    );
    final normalized = _normalizeBaseUrl(baseUrl);
    final body = <String, dynamic>{
      'orderId': orderId,
      'invoiceDate': invoiceDate,
      'customer': customer,
      'contact': contact,
      'address': address,
      'site': site,
      'lines': lines.map((line) => line.toJson()).toList(),
      'cartage': cartage,
      'paymentType': paymentTypeLabel(paymentType),
      if ((paymentNote ?? '').trim().isNotEmpty)
        'paymentNote': paymentNote!.trim(),
      if ((bank ?? '').trim().isNotEmpty) 'bank': bank!.trim(),
      if ((chequeNo ?? '').trim().isNotEmpty) 'chequeNo': chequeNo!.trim(),
      if ((txnId ?? '').trim().isNotEmpty) 'txnId': txnId!.trim(),
      if ((bankMode ?? '').trim().isNotEmpty) 'bankMode': bankMode!.trim(),
    };
    final Map<String, dynamic> response;
    try {
      response = await _requestJson(
        Uri.parse('$normalized/walk-in-invoices'),
        method: 'POST',
        headers: {HttpHeaders.authorizationHeader: 'Bearer ${auth.token}'},
        body: body,
      );
    } on ServerSyncException catch (e) {
      if (_isRouteNotFound(e)) {
        throw const ServerSyncException(
          'Walk-in sale recording is not available on this laptop server yet. Restart the laptop app after updating it.',
        );
      }
      rethrow;
    }
    final invoiceJson = response['invoice'] is Map<String, dynamic>
        ? response['invoice'] as Map<String, dynamic>
        : const <String, dynamic>{};
    final invoice = Invoice.fromJson(invoiceJson);
    if (invoice.sNo <= 0) {
      throw const ServerSyncException('Server did not return invoice.');
    }
    await Store.upsertInvoice(invoice);
    final orderJson = response['order'];
    if (orderJson is Map<String, dynamic>) {
      final order = MobileOrder.fromJson(orderJson);
      if (order.id.trim().isNotEmpty) {
        await MobileAccessStore.upsertOrder(
          order,
          preserveLocalFields: false,
        );
      }
    }
    return invoice;
  }

  static Future<Invoice> recordInvoiceReturn({
    required String baseUrl,
    required String username,
    required String passcode,
    required int sourceInvoiceNo,
    required String returnDate,
    required List<ItemLine> lines,
  }) async {
    final auth = await authenticateUser(
      baseUrl: baseUrl,
      username: username,
      passcode: passcode,
    );
    final normalized = _normalizeBaseUrl(baseUrl);
    final canonicalLines = lines
        .map((line) => {
              'type': line.typeLabel.trim(),
              'brand': line.brand.trim(),
              'qty': line.qty.abs(),
            })
        .toList()
      ..sort((a, b) =>
          '${a['type']}|${a['brand']}'.compareTo('${b['type']}|${b['brand']}'));
    final requestId = base64Url
        .encode(utf8.encode(jsonEncode({
          'invoice': sourceInvoiceNo,
          'date': returnDate,
          'lines': canonicalLines,
        })))
        .replaceAll('=', '');
    final Map<String, dynamic> response;
    try {
      response = await _requestJson(
        Uri.parse('$normalized/invoice-returns'),
        method: 'POST',
        headers: {HttpHeaders.authorizationHeader: 'Bearer ${auth.token}'},
        body: {
          'requestId': 'MRET-$requestId',
          'sourceInvoiceNo': sourceInvoiceNo,
          'returnDate': returnDate,
          'lines': canonicalLines,
        },
      );
    } on ServerSyncException catch (error) {
      if (_isRouteNotFound(error)) {
        throw const ServerSyncException(
          'Mobile returns are not available on this laptop server yet. Install and restart the updated laptop app.',
        );
      }
      rethrow;
    }
    final invoiceJson = response['invoice'] is Map<String, dynamic>
        ? response['invoice'] as Map<String, dynamic>
        : const <String, dynamic>{};
    final invoice = Invoice.fromJson(invoiceJson);
    if (invoice.sNo <= 0 || !invoice.isReturn) {
      throw const ServerSyncException(
          'Server did not return the saved return.');
    }
    await Store.upsertInvoice(invoice);
    return invoice;
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

  static Future<void> deleteInvoiceReturn({
    required String baseUrl,
    required String username,
    required String passcode,
    required int invoiceNo,
  }) async {
    final auth = await authenticateUser(
      baseUrl: baseUrl,
      username: username,
      passcode: passcode,
    );
    final normalized = _normalizeBaseUrl(baseUrl);
    try {
      await _requestJson(
        Uri.parse('$normalized/invoice-returns/$invoiceNo'),
        method: 'DELETE',
        headers: {HttpHeaders.authorizationHeader: 'Bearer ${auth.token}'},
      );
    } on ServerSyncException catch (e) {
      if (_isRouteNotFound(e)) {
        throw const ServerSyncException(
          'Return delete is not available on this laptop server yet. Restart the laptop app after updating it.',
        );
      }
      rethrow;
    }
    await Store.deleteInvoice(invoiceNo);
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

  static Future<void> registerPushToken({
    required String baseUrl,
    required String username,
    required String passcode,
    required String pushToken,
    required String deviceId,
    required String platform,
  }) async {
    final auth = await authenticateUser(
      baseUrl: baseUrl,
      username: username,
      passcode: passcode,
    );
    final normalized = _normalizeBaseUrl(baseUrl);
    await _requestJson(
      Uri.parse('$normalized/push-tokens'),
      method: 'POST',
      headers: {HttpHeaders.authorizationHeader: 'Bearer ${auth.token}'},
      body: {
        'token': pushToken,
        'deviceId': deviceId,
        'platform': platform,
      },
    );
  }

  static Future<ServerAuthResult> authenticateUser({
    required String baseUrl,
    required String username,
    required String passcode,
    bool forceRefresh = false,
  }) async {
    final normalized = _normalizeBaseUrl(baseUrl);
    final authKey = _authKey(normalized, username, passcode);
    final cached = _authByKey[authKey];
    if (!forceRefresh &&
        cached != null &&
        cached.expiresAt.isAfter(DateTime.now())) {
      return cached.result;
    }
    if (cached != null) _removeCachedAuth(cached);

    final inFlight = _authInFlight[authKey];
    if (!forceRefresh && inFlight != null) return inFlight;

    final login = _login(
      normalized: normalized,
      username: username,
      passcode: passcode,
      authKey: authKey,
    );
    _authInFlight[authKey] = login;
    try {
      return await login;
    } finally {
      if (identical(_authInFlight[authKey], login)) {
        _authInFlight.remove(authKey);
      }
    }
  }

  static Future<ServerAuthResult> _login({
    required String normalized,
    required String username,
    required String passcode,
    required String authKey,
  }) async {
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
    final result = ServerAuthResult(
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
    final cached = _CachedServerAuth(
      baseUrl: normalized,
      username: username,
      passcode: passcode,
      result: result,
      expiresAt: DateTime.now().add(_authLifetime),
    );
    _authByKey[authKey] = cached;
    _authByToken[token] = cached;
    return result;
  }

  static String _authKey(String baseUrl, String username, String passcode) =>
      '$baseUrl\u0000${username.trim().toLowerCase()}\u0000$passcode';

  static void _removeCachedAuth(_CachedServerAuth cached) {
    _authByKey.remove(
      _authKey(cached.baseUrl, cached.username, cached.passcode),
    );
    _authByToken.remove(cached.result.token);
  }

  static Future<Map<String, dynamic>> _requestJson(
    Uri uri, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String>? headers,
    bool allowAuthRetry = true,
  }) async {
    try {
      final HttpClientRequest request;
      if (method == 'POST') {
        request = await _httpClient.postUrl(uri);
      } else if (method == 'DELETE') {
        request = await _httpClient.deleteUrl(uri);
      } else {
        request = await _httpClient.getUrl(uri);
      }
      headers?.forEach(request.headers.set);
      if (body != null) {
        request.headers.contentType =
            ContentType('application', 'json', charset: 'utf-8');
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(
            const Duration(seconds: 25),
          );
      final text = await utf8.decodeStream(response).timeout(
            const Duration(seconds: 25),
          );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (response.statusCode == HttpStatus.unauthorized && allowAuthRetry) {
          final authorization =
              headers?[HttpHeaders.authorizationHeader]?.trim() ?? '';
          final token = authorization.toLowerCase().startsWith('bearer ')
              ? authorization.substring(7).trim()
              : '';
          final cached = _authByToken[token];
          if (cached != null) {
            _removeCachedAuth(cached);
            final refreshed = await authenticateUser(
              baseUrl: cached.baseUrl,
              username: cached.username,
              passcode: cached.passcode,
              forceRefresh: true,
            );
            return _requestJson(
              uri,
              method: method,
              body: body,
              headers: {
                ...?headers,
                HttpHeaders.authorizationHeader: 'Bearer ${refreshed.token}',
              },
              allowAuthRetry: false,
            );
          }
        }
        throw ServerSyncException(
          _readableHttpError(
            statusCode: response.statusCode,
            responseText: text,
            cloudflareRay: response.headers.value('cf-ray'),
          ),
        );
      }
      final dynamic decoded;
      try {
        decoded = jsonDecode(text);
      } on FormatException {
        if (_looksLikeHtml(text)) {
          throw const ServerSyncException(
            'The tunnel returned a web page instead of QuickBill data. '
            'Check the Cloudflare hostname and Access rules. [INVALID RESPONSE]',
          );
        }
        throw const ServerSyncException(
          'The laptop returned unreadable data. Restart the updated laptop app. '
          '[INVALID JSON]',
        );
      }
      if (decoded is! Map<String, dynamic>) {
        throw const ServerSyncException(
          'The laptop returned an unexpected response. Restart the laptop app. '
          '[INVALID JSON]',
        );
      }
      if ((decoded['error'] ?? '').toString().trim().isNotEmpty) {
        throw ServerSyncException((decoded['error'] ?? '').toString());
      }
      return decoded;
    } on TimeoutException {
      throw const ServerSyncException(
        'The request timed out. Check the laptop internet connection and make '
        'sure the Cloudflare tunnel is running. [TIMEOUT]',
      );
    } on HandshakeException {
      throw const ServerSyncException(
        'A secure connection could not be established. Check the Cloudflare '
        'hostname and SSL certificate. [TLS]',
      );
    } on SocketException catch (error) {
      final message = error.osError?.message.toLowerCase() ?? '';
      if (message.contains('name') || message.contains('host')) {
        throw const ServerSyncException(
          'The Cloudflare hostname could not be found. Check the saved server '
          'URL and internet connection. [DNS]',
        );
      }
      throw const ServerSyncException(
        'Could not reach the laptop through Cloudflare. Check internet on both '
        'devices and confirm cloudflared is running. [NETWORK]',
      );
    } on HttpException {
      throw const ServerSyncException(
        'The connection ended before QuickBill received a complete response. '
        'Restart the Cloudflare tunnel and try again. [CONNECTION]',
      );
    }
  }

  static String _normalizeBaseUrl(String baseUrl) {
    final trimmed = baseUrl.trim();
    if (trimmed.isEmpty) {
      throw const ServerSyncException('Server URL is required.');
    }
    final normalized = trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;
    final uri = Uri.tryParse(normalized);
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.trim().isEmpty) {
      throw const ServerSyncException(
        'Server URL is invalid. Use the full Cloudflare address, for example '
        'https://quickbill.example.com. [INVALID URL]',
      );
    }
    return normalized;
  }

  static bool _isRouteNotFound(ServerSyncException e) {
    final message = e.message.toLowerCase();
    return message.contains('route not found') ||
        message.contains('[http 404]');
  }

  static String _readableHttpError({
    required int statusCode,
    required String responseText,
    String? cloudflareRay,
  }) {
    final cloudflareCode = _cloudflareErrorCode(responseText);
    final reference = (cloudflareRay ?? '').trim();
    final suffix = [
      if (cloudflareCode != null) 'CF $cloudflareCode',
      'HTTP $statusCode',
      if (reference.isNotEmpty) 'Ref $reference',
    ].join(' | ');

    if (cloudflareCode != null) {
      return '${_cloudflareCodeMessage(cloudflareCode)} [$suffix]';
    }

    final serverMessage = _jsonErrorMessage(responseText);
    switch (statusCode) {
      case HttpStatus.badRequest:
        return '${serverMessage ?? 'The request was not accepted. Update both the mobile and laptop apps, then try again.'} [$suffix]';
      case HttpStatus.unauthorized:
        return 'Login was rejected. Check the username and passcode, then log in again. [$suffix]';
      case HttpStatus.forbidden:
        return 'Cloudflare or QuickBill blocked this request. Check Cloudflare Access rules and the user role. [$suffix]';
      case HttpStatus.notFound:
        return 'This QuickBill feature was not found on the laptop. Restart or update the laptop app and verify the tunnel URL. [$suffix]';
      case HttpStatus.methodNotAllowed:
        return 'The laptop does not support this operation yet. Update and restart the laptop app. [$suffix]';
      case HttpStatus.requestTimeout:
        return 'The request timed out before reaching QuickBill. Check cloudflared and try again. [$suffix]';
      case HttpStatus.conflict:
        return '${serverMessage ?? 'The record changed on another device. Sync and try again.'} [$suffix]';
      case HttpStatus.requestEntityTooLarge:
        return 'The request is too large for the Cloudflare tunnel. [$suffix]';
      case HttpStatus.tooManyRequests:
        return 'Too many requests were sent. Wait a moment and try again. [$suffix]';
      case HttpStatus.internalServerError:
        return '${serverMessage ?? 'QuickBill encountered an error on the laptop. Restart the laptop app and try again.'} [$suffix]';
      case HttpStatus.badGateway:
        return 'Cloudflare is online, but it cannot reach the QuickBill laptop server. Make sure the laptop app and cloudflared are running. [$suffix]';
      case HttpStatus.serviceUnavailable:
        return 'The QuickBill tunnel is temporarily unavailable. Check cloudflared on the laptop. [$suffix]';
      case HttpStatus.gatewayTimeout:
        return 'Cloudflare reached the tunnel, but the laptop took too long to respond. [$suffix]';
      case 520:
        return 'Cloudflare received an unexpected response from the laptop. Restart QuickBill and cloudflared. [$suffix]';
      case 521:
        return 'Cloudflare could not connect to the laptop server. Open QuickBill and check its local server. [$suffix]';
      case 522:
        return 'Cloudflare timed out while connecting to the laptop. Check the laptop internet and tunnel. [$suffix]';
      case 523:
        return 'Cloudflare cannot find the tunnel origin. Check the tunnel hostname and DNS route. [$suffix]';
      case 524:
        return 'The laptop connection was made, but QuickBill did not respond in time. [$suffix]';
      case 525:
        return 'Cloudflare could not complete the SSL handshake. Check the tunnel certificate settings. [$suffix]';
      case 526:
        return 'Cloudflare rejected the origin SSL certificate. Check the tunnel SSL mode. [$suffix]';
      case 530:
        return 'Cloudflare cannot route this hostname to a healthy tunnel. Check that cloudflared is connected. [$suffix]';
      default:
        return '${serverMessage ?? 'The server request failed.'} [$suffix]';
    }
  }

  static String? _jsonErrorMessage(String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return null;
      final error = decoded['error'];
      if (error is String && error.trim().isNotEmpty) return error.trim();
      if (error is Map<String, dynamic>) {
        final message = (error['message'] ?? '').toString().trim();
        if (message.isNotEmpty) return message;
      }
      final message = (decoded['message'] ?? '').toString().trim();
      return message.isEmpty ? null : message;
    } catch (_) {
      return null;
    }
  }

  static int? _cloudflareErrorCode(String text) {
    final patterns = <RegExp>[
      RegExp(r'error\s*code\s*[:#]?\s*(\d{3,4})', caseSensitive: false),
      RegExp(r'cloudflare[^\d]{0,40}(\d{3,4})', caseSensitive: false),
      RegExp(r'<span[^>]*class="code-label"[^>]*>[^\d]*(\d{3,4})',
          caseSensitive: false),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(text);
      final code = int.tryParse(match?.group(1) ?? '');
      if (code != null) return code;
    }
    return null;
  }

  static String _cloudflareCodeMessage(int code) {
    switch (code) {
      case 1000:
        return 'Cloudflare DNS points to an address it cannot use. Check the tunnel DNS route.';
      case 1001:
        return 'Cloudflare could not resolve the configured hostname. Check the tunnel DNS record.';
      case 1016:
        return 'Cloudflare cannot resolve the tunnel origin. Recheck the public hostname configuration.';
      case 1020:
        return 'Cloudflare Access or firewall rules denied this phone. Allow the QuickBill API hostname.';
      case 1033:
        return 'Cloudflare cannot find a healthy QuickBill tunnel. Start cloudflared on the laptop and check its connection.';
      default:
        return 'Cloudflare rejected the connection. Check the tunnel dashboard using the code shown.';
    }
  }

  static bool _looksLikeHtml(String text) {
    final lower = text.trimLeft().toLowerCase();
    return lower.startsWith('<!doctype html') ||
        lower.startsWith('<html') ||
        lower.contains('<title>cloudflare');
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
