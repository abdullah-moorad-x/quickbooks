import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../models/mobile_access.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
}

class NotificationService {
  static const pushChannelId = 'quickbill_push_loud_v1';
  static const _loudOrderSound =
      RawResourceAndroidNotificationSound('quickbill_loud_order');

  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  static bool _initialized = false;
  static bool _pushInitialized = false;
  static StreamSubscription<RemoteMessage>? _foregroundSubscription;

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
        final androidPlugin =
            _notifications.resolvePlatformSpecificImplementation<
                AndroidFlutterLocalNotificationsPlugin>();
        await androidPlugin?.createNotificationChannel(
          const AndroidNotificationChannel(
            pushChannelId,
            'QuickBill push alerts',
            description: 'Order and status notifications from QuickBill',
            importance: Importance.max,
            playSound: true,
            sound: _loudOrderSound,
            enableVibration: true,
          ),
        );
        await androidPlugin?.requestNotificationsPermission();
      }
      _initialized = true;
    } catch (_) {
      _initialized = false;
    }
  }

  static Future<void> initializePushMessaging() async {
    if (_pushInitialized || kIsWeb) return;
    if (!Platform.isAndroid && !Platform.isIOS) return;
    try {
      await Firebase.initializeApp();
      FirebaseMessaging.onBackgroundMessage(
        firebaseMessagingBackgroundHandler,
      );
      await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      await FirebaseMessaging.instance
          .setForegroundNotificationPresentationOptions(
        alert: true,
        badge: true,
        sound: true,
      );
      await _foregroundSubscription?.cancel();
      _foregroundSubscription = FirebaseMessaging.onMessage.listen(
        showRemoteMessage,
      );
      _pushInitialized = true;
    } catch (_) {
      _pushInitialized = false;
    }
  }

  static Future<String?> pushToken() async {
    await initializePushMessaging();
    if (!_pushInitialized) return null;
    try {
      return await FirebaseMessaging.instance.getToken();
    } catch (_) {
      return null;
    }
  }

  static Stream<String> get tokenRefreshes =>
      FirebaseMessaging.instance.onTokenRefresh;

  static Future<void> showRemoteMessage(RemoteMessage message) async {
    await initialize();
    if (!_initialized) return;
    final title = message.notification?.title ??
        message.data['title']?.toString() ??
        'QuickBill notification';
    final body = message.notification?.body ??
        message.data['body']?.toString() ??
        'QuickBill has a new update.';
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        pushChannelId,
        'QuickBill push alerts',
        channelDescription: 'Order and status notifications from QuickBill',
        importance: Importance.max,
        priority: Priority.max,
        playSound: true,
        sound: _loudOrderSound,
        audioAttributesUsage: AudioAttributesUsage.alarm,
        enableVibration: true,
        category: AndroidNotificationCategory.message,
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    );
    try {
      await _notifications.show(
        id: message.messageId?.hashCode ??
            DateTime.now().millisecondsSinceEpoch.remainder(100000),
        title: title,
        body: body,
        notificationDetails: details,
        payload: message.data['orderId']?.toString(),
      );
    } catch (_) {}
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
