import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:io';
import 'app.dart';
import 'services/desktop_runtime_controller.dart';
import 'services/notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await windowManager.ensureInitialized();

    const opts = WindowOptions(
      size: Size(1000, 700),
      minimumSize: Size(400, 300),
      center: true,
      titleBarStyle: TitleBarStyle.hidden,
    );

    windowManager.waitUntilReadyToShow(opts, () async {
      await windowManager.show();
      await windowManager.focus();
    });
  }
  await NotificationService.initialize();
  await NotificationService.initializePushMessaging();
  await DesktopRuntimeController.instance.initialize();

  runApp(const App());
}
