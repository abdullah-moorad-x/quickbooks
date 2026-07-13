import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:local_auth/local_auth.dart';
import 'package:share_plus/share_plus.dart';

import '../core/app_bus.dart';
import '../core/constants.dart';
import '../core/enums.dart';
import '../models/customer.dart';
import '../models/invoice.dart';
import '../models/mobile_access.dart';
import '../models/payment.dart';
import 'godown_hisaab_screen.dart';
import 'invoice_screen.dart';
import 'payments_screen.dart';
import 'stats_screen.dart';
import '../services/mobile_sync_store.dart';
import '../services/mobile_draft_retry_service.dart';
import '../services/invoice_draft_suggestions.dart';
import '../services/notification_service.dart';
import '../services/godown_stock_store.dart';
import '../services/paths.dart';
import '../services/pdf_builder.dart';
import '../services/server_sync_client.dart';
import '../services/storage.dart';
import '../utils/date.dart';
import '../utils/format.dart';
import '../utils/snackbar.dart';
import '../widgets/app_panels.dart';
import '../widgets/customer_summary_card.dart';
import '../widgets/expandable_card.dart';
import '../widgets/invoice_summary_card.dart';
import '../widgets/skeleton_loader.dart';

Future<ServerSyncResult> _pullLaptopData(AppUser user) async {
  final config = await MobileAccessStore.loadServerConfig();
  return ServerSyncClient.syncReadOnlyData(
    baseUrl: config.baseUrl,
    username: user.username,
    passcode: user.passcode,
  );
}

String _pullSuccessMessage(ServerSyncResult result) {
  return 'Synced ${result.customerCount} customers, ${result.invoiceCount} invoices, ${result.paymentCount} payments, and ${result.orderCount} orders.';
}

final ValueNotifier<bool> _mobileOrderDragActive = ValueNotifier(false);
DateTime _mobileOrderSyncPausedUntil = DateTime.fromMillisecondsSinceEpoch(0);

bool _mobileOrderSyncPaused() {
  return _mobileOrderDragActive.value ||
      DateTime.now().isBefore(_mobileOrderSyncPausedUntil);
}

void _pauseMobileOrderSync([Duration duration = const Duration(seconds: 2)]) {
  _mobileOrderSyncPausedUntil = DateTime.now().add(duration);
}

class MobileShell extends StatefulWidget {
  const MobileShell({super.key});

  @override
  State<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<MobileShell> {
  AppUser? _sessionUser;

  void _handleLogin(AppUser user) {
    setState(() => _sessionUser = user);
  }

  void _handleLogout() {
    setState(() => _sessionUser = null);
  }

  @override
  Widget build(BuildContext context) {
    if (_sessionUser == null) {
      return MobileLoginScreen(onLogin: _handleLogin);
    }
    return MobileHomeScreen(user: _sessionUser!, onLogout: _handleLogout);
  }
}

class MobileLoginScreen extends StatefulWidget {
  final ValueChanged<AppUser> onLogin;

  const MobileLoginScreen({super.key, required this.onLogin});

  @override
  State<MobileLoginScreen> createState() => _MobileLoginScreenState();
}

class _MobileLoginScreenState extends State<MobileLoginScreen> {
  final _usernameCtrl = TextEditingController();
  final _passcodeCtrl = TextEditingController();
  final LocalAuthentication _localAuth = LocalAuthentication();
  bool _loading = false;
  bool _biometricReady = false;
  BiometricLoginConfig _biometricConfig = const BiometricLoginConfig();

  @override
  void initState() {
    super.initState();
    _loadBiometricState();
  }

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _passcodeCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadBiometricState() async {
    final config = await MobileAccessStore.loadBiometricLoginConfig();
    bool ready = false;
    try {
      ready = await _localAuth.isDeviceSupported() &&
          await _localAuth.canCheckBiometrics &&
          (await _localAuth.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {
      ready = false;
    }
    if (!mounted) return;
    setState(() {
      _biometricConfig = config;
      _biometricReady = ready;
    });
  }

  Future<void> _saveBiometricUser(AppUser user) async {
    if (!_biometricReady) return;
    await MobileAccessStore.saveBiometricLoginConfig(
      BiometricLoginConfig(
        userId: user.id,
        username: user.username,
        displayName: user.displayName,
        enabled: true,
        updatedAt: DateTime.now().toIso8601String(),
      ),
    );
    if (!mounted) return;
    setState(() {
      _biometricConfig = BiometricLoginConfig(
        userId: user.id,
        username: user.username,
        displayName: user.displayName,
        enabled: true,
        updatedAt: DateTime.now().toIso8601String(),
      );
    });
  }

  Future<void> _loginWithFingerprint() async {
    if (!_biometricReady || !_biometricConfig.isConfigured) return;
    setState(() => _loading = true);
    try {
      final authenticated = await _localAuth.authenticate(
        localizedReason: 'Use fingerprint to sign in to QuickBill Mobile',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );
      if (!authenticated) {
        if (!mounted) return;
        setState(() => _loading = false);
        return;
      }
      final users = await MobileAccessStore.loadUsers();
      final matched = users.cast<AppUser?>().firstWhere(
            (user) =>
                user != null &&
                user.active &&
                user.id == _biometricConfig.userId,
            orElse: () => null,
          );
      if (!mounted) return;
      setState(() => _loading = false);
      if (matched == null) {
        showErr(context, 'Fingerprint user is not available on this phone.');
        return;
      }
      widget.onLogin(matched);
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
      showErr(context, 'Fingerprint login is not available right now.');
    }
  }

  Future<void> _login() async {
    final username = _usernameCtrl.text.trim().toLowerCase();
    final passcode = _passcodeCtrl.text.trim();
    if (username.isEmpty || passcode.isEmpty) {
      showErr(context, 'Username and passcode are required.');
      return;
    }
    setState(() => _loading = true);
    AppUser? matched;
    final serverConfig = await MobileAccessStore.loadServerConfig();
    final baseUrl = serverConfig.baseUrl.trim();
    if (baseUrl.isNotEmpty) {
      try {
        final auth = await ServerSyncClient.authenticateUser(
          baseUrl: baseUrl,
          username: username,
          passcode: passcode,
        );
        matched = await MobileAccessStore.upsertUser(auth.user);
      } on ServerSyncException {
        // Fall back to local cached users only when server auth is unavailable.
      }
    }
    matched ??=
        (await MobileAccessStore.loadUsers()).cast<AppUser?>().firstWhere(
              (user) =>
                  user != null &&
                  user.active &&
                  user.username.toLowerCase() == username &&
                  user.passcode == passcode,
              orElse: () => null,
            );
    if (!mounted) return;
    setState(() => _loading = false);
    if (matched == null) {
      showErr(context, 'Invalid login.');
      return;
    }
    await _saveBiometricUser(matched);
    widget.onLogin(matched);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'QuickBill Mobile',
                    style: Theme.of(context)
                        .textTheme
                        .headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Use the role created on desktop. Phone shows a local read-only copy of business data.',
                  ),
                  const SizedBox(height: 20),
                  TextField(
                    controller: _usernameCtrl,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(labelText: 'Username'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _passcodeCtrl,
                    obscureText: true,
                    onSubmitted: (_) => _login(),
                    decoration: const InputDecoration(labelText: 'Passcode'),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _loading ? null : _login,
                    child: Text(_loading ? 'Checking...' : 'Login'),
                  ),
                  if (_biometricReady && _biometricConfig.isConfigured) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      style: appGreenOutlineButtonStyle(context),
                      onPressed: _loading ? null : _loginWithFingerprint,
                      icon: const Icon(Icons.fingerprint),
                      label: Text(
                        _biometricConfig.displayName.trim().isEmpty
                            ? 'Login with fingerprint'
                            : 'Fingerprint - ${_biometricConfig.displayName}',
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  const Text(
                    'First sign in with username/passcode. After that, fingerprint can be used on this phone.',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class MobileHomeScreen extends StatefulWidget {
  final AppUser user;
  final VoidCallback onLogout;

  const MobileHomeScreen({
    super.key,
    required this.user,
    required this.onLogout,
  });

  @override
  State<MobileHomeScreen> createState() => _MobileHomeScreenState();
}

class _MobileHomeScreenState extends State<MobileHomeScreen> {
  int _tab = 0;
  final List<Widget?> _tabCache = <Widget?>[];
  List<Widget>? _drawerChildrenCache;
  bool _tabsReady = false;
  Timer? _dataPreloadTimer;
  int _dataPreloadStep = 0;
  Timer? _orderAutoSyncTimer;
  Timer? _locationShareTimer;
  StreamSubscription<String>? _pushTokenSubscription;
  bool _autoSyncingOrders = false;
  bool _sendingLocation = false;
  bool _pushNotificationsActive = false;
  Set<String> _knownOrderIds = const <String>{};
  Map<String, String> _knownOrderStatusKeys = const <String, String>{};

  List<({WidgetBuilder builder, IconData icon, String label})> _navItems() {
    return [
      (
        builder: (_) => StatsScreen(
              onRefresh: () async {
                await _pullLaptopData(widget.user);
              },
            ),
        icon: Icons.insights_outlined,
        label: 'Stats',
      ),
      if (widget.user.role != UserRole.viewer)
        (
          builder: (_) => const InvoiceScreen(makeupInvoiceMode: true),
          icon: Icons.edit_document,
          label: 'Makeup',
        ),
      (
        builder: (_) => MobileInvoicesTab(user: widget.user),
        icon: Icons.receipt_long_outlined,
        label: 'Invoices',
      ),
      (
        builder: (_) => MobileOrdersTab(user: widget.user),
        icon: Icons.assignment_outlined,
        label: 'Orders',
      ),
      (
        builder: (_) => PaymentsScreen(
              readOnly: widget.user.role != UserRole.admin,
              mobileUser:
                  widget.user.role == UserRole.admin ? widget.user : null,
              onRefresh: () async {
                await _pullLaptopData(widget.user);
              },
            ),
        icon: Icons.payments_outlined,
        label: 'Payments',
      ),
      (
        builder: (_) => MobileCustomersTab(user: widget.user),
        icon: Icons.people_alt_outlined,
        label: 'Customers',
      ),
      (
        builder: (_) => GodownHisaabScreen(
              readOnly: true,
              onRefresh: () async {
                await _pullLaptopData(widget.user);
              },
            ),
        icon: Icons.warehouse_outlined,
        label: 'Godown',
      ),
      (
        builder: (_) => MobileSyncSettingsTab(user: widget.user),
        icon: Icons.sync_alt_outlined,
        label: 'Sync',
      ),
    ];
  }

  void _syncTabCacheLength(int length) {
    while (_tabCache.length < length) {
      _tabCache.add(null);
    }
    while (_tabCache.length > length) {
      _tabCache.removeLast();
    }
  }

  List<Widget> _cachedTabChildren(
    BuildContext context,
    List<({WidgetBuilder builder, IconData icon, String label})> navItems,
  ) {
    _syncTabCacheLength(navItems.length);
    if (_tabsReady) {
      _ensureCachedTab(context, navItems, _tab);
    }
    return [
      for (var i = 0; i < navItems.length; i++)
        _tabCache[i] ??
            const SizedBox.expand(
              child: AppSkeletonLoader(),
            ),
    ];
  }

  void _ensureCachedTab(
    BuildContext context,
    List<({WidgetBuilder builder, IconData icon, String label})> navItems,
    int index,
  ) {
    if (index < 0 || index >= navItems.length) return;
    _tabCache[index] ??= KeyedSubtree(
      key: ValueKey(navItems[index].label),
      child: navItems[index].builder(context),
    );
  }

  List<Widget> _drawerChildren(
    BuildContext context,
    List<({WidgetBuilder builder, IconData icon, String label})> navItems,
  ) {
    return _drawerChildrenCache ??= [
      Padding(
        padding: const EdgeInsets.fromLTRB(28, 28, 28, 20),
        child: Row(
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                color: const Color(0xFFD0BCFF),
                borderRadius: BorderRadius.circular(18),
              ),
              child: const SizedBox(
                width: 52,
                height: 52,
                child: Icon(
                  Icons.receipt_long,
                  color: Color(0xFF21005D),
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'QuickBill',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: const Color(0xFF1D1B20),
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    widget.user.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF625B71),
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      ...navItems.map(
        (item) => NavigationDrawerDestination(
          icon: Icon(item.icon),
          selectedIcon: Icon(_selectedIconFor(item.icon)),
          label: Text(item.label),
        ),
      ),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 28, vertical: 12),
        child: Divider(height: 1),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: ListTile(
          leading: const Icon(Icons.logout, color: Color(0xFFBA1A1A)),
          title: const Text(
            'Logout',
            style: TextStyle(
              color: Color(0xFFBA1A1A),
              fontWeight: FontWeight.w700,
            ),
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28),
          ),
          onTap: () {
            Navigator.of(context).pop();
            widget.onLogout();
          },
        ),
      ),
    ];
  }

  IconData _selectedIconFor(IconData icon) {
    if (icon == Icons.insights_outlined) return Icons.insights;
    if (icon == Icons.home_outlined) return Icons.home;
    if (icon == Icons.receipt_long_outlined) return Icons.receipt_long;
    if (icon == Icons.assignment_outlined) return Icons.assignment;
    if (icon == Icons.payments_outlined) return Icons.payments;
    if (icon == Icons.people_alt_outlined) return Icons.people_alt;
    if (icon == Icons.warehouse_outlined) return Icons.warehouse;
    if (icon == Icons.sync_alt_outlined) return Icons.sync_alt;
    return icon;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _tabsReady = true);
      MobileDraftRetryService.start(widget.user);
      _scheduleDataPreload();
      Future<void>.delayed(const Duration(milliseconds: 350), () {
        if (mounted) _startOrderAutoSync();
      });
      Future<void>.delayed(const Duration(milliseconds: 900), () {
        if (!mounted) return;
        _startLocationSharing();
        _startPushNotifications();
      });
    });
  }

  @override
  void didUpdateWidget(covariant MobileHomeScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.user.id != widget.user.id ||
        oldWidget.user.passcode != widget.user.passcode) {
      _startOrderAutoSync();
      MobileDraftRetryService.start(widget.user);
      _startLocationSharing();
      _startPushNotifications();
      _tab = 0;
      _tabCache.clear();
      _drawerChildrenCache = null;
      _tabsReady = true;
      _dataPreloadStep = 0;
      _scheduleDataPreload();
    }
  }

  @override
  void dispose() {
    _dataPreloadTimer?.cancel();
    _orderAutoSyncTimer?.cancel();
    _locationShareTimer?.cancel();
    _pushTokenSubscription?.cancel();
    MobileDraftRetryService.stop();
    super.dispose();
  }

  void _startPushNotifications() {
    _pushTokenSubscription?.cancel();
    unawaited(_registerPushToken());
    _pushTokenSubscription = NotificationService.tokenRefreshes.listen(
      (token) => unawaited(_registerPushToken(token)),
    );
  }

  Future<void> _registerPushToken([String? refreshedToken]) async {
    try {
      final token = refreshedToken ?? await NotificationService.pushToken();
      if (token == null || token.trim().isEmpty) return;
      _pushNotificationsActive = true;
      final config = await MobileAccessStore.loadServerConfig();
      if (config.baseUrl.trim().isEmpty) return;
      final suffix =
          token.length <= 18 ? token : token.substring(token.length - 18);
      await ServerSyncClient.registerPushToken(
        baseUrl: config.baseUrl,
        username: widget.user.username,
        passcode: widget.user.passcode,
        pushToken: token,
        deviceId: 'fcm-${widget.user.id}-$suffix',
        platform: Platform.operatingSystem,
      );
    } catch (_) {
      // Push registration retries the next time the user opens the app.
    }
  }

  void _scheduleDataPreload({
    Duration delay = const Duration(milliseconds: 900),
  }) {
    _dataPreloadTimer?.cancel();
    _dataPreloadTimer = Timer(delay, () => unawaited(_preloadNextData()));
  }

  Future<void> _preloadNextData() async {
    if (!mounted || !_tabsReady) return;
    try {
      switch (_dataPreloadStep) {
        case 0:
          await MobileAccessStore.loadServerConfig();
          break;
        case 1:
          await MobileAccessStore.loadOrders();
          break;
        case 2:
          await MobileAccessStore.loadSurjaniTrucks();
          break;
        case 3:
          await MobileAccessStore.loadFactoryTrucks();
          break;
        case 4:
          await MobileAccessStore.loadOutgoingPayments();
          break;
        case 5:
          await MobileAccessStore.loadSyncLogs();
          break;
        case 6:
          await CustomerStore.loadAll();
          break;
        case 7:
          await Store.loadAll();
          break;
        case 8:
          await PaymentStore.loadAll();
          break;
        default:
          return;
      }
    } catch (_) {
      // Preloading should never interrupt normal mobile use.
    }
    if (!mounted) return;
    _dataPreloadStep++;
    _scheduleDataPreload(delay: const Duration(milliseconds: 1200));
  }

  void _startOrderAutoSync() {
    _orderAutoSyncTimer?.cancel();
    _knownOrderIds = const <String>{};
    _knownOrderStatusKeys = const <String, String>{};
    unawaited(_primeAndSyncOrders());
    _orderAutoSyncTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_syncOrdersInBackground()),
    );
  }

  void _startLocationSharing() {
    _locationShareTimer?.cancel();
    unawaited(_sendLocationIfEnabled());
    _locationShareTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => unawaited(_sendLocationIfEnabled()),
    );
  }

  Future<void> _sendLocationIfEnabled() async {
    if (_sendingLocation) return;
    _sendingLocation = true;
    try {
      final config = await MobileAccessStore.loadServerConfig();
      if (config.baseUrl.trim().isEmpty) return;
      if (!await Geolocator.isLocationServiceEnabled()) return;
      final permission = await Geolocator.checkPermission();
      if (permission != LocationPermission.always &&
          permission != LocationPermission.whileInUse) {
        return;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 12),
        ),
      );
      await ServerSyncClient.submitLocation(
        baseUrl: config.baseUrl,
        username: widget.user.username,
        passcode: widget.user.passcode,
        latitude: position.latitude,
        longitude: position.longitude,
        accuracyMeters: position.accuracy,
        capturedAt: position.timestamp.toIso8601String(),
        deviceId: 'mobile-${widget.user.id}',
      );
    } catch (_) {
      // Location sharing should not interrupt normal app use.
    } finally {
      _sendingLocation = false;
    }
  }

  Future<void> _primeAndSyncOrders() async {
    final localOrders = await MobileAccessStore.loadOrders();
    _knownOrderIds = localOrders.map((order) => order.id).toSet();
    _knownOrderStatusKeys = {
      for (final order in localOrders) order.id: _orderStatusKey(order),
    };
    await _syncOrdersInBackground();
  }

  Future<void> _syncOrdersInBackground() async {
    if (_autoSyncingOrders || _mobileOrderSyncPaused()) return;
    _autoSyncingOrders = true;
    try {
      final config = await MobileAccessStore.loadServerConfig();
      if (config.baseUrl.trim().isEmpty) return;
      final before = _knownOrderIds;
      final beforeStatusKeys = _knownOrderStatusKeys;
      final orders = await ServerSyncClient.fetchOrders(
        baseUrl: config.baseUrl,
        username: widget.user.username,
        passcode: widget.user.passcode,
      );
      final current = orders.map((order) => order.id).toSet();
      _knownOrderIds = current;
      _knownOrderStatusKeys = {
        for (final order in orders) order.id: _orderStatusKey(order),
      };
      final newOrders = orders
          .where((order) =>
              order.id.trim().isNotEmpty &&
              !before.contains(order.id) &&
              order.createdByUserId != widget.user.id)
          .toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      for (final order in newOrders) {
        if (!_pushNotificationsActive) {
          await NotificationService.showNewOrder(order);
        }
      }
      final changedStatusOrders = orders
          .where((order) =>
              before.contains(order.id) &&
              order.status != MobileOrderStatus.pending &&
              beforeStatusKeys[order.id] != _orderStatusKey(order) &&
              order.statusUpdatedByUserId != widget.user.id)
          .toList()
        ..sort((a, b) => a.statusUpdatedAt.compareTo(b.statusUpdatedAt));
      for (final order in changedStatusOrders) {
        if (!_pushNotificationsActive) {
          await NotificationService.showOrderStatusChanged(order);
        }
      }
    } catch (_) {
      // Background order sync should not interrupt normal mobile use.
    } finally {
      _autoSyncingOrders = false;
    }
  }

  String _orderStatusKey(MobileOrder order) {
    return '${order.status.name}|${order.statusUpdatedAt}|${order.statusUpdatedByUserId}';
  }

  void _openTab(int index) {
    if (index == _tab) return;
    setState(() => _tab = index);
  }

  void _selectDrawerTab(int index) {
    Navigator.of(context).pop();
    Future<void>.delayed(const Duration(milliseconds: 240), () {
      if (!mounted) return;
      _openTab(index);
    });
  }

  @override
  Widget build(BuildContext context) {
    final navItems = _navItems();
    _syncTabCacheLength(navItems.length);
    if (_tab >= navItems.length) {
      _tab = 0;
    }
    return Scaffold(
      backgroundColor: const Color(0xFFFEF9FF),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFEF9FF),
        foregroundColor: const Color(0xFF1D1B20),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text(
          navItems[_tab].label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: const Color(0xFF1D1B20),
                fontWeight: FontWeight.w800,
              ),
        ),
      ),
      drawer: NavigationDrawer(
        selectedIndex: _tab,
        backgroundColor: const Color(0xFFFEF9FF),
        surfaceTintColor: Colors.transparent,
        indicatorColor: const Color(0xFFEADDFF),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(28),
        ),
        onDestinationSelected: _selectDrawerTab,
        children: _drawerChildren(context, navItems),
      ),
      body: SafeArea(
        top: false,
        child: IndexedStack(
          index: _tab,
          children: _cachedTabChildren(context, navItems),
        ),
      ),
    );
  }
}

class MobileDashboardTab extends StatefulWidget {
  final AppUser user;

  const MobileDashboardTab({super.key, required this.user});

  @override
  State<MobileDashboardTab> createState() => _MobileDashboardTabState();
}

class _MobileDashboardTabState extends State<MobileDashboardTab> {
  bool _loading = true;
  List<Invoice> _invoices = const [];
  List<PaymentEntry> _payments = const [];
  List<MobileTruck> _surjaniTrucks = const [];
  List<MobileTruck> _factoryTrucks = const [];
  ServerSyncConfig _syncConfig = const ServerSyncConfig();

