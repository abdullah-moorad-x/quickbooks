import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/app_bus.dart';
import '../models/invoice.dart';
import '../models/mobile_access.dart';
import '../models/payment.dart';
import '../services/mobile_sync_store.dart';
import '../services/storage.dart';
import '../utils/date.dart';
import '../utils/format.dart';
import '../utils/snackbar.dart';
import '../widgets/skeleton_loader.dart';

enum _StatsPeriod { month, threeMonths, sixMonths, year, custom }

class StatsScreen extends StatefulWidget {
  final Future<void> Function()? onRefresh;

  const StatsScreen({super.key, this.onRefresh});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  bool _loading = true;
  bool _refreshing = false;
  List<Invoice> _invoices = const [];
  List<PaymentEntry> _payments = const [];
  List<MobileTruck> _surjaniTrucks = const [];
  List<MobileTruck> _factoryTrucks = const [];
  _StatsPeriod _period = _StatsPeriod.month;
  DateTime _anchor = DateTime(DateTime.now().year, DateTime.now().month, 1);
  DateTimeRange? _customRange;

  @override
  void initState() {
    super.initState();
    _load();
    AppBus.dataTick.addListener(_handleDataChange);
  }

  @override
  void dispose() {
    AppBus.dataTick.removeListener(_handleDataChange);
    super.dispose();
  }

  void _handleDataChange() {
    if (mounted) _load(showLoader: false);
  }

