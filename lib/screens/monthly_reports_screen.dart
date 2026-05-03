import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';

import '../core/enums.dart';
import '../services/excel_service.dart';
import '../services/storage.dart';
import '../services/paths.dart';
import '../utils/date.dart';
import '../utils/snackbar.dart';
import '../widgets/app_panels.dart';

class MonthlyReportsScreen extends StatefulWidget {
  const MonthlyReportsScreen({super.key});
  @override
  State<MonthlyReportsScreen> createState() => _MonthlyReportsScreenState();
}

class _MonthlyReportsScreenState extends State<MonthlyReportsScreen>
    with AutomaticKeepAliveClientMixin {
  final ScrollController _scroll = ScrollController();
  DateTime _selectedProfitLossMonth =
      DateTime(DateTime.now().year, DateTime.now().month);
  List<FileSystemEntity> _files = [];
  List<FileSystemEntity> _profitLossFiles = [];
  SortMode _sortReports = SortMode.newestFirst;
  Map<String, double> _sumTotal = {};
  Map<String, double> _sumPaid = {};
  Map<String, double> _sumRemaining = {};
  final FocusNode _sortFocusMonthly =
      FocusNode(skipTraversal: true, canRequestFocus: false);
  @override
  bool get wantKeepAlive => true;
  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _sortFocusMonthly.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final files = await listMonthlyReports();
    final profitLossFiles = await listMonthlyProfitLossReports();
    final invoices = await Store.loadAll();
    final agg = aggregateInvoiceSums(invoices, (inv) {
      final d = parseInvoiceDate(inv.date);
      return DateFormat('yyyy-MM').format(d);
    });
    if (!mounted) return;
    setState(() {
      _files = files;
      _profitLossFiles = profitLossFiles;
      _sumTotal = agg.total;
      _sumPaid = agg.paid;
      _sumRemaining = agg.remaining;
      _applyReportSort();
    });
  }

  void _applyReportSort() {
    String keyOf(FileSystemEntity e) {
      final name = e.path.split(Platform.pathSeparator).last;
      final m = RegExp(r'Sales_(\d{4}-\d{2})\.xlsx', caseSensitive: false)
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

  Future<void> _pickProfitLossMonth() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedProfitLossMonth,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1, 12, 31),
      helpText: 'Select P&L Month',
    );
    if (picked == null || !mounted) return;
    setState(() {
      _selectedProfitLossMonth = DateTime(picked.year, picked.month);
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scrollbar(
      controller: _scroll,
      thumbVisibility: true,
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          controller: _scroll,
          physics: const ClampingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
          children: [
            Wrap(spacing: 12, runSpacing: 10, children: [
              FilledButton.icon(
                style: appGreenButtonStyle(context),
                onPressed: () async {
                  final f = await exportMonthlySalesExcel(DateTime.now());
                  await _load();
                  if (!mounted) return;
                  showOk(this.context,
                      'Saved: ${f.path.split(Platform.pathSeparator).last}');
                },
                icon: const Icon(Icons.save_alt),
                label: const Text('Export This Month Now'),
              ),
              FilledButton.icon(
                style: appGreenButtonStyle(context),
                onPressed: () async {
                  final f = await exportMonthlyProfitLossExcel(
                    _selectedProfitLossMonth,
                  );
                  await _load();
                  if (!mounted) return;
                  showOk(this.context,
                      'Saved: ${f.path.split(Platform.pathSeparator).last}');
                },
                icon: const Icon(Icons.assessment_outlined),
                label: Text(
                  'Export ${DateFormat('MMM yyyy').format(_selectedProfitLossMonth)} P&L',
                ),
              ),
              OutlinedButton.icon(
                style: appGreenOutlineButtonStyle(context),
                onPressed: _pickProfitLossMonth,
                icon: const Icon(Icons.calendar_month),
                label: Text(
                  DateFormat('MMM yyyy').format(_selectedProfitLossMonth),
                ),
              ),
              OutlinedButton.icon(
                style: appGreenOutlineButtonStyle(context),
                onPressed: () async {
                  final dir = await subdir('monthly_sales');
                  await OpenFilex.open(dir.path);
                },
                icon: const Icon(Icons.folder_open),
                label: const Text('Open Monthly Reports Folder'),
              ),
              OutlinedButton.icon(
                style: appGreenOutlineButtonStyle(context),
                onPressed: () async {
                  final dir = await subdir('monthly_profit_loss');
                  await OpenFilex.open(dir.path);
                },
                icon: const Icon(Icons.folder_copy_outlined),
                label: const Text('Open P&L Folder'),
              ),
            ]),
            const SizedBox(height: 12),
            AppSoftCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AppSectionTitle(
                    title: 'Monthly Sales Sheets',
                    subtitle:
                        'Export, open, and review monthly sales workbooks.',
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
                        focusNode: _sortFocusMonthly,
                        value: _sortReports,
                        onChanged: (v) {
                          if (v != null) {
                            setState(() {
                              _sortReports = v;
                              _applyReportSort();
                            });
                            FocusScope.of(context).unfocus();
                            _sortFocusMonthly.unfocus();
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
                      child: Text('No monthly sales files yet'),
                    )
                  else
                    ..._files
                        .map((e) => _reportFileTile(e, includeTotals: true)),
                ],
              ),
            ),
            const SizedBox(height: 20),
            AppSoftCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const AppSectionTitle(
                    title: 'Profit & Loss Sheets',
                    subtitle: 'Stored monthly P&L exports for quick reopening.',
                  ),
                  const SizedBox(height: 14),
                  if (_profitLossFiles.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 18),
                      child: Text('No monthly P&L files yet'),
                    )
                  else
                    ..._profitLossFiles
                        .map((e) => _reportFileTile(e, includeTotals: false)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _reportFileTile(FileSystemEntity entity,
      {required bool includeTotals}) {
    final name = entity.path.split(Platform.pathSeparator).last;
    final stat = FileStat.statSync(entity.path);
    final sizeText = _sizeLabel(entity.path);
    final dateText = DateFormat('dd MMM yyyy, hh:mm a').format(stat.changed);
    final monthKey = _monthKeyFromSalesFile(name);

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
                            if (includeTotals && monthKey.isNotEmpty) ...[
                              AppMetaChip(
                                icon: Icons.payments_outlined,
                                text:
                                    'Total Rs ${(_sumTotal[monthKey] ?? 0).toStringAsFixed(0)}',
                              ),
                              AppMetaChip(
                                icon: Icons.account_balance_wallet_outlined,
                                text:
                                    'Paid Rs ${(_sumPaid[monthKey] ?? 0).toStringAsFixed(0)}',
                              ),
                              AppMetaChip(
                                icon: Icons.hourglass_bottom_outlined,
                                text:
                                    'Remaining Rs ${(_sumRemaining[monthKey] ?? 0).toStringAsFixed(0)}',
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
                    icon: const Icon(
                      Icons.open_in_new,
                      color: Color(0xFF273247),
                      size: 20,
                    ),
                    onPressed: () => OpenFilex.open(entity.path),
                  ),
                  _iconActionButton(
                    tooltip: 'Delete',
                    icon: const Icon(
                      Icons.delete_outline,
                      color: Color(0xFFB42318),
                      size: 20,
                    ),
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
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
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

  String _monthKeyFromSalesFile(String name) {
    final match = RegExp(r'Sales_(\d{4}-\d{2})\.xlsx', caseSensitive: false)
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
