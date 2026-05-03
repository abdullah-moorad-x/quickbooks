import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../models/mobile_access.dart';

class NotificationService {
  static const _loudOrderSound =
      RawResourceAndroidNotificationSound('quickbill_loud_order');

  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  static bool _initialized = false;

  static Future<void> initialize() async {
    if (_initialized || kIsWeb) return;

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
      defaultPresentAlert: true,
      defaultPresentBadge: true,
      defaultPresentSound: true,
    );
    const linux = LinuxInitializationSettings(
      defaultActionName: 'Open QuickBill',
    );
    const windows = WindowsInitializationSettings(
      appName: 'QuickBill By Abdullah',
      appUserModelId: 'Com.Abdullah.QuickBill',
      guid: 'd36f6a06-8ab2-4f36-9463-8ffb8b4a25ea',
    );

    const settings = InitializationSettings(
      android: android,
      iOS: darwin,
      macOS: darwin,
      linux: linux,
      windows: windows,
    );

    try {
      await _notifications.initialize(settings: settings);
      if (Platform.isAndroid) {
        await _notifications
            .resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>()
            ?.requestNotificationsPermission();
      }
      _initialized = true;
    } catch (_) {
      _initialized = false;
    }
  }

  static Future<void> showNewOrder(MobileOrder order) async {
    await initialize();
    if (!_initialized) return;

    final title = 'New order from ${order.createdByName}';
    final body =
        '${order.orderDate} - Plot ${order.plotNo}: ${order.bagsQuantity} ${order.bagsType} ${order.bagsBrand} - ${order.orderSite}';

    const android = AndroidNotificationDetails(
      'quickbill_orders_loud_v1',
      'Loud order alerts',
      channelDescription: 'Loud notifications for new mobile orders',
      importance: Importance.max,
      priority: Priority.max,
      playSound: true,
      sound: _loudOrderSound,
      audioAttributesUsage: AudioAttributesUsage.alarm,
      enableVibration: true,
      ticker: 'New QuickBill order',
      category: AndroidNotificationCategory.message,
    );
    const darwin = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    const linux = LinuxNotificationDetails(
      urgency: LinuxNotificationUrgency.critical,
    );
    final windows = WindowsNotificationDetails(
      audio: WindowsNotificationAudio.preset(
        sound: WindowsNotificationSound.alarm2,
      ),
      duration: WindowsNotificationDuration.long,
      scenario: WindowsNotificationScenario.urgent,
    );
    final details = NotificationDetails(
      android: android,
      iOS: darwin,
      macOS: darwin,
      linux: linux,
      windows: windows,
    );

    try {
      await _notifications.show(
        id: DateTime.now().millisecondsSinceEpoch.remainder(100000),
        title: title,
        body: body,
        notificationDetails: details,
        payload: order.id,
      );
    } catch (_) {}
  }

  static Future<void> showOrderStatusChanged(MobileOrder order) async {
    if (order.status == MobileOrderStatus.pending) return;
    await initialize();
    if (!_initialized) return;

    final status = mobileOrderStatusLabel(order.status);
    final title = 'Order $status';
    final body =
        'Plot ${order.plotNo}: ${order.bagsQuantity} ${order.bagsType} ${order.bagsBrand} - ${order.orderSite}';

    const android = AndroidNotificationDetails(
      'quickbill_order_status_loud_v1',
      'Loud order status alerts',
      channelDescription:
          'Loud notifications when orders are delivered or cancelled',
      importance: Importance.max,
      priority: Priority.max,
      playSound: true,
      sound: _loudOrderSound,
      audioAttributesUsage: AudioAttributesUsage.alarm,
      enableVibration: true,
      ticker: 'QuickBill order status',
      category: AndroidNotificationCategory.status,
    );
    const darwin = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    const linux = LinuxNotificationDetails(
      urgency: LinuxNotificationUrgency.critical,
    );
    final windows = WindowsNotificationDetails(
      audio: WindowsNotificationAudio.preset(
        sound: WindowsNotificationSound.defaultSound,
      ),
      duration: WindowsNotificationDuration.long,
      scenario: WindowsNotificationScenario.reminder,
    );
    final details = NotificationDetails(
      android: android,
      iOS: darwin,
      macOS: darwin,
      linux: linux,
      windows: windows,
    );

    try {
      await _notifications.show(
        id: DateTime.now().millisecondsSinceEpoch.remainder(100000),
        title: title,
        body: body,
        notificationDetails: details,
        payload: order.id,
      );
    } catch (_) {}
  }
}