  Future<void> _load({bool showLoader = true}) async {
    if (showLoader && mounted) setState(() => _loading = true);
    final values = await Future.wait([
      Store.loadAll(),
      PaymentStore.loadAll(),
      MobileAccessStore.loadSurjaniTrucks(),
      MobileAccessStore.loadFactoryTrucks(),
    ]);
    if (!mounted) return;
    setState(() {
      _invoices = values[0] as List<Invoice>;
      _payments = values[1] as List<PaymentEntry>;
      _surjaniTrucks = values[2] as List<MobileTruck>;
      _factoryTrucks = values[3] as List<MobileTruck>;
      _loading = false;
    });
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await widget.onRefresh?.call();
      await _load(showLoader: false);
    } catch (error) {
      if (mounted) showErr(context, 'Could not refresh stats: $error');
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  _DateWindow get _window {
    switch (_period) {
      case _StatsPeriod.month:
        return _DateWindow(_anchor, DateTime(_anchor.year, _anchor.month + 1));
      case _StatsPeriod.threeMonths:
        return _DateWindow(
          DateTime(_anchor.year, _anchor.month - 2),
          DateTime(_anchor.year, _anchor.month + 1),
        );
      case _StatsPeriod.sixMonths:
        return _DateWindow(
          DateTime(_anchor.year, _anchor.month - 5),
          DateTime(_anchor.year, _anchor.month + 1),
        );
      case _StatsPeriod.year:
        return _DateWindow(
          DateTime(_anchor.year),
          DateTime(_anchor.year + 1),
        );
      case _StatsPeriod.custom:
        final range = _customRange;
        if (range == null) {
          return _DateWindow(
            DateTime(_anchor.year, _anchor.month, 1),
            DateTime(_anchor.year, _anchor.month + 1, 1),
          );
        }
        return _DateWindow(
          _dateOnly(range.start),
          _dateOnly(range.end).add(const Duration(days: 1)),
        );
    }
  }

  _DateWindow _previousWindow(_DateWindow current) {
    switch (_period) {
      case _StatsPeriod.month:
        return _DateWindow(
          DateTime(current.start.year, current.start.month - 1),
          current.start,
        );
      case _StatsPeriod.threeMonths:
        return _DateWindow(
          DateTime(current.start.year, current.start.month - 3),
          current.start,
        );
      case _StatsPeriod.sixMonths:
        return _DateWindow(
          DateTime(current.start.year, current.start.month - 6),
          current.start,
        );
      case _StatsPeriod.year:
        return _DateWindow(
          DateTime(current.start.year - 1),
          current.start,
        );
      case _StatsPeriod.custom:
        final days = current.end.difference(current.start).inDays;
        return _DateWindow(
          current.start.subtract(Duration(days: days)),
          current.start,
        );
    }
  }

  DateTime _dateOnly(DateTime date) =>
      DateTime(date.year, date.month, date.day);

  String _rangeLabel(_DateWindow window) {
    if (_period == _StatsPeriod.month) {
      return DateFormat('MMMM yyyy').format(window.start);
    }
    if (_period == _StatsPeriod.year) return '${window.start.year}';
    final inclusiveEnd = window.end.subtract(const Duration(days: 1));
    if (window.start.year == inclusiveEnd.year) {
      return '${DateFormat('d MMM').format(window.start)} - ${DateFormat('d MMM yyyy').format(inclusiveEnd)}';
    }
    return '${DateFormat('d MMM yyyy').format(window.start)} - ${DateFormat('d MMM yyyy').format(inclusiveEnd)}';
  }

  void _movePeriod(int direction) {
    if (_period == _StatsPeriod.custom) return;
    final months = switch (_period) {
      _StatsPeriod.month => 1,
      _StatsPeriod.threeMonths => 3,
      _StatsPeriod.sixMonths => 6,
      _StatsPeriod.year => 12,
      _StatsPeriod.custom => 0,
    };
    setState(() {
      _anchor = DateTime(_anchor.year, _anchor.month + (months * direction));
    });
  }

  bool get _canMoveForward {
    final nowMonth = DateTime(DateTime.now().year, DateTime.now().month);
    return _anchor.isBefore(nowMonth);
  }

  Future<void> _chooseCustomRange() async {
    final now = DateTime.now();
    final current = _window;
    final selected = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 10),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialDateRange: DateTimeRange(
        start: current.start,
        end: current.end.subtract(const Duration(days: 1)),
      ),
      helpText: 'Choose stats date range',
    );
    if (selected == null || !mounted) return;
    setState(() {
      _customRange = selected;
      _period = _StatsPeriod.custom;
      _anchor = DateTime(selected.end.year, selected.end.month);
    });
  }

  _StatsSnapshot _snapshot(_DateWindow window) {
    final invoices = _invoices.where((invoice) {
      final date = _tryDate(invoice.date);
      return date != null && window.contains(date);
    }).toList();
    final payments = _payments.where((payment) {
      final date = _tryDate(payment.date);
      return date != null && window.contains(date);
    }).toList();

    var grossSales = 0.0;
    var returnValue = 0.0;
    var netSales = 0.0;
    var grossBags = 0.0;
    var returnedBags = 0.0;
    var outstanding = 0.0;
    var walkInSales = 0.0;
    var walkInCount = 0;
    var orderCount = 0;
    var returnCount = 0;
    final customers = <String>{};
    final categories = <String, _CategoryStats>{};
    final customerSales = <String, double>{};
    final paymentTypes = <PaymentType, double>{
      for (final type in PaymentType.values) type: 0,
    };

    for (final invoice in invoices) {
      final isReturn = _isReturn(invoice);
      netSales += invoice.balance;
      if (isReturn) {
        returnCount++;
        returnValue += invoice.balance.abs();
      } else {
        orderCount++;
        grossSales += math.max(0, invoice.balance);
        outstanding += invoice.remaining;
        if (invoice.walkIn) {
          walkInCount++;
          walkInSales += invoice.balance;
          final paymentType = invoice.walkInPaymentType ?? PaymentType.cash;
          paymentTypes[paymentType] =
              (paymentTypes[paymentType] ?? 0) + invoice.paid;
        } else {
          final key = invoice.customer.trim().isEmpty
              ? 'Unknown customer'
              : invoice.customer.trim();
          customers.add(key.toLowerCase());
          customerSales[key] = (customerSales[key] ?? 0) + invoice.balance;
        }
      }

      for (final line in invoice.lines) {
        final category = _categoryName(line.typeLabel);
        if (category.isEmpty || line.qty == 0) continue;
        final current = categories[category] ?? _CategoryStats(category);
        categories[category] = current.copyWith(
          bags: current.bags + line.qty,
          sales: current.sales + line.amount,
        );
        if (line.qty > 0) {
          grossBags += line.qty;
        } else {
          returnedBags += line.qty.abs();
        }
      }
    }

    var received = 0.0;
    var discount = 0.0;
    for (final payment in payments) {
      received += payment.effectiveAmount;
      discount += payment.discount;
      paymentTypes[payment.type] =
          (paymentTypes[payment.type] ?? 0) + payment.effectiveAmount;
    }
    final walkInReceived = invoices
        .where((invoice) => invoice.walkIn && !_isReturn(invoice))
        .fold<double>(0, (sum, invoice) => sum + invoice.paid);
    received += walkInReceived;

    final incoming = <String, _IncomingStats>{
      'Surjani': _incomingFor(_surjaniTrucks, window),
      'Factory': _incomingFor(_factoryTrucks, window),
    };
    final trend = _buildTrend(window, invoices, payments);
    final sortedCustomers = customerSales.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final sortedCategories = categories.values.toList()
      ..sort((a, b) => b.bags.abs().compareTo(a.bags.abs()));

    return _StatsSnapshot(
      netSales: netSales,
      grossSales: grossSales,
      returnValue: returnValue,
      received: received,
      discount: discount,
      netBags: grossBags - returnedBags,
      grossBags: grossBags,
      returnedBags: returnedBags,
      outstanding: outstanding,
      orderCount: orderCount,
      returnCount: returnCount,
      walkInCount: walkInCount,
      walkInSales: walkInSales,
      customerCount: customers.length,
      categories: sortedCategories,
      customerSales: sortedCustomers.take(5).toList(),
      paymentTypes: paymentTypes,
      incoming: incoming,
      trend: trend,
    );
  }

  _IncomingStats _incomingFor(List<MobileTruck> trucks, _DateWindow window) {
    var bags = 0.0;
    var count = 0;
    for (final truck in trucks) {
      final date = _tryDate(truck.orderDate);
      if (date == null || !window.contains(date)) continue;
      count++;
      bags += truck.capacity;
    }
    return _IncomingStats(count, bags);
  }

  List<_DailyTrendPoint> _buildTrend(
    _DateWindow window,
    List<Invoice> invoices,
    List<PaymentEntry> payments,
  ) {
    final salesByDay = <DateTime, double>{};
    final receivedByDay = <DateTime, double>{};
    final bagsByDay = <DateTime, double>{};
    for (final invoice in invoices) {
      final date = _tryDate(invoice.date);
      if (date == null) continue;
      salesByDay[date] = (salesByDay[date] ?? 0) + invoice.balance;
      bagsByDay[date] = (bagsByDay[date] ?? 0) +
          invoice.lines.fold<double>(0, (sum, line) => sum + line.qty);
      if (invoice.walkIn && !_isReturn(invoice)) {
        receivedByDay[date] = (receivedByDay[date] ?? 0) + invoice.paid;
      }
    }
    for (final payment in payments) {
      final date = _tryDate(payment.date);
      if (date == null) continue;
      receivedByDay[date] =
          (receivedByDay[date] ?? 0) + payment.effectiveAmount;
    }

    final points = <_DailyTrendPoint>[];
    final totalDays = window.end.difference(window.start).inDays;
    for (var offset = 0; offset < totalDays; offset++) {
      final date = window.start.add(Duration(days: offset));
      points.add(_DailyTrendPoint(
        date,
        DateFormat('d MMM').format(date),
        salesByDay[date] ?? 0,
        receivedByDay[date] ?? 0,
        bagsByDay[date] ?? 0,
      ));
    }
    return points;
  }

  DateTime? _tryDate(String value) {
    try {
      return _dateOnly(parseInvoiceDate(value));
    } catch (_) {
      return null;
    }
  }

  bool _isReturn(Invoice invoice) =>
      invoice.isReturn ||
      invoice.balance < 0 ||
      invoice.lines.any((line) => line.qty < 0);

  String _categoryName(String value) {
    final normalized = value.trim().toUpperCase().replaceAll('-', ' ');
    if (normalized == 'BOND') return 'BOUND';
    if (normalized == 'WHITE') return 'WHITE CEMENT';
    return normalized;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const AppSkeletonLoader();
    final window = _window;
    final current = _snapshot(window);
    final previous = _snapshot(_previousWindow(window));
    return RefreshIndicator(
      onRefresh: _refresh,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 780;
          return ListView(
            key: const PageStorageKey<String>('stats-screen'),
            padding: EdgeInsets.fromLTRB(wide ? 20 : 12, 8, wide ? 20 : 12, 28),
            children: [
              _StatsHeader(
                period: _period,
                rangeLabel: _rangeLabel(window),
                refreshing: _refreshing,
                canMoveForward: _canMoveForward,
                onPeriodChanged: (value) {
                  if (value == _StatsPeriod.custom) {
                    _chooseCustomRange();
                  } else {
                    setState(() => _period = value);
                  }
                },
                onPrevious: () => _movePeriod(-1),
                onNext: () => _movePeriod(1),
                onCalendar: _chooseCustomRange,
                onRefresh: _refresh,
              ),
              const SizedBox(height: 14),
              _HeadlinePanel(
                current: current,
                previous: previous,
                periodLabel: _rangeLabel(window),
              ),
              const SizedBox(height: 14),
              _MetricGrid(current: current, wide: wide),
              const SizedBox(height: 14),
              _StatsSection(
                title: 'Sales and payments trend',
                subtitle: 'Net figures include recorded returns.',
                child: _TrendChart(points: current.trend),
              ),
              const SizedBox(height: 14),
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _CategoryPanel(snapshot: current)),
                    const SizedBox(width: 14),
                    Expanded(child: _CustomerPanel(snapshot: current)),
                  ],
                )
              else ...[
                _CategoryPanel(snapshot: current),
                const SizedBox(height: 14),
                _CustomerPanel(snapshot: current),
              ],
              const SizedBox(height: 14),
              if (wide)
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: _PaymentPanel(snapshot: current)),
                    const SizedBox(width: 14),
                    Expanded(child: _IncomingPanel(snapshot: current)),
                  ],
                )
              else ...[
                _PaymentPanel(snapshot: current),
                const SizedBox(height: 14),
                _IncomingPanel(snapshot: current),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _StatsHeader extends StatelessWidget {
  final _StatsPeriod period;
  final String rangeLabel;
  final bool refreshing;
  final bool canMoveForward;
  final ValueChanged<_StatsPeriod> onPeriodChanged;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onCalendar;
  final VoidCallback onRefresh;

  const _StatsHeader({
    required this.period,
    required this.rangeLabel,
    required this.refreshing,
    required this.canMoveForward,
    required this.onPeriodChanged,
    required this.onPrevious,
    required this.onNext,
    required this.onCalendar,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Business stats',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Sales, collections, returns, customers, and stock movement',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF667085),
                        ),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Refresh stats',
              onPressed: refreshing ? null : onRefresh,
              icon: refreshing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SegmentedButton<_StatsPeriod>(
            segments: const [
              ButtonSegment(value: _StatsPeriod.month, label: Text('Month')),
              ButtonSegment(
                  value: _StatsPeriod.threeMonths, label: Text('3 months')),
              ButtonSegment(
                  value: _StatsPeriod.sixMonths, label: Text('6 months')),
              ButtonSegment(value: _StatsPeriod.year, label: Text('Year')),
              ButtonSegment(
                value: _StatsPeriod.custom,
                icon: Icon(Icons.date_range_outlined, size: 18),
                label: Text('Custom'),
              ),
            ],
            selected: {period},
            showSelectedIcon: false,
            onSelectionChanged: (values) => onPeriodChanged(values.first),
          ),
        ),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: const Color(0xFFF5F7FA),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFE4E7EC)),
          ),
          child: Row(
            children: [
              IconButton(
                tooltip: 'Previous period',
                onPressed: period == _StatsPeriod.custom ? null : onPrevious,
                icon: const Icon(Icons.chevron_left_rounded),
              ),
              Expanded(
                child: Text(
                  rangeLabel,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                tooltip: 'Choose custom dates',
                onPressed: onCalendar,
                icon: const Icon(Icons.calendar_month_outlined, size: 20),
              ),
              IconButton(
                tooltip: 'Next period',
                onPressed: period == _StatsPeriod.custom || !canMoveForward
                    ? null
                    : onNext,
                icon: const Icon(Icons.chevron_right_rounded),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _HeadlinePanel extends StatelessWidget {
  final _StatsSnapshot current;
  final _StatsSnapshot previous;
  final String periodLabel;

  const _HeadlinePanel({
    required this.current,
    required this.previous,
    required this.periodLabel,
  });

  @override
  Widget build(BuildContext context) {
    final change = _percentChange(current.netSales, previous.netSales);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF123B46),
        borderRadius: BorderRadius.circular(8),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 560;
          final main = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                periodLabel,
                style: const TextStyle(color: Color(0xFFB8DDE1), fontSize: 12),
              ),
              const SizedBox(height: 5),
              const Text(
                'Net sales',
                style: TextStyle(
                    color: Colors.white70, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 3),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  'Rs ${fmt0(current.netSales)}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(height: 7),
              _ChangeLabel(change: change),
            ],
          );
          final side = Wrap(
            spacing: 18,
            runSpacing: 12,
            children: [
              _HeadlineValue(
                  label: 'Gross sales',
                  value: 'Rs ${fmt0(current.grossSales)}'),
              _HeadlineValue(
                  label: 'Returns', value: 'Rs ${fmt0(current.returnValue)}'),
              _HeadlineValue(
                  label: 'Received', value: 'Rs ${fmt0(current.received)}'),
            ],
          );
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [main, const SizedBox(height: 18), side],
            );
          }
          return Row(
            children: [
              Expanded(child: main),
              const SizedBox(width: 24),
              Flexible(flex: 2, child: side),
            ],
          );
        },
      ),
    );
  }
}

