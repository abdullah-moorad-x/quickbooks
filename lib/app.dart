import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'dart:ui' as ui;
import 'dart:io';
import 'package:intl/intl.dart';

import 'services/excel_service.dart';
import 'services/storage.dart';
import 'services/paths.dart';
import 'utils/date.dart';
import 'screens/invoice_screen.dart';
import 'screens/daily_reports_screen.dart';
import 'screens/monthly_reports_screen.dart';
import 'screens/payments_screen.dart';
import 'screens/customer_master_screen.dart';
import 'screens/history_screen.dart';
import 'screens/surjani_ledger_screen.dart';

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext context) {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: const ColorScheme.light(
        primary: Color(0xFF00838F),
        secondary: Color(0xFF2196F3),
        surface: Colors.white,
        onPrimary: Colors.white,
        onSurface: Colors.black87,
      ),
      fontFamily: 'Poppins',
      scaffoldBackgroundColor: Colors.white,
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF00838F),
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: const Color(0xFF00838F)),
      ),
    );

    final theme = base.copyWith(
      textTheme: base.textTheme.copyWith(
        titleLarge: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(fontSize: 14.5, height: 1.32),
        labelSmall: base.textTheme.labelSmall?.copyWith(fontSize: 12, letterSpacing: 0.2),
      ),
      appBarTheme: base.appBarTheme.copyWith(
        titleTextStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        isDense: true,
        fillColor: Color(0xFFF3F6F8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(10)),
          borderSide: BorderSide(color: Color(0xFFCFD8DC)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(10)),
          borderSide: BorderSide(color: Color(0xFFCFD8DC)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(10)),
          borderSide: BorderSide(color: Color(0xFF00838F), width: 1.5),
        ),
        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      tooltipTheme: const TooltipThemeData(waitDuration: Duration(milliseconds: 500)),
    );

    return MaterialApp(
      title: 'QuickBill By Abdullah',
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
      home: const Home(),
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
    ];

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeRunOneTimeReexport();
    });
  }

  String _tabSubtitle(int t) {
    switch (t) {
      case 0: return 'Create and manage invoices';
      case 1: return "Today's exports & recent daily files";
      case 2: return "This month's summary & history";
      case 3: return 'Track payments and pending amounts';
      case 4: return 'Customer records and activity';
      case 5: return 'Invoice history and backups';
      default: return 'Surjani stock/payment ledger';
    }
  }

  void _goTo(int index) { if (index != _tab) setState(() => _tab = index); }

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
                    const Text('QuickBill By Abdullah'),
                    Text(_tabSubtitle(_tab), style: const TextStyle(fontSize: 12, color: Colors.white70)),
                  ],
                ),
              ),
            ),
          ),
        ),
        actions: const [
          _WindowButtons(),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1200),
          child: Builder(builder: (context) {
            final w = MediaQuery.of(context).size.width;
            final pad = w > 1200 ? 32.0 : w > 800 ? 24.0 : 16.0;
            return Padding(
              padding: EdgeInsets.symmetric(horizontal: pad, vertical: 16),
              child: PageStorage(
                bucket: _bucket,
                child: IndexedStack(index: _tab, children: _pages),
              ),
            );
          }),
        ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        type: BottomNavigationBarType.fixed,
        currentIndex: _tab,
        onTap: _goTo,
        showUnselectedLabels: false,
        selectedFontSize: 12,
        unselectedFontSize: 12,
        selectedItemColor: Theme.of(context).colorScheme.primary,
        unselectedItemColor: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.8),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.description), label: 'Invoice'),
          BottomNavigationBarItem(icon: Icon(Icons.table_view), label: 'Daily Reports'),
          BottomNavigationBarItem(icon: Icon(Icons.calendar_month), label: 'Monthly Reports'),
          BottomNavigationBarItem(icon: Icon(Icons.payments), label: 'Payments'),
          BottomNavigationBarItem(icon: Icon(Icons.people_alt), label: 'Customer Master'),
          BottomNavigationBarItem(icon: Icon(Icons.history), label: 'History'),
          BottomNavigationBarItem(icon: Icon(Icons.account_balance_wallet), label: 'Surjani Ledger'),
        ],
      ),
    );
  }

  Future<void> _maybeRunOneTimeReexport() async {
    try {
      final base = await baseDir();
      final marker = File('${base.path}${Platform.pathSeparator}.reexport_excel_default_sheet_fix.done');
      if (await marker.exists()) return;

      if (!mounted) return;
      int total = 0, completed = 0, skipped = 0;
      String stage = 'Preparing...';

      void updater() {
        if (!mounted) return;
        _reexportProgress?.value = _ReexportState(total, completed, skipped, stage);
      }

      _reexportProgress ??= ValueNotifier<_ReexportState>(const _ReexportState(0, 0, 0, 'Starting...'));
      _showReexportDialog(context, _reexportProgress!);

      stage = 'Scanning data...'; updater();
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
        final key = (inv.customerId.isNotEmpty ? inv.customerId : inv.customer).trim();
        if (key.isNotEmpty) customers.add(key);
      }
      final payMonths = <String>{};
      for (final p in payments) {
        try { final d = parseInvoiceDate(p.date); payMonths.add(DateFormat('yyyy-MM').format(d)); } catch (_) {}
      }

      final dayList = dayKeys.toList()..sort();
      final monthList = monthKeys.toList()..sort();
      final custList = customers.toList()..sort();
      final payMonthList = payMonths.toList()..sort();

      total = dayList.length + monthList.length + custList.length + payMonthList.length;
      stage = 'Re-exporting reports...'; updater();

      Future<void> attempt<T>(Future<T> Function() run) async {
        try { await run(); }
        catch (_) {
          try { await Future.delayed(const Duration(milliseconds: 300)); await run(); }
          catch (_) { skipped++; }
        }
        finally { completed++; updater(); }
      }

      for (final d in dayList) {
        final dt = parseInvoiceDate(d);
        stage = 'Daily: $d'; updater();
        await attempt(() => exportDailySalesExcel(dt));
      }
      for (final m in monthList) {
        stage = 'Monthly sales: $m'; updater();
        await attempt(() => exportMonthlySalesExcel(DateTime.parse('$m-01')));
      }
      for (final c in custList) {
        stage = 'Customer: $c'; updater();
        await attempt(() => rebuildCustomerWorkbookForKey(c));
      }
      for (final m in payMonthList) {
        stage = 'Payments: $m'; updater();
        await attempt(() => rebuildMonthlyPaymentsExcels(DateTime.parse('$m-01')));
      }

      try { await marker.writeAsString(DateTime.now().toIso8601String(), flush: true); } catch (_) {}
      stage = 'Completed'; updater();
    } catch (_) {
    } finally {
      try { _reexportProgress?.dispose(); } catch (_) {}
      _reexportProgress = null;
      if (mounted && Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Reports re-export finished'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(seconds: 2),
        ));
      }
    }
  }

  void _showReexportDialog(BuildContext context, ValueNotifier<_ReexportState> progress) {
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
                  final pct = (s.total == 0) ? 0.0 : (s.completed / s.total).clamp(0.0, 1.0);
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Repairing Excel reports...', style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 12),
                      LinearProgressIndicator(value: s.total == 0 ? null : pct),
                      const SizedBox(height: 8),
                      Text('${s.completed}/${s.total}    Skipped: ${s.skipped}'),
                      const SizedBox(height: 4),
                      Text(s.stage, maxLines: 2, overflow: TextOverflow.ellipsis),
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
    return Row(children: [
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
          isMax ? await windowManager.unmaximize() : await windowManager.maximize();
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
    ]);
  }
}
