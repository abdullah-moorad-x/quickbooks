import 'dart:convert';
import 'dart:io';

import 'package:googleapis_auth/auth_io.dart';

import '../models/mobile_access.dart';
import 'mobile_sync_store.dart';
import 'notification_service.dart';
import 'paths.dart';

class FirebasePushResult {
  final int attempted;
  final int delivered;
  final int removedInvalidTokens;
  final String? error;

  const FirebasePushResult({
    required this.attempted,
    required this.delivered,
    this.removedInvalidTokens = 0,
    this.error,
  });

  bool get success => delivered > 0 && error == null;
}

class FirebasePushSender {
  static const _messagingScope =
      'https://www.googleapis.com/auth/firebase.messaging';
  static const _defaultCredentialsPath =
      r'C:\firebase private key\quickbill-ec60f-firebase-adminsdk-fbsvc-03937d16bd.json';

  static String? lastError;
  static String? lastSentAt;

  static Future<bool> get isConfigured async =>
      await _credentialsFile() != null;

  static Future<String?> credentialsPath() async =>
      (await _credentialsFile())?.path;

  static Future<void> setCredentialsPath(String path) async {
    final cleanPath = path.trim();
    final file = File(cleanPath);
    if (cleanPath.isEmpty || !await file.exists()) {
      throw const FormatException('Selected Firebase key file was not found.');
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, dynamic> ||
        (decoded['project_id'] ?? '').toString().trim().isEmpty ||
        (decoded['private_key'] ?? '').toString().trim().isEmpty ||
        (decoded['client_email'] ?? '').toString().trim().isEmpty) {
      throw const FormatException(
        'This is not a valid Firebase service-account JSON key.',
      );
    }
    final configFile = await _credentialsConfigFile();
    await configFile.writeAsString(jsonEncode({'path': file.absolute.path}));
    lastError = null;
  }

  static Future<void> sendNewOrder(
    MobileOrder order, {
    required String excludeUserId,
  }) async {
    await _sendToRegisteredDevices(
      title: 'New order from ${order.createdByName}',
      body:
          '${order.orderDate} - Plot ${order.plotNo}: ${order.bagsQuantity} ${order.bagsType} ${order.bagsBrand} - ${order.orderSite}',
      order: order,
      excludeUserId: excludeUserId,
      eventType: 'new_order',
    );
  }

  static Future<FirebasePushResult> sendTestNotification() async {
    return _sendToRegisteredDevices(
      title: 'QuickBill test notification',
      body: 'Firebase push notifications are working correctly.',
      eventType: 'test_notification',
    );
  }

  static Future<void> sendOrderStatusChanged(
    MobileOrder order, {
    required String excludeUserId,
  }) async {
    if (order.status == MobileOrderStatus.pending) return;
    await _sendToRegisteredDevices(
      title: 'Order ${mobileOrderStatusLabel(order.status)}',
      body:
          'Plot ${order.plotNo}: ${order.bagsQuantity} ${order.bagsType} ${order.bagsBrand} - ${order.orderSite}',
      order: order,
      excludeUserId: excludeUserId,
      eventType: 'order_status',
    );
  }