class _ChangeLabel extends StatelessWidget {
  final double? change;

  const _ChangeLabel({required this.change});

  @override
  Widget build(BuildContext context) {
    if (change == null) {
      return const Text(
        'No sales in previous period',
        style: TextStyle(color: Color(0xFFB8DDE1), fontSize: 12),
      );
    }
    final positive = change! >= 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          positive ? Icons.trending_up_rounded : Icons.trending_down_rounded,
          color: positive ? const Color(0xFF79E2B8) : const Color(0xFFFFB4AB),
          size: 17,
        ),
        const SizedBox(width: 5),
        Text(
          '${change!.abs().toStringAsFixed(1)}% ${positive ? 'up' : 'down'} from previous period',
          style: TextStyle(
            color: positive ? const Color(0xFF79E2B8) : const Color(0xFFFFB4AB),
            fontWeight: FontWeight.w700,
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

class _HeadlineValue extends StatelessWidget {
  final String label;
  final String value;

  const _HeadlineValue({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 110,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(color: Color(0xFFB8DDE1), fontSize: 11)),
          const SizedBox(height: 3),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricGrid extends StatelessWidget {
  final _StatsSnapshot current;
  final bool wide;

  const _MetricGrid({required this.current, required this.wide});

  @override
  Widget build(BuildContext context) {
    final metrics = [
      _MetricData(
          'Net bags',
          '${fmt0(current.netBags)} bags',
          Icons.inventory_2_outlined,
          const Color(0xFF1570EF),
          'Sold ${fmt0(current.grossBags)} | Returned ${fmt0(current.returnedBags)}'),
      _MetricData(
          'Outstanding',
          'Rs ${fmt0(current.outstanding)}',
          Icons.account_balance_wallet_outlined,
          const Color(0xFFD97706),
          'Current unpaid on period invoices'),
      _MetricData(
          'Orders',
          '${current.orderCount}',
          Icons.receipt_long_outlined,
          const Color(0xFF027A48),
          'Average Rs ${fmt0(current.averageOrder)}'),
      _MetricData(
          'Returns',
          '${current.returnCount}',
          Icons.assignment_return_outlined,
          const Color(0xFFB42318),
          'Rs ${fmt0(current.returnValue)} returned'),
      _MetricData(
          'Walk-in sales',
          '${current.walkInCount}',
          Icons.storefront_outlined,
          const Color(0xFF7A5AF8),
          'Rs ${fmt0(current.walkInSales)}'),
      _MetricData(
          'Customers',
          '${current.customerCount}',
          Icons.people_alt_outlined,
          const Color(0xFF0E7490),
          'Customers buying in this period'),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 1000
            ? 3
            : constraints.maxWidth >= 560
                ? 3
                : 2;
        const spacing = 10.0;
        final width =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final metric in metrics)
              SizedBox(width: width, child: _MetricTile(data: metric))
          ],
        );
      },
    );
  }
}

class _MetricData {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final String detail;

