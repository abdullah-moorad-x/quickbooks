import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';

import '../core/enums.dart';
import '../services/excel_service.dart';
import '../services/paths.dart';
import '../services/storage.dart';
import '../utils/date.dart';
import '../utils/snackbar.dart';

class DailyReportsScreen extends StatefulWidget {
  const DailyReportsScreen({super.key});
  @override State<DailyReportsScreen> createState() => _DailyReportsScreenState();
}

class _DailyReportsScreenState extends State<DailyReportsScreen> with AutomaticKeepAliveClientMixin {
  final ScrollController _scroll = ScrollController();
  List<FileSystemEntity> _files = [];
  SortMode _sortReports = SortMode.newestFirst;
  Map<String,double> _sumTotal = {};
  Map<String,double> _sumPaid = {};
  Map<String,double> _sumRemaining = {};
  final FocusNode _sortFocusDaily = FocusNode(skipTraversal: true, canRequestFocus: false);
  @override void initState(){ super.initState(); _load(); }
  @override void dispose(){ _scroll.dispose(); _sortFocusDaily.dispose(); super.dispose(); }

  Future<void> _load() async {
    final files = await listDailyReports();
    final invoices = await Store.loadAll();
    final agg = aggregateInvoiceSums(invoices, (inv){ final d = parseInvoiceDate(inv.date); return DateFormat('dd-MM-yyyy').format(d); });
    if (!mounted) return;
    setState(() { _files = files; _sumTotal = agg.total; _sumPaid = agg.paid; _sumRemaining = agg.remaining; _applyReportSort(); });
  }
  
  void _applyReportSort(){
    String keyOf(FileSystemEntity e){
      final name = e.path.split(Platform.pathSeparator).last;
      final m = RegExp(r'Sales_(\d{2}-\d{2}-\d{4})\.xlsx', caseSensitive:false).firstMatch(name);
      return m != null ? m.group(1)! : '';
    }
    int byMetric(FileSystemEntity a, FileSystemEntity b, double Function(String) metric, bool desc){
      final ka = keyOf(a), kb = keyOf(b);
      final va = metric(ka), vb = metric(kb);
      final cmp = va.compareTo(vb);
      return desc ? -cmp : cmp;
    }
    switch(_sortReports){
      case SortMode.mostUnpaid: _files.sort((a,b)=>byMetric(a,b,(k)=>_sumRemaining[k] ?? 0,true)); break;
      case SortMode.mostPaid: _files.sort((a,b)=>byMetric(a,b,(k)=>_sumPaid[k] ?? 0,true)); break;
      case SortMode.mostSales: _files.sort((a,b)=>byMetric(a,b,(k)=>_sumTotal[k] ?? 0,true)); break;
      case SortMode.leastSales: _files.sort((a,b)=>byMetric(a,b,(k)=>_sumTotal[k] ?? 0,false)); break;
      case SortMode.newestFirst:
        _files.sort((a,b){ final ta = FileStat.statSync(a.path).changed; final tb = FileStat.statSync(b.path).changed; return tb.compareTo(ta); });
        break;
      case SortMode.oldestFirst:
        _files.sort((a,b){ final ta = FileStat.statSync(a.path).changed; final tb = FileStat.statSync(b.path).changed; return ta.compareTo(tb); });
        break;
    }
  }

  @override bool get wantKeepAlive => true;
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
          children: [
            Wrap(spacing: 12, runSpacing: 8, children: [
              FilledButton.icon(
                onPressed: () async {
                  final f = await exportDailySalesExcel(DateTime.now());
                  await exportMonthlySalesExcel(DateTime.now());
                  await _load();
                  if (!mounted) return;
                  // ignore: use_build_context_synchronously
                  showOk(context, 'Saved: ${f.path.split(Platform.pathSeparator).last}');
                },
                icon: const Icon(Icons.save_alt),
                label: const Text('Export Today Now'),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  final dir = await subdir('daily_sales');
                  await OpenFilex.open(dir.path);
                },
                icon: const Icon(Icons.folder_open),
                label: const Text('Open Daily Reports Folder'),
              ),
            ]),
            const SizedBox(height: 12),
            Row(children: [
              const SizedBox(width: 8),
              const Text('Sort:'),
              const SizedBox(width: 8),
              DropdownButton<SortMode>(
                focusNode: _sortFocusDaily,
                value: _sortReports,
                onChanged: (v) { if (v != null) { setState(() { _sortReports = v; _applyReportSort(); }); FocusScope.of(context).unfocus(); _sortFocusDaily.unfocus(); FocusManager.instance.primaryFocus?.unfocus(); } },
                items: const [
                  DropdownMenuItem(value: SortMode.mostUnpaid, child: Text('Most Unpaid')),
                  DropdownMenuItem(value: SortMode.mostPaid, child: Text('Most Paid')),
                  DropdownMenuItem(value: SortMode.mostSales, child: Text('Most Sales')),
                  DropdownMenuItem(value: SortMode.leastSales, child: Text('Least Sales')),
                  DropdownMenuItem(value: SortMode.newestFirst, child: Text('Newest First')),
                  DropdownMenuItem(value: SortMode.oldestFirst, child: Text('Oldest First')),
                ],
              ),
            ]),
            const SizedBox(height: 8),
            if (_files.isEmpty)
              const Center(child: Padding(padding: EdgeInsets.all(24.0), child: Text('No daily sales files yet'))),
            ..._files.map((e) => MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Card(
                child: ListTile(
                  title: Text(e.path.split(Platform.pathSeparator).last),
                  subtitle: Builder(builder: (context) {
                    String sizeText;
                    try { final bytes = File(e.path).lengthSync(); final kb = bytes / 1024; sizeText = kb < 1024 ? '${kb.toStringAsFixed(1)} KB' : '${(kb / 1024).toStringAsFixed(1)} MB'; } catch (_) { sizeText = '?'; }
                    final created = FileStat.statSync(e.path).changed;
                    final dateText = DateFormat('dd MMM yyyy, hh:mm a').format(created);
                    final name = e.path.split(Platform.pathSeparator).last;
                    final m = RegExp(r'Sales_(\d{2}-\d{2}-\d{4})\.xlsx', caseSensitive: false).firstMatch(name);
                    final key = m != null ? m.group(1)! : '';
                    final t = (_sumTotal[key] ?? 0).toStringAsFixed(0);
                    final p = (_sumPaid[key] ?? 0).toStringAsFixed(0);
                    final r = (_sumRemaining[key] ?? 0).toStringAsFixed(0);
                    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('$sizeText   |   $dateText', style: const TextStyle(fontSize: 12, color: Colors.black54)),
                      const SizedBox(height: 2),
                      Text('Total: Rs $t   |   Paid: Rs $p   |   Remaining: Rs $r', style: const TextStyle(fontSize: 12, color: Colors.black87)),
                    ]);
                  }),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(tooltip: 'Open', icon: const Icon(Icons.open_in_new), onPressed: () => OpenFilex.open(e.path)),
                    IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline, color: Colors.redAccent), onPressed: () async {
                      final confirm = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(title: const Text('Delete File?'), content: Text(e.path.split(Platform.pathSeparator).last), actions: [ TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')), TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')), ],),);
                      if (confirm == true) {
                        await File(e.path).delete();
                        await _load();
                        if (!mounted) return;
                        // ignore: use_build_context_synchronously
                        showOk(context, 'Deleted ${e.path.split(Platform.pathSeparator).last}');
                      }
                    }),
                  ]),
                  onTap: () => OpenFilex.open(e.path),
                ),
              ),
            )),
          ],
        ),
      ),
    );
  }
}