  static Future<FirebasePushResult> _sendToRegisteredDevices({
    required String title,
    required String body,
    MobileOrder? order,
    String? excludeUserId,
    required String eventType,
  }) async {
    final credentialFile = await _credentialsFile();
    if (credentialFile == null) {
      lastError = 'Firebase service-account key was not found.';
      return FirebasePushResult(
        attempted: 0,
        delivered: 0,
        error: lastError,
      );
    }
    final devices = await MobileAccessStore.loadDevices();
    final recipients = devices
        .where(
          (device) =>
              device.trusted &&
              (excludeUserId == null || device.userId != excludeUserId) &&
              (device.pushToken ?? '').trim().isNotEmpty,
        )
        .toList();
    if (recipients.isEmpty) {
      lastError =
          'No registered phone found. Open the updated mobile app, log in, and sync once.';
      return FirebasePushResult(
        attempted: 0,
        delivered: 0,
        error: lastError,
      );
    }

    AutoRefreshingAuthClient? client;
    try {
      final decoded = jsonDecode(await credentialFile.readAsString())
          as Map<String, dynamic>;
      final projectId = (decoded['project_id'] ?? '').toString().trim();
      if (projectId.isEmpty) {
        throw const FormatException('Firebase project_id is missing.');
      }
      client = await clientViaServiceAccount(
        ServiceAccountCredentials.fromJson(decoded),
        const [_messagingScope],
      );
      final endpoint = Uri.parse(
        'https://fcm.googleapis.com/v1/projects/$projectId/messages:send',
      );
      final invalidTokens = <String>{};
      var delivered = 0;
      for (final device in recipients) {
        final token = device.pushToken!.trim();
        final response = await client.post(
          endpoint,
          headers: const {'Content-Type': 'application/json; charset=UTF-8'},
          body: jsonEncode({
            'message': {
              'token': token,
              'notification': {'title': title, 'body': body},
              'data': {
                'type': eventType,
                if (order != null) 'orderId': order.id,
                if (order != null) 'status': order.status.name,
                'title': title,
                'body': body,
              },
              'android': {
                'priority': 'high',
                'notification': {
                  'channel_id': NotificationService.pushChannelId,
                  'sound': 'quickbill_loud_order',
                  'notification_priority': 'PRIORITY_MAX',
                  'default_vibrate_timings': true,
                },
              },
              'apns': {
                'payload': {
                  'aps': {'sound': 'default', 'content-available': 1},
                },
              },
            },
          }),
        );
        if (response.statusCode >= 200 && response.statusCode < 300) {
          delivered++;
          continue;
        }
        if (response.statusCode == HttpStatus.notFound ||
            response.body.contains('UNREGISTERED')) {
          invalidTokens.add(token);
        }
        lastError = 'FCM ${response.statusCode}: ${_safeError(response.body)}';
      }
      if (invalidTokens.isNotEmpty) {
        await MobileAccessStore.saveDevices(
          devices
              .where(
                (device) => !invalidTokens.contains(device.pushToken?.trim()),
              )
              .toList(),
        );
      }
      if (delivered > 0) {
        lastSentAt = DateTime.now().toIso8601String();
        if (delivered == recipients.length) lastError = null;
      }
      return FirebasePushResult(
        attempted: recipients.length,
        delivered: delivered,
        removedInvalidTokens: invalidTokens.length,
        error: delivered == recipients.length ? null : lastError,
      );
    } catch (error) {
      lastError = error.toString();
      return FirebasePushResult(
        attempted: recipients.length,
        delivered: 0,
        error: lastError,
      );
    } finally {
      client?.close();
    }
  }

  static Future<File?> _credentialsFile() async {
    final environmentPath =
        (Platform.environment['GOOGLE_APPLICATION_CREDENTIALS'] ?? '').trim();
    final savedPath = await _savedCredentialsPath();
    final executableFolder = File(Platform.resolvedExecutable).parent.path;
    final candidates = <String>[
      if (savedPath.isNotEmpty) savedPath,
      if (environmentPath.isNotEmpty) environmentPath,
      _defaultCredentialsPath,
      '$executableFolder${Platform.pathSeparator}firebase-service-account.json',
    ];
    for (final path in candidates) {
      final file = File(path);
      if (await file.exists()) return file;
    }
    return null;
  }

  static Future<File> _credentialsConfigFile() async {
    final directory = await baseDir();
    return File(
      '${directory.path}${Platform.pathSeparator}firebase_credentials.json',
    );
  }

  static Future<String> _savedCredentialsPath() async {
    try {
      final file = await _credentialsConfigFile();
      if (!await file.exists()) return '';
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return '';
      return (decoded['path'] ?? '').toString().trim();
    } catch (_) {
      return '';
    }
  }

  static String _safeError(String body) {
    try {
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final error = decoded['error'];
      if (error is Map<String, dynamic>) {
        return (error['message'] ?? 'Firebase request failed.').toString();
      }
    } catch (_) {}
    return 'Firebase request failed.';
  }
}