  const _MetricData(this.label, this.value, this.icon, this.color, this.detail);
}

class _MetricTile extends StatelessWidget {
  final _MetricData data;

  const _MetricTile({required this.data});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 128,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE4E7EC)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(data.icon, color: data.color, size: 19),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  data.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Color(0xFF667085),
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const Spacer(),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(data.value,
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
          ),
          const SizedBox(height: 4),
          Text(
            data.detail,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                color: Color(0xFF98A2B3), fontSize: 10, height: 1.2),
          ),
        ],
      ),
    );
  }
}

class _StatsSection extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;

  const _StatsSection(
      {required this.title, this.subtitle, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFE4E7EC)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(subtitle!,
                style: const TextStyle(color: Color(0xFF667085), fontSize: 11)),
          ],
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _TrendChart extends StatefulWidget {
  final List<_DailyTrendPoint> points;

  const _TrendChart({required this.points});

  @override
  State<_TrendChart> createState() => _TrendChartState();
}

class _TrendChartState extends State<_TrendChart> {
  late int _selectedIndex = _defaultSelectedIndex();

  int _defaultSelectedIndex() {
    if (widget.points.isEmpty) return 0;
    final today = DateTime.now();
    final todayIndex = widget.points.indexWhere(
      (point) =>
          point.date.year == today.year &&
          point.date.month == today.month &&
          point.date.day == today.day,
    );
    return todayIndex >= 0 ? todayIndex : widget.points.length - 1;
  }

