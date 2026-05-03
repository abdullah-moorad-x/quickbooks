import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';

import '../core/app_bus.dart';
import '../core/constants.dart';
import '../services/excel_service.dart';
import '../services/godown_stock_store.dart';
import '../utils/date.dart';
import '../utils/snackbar.dart';
import '../widgets/app_panels.dart';
import '../widgets/skeleton_loader.dart';

class GodownHisaabScreen extends StatefulWidget {
  final bool readOnly;
  final Future<void> Function()? onRefresh;

  const GodownHisaabScreen({
    super.key,
    this.readOnly = false,
    this.onRefresh,
  });

  @override
  State<GodownHisaabScreen> createState() => _GodownHisaabScreenState();
}

class _GodownHisaabScreenState extends State<GodownHisaabScreen>
    with AutomaticKeepAliveClientMixin {
  final _openingDateCtrl =
      TextEditingController(text: formatInvoiceDate(DateTime.now()));
  final _skuCtrl = TextEditingController();
  final _aliasesCtrl = TextEditingController();
  final _openingBagsCtrl = TextEditingController(text: '0');
  final _stockDateCtrl =
      TextEditingController(text: formatInvoiceDate(DateTime.now()));
  final _truckNoCtrl = TextEditingController();
  final _stockQtyCtrl = TextEditingController(text: '0');
  final _stockNoteCtrl = TextEditingController();
  final ScrollController _pageScrollCtrl = ScrollController();
  String _skuCategory = kItemTypes.first;
  String _stockCategory = kItemTypes.first;
  String? _stockSku;
  bool _showDailySkuHisaab = false;

  bool _loading = true;
  GodownStockReport? _report;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
    AppBus.dataTick.addListener(_load);
  }

  @override
  void dispose() {
    AppBus.dataTick.removeListener(_load);
    _openingDateCtrl.dispose();
    _skuCtrl.dispose();
    _aliasesCtrl.dispose();
    _openingBagsCtrl.dispose();
    _stockDateCtrl.dispose();
    _truckNoCtrl.dispose();
    _stockQtyCtrl.dispose();
    _stockNoteCtrl.dispose();
    _pageScrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final report = await GodownStockStore.buildReport();
    if (!mounted) return;
    final skuOptions = report.config.skus
        .where((e) => e.category == _stockCategory || e.category.isEmpty)
        .toList();
    setState(() {
      _report = report;
      _openingDateCtrl.text = report.config.openingDate;
      if (_stockSku == null || !skuOptions.any((e) => e.name == _stockSku)) {
        _stockSku = skuOptions.isEmpty ? null : skuOptions.first.name;
      }
      _loading = false;
    });
  }

  Future<void> _refresh() async {
    try {
      await widget.onRefresh?.call();
    } catch (e) {
      if (!mounted) return;
      showErr(context, e.toString());
    }
    await _load();
  }

  Future<void> _pickOpeningDate() async {
    DateTime initial;
    try {
      initial = parseInvoiceDate(_openingDateCtrl.text.trim());
    } catch (_) {
      initial = DateTime.now();
    }
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000, 1, 1),
      lastDate: DateTime(DateTime.now().year + 5),
    );
    if (picked == null) return;
    setState(() => _openingDateCtrl.text = formatInvoiceDate(picked));
  }

  Future<void> _saveOpeningDate() async {
    final raw = _openingDateCtrl.text.trim();
    if (raw.isEmpty) {
      showErr(context, 'Opening date is required');
      return;
    }
    try {
      parseInvoiceDate(raw);
    } catch (_) {
      showErr(context, 'Invalid opening date');
      return;
    }
    await GodownStockStore.saveOpeningDate(raw);
    await _load();
    if (!mounted) return;
    showOk(context, 'Opening date saved');
  }

  Future<void> _pickStockDate() async {
    DateTime initial;
    try {
      initial = parseInvoiceDate(_stockDateCtrl.text.trim());
    } catch (_) {
      initial = DateTime.now();
    }
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000, 1, 1),
      lastDate: DateTime(DateTime.now().year + 5),
    );
    if (picked == null) return;
    setState(() => _stockDateCtrl.text = formatInvoiceDate(picked));
  }

  Future<void> _saveSku() async {
    final sku = _skuCtrl.text.trim();
    if (sku.isEmpty) {
      showErr(context, 'SKU name is required');
      return;
    }
    final opening =
        double.tryParse(_openingBagsCtrl.text.trim().replaceAll(',', ''));
    if (opening == null) {
      showErr(context, 'Invalid opening bags');
      return;
    }
    final aliases = _aliasesCtrl.text
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    await GodownStockStore.upsertSku(
      name: sku,
      category: _skuCategory,
      openingBags: opening,
      aliases: aliases,
    );
    _skuCtrl.clear();
    _aliasesCtrl.clear();
    _openingBagsCtrl.text = '0';
    await _load();
    if (!mounted) return;
    showOk(context, 'SKU saved');
  }

  List<GodownSku> _stockSkuOptions(GodownStockReport report) {
    return report.config.skus
        .where((e) => e.category == _stockCategory || e.category.isEmpty)
        .toList();
  }

  Future<void> _addStockIn() async {
    final report = _report;
    if (report == null) return;
    final rawDate = _stockDateCtrl.text.trim();
    final truck = _truckNoCtrl.text.trim();
    final sku = _stockSku?.trim() ?? '';
    final qty = double.tryParse(_stockQtyCtrl.text.trim().replaceAll(',', ''));
    if (rawDate.isEmpty) {
      showErr(context, 'Stock date is required');
      return;
    }
    try {
      parseInvoiceDate(rawDate);
    } catch (_) {
      showErr(context, 'Invalid stock date');
      return;
    }
    if (truck.isEmpty) {
      showErr(context, 'Truck number is required');
      return;
    }
    if (sku.isEmpty) {
      showErr(context, 'Select SKU');
      return;
    }
    if (qty == null || qty <= 0) {
      showErr(context, 'Enter valid stock quantity');
      return;
    }
    final validSku = report.config.skus.any((e) => e.name == sku);
    if (!validSku) {
      showErr(context, 'Selected SKU not found');
      return;
    }
    await GodownStockStore.addStockIn(
      date: rawDate,
      truckNo: truck,
      category: _stockCategory,
      sku: sku,
      qty: qty,
      note: _stockNoteCtrl.text.trim(),
    );
    _truckNoCtrl.clear();
    _stockQtyCtrl.text = '0';
    _stockNoteCtrl.clear();
    await _load();
    if (!mounted) return;
    showOk(context, 'Stock-in entry saved');
  }

  Future<void> _deleteStockIn(String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete Stock Entry'),
        content: const Text('Delete this stock-in record?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await GodownStockStore.deleteStockIn(id);
    await _load();
  }

  Future<void> _deleteSku(String sku, String category) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete SKU'),
        content: Text('Delete "$sku" in $category?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await GodownStockStore.deleteSku(sku, category);
    await _load();
  }

  Future<void> _exportExcel() async {
    try {
      final file = await exportGodownDailyRemainingExcel();
      await OpenFilex.open(file.path);
    } catch (_) {
      if (!mounted) return;
      showErr(context, 'Could not export godown Excel');
    }
  }

  void _prefillSku(GodownSkuBalance b) {
    final cfg = _report?.config.skus.firstWhere(
      (e) =>
          e.name.toLowerCase() == b.sku.toLowerCase() &&
          e.category.toLowerCase() == b.category.toLowerCase(),
      orElse: () => GodownSku(
          name: b.sku,
          category: b.category,
          aliases: const [],
          openingBags: b.openingBags),
    );
    setState(() {
      _skuCtrl.text = b.sku;
      _skuCategory = (cfg?.category.isNotEmpty == true &&
              kItemTypes.contains(cfg?.category))
          ? cfg!.category
          : kItemTypes.first;
      _openingBagsCtrl.text = b.openingBags.toStringAsFixed(0);
      _aliasesCtrl.text = cfg?.aliases.join(', ') ?? '';
    });
    if (_pageScrollCtrl.hasClients) {
      _pageScrollCtrl.animateTo(
        0,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
      );
    }
    showOk(context, 'Loaded "${b.sku}" (${b.category}) into form for edit');
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading || _report == null) {
      return const AppSkeletonLoader();
    }
    final report = _report!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 980;
        final showReadOnlyMobileStock =
            widget.readOnly && constraints.maxWidth < 700;
        final content = Scrollbar(
          controller: _pageScrollCtrl,
          thumbVisibility: true,
          scrollbarOrientation: ScrollbarOrientation.right,
          child: SingleChildScrollView(
            controller: _pageScrollCtrl,
            physics: const AlwaysScrollableScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!widget.readOnly) ...[
                    AppSoftCard(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          crossAxisAlignment: WrapCrossAlignment.end,
                          children: [
                            SizedBox(
                              width: 170,
                              child: TextField(
                                controller: _openingDateCtrl,
                                readOnly: true,
                                onTap: _pickOpeningDate,
                                decoration: const InputDecoration(
                                  labelText: 'Opening Date',
                                  suffixIcon:
                                      Icon(Icons.calendar_today, size: 18),
                                ),
                              ),
                            ),
                            FilledButton.tonalIcon(
                              style: appGreenButtonStyle(context),
                              onPressed: _saveOpeningDate,
                              icon: const Icon(Icons.save),
                              label: const Text('Save Date'),
                            ),
                            FilledButton.tonalIcon(
                              style: appGreenButtonStyle(context),
                              onPressed: _exportExcel,
                              icon: const Icon(Icons.file_download),
                              label: const Text('Export Excel'),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      _chip('Total Opening', report.totalOpening),
                      _chip('Total Stock-In', report.totalStocked),
                      _chip('Total Sold', report.totalSold),
                      _chip('Total Remaining', report.totalRemaining),
                      _chip(
                          'Unmapped Lines', report.unmapped.length.toDouble()),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (!widget.readOnly) ...[
                    AppSoftCard(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          crossAxisAlignment: WrapCrossAlignment.end,
                          children: [
                            SizedBox(
                              width: 220,
                              child: TextField(
                                controller: _skuCtrl,
                                decoration: const InputDecoration(
                                    labelText: 'SKU Name'),
                              ),
                            ),
                            SizedBox(
                              width: 190,
                              child: DropdownButtonFormField<String>(
                                key: ValueKey('godown-sku-cat-$_skuCategory'),
                                initialValue: _skuCategory,
                                items: kItemTypes
                                    .map((t) => DropdownMenuItem(
                                        value: t, child: Text(t)))
                                    .toList(),
                                onChanged: (v) => setState(
                                    () => _skuCategory = v ?? kItemTypes.first),
                                decoration: const InputDecoration(
                                    labelText: 'Category'),
                              ),
                            ),
                            SizedBox(
                              width: 180,
                              child: TextField(
                                controller: _openingBagsCtrl,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                    labelText: 'Opening Bags'),
                              ),
                            ),
                            SizedBox(
                              width: 320,
                              child: TextField(
                                controller: _aliasesCtrl,
                                decoration: const InputDecoration(
                                    labelText: 'Aliases (comma separated)'),
                              ),
                            ),
                            FilledButton.tonalIcon(
                              style: appGreenButtonStyle(context),
                              onPressed: _saveSku,
                              icon: const Icon(Icons.add),
                              label: const Text('Save SKU'),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    AppSoftCard(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          crossAxisAlignment: WrapCrossAlignment.end,
                          children: [
                            SizedBox(
                              width: 160,
                              child: TextField(
                                controller: _stockDateCtrl,
                                readOnly: true,
                                onTap: _pickStockDate,
                                decoration: const InputDecoration(
                                  labelText: 'Stock Date',
                                  suffixIcon:
                                      Icon(Icons.calendar_today, size: 18),
                                ),
                              ),
                            ),
                            SizedBox(
                              width: 180,
                              child: TextField(
                                controller: _truckNoCtrl,
                                decoration: const InputDecoration(
                                    labelText: 'Truck Number'),
                              ),
                            ),
                            SizedBox(
                              width: 180,
                              child: DropdownButtonFormField<String>(
                                key: ValueKey('stock-cat-$_stockCategory'),
                                initialValue: _stockCategory,
                                items: kItemTypes
                                    .map((t) => DropdownMenuItem(
                                        value: t, child: Text(t)))
                                    .toList(),
                                onChanged: (v) {
                                  final next = v ?? kItemTypes.first;
                                  final options = report.config.skus
                                      .where((e) =>
                                          e.category == next ||
                                          e.category.isEmpty)
                                      .toList();
                                  setState(() {
                                    _stockCategory = next;
                                    _stockSku = options.isEmpty
                                        ? null
                                        : options.first.name;
                                  });
                                },
                                decoration: const InputDecoration(
                                    labelText: 'Stock Category'),
                              ),
                            ),
                            SizedBox(
                              width: 220,
                              child: DropdownButtonFormField<String>(
                                key: ValueKey(
                                    'stock-sku-${_stockSku ?? ''}-$_stockCategory'),
                                initialValue: _stockSku,
                                items: _stockSkuOptions(report)
                                    .map((s) => DropdownMenuItem(
                                        value: s.name, child: Text(s.name)))
                                    .toList(),
                                onChanged: (v) => setState(() => _stockSku = v),
                                decoration:
                                    const InputDecoration(labelText: 'SKU'),
                              ),
                            ),
                            SizedBox(
                              width: 140,
                              child: TextField(
                                controller: _stockQtyCtrl,
                                keyboardType: TextInputType.number,
                                decoration:
                                    const InputDecoration(labelText: 'Qty'),
                              ),
                            ),
                            SizedBox(
                              width: 220,
                              child: TextField(
                                controller: _stockNoteCtrl,
                                decoration: const InputDecoration(
                                    labelText: 'Note (optional)'),
                              ),
                            ),
                            FilledButton.tonalIcon(
                              style: appGreenButtonStyle(context),
                              onPressed: _addStockIn,
                              icon: const Icon(Icons.local_shipping_outlined),
                              label: const Text('Add Stock-In'),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 220,
                      child: AppSoftCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Padding(
                              padding: EdgeInsets.fromLTRB(12, 10, 12, 6),
                              child: Text('Recent Truck Stock-In',
                                  style:
                                      TextStyle(fontWeight: FontWeight.w700)),
                            ),
                            Expanded(
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: SingleChildScrollView(
                                  child: _sheetTable(
                                    columns: const [
                                      DataColumn(label: Text('Date')),
                                      DataColumn(label: Text('Truck')),
                                      DataColumn(label: Text('Category')),
                                      DataColumn(label: Text('SKU')),
                                      DataColumn(label: Text('Qty')),
                                      DataColumn(label: Text('Note')),
                                      DataColumn(label: Text('')),
                                    ],
                                    rows: [
                                      for (final e in report
                                          .config.stockIns.reversed
                                          .take(120))
                                        DataRow(cells: [
                                          DataCell(Text(e.date)),
                                          DataCell(Text(e.truckNo)),
                                          DataCell(Text(e.category)),
                                          DataCell(Text(e.sku)),
                                          DataCell(
                                              Text(e.qty.toStringAsFixed(0))),
                                          DataCell(Text(e.note ?? '')),
                                          DataCell(
                                            IconButton(
                                              tooltip: 'Delete stock-in',
                                              icon: const Icon(
                                                  Icons.delete_outline,
                                                  size: 18,
                                                  color: Color(0xFFB71C1C)),
                                              onPressed: () =>
                                                  _deleteStockIn(e.id),
                                            ),
                                          ),
                                        ]),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  if (showReadOnlyMobileStock)
                    SizedBox(
                      height: 420,
                      child: _skuHisaabPanel(report),
                    )
                  else if (isNarrow) ...[
                    SizedBox(
                      height: 360,
                      child: _skuHisaabPanel(report),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(height: 320, child: _unmappedTable(report)),
                  ] else
                    SizedBox(
                      height: 360,
                      child: Row(
                        children: [
                          Expanded(
                            child: _skuHisaabPanel(report),
                          ),
                          const SizedBox(width: 10),
                          Expanded(child: _unmappedTable(report)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
        if (widget.onRefresh == null) return content;
        return RefreshIndicator(
          onRefresh: _refresh,
          child: content,
        );
      },
    );
  }

  Widget _skuHisaabPanel(GodownStockReport report) {
    final rows = [...report.dailyRows]..sort((a, b) {
        final d = b.date.compareTo(a.date);
        if (d != 0) return d;
        final c = a.category.toLowerCase().compareTo(b.category.toLowerCase());
        if (c != 0) return c;
        return a.sku.toLowerCase().compareTo(b.sku.toLowerCase());
      });
    return AppSoftCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _showDailySkuHisaab ? 'SKU Hisaab (Per Day)' : 'SKU Hisaab',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                _modeChip(
                  label: 'Summary',
                  selected: !_showDailySkuHisaab,
                  onTap: () => setState(() => _showDailySkuHisaab = false),
                ),
                const SizedBox(width: 8),
                _modeChip(
                  label: 'Daily Details',
                  selected: _showDailySkuHisaab,
                  onTap: () => setState(() => _showDailySkuHisaab = true),
                ),
              ],
            ),
          ),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              switchInCurve: Curves.easeOut,
              switchOutCurve: Curves.easeIn,
              child: SingleChildScrollView(
                key: ValueKey(_showDailySkuHisaab),
                scrollDirection: Axis.horizontal,
                child: SingleChildScrollView(
                  child: _sheetTable(
                    columns: _showDailySkuHisaab
                        ? const [
                            DataColumn(label: Text('Date')),
                            DataColumn(label: Text('SKU')),
                            DataColumn(label: Text('Category')),
                            DataColumn(label: Text('Stock-In Today')),
                            DataColumn(label: Text('Sold Today')),
                            DataColumn(label: Text('Remaining')),
                          ]
                        : [
                            const DataColumn(label: Text('SKU')),
                            const DataColumn(label: Text('Category')),
                            const DataColumn(label: Text('Opening')),
                            const DataColumn(label: Text('Stock-In')),
                            const DataColumn(label: Text('Sold')),
                            const DataColumn(label: Text('Remaining')),
                            if (!widget.readOnly)
                              const DataColumn(label: Text('Actions')),
                          ],
                    rows: _showDailySkuHisaab
                        ? [
                            for (final r in rows)
                              DataRow(cells: [
                                DataCell(Text(formatInvoiceDate(r.date))),
                                DataCell(Text(r.sku)),
                                DataCell(Text(r.category)),
                                DataCell(
                                    Text(r.stockedToday.toStringAsFixed(0))),
                                DataCell(Text(r.soldToday.toStringAsFixed(0))),
                                DataCell(
                                    Text(r.remainingBags.toStringAsFixed(0))),
                              ]),
                          ]
                        : [
                            for (final b in report.balances)
                              DataRow(cells: [
                                DataCell(Text(b.sku)),
                                DataCell(Text(b.category)),
                                DataCell(
                                    Text(b.openingBags.toStringAsFixed(0))),
                                DataCell(
                                    Text(b.stockedTillDate.toStringAsFixed(0))),
                                DataCell(
                                    Text(b.soldTillDate.toStringAsFixed(0))),
                                DataCell(
                                    Text(b.remainingBags.toStringAsFixed(0))),
                                if (!widget.readOnly)
                                  DataCell(
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          tooltip: 'Edit',
                                          icon:
                                              const Icon(Icons.edit, size: 18),
                                          onPressed: () => _prefillSku(b),
                                        ),
                                        IconButton(
                                          tooltip: 'Delete',
                                          icon: const Icon(Icons.delete_outline,
                                              size: 18,
                                              color: Color(0xFFB71C1C)),
                                          onPressed: () =>
                                              _deleteSku(b.sku, b.category),
                                        ),
                                      ],
                                    ),
                                  ),
                              ]),
                          ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _unmappedTable(GodownStockReport report) {
    return AppSoftCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Text('Unmapped Invoice Brands',
                style: TextStyle(fontWeight: FontWeight.w700)),
          ),
          if (report.unmapped.isEmpty)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('No unmapped brands. Deduction is fully matched.'),
            )
          else
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SingleChildScrollView(
                  child: _sheetTable(
                    columns: const [
                      DataColumn(label: Text('Date')),
                      DataColumn(label: Text('Invoice')),
                      DataColumn(label: Text('Type')),
                      DataColumn(label: Text('Brand Text')),
                      DataColumn(label: Text('Qty')),
                    ],
                    rows: [
                      for (final r in report.unmapped.take(400))
                        DataRow(cells: [
                          DataCell(Text(formatInvoiceDate(r.date))),
                          DataCell(Text('#${r.invoiceNo}')),
                          DataCell(Text(r.typeLabel)),
                          DataCell(Text(r.brandText)),
                          DataCell(Text(r.qty.toStringAsFixed(0))),
                        ]),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _chip(String label, double value) {
    return AppMetaChip(
      text: '$label: ${value.toStringAsFixed(0)}',
      backgroundColor: const Color(0xFFF8FAFC),
      borderColor: const Color(0xFFDCE5EE),
      foregroundColor: const Color(0xFF273247),
    );
  }

  DataTable _sheetTable({
    required List<DataColumn> columns,
    required List<DataRow> rows,
  }) {
    return DataTable(
      headingRowHeight: 52,
      dataRowMinHeight: 46,
      dataRowMaxHeight: 52,
      columnSpacing: 28,
      headingTextStyle: const TextStyle(
        fontWeight: FontWeight.w700,
        color: Color(0xFF22304A),
        fontSize: 15,
      ),
      dataTextStyle: const TextStyle(
        color: Color(0xFF384357),
        fontSize: 14,
      ),
      columns: columns,
      rows: rows,
    );
  }

  Widget _modeChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF0D8EA0) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? const Color(0xFF0D8EA0) : const Color(0xFFD6E0E8),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selected) ...[
              const Icon(Icons.check, size: 16, color: Colors.white),
              const SizedBox(width: 6),
            ],
            Text(
              label,
              style: TextStyle(
                color: selected ? Colors.white : const Color(0xFF273247),
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
