import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';

import '../core/enums.dart';
import '../services/excel_service.dart';
import '../services/godown_stock_store.dart';
import '../services/paths.dart';
import '../services/storage.dart';
import '../utils/date.dart';
import '../utils/snackbar.dart';
import '../widgets/app_panels.dart';

class DailyReportsScreen extends StatefulWidget {
  const DailyReportsScreen({super.key});
  @override
  State<DailyReportsScreen> createState() => _DailyReportsScreenState();
}

class _DailyReportsScreenState extends State<DailyReportsScreen>
    with AutomaticKeepAliveClientMixin {
  static const double _a4LandscapeWidth = 1400;
  static const double _a4LandscapeHeight = 990;
  static const TextStyle _sectionTitleStyle =
      TextStyle(fontSize: 18, fontWeight: FontWeight.w700);
  static const TextStyle _totalStyle =
      TextStyle(fontSize: 14, fontWeight: FontWeight.w600);
  static const TextStyle _lineStyle =
      TextStyle(fontSize: 12, color: Colors.black87);
  static const TextStyle _mutedStyle =
      TextStyle(fontSize: 12, color: Colors.black54);

  final ScrollController _scroll = ScrollController();
  final FocusNode _sortFocusDaily =
      FocusNode(skipTraversal: true, canRequestFocus: false);
  final GlobalKey _hisaabImageKey = GlobalKey();

  List<FileSystemEntity> _files = [];
  SortMode _sortReports = SortMode.newestFirst;
  Map<String, double> _sumTotal = {};
  Map<String, double> _sumPaid = {};
  Map<String, double> _sumRemaining = {};
  _HisaabImageData? _captureData;
  bool _showHisaabImageView = false;
  bool _hisaabViewLoading = false;
  DateTime _hisaabViewDay = DateTime.now();
  _HisaabImageData? _hisaabViewData;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _sortFocusDaily.dispose();
    super.dispose();
  }

  @override
  bool get wantKeepAlive => true;

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
  DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  Future<void> _load() async {
    final files = await listDailyReports();
    final invoices = await Store.loadAll();
    final agg = aggregateInvoiceSums(invoices, (inv) {
      final d = parseInvoiceDate(inv.date);
      return DateFormat('dd-MM-yyyy').format(d);
    });

    if (!mounted) return;
    setState(() {
      _files = files;
      _sumTotal = agg.total;
      _sumPaid = agg.paid;
      _sumRemaining = agg.remaining;
      _applyReportSort();
    });
  }

  void _applyReportSort() {
    String keyOf(FileSystemEntity e) {
      final name = e.path.split(Platform.pathSeparator).last;
      final m = RegExp(r'Sales_(\d{2}-\d{2}-\d{4})\.xlsx', caseSensitive: false)
          .firstMatch(name);
      return m != null ? m.group(1)! : '';
    }

    int byMetric(FileSystemEntity a, FileSystemEntity b,
        double Function(String) metric, bool desc) {
      final ka = keyOf(a), kb = keyOf(b);
      final va = metric(ka), vb = metric(kb);
      final cmp = va.compareTo(vb);
      return desc ? -cmp : cmp;
    }

    switch (_sortReports) {
      case SortMode.mostUnpaid:
        _files
            .sort((a, b) => byMetric(a, b, (k) => _sumRemaining[k] ?? 0, true));
        break;
      case SortMode.mostPaid:
        _files.sort((a, b) => byMetric(a, b, (k) => _sumPaid[k] ?? 0, true));
        break;
      case SortMode.mostSales:
        _files.sort((a, b) => byMetric(a, b, (k) => _sumTotal[k] ?? 0, true));
        break;
      case SortMode.leastSales:
        _files.sort((a, b) => byMetric(a, b, (k) => _sumTotal[k] ?? 0, false));
        break;
      case SortMode.newestFirst:
        _files.sort((a, b) {
          final ta = FileStat.statSync(a.path).changed;
          final tb = FileStat.statSync(b.path).changed;
          return tb.compareTo(ta);
        });
        break;
      case SortMode.oldestFirst:
        _files.sort((a, b) {
          final ta = FileStat.statSync(a.path).changed;
          final tb = FileStat.statSync(b.path).changed;
          return ta.compareTo(tb);
        });
        break;
    }
  }

  Future<_HisaabImageData> _buildHisaabImageData(DateTime day) async {
    final invoices = await Store.loadAll();
    final cfg = await GodownStockStore.loadConfig();
    final stockReport = await GodownStockStore.buildReport(until: day);

    final surjaniDetails = <_SurjaniDetailRow>[];
    final factoryMap = <String, double>{};
    final godownRows = <_GodownDetailRow>[];
    for (final inv in invoices) {
      DateTime d;
      try {
        d = parseInvoiceDate(inv.date);
      } catch (_) {
        continue;
      }
      if (!_sameDay(d, day)) continue;
      final site = inv.site.trim().toLowerCase();
      for (final l in inv.lines) {
        if (l.qty <= 0) continue;
        final sku = l.brand.trim().isEmpty ? '-' : l.brand.trim();
        final key = '${l.typeLabel}|$sku';
        if (site == 'surjani') {
          final name = inv.customer.trim();
          final address = inv.address.trim().isEmpty ? '-' : inv.address.trim();
          surjaniDetails.add(_SurjaniDetailRow(
            name: name.isEmpty ? '-' : name,
            address: address,
            category: l.typeLabel.trim().isEmpty ? '-' : l.typeLabel.trim(),
            brand: sku,
            qty: l.qty.toDouble(),
          ));
        } else if (site == 'factory') {
          factoryMap[key] = (factoryMap[key] ?? 0) + l.qty.toDouble();
        } else if (site == 'godown') {
          final name = inv.customer.trim();
          final address = inv.address.trim().isEmpty ? '-' : inv.address.trim();
          godownRows.add(_GodownDetailRow(
            name: name.isEmpty ? '-' : name,
            address: address,
            category: l.typeLabel,
            sku: sku,
            qty: l.qty.toDouble(),
          ));
        }
      }
    }
    godownRows.sort((a, b) {
      final c = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      if (c != 0) return c;
      return a.address.toLowerCase().compareTo(b.address.toLowerCase());
    });
    surjaniDetails.sort((a, b) {
      final c = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      if (c != 0) return c;
      return a.address.toLowerCase().compareTo(b.address.toLowerCase());
    });

    final stockInToday = <_StockInLine>[];
    for (final s in cfg.stockIns) {
      try {
        if (_sameDay(parseInvoiceDate(s.date), day)) {
          stockInToday.add(_StockInLine(
              truckNo: s.truckNo,
              category: s.category,
              sku: s.sku,
              qty: s.qty));
        }
      } catch (_) {}
    }
    stockInToday.sort(
        (a, b) => a.truckNo.toLowerCase().compareTo(b.truckNo.toLowerCase()));

    List<_QtyLine> asLines(Map<String, double> map) {
      final out = <_QtyLine>[];
      for (final e in map.entries) {
        final parts = e.key.split('|');
        out.add(_QtyLine(
            category: parts.first,
            sku: parts.length > 1 ? parts[1] : '-',
            qty: e.value));
      }
      out.sort((a, b) {
        final c = a.category.toLowerCase().compareTo(b.category.toLowerCase());
        if (c != 0) return c;
        return a.sku.toLowerCase().compareTo(b.sku.toLowerCase());
      });
      return out;
    }

    final endRows = <_StockRow>[];
    for (final r in stockReport.dailyRows) {
      if (!_sameDay(r.date, day)) continue;
      endRows.add(
          _StockRow(category: r.category, sku: r.sku, qty: r.remainingBags));
    }
    endRows.sort((a, b) {
      final c = a.category.toLowerCase().compareTo(b.category.toLowerCase());
      if (c != 0) return c;
      return a.sku.toLowerCase().compareTo(b.sku.toLowerCase());
    });

    return _HisaabImageData(
      day: day,
      surjaniDetails: surjaniDetails,
      stockInLines: stockInToday,
      factoryLines: asLines(factoryMap),
      godownSaleRows: godownRows,
      endOfDayStock: endRows,
    );
  }

  Future<File?> _exportHisaabImage(DateTime day) async {
    try {
      final data = await _buildHisaabImageData(day);
      if (!mounted) return null;
      setState(() => _captureData = data);
      await WidgetsBinding.instance.endOfFrame;
      await Future.delayed(const Duration(milliseconds: 60));

      final ctx = _hisaabImageKey.currentContext;
      final boundary = ctx?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return null;

      final image = await boundary.toImage(pixelRatio: 2.5);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final bytes = byteData?.buffer.asUint8List();
      if (bytes == null || bytes.isEmpty) return null;

      final dir = await subdir('daily_hisaab_images');
      final dayTag = DateFormat('yyyy-MM-dd').format(day);
      final file =
          File('${dir.path}${Platform.pathSeparator}Daily_Hisaab_$dayTag.png');
      await file.writeAsBytes(Uint8List.fromList(bytes), flush: true);
      return file;
    } catch (_) {
      return null;
    } finally {
      if (mounted) {
        setState(() => _captureData = null);
      }
    }
  }

  Future<void> _loadHisaabImageView({bool force = false}) async {
    if (_hisaabViewLoading) return;
    final current = _hisaabViewData;
    if (!force && current != null && _sameDay(current.day, _hisaabViewDay)) {
      return;
    }
    final requestedDay = _hisaabViewDay;
    setState(() => _hisaabViewLoading = true);
    try {
      final data = await _buildHisaabImageData(requestedDay);
      if (!mounted) return;
      if (!_sameDay(requestedDay, _hisaabViewDay)) {
        setState(() => _hisaabViewLoading = false);
        return;
      }
      setState(() {
        _hisaabViewData = data;
        _hisaabViewLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _hisaabViewLoading = false);
      showErr(context, 'Could not load hisaab image view');
    }
  }

  Future<void> _pickHisaabViewDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _hisaabViewDay,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null) return;
    setState(() {
      _hisaabViewDay = _dateOnly(picked);
      _hisaabViewData = null;
    });
    await _loadHisaabImageView(force: true);
  }

  Future<void> _exportCurrentHisaabImage() async {
    final file = await _exportHisaabImage(_hisaabViewDay);
    if (!mounted) return;
    if (file == null) {
      showErr(context, 'Could not export hisaab image');
      return;
    }
    showOk(context, 'Saved ${file.path.split(Platform.pathSeparator).last}');
  }

  Future<void> _exportRangeNow() async {
    DateTime from = _dateOnly(DateTime.now());
    DateTime to = _dateOnly(DateTime.now());

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Export Date Range'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('From'),
                subtitle: Text(dfDay.format(from)),
                trailing: const Icon(Icons.calendar_today),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: ctx,
                    initialDate: from,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (picked != null) {
                    setDialogState(() => from = _dateOnly(picked));
                  }
                },
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('To'),
                subtitle: Text(dfDay.format(to)),
                trailing: const Icon(Icons.calendar_today),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: ctx,
                    initialDate: to,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                  );
                  if (picked != null) {
                    setDialogState(() => to = _dateOnly(picked));
                  }
                },
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Export')),
          ],
        ),
      ),
    );

    if (ok != true) return;

    if (to.isBefore(from)) {
      if (!mounted) return;
      showErr(context, '"To" date must be same or after "From" date');
      return;
    }

    if (!mounted) return;
    showOk(context, 'Export started...');

    int salesCount = 0;
    int imageCount = 0;
    int imageFailCount = 0;
    final months = <String>{};

    for (DateTime d = from;
        !d.isAfter(to);
        d = d.add(const Duration(days: 1))) {
      final day = _dateOnly(d);
      try {
        await exportDailySalesExcel(day);
        salesCount++;
      } catch (_) {}
      final img = await _exportHisaabImage(day);
      if (img == null) {
        imageFailCount++;
      } else {
        imageCount++;
      }
      months.add(DateFormat('yyyy-MM').format(day));
    }

    for (final ym in months) {
      try {
        await exportMonthlySalesExcel(DateTime.parse('$ym-01'));
      } catch (_) {}
    }

    await _load();
    if (!mounted) return;
    if (imageFailCount > 0) {
      showErr(
        context,
        'Exported $salesCount sales file(s), $imageCount hisaab image(s). Failed images: $imageFailCount',
      );
      return;
    }
    showOk(
      context,
      'Exported $salesCount sales file(s) and $imageCount hisaab image(s)',
    );
  }

  Widget _compactLine(String text) {
    return Text(text,
        style: _lineStyle, maxLines: 1, overflow: TextOverflow.ellipsis);
  }

  Widget _qtyLinesBlock(String title, List<_QtyLine> lines) {
    final total = lines.fold<double>(0, (s, e) => s + e.qty);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: _sectionTitleStyle),
        const SizedBox(height: 3),
        Text('Total: ${total.toStringAsFixed(0)}', style: _totalStyle),
        const SizedBox(height: 3),
        if (lines.isEmpty)
          const Text('No entries', style: _mutedStyle)
        else
          ...lines.take(24).map((e) => _compactLine(
              '${e.category} | ${e.sku}: ${e.qty.toStringAsFixed(0)}')),
        if (lines.length > 24) const Text('...more', style: _mutedStyle),
      ],
    );
  }

  Widget _hisaabImageSheet(_HisaabImageData data) {
    final stockTotal = data.endOfDayStock.fold<double>(0, (s, e) => s + e.qty);
    final surjaniTotal =
        data.surjaniDetails.fold<double>(0, (s, e) => s + e.qty);
    return Container(
      width: _a4LandscapeWidth,
      height: _a4LandscapeHeight,
      color: Colors.white,
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Daily Hisaab ${formatInvoiceDate(data.day)}',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.black87, width: 1.5),
                borderRadius: BorderRadius.circular(4),
              ),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 52,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Surjani Details',
                                    style: _sectionTitleStyle),
                                const SizedBox(height: 3),
                                Text(
                                    'Total: ${surjaniTotal.toStringAsFixed(0)}',
                                    style: _totalStyle),
                                const SizedBox(height: 3),
                                if (data.surjaniDetails.isEmpty)
                                  const Text('No entries', style: _mutedStyle)
                                else
                                  ...data.surjaniDetails
                                      .take(22)
                                      .map((r) => _compactLine(
                                            '${r.name} | ${r.address} | ${r.category} ${r.brand} | ${r.qty.toStringAsFixed(0)}',
                                          )),
                                if (data.surjaniDetails.length > 22)
                                  const Text('...more', style: _mutedStyle),
                              ],
                            ),
                            const SizedBox(height: 14),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('Godown Stock-In',
                                    style: _sectionTitleStyle),
                                const SizedBox(height: 3),
                                Text(
                                  'Total: ${data.stockInLines.fold<double>(0, (s, e) => s + e.qty).toStringAsFixed(0)}',
                                  style: _totalStyle,
                                ),
                                const SizedBox(height: 3),
                                if (data.stockInLines.isEmpty)
                                  const Text('No entries', style: _mutedStyle)
                                else
                                  ...data.stockInLines
                                      .take(20)
                                      .map((s) => _compactLine(
                                            '${s.truckNo} | ${s.category} | ${s.sku}: ${s.qty.toStringAsFixed(0)}',
                                          )),
                                if (data.stockInLines.length > 20)
                                  const Text('...more', style: _mutedStyle),
                              ],
                            ),
                            const SizedBox(height: 14),
                            _qtyLinesBlock('Factory Sales', data.factoryLines),
                          ],
                        ),
                      ),
                    ),
                    Container(width: 1.5, color: Colors.black87),
                    Expanded(
                      flex: 48,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('Godown Sale Details',
                                      style: _sectionTitleStyle),
                                  const SizedBox(height: 4),
                                  if (data.godownSaleRows.isEmpty)
                                    const Text('No Godown sale details',
                                        style: _mutedStyle)
                                  else
                                    ...data.godownSaleRows
                                        .take(32)
                                        .map((r) => _compactLine(
                                              '${r.name} | ${r.address} | ${r.category} ${r.sku} | ${r.qty.toStringAsFixed(0)}',
                                            )),
                                  if (data.godownSaleRows.length > 32)
                                    const Padding(
                                      padding: EdgeInsets.only(top: 2),
                                      child:
                                          Text('...more', style: _mutedStyle),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          Container(height: 1.5, color: Colors.black87),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('Godown Stock At End Of Day',
                                      style: _sectionTitleStyle),
                                  const SizedBox(height: 3),
                                  Text(
                                      'Total: ${stockTotal.toStringAsFixed(0)}',
                                      style: _totalStyle),
                                  const SizedBox(height: 4),
                                  if (data.endOfDayStock.isEmpty)
                                    const Text('No stock data',
                                        style: _mutedStyle)
                                  else
                                    ...data.endOfDayStock
                                        .take(24)
                                        .map((r) => _compactLine(
                                              '${r.category} | ${r.sku} | ${r.qty.toStringAsFixed(0)}',
                                            )),
                                  if (data.endOfDayStock.length > 24)
                                    const Padding(
                                      padding: EdgeInsets.only(top: 2),
                                      child:
                                          Text('...more', style: _mutedStyle),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _viewModeToggle() {
    return SegmentedButton<bool>(
      segments: const [
        ButtonSegment<bool>(
          value: false,
          icon: Icon(Icons.table_chart_outlined),
          label: Text('Sheets'),
        ),
        ButtonSegment<bool>(
          value: true,
          icon: Icon(Icons.image_outlined),
          label: Text('Hisaab Image'),
        ),
      ],
      selected: {_showHisaabImageView},
      onSelectionChanged: (values) {
        final next = values.first;
        setState(() => _showHisaabImageView = next);
        if (next) {
          _loadHisaabImageView();
        }
      },
    );
  }

  Widget _hisaabImageViewCard() {
    final data = _hisaabViewData;
    return AppSoftCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AppSectionTitle(
            title: 'Daily Hisaab Image View',
            subtitle: 'Preview the same layout used for exported PNG images.',
            trailing: AppMetaChip(
              icon: Icons.calendar_today_outlined,
              text: formatInvoiceDate(_hisaabViewDay),
              backgroundColor: const Color(0xFFF3F6FA),
              borderColor: const Color(0xFFDCE5EE),
              foregroundColor: const Color(0xFF51607A),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                style: appGreenOutlineButtonStyle(context),
                onPressed: _hisaabViewLoading ? null : _pickHisaabViewDate,
                icon: const Icon(Icons.event_outlined),
                label: const Text('Pick Date'),
              ),
              OutlinedButton.icon(
                style: appGreenOutlineButtonStyle(context),
                onPressed: _hisaabViewLoading
                    ? null
                    : () => _loadHisaabImageView(force: true),
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh'),
              ),
              FilledButton.icon(
                style: appGreenButtonStyle(context),
                onPressed:
                    _hisaabViewLoading ? null : _exportCurrentHisaabImage,
                icon: const Icon(Icons.image_outlined),
                label: const Text('Export PNG'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (_hisaabViewLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 42),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (data == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 28),
              child: Text('Select or refresh a date to load the hisaab image.'),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final scale = (constraints.maxWidth / _a4LandscapeWidth)
                    .clamp(0.25, 1.0)
                    .toDouble();
                return SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(
                    width: _a4LandscapeWidth * scale,
                    height: _a4LandscapeHeight * scale,
                    child: Transform.scale(
                      scale: scale,
                      alignment: Alignment.topLeft,
                      child: _hisaabImageSheet(data),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Scrollbar(
          controller: _scroll,
          thumbVisibility: true,
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              controller: _scroll,
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
              children: [
                Wrap(
                  spacing: 12,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _viewModeToggle(),
                    FilledButton.icon(
                      style: appGreenButtonStyle(context),
                      onPressed: _exportRangeNow,
                      icon: const Icon(Icons.save_alt),
                      label: const Text('Export Date Range'),
                    ),
                    OutlinedButton.icon(
                      style: appGreenOutlineButtonStyle(context),
                      onPressed: () async {
                        final dir = await subdir('daily_sales');
                        await OpenFilex.open(dir.path);
                      },
                      icon: const Icon(Icons.folder_open),
                      label: const Text('Open Daily Reports Folder'),
                    ),
                    OutlinedButton.icon(
                      style: appGreenOutlineButtonStyle(context),
                      onPressed: () async {
                        final dir = await subdir('daily_hisaab_images');
                        await OpenFilex.open(dir.path);
                      },
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('Open Hisaab Images Folder'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (_showHisaabImageView)
                  _hisaabImageViewCard()
                else
                  AppSoftCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        AppSectionTitle(
                          title: 'Daily Sales Sheets',
                          subtitle:
                              'Export daily sales and keep hisaab images beside them.',
                          trailing: AppMetaChip(
                            icon: Icons.sort,
                            text: _sortLabel(_sortReports),
                            backgroundColor: const Color(0xFFF3F6FA),
                            borderColor: const Color(0xFFDCE5EE),
                            foregroundColor: const Color(0xFF51607A),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            const Text(
                              'Sort',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF364056),
                              ),
                            ),
                            DropdownButton<SortMode>(
                              focusNode: _sortFocusDaily,
                              value: _sortReports,
                              onChanged: (v) {
                                if (v != null) {
                                  setState(() {
                                    _sortReports = v;
                                    _applyReportSort();
                                  });
                                  FocusScope.of(context).unfocus();
                                  _sortFocusDaily.unfocus();
                                  FocusManager.instance.primaryFocus?.unfocus();
                                }
                              },
                              items: const [
                                DropdownMenuItem(
                                    value: SortMode.mostUnpaid,
                                    child: Text('Most Unpaid')),
                                DropdownMenuItem(
                                    value: SortMode.mostPaid,
                                    child: Text('Most Paid')),
                                DropdownMenuItem(
                                    value: SortMode.mostSales,
                                    child: Text('Most Sales')),
                                DropdownMenuItem(
                                    value: SortMode.leastSales,
                                    child: Text('Least Sales')),
                                DropdownMenuItem(
                                    value: SortMode.newestFirst,
                                    child: Text('Newest First')),
                                DropdownMenuItem(
                                    value: SortMode.oldestFirst,
                                    child: Text('Oldest First')),
                              ],
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),
                        if (_files.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 18),
                            child: Text('No daily sales files yet'),
                          )
                        else
                          ..._files.map(_reportFileTile),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (_captureData != null)
          Positioned(
            left: -5000,
            top: 0,
            child: IgnorePointer(
              child: Material(
                color: Colors.white,
                child: RepaintBoundary(
                  key: _hisaabImageKey,
                  child: _hisaabImageSheet(_captureData!),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _reportFileTile(FileSystemEntity entity) {
    final name = entity.path.split(Platform.pathSeparator).last;
    final stat = FileStat.statSync(entity.path);
    final sizeText = _sizeLabel(entity.path);
    final dateText = DateFormat('dd MMM yyyy, hh:mm a').format(stat.changed);
    final dayKey = _dayKeyFromSalesFile(name);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: AppSoftCard(
          backgroundColor: Colors.white,
          padding: const EdgeInsets.all(14),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: InkWell(
                  onTap: () => OpenFilex.open(entity.path),
                  borderRadius: BorderRadius.circular(14),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: const Color(0xFF172033),
                                  ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            AppMetaChip(
                              icon: Icons.folder_zip_outlined,
                              text: sizeText,
                              backgroundColor: const Color(0xFFF3F6FA),
                              borderColor: const Color(0xFFDCE5EE),
                              foregroundColor: const Color(0xFF51607A),
                            ),
                            AppMetaChip(
                              icon: Icons.schedule_outlined,
                              text: dateText,
                              backgroundColor: const Color(0xFFF3F6FA),
                              borderColor: const Color(0xFFDCE5EE),
                              foregroundColor: const Color(0xFF51607A),
                            ),
                            if (dayKey.isNotEmpty) ...[
                              AppMetaChip(
                                icon: Icons.payments_outlined,
                                text:
                                    'Total Rs ${(_sumTotal[dayKey] ?? 0).toStringAsFixed(0)}',
                              ),
                              AppMetaChip(
                                icon: Icons.account_balance_wallet_outlined,
                                text:
                                    'Paid Rs ${(_sumPaid[dayKey] ?? 0).toStringAsFixed(0)}',
                              ),
                              AppMetaChip(
                                icon: Icons.hourglass_bottom_outlined,
                                text:
                                    'Remaining Rs ${(_sumRemaining[dayKey] ?? 0).toStringAsFixed(0)}',
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _iconActionButton(
                    tooltip: 'Open',
                    icon: const Icon(Icons.open_in_new,
                        color: Color(0xFF273247), size: 20),
                    onPressed: () => OpenFilex.open(entity.path),
                  ),
                  _iconActionButton(
                    tooltip: 'Delete',
                    icon: const Icon(Icons.delete_outline,
                        color: Color(0xFFB42318), size: 20),
                    onPressed: () => _deleteFile(entity),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _iconActionButton({
    required String tooltip,
    required Widget icon,
    required VoidCallback onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onPressed,
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: const Color(0xFFF8FAFC),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xFFDCE5EE)),
            ),
            child: Center(child: icon),
          ),
        ),
      ),
    );
  }

  Future<void> _deleteFile(FileSystemEntity entity) async {
    final name = entity.path.split(Platform.pathSeparator).last;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete File?'),
        content: Text(name),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirm != true) return;
    await File(entity.path).delete();
    await _load();
    if (!mounted) return;
    showOk(context, 'Deleted $name');
  }

  String _sizeLabel(String path) {
    try {
      final bytes = File(path).lengthSync();
      final kb = bytes / 1024;
      return kb < 1024
          ? '${kb.toStringAsFixed(1)} KB'
          : '${(kb / 1024).toStringAsFixed(1)} MB';
    } catch (_) {
      return '?';
    }
  }

  String _dayKeyFromSalesFile(String name) {
    final match =
        RegExp(r'Sales_(\d{2}-\d{2}-\d{4})\.xlsx', caseSensitive: false)
            .firstMatch(name);
    return match?.group(1) ?? '';
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
}

class _QtyLine {
  final String category;
  final String sku;
  final double qty;
  const _QtyLine(
      {required this.category, required this.sku, required this.qty});
}

class _StockInLine {
  final String truckNo;
  final String category;
  final String sku;
  final double qty;
  const _StockInLine(
      {required this.truckNo,
      required this.category,
      required this.sku,
      required this.qty});
}

class _GodownDetailRow {
  final String name;
  final String address;
  final String category;
  final String sku;
  final double qty;
  const _GodownDetailRow({
    required this.name,
    required this.address,
    required this.category,
    required this.sku,
    required this.qty,
  });
}

class _StockRow {
  final String category;
  final String sku;
  final double qty;
  const _StockRow(
      {required this.category, required this.sku, required this.qty});
}

class _HisaabImageData {
  final DateTime day;
  final List<_SurjaniDetailRow> surjaniDetails;
  final List<_StockInLine> stockInLines;
  final List<_QtyLine> factoryLines;
  final List<_GodownDetailRow> godownSaleRows;
  final List<_StockRow> endOfDayStock;

  const _HisaabImageData({
    required this.day,
    required this.surjaniDetails,
    required this.stockInLines,
    required this.factoryLines,
    required this.godownSaleRows,
    required this.endOfDayStock,
  });
}

class _SurjaniDetailRow {
  final String name;
  final String address;
  final String category;
  final String brand;
  final double qty;
  const _SurjaniDetailRow({
    required this.name,
    required this.address,
    required this.category,
    required this.brand,
    required this.qty,
  });
}