  @override
  void didUpdateWidget(covariant _TrendChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldStart =
        oldWidget.points.isEmpty ? null : oldWidget.points.first.date;
    final newStart = widget.points.isEmpty ? null : widget.points.first.date;
    if (oldStart != newStart ||
        oldWidget.points.length != widget.points.length) {
      _selectedIndex = _defaultSelectedIndex();
    } else if (widget.points.isNotEmpty &&
        _selectedIndex >= widget.points.length) {
      _selectedIndex = widget.points.length - 1;
    }
  }

  void _selectAt(double dx, double width) {
    if (widget.points.isEmpty || width <= 0) return;
    final next = ((dx.clamp(0, width) / width) * (widget.points.length - 1))
        .round()
        .clamp(0, widget.points.length - 1);
    if (next != _selectedIndex) setState(() => _selectedIndex = next);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.points.isEmpty) {
      return const _EmptyStats(text: 'No trend data for this period.');
    }
    final selected = widget.points[_selectedIndex];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                DateFormat('EEEE, d MMMM yyyy').format(selected.date),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:
                    const TextStyle(fontWeight: FontWeight.w800, fontSize: 13),
              ),
            ),
            const Icon(Icons.swipe_rounded, size: 18, color: Color(0xFF98A2B3)),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _SelectedTrendValue(
                label: 'Net sales',
                value: 'Rs ${fmt0(selected.sales)}',
                color: const Color(0xFF1570EF),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _SelectedTrendValue(
                label: 'Received',
                value: 'Rs ${fmt0(selected.received)}',
                color: const Color(0xFF039855),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _SelectedTrendValue(
                label: 'Net bags',
                value: fmt0(selected.bags),
                color: const Color(0xFFD97706),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        const Row(
          children: [
            _Legend(color: Color(0xFF1570EF), text: 'Net sales'),
            SizedBox(width: 16),
            _Legend(color: Color(0xFF039855), text: 'Received'),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 190,
          child: LayoutBuilder(
            builder: (context, constraints) => GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (details) =>
                  _selectAt(details.localPosition.dx, constraints.maxWidth),
              onHorizontalDragUpdate: (details) =>
                  _selectAt(details.localPosition.dx, constraints.maxWidth),
              child: CustomPaint(
                painter: _StatsChartPainter(widget.points, _selectedIndex),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SelectedTrendValue extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _SelectedTrendValue({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(color: Color(0xFF667085), fontSize: 10)),
          const Spacer(),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value,
                style: TextStyle(color: color, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  final Color color;
  final String text;

  const _Legend({required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 5),
        Text(text,
            style: const TextStyle(color: Color(0xFF667085), fontSize: 11)),
      ],
    );
  }
}

class _StatsChartPainter extends CustomPainter {
  final List<_DailyTrendPoint> points;
  final int selectedIndex;

  const _StatsChartPainter(this.points, this.selectedIndex);

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty || size.isEmpty) return;
    const left = 4.0;
    const top = 8.0;
    const bottom = 26.0;
    final chartHeight = size.height - top - bottom;
    final values = <double>[
      for (final point in points) point.sales,
      for (final point in points) point.received,
    ];
    final minValue = values.fold<double>(0, math.min);
    final maxValue = values.fold<double>(0, math.max);
    final valueRange =
        (maxValue - minValue).abs() < .001 ? 1.0 : maxValue - minValue;
    double yFor(double value) =>
        top + chartHeight * (1 - ((value - minValue) / valueRange));
    final grid = Paint()..color = const Color(0xFFE4E7EC);
    for (var i = 0; i <= 3; i++) {
      final y = top + chartHeight * i / 3;
      canvas.drawLine(Offset(left, y), Offset(size.width, y), grid);
    }

    void drawSeries(double Function(_DailyTrendPoint) value, Color color) {
      final path = Path();
      for (var i = 0; i < points.length; i++) {
        final x = points.length == 1
            ? size.width / 2
            : left + (size.width - left) * i / (points.length - 1);
        final y = yFor(value(points[i]));
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..strokeWidth = 2.5
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }

    drawSeries((point) => point.sales, const Color(0xFF1570EF));
    drawSeries((point) => point.received, const Color(0xFF039855));

    final selected = selectedIndex.clamp(0, points.length - 1);
    final selectedX = points.length == 1
        ? size.width / 2
        : left + (size.width - left) * selected / (points.length - 1);
    canvas.drawLine(
      Offset(selectedX, top),
      Offset(selectedX, top + chartHeight),
      Paint()
        ..color = const Color(0xFF98A2B3)
        ..strokeWidth = 1,
    );
    void drawSelectedDot(double value, Color color) {
      canvas.drawCircle(
        Offset(selectedX, yFor(value)),
        4.5,
        Paint()..color = Colors.white,
      );
      canvas.drawCircle(
        Offset(selectedX, yFor(value)),
        3,
        Paint()..color = color,
      );
    }

    drawSelectedDot(points[selected].sales, const Color(0xFF1570EF));
    drawSelectedDot(points[selected].received, const Color(0xFF039855));

    const labelStyle = TextStyle(color: Color(0xFF98A2B3), fontSize: 9);
    final labelEvery = math.max(1, (points.length / 6).ceil());
    for (var i = 0; i < points.length; i += labelEvery) {
      final painter = TextPainter(
        text: TextSpan(text: points[i].label, style: labelStyle),
        textDirection: ui.TextDirection.ltr,
      )..layout(maxWidth: 50);
      final x = points.length == 1
          ? size.width / 2
          : left + (size.width - left) * i / (points.length - 1);
      painter.paint(
          canvas,
          Offset((x - painter.width / 2).clamp(0, size.width - painter.width),
              size.height - 17));
    }
  }

  @override
  bool shouldRepaint(covariant _StatsChartPainter oldDelegate) =>
      oldDelegate.points != points ||
      oldDelegate.selectedIndex != selectedIndex;
}

class _CategoryPanel extends StatelessWidget {
  final _StatsSnapshot snapshot;

  const _CategoryPanel({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final maxBags = snapshot.categories
        .fold<double>(0, (max, row) => math.max(max, row.bags.abs()));
    return _StatsSection(
      title: 'Product performance',
      subtitle: 'Net bags and value after returns',
      child: snapshot.categories.isEmpty
          ? const _EmptyStats(text: 'No product sales in this period.')
          : Column(
              children: [
                for (var i = 0; i < snapshot.categories.length; i++) ...[
                  _BreakdownRow(
                    label: snapshot.categories[i].name,
                    value: '${fmt0(snapshot.categories[i].bags)} bags',
                    detail: 'Rs ${fmt0(snapshot.categories[i].sales)}',
                    progress: maxBags == 0
                        ? 0
                        : snapshot.categories[i].bags.abs() / maxBags,
                    color: const Color(0xFF1570EF),
                  ),
                  if (i != snapshot.categories.length - 1)
                    const SizedBox(height: 13),
                ],
              ],
            ),
    );
  }
}

class _CustomerPanel extends StatelessWidget {
  final _StatsSnapshot snapshot;

  const _CustomerPanel({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final maxSales = snapshot.customerSales.isEmpty
        ? 0.0
        : snapshot.customerSales.first.value.abs();
    return _StatsSection(
      title: 'Top customers',
      subtitle: 'Highest net sales in the selected period',
      child: snapshot.customerSales.isEmpty
          ? const _EmptyStats(text: 'No customer sales in this period.')
          : Column(
              children: [
                for (var i = 0; i < snapshot.customerSales.length; i++) ...[
                  _BreakdownRow(
                    label: snapshot.customerSales[i].key,
                    value: 'Rs ${fmt0(snapshot.customerSales[i].value)}',
                    progress: maxSales == 0
                        ? 0
                        : snapshot.customerSales[i].value.abs() / maxSales,
                    color: const Color(0xFF0E7490),
                  ),
                  if (i != snapshot.customerSales.length - 1)
                    const SizedBox(height: 13),
                ],
              ],
            ),
    );
  }
}

class _PaymentPanel extends StatelessWidget {
  final _StatsSnapshot snapshot;

  const _PaymentPanel({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final total = snapshot.paymentTypes.values
        .fold<double>(0, (sum, value) => sum + value);
    const colors = {
      PaymentType.cash: Color(0xFF039855),
      PaymentType.cheque: Color(0xFFD97706),
      PaymentType.bank: Color(0xFF7A5AF8),
    };
    return _StatsSection(
      title: 'Payment methods',
      subtitle: snapshot.discount > 0
          ? 'Includes Rs ${fmt0(snapshot.discount)} discount'
          : 'Customer payments and paid walk-in sales',
      child: Column(
        children: [
          for (var i = 0; i < PaymentType.values.length; i++) ...[
            _BreakdownRow(
              label: paymentTypeLabel(PaymentType.values[i]),
              value:
                  'Rs ${fmt0(snapshot.paymentTypes[PaymentType.values[i]] ?? 0)}',
              progress: total == 0
                  ? 0
                  : (snapshot.paymentTypes[PaymentType.values[i]] ?? 0) / total,
              color: colors[PaymentType.values[i]]!,
            ),
            if (i != PaymentType.values.length - 1) const SizedBox(height: 13),
          ],
        ],
      ),
    );
  }
}

class _IncomingPanel extends StatelessWidget {
  final _StatsSnapshot snapshot;

  const _IncomingPanel({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final surjani = snapshot.incoming['Surjani'] ?? const _IncomingStats(0, 0);
    final factory = snapshot.incoming['Factory'] ?? const _IncomingStats(0, 0);
    return _StatsSection(
      title: 'Incoming stock',
      subtitle: 'Truck entries during the selected period',
      child: Row(
        children: [
          Expanded(
            child: _IncomingTile(
              label: 'Surjani',
              stats: surjani,
              icon: Icons.local_shipping_outlined,
              color: const Color(0xFF0E7490),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _IncomingTile(
              label: 'Factory',
              stats: factory,
              icon: Icons.factory_outlined,
              color: const Color(0xFFD97706),
            ),
          ),
        ],
      ),
    );
  }
}

class _IncomingTile extends StatelessWidget {
  final String label;
  final _IncomingStats stats;
  final IconData icon;
  final Color color;

  const _IncomingTile(
      {required this.label,
      required this.stats,
      required this.icon,
      required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 108,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 18),
              const SizedBox(width: 6),
              Expanded(
                  child: Text(label,
                      style: TextStyle(
                          color: color,
                          fontWeight: FontWeight.w700,
                          fontSize: 12))),
            ],
          ),
          const Spacer(),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text('${fmt0(stats.bags)} bags',
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          ),
          Text('${stats.trucks} trucks',
              style: const TextStyle(color: Color(0xFF667085), fontSize: 10)),
        ],
      ),
    );
  }
}

class _BreakdownRow extends StatelessWidget {
  final String label;
  final String value;
  final String? detail;
  final double progress;
  final Color color;

  const _BreakdownRow({
    required this.label,
    required this.value,
    this.detail,
    required this.progress,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 12)),
            ),
            if (detail != null) ...[
              Text(detail!,
                  style:
                      const TextStyle(color: Color(0xFF667085), fontSize: 10)),
              const SizedBox(width: 9),
            ],
            Text(value,
                style:
                    const TextStyle(fontWeight: FontWeight.w800, fontSize: 12)),
          ],
        ),
        const SizedBox(height: 7),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            minHeight: 5,
            value: progress.clamp(0, 1),
            backgroundColor: const Color(0xFFEAECF0),
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
      ],
    );
  }
}

