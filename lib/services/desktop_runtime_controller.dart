import 'dart:io';

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'local_api_server.dart';
import 'mobile_sync_store.dart';

class DesktopRuntimeController with WindowListener, TrayListener {
  DesktopRuntimeController._();

  static final DesktopRuntimeController instance = DesktopRuntimeController._();

  bool _quitting = false;
  bool _ready = false;
  bool _trayReady = false;

  bool get _isDesktop =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  Future<void> initialize() async {
    if (!_isDesktop || _ready) return;
    _ready = true;
    windowManager.addListener(this);
    trayManager.addListener(this);
    await _initTray();
    if (_trayReady) {
      await windowManager.setPreventClose(true);
    }
    await startServerOnLaunch();
  }

  Future<void> _initTray() async {
    try {
      await trayManager.setIcon(
        Platform.isWindows
            ? 'windows/runner/resources/app_icon.ico'
            : 'assets/icon.png',
      );
      await trayManager.setToolTip('QuickBill By Abdullah');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show_window', label: 'Show QuickBill'),
            MenuItem.separator(),
            MenuItem(key: 'exit_app', label: 'Exit QuickBill'),
          ],
        ),
      );
      _trayReady = true;
    } catch (_) {
      // Tray support should not block the desktop app from opening.
    }
  }

  Future<void> startServerOnLaunch() async {
    if (!_isDesktop || LocalApiServer.isRunning) return;
    var config = await MobileAccessStore.loadServerConfig();
    config = config.copyWith(enabled: true);
    try {
      await LocalApiServer.start(host: config.host, port: config.port);
      await MobileAccessStore.saveServerConfig(
        config.copyWith(
          lastStatus:
              'Laptop server auto-started on ${config.host}:${config.port}.',
          lastSyncAt: DateTime.now().toIso8601String(),
        ),
      );
    } catch (e) {
      await MobileAccessStore.saveServerConfig(
        config.copyWith(
          enabled: false,
          lastStatus: 'Laptop server auto-start failed: $e',
          lastSyncAt: DateTime.now().toIso8601String(),
        ),
      );
    }
  }

  Future<void> _showWindow() async {
    await windowManager.setSkipTaskbar(false);
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _hideToTray() async {
    await windowManager.hide();
    await windowManager.setSkipTaskbar(true);
  }

  Future<void> _exitApp() async {
    _quitting = true;
    try {
      await LocalApiServer.stop();
    } catch (_) {}
    try {
      await trayManager.destroy();
    } catch (_) {}
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  @override
  void onWindowClose() {
    if (_quitting) return;
    if (_trayReady) {
      _hideToTray();
    } else {
      _exitApp();
    }
  }

  @override
  void onTrayIconMouseDown() {
    if (Platform.isWindows) {
      trayManager.popUpContextMenu();
    } else {
      _showWindow();
    }
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show_window':
        _showWindow();
        break;
      case 'exit_app':
        _exitApp();
        break;
    }
  }
}