  @override
  void initState() {
    super.initState();
    _load();
    AppBus.dataTick.addListener(_onDataTick);
  }

  @override
  void dispose() {
    AppBus.dataTick.removeListener(_onDataTick);
    super.dispose();
  }

  void _onDataTick() {
    if (!mounted) return;
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      Store.loadAll(),
      PaymentStore.loadAll(),
      MobileAccessStore.loadServerConfig(),
      MobileAccessStore.loadSurjaniTrucks(),
      MobileAccessStore.loadFactoryTrucks(),
    ]);
    if (!mounted) return;
    setState(() {
      _invoices = results[0] as List<Invoice>;
      _payments = results[1] as List<PaymentEntry>;
      _syncConfig = results[2] as ServerSyncConfig;
      _surjaniTrucks = results[3] as List<MobileTruck>;
      _factoryTrucks = results[4] as List<MobileTruck>;
      _loading = false;
    });
  }

  Future<void> _syncFromLaptop() async {
    try {
      final result = await _pullLaptopData(widget.user);
      if (!mounted) return;
      showOk(context, _pullSuccessMessage(result));
    } on ServerSyncException catch (e) {
      if (!mounted) return;
      showErr(context, e.message);
    } finally {
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const AppSkeletonLoader();
    }
    final theme = Theme.of(context);
    final now = DateTime.now();
    bool isCurrentMonth(DateTime date) =>
        date.year == now.year && date.month == now.month;
    final currentMonthInvoices = _invoices.where((invoice) {
      try {
        return isCurrentMonth(parseInvoiceDate(invoice.date));
      } catch (_) {
        return false;
      }
    }).toList();
    final monthBags = currentMonthInvoices.fold<double>(
      0,
      (sum, invoice) => sum + _bagsInInvoice(invoice),
    );
    final currentMonthSales = currentMonthInvoices.fold<double>(
      0,
      (sum, invoice) => sum + invoice.balance,
    );
    final currentMonthReceived = _payments.where((payment) {
      try {
        return isCurrentMonth(parseInvoiceDate(payment.date));
      } catch (_) {
        return false;
      }
    }).fold<double>(0, (sum, payment) => sum + payment.effectiveAmount);
    final monthlySalesSeries = List<double>.generate(6, (index) {
      final monthDate = DateTime(now.year, now.month - (5 - index), 1);
      return _invoices.where((invoice) {
        try {
          final parsed = parseInvoiceDate(invoice.date);
          return parsed.year == monthDate.year &&
              parsed.month == monthDate.month;
        } catch (_) {
          return false;
        }
      }).fold<double>(0, (sum, invoice) => sum + invoice.balance);
    });
    final monthlyBagSeries = List<double>.generate(6, (index) {
      final monthDate = DateTime(now.year, now.month - (5 - index), 1);
      return _invoices.where((invoice) {
        try {
          final parsed = parseInvoiceDate(invoice.date);
          return parsed.year == monthDate.year &&
              parsed.month == monthDate.month;
        } catch (_) {
          return false;
        }
      }).fold<double>(0, (sum, invoice) => sum + _bagsInInvoice(invoice));
    });
    final monthlyReceivedSeries = List<double>.generate(6, (index) {
      final monthDate = DateTime(now.year, now.month - (5 - index), 1);
      return _payments.where((payment) {
        try {
          final parsed = parseInvoiceDate(payment.date);
          return parsed.year == monthDate.year &&
              parsed.month == monthDate.month;
        } catch (_) {
          return false;
        }
      }).fold<double>(0, (sum, payment) => sum + payment.effectiveAmount);
    });
    final sixMonthBags = monthlyBagSeries.fold<double>(
      0,
      (sum, value) => sum + value,
    );
    final sixMonthReceived = monthlyReceivedSeries.fold<double>(
      0,
      (sum, value) => sum + value,
    );
    final currentMonthStart = DateTime(now.year, now.month, 1);
    final detailStart = DateTime(now.year, now.month - 5, 1);
    final detailEnd = DateTime(now.year, now.month + 1, 1);
    final currentMonthDetails =
        _categoryDetailsForRange(currentMonthStart, detailEnd);
    final categoryDetails = _categoryDetailsForRange(detailStart, detailEnd);
    final currentMonthIncoming =
        _truckIncomingDetailsForRange(currentMonthStart, detailEnd);
    final sixMonthIncoming =
        _truckIncomingDetailsForRange(detailStart, detailEnd);
    final currentSurjaniIncoming = currentMonthIncoming
        .firstWhere((detail) => detail.source == 'Surjani')
        .totalBags;
    final currentFactoryIncoming = currentMonthIncoming
        .firstWhere((detail) => detail.source == 'Factory')
        .totalBags;
    final sixMonthSales =
        monthlySalesSeries.fold<double>(0, (sum, value) => sum + value);
    void openCurrentMonthStats() => _showStatsDetails(
          title: 'Current Month Stats Details',
          paymentReceived: currentMonthReceived,
          soldBags: monthBags,
          salesAmount: currentMonthSales,
          details: currentMonthDetails,
          incomingDetails: currentMonthIncoming,
        );
    void openSixMonthStats() => _showStatsDetails(
          title: '6-Month Stats Details',
          paymentReceived: sixMonthReceived,
          soldBags: sixMonthBags,
          salesAmount: sixMonthSales,
          details: categoryDetails,
          incomingDetails: sixMonthIncoming,
        );
    final monthLabels = List<String>.generate(6, (index) {
      final monthDate = DateTime(now.year, now.month - (5 - index), 1);
      const names = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec'
      ];
      return names[monthDate.month - 1];
    });
    final daysInMonth = DateTime(now.year, now.month + 1, 0).day;
    final currentDayIndex = (now.day - 1).clamp(0, daysInMonth - 1);
    final dailyLabels = List<String>.generate(
      daysInMonth,
      (index) => '${index + 1}',
    );
    final dailySalesSeries = List<double>.generate(daysInMonth, (index) {
      final day = DateTime(now.year, now.month, index + 1);
      return _invoices.where((invoice) {
        try {
          final parsed = parseInvoiceDate(invoice.date);
          return parsed.year == day.year &&
              parsed.month == day.month &&
              parsed.day == day.day;
        } catch (_) {
          return false;
        }
      }).fold<double>(0, (sum, invoice) => sum + invoice.balance);
    });
    final dailyBagSeries = List<double>.generate(daysInMonth, (index) {
      final day = DateTime(now.year, now.month, index + 1);
      return _invoices.where((invoice) {
        try {
          final parsed = parseInvoiceDate(invoice.date);
          return parsed.year == day.year &&
              parsed.month == day.month &&
              parsed.day == day.day;
        } catch (_) {
          return false;
        }
      }).fold<double>(0, (sum, invoice) => sum + _bagsInInvoice(invoice));
    });
    final dailyReceivedSeries = List<double>.generate(daysInMonth, (index) {
      final day = DateTime(now.year, now.month, index + 1);
      return _payments.where((payment) {
        try {
          final parsed = parseInvoiceDate(payment.date);
          return parsed.year == day.year &&
              parsed.month == day.month &&
              parsed.day == day.day;
        } catch (_) {
          return false;
        }
      }).fold<double>(0, (sum, payment) => sum + payment.effectiveAmount);
    });
    return RefreshIndicator(
      onRefresh: _syncFromLaptop,
      color: const Color(0xFF4B5DFF),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          AppPressable(
            onTap: openCurrentMonthStats,
            borderRadius: BorderRadius.circular(28),
            child: Container(
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF5B63F6), Color(0xFF2B2F77)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(28),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x332B2F77),
                    blurRadius: 28,
                    offset: Offset(0, 18),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'QuickBill Dashboard',
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Role: ${userRoleLabel(widget.user.role)}',
                      style: const TextStyle(color: Color(0xFFD9DDFF)),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _syncConfig.lastSyncAt == null
                          ? 'Last sync: not synced yet'
                          : 'Last sync: ${_syncConfig.lastSyncAt}',
                      style: const TextStyle(color: Color(0xFFB9C0FF)),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Current Month Bags Sold',
                                style: TextStyle(color: Color(0xFFD9DDFF)),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '${fmt0(monthBags)} bags',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 28,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  _DashboardGlassStat(
                                    label: 'Surjani in',
                                    value:
                                        '${fmt0(currentSurjaniIncoming)} bags',
                                  ),
                                  _DashboardGlassStat(
                                    label: 'Factory in',
                                    value:
                                        '${fmt0(currentFactoryIncoming)} bags',
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              _Sparkline(
                                values: dailyBagSeries,
                                color: const Color(0xFFFF7A9D),
                                fillColor: const Color(0x33FF7A9D),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 14),
                        Container(
                          width: 108,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: const Color(0x1FFFFFFF),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(color: const Color(0x33FFFFFF)),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.open_in_new_rounded,
                                  color: Colors.white),
                              const SizedBox(height: 10),
                              const Text(
                                'Mode',
                                style: TextStyle(
                                  color: Color(0xFFD9DDFF),
                                  fontSize: 12,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                userRoleLabel(widget.user.role),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _ModernMetricCard(
                  title: '6-Month Received',
                  value: 'Rs ${fmt0(sixMonthReceived)}',
                  accent: const Color(0xFF17C7A3),
                  icon: Icons.south_west_rounded,
                  onTap: openSixMonthStats,
                  child: _Sparkline(
                    values: monthlyReceivedSeries,
                    color: const Color(0xFF17C7A3),
                    fillColor: const Color(0x3317C7A3),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _ModernMetricCard(
                  title: '6-Month Bags Sold',
                  value: fmt0(sixMonthBags),
                  accent: const Color(0xFFFF9F1C),
                  icon: Icons.north_east_rounded,
                  onTap: openSixMonthStats,
                  child: _Sparkline(
                    values: monthlyBagSeries,
                    color: const Color(0xFFFF9F1C),
                    fillColor: const Color(0x33FF9F1C),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _DashboardGraphPager(
            dailyLabels: dailyLabels,
            dailyBags: dailyBagSeries,
            dailySales: dailySalesSeries,
            dailyReceived: dailyReceivedSeries,
            monthLabels: monthLabels,
            monthlyBags: monthlyBagSeries,
            monthlySales: monthlySalesSeries,
            monthlyReceived: monthlyReceivedSeries,
            currentDayIndex: currentDayIndex,
            currentMonthIndex: monthLabels.length - 1,
            onOpenSixMonthDetails: openSixMonthStats,
          ),
        ],
      ),
    );
  }

  double _bagsInInvoice(Invoice invoice) {
    return invoice.lines.fold<double>(
      0,
      (sum, line) => sum + (line.qty > 0 ? line.qty : 0),
    );
  }

  List<_DashboardCategoryDetail> _categoryDetailsForRange(
    DateTime start,
    DateTime end,
  ) {
    final details = <String, _DashboardCategoryDetail>{
      for (final type in kItemTypes)
        _canonicalDashboardCategory(type): _DashboardCategoryDetail(
          category: _canonicalDashboardCategory(type),
        ),
    };

    for (final invoice in _invoices) {
      try {
        final date = parseInvoiceDate(invoice.date);
        if (date.isBefore(start) || !date.isBefore(end)) continue;
      } catch (_) {
        continue;
      }
      for (final line in invoice.lines) {
        if (line.qty <= 0) continue;
        final category = _canonicalDashboardCategory(line.typeLabel);
        final current = details[category];
        if (current == null) continue;
        details[category] = current.copyWith(
          soldBags: current.soldBags + line.qty,
          salesAmount: current.salesAmount + line.amount,
        );
      }
    }

    return kItemTypes
        .map((type) => details[_canonicalDashboardCategory(type)]!)
        .toList();
  }

  List<_DashboardTruckIncomingDetail> _truckIncomingDetailsForRange(
    DateTime start,
    DateTime end,
  ) {
    return [
      _truckIncomingDetailForRange('Surjani', _surjaniTrucks, start, end),
      _truckIncomingDetailForRange('Factory', _factoryTrucks, start, end),
    ];
  }

  _DashboardTruckIncomingDetail _truckIncomingDetailForRange(
    String source,
    List<MobileTruck> trucks,
    DateTime start,
    DateTime end,
  ) {
    final byType = <String, double>{
      for (final type in kItemTypes) _canonicalDashboardCategory(type): 0,
    };
    var totalBags = 0.0;
    var truckCount = 0;
    for (final truck in trucks) {
      DateTime date;
      try {
        date = parseInvoiceDate(truck.orderDate);
      } catch (_) {
        continue;
      }
      if (date.isBefore(start) || !date.isBefore(end)) continue;
      truckCount++;
      totalBags += truck.capacity;
      for (final entry in truck.typeBags.entries) {
        final category = _canonicalDashboardCategory(entry.key);
        byType[category] = (byType[category] ?? 0) + entry.value;
      }
    }
    byType.removeWhere((_, value) => value <= 0);
    return _DashboardTruckIncomingDetail(
      source: source,
      truckCount: truckCount,
      totalBags: totalBags,
      bagsByType: byType,
    );
  }

  void _showStatsDetails({
    required String title,
    required double paymentReceived,
    required double soldBags,
    required double salesAmount,
    required List<_DashboardCategoryDetail> details,
    required List<_DashboardTruckIncomingDetail> incomingDetails,
  }) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => _SixMonthStatsDetailSheet(
        title: title,
        paymentReceived: paymentReceived,
        soldBags: soldBags,
        salesAmount: salesAmount,
        details: details,
        incomingDetails: incomingDetails,
      ),
    );
  }
}

String _canonicalDashboardCategory(String value) {
  final normalized = value.trim().toUpperCase().replaceAll('-', ' ');
  if (normalized == 'BOND') return 'BOUND';
  if (normalized == 'WHITE' || normalized == 'WHITE CEMENT') {
    return 'WHITE CEMENT';
  }
  if (normalized == 'OPC' || normalized == 'SRC' || normalized == 'BLOCK') {
    return normalized;
  }
  return normalized;
}

String _dashboardCategoryLabel(String value) {
  final category = _canonicalDashboardCategory(value);
  if (category == 'BOUND') return 'Bond';
  if (category == 'WHITE CEMENT') return 'White Cement';
  return category;
}

class _DashboardCategoryDetail {
  final String category;
  final double soldBags;
  final double salesAmount;

  const _DashboardCategoryDetail({
    required this.category,
    this.soldBags = 0,
    this.salesAmount = 0,
  });

  _DashboardCategoryDetail copyWith({
    double? soldBags,
    double? salesAmount,
  }) {
    return _DashboardCategoryDetail(
      category: category,
      soldBags: soldBags ?? this.soldBags,
      salesAmount: salesAmount ?? this.salesAmount,
    );
  }
}

class _DashboardTruckIncomingDetail {
  final String source;
  final int truckCount;
  final double totalBags;
  final Map<String, double> bagsByType;

  const _DashboardTruckIncomingDetail({
    required this.source,
    required this.truckCount,
    required this.totalBags,
    required this.bagsByType,
  });
}

class _DashboardGlassStat extends StatelessWidget {
  final String label;
  final String value;

  const _DashboardGlassStat({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0x1FFFFFFF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x24FFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFFD9DDFF),
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _SixMonthStatsDetailSheet extends StatelessWidget {
  final String title;
  final double paymentReceived;
  final double soldBags;
  final double salesAmount;
  final List<_DashboardCategoryDetail> details;
  final List<_DashboardTruckIncomingDetail> incomingDetails;

  const _SixMonthStatsDetailSheet({
    required this.title,
    required this.paymentReceived,
    required this.soldBags,
    required this.salesAmount,
    required this.details,
    required this.incomingDetails,
  });

  @override
  Widget build(BuildContext context) {
    final byCategory = {
      for (final detail in details)
        _canonicalDashboardCategory(detail.category): detail,
    };
    final cementRows = ['OPC', 'SRC', 'BLOCK']
        .map((category) =>
            byCategory[category] ??
            _DashboardCategoryDetail(category: category))
        .toList();
    final whiteCement = byCategory['WHITE CEMENT'] ??
        const _DashboardCategoryDetail(category: 'WHITE CEMENT');
    final bond = byCategory['BOUND'] ??
        const _DashboardCategoryDetail(category: 'BOUND');

    return DraggableScrollableSheet(
      initialChildSize: .78,
      minChildSize: .45,
      maxChildSize: .94,
      builder: (context, controller) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFFF6F7FB),
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: ListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 5,
                  decoration: BoxDecoration(
                    color: const Color(0xFFD7DCEB),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        color: Color(0xFF1C2140),
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  _DetailTotalTile(
                    label: 'Payment received',
                    value: 'Rs ${fmt0(paymentReceived)}',
                    accent: const Color(0xFF17C7A3),
                  ),
                  _DetailTotalTile(
                    label: 'Bags sold',
                    value: '${fmt0(soldBags)} bags',
                    accent: const Color(0xFF5B63F6),
                  ),
                  _DetailTotalTile(
                    label: 'Sales',
                    value: 'Rs ${fmt0(salesAmount)}',
                    accent: const Color(0xFFFF9F1C),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              _IncomingTruckSection(rows: incomingDetails),
              const SizedBox(height: 12),
              _DetailSection(
                title: 'Cement',
                rows: cementRows,
              ),
              const SizedBox(height: 12),
              _DetailSection(
                title: 'White Cement',
                rows: [whiteCement],
              ),
              const SizedBox(height: 12),
              _DetailSection(
                title: 'Bond',
                rows: [bond],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DetailTotalTile extends StatelessWidget {
  final String label;
  final String value;
  final Color accent;

  const _DetailTotalTile({
    required this.label,
    required this.value,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 155,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: accent.withValues(alpha: .18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: accent,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF69708D),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _IncomingTruckSection extends StatelessWidget {
  final List<_DashboardTruckIncomingDetail> rows;

  const _IncomingTruckSection({required this.rows});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE6E9F2)),
      ),
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 14, 14, 8),
            child: Row(
              children: [
                Icon(
                  Icons.local_shipping_outlined,
                  size: 18,
                  color: Color(0xFF17A673),
                ),
                SizedBox(width: 8),
                Text(
                  'Incoming Trucks',
                  style: TextStyle(
                    color: Color(0xFF1C2140),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFFE6E9F2)),
          for (var i = 0; i < rows.length; i++) ...[
            _IncomingTruckRow(detail: rows[i]),
            if (i != rows.length - 1)
              const Divider(height: 1, color: Color(0xFFE6E9F2)),
          ],
        ],
      ),
    );
  }
}

class _IncomingTruckRow extends StatelessWidget {
  final _DashboardTruckIncomingDetail detail;

  const _IncomingTruckRow({required this.detail});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  detail.source,
                  style: const TextStyle(
                    color: Color(0xFF273247),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                '${fmt0(detail.totalBags)} bags',
                style: const TextStyle(
                  color: Color(0xFF17A673),
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _MiniStatPill(
                label: 'Trucks',
                value: '${detail.truckCount}',
                color: const Color(0xFF17A673),
              ),
              for (final entry in detail.bagsByType.entries)
                _MiniStatPill(
                  label: _dashboardCategoryLabel(entry.key),
                  value: '${fmt0(entry.value)} bags',
                  color: const Color(0xFF5B63F6),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DetailSection extends StatelessWidget {
  final String title;
  final List<_DashboardCategoryDetail> rows;

  const _DetailSection({
    required this.title,
    required this.rows,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE6E9F2)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
            child: Row(
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Color(0xFF1C2140),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFFE6E9F2)),
          for (var i = 0; i < rows.length; i++) ...[
            _DetailCategoryRow(detail: rows[i]),
            if (i != rows.length - 1)
              const Divider(height: 1, color: Color(0xFFE6E9F2)),
          ],
        ],
      ),
    );
  }
}

class _DetailCategoryRow extends StatelessWidget {
  final _DashboardCategoryDetail detail;

  const _DetailCategoryRow({required this.detail});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _dashboardCategoryLabel(detail.category),
            style: const TextStyle(
              color: Color(0xFF273247),
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _MiniStatPill(
                label: 'Sold',
                value: '${fmt0(detail.soldBags)} bags',
                color: const Color(0xFF5B63F6),
              ),
              _MiniStatPill(
                label: 'Sales',
                value: 'Rs ${fmt0(detail.salesAmount)}',
                color: const Color(0xFFFF9F1C),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MiniStatPill extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _MiniStatPill({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF69708D),
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _ModernMetricCard extends StatelessWidget {
  final String title;
  final String value;
  final Color accent;
  final IconData icon;
  final Widget child;
  final VoidCallback? onTap;

  const _ModernMetricCard({
    required this.title,
    required this.value,
    required this.accent,
    required this.icon,
    required this.child,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(24),
      elevation: 0,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            boxShadow: const [
              BoxShadow(
                color: Color(0x14000000),
                blurRadius: 20,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: .14),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, color: accent, size: 18),
                  ),
                  const SizedBox(width: 8),
                  if (onTap != null)
                    Icon(Icons.open_in_new_rounded, color: accent, size: 16),
                  if (onTap != null) const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: const TextStyle(
                        color: Color(0xFF5F6388),
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                        height: 1.15,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF1C2140),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(height: 52, child: child),
            ],
          ),
        ),
      ),
    );
  }
}

class _DashboardGraphPager extends StatefulWidget {
  final List<String> dailyLabels;
  final List<double> dailyBags;
  final List<double> dailySales;
  final List<double> dailyReceived;
  final List<String> monthLabels;
  final List<double> monthlyBags;
  final List<double> monthlySales;
  final List<double> monthlyReceived;
  final int currentDayIndex;
  final int currentMonthIndex;
  final VoidCallback? onOpenSixMonthDetails;

  const _DashboardGraphPager({
    required this.dailyLabels,
    required this.dailyBags,
    required this.dailySales,
    required this.dailyReceived,
    required this.monthLabels,
    required this.monthlyBags,
    required this.monthlySales,
    required this.monthlyReceived,
    required this.currentDayIndex,
    required this.currentMonthIndex,
    this.onOpenSixMonthDetails,
  });

  @override
  State<_DashboardGraphPager> createState() => _DashboardGraphPagerState();
}

class _DashboardGraphPagerState extends State<_DashboardGraphPager> {
  final PageController _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cards = [
      _InteractiveTrendCard(
        title: 'Daily Bags Sold',
        subtitle:
            'Graph is based on bags. Rupees are shown for the selected day.',
        labels: widget.dailyLabels,
        primaryValues: widget.dailyBags,
        secondaryValues: widget.dailySales,
        primaryLabel: 'Bags',
        secondaryLabel: 'Sales',
        primaryIsCurrency: false,
        primaryColor: const Color(0xFF5B63F6),
        secondaryColor: const Color(0xFFFF9F1C),
        fillColor: const Color(0x225B63F6),
        initialSelectedIndex: widget.currentDayIndex,
      ),
      _InteractiveTrendCard(
        title: 'Daily Received',
        subtitle: 'Payments received this month',
        labels: widget.dailyLabels,
        primaryValues: widget.dailyReceived,
        primaryLabel: 'Received',
        primaryColor: const Color(0xFF17C7A3),
        fillColor: const Color(0x2217C7A3),
        initialSelectedIndex: widget.currentDayIndex,
      ),
      _InteractiveTrendCard(
        title: '6-Month Received',
        subtitle: 'Payments received in the last 6 months.',
        labels: widget.monthLabels,
        primaryValues: widget.monthlyReceived,
        primaryLabel: 'Payments',
        primaryColor: const Color(0xFF17C7A3),
        fillColor: const Color(0x2217C7A3),
        initialSelectedIndex: widget.currentMonthIndex,
        onOpenDetails: widget.onOpenSixMonthDetails,
      ),
      _InteractiveTrendCard(
        title: '6-Month Bags Sold',
        subtitle: 'Graph is based on bags. Rupees are secondary detail.',
        labels: widget.monthLabels,
        primaryValues: widget.monthlyBags,
        secondaryValues: widget.monthlySales,
        primaryLabel: 'Bags',
        secondaryLabel: 'Sales',
        primaryIsCurrency: false,
        primaryColor: const Color(0xFF5B63F6),
        secondaryColor: const Color(0xFFFF9F1C),
        fillColor: const Color(0x225B63F6),
        initialSelectedIndex: widget.currentMonthIndex,
        onOpenDetails: widget.onOpenSixMonthDetails,
      ),
    ];
    return Column(
      children: [
        SizedBox(
          height: 360,
          child: PageView.builder(
            controller: _controller,
            onPageChanged: (value) => setState(() => _page = value),
            itemCount: cards.length,
            itemBuilder: (_, index) => cards[index],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < cards.length; i++)
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: _page == i ? 22 : 8,
                height: 8,
                margin: const EdgeInsets.symmetric(horizontal: 4),
                decoration: BoxDecoration(
                  color: _page == i
                      ? const Color(0xFF5B63F6)
                      : const Color(0xFFD7DCEB),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _InteractiveTrendCard extends StatefulWidget {
  final String title;
  final String subtitle;
  final List<String> labels;
  final List<double> primaryValues;
  final List<double>? secondaryValues;
  final String primaryLabel;
  final String? secondaryLabel;
  final bool primaryIsCurrency;
  final Color primaryColor;
  final Color? secondaryColor;
  final Color fillColor;
  final int initialSelectedIndex;
  final VoidCallback? onOpenDetails;

  const _InteractiveTrendCard({
    required this.title,
    required this.subtitle,
    required this.labels,
    required this.primaryValues,
    this.secondaryValues,
    required this.primaryLabel,
    this.secondaryLabel,
    this.primaryIsCurrency = true,
    required this.primaryColor,
    this.secondaryColor,
    required this.fillColor,
    this.initialSelectedIndex = 0,
    this.onOpenDetails,
  });

  @override
  State<_InteractiveTrendCard> createState() => _InteractiveTrendCardState();
}

class _InteractiveTrendCardState extends State<_InteractiveTrendCard> {
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _selectedIndex = _clampedInitialIndex();
  }

  @override
  void didUpdateWidget(covariant _InteractiveTrendCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final maxIndex = widget.primaryValues.length - 1;
    if (maxIndex < 0) {
      _selectedIndex = 0;
    } else if (_selectedIndex > maxIndex) {
      _selectedIndex = maxIndex;
    }
    if (oldWidget.initialSelectedIndex != widget.initialSelectedIndex ||
        oldWidget.primaryValues.length != widget.primaryValues.length) {
      _selectedIndex = _clampedInitialIndex();
    }
  }

  int _clampedInitialIndex() {
    final maxIndex = widget.primaryValues.length - 1;
    if (maxIndex < 0) return 0;
    return widget.initialSelectedIndex.clamp(0, maxIndex);
  }

  void _selectFromDx(double dx, double width) {
    final count = widget.primaryValues.length;
    if (count <= 0 || width <= 0) return;
    final raw = (dx / width) * (count - 1);
    final next = raw.round().clamp(0, count - 1);
    if (next == _selectedIndex) return;
    setState(() => _selectedIndex = next);
  }

  String _formatValue(double value, bool isCurrency) {
    if (isCurrency) return 'Rs ${fmt0(value)}';
    return '${fmt0(value)} bags';
  }

  @override
  Widget build(BuildContext context) {
    final hasSecondary = widget.secondaryValues != null &&
        widget.secondaryValues!.isNotEmpty &&
        widget.secondaryColor != null &&
        widget.secondaryLabel != null;
    final selectedLabel = widget.labels.isEmpty
        ? '-'
        : widget.labels[_selectedIndex.clamp(0, widget.labels.length - 1)];
    final selectedPrimary = widget.primaryValues.isEmpty
        ? 0.0
        : widget.primaryValues[
            _selectedIndex.clamp(0, widget.primaryValues.length - 1)];
    final selectedSecondary = hasSecondary
        ? widget.secondaryValues![
            _selectedIndex.clamp(0, widget.secondaryValues!.length - 1)]
        : null;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 1),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(28),
        boxShadow: const [
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 20,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF1C2140),
                  ),
                ),
              ),
              AppStatusPill(
                text: selectedLabel,
                color: widget.primaryColor,
              ),
              if (widget.onOpenDetails != null) ...[
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Open details',
                  onPressed: widget.onOpenDetails,
                  icon: Icon(
                    Icons.open_in_new_rounded,
                    color: widget.primaryColor,
                    size: 20,
                  ),
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                  padding: EdgeInsets.zero,
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Text(
            widget.subtitle,
            style: const TextStyle(color: Color(0xFF757B9B)),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              _ValueBadge(
                color: widget.primaryColor,
                label: widget.primaryLabel,
                value: _formatValue(
                  selectedPrimary,
                  widget.primaryIsCurrency,
                ),
              ),
              if (hasSecondary)
                _ValueBadge(
                  color: widget.secondaryColor!,
                  label: widget.secondaryLabel!,
                  value: _formatValue(selectedSecondary ?? 0, true),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (details) => _selectFromDx(
                      details.localPosition.dx, constraints.maxWidth),
                  onHorizontalDragUpdate: (details) => _selectFromDx(
                    details.localPosition.dx,
                    constraints.maxWidth,
                  ),
                  child: _InteractiveLineChart(
                    labels: widget.labels,
                    primaryValues: widget.primaryValues,
                    secondaryValues: null,
                    primaryColor: widget.primaryColor,
                    secondaryColor: widget.secondaryColor,
                    fillColor: widget.fillColor,
                    selectedIndex: _selectedIndex,
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 16,
            runSpacing: 8,
            children: [
              _LegendDot(
                  color: widget.primaryColor, label: widget.primaryLabel),
              if (hasSecondary)
                _LegendDot(
                  color: widget.secondaryColor!,
                  label: widget.secondaryLabel!,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ValueBadge extends StatelessWidget {
  final Color color;
  final String label;
  final String value;

  const _ValueBadge({
    required this.color,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .10),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            value,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF69708D),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _InteractiveLineChart extends StatelessWidget {
  final List<String> labels;
  final List<double> primaryValues;
  final List<double>? secondaryValues;
  final Color primaryColor;
  final Color? secondaryColor;
  final Color fillColor;
  final int selectedIndex;

  const _InteractiveLineChart({
    required this.labels,
    required this.primaryValues,
    this.secondaryValues,
    required this.primaryColor,
    this.secondaryColor,
    required this.fillColor,
    required this.selectedIndex,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _InteractiveLineChartPainter(
        labels: labels,
        primaryValues: primaryValues,
        secondaryValues: secondaryValues,
        primaryColor: primaryColor,
        secondaryColor: secondaryColor,
        fillColor: fillColor,
        selectedIndex: selectedIndex,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _InteractiveLineChartPainter extends CustomPainter {
  final List<String> labels;
  final List<double> primaryValues;
  final List<double>? secondaryValues;
  final Color primaryColor;
  final Color? secondaryColor;
  final Color fillColor;
  final int selectedIndex;

  const _InteractiveLineChartPainter({
    required this.labels,
    required this.primaryValues,
    this.secondaryValues,
    required this.primaryColor,
    this.secondaryColor,
    required this.fillColor,
    required this.selectedIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const left = 8.0;
    const right = 8.0;
    const top = 10.0;
    const bottom = 26.0;
    final chartWidth = (size.width - left - right).clamp(1.0, double.infinity);
    final chartHeight =
        (size.height - top - bottom).clamp(1.0, double.infinity);
    final chartRect = Rect.fromLTWH(left, top, chartWidth, chartHeight);

    final gridPaint = Paint()
      ..color = const Color(0x11000000)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = chartRect.top + (chartRect.height * i / 4);
      canvas.drawLine(
        Offset(chartRect.left, y),
        Offset(chartRect.right, y),
        gridPaint,
      );
    }

    final allValues = <double>[
      ...primaryValues,
      ...?secondaryValues,
    ];
    final maxValue = allValues.isEmpty
        ? 1.0
        : allValues.reduce((a, b) => a > b ? a : b).clamp(1.0, double.infinity);

    Offset pointFor(List<double> values, int index) {
      final count = values.length;
      final x = count <= 1
          ? chartRect.center.dx
          : chartRect.left + (chartRect.width * index / (count - 1));
      final y = chartRect.bottom -
          ((values[index] / maxValue) * (chartRect.height - 6)) -
          3;
      return Offset(x, y);
    }

    void drawSeries(List<double> values, Color color, {Color? areaColor}) {
      if (values.isEmpty) return;
      final path = Path();
      final areaPath = Path();
      for (var i = 0; i < values.length; i++) {
        final point = pointFor(values, i);
        if (i == 0) {
          path.moveTo(point.dx, point.dy);
          areaPath.moveTo(point.dx, chartRect.bottom);
          areaPath.lineTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
          areaPath.lineTo(point.dx, point.dy);
        }
      }
      final lastPoint = pointFor(values, values.length - 1);
      areaPath.lineTo(lastPoint.dx, chartRect.bottom);
      areaPath.close();
      if (areaColor != null) {
        canvas.drawPath(areaPath, Paint()..color = areaColor);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..strokeWidth = 3
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    drawSeries(primaryValues, primaryColor, areaColor: fillColor);
    if (secondaryValues != null &&
        secondaryValues!.isNotEmpty &&
        secondaryColor != null) {
      drawSeries(secondaryValues!, secondaryColor!);
    }

    if (primaryValues.isNotEmpty) {
      final idx = selectedIndex.clamp(0, primaryValues.length - 1);
      final selected = pointFor(primaryValues, idx);
      final markerPaint = Paint()
        ..color = const Color(0x55272D45)
        ..strokeWidth = 1;
      canvas.drawLine(
        Offset(selected.dx, chartRect.top),
        Offset(selected.dx, chartRect.bottom),
        markerPaint,
      );
      canvas.drawCircle(selected, 6, Paint()..color = Colors.white);
      canvas.drawCircle(selected, 4, Paint()..color = primaryColor);
      if (secondaryValues != null &&
          secondaryValues!.isNotEmpty &&
          secondaryColor != null &&
          idx < secondaryValues!.length) {
        final secondary = pointFor(secondaryValues!, idx);
        canvas.drawCircle(secondary, 5, Paint()..color = Colors.white);
        canvas.drawCircle(secondary, 3.5, Paint()..color = secondaryColor!);
      }
    }

    final textPainter = TextPainter(
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    );
    final labelIndexes = <int>{};
    if (labels.isNotEmpty) {
      labelIndexes.add(0);
      labelIndexes.add(labels.length ~/ 2);
      labelIndexes.add(labels.length - 1);
    }
    for (final index in labelIndexes) {
      if (index < 0 || index >= labels.length) continue;
      final count = labels.length;
      final x = count <= 1
          ? chartRect.center.dx
          : chartRect.left + (chartRect.width * index / (count - 1));
      textPainter.text = TextSpan(
        text: labels[index],
        style: const TextStyle(
          color: Color(0xFF7A819B),
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(
          (x - textPainter.width / 2).clamp(0, size.width - textPainter.width),
          chartRect.bottom + 8,
        ),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _InteractiveLineChartPainter oldDelegate) {
    return oldDelegate.labels != labels ||
        oldDelegate.primaryValues != primaryValues ||
        oldDelegate.secondaryValues != secondaryValues ||
        oldDelegate.primaryColor != primaryColor ||
        oldDelegate.secondaryColor != secondaryColor ||
        oldDelegate.fillColor != fillColor ||
        oldDelegate.selectedIndex != selectedIndex;
  }
}

class _Sparkline extends StatelessWidget {
  final List<double> values;
  final Color color;
  final Color fillColor;

  const _Sparkline({
    required this.values,
    required this.color,
    required this.fillColor,
  });

  @override
  Widget build(BuildContext context) {
    return _MiniLineChart(
      primaryValues: values,
      primaryColor: color,
      fillColor: fillColor,
    );
  }
}

class _MiniLineChart extends StatelessWidget {
  final List<double> primaryValues;
  final Color primaryColor;
  final Color? fillColor;

  const _MiniLineChart({
    required this.primaryValues,
    required this.primaryColor,
    this.fillColor,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 200.0;
        final height =
            constraints.maxHeight.isFinite ? constraints.maxHeight : 80.0;
        return CustomPaint(
          size: Size(width, height),
          painter: _MiniLineChartPainter(
            primaryValues: primaryValues,
            primaryColor: primaryColor,
            fillColor: fillColor,
          ),
        );
      },
    );
  }
}

class _MiniLineChartPainter extends CustomPainter {
  final List<double> primaryValues;
  final Color primaryColor;
  final Color? fillColor;

  const _MiniLineChartPainter({
    required this.primaryValues,
    required this.primaryColor,
    this.fillColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final maxValue = primaryValues.isEmpty
        ? 1.0
        : primaryValues
            .reduce((a, b) => a > b ? a : b)
            .clamp(1.0, double.infinity);

    void drawSeries(
      List<double> values,
      Color color, {
      Color? areaColor,
    }) {
      if (values.isEmpty) return;
      final path = Path();
      final areaPath = Path();
      for (var i = 0; i < values.length; i++) {
        final dx = values.length == 1
            ? size.width / 2
            : (size.width * i) / (values.length - 1);
        final dy =
            size.height - ((values[i] / maxValue) * (size.height - 8)) - 4;
        if (i == 0) {
          path.moveTo(dx, dy);
          areaPath.moveTo(dx, size.height);
          areaPath.lineTo(dx, dy);
        } else {
          path.lineTo(dx, dy);
          areaPath.lineTo(dx, dy);
        }
      }
      final lastDx = values.length == 1 ? size.width / 2 : size.width;
      areaPath.lineTo(lastDx, size.height);
      areaPath.close();

      if (areaColor != null) {
        canvas.drawPath(
          areaPath,
          Paint()..color = areaColor,
        );
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..strokeWidth = 3
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    drawSeries(primaryValues, primaryColor, areaColor: fillColor);
  }

  @override
  bool shouldRepaint(covariant _MiniLineChartPainter oldDelegate) {
    return oldDelegate.primaryValues != primaryValues ||
        oldDelegate.primaryColor != primaryColor ||
        oldDelegate.fillColor != fillColor;
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendDot({
    required this.color,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF6D7392),
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class MobileInvoicesTab extends StatefulWidget {
  final AppUser user;

  const MobileInvoicesTab({super.key, required this.user});

  @override
  State<MobileInvoicesTab> createState() => _MobileInvoicesTabState();
}

class _MobileInvoicesTabState extends State<MobileInvoicesTab> {
  bool _loading = true;
  List<Invoice> _invoices = const [];
  List<Invoice> _filtered = const [];
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
    AppBus.dataTick.addListener(_onDataTick);
    _searchCtrl.addListener(_applyFilter);
  }

  @override
  void dispose() {
    AppBus.dataTick.removeListener(_onDataTick);
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onDataTick() {
    if (!mounted) return;
    _load();
  }

  Future<void> _load() async {
    final invoices = await Store.loadAll();
    invoices.sort((a, b) {
      try {
        return parseInvoiceDate(b.date).compareTo(parseInvoiceDate(a.date));
      } catch (_) {
        return b.sNo.compareTo(a.sNo);
      }
    });
    if (!mounted) return;
    setState(() {
      _invoices = invoices;
      _loading = false;
    });
    _applyFilter();
  }

  Future<void> _syncFromLaptop() async {
    try {
      final result = await _pullLaptopData(widget.user);
      if (!mounted) return;
      showOk(context, _pullSuccessMessage(result));
    } on ServerSyncException catch (e) {
      if (!mounted) return;
      showErr(context, e.message);
    } finally {
      await _load();
    }
  }

  void _applyFilter() {
    final query = _searchCtrl.text.trim().toLowerCase();
    final next = query.isEmpty
        ? _invoices
        : _invoices.where((invoice) {
            return invoiceSummarySearchText(invoice).contains(query);
          }).toList();
    if (!mounted) return;
    setState(() => _filtered = next);
  }

  Widget _invoiceCard(BuildContext context, Invoice invoice) {
    return InvoiceSummaryCard(
      invoice: invoice,
      showContactLine: true,
      showTotalPill: true,
      maxTitleLines: 2,
      backgroundColor: Colors.white,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MobileInvoiceDetailScreen(
            invoice: invoice,
            user: widget.user,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const AppSkeletonLoader();
    }
    if (_invoices.isEmpty) {
      return RefreshIndicator(
        onRefresh: _syncFromLaptop,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 220),
            Center(child: Text('No invoices in local mobile copy.')),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _syncFromLaptop,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _filtered.length + 1,
        itemBuilder: (_, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextField(
                controller: _searchCtrl,
                decoration: const InputDecoration(
                  hintText: 'Search invoices by name, ID, date, or address',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
            );
          }
          final invoice = _filtered[index - 1];
          return _invoiceCard(context, invoice);
        },
      ),
    );
  }
}

class MobileCustomersTab extends StatefulWidget {
  final AppUser user;

  const MobileCustomersTab({super.key, required this.user});

  @override
  State<MobileCustomersTab> createState() => _MobileCustomersTabState();
}

class _CustomerMetrics {
  double sales = 0;
  double paid = 0;
  DateTime latestDate = DateTime.fromMillisecondsSinceEpoch(0);

  double get remaining => (sales - paid).clamp(0, double.infinity).toDouble();
}

class _MobileCustomersTabState extends State<MobileCustomersTab> {
  bool _loading = true;
  List<Customer> _customers = const [];
  List<Customer> _filtered = const [];
  Map<String, _CustomerMetrics> _customerMetrics = const {};
  SortMode _sortCustomers = SortMode.mostSales;
  final TextEditingController _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
    AppBus.dataTick.addListener(_onDataTick);
    _searchCtrl.addListener(_applyFilter);
  }

  @override
  void dispose() {
    AppBus.dataTick.removeListener(_onDataTick);
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onDataTick() {
    if (!mounted) return;
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      CustomerStore.loadAll(),
      Store.loadAll(),
      PaymentStore.loadAll(),
    ]);
    final customers = results[0] as List<Customer>;
    final invoices = results[1] as List<Invoice>;
    final payments = results[2] as List<PaymentEntry>;
    final metrics = _buildCustomerMetrics(invoices, payments);
    customers.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    if (!mounted) return;
    setState(() {
      _customers = customers;
      _customerMetrics = metrics;
      _loading = false;
    });
    _applyFilter();
  }

  Future<void> _syncFromLaptop() async {
    try {
      final result = await _pullLaptopData(widget.user);
      if (!mounted) return;
      showOk(context, _pullSuccessMessage(result));
    } on ServerSyncException catch (e) {
      if (!mounted) return;
      showErr(context, e.message);
    } finally {
      await _load();
    }
  }

  String _keyOf(Customer customer) =>
      (customer.id.isNotEmpty ? customer.id : customer.name).trim();

  String _invoiceKey(Invoice invoice) =>
      (invoice.customerId.isNotEmpty ? invoice.customerId : invoice.customer)
          .trim()
          .toLowerCase();

  String _paymentKey(PaymentEntry payment) =>
      (payment.customerId.isNotEmpty ? payment.customerId : payment.customer)
          .trim()
          .toLowerCase();

  Map<String, _CustomerMetrics> _buildCustomerMetrics(
    List<Invoice> invoices,
    List<PaymentEntry> payments,
  ) {
    final metrics = <String, _CustomerMetrics>{};
    for (final invoice in invoices) {
      final key = _invoiceKey(invoice);
      final metric = metrics.putIfAbsent(key, () => _CustomerMetrics());
      metric.sales += invoice.balance;
      try {
        final date = parseInvoiceDate(invoice.date);
        if (date.isAfter(metric.latestDate)) {
          metric.latestDate = date;
        }
      } catch (_) {}
    }
    for (final payment in payments) {
      final key = _paymentKey(payment);
      final metric = metrics.putIfAbsent(key, () => _CustomerMetrics());
      metric.paid += payment.effectiveAmount;
    }
    return metrics;
  }

  _CustomerMetrics _metricsFor(Customer customer) {
    return _customerMetrics[_keyOf(customer).toLowerCase()] ??
        _CustomerMetrics();
  }

  double _salesFor(Customer customer) {
    return _metricsFor(customer).sales;
  }

  double _paidFor(Customer customer) {
    return _metricsFor(customer).paid;
  }

  double _remainingFor(Customer customer) {
    return _metricsFor(customer).remaining;
  }

  DateTime _latestDateFor(Customer customer) {
    return _metricsFor(customer).latestDate;
  }

  String _sortLabel(SortMode mode) {
    switch (mode) {
      case SortMode.mostUnpaid:
        return 'Most Unpaid';
      case SortMode.mostPaid:
        return 'Most Paid';
      case SortMode.mostSales:
        return 'Most Sales';
      case SortMode.leastSales:
        return 'Least Sales';
      case SortMode.newestFirst:
        return 'Newest First';
      case SortMode.oldestFirst:
        return 'Oldest First';
    }
  }

  void _applyFilter() {
    final query = _searchCtrl.text.trim().toLowerCase();
    final next = query.isEmpty
        ? _customers
        : _customers.where((customer) {
            return customerSummarySearchText(customer).contains(query);
          }).toList();
    int cmpNumDesc(num a, num b) => b.compareTo(a);
    int cmpNumAsc(num a, num b) => a.compareTo(b);
    switch (_sortCustomers) {
      case SortMode.mostUnpaid:
        next.sort(
          (a, b) => cmpNumDesc(_remainingFor(a), _remainingFor(b)),
        );
        break;
      case SortMode.mostPaid:
        next.sort((a, b) => cmpNumDesc(_paidFor(a), _paidFor(b)));
        break;
      case SortMode.mostSales:
        next.sort((a, b) => cmpNumDesc(_salesFor(a), _salesFor(b)));
        break;
      case SortMode.leastSales:
        next.sort((a, b) => cmpNumAsc(_salesFor(a), _salesFor(b)));
        break;
      case SortMode.newestFirst:
        next.sort((a, b) => _latestDateFor(b).compareTo(_latestDateFor(a)));
        break;
      case SortMode.oldestFirst:
        next.sort((a, b) => _latestDateFor(a).compareTo(_latestDateFor(b)));
        break;
    }
    if (!mounted) return;
    setState(() => _filtered = next);
  }

  Widget _customerCard(BuildContext context, Customer customer) {
    final metrics = _metricsFor(customer);
    return CustomerSummaryCard(
      customer: customer,
      sortLabel: _sortLabel(_sortCustomers),
      total: metrics.sales,
      paid: metrics.paid,
      remaining: metrics.remaining,
      showRemainingPill: true,
      maxTitleLines: 2,
      backgroundColor: Colors.white,
      margin: const EdgeInsets.only(bottom: 10),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => MobileCustomerDetailScreen(
            customer: customer,
            user: widget.user,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const AppSkeletonLoader();
    }
    if (_customers.isEmpty) {
      return RefreshIndicator(
        onRefresh: _syncFromLaptop,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 220),
            Center(child: Text('No customers in local mobile copy.')),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _syncFromLaptop,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: _filtered.length + 1,
        itemBuilder: (_, index) {
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _searchCtrl,
                    decoration: const InputDecoration(
                      hintText: 'Search customers by name, ID, or phone',
                      prefixIcon: Icon(Icons.search),
                    ),
                  ),
                  const SizedBox(height: 10),
                  InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Sort',
                      prefixIcon: Icon(Icons.sort),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<SortMode>(
                        value: _sortCustomers,
                        isExpanded: true,
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() => _sortCustomers = value);
                          _applyFilter();
                        },
                        items: const [
                          DropdownMenuItem(
                            value: SortMode.mostUnpaid,
                            child: Text('Most Unpaid'),
                          ),
                          DropdownMenuItem(
                            value: SortMode.mostPaid,
                            child: Text('Most Paid'),
                          ),
                          DropdownMenuItem(
                            value: SortMode.mostSales,
                            child: Text('Most Sales'),
                          ),
                          DropdownMenuItem(
                            value: SortMode.leastSales,
                            child: Text('Least Sales'),
                          ),
                          DropdownMenuItem(
                            value: SortMode.newestFirst,
                            child: Text('Newest First'),
                          ),
                          DropdownMenuItem(
                            value: SortMode.oldestFirst,
                            child: Text('Oldest First'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          }
          final customer = _filtered[index - 1];
          return _customerCard(context, customer);
        },
      ),
    );
  }
}

class MobileOrdersTab extends StatefulWidget {
  final AppUser user;

  const MobileOrdersTab({super.key, required this.user});

  @override
  State<MobileOrdersTab> createState() => _MobileOrdersTabState();
}

class _SurjaniTruckColumn {
  String? _id;
  final TextEditingController numberCtrl;
  final TextEditingController qtyCtrl;
  final Map<String, TextEditingController> typeQtyCtrls;

  _SurjaniTruckColumn({
    required String number,
    required int qty,
    String? id,
    Map<String, int> typeBags = const {},
  })  : _id = id,
        numberCtrl = TextEditingController(text: number),
        qtyCtrl = TextEditingController(text: '$qty'),
        typeQtyCtrls = {
          for (final type in kItemTypes)
            type: TextEditingController(
              text: (typeBags[type] ?? 0) <= 0 ? '' : '${typeBags[type]}',
            ),
        };

  String get id {
    final current = _id?.trim();
    if (current != null && current.isNotEmpty) return current;
    final generated =
        'truck-${DateTime.now().microsecondsSinceEpoch}-${identityHashCode(this)}';
    _id = generated;
    return generated;
  }

  int get capacity {
    final parsed = int.tryParse(qtyCtrl.text.trim()) ?? 0;
    return parsed <= 0 ? 250 : parsed;
  }

  Map<String, int> get typeBags {
    final values = <String, int>{};
    for (final entry in typeQtyCtrls.entries) {
      final qty = int.tryParse(entry.value.text.trim()) ?? 0;
      if (qty > 0) values[entry.key] = qty;
    }
    return values;
  }

  int get allottedTypeBags =>
      typeBags.values.fold<int>(0, (sum, qty) => sum + qty);

  String get typeSummary {
    final values = typeBags.entries
        .map((entry) => '${entry.key} ${entry.value}')
        .join(', ');
    return values.isEmpty ? 'No type split' : values;
  }

  void dispose() {
    numberCtrl.dispose();
    qtyCtrl.dispose();
    for (final controller in typeQtyCtrls.values) {
      controller.dispose();
    }
  }

  MobileTruck toMobileTruck({String orderDate = ''}) {
    return MobileTruck(
      id: id,
      number: numberCtrl.text.trim(),
      capacity: capacity,
      orderDate: orderDate,
      typeBags: typeBags,
    );
  }
}

class _TruckBalanceStockLine {
  final String category;
  final String sku;
  final int qty;

  const _TruckBalanceStockLine({
    required this.category,
    required this.sku,
    required this.qty,
  });

  Map<String, dynamic> toJson() => {
        'category': category,
        'sku': sku,
        'qty': qty,
      };
}

class _TruckBalanceBrandRow {
  final String category;
  final TextEditingController brandCtrl;
  final TextEditingController qtyCtrl;

  _TruckBalanceBrandRow({
    required this.category,
    String brand = '',
    String qty = '',
  })  : brandCtrl = TextEditingController(text: brand),
        qtyCtrl = TextEditingController(text: qty);

  void dispose() {
    brandCtrl.dispose();
    qtyCtrl.dispose();
  }
}

class _TruckGodownBalanceEntry {
  final String category;
  final String sku;
  final double qty;

  const _TruckGodownBalanceEntry({
    required this.category,
    required this.sku,
    required this.qty,
  });
}

class _MobileOrdersTabState extends State<MobileOrdersTab> {
  bool _loading = true;
  bool _syncing = false;
  late String _selectedOrderDate;
  final _selectedOrderDateCtrl = TextEditingController();
  final _newSurjaniTruckNoCtrl = TextEditingController(text: 'JW-2535');
  final _newSurjaniTruckQtyCtrl = TextEditingController(text: '250');
  final _newFactoryTruckNoCtrl = TextEditingController(text: 'Factory-1');
  final _newFactoryTruckQtyCtrl = TextEditingController(text: '250');
  final List<_SurjaniTruckColumn> _surjaniTrucks = [];
  final List<_SurjaniTruckColumn> _factoryTrucks = [];
  bool _surjaniTrucksLoaded = false;
  bool _factoryTrucksLoaded = false;
  bool _initialTruckSyncDone = false;
  bool _initialFactoryTruckSyncDone = false;
  int _activeOrderDrags = 0;
  List<MobileOrder> _orders = const [];
  List<Invoice> _returnInvoices = const [];
  List<GodownStockInEntry> _godownStockIns = const [];

  bool _compactOrders(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return size.height <= 760 || size.width <= 390;
  }

  @override
  void initState() {
    super.initState();
    _setSelectedOrderDate(DateTime.now().toIso8601String().split('T').first);
    _load();
    AppBus.dataTick.addListener(_onDataTick);
  }

  @override
  void dispose() {
    AppBus.dataTick.removeListener(_onDataTick);
    _selectedOrderDateCtrl.dispose();
    _newSurjaniTruckNoCtrl.dispose();
    _newSurjaniTruckQtyCtrl.dispose();
    _newFactoryTruckNoCtrl.dispose();
    _newFactoryTruckQtyCtrl.dispose();
    for (final truck in _surjaniTrucks) {
      truck.dispose();
    }
    for (final truck in _factoryTrucks) {
      truck.dispose();
    }
    super.dispose();
  }

  void _onDataTick() {
    if (!mounted) return;
    if (_mobileOrderSyncPaused()) return;
    _load();
  }

  void _beginOrderDrag() {
    _activeOrderDrags++;
    _mobileOrderDragActive.value = true;
  }

  void _endOrderDrag() {
    if (_activeOrderDrags > 0) {
      _activeOrderDrags--;
    }
    _pauseMobileOrderSync();
    if (_activeOrderDrags == 0) {
      Future<void>.delayed(const Duration(milliseconds: 350), () {
        if (_activeOrderDrags == 0) {
          _mobileOrderDragActive.value = false;
        }
      });
    }
  }

  void _setSelectedOrderDate(String date) {
    _selectedOrderDate = date;
    _selectedOrderDateCtrl.text = date;
  }

  Future<void> _changeSelectedOrderDate(String date) async {
    setState(() => _setSelectedOrderDate(date));
    await _refreshSurjaniTrucksFromStore();
  }

  List<MobileTruck> _trucksForSelectedDate(List<MobileTruck> trucks) {
    return trucks
        .where((truck) => truck.orderDate == _selectedOrderDate)
        .toList();
  }

  Future<void> _load() async {
    final results = await Future.wait<dynamic>([
      MobileAccessStore.loadOrders(),
      MobileAccessStore.loadSurjaniTrucks(),
      MobileAccessStore.loadFactoryTrucks(),
      Store.loadAll(),
    ]);
    final orders = results[0] as List<MobileOrder>;
    final allTrucks = results[1] as List<MobileTruck>;
    final allFactoryTrucks = results[2] as List<MobileTruck>;
    final invoices = results[3] as List<Invoice>;
    final trucks = _trucksForSelectedDate(allTrucks);
    final factoryTrucks = _trucksForSelectedDate(allFactoryTrucks);
    if (!mounted) return;
    setState(() {
      _orders = orders;
      _returnInvoices = invoices.where((invoice) => invoice.isReturn).toList()
        ..sort((a, b) => b.sNo.compareTo(a.sNo));
      _replaceSurjaniTrucksIfChanged(trucks);
      _replaceFactoryTrucksIfChanged(factoryTrucks);
      _loading = false;
    });
    unawaited(_loadGodownStockIns());
    if (!_initialTruckSyncDone && allTrucks.isNotEmpty) {
      _initialTruckSyncDone = true;
      unawaited(_pushSurjaniTrucks(allTrucks, showErrors: false));
    }
    if (!_initialFactoryTruckSyncDone && allFactoryTrucks.isNotEmpty) {
      _initialFactoryTruckSyncDone = true;
      unawaited(_pushFactoryTrucks(allFactoryTrucks, showErrors: false));
    }
  }

  Future<void> _loadGodownStockIns() async {
    final godownConfig = await GodownStockStore.loadConfig();
    if (!mounted) return;
    setState(() => _godownStockIns = godownConfig.stockIns);
  }

  void _replaceSurjaniTrucksIfChanged(List<MobileTruck> trucks) {
    if (_surjaniTrucksLoaded && _sameTruckList(_surjaniTrucks, trucks)) {
      return;
    }
    for (final truck in _surjaniTrucks) {
      truck.dispose();
    }
    _surjaniTrucks
      ..clear()
      ..addAll(
        trucks.map(
          (truck) => _SurjaniTruckColumn(
            id: truck.id,
            number: truck.number,
            qty: truck.capacity,
            typeBags: truck.typeBags,
          ),
        ),
      );
    _surjaniTrucksLoaded = true;
  }

  void _replaceFactoryTrucksIfChanged(List<MobileTruck> trucks) {
    if (_factoryTrucksLoaded && _sameTruckList(_factoryTrucks, trucks)) {
      return;
    }
    for (final truck in _factoryTrucks) {
      truck.dispose();
    }
    _factoryTrucks
      ..clear()
      ..addAll(
        trucks.map(
          (truck) => _SurjaniTruckColumn(
            id: truck.id,
            number: truck.number,
            qty: truck.capacity,
            typeBags: truck.typeBags,
          ),
        ),
      );
    _factoryTrucksLoaded = true;
  }

  bool _sameTruckList(
    List<_SurjaniTruckColumn> current,
    List<MobileTruck> incoming,
  ) {
    if (current.length != incoming.length) return false;
    for (var i = 0; i < current.length; i++) {
      final a = current[i];
      final b = incoming[i];
      if (a.id != b.id ||
          a.numberCtrl.text.trim() != b.number.trim() ||
          a.capacity != b.capacity ||
          b.orderDate != _selectedOrderDate ||
          !_sameTypeBags(a.typeBags, b.typeBags)) {
        return false;
      }
    }
    return true;
  }

  bool _sameTypeBags(Map<String, int> a, Map<String, int> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  Map<String, int> _truckBalanceByType(
    _SurjaniTruckColumn truck,
    List<MobileOrder> allocations,
  ) {
    final balances = Map<String, int>.from(truck.typeBags);
    for (final order in allocations) {
      if (order.status == MobileOrderStatus.cancelled) continue;
      final type = order.bagsType.trim();
      if (!balances.containsKey(type)) continue;
      balances[type] = (balances[type] ?? 0) - order.bagsQuantity;
    }
    balances.removeWhere((_, qty) => qty <= 0);
    return balances;
  }

  String _stockTruckKey(String truckId) {
    return truckId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-').toLowerCase();
  }

  bool _isSelectedOrderDay(String value) {
    try {
      final entryDate = parseInvoiceDate(value);
      final selectedDate = parseInvoiceDate(_selectedOrderDate);
      return entryDate.year == selectedDate.year &&
          entryDate.month == selectedDate.month &&
          entryDate.day == selectedDate.day;
    } catch (_) {
      return value == _selectedOrderDate;
    }
  }

  List<_TruckGodownBalanceEntry> _godownBalanceEntriesForTruck(
    _SurjaniTruckColumn truck,
  ) {
    final truckKey = _stockTruckKey(truck.id);
    final byLine = <String, _TruckGodownBalanceEntry>{};
    for (final entry in _godownStockIns) {
      if (!_isSelectedOrderDay(entry.date)) continue;
      final id = entry.id.toLowerCase();
      if (!id.startsWith('gbal-') || !id.contains('-$truckKey-')) continue;
      final key = '${entry.category.trim()}|${entry.sku.trim()}';
      final current = byLine[key];
      byLine[key] = _TruckGodownBalanceEntry(
        category: entry.category.trim(),
        sku: entry.sku.trim(),
        qty: (current?.qty ?? 0) + entry.qty,
      );
    }
    final values = byLine.values.where((entry) => entry.qty > 0).toList();
    values.sort((a, b) {
      final c = a.category.toLowerCase().compareTo(b.category.toLowerCase());
      if (c != 0) return c;
      return a.sku.toLowerCase().compareTo(b.sku.toLowerCase());
    });
    return values;
  }

  Future<void> _moveTruckBalanceToGodown({
    required String sourceSite,
    required _SurjaniTruckColumn truck,
    required List<MobileOrder> allocations,
  }) async {
    final balanceByType = _truckBalanceByType(truck, allocations);
    if (balanceByType.isEmpty) {
      showErr(context, 'No typed balance bags to move.');
      return;
    }
    final stockLines = await _showTruckBalanceBrandDialog(balanceByType);
    if (stockLines == null || stockLines.isEmpty) return;
    if (!mounted) return;
    try {
      final config = await MobileAccessStore.loadServerConfig();
      await ServerSyncClient.moveTruckBalanceToGodown(
        baseUrl: config.baseUrl,
        username: widget.user.username,
        passcode: widget.user.passcode,
        sourceSite: sourceSite,
        sourceTruckId: truck.id,
        truckNo: truck.numberCtrl.text.trim(),
        date: _selectedOrderDate,
        typeBags: balanceByType,
        stockLines: stockLines.map((line) => line.toJson()).toList(),
      );
      final godownConfig = await GodownStockStore.loadConfig();
      if (!mounted) return;
      setState(() => _godownStockIns = godownConfig.stockIns);
      showOk(context, 'Moved balance to Godown.');
    } on ServerSyncException catch (e) {
      if (!mounted) return;
      showErr(context, e.message);
    }
  }

  Future<List<_TruckBalanceStockLine>?> _showTruckBalanceBrandDialog(
    Map<String, int> balanceByType,
  ) async {
    final rows = <_TruckBalanceBrandRow>[
      for (final entry in balanceByType.entries)
        _TruckBalanceBrandRow(
          category: entry.key,
          qty: '${entry.value}',
        ),
    ];
    String? error;
    final lines = await showDialog<List<_TruckBalanceStockLine>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          int totalFor(String category) {
            return rows.where((row) => row.category == category).fold<int>(
                  0,
                  (sum, row) =>
                      sum + (int.tryParse(row.qtyCtrl.text.trim()) ?? 0),
                );
          }

          return AlertDialog(
            title: const Text('Move balance to Godown'),
            content: SizedBox(
              width: 360,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final entry in balanceByType.entries) ...[
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '${entry.key} remaining ${entry.value}',
                              style:
                                  const TextStyle(fontWeight: FontWeight.w800),
                            ),
                          ),
                          Text(
                            '${totalFor(entry.key)} / ${entry.value}',
                            style: TextStyle(
                              color: totalFor(entry.key) == entry.value
                                  ? const Color(0xFF17A673)
                                  : const Color(0xFFE15241),
                              fontWeight: FontWeight.w800,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      for (final row
                          in rows.where((row) => row.category == entry.key))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: row.brandCtrl,
                                  decoration: const InputDecoration(
                                    labelText: 'Brand',
                                    isDense: true,
                                  ),
                                  onChanged: (_) =>
                                      setDialogState(() => error = null),
                                ),
                              ),
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 78,
                                child: TextField(
                                  controller: row.qtyCtrl,
                                  keyboardType: TextInputType.number,
                                  decoration: const InputDecoration(
                                    labelText: 'Qty',
                                    isDense: true,
                                  ),
                                  onChanged: (_) =>
                                      setDialogState(() => error = null),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Remove brand',
                                visualDensity: const VisualDensity(
                                  horizontal: -4,
                                  vertical: -4,
                                ),
                                onPressed: rows
                                            .where((item) =>
                                                item.category == entry.key)
                                            .length <=
                                        1
                                    ? null
                                    : () {
                                        setDialogState(() {
                                          rows.remove(row);
                                          error = null;
                                        });
                                        unawaited(
                                          Future<void>.delayed(
                                            const Duration(milliseconds: 400),
                                            row.dispose,
                                          ),
                                        );
                                      },
                                icon: const Icon(Icons.close, size: 18),
                              ),
                            ],
                          ),
                        ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          onPressed: () {
                            setDialogState(() {
                              rows.add(
                                _TruckBalanceBrandRow(category: entry.key),
                              );
                              error = null;
                            });
                          },
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Brand'),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (error != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          error!,
                          style: const TextStyle(color: Color(0xFFE15241)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final parsed = <_TruckBalanceStockLine>[];
                  for (final entry in balanceByType.entries) {
                    final typeRows =
                        rows.where((row) => row.category == entry.key);
                    var total = 0;
                    for (final row in typeRows) {
                      final brand = row.brandCtrl.text.trim();
                      final qty = int.tryParse(row.qtyCtrl.text.trim()) ?? 0;
                      if (brand.isEmpty || qty <= 0) {
                        setDialogState(() =>
                            error = 'Enter brand and qty for ${entry.key}.');
                        return;
                      }
                      total += qty;
                      parsed.add(_TruckBalanceStockLine(
                        category: entry.key,
                        sku: brand,
                        qty: qty,
                      ));
                    }
                    if (total != entry.value) {
                      setDialogState(() => error =
                          '${entry.key} brand qty must total ${entry.value}.');
                      return;
                    }
                  }
                  Navigator.of(dialogContext).pop(parsed);
                },
                child: const Text('Move'),
              ),
            ],
          );
        },
      ),
    );
    final disposableRows = rows.toList();
    unawaited(Future<void>.delayed(const Duration(milliseconds: 400), () {
      for (final row in disposableRows) {
        row.dispose();
      }
    }));
    return lines;
  }

  Future<void> _saveSurjaniTrucks({bool syncToServer = true}) async {
    _pauseMobileOrderSync();
    final trucks = _surjaniTrucks
        .map((truck) => truck.toMobileTruck(orderDate: _selectedOrderDate))
        .toList();
    await MobileAccessStore.saveSurjaniTrucksForDate(
      _selectedOrderDate,
      trucks,
    );
    if (syncToServer) {
      unawaited(_pushSurjaniTrucks(trucks));
    }
  }

  Future<void> _saveFactoryTrucks({bool syncToServer = true}) async {
    _pauseMobileOrderSync();
    final trucks = _factoryTrucks
        .map((truck) => truck.toMobileTruck(orderDate: _selectedOrderDate))
        .toList();
    await MobileAccessStore.saveFactoryTrucksForDate(
      _selectedOrderDate,
      trucks,
    );
    if (syncToServer) {
      unawaited(_pushFactoryTrucks(trucks));
    }
  }

  Future<void> _pushSurjaniTrucks(
    List<MobileTruck> trucks, {
    bool showErrors = true,
  }) async {
    try {
      final config = await MobileAccessStore.loadServerConfig();
      if (config.baseUrl.trim().isEmpty) return;
      final saved = await ServerSyncClient.saveSurjaniTrucks(
        baseUrl: config.baseUrl,
        username: widget.user.username,
        passcode: widget.user.passcode,
        trucks: trucks,
      );
      if (!mounted) return;
      if (_mobileOrderSyncPaused()) return;
      setState(() => _replaceSurjaniTrucksIfChanged(
            _trucksForSelectedDate(saved),
          ));
    } on ServerSyncException catch (e) {
      if (!mounted || !showErrors) return;
      showErr(context, e.message);
    }
  }

  Future<void> _deleteSurjaniTruckOnServer(String truckId) async {
    try {
      final config = await MobileAccessStore.loadServerConfig();
      if (config.baseUrl.trim().isEmpty) return;
      final saved = await ServerSyncClient.deleteSurjaniTruck(
        baseUrl: config.baseUrl,
        username: widget.user.username,
        passcode: widget.user.passcode,
        truckId: truckId,
      );
      if (!mounted) return;
      setState(() => _replaceSurjaniTrucksIfChanged(
            _trucksForSelectedDate(saved),
          ));
    } on ServerSyncException catch (e) {
      if (!mounted) return;
      showErr(context, e.message);
    }
  }

  Future<void> _pushFactoryTrucks(
    List<MobileTruck> trucks, {
    bool showErrors = true,
  }) async {
    try {
      final config = await MobileAccessStore.loadServerConfig();
      if (config.baseUrl.trim().isEmpty) return;
      final saved = await ServerSyncClient.saveFactoryTrucks(
        baseUrl: config.baseUrl,
        username: widget.user.username,
        passcode: widget.user.passcode,
        trucks: trucks,
      );
      if (!mounted) return;
      if (_mobileOrderSyncPaused()) return;
      setState(() => _replaceFactoryTrucksIfChanged(
            _trucksForSelectedDate(saved),
          ));
    } on ServerSyncException catch (e) {
      if (!mounted || !showErrors) return;
      showErr(context, e.message);
    }
  }

  Future<void> _deleteFactoryTruckOnServer(String truckId) async {
    try {
      final config = await MobileAccessStore.loadServerConfig();
      if (config.baseUrl.trim().isEmpty) return;
      final saved = await ServerSyncClient.deleteFactoryTruck(
        baseUrl: config.baseUrl,
        username: widget.user.username,
        passcode: widget.user.passcode,
        truckId: truckId,
      );
      if (!mounted) return;
      setState(() => _replaceFactoryTrucksIfChanged(
            _trucksForSelectedDate(saved),
          ));
    } on ServerSyncException catch (e) {
      if (!mounted) return;
      showErr(context, e.message);
    }
  }

  Future<void> _refreshSurjaniTrucksFromStore() async {
    final results = await Future.wait<dynamic>([
      MobileAccessStore.loadSurjaniTrucksForDate(_selectedOrderDate),
      MobileAccessStore.loadFactoryTrucksForDate(_selectedOrderDate),
    ]);
    final trucks = results[0] as List<MobileTruck>;
    final factoryTrucks = results[1] as List<MobileTruck>;
    if (!mounted) return;
    setState(() {
      _replaceSurjaniTrucksIfChanged(trucks);
      _replaceFactoryTrucksIfChanged(factoryTrucks);
    });
    unawaited(_loadGodownStockIns());
  }

  Future<void> _syncOrders() async {
    _pauseMobileOrderSync(const Duration(milliseconds: 700));
    setState(() => _syncing = true);
    try {
      final config = await MobileAccessStore.loadServerConfig();
      final orders = await ServerSyncClient.fetchOrders(
        baseUrl: config.baseUrl,
        username: widget.user.username,
        passcode: widget.user.passcode,
      );
      if (!mounted) return;
      setState(() => _orders = orders);
      await _refreshSurjaniTrucksFromStore();
      if (!mounted) return;
      showOk(context, 'Synced ${orders.length} orders.');
    } on ServerSyncException catch (e) {
      if (!mounted) return;
      showErr(context, e.message);
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _openOrderForm([MobileOrder? order]) async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => MobileOrderFormScreen(
          user: widget.user,
          order: order,
        ),
      ),
    );
    if (saved == true) {
      await _load();
    }
  }

  Future<void> _openWalkInSaleForm() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => MobileWalkInSaleScreen(
          user: widget.user,
          initialDate: _selectedOrderDate,
        ),
      ),
    );
    if (saved == true) {
      await _load();
    }
  }

  List<MobileOrder> _ordersForSite(String site) {
    return _orders
        .where((order) =>
            order.orderSite.trim().toLowerCase() == site.toLowerCase() &&
            order.orderDate == _selectedOrderDate)
        .toList();
  }

  List<Invoice> _returnsForSelectedDate() {
    final selected = DateTime.tryParse(_selectedOrderDate);
    if (selected == null) return const [];
    return _returnInvoices.where((invoice) {
      try {
        final date = parseInvoiceDate(invoice.date);
        return date.year == selected.year &&
            date.month == selected.month &&
            date.day == selected.day;
      } catch (_) {
        return false;
      }
    }).toList();
  }

  Widget _returnRow(Invoice invoice) {
    final compact = _compactOrders(context);
    const color = Color(0xFFC62828);
    final returnedBags = invoice.lines.fold<int>(
      0,
      (sum, line) => sum + (line.qty < 0 ? line.qty.abs() : 0),
    );
    final itemSummary = invoice.lines
        .where((line) => line.qty < 0)
        .map((line) =>
            '${line.qty.abs()} ${line.brand.trim().isEmpty ? line.typeLabel : line.brand.trim()}')
        .join(', ');
    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 4 : 6),
      child: AppPressable(
        onTap: () async {
          final deleted = await Navigator.of(context).push<bool>(
            MaterialPageRoute(
              builder: (_) => MobileInvoiceDetailScreen(
                invoice: invoice,
                user: widget.user,
              ),
            ),
          );
          if (deleted == true) await _load();
        },
        borderRadius: BorderRadius.circular(8),
        child: Material(
          color: const Color(0xFFFFEBEE),
          borderRadius: BorderRadius.circular(8),
          child: ListTile(
            dense: true,
            isThreeLine: !compact,
            minVerticalPadding: compact ? 4 : null,
            visualDensity: compact
                ? const VisualDensity(horizontal: -2, vertical: -3)
                : VisualDensity.compact,
            contentPadding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10),
            leading: const Icon(Icons.assignment_return, color: color),
            title: Text(
              'RETURN #${invoice.sNo} • Invoice #${invoice.returnOfInvoiceNo ?? '-'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w800,
                fontSize: compact ? 12 : null,
              ),
            ),
            subtitle: Text(
              [
                invoice.customer,
                if (itemSummary.isNotEmpty) itemSummary,
                'Returned to Godown',
              ].join(' - '),
              maxLines: compact ? 1 : 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: compact ? 11 : 12),
            ),
            trailing: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '$returnedBags bags',
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.w800,
                    fontSize: compact ? 11 : 12,
                  ),
                ),
                Text(
                  'Rs ${fmt0(invoice.balance.abs())}',
                  style: const TextStyle(
                    color: color,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            shape: RoundedRectangleBorder(
              side: const BorderSide(color: color, width: 1.2),
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      ),
    );
  }

  bool _siteUsesTruckPlanning(String site) {
    final value = site.trim().toLowerCase();
    return value == 'surjani' || value == 'factory';
  }

  Future<void> _pickSelectedOrderDate() async {
    final now = DateTime.now();
    final selected = DateTime.tryParse(_selectedOrderDate) ??
        DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: selected,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1),
    );
    if (picked == null) return;
    await _changeSelectedOrderDate(picked.toIso8601String().split('T').first);
  }

  Color _statusColor(MobileOrderStatus status) {
    switch (status) {
      case MobileOrderStatus.delivered:
        return const Color(0xFF17A673);
      case MobileOrderStatus.cancelled:
        return const Color(0xFFE15241);
      case MobileOrderStatus.pending:
        return const Color(0xFFE6A700);
    }
  }

  Color _statusBackgroundColor(MobileOrderStatus status) {
    return _statusColor(status).withValues(alpha: .12);
  }

  Widget? _orderSubtitle(MobileOrder order, {required bool compact}) {
    final customerName = order.customerName.trim();
    final brand = order.bagsBrand.trim();
    final note = order.note.trim();
    final recordedInvoiceNo = order.recordedInvoiceNo;
    final meta = [
      if (customerName.isNotEmpty) customerName,
      if (brand.isNotEmpty) brand,
      if (recordedInvoiceNo != null) 'Invoice #$recordedInvoiceNo',
    ].join(' - ');
    if (meta.isEmpty && note.isEmpty) {
      return null;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (meta.isNotEmpty)
          Text(
            meta,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: compact ? const TextStyle(fontSize: 12) : null,
          ),
        if (note.isNotEmpty)
          Text(
            note,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: compact ? const TextStyle(fontSize: 12) : null,
          ),
      ],
    );
  }

  Widget _orderRow(MobileOrder order, {bool zeroCancelled = false}) {
    final compact = _compactOrders(context);
    final color = _statusColor(order.status);
    return LongPressDraggable<MobileOrder>(
      data: order,
      onDragStarted: _beginOrderDrag,
      onDragCompleted: _endOrderDrag,
      onDraggableCanceled: (_, __) => _endOrderDrag(),
      onDragEnd: (_) => _pauseMobileOrderSync(),
      feedback: Material(
        color: Colors.transparent,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: _OrderDragPreview(order: order, color: color),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: .35,
        child: RepaintBoundary(
          child: _orderTile(
            order,
            color,
            zeroCancelled: zeroCancelled,
            compact: compact,
          ),
        ),
      ),
      child: RepaintBoundary(
        child: _orderTile(
          order,
          color,
          zeroCancelled: zeroCancelled,
          compact: compact,
        ),
      ),
    );
  }

  Widget _orderTile(
    MobileOrder order,
    Color color, {
    bool zeroCancelled = false,
    required bool compact,
  }) {
    final subtitle = _orderSubtitle(order, compact: compact);
    final isWalkIn = order.note.trim().toLowerCase().startsWith('walk-in sale');
    var quantityLabel = '${order.bagsQuantity} ${order.bagsType}';
    if (zeroCancelled && order.status == MobileOrderStatus.cancelled) {
      quantityLabel = '0 ${order.bagsType}';
    }
    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 4 : 6),
      child: AppPressable(
        onTap: () => _openOrderForm(order),
        borderRadius: BorderRadius.circular(8),
        child: Material(
          color: _statusBackgroundColor(order.status),
          borderRadius: BorderRadius.circular(8),
          child: ListTile(
            dense: true,
            isThreeLine: subtitle != null && !compact,
            minVerticalPadding: compact ? 4 : null,
            visualDensity: compact
                ? const VisualDensity(horizontal: -2, vertical: -3)
                : VisualDensity.compact,
            contentPadding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10),
            title: Text(
              isWalkIn ? 'WALK-IN SALE' : 'Plot ${order.plotNo}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: compact ? const TextStyle(fontSize: 13) : null,
            ),
            subtitle: subtitle,
            trailing: _orderTrailing(
              quantityLabel: quantityLabel,
              recordedInvoiceNo: order.recordedInvoiceNo,
              color: color,
              compact: compact,
            ),
            shape: RoundedRectangleBorder(
              side: BorderSide(color: color, width: 1),
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      ),
    );
  }

  Widget _orderTrailing({
    required String quantityLabel,
    required int? recordedInvoiceNo,
    required Color color,
    required bool compact,
  }) {
    final qtyText = Text(
      quantityLabel,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.end,
      style: TextStyle(
        color: color,
        fontWeight: FontWeight.w800,
        fontSize: compact ? 12 : null,
      ),
    );
    if (recordedInvoiceNo == null) return qtyText;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        qtyText,
        Text(
          'REC #$recordedInvoiceNo',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.end,
          style: TextStyle(
            color: color.withValues(alpha: .82),
            fontSize: compact ? 9 : 10,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  void _moveOrder(
    MobileOrder order, {
    required String site,
    String truckId = '',
    String truckLabel = '',
  }) {
    _pauseMobileOrderSync();
    final cleanSite = site.trim();
    final cleanTruckId =
        _siteUsesTruckPlanning(cleanSite) ? truckId.trim() : '';
    final cleanTruckNo = cleanTruckId.isEmpty ? '' : truckLabel.trim();
    final movedOrder = order.copyWith(
      orderSite: cleanSite,
      assignedTruckId: cleanTruckId,
      assignedTruckNo: cleanTruckNo,
    );
    if (mounted) {
      setState(() {
        _orders = [
          for (final current in _orders)
            current.id == order.id ? movedOrder : current,
        ];
      });
    }
    unawaited(Future<void>(() async {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await _persistMovedOrder(
        originalOrder: order,
        movedOrder: movedOrder,
        cleanSite: cleanSite,
        cleanTruckId: cleanTruckId,
        cleanTruckNo: cleanTruckNo,
      );
    }));
  }

  Future<void> _persistMovedOrder({
    required MobileOrder originalOrder,
    required MobileOrder movedOrder,
    required String cleanSite,
    required String cleanTruckId,
    required String cleanTruckNo,
  }) async {
    try {
      await MobileAccessStore.upsertOrder(movedOrder);
      final config = await MobileAccessStore.loadServerConfig();
      final result = await ServerSyncClient.saveOrder(
        baseUrl: config.baseUrl,
        username: widget.user.username,
        passcode: widget.user.passcode,
        payload: {
          'id': movedOrder.id,
          'orderDate': movedOrder.orderDate,
          'customerName': movedOrder.customerName,
          'plotNo': movedOrder.plotNo,
          'bagsQuantity': movedOrder.bagsQuantity,
          'bagsType': movedOrder.bagsType,
          'bagsBrand': movedOrder.bagsBrand,
          'orderSite': cleanSite,
          'assignedTruckId': cleanTruckId,
          'assignedTruckNo': cleanTruckNo,
          'note': movedOrder.note,
          'status': movedOrder.status.name,
        },
      );
      if (mounted &&
          (result.order.orderSite != movedOrder.orderSite ||
              result.order.assignedTruckId != movedOrder.assignedTruckId ||
              result.order.assignedTruckNo != movedOrder.assignedTruckNo)) {
        setState(() {
          _orders = [
            for (final current in _orders)
              current.id == movedOrder.id ? result.order : current,
          ];
        });
      }
    } on ServerSyncException catch (e) {
      if (!mounted) return;
      setState(() {
        _orders = [
          for (final current in _orders)
            current.id == originalOrder.id ? originalOrder : current,
        ];
      });
      await MobileAccessStore.upsertOrder(originalOrder);
      if (!mounted) return;
      showErr(context, e.message);
    }
  }

  Widget _siteSection(String site) {
    final compact = _compactOrders(context);
    final orders = _ordersForSite(site);
    final isSurjani = site.toLowerCase() == 'surjani';
    final isFactory = site.toLowerCase() == 'factory';
    final isGodown = site.toLowerCase() == 'godown';
    final returns = isGodown ? _returnsForSelectedDate() : const <Invoice>[];
    final entryCount = orders.length + returns.length;
    final children = <Widget>[
      if (isSurjani)
        _surjaniTruckPlanner()
      else if (isFactory)
        _factoryTruckPlanner()
      else if (orders.isEmpty && returns.isEmpty)
        const Padding(
          padding: EdgeInsets.only(bottom: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text('No orders.'),
          ),
        )
      else ...[
        ...orders.map(_orderRow),
        ...returns.map(_returnRow),
      ],
    ];
    final section = AppExpandableCard(
      margin: EdgeInsets.only(bottom: compact ? 6 : 10),
      headerPadding:
          EdgeInsets.fromLTRB(12, compact ? 8 : 12, 8, compact ? 8 : 12),
      childrenPadding: EdgeInsets.fromLTRB(12, 0, 12, compact ? 10 : 14),
      title: Text(
        '$site ($entryCount)',
        style: const TextStyle(fontWeight: FontWeight.w800),
      ),
      subtitle: Text(
        isSurjani || isFactory
            ? 'Trucks and assigned orders'
            : isGodown
                ? 'Orders and buyer returns for selected date'
                : 'Orders for selected date',
        style: const TextStyle(fontSize: 12, color: Color(0xFF5F6368)),
      ),
      expandedColor:
          isSurjani || isFactory ? const Color(0xFFEAF7F5) : Colors.white,
      children: children,
    );
    if (isSurjani || isFactory) {
      return section;
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DragTarget<MobileOrder>(
        onWillAcceptWithDetails: (_) => true,
        onAcceptWithDetails: (details) => _moveOrder(details.data, site: site),
        builder: (context, candidateData, rejectedData) {
          final hover = candidateData.isNotEmpty;
          return Container(
            decoration: BoxDecoration(
              color: hover ? const Color(0xFFEAF7F5) : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: AppExpandableCard(
              margin: EdgeInsets.zero,
              headerPadding: EdgeInsets.fromLTRB(
                  12, compact ? 8 : 12, 8, compact ? 8 : 12),
              childrenPadding:
                  EdgeInsets.fromLTRB(12, 0, 12, compact ? 10 : 14),
              expandedColor:
                  hover ? const Color(0xFFDFF4EF) : const Color(0xFFF9FBFB),
              borderColor:
                  hover ? const Color(0xFF00838F) : const Color(0xFFE2EAED),
              title: Text(
                hover ? 'Drop to $site' : '$site ($entryCount)',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              subtitle: Text(
                hover
                    ? 'Release order here'
                    : isGodown
                        ? 'Orders and buyer returns for selected date'
                        : 'Orders for selected date',
                style: const TextStyle(fontSize: 12, color: Color(0xFF5F6368)),
              ),
              children: children,
            ),
          );
        },
      ),
    );
  }

  Widget _surjaniTruckPlanner() {
    final compact = _compactOrders(context);
    final surjaniOrders = _ordersForSite('Surjani');
    final pendingBags = surjaniOrders
        .where((order) => order.status == MobileOrderStatus.pending)
        .fold<int>(
          0,
          (sum, order) => sum + order.bagsQuantity,
        );
    final totalCapacity = _surjaniTrucks.fold<int>(
      0,
      (sum, truck) => sum + truck.capacity,
    );
    final remainingCapacity = (totalCapacity - pendingBags).clamp(0, 1 << 31);
    final shortBags = (pendingBags - totalCapacity).clamp(0, 1 << 31);
    final allocations = _allocateSurjaniOrders(surjaniOrders);
    final allocatedOrderIds = allocations
        .expand((truckOrders) => truckOrders)
        .map((order) => order.id)
        .toSet();
    final unassignedOrders = surjaniOrders
        .where((order) => !allocatedOrderIds.contains(order.id))
        .toList();
    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 8 : 12),
      child: AppSoftCard(
        backgroundColor: Colors.white,
        padding: EdgeInsets.all(compact ? 10 : 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Expanded(
                  child: Text(
                    'Surjani Trucks',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            SizedBox(height: compact ? 6 : 10),
            TextField(
              controller: _newSurjaniTruckNoCtrl,
              decoration: const InputDecoration(
                labelText: 'Truck no',
                isDense: true,
              ),
            ),
            SizedBox(height: compact ? 6 : 8),
            Row(
              children: [
                SizedBox(
                  width: compact ? 92 : 110,
                  child: TextField(
                    controller: _newSurjaniTruckQtyCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Qty',
                      isDense: true,
                    ),
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Add truck',
                  onPressed: _addSurjaniTruck,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            SizedBox(height: compact ? 6 : 10),
            Wrap(
              spacing: compact ? 5 : 8,
              runSpacing: compact ? 5 : 8,
              children: [
                AppMetaChip(text: 'Pending bags $pendingBags'),
                AppMetaChip(text: 'Capacity $totalCapacity'),
                AppMetaChip(text: 'Balance $remainingCapacity'),
                if (shortBags > 0) AppMetaChip(text: 'Need $shortBags'),
              ],
            ),
            SizedBox(height: compact ? 6 : 8),
            ...List<Widget>.generate(
              _surjaniTrucks.length,
              (index) => _surjaniTruckColumn(index, allocations[index]),
            ),
            if (unassignedOrders.isNotEmpty) ...[
              SizedBox(height: compact ? 6 : 8),
              const Text(
                'Unassigned orders',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              SizedBox(height: compact ? 4 : 6),
              ...unassignedOrders.map(_orderRow),
            ],
            if (_surjaniTrucks.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('No trucks added.'),
              ),
            if (surjaniOrders.isEmpty) const Text('No Surjani orders.'),
          ],
        ),
      ),
    );
  }

  Widget _factoryTruckPlanner() {
    final compact = _compactOrders(context);
    final factoryOrders = _ordersForSite('Factory');
    final pendingBags = factoryOrders
        .where((order) => order.status == MobileOrderStatus.pending)
        .fold<int>(
          0,
          (sum, order) => sum + order.bagsQuantity,
        );
    final totalCapacity = _factoryTrucks.fold<int>(
      0,
      (sum, truck) => sum + truck.capacity,
    );
    final remainingCapacity = (totalCapacity - pendingBags).clamp(0, 1 << 31);
    final shortBags = (pendingBags - totalCapacity).clamp(0, 1 << 31);
    final allocations = _allocateFactoryOrders(factoryOrders);
    final allocatedOrderIds = allocations
        .expand((truckOrders) => truckOrders)
        .map((order) => order.id)
        .toSet();
    final unassignedOrders = factoryOrders
        .where((order) => !allocatedOrderIds.contains(order.id))
        .toList();
    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 8 : 12),
      child: AppSoftCard(
        backgroundColor: Colors.white,
        padding: EdgeInsets.all(compact ? 10 : 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Expanded(
                  child: Text(
                    'Factory Trucks',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            SizedBox(height: compact ? 6 : 10),
            TextField(
              controller: _newFactoryTruckNoCtrl,
              decoration: const InputDecoration(
                labelText: 'Truck no',
                isDense: true,
              ),
            ),
            SizedBox(height: compact ? 6 : 8),
            Row(
              children: [
                SizedBox(
                  width: compact ? 92 : 110,
                  child: TextField(
                    controller: _newFactoryTruckQtyCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Qty',
                      isDense: true,
                    ),
                  ),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Add truck',
                  onPressed: _addFactoryTruck,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            SizedBox(height: compact ? 6 : 10),
            Wrap(
              spacing: compact ? 5 : 8,
              runSpacing: compact ? 5 : 8,
              children: [
                AppMetaChip(text: 'Pending bags $pendingBags'),
                AppMetaChip(text: 'Capacity $totalCapacity'),
                AppMetaChip(text: 'Balance $remainingCapacity'),
                if (shortBags > 0) AppMetaChip(text: 'Need $shortBags'),
              ],
            ),
            SizedBox(height: compact ? 6 : 8),
            ...List<Widget>.generate(
              _factoryTrucks.length,
              (index) => _factoryTruckColumn(index, allocations[index]),
            ),
            if (unassignedOrders.isNotEmpty) ...[
              SizedBox(height: compact ? 6 : 8),
              const Text(
                'Unassigned orders',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              SizedBox(height: compact ? 4 : 6),
              ...unassignedOrders.map(_orderRow),
            ],
            if (_factoryTrucks.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('No trucks added.'),
              ),
            if (factoryOrders.isEmpty) const Text('No Factory orders.'),
          ],
        ),
      ),
    );
  }

  List<List<MobileOrder>> _allocateSurjaniOrders(
    List<MobileOrder> orders,
  ) {
    final allocations = List<List<MobileOrder>>.generate(
      _surjaniTrucks.length,
      (_) => <MobileOrder>[],
    );
    final assignedTruckIndexes = <String, int>{};
    for (var i = 0; i < _surjaniTrucks.length; i++) {
      assignedTruckIndexes[_surjaniTrucks[i].id.toLowerCase()] = i;
    }
    for (final order in orders) {
      final assignedTruckKey = order.assignedTruckId.trim();
      final assignedIndex =
          assignedTruckIndexes[assignedTruckKey.toLowerCase()];
      if (assignedIndex != null) {
        allocations[assignedIndex].add(order);
      }
    }
    return allocations;
  }

  List<List<MobileOrder>> _allocateFactoryOrders(
    List<MobileOrder> orders,
  ) {
    final allocations = List<List<MobileOrder>>.generate(
      _factoryTrucks.length,
      (_) => <MobileOrder>[],
    );
    final assignedTruckIndexes = <String, int>{};
    for (var i = 0; i < _factoryTrucks.length; i++) {
      assignedTruckIndexes[_factoryTrucks[i].id.toLowerCase()] = i;
    }
    for (final order in orders) {
      final assignedTruckKey = order.assignedTruckId.trim();
      final assignedIndex =
          assignedTruckIndexes[assignedTruckKey.toLowerCase()];
      if (assignedIndex != null) {
        allocations[assignedIndex].add(order);
      }
    }
    return allocations;
  }

  Widget _surjaniTruckColumn(
    int index,
    List<MobileOrder> allocations,
  ) {
    final compact = _compactOrders(context);
    final truck = _surjaniTrucks[index];
    final load = allocations.fold<int>(
      0,
      (sum, order) =>
          sum +
          (order.status == MobileOrderStatus.cancelled
              ? 0
              : order.bagsQuantity),
    );
    final balance = truck.capacity - load;
    final typeBalance = truck.capacity - truck.allottedTypeBags;
    final balanceByType = _truckBalanceByType(truck, allocations);
    final godownBalanceEntries = _godownBalanceEntriesForTruck(truck);
    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 6 : 8),
      child: DragTarget<MobileOrder>(
        onWillAcceptWithDetails: (_) => true,
        onAcceptWithDetails: (details) => _moveOrder(
          details.data,
          site: 'Surjani',
          truckId: truck.id,
          truckLabel: truck.numberCtrl.text,
        ),
        builder: (context, candidateData, rejectedData) {
          final hover = candidateData.isNotEmpty;
          return AppExpandableCard(
            margin: EdgeInsets.zero,
            headerPadding:
                EdgeInsets.fromLTRB(8, compact ? 6 : 10, 6, compact ? 6 : 10),
            childrenPadding: EdgeInsets.fromLTRB(8, 0, 8, compact ? 8 : 10),
            expandedColor:
                hover ? const Color(0xFFDFF4EF) : const Color(0xFFF8FBFB),
            borderColor:
                hover ? const Color(0xFF00838F) : const Color(0xFFE2EAED),
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: truck.numberCtrl,
                  onEditingComplete: _saveSurjaniTrucks,
                  decoration: InputDecoration(
                    labelText: index == 0 ? 'Truck no' : 'Truck ${index + 1}',
                    isDense: true,
                  ),
                ),
                SizedBox(height: compact ? 6 : 8),
                Row(
                  children: [
                    SizedBox(
                      width: compact ? 82 : 96,
                      child: TextField(
                        controller: truck.qtyCtrl,
                        keyboardType: TextInputType.number,
                        onEditingComplete: () {
                          setState(() {});
                          _saveSurjaniTrucks();
                        },
                        decoration: const InputDecoration(
                          labelText: 'Qty',
                          isDense: true,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    SizedBox(width: compact ? 8 : 10),
                    Expanded(
                      child: Text(
                        '$load / ${truck.capacity}',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          fontSize: compact ? 12 : null,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    _truckActionMenu(
                      compact: compact,
                      onEditTypes: () => _editTruckTypeSplit(
                        truck,
                        onSave: _saveSurjaniTrucks,
                      ),
                      onMoveBalance: balanceByType.isEmpty
                          ? null
                          : () => _moveTruckBalanceToGodown(
                                sourceSite: 'Surjani',
                                truck: truck,
                                allocations: allocations,
                              ),
                      onDelete: () => _deleteTruckSlot(index),
                    ),
                  ],
                ),
              ],
            ),
            subtitle: Text(
              hover
                  ? 'Drop order here'
                  : 'Balance $balance bags | ${truck.typeSummary}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF5F6368)),
            ),
            children: [
              if (truck.typeBags.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(bottom: compact ? 6 : 8),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      AppMetaChip(
                        text: typeBalance == 0
                            ? 'Types complete'
                            : 'Type balance $typeBalance',
                      ),
                      for (final entry in truck.typeBags.entries)
                        AppMetaChip(text: '${entry.key} ${entry.value}'),
                      if (balanceByType.isNotEmpty)
                        AppMetaChip(
                          icon: Icons.inventory_2_outlined,
                          text:
                              'Godown ${balanceByType.values.fold<int>(0, (sum, qty) => sum + qty)}',
                        ),
                    ],
                  ),
                ),
              if (godownBalanceEntries.isNotEmpty) ...[
                ...godownBalanceEntries.map(
                  (entry) => _godownBalanceRow(entry, compact: compact),
                ),
                SizedBox(height: compact ? 4 : 6),
              ],
              ...allocations
                  .map((order) => _orderRow(order, zeroCancelled: true)),
              if (allocations.isEmpty)
                SizedBox(
                  height: compact ? 34 : 44,
                  child: const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Drop order here'),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _factoryTruckColumn(
    int index,
    List<MobileOrder> allocations,
  ) {
    final compact = _compactOrders(context);
    final truck = _factoryTrucks[index];
    final load = allocations.fold<int>(
      0,
      (sum, order) =>
          sum +
          (order.status == MobileOrderStatus.cancelled
              ? 0
              : order.bagsQuantity),
    );
    final balance = truck.capacity - load;
    final typeBalance = truck.capacity - truck.allottedTypeBags;
    final balanceByType = _truckBalanceByType(truck, allocations);
    final godownBalanceEntries = _godownBalanceEntriesForTruck(truck);
    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 6 : 8),
      child: DragTarget<MobileOrder>(
        onWillAcceptWithDetails: (_) => true,
        onAcceptWithDetails: (details) => _moveOrder(
          details.data,
          site: 'Factory',
          truckId: truck.id,
          truckLabel: truck.numberCtrl.text,
        ),
        builder: (context, candidateData, rejectedData) {
          final hover = candidateData.isNotEmpty;
          return AppExpandableCard(
            margin: EdgeInsets.zero,
            headerPadding:
                EdgeInsets.fromLTRB(8, compact ? 6 : 10, 6, compact ? 6 : 10),
            childrenPadding: EdgeInsets.fromLTRB(8, 0, 8, compact ? 8 : 10),
            expandedColor:
                hover ? const Color(0xFFDFF4EF) : const Color(0xFFF8FBFB),
            borderColor:
                hover ? const Color(0xFF00838F) : const Color(0xFFE2EAED),
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: truck.numberCtrl,
                  onEditingComplete: _saveFactoryTrucks,
                  decoration: InputDecoration(
                    labelText: index == 0 ? 'Truck no' : 'Truck ${index + 1}',
                    isDense: true,
                  ),
                ),
                SizedBox(height: compact ? 6 : 8),
                Row(
                  children: [
                    SizedBox(
                      width: compact ? 82 : 96,
                      child: TextField(
                        controller: truck.qtyCtrl,
                        keyboardType: TextInputType.number,
                        onEditingComplete: () {
                          setState(() {});
                          _saveFactoryTrucks();
                        },
                        decoration: const InputDecoration(
                          labelText: 'Qty',
                          isDense: true,
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    SizedBox(width: compact ? 8 : 10),
                    Expanded(
                      child: Text(
                        '$load / ${truck.capacity}',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          fontSize: compact ? 12 : null,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    _truckActionMenu(
                      compact: compact,
                      onEditTypes: () => _editTruckTypeSplit(
                        truck,
                        onSave: _saveFactoryTrucks,
                      ),
                      onMoveBalance: balanceByType.isEmpty
                          ? null
                          : () => _moveTruckBalanceToGodown(
                                sourceSite: 'Factory',
                                truck: truck,
                                allocations: allocations,
                              ),
                      onDelete: () => _deleteFactoryTruckSlot(index),
                    ),
                  ],
                ),
              ],
            ),
            subtitle: Text(
              hover
                  ? 'Drop order here'
                  : 'Balance $balance bags | ${truck.typeSummary}',
              style: const TextStyle(fontSize: 12, color: Color(0xFF5F6368)),
            ),
            children: [
              if (truck.typeBags.isNotEmpty)
                Padding(
                  padding: EdgeInsets.only(bottom: compact ? 6 : 8),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      AppMetaChip(
                        text: typeBalance == 0
                            ? 'Types complete'
                            : 'Type balance $typeBalance',
                      ),
                      for (final entry in truck.typeBags.entries)
                        AppMetaChip(text: '${entry.key} ${entry.value}'),
                      if (balanceByType.isNotEmpty)
                        AppMetaChip(
                          icon: Icons.inventory_2_outlined,
                          text:
                              'Godown ${balanceByType.values.fold<int>(0, (sum, qty) => sum + qty)}',
                        ),
                    ],
                  ),
                ),
              if (godownBalanceEntries.isNotEmpty) ...[
                ...godownBalanceEntries.map(
                  (entry) => _godownBalanceRow(entry, compact: compact),
                ),
                SizedBox(height: compact ? 4 : 6),
              ],
              ...allocations
                  .map((order) => _orderRow(order, zeroCancelled: true)),
              if (allocations.isEmpty)
                SizedBox(
                  height: compact ? 34 : 44,
                  child: const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Drop order here'),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _godownBalanceRow(
    _TruckGodownBalanceEntry entry, {
    required bool compact,
  }) {
    const color = Color(0xFF17A673);
    return Padding(
      padding: EdgeInsets.only(bottom: compact ? 4 : 6),
      child: Material(
        color: const Color(0xFFEAF7F1),
        borderRadius: BorderRadius.circular(8),
        child: ListTile(
          dense: true,
          minVerticalPadding: compact ? 4 : null,
          visualDensity: compact
              ? const VisualDensity(horizontal: -2, vertical: -3)
              : VisualDensity.compact,
          contentPadding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10),
          leading: Icon(
            Icons.warehouse_outlined,
            size: compact ? 18 : 20,
            color: color,
          ),
          title: Text(
            entry.sku.isEmpty ? 'Godown balance' : entry.sku,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: compact ? 13 : null,
              fontWeight: FontWeight.w800,
              color: const Color(0xFF173A2A),
            ),
          ),
          subtitle: Text(
            'Moved to Godown',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: compact ? 11 : 12),
          ),
          trailing: Text(
            '${fmt0(entry.qty)} ${entry.category}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w800,
              fontSize: compact ? 12 : null,
            ),
          ),
          shape: RoundedRectangleBorder(
            side: const BorderSide(color: Color(0xFF9ED9BD), width: 1),
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
    );
  }

  Widget _truckActionMenu({
    required bool compact,
    required VoidCallback onEditTypes,
    required VoidCallback? onMoveBalance,
    required VoidCallback onDelete,
  }) {
    return PopupMenuButton<String>(
      tooltip: 'Truck actions',
      icon: const Icon(Icons.more_vert),
      iconSize: compact ? 20 : 24,
      onSelected: (value) {
        switch (value) {
          case 'types':
            onEditTypes();
            break;
          case 'godown':
            onMoveBalance?.call();
            break;
          case 'delete':
            onDelete();
            break;
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'types',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.category_outlined),
            title: Text('Allot bag types'),
          ),
        ),
        PopupMenuItem(
          value: 'godown',
          enabled: onMoveBalance != null,
          child: const ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.inventory_2_outlined),
            title: Text('Move balance to Godown'),
          ),
        ),
        const PopupMenuItem(
          value: 'delete',
          child: ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.delete_outline, color: Color(0xFFB42318)),
            title: Text('Delete truck'),
          ),
        ),
      ],
    );
  }

  Future<void> _editTruckTypeSplit(
    _SurjaniTruckColumn truck, {
    required Future<void> Function() onSave,
  }) async {
    final controllers = {
      for (final type in kItemTypes)
        type: TextEditingController(
          text: truck.typeQtyCtrls[type]?.text.trim() ?? '',
        ),
    };
    String? error;
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) {
          final total = controllers.values.fold<int>(
            0,
            (sum, controller) =>
                sum + (int.tryParse(controller.text.trim()) ?? 0),
          );
          return AlertDialog(
            title: Text('Allot ${truck.numberCtrl.text.trim()}'),
            content: SizedBox(
              width: 320,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 360),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final type in kItemTypes) ...[
                        TextField(
                          controller: controllers[type],
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: type,
                            isDense: true,
                          ),
                          onChanged: (_) {
                            setDialogState(() => error = null);
                          },
                        ),
                        const SizedBox(height: 8),
                      ],
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Allotted $total / ${truck.capacity}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      if (error != null) ...[
                        const SizedBox(height: 6),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            error!,
                            style: const TextStyle(color: Color(0xFFE15241)),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  if (total > truck.capacity) {
                    setDialogState(
                      () => error = 'Split cannot exceed truck quantity.',
                    );
                    return;
                  }
                  Navigator.of(dialogContext).pop(true);
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
    if (saved == true) {
      setState(() {
        for (final entry in controllers.entries) {
          truck.typeQtyCtrls[entry.key]?.text = entry.value.text.trim();
        }
      });
      await onSave();
    }
    for (final controller in controllers.values) {
      controller.dispose();
    }
  }

  Future<void> _addSurjaniTruck() async {
    final truckNo = _newSurjaniTruckNoCtrl.text.trim();
    final qtyText = _newSurjaniTruckQtyCtrl.text.trim();
    final qty = int.tryParse(qtyText) ?? 0;
    if (truckNo.isEmpty || qty <= 0) {
      showErr(context, 'Truck number and quantity are required.');
      return;
    }
    setState(() {
      _surjaniTrucks.add(_SurjaniTruckColumn(number: truckNo, qty: qty));
      _newSurjaniTruckNoCtrl.text = 'JW-2535';
      _newSurjaniTruckQtyCtrl.text = '250';
    });
    await _saveSurjaniTrucks();
  }

  Future<void> _addFactoryTruck() async {
    final truckNo = _newFactoryTruckNoCtrl.text.trim();
    final qtyText = _newFactoryTruckQtyCtrl.text.trim();
    final qty = int.tryParse(qtyText) ?? 0;
    if (truckNo.isEmpty || qty <= 0) {
      showErr(context, 'Truck number and quantity are required.');
      return;
    }
    setState(() {
      _factoryTrucks.add(_SurjaniTruckColumn(number: truckNo, qty: qty));
      _newFactoryTruckNoCtrl.text = 'Factory-1';
      _newFactoryTruckQtyCtrl.text = '250';
    });
    await _saveFactoryTrucks();
  }

  Future<void> _deleteTruckSlot(int index) async {
    if (index < 0 || index >= _surjaniTrucks.length) {
      return;
    }
    final truckId = _surjaniTrucks[index].id;
    setState(() {
      final removed = _surjaniTrucks.removeAt(index);
      removed.dispose();
    });
    await _saveSurjaniTrucks(syncToServer: false);
    unawaited(_deleteSurjaniTruckOnServer(truckId));
  }

  Future<void> _deleteFactoryTruckSlot(int index) async {
    if (index < 0 || index >= _factoryTrucks.length) {
      return;
    }
    final truckId = _factoryTrucks[index].id;
    setState(() {
      final removed = _factoryTrucks.removeAt(index);
      removed.dispose();
    });
    await _saveFactoryTrucks(syncToServer: false);
    unawaited(_deleteFactoryTruckOnServer(truckId));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const AppSkeletonLoader();
    }
    final compact = _compactOrders(context);
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _syncOrders,
        child: ListView(
          padding: EdgeInsets.all(compact ? 10 : 16),
          children: [
            Padding(
              padding: EdgeInsets.only(bottom: compact ? 8 : 12),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      readOnly: true,
                      onTap: _pickSelectedOrderDate,
                      controller: _selectedOrderDateCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Order Date',
                        suffixIcon: Icon(Icons.calendar_today, size: 18),
                      ),
                    ),
                  ),
                  SizedBox(width: compact ? 6 : 8),
                  IconButton(
                    tooltip: 'Today',
                    visualDensity: compact
                        ? const VisualDensity(horizontal: -4, vertical: -4)
                        : null,
                    onPressed: () => _changeSelectedOrderDate(
                      DateTime.now().toIso8601String().split('T').first,
                    ),
                    icon: const Icon(Icons.today),
                  ),
                  IconButton(
                    tooltip: _syncing ? 'Syncing...' : 'Sync orders',
                    onPressed: _syncing ? null : _syncOrders,
                    visualDensity: compact
                        ? const VisualDensity(horizontal: -4, vertical: -4)
                        : null,
                    icon: const Icon(Icons.sync),
                  ),
                ],
              ),
            ),
            _siteSection('Surjani'),
            _siteSection('Godown'),
            _siteSection('Factory'),
          ],
        ),
      ),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.extended(
            heroTag: 'walk-in-sale',
            onPressed: _openWalkInSaleForm,
            icon: const Icon(Icons.point_of_sale_outlined),
            label: const Text('Walk-in'),
          ),
          const SizedBox(height: 10),
          FloatingActionButton.extended(
            heroTag: 'new-order',
            onPressed: () => _openOrderForm(),
            icon: const Icon(Icons.add),
            label: const Text('Order'),
          ),
        ],
      ),
    );
  }
}

class MobileWalkInSaleScreen extends StatefulWidget {
  final AppUser user;
  final String initialDate;

  const MobileWalkInSaleScreen({
    super.key,
    required this.user,
    required this.initialDate,
  });

  @override
  State<MobileWalkInSaleScreen> createState() => _MobileWalkInSaleScreenState();
}

class _MobileWalkInSaleScreenState extends State<MobileWalkInSaleScreen> {
  late final TextEditingController _dateCtrl;
  late final String _orderId;
  final _brandCtrl = TextEditingController();
  final _brandFocus = FocusNode();
  final _qtyCtrl = TextEditingController();
  final _rateCtrl = TextEditingController();
  final _cartageCtrl = TextEditingController(text: '0');
  final _paymentNoteCtrl = TextEditingController();
  String _type = kItemTypes.first;
  String _site = kShipmentSites.first;
  PaymentType _paymentType = PaymentType.cash;
  InvoiceDraftSuggestions _suggestions = const InvoiceDraftSuggestions.empty();
  bool _suggestionsLoading = false;
  bool _suggestionsLoaded = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _orderId = MobileAccessStore.nextOrderId();
    _dateCtrl = TextEditingController(text: widget.initialDate);
    unawaited(_loadSuggestions());
  }

  @override
  void dispose() {
    _dateCtrl.dispose();
    _brandCtrl.dispose();
    _brandFocus.dispose();
    _qtyCtrl.dispose();
    _rateCtrl.dispose();
    _cartageCtrl.dispose();
    _paymentNoteCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSuggestions() async {
    if (_suggestionsLoading || _suggestionsLoaded) return;
    _suggestionsLoading = true;
    try {
      final suggestions = await InvoiceDraftSuggestions.load();
      if (!mounted) return;
      setState(() {
        _suggestions = suggestions;
        _suggestionsLoaded = true;
      });
    } catch (_) {
      // The sale form remains usable when local suggestions cannot be loaded.
    } finally {
      _suggestionsLoading = false;
    }
  }

  Iterable<String> _brandOptions(String query) {
    return _suggestions.brandOptionsFor(_site, _type, query);
  }

  Future<void> _pickDate() async {
    final initial = DateTime.tryParse(_dateCtrl.text.trim()) ?? DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() => _dateCtrl.text = picked.toIso8601String().split('T').first);
  }

  List<ItemLine>? _buildInvoiceLines() {
    final brand = _brandCtrl.text.trim();
    final qty = int.tryParse(_qtyCtrl.text.trim()) ?? 0;
    final rate = double.tryParse(_rateCtrl.text.trim()) ?? 0;
    if (brand.isEmpty || qty <= 0 || rate <= 0) {
      showErr(context, 'Brand, quantity, and rate are required.');
      return null;
    }
    return [ItemLine(_type, brand: brand, qty: qty, rate: rate)];
  }

  Future<void> _save() async {
    if (_saving) return;
    final lines = _buildInvoiceLines();
    if (lines == null) return;
    final cartage = double.tryParse(_cartageCtrl.text.trim()) ?? 0;
    if (cartage < 0) {
      showErr(context, 'Cartage cannot be negative.');
      return;
    }
    setState(() => _saving = true);
    try {
      final config = await MobileAccessStore.loadServerConfig();
      final invoice = await ServerSyncClient.recordWalkInInvoice(
        baseUrl: config.baseUrl,
        username: widget.user.username,
        passcode: widget.user.passcode,
        invoiceDate: _dateCtrl.text.trim(),
        customer: 'Walk-in Customer',
        contact: '',
        address: '',
        site: _site,
        lines: lines,
        cartage: cartage,
        paymentType: _paymentType,
        orderId: _orderId,
        paymentNote: _paymentNoteCtrl.text.trim(),
      );
      if (!mounted) return;
      showOk(context, 'Walk-in invoice #${invoice.sNo} saved.');
      Navigator.of(context).pop(true);
    } on ServerSyncException catch (e) {
      if (!mounted) return;
      showErr(context, e.message);
    } catch (e) {
      if (!mounted) return;
      showErr(context, 'Could not save walk-in sale: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
      for (final line in lines) {
        line.dispose();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Walk-in Sale')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _dateCtrl,
            readOnly: true,
            onTap: _pickDate,
            decoration: const InputDecoration(
              labelText: 'Sale date',
              suffixIcon: Icon(Icons.calendar_today_outlined),
            ),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _site,
            items: kShipmentSites
                .map((site) => DropdownMenuItem(value: site, child: Text(site)))
                .toList(),
            onChanged: (value) =>
                setState(() => _site = value ?? kShipmentSites.first),
            decoration: const InputDecoration(labelText: 'Shipment Site'),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _type,
            items: kItemTypes
                .map((type) => DropdownMenuItem(value: type, child: Text(type)))
                .toList(),
            onChanged: (value) =>
                setState(() => _type = value ?? kItemTypes.first),
            decoration: const InputDecoration(labelText: 'Type'),
          ),
          const SizedBox(height: 10),
          RawAutocomplete<String>(
            textEditingController: _brandCtrl,
            focusNode: _brandFocus,
            optionsBuilder: (text) => _brandOptions(text.text),
            onSelected: (value) => _brandCtrl.text = value,
            fieldViewBuilder: (context, controller, focusNode, onSubmitted) {
              return TextField(
                controller: controller,
                focusNode: focusNode,
                onTap: () => unawaited(_loadSuggestions()),
                decoration: const InputDecoration(labelText: 'Brand / company'),
              );
            },
            optionsViewBuilder: (context, onSelected, options) {
              return Align(
                alignment: Alignment.topLeft,
                child: Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(8),
                  child: ConstrainedBox(
                    constraints:
                        const BoxConstraints(maxHeight: 220, maxWidth: 320),
                    child: ListView.builder(
                      padding: EdgeInsets.zero,
                      shrinkWrap: true,
                      itemCount: options.length,
                      itemBuilder: (context, index) {
                        final option = options.elementAt(index);
                        return ListTile(
                          dense: true,
                          title: Text(option),
                          onTap: () => onSelected(option),
                        );
                      },
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _qtyCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Qty'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _rateCtrl,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Rate'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _cartageCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Cartage optional'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<PaymentType>(
            initialValue: _paymentType,
            items: PaymentType.values
                .map((type) => DropdownMenuItem(
                      value: type,
                      child: Text(paymentTypeLabel(type)),
                    ))
                .toList(),
            onChanged: (value) =>
                setState(() => _paymentType = value ?? PaymentType.cash),
            decoration: const InputDecoration(labelText: 'Payment type'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _paymentNoteCtrl,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Payment note (optional)',
            ),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.check),
            label: Text(_saving ? 'Saving...' : 'Save walk-in sale'),
          ),
        ],
      ),
    );
  }
}

class _OrderDragPreview extends StatelessWidget {
  final MobileOrder order;
  final Color color;

  const _OrderDragPreview({
    required this.order,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Transform.scale(
      scale: .96,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color, width: 1.2),
          boxShadow: const [
            BoxShadow(
              color: Color(0x26000000),
              blurRadius: 14,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.drag_indicator, color: color, size: 18),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  'Plot ${order.plotNo}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '${order.bagsQuantity} ${order.bagsType}',
                style: TextStyle(color: color, fontWeight: FontWeight.w800),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class MobileOrderFormScreen extends StatefulWidget {
  final AppUser user;
  final MobileOrder? order;

  const MobileOrderFormScreen({
    super.key,
    required this.user,
    this.order,
  });

  @override
  State<MobileOrderFormScreen> createState() => _MobileOrderFormScreenState();
}

class _MobileOrderFormScreenState extends State<MobileOrderFormScreen> {
  static const _sites = ['Surjani', 'Godown', 'Factory'];

  final _dateCtrl = TextEditingController();
  final _customerCtrl = TextEditingController();
  final _customerFocus = FocusNode();
  final _plotCtrl = TextEditingController();
  final _plotFocus = FocusNode();
  final _qtyCtrl = TextEditingController();
  final _brandCtrl = TextEditingController();
  final _brandFocus = FocusNode();
  final _noteCtrl = TextEditingController();
  late final String _orderId;
  String _bagType = kItemTypes.first;
  String _site = _sites.first;
  bool _saving = false;
  bool _suggestionsLoading = false;
  InvoiceDraftSuggestions _suggestions = const InvoiceDraftSuggestions.empty();

  bool get _isEditing => widget.order != null;

  @override
  void initState() {
    super.initState();
    final order = widget.order;
    _orderId = order?.id ?? MobileAccessStore.nextOrderId();
    if (order != null) {
      _dateCtrl.text = order.orderDate;
      _customerCtrl.text = order.customerName;
      _plotCtrl.text = order.plotNo;
      _qtyCtrl.text = order.bagsQuantity <= 0 ? '' : '${order.bagsQuantity}';
      _bagType = kItemTypes.contains(order.bagsType)
          ? order.bagsType
          : kItemTypes.first;
      _brandCtrl.text = order.bagsBrand;
      _noteCtrl.text = order.note;
      _site = _sites.contains(order.orderSite) ? order.orderSite : _sites.first;
    } else {
      _dateCtrl.text = DateTime.now().toIso8601String().split('T').first;
    }
    if (!_isEditing) {
      unawaited(_loadSuggestions());
    }
  }

  @override
  void dispose() {
    _dateCtrl.dispose();
    _customerCtrl.dispose();
    _customerFocus.dispose();
    _plotCtrl.dispose();
    _plotFocus.dispose();
    _qtyCtrl.dispose();
    _brandCtrl.dispose();
    _brandFocus.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSuggestions() async {
    if (_suggestionsLoading || _suggestions.customers.isNotEmpty) return;
    _suggestionsLoading = true;
    final InvoiceDraftSuggestions suggestions;
    try {
      suggestions = await InvoiceDraftSuggestions.load();
    } finally {
      _suggestionsLoading = false;
    }
    if (!mounted) return;
    setState(() => _suggestions = suggestions);
  }

  Iterable<String> _brandOptions(String query) {
    return _suggestions.brandOptionsFor(_site, _bagType, query);
  }

  Iterable<String> _plotOptions(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return _suggestions.addressSuggestions;
    return _suggestions.addressSuggestions
        .where((address) => address.toLowerCase().contains(q));
  }

  Iterable<String> _customerOptions(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return _suggestions.unifiedCustomers;
    return _suggestions.unifiedCustomers
        .where((customer) => customer.toLowerCase().contains(q));
  }

  String _customerNameFromOption(String option) {
    final parts = option
        .split(' - ')
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.length >= 2) return parts[1];
    return option.trim();
  }

  Future<void> _pickOrderDate() async {
    final now = DateTime.now();
    final selected = DateTime.tryParse(_dateCtrl.text.trim()) ??
        DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: selected,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1),
    );
    if (picked == null) return;
    _dateCtrl.text = picked.toIso8601String().split('T').first;
  }

  Future<void> _save() async {
    if (_saving) return;
    final orderDate = _dateCtrl.text.trim();
    final customerName = _customerCtrl.text.trim();
    final plotNo = _plotCtrl.text.trim();
    final qty = int.tryParse(_qtyCtrl.text.trim()) ?? 0;
    final brand = _brandCtrl.text.trim();
    final note = _noteCtrl.text.trim();
    if (orderDate.isEmpty || plotNo.isEmpty || qty <= 0 || brand.isEmpty) {
      showErr(context, 'Date, plot, quantity, and brand are required.');
      return;
    }
    setState(() => _saving = true);
    try {
      final siteKey = _site.toLowerCase();
      final cleanTruckId = (siteKey == 'surjani' || siteKey == 'factory')
          ? widget.order?.assignedTruckId ?? ''
          : '';
      final cleanTruckNo =
          cleanTruckId.isEmpty ? '' : widget.order?.assignedTruckNo ?? '';
      final config = await MobileAccessStore.loadServerConfig();
      await ServerSyncClient.saveOrder(
        baseUrl: config.baseUrl,
        username: widget.user.username,
        passcode: widget.user.passcode,
        payload: {
          'id': _orderId,
          'orderDate': orderDate,
          'customerName': customerName,
          'plotNo': plotNo,
          'bagsQuantity': qty,
          'bagsType': _bagType,
          'bagsBrand': brand,
          'orderSite': _site,
          'assignedTruckId': cleanTruckId,
          'assignedTruckNo': cleanTruckNo,
          'note': note,
        },
      );
      if (!mounted) return;
      showOk(context, _isEditing ? 'Order updated.' : 'Order sent.');
      Navigator.of(context).pop(true);
    } on ServerSyncException catch (e) {
      if (!mounted) return;
      showErr(context, e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _setStatus(MobileOrderStatus status) async {
    final order = widget.order;
    if (order == null) return;
    setState(() => _saving = true);
    try {
      final config = await MobileAccessStore.loadServerConfig();
      final result = await ServerSyncClient.updateOrderStatus(
        baseUrl: config.baseUrl,
        username: widget.user.username,
        passcode: widget.user.passcode,
        orderId: order.id,
        status: status,
      );
      if (result.order.status != status) {
        throw ServerSyncException(
          'Server kept this order ${mobileOrderStatusLabel(result.order.status)}. Sync orders and try again.',
        );
      }
      if (!mounted) return;
      showOk(context, 'Order marked ${mobileOrderStatusLabel(status)}.');
      Navigator.of(context).pop(true);
    } on ServerSyncException catch (e) {
      if (!mounted) return;
      showErr(context, e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<_OrderInvoiceAmountInput?> _askInvoiceRate() async {
    final rateCtrl = TextEditingController();
    final cartageCtrl = TextEditingController();
    try {
      return await showDialog<_OrderInvoiceAmountInput>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Rate & Cartage'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: rateCtrl,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Rate'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: cartageCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration:
                    const InputDecoration(labelText: 'Cartage (optional)'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final rate = double.tryParse(rateCtrl.text.trim()) ?? 0;
                if (rate <= 0) return;
                Navigator.of(dialogContext).pop(
                  _OrderInvoiceAmountInput(
                    rate: rate,
                    cartage: double.tryParse(cartageCtrl.text.trim()) ?? 0,
                  ),
                );
              },
              child: const Text('Submit'),
            ),
          ],
        ),
      );
    } finally {
      _disposeDialogTextControllers([rateCtrl, cartageCtrl]);
    }
  }

  void _disposeDialogTextControllers(
    List<TextEditingController> controllers,
  ) {
    unawaited(Future<void>.delayed(const Duration(milliseconds: 400), () {
      for (final controller in controllers) {
        controller.dispose();
      }
    }));
  }

  Future<_OrderInvoiceCustomerInput?> _askInvoiceCustomerAndRate() async {
    final nameCtrl = TextEditingController(
      text: widget.order?.customerName.trim() ?? '',
    );
    final contactCtrl = TextEditingController();
    final rateCtrl = TextEditingController();
    final cartageCtrl = TextEditingController();
    try {
      return await showDialog<_OrderInvoiceCustomerInput>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Customer & Rate'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Customer Name'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: contactCtrl,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Contact'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: rateCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Rate'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: cartageCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration:
                    const InputDecoration(labelText: 'Cartage (optional)'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final name = nameCtrl.text.trim();
                final rate = double.tryParse(rateCtrl.text.trim()) ?? 0;
                if (name.isEmpty || rate <= 0) return;
                Navigator.of(dialogContext).pop(
                  _OrderInvoiceCustomerInput(
                    name: name,
                    contact: contactCtrl.text.trim(),
                    rate: rate,
                    cartage: double.tryParse(cartageCtrl.text.trim()) ?? 0,
                  ),
                );
              },
              child: const Text('Submit'),
            ),
          ],
        ),
      );
    } finally {
      _disposeDialogTextControllers([
        nameCtrl,
        contactCtrl,
        rateCtrl,
        cartageCtrl,
      ]);
    }
  }

  Future<void> _recordDeliveredInvoice({double? rate, double? cartage}) async {
    final order = widget.order;
    if (order == null || _saving) return;
    setState(() => _saving = true);
    try {
      final config = await MobileAccessStore.loadServerConfig();
      final result = await ServerSyncClient.recordOrderInvoice(
        baseUrl: config.baseUrl,
        username: widget.user.username,
        passcode: widget.user.passcode,
        orderId: order.id,
        rate: rate,
        cartage: cartage,
      );
      final invoiceNo = result.order.recordedInvoiceNo;
      if (invoiceNo == null) {
        throw const ServerSyncException('Invoice number was not returned.');
      }
      if (!mounted) return;
      showOk(context, 'Invoice #$invoiceNo recorded.');
      Navigator.of(context).pop(true);
    } on ServerSyncException catch (e) {
      if (!mounted) return;
      if (rate == null && e.message.toLowerCase().contains('rate')) {
        setState(() => _saving = false);
        final input = await _askInvoiceRate();
        if (!mounted || input == null) return;
        await _recordDeliveredInvoice(
          rate: input.rate,
          cartage: input.cartage,
        );
        return;
      }
      if (e.message.toLowerCase().contains('customer')) {
        setState(() => _saving = false);
        final input = await _askInvoiceCustomerAndRate();
        if (!mounted || input == null) return;
        await _recordDeliveredInvoiceWithCustomer(input);
        return;
      }
      showErr(context, e.message);
    } finally {
      if (mounted && _saving) setState(() => _saving = false);
    }
  }

  Future<void> _recordDeliveredInvoiceWithCustomer(
    _OrderInvoiceCustomerInput input,
  ) async {
    final order = widget.order;
    if (order == null || _saving) return;
    setState(() => _saving = true);
    try {
      final config = await MobileAccessStore.loadServerConfig();
      final result = await ServerSyncClient.recordOrderInvoice(
        baseUrl: config.baseUrl,
        username: widget.user.username,
        passcode: widget.user.passcode,
        orderId: order.id,
        rate: input.rate,
        cartage: input.cartage,
        customerName: input.name,
        customerContact: input.contact,
      );
      final invoiceNo = result.order.recordedInvoiceNo;
      if (invoiceNo == null) {
        throw const ServerSyncException('Invoice number was not returned.');
      }
      if (!mounted) return;
      showOk(context, 'Invoice #$invoiceNo recorded.');
      Navigator.of(context).pop(true);
    } on ServerSyncException catch (e) {
      if (!mounted) return;
      showErr(context, e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<_OrderInvoiceAmountInput?> _askRecordedInvoiceEdit() async {
    final invoiceNo = widget.order?.recordedInvoiceNo;
    if (invoiceNo == null) return null;
    final invoices = await Store.loadAll();
    final invoice = invoices.cast<Invoice?>().firstWhere(
          (item) => item != null && item.sNo == invoiceNo,
          orElse: () => null,
        );
    final rate = invoice == null || invoice.lines.isEmpty
        ? ''
        : invoice.lines.first.rate.toStringAsFixed(0);
    final cartage = invoice == null || invoice.cartage <= 0
        ? ''
        : invoice.cartage.toStringAsFixed(0);
    final rateCtrl = TextEditingController(text: rate);
    final cartageCtrl = TextEditingController(text: cartage);
    try {
      if (!mounted) return null;
      return await showDialog<_OrderInvoiceAmountInput>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Edit Invoice #$invoiceNo'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: rateCtrl,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Rate'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: cartageCtrl,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration:
                    const InputDecoration(labelText: 'Cartage (optional)'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final nextRate = double.tryParse(rateCtrl.text.trim()) ?? 0;
                if (nextRate <= 0) return;
                Navigator.of(dialogContext).pop(
                  _OrderInvoiceAmountInput(
                    rate: nextRate,
                    cartage: double.tryParse(cartageCtrl.text.trim()) ?? 0,
                  ),
                );
              },
              child: const Text('Save'),
            ),
          ],
        ),
      );
    } finally {
      _disposeDialogTextControllers([rateCtrl, cartageCtrl]);
    }
  }

  Future<void> _editRecordedInvoice() async {
    final order = widget.order;
    if (order == null || _saving) return;
    final input = await _askRecordedInvoiceEdit();
    if (!mounted || input == null) return;
    setState(() => _saving = true);
    try {
      final config = await MobileAccessStore.loadServerConfig();
      final result = await ServerSyncClient.recordOrderInvoice(
        baseUrl: config.baseUrl,
        username: widget.user.username,
        passcode: widget.user.passcode,
        orderId: order.id,
        rate: input.rate,
        cartage: input.cartage,
      );
      final invoiceNo = result.order.recordedInvoiceNo;
      if (invoiceNo == null) {
        throw const ServerSyncException('Invoice number was not returned.');
      }
      if (!mounted) return;
      showOk(context, 'Invoice #$invoiceNo updated.');
      Navigator.of(context).pop(true);
    } on ServerSyncException catch (e) {
      if (!mounted) return;
      showErr(context, e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _sendRecordedInvoicePdf() async {
    final invoiceNo = widget.order?.recordedInvoiceNo;
    if (invoiceNo == null) return;
    setState(() => _saving = true);
    try {
      final invoices = await Store.loadAll();
      final invoice = invoices.cast<Invoice?>().firstWhere(
            (item) => item != null && item.sNo == invoiceNo,
            orElse: () => null,
          );
      if (invoice == null) {
        if (!mounted) return;
        showErr(context, 'Invoice #$invoiceNo not found. Sync and try again.');
        return;
      }
      if (!mounted) return;
      setState(() => _saving = false);
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => InvoiceScreen(
            editing: true,
            initialInvoice: invoice,
            pdfOnlyShare: true,
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      showErr(context, 'Could not open invoice: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _returnRecordedInvoice() async {
    final invoiceNo = widget.order?.recordedInvoiceNo;
    if (invoiceNo == null || _saving) return;
    setState(() => _saving = true);
    try {
      final invoices = await Store.loadAll();
      final invoice = invoices.cast<Invoice?>().firstWhere(
            (item) => item != null && item.sNo == invoiceNo,
            orElse: () => null,
          );
      if (invoice == null) {
        if (!mounted) return;
        showErr(context, 'Invoice #$invoiceNo not found. Sync and try again.');
        return;
      }
      if (!mounted) return;
      setState(() => _saving = false);
      final result = await Navigator.of(context).push<Invoice?>(
        MaterialPageRoute(
          builder: (_) => InvoiceScreen(
            editing: true,
            initialInvoice: invoice,
            startReturnFlow: true,
            draftUser: widget.user,
          ),
        ),
      );
      if (!mounted) return;
      if (result != null && result.isReturn) {
        showOk(context, 'Return #${result.sNo} recorded.');
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (!mounted) return;
      showErr(context, 'Could not record return: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _deleteOrder() async {
    final order = widget.order;
    if (order == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Order'),
        content: Text(
          'Delete plot ${order.plotNo}? This order will be removed completely.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _saving = true);
    try {
      final config = await MobileAccessStore.loadServerConfig();
      await ServerSyncClient.deleteOrder(
        baseUrl: config.baseUrl,
        username: widget.user.username,
        passcode: widget.user.passcode,
        orderId: order.id,
      );
      if (!mounted) return;
      showOk(context, 'Order deleted.');
      Navigator.of(context).pop(true);
    } on ServerSyncException catch (e) {
      if (!mounted) return;
      showErr(context, e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Color _statusColor(MobileOrderStatus status) {
    switch (status) {
      case MobileOrderStatus.delivered:
        return const Color(0xFF17A673);
      case MobileOrderStatus.cancelled:
        return const Color(0xFFE15241);
      case MobileOrderStatus.pending:
        return const Color(0xFFE6A700);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isEditing ? 'Edit Order' : 'Send Order')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _dateCtrl,
            readOnly: true,
            onTap: _pickOrderDate,
            decoration: const InputDecoration(
              labelText: 'Order Date',
              suffixIcon: Icon(Icons.calendar_today, size: 18),
            ),
          ),
          const SizedBox(height: 12),
          RawAutocomplete<String>(
            textEditingController: _customerCtrl,
            focusNode: _customerFocus,
            optionsBuilder: (text) => _customerOptions(text.text),
            onSelected: (value) =>
                _customerCtrl.text = _customerNameFromOption(value),
            fieldViewBuilder: (context, controller, focusNode, onSubmitted) {
              return TextField(
                controller: controller,
                focusNode: focusNode,
                onTap: () => unawaited(_loadSuggestions()),
                decoration:
                    const InputDecoration(labelText: 'Customer (optional)'),
              );
            },
            optionsViewBuilder: (context, onSelected, options) {
              return Align(
                alignment: Alignment.topLeft,
                child: Material(
                  elevation: 4,
                  child: ConstrainedBox(
                    constraints:
                        const BoxConstraints(maxHeight: 220, maxWidth: 320),
                    child: ListView.builder(
                      padding: EdgeInsets.zero,
                      shrinkWrap: true,
                      itemCount: options.length,
                      itemBuilder: (context, index) {
                        final option = options.elementAt(index);
                        return ListTile(
                          dense: true,
                          title: Text(option),
                          onTap: () => onSelected(option),
                        );
                      },
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          RawAutocomplete<String>(
            textEditingController: _plotCtrl,
            focusNode: _plotFocus,
            optionsBuilder: (text) => _plotOptions(text.text),
            onSelected: (value) => _plotCtrl.text = value,
            fieldViewBuilder: (context, controller, focusNode, onSubmitted) {
              return TextField(
                controller: controller,
                focusNode: focusNode,
                onTap: () => unawaited(_loadSuggestions()),
                decoration: const InputDecoration(labelText: 'Plot No'),
              );
            },
            optionsViewBuilder: (context, onSelected, options) {
              return Align(
                alignment: Alignment.topLeft,
                child: Material(
                  elevation: 4,
                  child: ConstrainedBox(
                    constraints:
                        const BoxConstraints(maxHeight: 220, maxWidth: 320),
                    child: ListView.builder(
                      padding: EdgeInsets.zero,
                      shrinkWrap: true,
                      itemCount: options.length,
                      itemBuilder: (context, index) {
                        final option = options.elementAt(index);
                        return ListTile(
                          dense: true,
                          title: Text(option),
                          onTap: () => onSelected(option),
                        );
                      },
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _qtyCtrl,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: 'Bags Quantity'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _bagType,
            decoration: const InputDecoration(labelText: 'Bags Type'),
            items: kItemTypes
                .map((type) => DropdownMenuItem(value: type, child: Text(type)))
                .toList(),
            onChanged: (value) {
              if (value == null) return;
              setState(() => _bagType = value);
            },
          ),
          const SizedBox(height: 12),
          RawAutocomplete<String>(
            textEditingController: _brandCtrl,
            focusNode: _brandFocus,
            optionsBuilder: (text) => _brandOptions(text.text),
            onSelected: (value) => _brandCtrl.text = value,
            fieldViewBuilder: (context, controller, focusNode, onSubmitted) {
              return TextField(
                controller: controller,
                focusNode: focusNode,
                onTap: () => unawaited(_loadSuggestions()),
                decoration: const InputDecoration(labelText: 'Bags Brand'),
              );
            },
            optionsViewBuilder: (context, onSelected, options) {
              return Align(
                alignment: Alignment.topLeft,
                child: Material(
                  elevation: 4,
                  child: ConstrainedBox(
                    constraints:
                        const BoxConstraints(maxHeight: 220, maxWidth: 320),
                    child: ListView.builder(
                      padding: EdgeInsets.zero,
                      shrinkWrap: true,
                      itemCount: options.length,
                      itemBuilder: (context, index) {
                        final option = options.elementAt(index);
                        return ListTile(
                          dense: true,
                          title: Text(option),
                          onTap: () => onSelected(option),
                        );
                      },
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _site,
            decoration: const InputDecoration(labelText: 'Order Site'),
            items: _sites
                .map((site) => DropdownMenuItem(value: site, child: Text(site)))
                .toList(),
            onChanged: (value) {
              if (value == null) return;
              setState(() => _site = value);
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _noteCtrl,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'Note'),
          ),
          if (_isEditing) ...[
            const SizedBox(height: 16),
            _DetailCard(
              title: 'Status',
              trailing: AppStatusPill(
                text: mobileOrderStatusLabel(widget.order!.status),
                color: _statusColor(widget.order!.status),
              ),
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _saving ||
                              widget.order!.status == MobileOrderStatus.pending
                          ? null
                          : () => _setStatus(MobileOrderStatus.pending),
                      icon: const Icon(Icons.pending_actions_outlined),
                      label: const Text('Pending'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _saving ||
                              widget.order!.status ==
                                  MobileOrderStatus.delivered
                          ? null
                          : () => _setStatus(MobileOrderStatus.delivered),
                      icon: const Icon(Icons.local_shipping_outlined),
                      label: const Text('Delivered'),
                    ),
                    OutlinedButton.icon(
                      onPressed: _saving ||
                              widget.order!.status ==
                                  MobileOrderStatus.cancelled
                          ? null
                          : () => _setStatus(MobileOrderStatus.cancelled),
                      icon: const Icon(Icons.cancel_outlined),
                      label: const Text('Cancel'),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            _DetailCard(
              title: 'Order History',
              children: [
                _detailRow('Given by', widget.order!.createdByName),
                _detailRow('Edited by', widget.order!.updatedByName),
                _detailRow('Last edit', widget.order!.updatedAt),
                _detailRow(
                  'Status',
                  mobileOrderStatusLabel(widget.order!.status),
                ),
                _detailRow(
                  'Note',
                  widget.order!.note.trim().isEmpty
                      ? '-'
                      : widget.order!.note.trim(),
                ),
                _detailRow(
                  'Marked by',
                  widget.order!.statusUpdatedByName,
                ),
                if (widget.order!.recordedInvoiceNo != null) ...[
                  _detailRow(
                    'Recorded',
                    'Invoice #${widget.order!.recordedInvoiceNo}',
                  ),
                  _detailRow(
                    'Recorded at',
                    widget.order!.recordedInvoiceAt ?? '-',
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            if (widget.order!.recordedInvoiceNo != null) ...[
              FilledButton.icon(
                onPressed: _saving ? null : _sendRecordedInvoicePdf,
                icon: const Icon(Icons.picture_as_pdf_outlined),
                label: const Text('Send Invoice'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _saving ? null : _editRecordedInvoice,
                icon: const Icon(Icons.edit_note_outlined),
                label: const Text('Edit Entry'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                onPressed: _saving ? null : _returnRecordedInvoice,
                icon: const Icon(Icons.assignment_return_outlined),
                label: const Text('Return'),
              ),
              const SizedBox(height: 12),
            ] else if (widget.order!.status == MobileOrderStatus.delivered) ...[
              FilledButton.icon(
                onPressed: _saving ? null : _recordDeliveredInvoice,
                icon: const Icon(Icons.receipt_long_outlined),
                label: const Text('Record Invoice'),
              ),
              const SizedBox(height: 12),
            ],
            OutlinedButton.icon(
              style: appDangerOutlineButtonStyle(context),
              onPressed: _saving ? null : _deleteOrder,
              icon: const Icon(Icons.delete_outline),
              label: const Text('Delete order'),
            ),
          ],
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: const Icon(Icons.check),
            label: Text(_saving
                ? 'Saving...'
                : (_isEditing ? 'Save order' : 'Send order')),
          ),
        ],
      ),
    );
  }
}

class _OrderInvoiceAmountInput {
  final double rate;
  final double cartage;

  const _OrderInvoiceAmountInput({
    required this.rate,
    required this.cartage,
  });
}

class _OrderInvoiceCustomerInput {
  final String name;
  final String contact;
  final double rate;
  final double cartage;

  const _OrderInvoiceCustomerInput({
    required this.name,
    required this.contact,
    required this.rate,
    required this.cartage,
  });
}

class MobileSyncSettingsTab extends StatefulWidget {
  final AppUser user;

  const MobileSyncSettingsTab({super.key, required this.user});

  @override
  State<MobileSyncSettingsTab> createState() => _MobileSyncSettingsTabState();
}

class _MobileSyncSettingsTabState extends State<MobileSyncSettingsTab> {
  final _baseUrlCtrl = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  bool _testing = false;
  bool _pulling = false;
  bool _fullSyncing = false;
  bool _resetting = false;
  bool _checkingLocation = false;
  bool _requestingLocation = false;
  bool _locationServiceEnabled = false;
  LocationPermission _locationPermission = LocationPermission.unableToDetermine;
  ServerSyncConfig _config = const ServerSyncConfig();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _baseUrlCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final config = await MobileAccessStore.loadServerConfig();
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    final permission = await Geolocator.checkPermission();
    if (!mounted) return;
    setState(() {
      _config = config;
      _baseUrlCtrl.text = config.baseUrl;
      _locationServiceEnabled = serviceEnabled;
      _locationPermission = permission;
      _loading = false;
    });
  }

  Future<void> _refreshLocationPermission() async {
    setState(() => _checkingLocation = true);
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    final permission = await Geolocator.checkPermission();
    if (!mounted) return;
    setState(() {
      _locationServiceEnabled = serviceEnabled;
      _locationPermission = permission;
      _checkingLocation = false;
    });
  }

  Future<void> _requestAlwaysLocation() async {
    setState(() => _requestingLocation = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        await Geolocator.openLocationSettings();
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.whileInUse) {
        permission = await Geolocator.requestPermission();
      }
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!mounted) return;
      setState(() {
        _locationServiceEnabled = serviceEnabled;
        _locationPermission = permission;
      });
      if (permission == LocationPermission.deniedForever ||
          permission == LocationPermission.whileInUse) {
        await Geolocator.openAppSettings();
      }
    } finally {
      if (mounted) setState(() => _requestingLocation = false);
    }
  }

  String _locationPermissionLabel() {
    if (!_locationServiceEnabled) return 'Location service off';
    switch (_locationPermission) {
      case LocationPermission.always:
        return 'Always allowed';
      case LocationPermission.whileInUse:
        return 'Allowed while using app';
      case LocationPermission.denied:
        return 'Not allowed';
      case LocationPermission.deniedForever:
        return 'Blocked in settings';
      case LocationPermission.unableToDetermine:
        return 'Not checked';
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final updated = _config.copyWith(
      baseUrl: _baseUrlCtrl.text.trim(),
      enabled: _baseUrlCtrl.text.trim().isNotEmpty,
      lastStatus: 'Saved mobile server URL.',
    );
    await MobileAccessStore.saveServerConfig(updated);
    if (!mounted) return;
    setState(() {
      _config = updated;
      _saving = false;
    });
    showOk(context, 'Server settings saved.');
  }

  Future<void> _testServer() async {
    setState(() => _testing = true);
    try {
      await ServerSyncClient.testConnection(_baseUrlCtrl.text.trim());
      if (!mounted) return;
      showOk(context, 'Laptop server is reachable.');
    } on ServerSyncException catch (e) {
      if (!mounted) return;
      showErr(context, e.message);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _pullSnapshot() async {
    setState(() => _pulling = true);
    try {
      final result = await ServerSyncClient.syncReadOnlyData(
        baseUrl: _baseUrlCtrl.text.trim(),
        username: widget.user.username,
        passcode: widget.user.passcode,
      );
      if (!mounted) return;
      showOk(
        context,
        'Imported ${result.invoiceCount} invoices and ${result.paymentCount} payments.',
      );
      AppBus.bump();
      await _load();
    } on ServerSyncException catch (e) {
      if (!mounted) return;
      showErr(context, e.message);
    } finally {
      if (mounted) {
        setState(() => _pulling = false);
      }
    }
  }

  Future<void> _fullResync() async {
    setState(() => _fullSyncing = true);
    try {
      final result = await ServerSyncClient.syncReadOnlyData(
        baseUrl: _baseUrlCtrl.text.trim(),
        username: widget.user.username,
        passcode: widget.user.passcode,
        forceFull: true,
      );
      if (!mounted) return;
      showOk(
        context,
        'Full resynced ${result.invoiceCount} invoices and ${result.paymentCount} payments.',
      );
      AppBus.bump();
      await _load();
    } on ServerSyncException catch (e) {
      if (!mounted) return;
      showErr(context, e.message);
    } finally {
      if (mounted) {
        setState(() => _fullSyncing = false);
      }
    }
  }

  Future<void> _resetOffset() async {
    setState(() => _resetting = true);
    await MobileAccessStore.saveServerConfig(
      _config.copyWith(
        lastSyncAt: null,
        clearLastSyncAt: true,
        lastStatus: null,
        clearLastStatus: true,
      ),
    );
    if (!mounted) return;
    setState(() => _resetting = false);
    showOk(context, 'Server sync status reset.');
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const AppSkeletonLoader();
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Laptop Server Sync',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _baseUrlCtrl,
                  decoration:
                      const InputDecoration(labelText: 'Server base URL'),
                ),
                const SizedBox(height: 14),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: Text(_saving ? 'Saving...' : 'Save settings'),
                ),
                const SizedBox(height: 10),
                OutlinedButton(
                  onPressed: _testing ? null : _testServer,
                  child: Text(_testing ? 'Testing...' : 'Test server'),
                ),
                const SizedBox(height: 10),
                OutlinedButton(
                  onPressed:
                      _pulling || !_config.enabled ? null : _pullSnapshot,
                  child: Text(_pulling ? 'Syncing...' : 'Pull changes'),
                ),
                const SizedBox(height: 10),
                OutlinedButton(
                  onPressed:
                      _fullSyncing || !_config.enabled ? null : _fullResync,
                  child: Text(_fullSyncing ? 'Resyncing...' : 'Full resync'),
                ),
                const SizedBox(height: 10),
                OutlinedButton(
                  onPressed: _resetting ? null : _resetOffset,
                  child: Text(_resetting ? 'Resetting...' : 'Reset status'),
                ),
                const SizedBox(height: 10),
                Text(
                  _config.lastSyncAt == null
                      ? 'Last sync: not synced yet'
                      : 'Last sync: ${_config.lastSyncAt}',
                ),
                const SizedBox(height: 6),
                if ((_config.lastStatus ?? '').isNotEmpty)
                  Text('Server status: ${_config.lastStatus}'),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Location Permission',
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                AppMetaChip(
                  icon: Icons.location_on_outlined,
                  text: _locationPermissionLabel(),
                  foregroundColor:
                      _locationPermission == LocationPermission.always
                          ? const Color(0xFF17A673)
                          : const Color(0xFFE6A700),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    FilledButton.icon(
                      onPressed:
                          _requestingLocation ? null : _requestAlwaysLocation,
                      icon: const Icon(Icons.my_location_outlined),
                      label: Text(_requestingLocation
                          ? 'Requesting...'
                          : 'Allow always'),
                    ),
                    OutlinedButton.icon(
                      onPressed:
                          _checkingLocation ? null : _refreshLocationPermission,
                      icon: const Icon(Icons.refresh),
                      label: Text(_checkingLocation ? 'Checking...' : 'Check'),
                    ),
                    OutlinedButton.icon(
                      onPressed: Geolocator.openAppSettings,
                      icon: const Icon(Icons.settings_outlined),
                      label: const Text('App settings'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class MobileInvoiceDetailScreen extends StatelessWidget {
  final Invoice invoice;
  final AppUser user;

  const MobileInvoiceDetailScreen({
    super.key,
    required this.invoice,
    required this.user,
  });

  Future<void> _deleteReturn(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete Return'),
        content: Text(
          'Delete return #${invoice.sNo}? Its ledger, history and godown effects will also be removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      final config = await MobileAccessStore.loadServerConfig();
      await ServerSyncClient.deleteInvoiceReturn(
        baseUrl: config.baseUrl,
        username: user.username,
        passcode: user.passcode,
        invoiceNo: invoice.sNo,
      );
      if (!context.mounted) return;
      showOk(context, 'Return #${invoice.sNo} deleted.');
      Navigator.of(context).pop(true);
    } on ServerSyncException catch (e) {
      if (!context.mounted) return;
      showErr(context, e.message);
    }
  }

  Future<void> _sendPdf(BuildContext context) async {
    try {
      final bytes = await PdfBuilder.build(invoice);
      final dir = await subdir('invoices');
      final file = File(
        '${dir.path}${Platform.pathSeparator}invoice_${invoice.sNo}.pdf',
      );
      await file.writeAsBytes(bytes, flush: true);
      await Share.shareXFiles(
        [XFile(file.path)],
        text: 'Invoice #${invoice.sNo}',
      );
    } catch (_) {
      if (!context.mounted) return;
      showErr(context, 'Could not send PDF.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isReturn = invoice.isReturn;
    const returnColor = Color(0xFFC62828);
    return Scaffold(
      appBar: AppBar(
        title: Text(
            isReturn ? 'Return #${invoice.sNo}' : 'Invoice #${invoice.sNo}'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _DetailCard(
            title: invoice.customer,
            subtitle: isReturn
                ? 'Return #${invoice.sNo} of Invoice #${invoice.returnOfInvoiceNo ?? '-'}'
                : 'Invoice #${invoice.sNo}',
            trailing: AppStatusPill(
              text: isReturn
                  ? 'RETURN Rs ${fmt0(invoice.balance.abs())}'
                  : 'Rs ${fmt0(invoice.balance)}',
              color: isReturn ? returnColor : const Color(0xFF4B5DFF),
            ),
            children: [
              if (isReturn)
                _detailRow(
                  'Original invoice',
                  '#${invoice.returnOfInvoiceNo ?? '-'}',
                ),
              _detailRow('Customer ID', invoice.customerId),
              _detailRow('Contact', invoice.contact),
              _detailRow('Address', invoice.address),
              _detailRow('Site', invoice.site),
              _detailRow('Date', invoice.date),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => _sendPdf(context),
                icon: const Icon(Icons.ios_share_outlined),
                label: const Text('Send PDF'),
              ),
              if (isReturn) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => _deleteReturn(context),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete return'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: returnColor,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          _DetailCard(
            title: isReturn ? 'Returned items' : 'Items',
            children: invoice.lines
                .where((line) => line.qty != 0)
                .map(
                  (line) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: AppSoftCard(
                      padding: const EdgeInsets.all(12),
                      backgroundColor: Colors.white,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  line.typeLabel,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: Color(0xFF172033),
                                  ),
                                ),
                              ),
                              Text(
                                'Rs ${fmt0(isReturn ? line.amount.abs() : line.amount)}',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: isReturn ? returnColor : null,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Text(
                            line.brand.isEmpty ? '-' : line.brand,
                            style: const TextStyle(color: Color(0xFF566074)),
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              AppMetaChip(
                                text: isReturn
                                    ? 'Returned ${line.qty.abs()}'
                                    : 'Qty ${line.qty}',
                                foregroundColor: isReturn
                                    ? returnColor
                                    : const Color(0xFF364056),
                                backgroundColor: isReturn
                                    ? const Color(0xFFFFEBEE)
                                    : Colors.white,
                              ),
                              AppMetaChip(text: 'Rate ${fmt0(line.rate)}'),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
          const SizedBox(height: 12),
          _DetailCard(
            title: isReturn ? 'Return total' : 'Totals',
            children: isReturn
                ? [
                    _detailRow(
                      'Returned value',
                      'Rs ${fmt0(invoice.balance.abs())}',
                    ),
                    _detailRow('Stock destination', 'Godown'),
                  ]
                : [
                    _detailRow('Items total', 'Rs ${fmt0(invoice.total)}'),
                    _detailRow('Cartage', 'Rs ${fmt0(invoice.cartage)}'),
                    _detailRow('Bill total', 'Rs ${fmt0(invoice.balance)}'),
                    _detailRow('Paid', 'Rs ${fmt0(invoice.paid)}'),
                    _detailRow('Remaining', 'Rs ${fmt0(invoice.remaining)}'),
                  ],
          ),
        ],
      ),
    );
  }
}

class MobilePaymentDetailScreen extends StatelessWidget {
  final PaymentEntry payment;

  const MobilePaymentDetailScreen({super.key, required this.payment});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Payment Detail')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _DetailCard(
            title: payment.customer,
            trailing: AppStatusPill(
              text: paymentTypeLabel(payment.type),
              color: const Color(0xFF17A673),
            ),
            children: [
              _detailRow('Date', payment.date),
              _detailRow('Type', paymentTypeLabel(payment.type)),
              _detailRow('Amount', 'Rs ${fmt0(payment.amount)}'),
              _detailRow('Discount', 'Rs ${fmt0(payment.discount)}'),
              _detailRow('Effective', 'Rs ${fmt0(payment.effectiveAmount)}'),
              _detailRow('Bank', payment.bank ?? '-'),
              _detailRow('Cheque No', payment.chequeNo ?? '-'),
              _detailRow('Txn ID', payment.txnId ?? '-'),
              _detailRow('Note', payment.note ?? '-'),
            ],
          ),
        ],
      ),
    );
  }
}

class MobileCustomerDetailScreen extends StatefulWidget {
  final Customer customer;
  final AppUser user;

  const MobileCustomerDetailScreen({
    super.key,
    required this.customer,
    required this.user,
  });

  @override
  State<MobileCustomerDetailScreen> createState() =>
      _MobileCustomerDetailScreenState();
}

class _MobileCustomerDetailScreenState
    extends State<MobileCustomerDetailScreen> {
  bool _loading = true;
  List<Invoice> _invoices = const [];
  List<PaymentEntry> _payments = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final invoices = await Store.loadAll();
    final payments = await PaymentStore.loadAll();
    final key = widget.customer.id.trim().isNotEmpty
        ? widget.customer.id.trim().toLowerCase()
        : widget.customer.name.trim().toLowerCase();
    final filteredInvoices = invoices.where((invoice) {
      final invoiceKey = (invoice.customerId.isNotEmpty
              ? invoice.customerId
              : invoice.customer)
          .trim()
          .toLowerCase();
      return invoiceKey == key;
    }).toList()
      ..sort((a, b) => b.sNo.compareTo(a.sNo));
    final filteredPayments = payments.where((payment) {
      final paymentKey = (payment.customerId.isNotEmpty
              ? payment.customerId
              : payment.customer)
          .trim()
          .toLowerCase();
      return paymentKey == key;
    }).toList()
      ..sort((a, b) => b.id.compareTo(a.id));
    if (!mounted) return;
    setState(() {
      _invoices = filteredInvoices;
      _payments = filteredPayments;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final totalSales =
        _invoices.fold<double>(0, (sum, invoice) => sum + invoice.balance);
    final totalPaid = _payments.fold<double>(
      0,
      (sum, payment) => sum + payment.effectiveAmount,
    );
    return Scaffold(
      appBar: AppBar(title: Text(widget.customer.name)),
      body: _loading
          ? const AppSkeletonLoader()
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _DetailCard(
                  title: widget.customer.name,
                  subtitle:
                      widget.customer.id.isEmpty ? null : widget.customer.id,
                  trailing: AppStatusPill(
                    text:
                        'Rs ${fmt0((totalSales - totalPaid).clamp(0, double.infinity))}',
                    color: const Color(0xFFFF8A00),
                  ),
                  children: [
                    _detailRow('Phone', widget.customer.contact),
                    _detailRow('Invoices', '${_invoices.length}'),
                    _detailRow('Sales', 'Rs ${fmt0(totalSales)}'),
                    _detailRow('Payments', 'Rs ${fmt0(totalPaid)}'),
                    _detailRow(
                      'Outstanding',
                      'Rs ${fmt0((totalSales - totalPaid).clamp(0, double.infinity))}',
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _DetailCard(
                  title: 'Recent Invoices',
                  children: _invoices.isEmpty
                      ? const [Text('No invoices found.')]
                      : _invoices
                          .take(10)
                          .map(
                            (invoice) => ListTile(
                              contentPadding: EdgeInsets.zero,
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => MobileInvoiceDetailScreen(
                                    invoice: invoice,
                                    user: widget.user,
                                  ),
                                ),
                              ),
                              title: Text('#${invoice.sNo} - ${invoice.date}'),
                              trailing: Text('Rs ${fmt0(invoice.balance)}'),
                            ),
                          )
                          .toList(),
                ),
                const SizedBox(height: 12),
                _DetailCard(
                  title: 'Recent Payments',
                  children: _payments.isEmpty
                      ? const [Text('No payments found.')]
                      : _payments
                          .take(10)
                          .map(
                            (payment) => ListTile(
                              contentPadding: EdgeInsets.zero,
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => MobilePaymentDetailScreen(
                                      payment: payment),
                                ),
                              ),
                              title: Text(payment.date),
                              subtitle: Text(paymentTypeLabel(payment.type)),
                              trailing:
                                  Text('Rs ${fmt0(payment.effectiveAmount)}'),
                            ),
                          )
                          .toList(),
                ),
              ],
            ),
    );
  }
}

class _DetailCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final List<Widget> children;

  const _DetailCard({
    required this.title,
    this.subtitle,
    this.trailing,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return AppSoftCard(
      child: Padding(
        padding: EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppSectionTitle(
              title: title,
              subtitle: subtitle,
              trailing: trailing,
            ),
            const SizedBox(height: 10),
            ...children,
          ],
        ),
      ),
    );
  }
}

Widget _detailRow(String label, String value) {
  final safeValue = value.trim().isEmpty ? '-' : value;
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110,
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        Expanded(child: Text(safeValue)),
      ],
    ),
  );
}