class _EmptyStats extends StatelessWidget {
  final String text;

  const _EmptyStats({required this.text});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 70,
      child: Center(
        child: Text(text,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFF98A2B3))),
      ),
    );
  }
}

class _DateWindow {
  final DateTime start;
  final DateTime end;

  const _DateWindow(this.start, this.end);

  bool contains(DateTime value) =>
      !value.isBefore(start) && value.isBefore(end);
}

class _StatsSnapshot {
  final double netSales;
  final double grossSales;
  final double returnValue;
  final double received;
  final double discount;
  final double netBags;
  final double grossBags;
  final double returnedBags;
  final double outstanding;
  final int orderCount;
  final int returnCount;
  final int walkInCount;
  final double walkInSales;
  final int customerCount;
  final List<_CategoryStats> categories;
  final List<MapEntry<String, double>> customerSales;
  final Map<PaymentType, double> paymentTypes;
  final Map<String, _IncomingStats> incoming;
  final List<_DailyTrendPoint> trend;

  const _StatsSnapshot({
    required this.netSales,
    required this.grossSales,
    required this.returnValue,
    required this.received,
    required this.discount,
    required this.netBags,
    required this.grossBags,
    required this.returnedBags,
    required this.outstanding,
    required this.orderCount,
    required this.returnCount,
    required this.walkInCount,
    required this.walkInSales,
    required this.customerCount,
    required this.categories,
    required this.customerSales,
    required this.paymentTypes,
    required this.incoming,
    required this.trend,
  });

  double get averageOrder => orderCount == 0 ? 0 : grossSales / orderCount;
}

class _CategoryStats {
  final String name;
  final double bags;
  final double sales;

  const _CategoryStats(this.name, {this.bags = 0, this.sales = 0});

  _CategoryStats copyWith({double? bags, double? sales}) =>
      _CategoryStats(name, bags: bags ?? this.bags, sales: sales ?? this.sales);
}

class _IncomingStats {
  final int trucks;
  final double bags;

  const _IncomingStats(this.trucks, this.bags);
}

class _DailyTrendPoint {
  final DateTime date;
  final String label;
  final double sales;
  final double received;
  final double bags;

  const _DailyTrendPoint(
      this.date, this.label, this.sales, this.received, this.bags);
}

double? _percentChange(double current, double previous) {
  if (previous.abs() < .001) return null;
  return ((current - previous) / previous.abs()) * 100;
}
