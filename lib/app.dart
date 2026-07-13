import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:ui' as ui;
import 'dart:io';
import 'package:intl/intl.dart';

import 'services/excel_service.dart';
import 'services/app_update_service.dart';
import 'services/storage.dart';
import 'services/paths.dart';
import 'utils/date.dart';
import 'utils/snackbar.dart';
import 'screens/invoice_screen.dart';
import 'screens/daily_reports_screen.dart';
import 'screens/monthly_reports_screen.dart';
import 'screens/payments_screen.dart';
import 'screens/customer_master_screen.dart';
import 'screens/history_screen.dart';
import 'screens/surjani_ledger_screen.dart';
import 'screens/godown_hisaab_screen.dart';
import 'screens/mobile_access_screen.dart';
import 'screens/mobile_shell.dart';
import 'screens/stats_screen.dart';

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: const ColorScheme.light(
        primary: Color(0xFF087F8C),
        secondary: Color(0xFF2563EB),
        surface: Color(0xFFFFFFFF),
        onPrimary: Colors.white,
        onSurface: Color(0xFF172033),
      ),
      fontFamily: 'Poppins',
      scaffoldBackgroundColor: const Color(0xFFF6F8FB),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF087F8C),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: const Color(0xFF00838F)),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: _QuickPageTransitionsBuilder(),
          TargetPlatform.iOS: _QuickPageTransitionsBuilder(),
          TargetPlatform.windows: _QuickPageTransitionsBuilder(),
          TargetPlatform.macOS: _QuickPageTransitionsBuilder(),
          TargetPlatform.linux: _QuickPageTransitionsBuilder(),
        },
      ),
    );

    final theme = base.copyWith(
      textTheme: base.textTheme.copyWith(
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
        ),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(
          fontSize: 14.5,
          height: 1.32,
        ),
        labelSmall: base.textTheme.labelSmall?.copyWith(
          fontSize: 12,
          letterSpacing: 0.2,
        ),
      ),
      appBarTheme: base.appBarTheme.copyWith(
        titleTextStyle: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        isDense: true,
        fillColor: Color(0xFFFFFFFF),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(7)),
          borderSide: BorderSide(color: Color(0xFFD7DEE8)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(7)),
          borderSide: BorderSide(color: Color(0xFFD7DEE8)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(7)),
          borderSide: BorderSide(color: Color(0xFF087F8C), width: 1.5),
        ),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
      tooltipTheme: const TooltipThemeData(
        waitDuration: Duration(milliseconds: 500),
      ),
      cardTheme: const CardThemeData(
        elevation: 0,
        color: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
          side: BorderSide(color: Color(0xFFE2E8F0)),
        ),
      ),
      dividerTheme: const DividerThemeData(color: Color(0xFFE7ECF2)),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
        ),
      ),
    );

    return MaterialApp(
      title: 'QuickBill Lab',
      theme: theme,
      scrollBehavior: const MaterialScrollBehavior().copyWith(
        dragDevices: {
          ui.PointerDeviceKind.mouse,
          ui.PointerDeviceKind.touch,
          ui.PointerDeviceKind.stylus,
          ui.PointerDeviceKind.trackpad,
          ui.PointerDeviceKind.unknown,
        },
      ),
      home: _isMobilePlatform ? const MobileShell() : const Home(),
    );
  }

  bool get _isMobilePlatform => Platform.isAndroid || Platform.isIOS;
}

