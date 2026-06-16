import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/constants.dart';
import '../models/customer.dart';
import '../models/invoice.dart';
import '../models/mobile_access.dart';
import '../models/payment.dart';
import '../utils/date.dart';
import 'excel_service.dart';
import 'godown_stock_store.dart';
import 'mobile_sync_store.dart';
import 'notification_service.dart';
import 'storage.dart';
import 'sync_change_log_store.dart';

class LocalApiServer {
  static HttpServer? _server;
  static final Map<String, String> _sessions = <String, String>{};

  static bool get isRunning => _server != null;

  static int? get port => _server?.port;

  static Future<void> start({
    required String host,
    required int port,
  }) async {
    if (_server != null) {
      await stop();
    }
    _server = await HttpServer.bind(host, port);
    _server!.listen(_handleRequest, onError: (_) {});
  }

  static Future<void> stop() async {
    final server = _server;
    _server = null;
    _sessions.clear();
    await server?.close(force: true);
  }

  static Future<List<String>> reachableAddresses([int? preferredPort]) async {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.any,
    );
    final seen = <String>{};
    final addresses = <String>[];
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        if (addr.type != InternetAddressType.IPv4) continue;
        final value = 'http://${addr.address}:${preferredPort ?? port ?? 8787}';
        if (seen.add(value)) {
          addresses.add(value);
        }
      }
    }
    addresses.sort();
    return addresses;
  }

  static Future<void> _handleRequest(HttpRequest request) async {
    try {
      final path = request.uri.path;
      if (request.method == 'GET' && path == '/health') {
        return _writeJson(request, HttpStatus.ok, {
          'ok': true,
          'app': 'QuickBill',
          'time': DateTime.now().toIso8601String(),
        });
      }
      if (request.method == 'POST' && path == '/auth/login') {
        final body = await utf8.decodeStream(request);
        final decoded = jsonDecode(body);
        if (decoded is! Map<String, dynamic>) {
          return _writeJson(
            request,
            HttpStatus.badRequest,
            {'error': 'Invalid JSON body.'},
          );
        }
        final username =
            (decoded['username'] ?? '').toString().trim().toLowerCase();
        final passcode = (decoded['passcode'] ?? '').toString().trim();
        final users = await MobileAccessStore.loadUsers();
        final user = users.cast<AppUser?>().firstWhere(
              (item) =>
                  item != null &&
                  item.active &&
                  item.username.toLowerCase() == username &&
                  item.passcode == passcode,
              orElse: () => null,
            );
        if (user == null) {
          return _writeJson(
            request,
            HttpStatus.unauthorized,
            {'error': 'Invalid credentials.'},
          );
        }
        final token = 'qb-${DateTime.now().microsecondsSinceEpoch}';
        _sessions[token] = user.id;
        return _writeJson(request, HttpStatus.ok, {
          'token': token,
          'user': {
            'id': user.id,
            'username': user.username,
            'displayName': user.displayName,
            'role': user.role.name,
          },
        });
      }
      if (request.method == 'GET' && path == '/sync/read-only') {
        final user = await _authorizedUser(request);
        if (user == null) {
          return _writeJson(
            request,
            HttpStatus.unauthorized,
            {'error': 'Unauthorized.'},
          );
        }
        final customers = await CustomerStore.loadAll();
        final invoices = await Store.loadAll();
        final payments = await PaymentStore.loadAll();
        final orders = await MobileAccessStore.loadOrders();
        final surjaniTrucks = await MobileAccessStore.loadSurjaniTrucks();
        final factoryTrucks = await MobileAccessStore.loadFactoryTrucks();
        final godownConfig = await GodownStockStore.loadConfig();
        invoices.sort((a, b) => b.sNo.compareTo(a.sNo));
        payments.sort((a, b) => b.id.compareTo(a.id));
        return _writeJson(request, HttpStatus.ok, {
          'customers': customers.map((e) => e.toJson()).toList(),
          'invoices': invoices.map((e) => e.toJson()).toList(),
          'payments': payments.map((e) => e.toJson()).toList(),
          'orders': orders.map((e) => e.toJson()).toList(),
          'surjaniTrucks': surjaniTrucks.map((e) => e.toJson()).toList(),
          'factoryTrucks': factoryTrucks.map((e) => e.toJson()).toList(),
          'godownConfig': godownConfig.toJson(),
          'serverTime': DateTime.now().toIso8601String(),
          'userRole': user.role.name,
        });
      }
      if (request.method == 'POST' && path == '/payments') {
        final user = await _authorizedUser(request);
        if (user == null) {
          return _writeJson(
            request,
            HttpStatus.unauthorized,
            {'error': 'Unauthorized.'},
          );
        }
        if (user.role != UserRole.admin) {
          return _writeJson(
            request,
            HttpStatus.forbidden,
            {'error': 'Only admin accounts can add payments.'},
          );
        }
        final body = await utf8.decodeStream(request);
        final decoded = jsonDecode(body);
        if (decoded is! Map<String, dynamic>) {
          return _writeJson(
            request,
            HttpStatus.badRequest,
            {'error': 'Invalid JSON body.'},
          );
        }
        var payment = PaymentEntry.fromJson(decoded);
        if (payment.customer.trim().isEmpty || payment.effectiveAmount <= 0) {
          return _writeJson(
            request,
            HttpStatus.badRequest,
            {'error': 'Customer and amount are required.'},
          );
        }
        if (payment.id.trim().isEmpty) {
          payment = PaymentEntry(
            id: await PaymentStore.nextPaymentId(),
            date: payment.date,
            customerId: payment.customerId,
            customer: payment.customer,
            type: payment.type,
            amount: payment.amount,
            discount: payment.discount,
            note: payment.note,
            chequeNo: payment.chequeNo,
            bank: payment.bank,
            txnId: payment.txnId,
            bankMode: payment.bankMode,
          );
        }
        final existing = await PaymentStore.loadAll();
        if (!existing.any((entry) => entry.id == payment.id)) {
          DateTime paymentDate;
          try {
            paymentDate = parseInvoiceDate(payment.date);
          } catch (_) {
            paymentDate = DateTime.now();
          }
          payment = await addPaymentForCustomer(
            customerId: payment.customerId,
            customerName: payment.customer,
            type: payment.type,
            date: paymentDate,
            amount: payment.amount,
            discount: payment.discount,
            paymentId: payment.id,
            chequeNo: payment.chequeNo,
            bank: payment.bank,
            txnId: payment.txnId,
            bankMode: payment.bankMode,
            note: payment.note,
          );
        }
        await MobileAccessStore.addSyncLog(
          SyncLogEntry(
            id: MobileAccessStore.nextSyncLogId(),
            createdAt: DateTime.now().toIso8601String(),
            direction: SyncLogDirection.incoming,
            status: SyncLogStatus.success,
            entityType: 'payment',
            entityId: payment.id,
            summary: 'Received mobile payment',
            details: '${payment.customer} - ${user.username}',
          ),
        );
        return _writeJson(request, HttpStatus.ok, {
          'ok': true,
          'paymentId': payment.id,
        });
      }
      if (request.method == 'DELETE' &&
          request.uri.pathSegments.length == 2 &&
          request.uri.pathSegments.first == 'payments') {
        final user = await _authorizedUser(request);
        if (user == null) {
          return _writeJson(
            request,
            HttpStatus.unauthorized,
            {'error': 'Unauthorized.'},
          );
        }
        if (user.role != UserRole.admin) {
          return _writeJson(
            request,
            HttpStatus.forbidden,
            {'error': 'Only admin accounts can delete payments.'},
          );
        }
        final paymentId = request.uri.pathSegments[1].trim();
        if (paymentId.isEmpty) {
          return _writeJson(
            request,
            HttpStatus.badRequest,
            {'error': 'Payment id is required.'},
          );
        }
        final existingPayments = await PaymentStore.loadAll();
        final existingPayment =
            existingPayments.cast<PaymentEntry?>().firstWhere(
                  (entry) => entry != null && entry.id == paymentId,
                  orElse: () => null,
                );
        final removed = await PaymentStore.deleteById(paymentId);
        if (removed) {
          await syncInvoicesPaidFromPayments();
          if (existingPayment != null) {
            try {
              queuePaymentReportRefresh(parseInvoiceDate(existingPayment.date));
            } catch (_) {}
          }
        }
        await MobileAccessStore.addSyncLog(
          SyncLogEntry(
            id: MobileAccessStore.nextSyncLogId(),
            createdAt: DateTime.now().toIso8601String(),
            direction: SyncLogDirection.incoming,
            status: SyncLogStatus.success,
            entityType: 'payment',
            entityId: paymentId,
            summary: removed
                ? 'Deleted mobile payment'
                : 'Mobile payment delete already applied',
            details: user.username,
          ),
        );
        return _writeJson(request, HttpStatus.ok, {
          'ok': true,
          'removed': removed,
          'paymentId': paymentId,
        });
      }
      if (request.method == 'GET' && path == '/sync/changes') {
        final user = await _authorizedUser(request);
        if (user == null) {
          return _writeJson(
            request,
            HttpStatus.unauthorized,
            {'error': 'Unauthorized.'},
          );
        }
        final since = request.uri.queryParameters['since'];
        if ((since ?? '').trim().isEmpty ||
            DateTime.tryParse((since ?? '').trim()) == null) {
          return _writeJson(request, HttpStatus.ok, {
            'fullRequired': true,
            'serverTime': DateTime.now().toIso8601String(),
          });
        }

        final changes = await SyncChangeLogStore.loadSince(since);
        final customerUpserts = <String>{};
        final invoiceUpserts = <String>{};
        final paymentUpserts = <String>{};
        final deletedCustomers = <String>{};
        final deletedInvoices = <String>{};
        final deletedPayments = <String>{};

        void applyChange(SyncChangeEntry change) {
          final targetUpserts = switch (change.entityType) {
            'customer' => customerUpserts,
            'invoice' => invoiceUpserts,
            'payment' => paymentUpserts,
            _ => null,
          };
          final targetDeletes = switch (change.entityType) {
            'customer' => deletedCustomers,
            'invoice' => deletedInvoices,
            'payment' => deletedPayments,
            _ => null,
          };
          if (targetUpserts == null || targetDeletes == null) return;
          if (change.action == 'delete') {
            targetUpserts.remove(change.entityId);
            targetDeletes.add(change.entityId);
          } else if (change.action == 'upsert') {
            targetDeletes.remove(change.entityId);
            targetUpserts.add(change.entityId);
          }
        }

        for (final change in changes) {
          applyChange(change);
        }

        final customers = await CustomerStore.loadAll();
        final invoices = await Store.loadAll();
        final payments = await PaymentStore.loadAll();
        final orders = await MobileAccessStore.loadOrders();
        final surjaniTrucks = await MobileAccessStore.loadSurjaniTrucks();
        final factoryTrucks = await MobileAccessStore.loadFactoryTrucks();
        final godownConfig = await GodownStockStore.loadConfig();
        final customerById = {
          for (final customer in customers) _customerSyncId(customer): customer,
        };
        final invoiceById = {
          for (final invoice in invoices) invoice.sNo.toString(): invoice,
        };
        final paymentById = {
          for (final payment in payments) _paymentSyncId(payment): payment,
        };

        final changedCustomers = <dynamic>[];
        for (final id in customerUpserts) {
          final item = customerById[id];
          if (item == null) {
            deletedCustomers.add(id);
          } else {
            changedCustomers.add(item.toJson());
          }
        }
        final changedInvoices = <dynamic>[];
        for (final id in invoiceUpserts) {
          final item = invoiceById[id];
          if (item == null) {
            deletedInvoices.add(id);
          } else {
            changedInvoices.add(item.toJson());
          }
        }
        final changedPayments = <dynamic>[];
        for (final id in paymentUpserts) {
          final item = paymentById[id];
          if (item == null) {
            deletedPayments.add(id);
          } else {
            changedPayments.add(item.toJson());
          }
        }

        return _writeJson(request, HttpStatus.ok, {
          'customers': changedCustomers,
          'invoices': changedInvoices,
          'payments': changedPayments,
          'orders': orders.map((e) => e.toJson()).toList(),
          'surjaniTrucks': surjaniTrucks.map((e) => e.toJson()).toList(),
          'factoryTrucks': factoryTrucks.map((e) => e.toJson()).toList(),
          'deletedCustomers': deletedCustomers.toList(),
          'deletedInvoices': deletedInvoices.toList(),
          'deletedPayments': deletedPayments.toList(),
          'godownConfig': godownConfig.toJson(),
          'serverTime': DateTime.now().toIso8601String(),
          'userRole': user.role.name,
        });
      }
      if (request.method == 'GET' && path == '/orders') {
        final user = await _authorizedUser(request);
        if (user == null) {
          return _writeJson(
            request,
            HttpStatus.unauthorized,
            {'error': 'Unauthorized.'},
          );
        }
        final orders = await MobileAccessStore.loadOrders();
        final surjaniTrucks = await MobileAccessStore.loadSurjaniTrucks();
        final factoryTrucks = await MobileAccessStore.loadFactoryTrucks();
        return _writeJson(request, HttpStatus.ok, {
          'orders': orders.map((e) => e.toJson()).toList(),
          'surjaniTrucks': surjaniTrucks.map((e) => e.toJson()).toList(),
          'factoryTrucks': factoryTrucks.map((e) => e.toJson()).toList(),
          'serverTime': DateTime.now().toIso8601String(),
        });
      }
      if (request.method == 'POST' && path == '/surjani-trucks') {
        final user = await _authorizedUser(request);
        if (user == null) {
          return _writeJson(
            request,
            HttpStatus.unauthorized,
            {'error': 'Unauthorized.'},
          );
        }
        final body = await utf8.decodeStream(request);
        final decoded = jsonDecode(body);
        if (decoded is! Map<String, dynamic>) {
          return _writeJson(
            request,
            HttpStatus.badRequest,
            {'error': 'Invalid JSON body.'},
          );
        }
        final incoming = ((decoded['trucks'] as List?) ?? const [])
            .map((e) => MobileTruck.fromJson(e as Map<String, dynamic>))
            .where((truck) =>
                truck.id.trim().isNotEmpty &&
                truck.number.trim().isNotEmpty &&
                truck.capacity > 0)
            .toList();
        final mergedById = {
          for (final truck in await MobileAccessStore.loadSurjaniTrucks())
            truck.id: truck,
        };
        for (final truck in incoming) {
          mergedById[truck.id] = truck;
        }
        final merged = mergedById.values.toList()
          ..sort((a, b) => a.number.compareTo(b.number));
        await MobileAccessStore.saveSurjaniTrucks(merged);
        await MobileAccessStore.addSyncLog(
          SyncLogEntry(
            id: MobileAccessStore.nextSyncLogId(),
            createdAt: DateTime.now().toIso8601String(),
            direction: SyncLogDirection.incoming,
            status: SyncLogStatus.success,
            entityType: 'surjaniTruck',
            entityId: incoming.map((e) => e.id).join(','),
            summary: 'Updated Surjani trucks',
            details: user.username,
          ),
        );
        return _writeJson(request, HttpStatus.ok, {
          'ok': true,
          'surjaniTrucks': merged.map((e) => e.toJson()).toList(),
        });
      }
      if (request.method == 'DELETE' &&
          request.uri.pathSegments.length == 2 &&
          request.uri.pathSegments.first == 'surjani-trucks') {
        final user = await _authorizedUser(request);
        if (user == null) {
          return _writeJson(
            request,
            HttpStatus.unauthorized,
            {'error': 'Unauthorized.'},
          );
        }
        final truckId = request.uri.pathSegments[1].trim();
        if (truckId.isEmpty) {
          return _writeJson(
            request,
            HttpStatus.badRequest,
            {'error': 'Truck ID is required.'},
          );
        }
        final trucks = await MobileAccessStore.loadSurjaniTrucks();
        final kept = trucks.where((truck) => truck.id != truckId).toList();
        final removed = kept.length != trucks.length;
        if (removed) {
          await MobileAccessStore.saveSurjaniTrucks(kept);
        }
        await MobileAccessStore.addSyncLog(
          SyncLogEntry(
            id: MobileAccessStore.nextSyncLogId(),
            createdAt: DateTime.now().toIso8601String(),
            direction: SyncLogDirection.incoming,
            status: SyncLogStatus.success,
            entityType: 'surjaniTruck',
            entityId: truckId,
            summary: removed
                ? 'Deleted Surjani truck'
                : 'Surjani truck delete already applied',
            details: user.username,
          ),
        );
        return _writeJson(request, HttpStatus.ok, {
          'ok': true,
          'removed': removed,
          'surjaniTrucks': kept.map((e) => e.toJson()).toList(),
        });
      }
      if (request.method == 'POST' && path == '/factory-trucks') {
        final user = await _authorizedUser(request);
        if (user == null) {
          return _writeJson(
            request,
            HttpStatus.unauthorized,
            {'error': 'Unauthorized.'},
          );
        }
        final body = await utf8.decodeStream(request);
        final decoded = jsonDecode(body);
        if (decoded is! Map<String, dynamic>) {
          return _writeJson(
            request,
            HttpStatus.badRequest,
            {'error': 'Invalid JSON body.'},
          );
        }
        final incoming = ((decoded['trucks'] as List?) ?? const [])
            .map((e) => MobileTruck.fromJson(e as Map<String, dynamic>))
            .where((truck) =>
                truck.id.trim().isNotEmpty &&
                truck.number.trim().isNotEmpty &&
                truck.capacity > 0)
            .toList();
        final mergedById = {
          for (final truck in await MobileAccessStore.loadFactoryTrucks())
            truck.id: truck,
        };
        for (final truck in incoming) {
          mergedById[truck.id] = truck;
        }
        final merged = mergedById.values.toList()
          ..sort((a, b) => a.number.compareTo(b.number));
        await MobileAccessStore.saveFactoryTrucks(merged);
        await MobileAccessStore.addSyncLog(
          SyncLogEntry(
            id: MobileAccessStore.nextSyncLogId(),
            createdAt: DateTime.now().toIso8601String(),
            direction: SyncLogDirection.incoming,
            status: SyncLogStatus.success,
            entityType: 'factoryTruck',
            entityId: incoming.map((e) => e.id).join(','),
            summary: 'Updated Factory trucks',
            details: user.username,
          ),
        );
        return _writeJson(request, HttpStatus.ok, {
          'ok': true,
          'factoryTrucks': merged.map((e) => e.toJson()).toList(),
        });
      }
      if (request.method == 'DELETE' &&
          request.uri.pathSegments.length == 2 &&
          request.uri.pathSegments.first == 'factory-trucks') {
        final user = await _authorizedUser(request);
        if (user == null) {
          return _writeJson(
            request,
            HttpStatus.unauthorized,
            {'error': 'Unauthorized.'},
          );
        }
        final truckId = request.uri.pathSegments[1].trim();
        if (truckId.isEmpty) {
          return _writeJson(
            request,
            HttpStatus.badRequest,
            {'error': 'Truck ID is required.'},
          );
        }
        final trucks = await MobileAccessStore.loadFactoryTrucks();
        final kept = trucks.where((truck) => truck.id != truckId).toList();
        final removed = kept.length != trucks.length;
        if (removed) {
          await MobileAccessStore.saveFactoryTrucks(kept);
        }
        await MobileAccessStore.addSyncLog(
          SyncLogEntry(
            id: MobileAccessStore.nextSyncLogId(),
            createdAt: DateTime.now().toIso8601String(),
            direction: SyncLogDirection.incoming,
            status: SyncLogStatus.success,
            entityType: 'factoryTruck',
            entityId: truckId,
            summary: removed
                ? 'Deleted Factory truck'
                : 'Factory truck delete already applied',
            details: user.username,
          ),
        );
        return _writeJson(request, HttpStatus.ok, {
          'ok': true,
          'removed': removed,
          'factoryTrucks': kept.map((e) => e.toJson()).toList(),
        });
      }
      if (request.method == 'POST' && path == '/godown/truck-balance') {
        final user = await _authorizedUser(request);
        if (user == null) {
          return _writeJson(
            request,
            HttpStatus.unauthorized,
            {'error': 'Unauthorized.'},
          );
        }
        final body = await utf8.decodeStream(request);
        final decoded = jsonDecode(body);
        if (decoded is! Map<String, dynamic>) {
          return _writeJson(
            request,
            HttpStatus.badRequest,
            {'error': 'Invalid JSON body.'},
          );
        }
        final sourceSite = (decoded['sourceSite'] ?? '').toString().trim();
        final sourceTruckId =
            (decoded['sourceTruckId'] ?? '').toString().trim();
        final truckNo = (decoded['truckNo'] ?? '').toString().trim();
        final date = (decoded['date'] ?? '').toString().trim();
        final rawTypeBags = decoded['typeBags'];
        final rawStockLines = decoded['stockLines'];
        if (sourceSite.isEmpty ||
            sourceTruckId.isEmpty ||
            truckNo.isEmpty ||
            date.isEmpty) {
          return _writeJson(
            request,
            HttpStatus.badRequest,
            {'error': 'Truck, date, and balance bags are required.'},
          );
        }
        if (rawTypeBags is! Map) {
          return _writeJson(
            request,
            HttpStatus.badRequest,
            {'error': 'Balance bags are required.'},
          );
        }
        try {
          parseInvoiceDate(date);
        } catch (_) {
          return _writeJson(
            request,
            HttpStatus.badRequest,
            {'error': 'Invalid stock date.'},
          );
        }
        final cleanBalances = <String, int>{};
        rawTypeBags.forEach((key, value) {
          final category = key.toString().trim();
          final qty = value is num
              ? value.toInt()
              : int.tryParse(value.toString()) ?? 0;
          if (kItemTypes.contains(category) && qty > 0) {
            cleanBalances[category] = qty;
          }
        });
        if (cleanBalances.isEmpty) {
          return _writeJson(
            request,
            HttpStatus.badRequest,
            {'error': 'No balance bags to move.'},
          );
        }
        final stockLines = <GodownStockInEntry>[];
        if (rawStockLines is List) {
          for (final rawLine in rawStockLines) {
            if (rawLine is! Map) continue;
            final category = (rawLine['category'] ?? '').toString().trim();
            final sku = (rawLine['sku'] ?? '').toString().trim();
            final qty = rawLine['qty'] is num
                ? (rawLine['qty'] as num).toDouble()
                : double.tryParse((rawLine['qty'] ?? '').toString()) ?? 0;
            if (!kItemTypes.contains(category) || sku.isEmpty || qty <= 0) {
              continue;
            }
            stockLines.add(
              GodownStockInEntry(
                id: '',
                date: date,
                truckNo: truckNo,
                category: category,
                sku: sku,
                qty: qty,
                note: '$sourceSite truck balance moved to Godown',
              ),
            );
          }
        }
        if (stockLines.isEmpty) {
          for (final entry in cleanBalances.entries) {
            stockLines.add(
              GodownStockInEntry(
                id: '',
                date: date,
                truckNo: truckNo,
                category: entry.key,
                sku: 'Truck Balance',
                qty: entry.value.toDouble(),
                note: '$sourceSite truck balance moved to Godown',
              ),
            );
          }
        }
        final siteKey = sourceSite.toLowerCase().replaceAll(' ', '-');
        final truckKey =
            sourceTruckId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-');
        final dateKey = date.replaceAll(RegExp(r'[^0-9]'), '');
        for (final line in stockLines) {
          final categoryKey = line.category.replaceAll(' ', '-');
          final skuKey = line.sku.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-');
          await GodownStockStore.upsertStockInEntry(
            GodownStockInEntry(
              id: 'GBAL-$dateKey-$siteKey-$truckKey-$categoryKey-$skuKey',
              date: line.date,
              truckNo: line.truckNo,
              category: line.category,
              sku: line.sku,
              qty: line.qty,
              note: line.note,
            ),
          );
        }
        final godownConfig = await GodownStockStore.loadConfig();
        await MobileAccessStore.addSyncLog(
          SyncLogEntry(
            id: MobileAccessStore.nextSyncLogId(),
            createdAt: DateTime.now().toIso8601String(),
            direction: SyncLogDirection.incoming,
            status: SyncLogStatus.success,
            entityType: 'godown-stock',
            entityId: sourceTruckId,
            summary: 'Moved truck balance to Godown',
            details:
                '$sourceSite $truckNo - ${stockLines.map((e) => '${e.category} ${e.sku} ${e.qty.toStringAsFixed(0)}').join(', ')}',
          ),
        );
        return _writeJson(request, HttpStatus.ok, {
          'ok': true,
          'godownConfig': godownConfig.toJson(),
        });
      }
      if (request.method == 'POST' && path == '/orders/status') {
        final user = await _authorizedUser(request);
        if (user == null) {
          return _writeJson(
            request,
            HttpStatus.unauthorized,
            {'error': 'Unauthorized.'},
          );
        }
        final body = await utf8.decodeStream(request);
        final decoded = jsonDecode(body);
        if (decoded is! Map<String, dynamic>) {
          return _writeJson(
            request,
            HttpStatus.badRequest,
            {'error': 'Invalid JSON body.'},
          );
        }
        final id = (decoded['id'] ?? '').toString().trim();
        final requestedStatus =
            mobileOrderStatusFromString((decoded['status'] ?? '').toString());
        if (id.isEmpty) {
          return _writeJson(
            request,
            HttpStatus.badRequest,
            {'error': 'Order ID is required.'},
          );
        }
        final existing = (await MobileAccessStore.loadOrders())
            .cast<MobileOrder?>()
            .firstWhere(
              (order) => order != null && order.id == id,
              orElse: () => null,
            );
        if (existing == null) {
          return _writeJson(
            request,
            HttpStatus.notFound,
            {'error': 'Order not found.'},
          );
        }
        final now = DateTime.now().toIso8601String();
        final statusChanged = requestedStatus != existing.status;
        var order = existing.copyWith(
          updatedAt: now,
          updatedByUserId: user.id,
          updatedByName: user.displayName,
          status: requestedStatus,
          statusUpdatedAt: now,
          statusUpdatedByUserId: user.id,
          statusUpdatedByName: user.displayName,
        );
        await MobileAccessStore.upsertOrder(order);
        if (statusChanged && order.status != MobileOrderStatus.pending) {
          unawaited(NotificationService.showOrderStatusChanged(order));
        }
        unawaited(_syncOrderInvoiceAndSave(
          order,
          createIfMissing: statusChanged,
        ));
        await MobileAccessStore.addSyncLog(
          SyncLogEntry(
            id: MobileAccessStore.nextSyncLogId(),
            createdAt: now,
            direction: SyncLogDirection.incoming,
            status: SyncLogStatus.success,
            entityType: 'order',
            entityId: order.id,
            summary: 'Updated order status',
            details:
                'Plot ${order.plotNo} - ${mobileOrderStatusLabel(order.status)} - ${user.username}',
          ),
        );
        return _writeJson(request, HttpStatus.ok, {
          'ok': true,
          'order': order.toJson(),
        });
      }
      if (request.method == 'DELETE' &&
          request.uri.pathSegments.length == 2 &&
          request.uri.pathSegments.first == 'orders') {
        final user = await _authorizedUser(request);
        if (user == null) {
          return _writeJson(
            request,
            HttpStatus.unauthorized,
            {'error': 'Unauthorized.'},
          );
        }
        final orderId = request.uri.pathSegments[1].trim();
        if (orderId.isEmpty) {
          return _writeJson(
            request,
            HttpStatus.badRequest,
            {'error': 'Order ID is required.'},
          );
        }
        final orders = await MobileAccessStore.loadOrders();
        final existing = orders.cast<MobileOrder?>().firstWhere(
              (order) => order != null && order.id == orderId,
              orElse: () => null,
            );
        final existed = existing != null;
        if (existing?.recordedInvoiceNo != null) {
          await _deleteRecordedOrderInvoice(existing!);
        }
        await MobileAccessStore.deleteOrder(orderId);
        await MobileAccessStore.addSyncLog(
          SyncLogEntry(
            id: MobileAccessStore.nextSyncLogId(),
            createdAt: DateTime.now().toIso8601String(),
            direction: SyncLogDirection.incoming,
            status: SyncLogStatus.success,
            entityType: 'order',
            entityId: orderId,
            summary: existed ? 'Deleted order' : 'Order delete already applied',
            details: user.username,
          ),
        );
        return _writeJson(request, HttpStatus.ok, {
          'ok': true,
          'removed': existed,
          'orderId': orderId,
        });
      }
      if (request.method == 'POST' && path == '/orders') {
        final user = await _authorizedUser(request);
        if (user == null) {
          return _writeJson(
            request,
            HttpStatus.unauthorized,
            {'error': 'Unauthorized.'},
          );
        }
        final body = await utf8.decodeStream(request);
        final decoded = jsonDecode(body);
        if (decoded is! Map<String, dynamic>) {
          return _writeJson(
            request,
            HttpStatus.badRequest,
            {'error': 'Invalid JSON body.'},
          );
        }
        final id = (decoded['id'] ?? '').toString().trim();
        final existing = id.isEmpty
            ? null
            : (await MobileAccessStore.loadOrders())
                .cast<MobileOrder?>()
                .firstWhere(
                  (order) => order != null && order.id == id,
                  orElse: () => null,
                );
        final plotNo = (decoded['plotNo'] ?? '').toString().trim();
        final customerName =
            (decoded['customerName'] ?? existing?.customerName ?? '')
                .toString()
                .trim();
        final bagsQuantity = (decoded['bagsQuantity'] as num?)?.toInt() ??
            int.tryParse((decoded['bagsQuantity'] ?? '').toString()) ??
            0;
        final bagsType = (decoded['bagsType'] ?? '').toString().trim();
        final bagsBrand = (decoded['bagsBrand'] ?? '').toString().trim();
        final orderSite = (decoded['orderSite'] ?? '').toString().trim();
        final assignedTruckId =
            (decoded['assignedTruckId'] ?? existing?.assignedTruckId ?? '')
                .toString()
                .trim();
        final assignedTruckNo =
            (decoded['assignedTruckNo'] ?? existing?.assignedTruckNo ?? '')
                .toString()
                .trim();
        final note =
            (decoded['note'] ?? existing?.note ?? '').toString().trim();
        final orderDate = (decoded['orderDate'] ?? existing?.orderDate ?? '')
            .toString()
            .trim();
        final requestedStatus = decoded.containsKey('status')
            ? mobileOrderStatusFromString((decoded['status'] ?? '').toString())
            : existing?.status ?? MobileOrderStatus.pending;
        final statusChanged = decoded.containsKey('status') &&
            requestedStatus != existing?.status;
        if (plotNo.isEmpty ||
            bagsQuantity <= 0 ||
            bagsType.isEmpty ||
            bagsBrand.isEmpty ||
            orderDate.isEmpty ||
            orderSite.isEmpty) {
          return _writeJson(
            request,
            HttpStatus.badRequest,
            {
              'error':
                  'Date, plot, quantity, bag type, brand, and site are required.'
            },
          );
        }
        final now = DateTime.now().toIso8601String();
        final isNewOrder = existing == null;
        var order = (existing ??
                MobileOrder(
                  id: id.isEmpty ? MobileAccessStore.nextOrderId() : id,
                  createdAt: now,
                  createdByUserId: user.id,
                  createdByName: user.displayName,
                  updatedAt: now,
                  updatedByUserId: user.id,
                  updatedByName: user.displayName,
                  orderDate: orderDate,
                  customerName: customerName,
                  plotNo: plotNo,
                  bagsQuantity: bagsQuantity,
                  bagsType: bagsType,
                  bagsBrand: bagsBrand,
                  orderSite: orderSite,
                  assignedTruckId: assignedTruckId,
                  assignedTruckNo: assignedTruckNo,
                  note: note,
                  status: requestedStatus,
                  statusUpdatedAt: now,
                  statusUpdatedByUserId: user.id,
                  statusUpdatedByName: user.displayName,
                ))
            .copyWith(
          updatedAt: now,
          updatedByUserId: user.id,
          updatedByName: user.displayName,
          orderDate: orderDate,
          customerName: customerName,
          plotNo: plotNo,
          bagsQuantity: bagsQuantity,
          bagsType: bagsType,
          bagsBrand: bagsBrand,
          orderSite: orderSite,
          assignedTruckId: assignedTruckId,
          assignedTruckNo: assignedTruckNo,
          note: note,
          status: requestedStatus,
          statusUpdatedAt: statusChanged ? now : null,
          statusUpdatedByUserId: statusChanged ? user.id : null,
          statusUpdatedByName: statusChanged ? user.displayName : null,
        );
        if (isNewOrder) {
          await NotificationService.showNewOrder(order);
        } else if (statusChanged && order.status != MobileOrderStatus.pending) {
          await NotificationService.showOrderStatusChanged(order);
        }
        order = await _syncDeliveredOrderInvoice(
          order,
          createIfMissing: isNewOrder || statusChanged,
        );
        await MobileAccessStore.upsertOrder(order);
        await MobileAccessStore.addSyncLog(
          SyncLogEntry(
            id: MobileAccessStore.nextSyncLogId(),
            createdAt: now,
            direction: SyncLogDirection.incoming,
            status: SyncLogStatus.success,
            entityType: 'order',
            entityId: order.id,
            summary:
                existing == null ? 'Received mobile order' : 'Updated order',
            details: 'Plot ${order.plotNo} - ${user.username}',
          ),
        );
        return _writeJson(request, HttpStatus.ok, {
          'ok': true,
          'order': order.toJson(),
        });
      }
      if (request.method == 'POST' && path == '/pending-invoices') {
        final user = await _authorizedUser(request);
        if (user == null) {
          return _writeJson(
            request,
            HttpStatus.unauthorized,
            {'error': 'Unauthorized.'},
          );
        }
        if (user.role == UserRole.viewer) {
          return _writeJson(
            request,
            HttpStatus.forbidden,
            {'error': 'Viewer accounts cannot create draft invoices.'},
          );
        }
        final body = await utf8.decodeStream(request);
        final decoded = jsonDecode(body);
        if (decoded is! Map<String, dynamic>) {
          return _writeJson(
            request,
            HttpStatus.badRequest,
            {'error': 'Invalid JSON body.'},
          );
        }
        final lines = ((decoded['lines'] as List?) ?? const [])
            .map((e) => PendingInvoiceLine.fromJson(e as Map<String, dynamic>))
            .where((line) => line.qty > 0 && line.typeLabel.trim().isNotEmpty)
            .toList();
        if (lines.isEmpty) {
          return _writeJson(
            request,
            HttpStatus.badRequest,
            {'error': 'At least one valid line item is required.'},
          );
        }
        final now = DateTime.now().toIso8601String();
        final draftCode = (decoded['draftCode'] ?? '').toString().trim().isEmpty
            ? 'TMP-MOB-${DateTime.now().microsecondsSinceEpoch}'
            : (decoded['draftCode'] ?? '').toString().trim();
        final existing = (await MobileAccessStore.loadPendingInvoices())
            .cast<PendingInvoice?>()
            .firstWhere(
              (invoice) =>
                  invoice != null &&
                  (invoice.id == draftCode || invoice.draftCode == draftCode),
              orElse: () => null,
            );
        if (existing != null) {
          return _writeJson(request, HttpStatus.ok, {
            'ok': true,
            'draftCode': existing.draftCode,
            'status': existing.status.name,
            'duplicate': true,
          });
        }
        final pending = PendingInvoice(
          id: draftCode,
          draftCode: draftCode,
          submittedAt: now,
          invoiceDate: (decoded['invoiceDate'] ?? '').toString(),
          submittedByUserId: user.id,
          submittedByName: user.displayName,
          sourceDeviceId: (decoded['deviceId'] ?? '').toString(),
          customerId: (decoded['customerId'] ?? '').toString(),
          customer: (decoded['customer'] ?? '').toString(),
          customerDisplay:
              ((decoded['customerDisplay'] ?? decoded['customer']) ?? '')
                  .toString(),
          contact: (decoded['contact'] ?? '').toString(),
          address: (decoded['address'] ?? '').toString(),
          site: (decoded['site'] ?? '').toString(),
          lines: lines,
          cartage: (decoded['cartage'] as num?)?.toDouble() ?? 0,
        );
        await MobileAccessStore.upsertPendingInvoice(pending);
        await MobileAccessStore.addSyncLog(
          SyncLogEntry(
            id: MobileAccessStore.nextSyncLogId(),
            createdAt: now,
            direction: SyncLogDirection.incoming,
            status: SyncLogStatus.success,
            entityType: 'pending_invoice',
            entityId: pending.id,
            summary: 'Received mobile draft ${pending.draftCode}',
            details: '${pending.customer} - ${user.username}',
          ),
        );
        return _writeJson(request, HttpStatus.ok, {
          'ok': true,
          'draftCode': pending.draftCode,
          'status': pending.status.name,
        });
      }
      if (request.method == 'POST' && path == '/locations') {
        final user = await _authorizedUser(request);
        if (user == null) {
          return _writeJson(
            request,
            HttpStatus.unauthorized,
            {'error': 'Unauthorized.'},
          );
        }
        final body = await utf8.decodeStream(request);
        final decoded = jsonDecode(body);
        if (decoded is! Map<String, dynamic>) {
          return _writeJson(
            request,
            HttpStatus.badRequest,
            {'error': 'Invalid JSON body.'},
          );
        }
        if (decoded['sharingEnabled'] != true) {
          return _writeJson(
            request,
            HttpStatus.badRequest,
            {'error': 'Location sharing is not enabled.'},
          );
        }
        final lat = (decoded['latitude'] as num?)?.toDouble();
        final lon = (decoded['longitude'] as num?)?.toDouble();
        if (lat == null || lon == null) {
          return _writeJson(
            request,
            HttpStatus.badRequest,
            {'error': 'Latitude and longitude are required.'},
          );
        }
        final now = DateTime.now().toIso8601String();
        final location = MobileUserLocation(
          userId: user.id,
          username: user.username,
          displayName: user.displayName,
          deviceId: (decoded['deviceId'] ?? '').toString(),
          latitude: lat,
          longitude: lon,
          accuracyMeters: (decoded['accuracyMeters'] as num?)?.toDouble(),
          capturedAt: (decoded['capturedAt'] ?? now).toString(),
          receivedAt: now,
          sharingEnabled: true,
        );
        await MobileAccessStore.upsertUserLocation(location);
        return _writeJson(request, HttpStatus.ok, {
          'ok': true,
          'receivedAt': now,
        });
      }
      return _writeJson(
        request,
        HttpStatus.notFound,
        {'error': 'Route not found.'},
      );
    } catch (e) {
      return _writeJson(
        request,
        HttpStatus.internalServerError,
        {'error': e.toString()},
      );
    }
  }

  static Future<AppUser?> _authorizedUser(HttpRequest request) async {
    final auth = request.headers.value(HttpHeaders.authorizationHeader) ?? '';
    if (!auth.startsWith('Bearer ')) return null;
    final token = auth.substring(7).trim();
    final userId = _sessions[token];
    if (userId == null) return null;
    final users = await MobileAccessStore.loadUsers();
    try {
      return users.firstWhere((user) => user.id == userId && user.active);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _writeJson(
    HttpRequest request,
    int statusCode,
    Map<String, dynamic> body,
  ) async {
    request.response.statusCode = statusCode;
    request.response.headers.contentType =
        ContentType('application', 'json', charset: 'utf-8');
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  static String _customerSyncId(Customer customer) {
    final id = customer.id.trim();
    if (id.isNotEmpty) return id;
    return customer.name.trim().toLowerCase();
  }

  static String _paymentSyncId(PaymentEntry payment) {
    final id = payment.id.trim();
    if (id.isNotEmpty) return id;
    return '${payment.date}|${payment.customerId}|${payment.customer}|${payment.amount}|${payment.type.name}';
  }

  static Future<void> _syncOrderInvoiceAndSave(
    MobileOrder order, {
    required bool createIfMissing,
  }) async {
    try {
      final synced = await _syncDeliveredOrderInvoice(
        order,
        createIfMissing: createIfMissing,
      );
      await MobileAccessStore.upsertOrder(synced);
    } catch (e) {
      await MobileAccessStore.addSyncLog(
        SyncLogEntry(
          id: MobileAccessStore.nextSyncLogId(),
          createdAt: DateTime.now().toIso8601String(),
          direction: SyncLogDirection.local,
          status: SyncLogStatus.error,
          entityType: 'invoice',
          entityId: order.id,
          summary: 'Could not auto-record delivered order',
          details: e.toString(),
        ),
      );
    }
  }

  static Future<MobileOrder> _syncDeliveredOrderInvoice(MobileOrder order,
      {required bool createIfMissing}) async {
    final recordedInvoiceNo = order.recordedInvoiceNo;
    if (recordedInvoiceNo != null) {
      if (order.status != MobileOrderStatus.delivered) {
        await _deleteRecordedOrderInvoice(order);
        return order.copyWith(clearRecordedInvoice: true);
      }
      await _updateRecordedOrderInvoice(order, recordedInvoiceNo);
      return order;
    }
    if (!createIfMissing || order.status != MobileOrderStatus.delivered) {
      return order;
    }
    final customerName = order.customerName.trim();
    if (customerName.isEmpty) return order;

    final customer = await _customerForDeliveredOrder(customerName);
    if (customer == null) return order;

    final DateTime parsedOrderDate;
    try {
      parsedOrderDate = parseInvoiceDate(order.orderDate);
    } catch (_) {
      return order;
    }

    final rate = await _latestRateForOrder(customer, order);
    if (rate <= 0) return order;

    final now = DateTime.now().toIso8601String();
    final invoiceDate = formatInvoiceDate(parsedOrderDate);
    final nextNo = await Store.nextSerial();
    final invoice = Invoice(
      sNo: nextNo,
      date: invoiceDate,
      customer: customer.name,
      customerDisplay: customer.displayName.trim().isEmpty
          ? customer.name
          : customer.displayName,
      customerId: customer.id,
      contact: customer.contact,
      address: order.plotNo,
      site: order.orderSite,
      lines: [
        ItemLine(
          order.bagsType,
          brand: order.bagsBrand,
          qty: order.bagsQuantity,
          rate: rate,
        ),
      ],
      cartage: 0,
      paid: 0,
      walkIn: false,
    );
    await Store.upsertInvoice(invoice);
    queueInvoiceReportRefresh(
      dates: {parsedOrderDate},
      months: {parsedOrderDate},
      customerKeys: {invoice.customerId, invoice.customer},
    );

    final recorded = order.copyWith(
      recordedInvoiceNo: nextNo,
      recordedInvoiceAt: now,
    );
    await MobileAccessStore.addSyncLog(
      SyncLogEntry(
        id: MobileAccessStore.nextSyncLogId(),
        createdAt: now,
        direction: SyncLogDirection.local,
        status: SyncLogStatus.success,
        entityType: 'invoice',
        entityId: '$nextNo',
        summary: 'Auto-recorded delivered order as invoice #$nextNo',
        details: 'Order ${order.id} - ${customer.name}',
      ),
    );
    return recorded;
  }

  static Future<void> _updateRecordedOrderInvoice(
    MobileOrder order,
    int invoiceNo,
  ) async {
    final invoices = await Store.loadAll();
    final index = invoices.indexWhere((invoice) => invoice.sNo == invoiceNo);
    if (index < 0) return;
    final existing = invoices[index];
    final customer = await _customerForDeliveredOrder(order.customerName);
    final DateTime parsedOrderDate;
    try {
      parsedOrderDate = parseInvoiceDate(order.orderDate);
    } catch (_) {
      return;
    }
    final latestRate =
        customer == null ? 0.0 : await _latestRateForOrder(customer, order);
    final existingRate =
        existing.lines.isEmpty ? 0.0 : existing.lines.first.rate;
    final invoice = Invoice(
      sNo: existing.sNo,
      date: formatInvoiceDate(parsedOrderDate),
      customer: customer?.name ?? existing.customer,
      customerDisplay: customer == null
          ? existing.customerDisplay
          : (customer.displayName.trim().isEmpty
              ? customer.name
              : customer.displayName),
      customerId: customer?.id ?? existing.customerId,
      contact: customer?.contact ?? existing.contact,
      address: order.plotNo,
      site: order.orderSite,
      lines: [
        ItemLine(
          order.bagsType,
          brand: order.bagsBrand,
          qty: order.bagsQuantity,
          rate: latestRate > 0 ? latestRate : existingRate,
        ),
      ],
      cartage: existing.cartage,
      paid: existing.paid,
      walkIn: existing.walkIn,
      walkInPaymentType: existing.walkInPaymentType,
      walkInPaymentNote: existing.walkInPaymentNote,
      walkInBank: existing.walkInBank,
      walkInChequeNo: existing.walkInChequeNo,
      walkInTxnId: existing.walkInTxnId,
      walkInBankMode: existing.walkInBankMode,
    );
    await Store.upsertInvoice(invoice);
    queueInvoiceReportRefresh(
      dates: {parsedOrderDate},
      months: {parsedOrderDate},
      customerKeys: {invoice.customerId, invoice.customer},
    );
  }

  static Future<void> _deleteRecordedOrderInvoice(MobileOrder order) async {
    final invoiceNo = order.recordedInvoiceNo;
    if (invoiceNo == null) return;
    final removed = await Store.deleteInvoice(invoiceNo);
    if (removed == null) return;
    DateTime? parsedDate;
    try {
      parsedDate = parseInvoiceDate(removed.date);
    } catch (_) {
      parsedDate = null;
    }
    if (parsedDate != null) {
      queueInvoiceReportRefresh(
        dates: {parsedDate},
        months: {parsedDate},
        customerKeys: {removed.customerId, removed.customer},
      );
    }
    await MobileAccessStore.addSyncLog(
      SyncLogEntry(
        id: MobileAccessStore.nextSyncLogId(),
        createdAt: DateTime.now().toIso8601String(),
        direction: SyncLogDirection.local,
        status: SyncLogStatus.success,
        entityType: 'invoice',
        entityId: '$invoiceNo',
        summary: 'Deleted auto-recorded invoice #$invoiceNo',
        details: 'Order ${order.id}',
      ),
    );
  }

  static Future<Customer?> _customerForDeliveredOrder(
      String customerName) async {
    final needle = customerName.trim().toLowerCase();
    if (needle.isEmpty) return null;
    final customers = await CustomerStore.loadActive();
    for (final customer in customers) {
      if (customer.name.trim().toLowerCase() == needle ||
          customer.displayName.trim().toLowerCase() == needle) {
        return customer;
      }
    }
    return null;
  }

  static Future<double> _latestRateForOrder(
    Customer customer,
    MobileOrder order,
  ) async {
    final invoices = await Store.loadAll();
    final customerIdKey = customer.id.trim().toLowerCase();
    final customerNameKey = customer.name.trim().toLowerCase();
    final displayNameKey = customer.displayName.trim().toLowerCase();
    final typeKey = order.bagsType.trim().toLowerCase();
    DateTime? latestDate;
    var latestRate = 0.0;
    for (final invoice in invoices) {
      final invoiceId = invoice.customerId.trim().toLowerCase();
      final invoiceName = invoice.customer.trim().toLowerCase();
      final invoiceDisplay =
          (invoice.customerDisplay ?? '').trim().toLowerCase();
      final sameCustomer =
          (customerIdKey.isNotEmpty && invoiceId == customerIdKey) ||
              (customerNameKey.isNotEmpty && invoiceName == customerNameKey) ||
              (displayNameKey.isNotEmpty && invoiceDisplay == displayNameKey);
      if (!sameCustomer) continue;

      final invoiceDate = DateTime.tryParse(invoice.date) ??
          (() {
            try {
              return parseInvoiceDate(invoice.date);
            } catch (_) {
              return null;
            }
          })();
      if (invoiceDate == null) continue;
      if (latestDate != null && !invoiceDate.isAfter(latestDate)) continue;

      for (final line in invoice.lines) {
        if (line.typeLabel.trim().toLowerCase() == typeKey && line.rate > 0) {
          latestDate = invoiceDate;
          latestRate = line.rate;
          break;
        }
      }
    }
    return latestRate;
  }

  static Future<int> approvePendingInvoice(
    PendingInvoice invoice, {
    String? reviewNote,
  }) async {
    final nextNo = await Store.nextSerial();
    final resolvedCustomerId = invoice.customerId.trim().isEmpty
        ? invoice.customer.trim()
        : invoice.customerId.trim();
    final actual = Invoice(
      sNo: nextNo,
      date: invoice.invoiceDate,
      customer: invoice.customer,
      customerDisplay: invoice.customerDisplay.trim().isEmpty
          ? invoice.customer
          : invoice.customerDisplay,
      customerId: resolvedCustomerId,
      contact: invoice.contact,
      address: invoice.address,
      site: invoice.site,
      lines: invoice.lines
          .map(
            (line) => ItemLine(
              line.typeLabel,
              brand: line.brand,
              qty: line.qty,
              rate: line.rate,
            ),
          )
          .toList(),
      cartage: invoice.cartage,
      paid: 0,
      walkIn: false,
    );
    await Store.upsertInvoice(actual);
    if (resolvedCustomerId.isNotEmpty || invoice.customer.trim().isNotEmpty) {
      final customerId = resolvedCustomerId.isEmpty
          ? await CustomerStore.nextCustomerId()
          : resolvedCustomerId;
      await CustomerStore.addCustomer(
        customerId,
        invoice.customer.trim(),
        invoice.contact.trim(),
        displayName: invoice.customerDisplay.trim().isEmpty
            ? invoice.customer.trim()
            : invoice.customerDisplay.trim(),
      );
    }
    await MobileAccessStore.updatePendingInvoiceStatus(
      invoice.id,
      PendingInvoiceStatus.approved,
      reviewNote: reviewNote,
      approvedInvoiceNo: nextNo,
    );
    await MobileAccessStore.addSyncLog(
      SyncLogEntry(
        id: MobileAccessStore.nextSyncLogId(),
        createdAt: DateTime.now().toIso8601String(),
        direction: SyncLogDirection.local,
        status: SyncLogStatus.success,
        entityType: 'invoice',
        entityId: '$nextNo',
        summary: 'Approved draft ${invoice.draftCode} as invoice #$nextNo',
        details: reviewNote,
      ),
    );
    return nextNo;
  }
}