class _QuickPageTransitionsBuilder extends PageTransitionsBuilder {
  const _QuickPageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (route.fullscreenDialog) return child;
    final curved = CurvedAnimation(
      parent: animation,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(.025, 0),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int _tab = 0;
  late final List<Widget> _pages;
  final PageStorageBucket _bucket = PageStorageBucket();
  ValueNotifier<_ReexportState>? _reexportProgress;
  bool _checkingForUpdates = false;

  @override
  void initState() {
    super.initState();
    _pages = const [
      InvoiceScreen(),
      DailyReportsScreen(),
      MonthlyReportsScreen(),
      PaymentsScreen(),
      CustomerMasterScreen(),
      HistoryScreen(),
      SurjaniLedgerScreen(),
      GodownHisaabScreen(),
      MobileAccessScreen(),
      StatsScreen(),
    ];

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeRunOneTimeReexport();
    });
  }

  String _tabSubtitle(int t) {
    switch (t) {
      case 0:
        return 'Create and manage invoices';
      case 1:
        return "Today's exports & recent daily files";
      case 2:
        return "This month's summary & history";
      case 3:
        return 'Track payments and pending amounts';
      case 4:
        return 'Customer records and activity';
      case 5:
        return 'Invoice history and backups';
      case 6:
        return 'Surjani, Factory, and custom ledgers';
      case 7:
        return 'Godown opening stock and daily remaining bags';
      case 8:
        return 'Mobile roles, locations, and sync activity';
      default:
        return 'Sales, payments, returns, customers, and stock stats';
    }
  }

  void _goTo(int index) {
    if (index != _tab) setState(() => _tab = index);
  }

  Future<void> _checkForUpdates() async {
    if (_checkingForUpdates) return;
    setState(() => _checkingForUpdates = true);
    try {
      final info = await AppUpdateService.checkForUpdate();
      if (!mounted) return;
      if (info == null) {
        showOk(context, 'No update available.');
        return;
      }
      final shouldDownload = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Update ${info.latestVersion} Available'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Current version: ${info.currentVersion}'),
                Text('Latest version: ${info.latestVersion}'),
                const SizedBox(height: 12),
                const Text(
                  'Release notes',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 6),
                Text(
                  info.releaseNotes.isEmpty
                      ? 'No release notes provided.'
                      : info.releaseNotes,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Later'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Download and Install'),
            ),
          ],
        ),
      );
      if (shouldDownload != true || !mounted) return;

      _showBusyDialog('Downloading update installer...');
      File installerFile;
      try {
        installerFile = await AppUpdateService.downloadInstaller(info);
      } finally {
        if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
          Navigator.of(context, rootNavigator: true).pop();
        }
      }
      if (!mounted) return;
      final shouldInstall = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Install Update'),
          content: Text(
            'The installer has been downloaded.\n\nQuickBill will close and the installer will start.\n\nFile: ${installerFile.path.split(Platform.pathSeparator).last}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Install Now'),
            ),
          ],
        ),
      );
      if (shouldInstall == true) {
        await AppUpdateService.launchInstallerAndExit(installerFile);
      }
    } on AppUpdateCheckException catch (e) {
      if (!mounted) return;
      showErr(context, e.message);
    } on SocketException {
      if (!mounted) return;
      showErr(context, 'Could not check for updates. Please check internet.');
    } catch (_) {
      if (!mounted) return;
      showErr(context, 'Could not check for updates right now.');
    } finally {
      if (mounted) setState(() => _checkingForUpdates = false);
    }
  }

  void _showBusyDialog(String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              const SizedBox(width: 14),
              Expanded(child: Text(message)),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        automaticallyImplyLeading: false,
        title: DragToMoveArea(
          child: SizedBox(
            width: double.infinity,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('QuickBill Lab'),
                    Text(
                      _tabSubtitle(_tab),
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: _checkingForUpdates
                ? 'Checking for updates...'
                : 'Check for Updates',
            onPressed: _checkingForUpdates ? null : _checkForUpdates,
            icon: _checkingForUpdates
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  )
                : const Icon(Icons.system_update_alt, color: Colors.white),
          ),
          const _WindowButtons(),
        ],
      ),
      body: Row(
        children: [
          Container(
            width: 216,
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 12),
            child: ListView(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(10, 0, 10, 10),
                  child: Text(
                    'WORKSPACE',
                    style: TextStyle(
                      color: Color(0xFF8A94A6),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                _navItem(0, Icons.receipt_long_outlined, 'Invoices'),
                _navItem(3, Icons.payments_outlined, 'Payments'),
                _navItem(4, Icons.people_outline, 'Customers'),
                _navItem(5, Icons.history_outlined, 'History'),
                _navItem(9, Icons.insights_outlined, 'Stats'),
                const Padding(
                  padding: EdgeInsets.fromLTRB(10, 18, 10, 10),
                  child: Text(
                    'REPORTS & OPERATIONS',
                    style: TextStyle(
                      color: Color(0xFF8A94A6),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                _navItem(1, Icons.today_outlined, 'Daily reports'),
                _navItem(2, Icons.calendar_month_outlined, 'Monthly reports'),
                _navItem(6, Icons.account_balance_wallet_outlined, 'Ledgers'),
                _navItem(7, Icons.warehouse_outlined, 'Godown'),
                _navItem(8, Icons.phone_android_outlined, 'Mobile access'),
              ],
            ),
          ),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1320),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 18, 24, 20),
                  child: PageStorage(
                    bucket: _bucket,
                    child: IndexedStack(index: _tab, children: _pages),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _navItem(int index, IconData icon, String label) {
    final selected = _tab == index;
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Material(
        color: selected ? const Color(0xFFE7F4F5) : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        child: InkWell(
          onTap: () => _goTo(index),
          borderRadius: BorderRadius.circular(7),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 19,
                  color: selected
                      ? const Color(0xFF087F8C)
                      : const Color(0xFF667085),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: selected
                          ? const Color(0xFF075E68)
                          : const Color(0xFF344054),
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _maybeRunOneTimeReexport() async {
    try {
      final base = await baseDir();
      final marker = File(
        '${base.path}${Platform.pathSeparator}.reexport_excel_default_sheet_fix.done',
      );
      if (await marker.exists()) return;

      if (!mounted) return;
      int total = 0, completed = 0, skipped = 0;
      String stage = 'Preparing...';

      void updater() {
        if (!mounted) return;
        _reexportProgress?.value = _ReexportState(
          total,
          completed,
          skipped,
          stage,
        );
      }

      _reexportProgress ??= ValueNotifier<_ReexportState>(
        const _ReexportState(0, 0, 0, 'Starting...'),
      );
      _showReexportDialog(context, _reexportProgress!);

      stage = 'Scanning data...';
      updater();
      final invoices = await Store.loadAll();
      final payments = await PaymentStore.loadAll();

      final dayKeys = <String>{};
      final monthKeys = <String>{};
      final customers = <String>{};
      for (final inv in invoices) {
        try {
          final d = parseInvoiceDate(inv.date);
          dayKeys.add(formatInvoiceDate(d));
          monthKeys.add(DateFormat('yyyy-MM').format(d));
        } catch (_) {}
        final key = (inv.customerId.isNotEmpty ? inv.customerId : inv.customer)
            .trim();
        if (key.isNotEmpty) customers.add(key);
      }
      final payMonths = <String>{};
      for (final p in payments) {
        try {
          final d = parseInvoiceDate(p.date);
          payMonths.add(DateFormat('yyyy-MM').format(d));
        } catch (_) {}
      }

      final dayList = dayKeys.toList()..sort();
      final monthList = monthKeys.toList()..sort();
      final custList = customers.toList()..sort();
      final payMonthList = payMonths.toList()..sort();

      total =
          dayList.length +
          monthList.length +
          custList.length +
          payMonthList.length;
      stage = 'Re-exporting reports...';
      updater();

      Future<void> attempt<T>(Future<T> Function() run) async {
        try {
          await run();
        } catch (_) {
          try {
            await Future.delayed(const Duration(milliseconds: 300));
            await run();
          } catch (_) {
            skipped++;
          }
        } finally {
          completed++;
          updater();
        }
      }

      for (final d in dayList) {
        final dt = parseInvoiceDate(d);
        stage = 'Daily: $d';
        updater();
        await attempt(() => exportDailySalesExcel(dt));
      }
      for (final m in monthList) {
        stage = 'Monthly sales: $m';
        updater();
        await attempt(() => exportMonthlySalesExcel(DateTime.parse('$m-01')));
        stage = 'Profit & loss: $m';
        updater();
        await attempt(
          () => exportMonthlyProfitLossExcel(DateTime.parse('$m-01')),
        );
      }
      for (final c in custList) {
        stage = 'Customer: $c';
        updater();
        await attempt(() => rebuildCustomerWorkbookForKey(c));
      }
      for (final m in payMonthList) {
        stage = 'Payments: $m';
        updater();
        await attempt(
          () => rebuildMonthlyPaymentsExcels(DateTime.parse('$m-01')),
        );
      }

      try {
        await marker.writeAsString(
          DateTime.now().toIso8601String(),
          flush: true,
        );
      } catch (_) {}
      stage = 'Completed';
      updater();
    } catch (_) {
    } finally {
      try {
        _reexportProgress?.dispose();
      } catch (_) {}
      _reexportProgress = null;
      if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Reports re-export finished'),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  void _showReexportDialog(
    BuildContext context,
    ValueNotifier<_ReexportState> progress,
  ) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) {
        return PopScope(
          canPop: false,
          child: Dialog(
            insetPadding: const EdgeInsets.all(24),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: ValueListenableBuilder<_ReexportState>(
                valueListenable: progress,
                builder: (context, s, __) {
                  final pct = (s.total == 0)
                      ? 0.0
                      : (s.completed / s.total).clamp(0.0, 1.0);
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Repairing Excel reports...',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 12),
                      LinearProgressIndicator(value: s.total == 0 ? null : pct),
                      const SizedBox(height: 8),
                      Text(
                        '${s.completed}/${s.total}    Skipped: ${s.skipped}',
                      ),
                      const SizedBox(height: 4),
                      Text(
                        s.stage,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ReexportState {
  final int total;
  final int completed;
  final int skipped;
  final String stage;
  const _ReexportState(this.total, this.completed, this.skipped, this.stage);
}

class _WindowButtons extends StatelessWidget {
  const _WindowButtons();
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(
          tooltip: 'Minimize',
          icon: const Icon(Icons.minimize, color: Colors.white),
          onPressed: () async => windowManager.minimize(),
          iconSize: 16,
          padding: const EdgeInsets.all(4),
          constraints: const BoxConstraints.tightFor(width: 36, height: 36),
          splashRadius: 16,
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: 'Maximize/Restore',
          icon: const Icon(Icons.crop_square, color: Colors.white),
          onPressed: () async {
            final isMax = await windowManager.isMaximized();
            isMax
                ? await windowManager.unmaximize()
                : await windowManager.maximize();
          },
          iconSize: 16,
          padding: const EdgeInsets.all(4),
          constraints: const BoxConstraints.tightFor(width: 36, height: 36),
          splashRadius: 16,
        ),
        const SizedBox(width: 4),
        IconButton(
          tooltip: 'Close',
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () async => windowManager.close(),
          iconSize: 16,
          padding: const EdgeInsets.all(4),
          constraints: const BoxConstraints.tightFor(width: 36, height: 36),
          splashRadius: 16,
        ),
      ],
    );
  }
}
