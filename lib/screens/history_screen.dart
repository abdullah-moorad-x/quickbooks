import 'dart:io';
import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:open_filex/open_filex.dart';
import '../core/app_bus.dart';
import '../models/invoice.dart';
import '../services/paths.dart';
import '../services/pdf_builder.dart';
import '../services/storage.dart';
import '../services/excel_service.dart';
import '../utils/date.dart';
import '../utils/format.dart';
import '../utils/snackbar.dart';
import '../widgets/invoice_summary_card.dart';
import 'invoice_screen.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen>
    with AutomaticKeepAliveClientMixin {
  List<Invoice> _all = [];
  List<Invoice> _filtered = [];
  final TextEditingController _searchCtrl = TextEditingController();
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
    _searchCtrl.addListener(_applyFilter);
    AppBus.dataTick.addListener(_load);
  }

  @override
  void dispose() {
    AppBus.dataTick.removeListener(_load);
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendWhatsappForInvoice(Invoice inv) async {
    try {
      final bytes = await PdfBuilder.build(inv);
      final invDir = await subdir('invoices');
      final pdfFile =
          File('${invDir.path}${Platform.pathSeparator}invoice_${inv.sNo}.pdf');
      await pdfFile.writeAsBytes(bytes, flush: true);
      try {
        await OpenFilex.open(invDir.path);
      } catch (_) {
        if (Platform.isWindows) {
          try {
            await Process.run('explorer', [invDir.path]);
          } catch (_) {}
        }
      }
      var raw = inv.contact.trim();
      var digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
      if (digits.startsWith('0092')) {
        digits = digits.substring(2);
      } else if (digits.startsWith('0')) {
        digits = '92${digits.substring(1)}';
      } else if (!digits.startsWith('92')) {
        digits = '92$digits';
      }
      final displayName = (inv.customerDisplay ?? inv.customer).trim();
      final msg =
          'Invoice #${inv.sNo} for $displayName, Date ${inv.date}. Total Rs ${fmt0(inv.total)}, Cartage Rs ${fmt0(inv.cartage)}, Balance Rs ${fmt0(inv.balance)}. Thank you.';
      final url = 'https://wa.me/$digits?text=${Uri.encodeComponent(msg)}';
      if (Platform.isWindows) {
        try {
          final esc = pdfFile.path.replaceAll("'", "''");
          await Process.run('powershell',
              ['-NoProfile', '-Command', "Set-Clipboard -Path '$esc'"]);
        } catch (_) {}
      }
      try {
        await OpenFilex.open(url);
      } catch (_) {
        if (Platform.isWindows) {
          try {
            await Process.run('cmd', ['/c', 'start', url]);
          } catch (_) {}
        }
      }
      if (!mounted) return;
      // ignore: use_build_context_synchronously
      showOk(context, 'Prepared WhatsApp for invoice #${inv.sNo}');
    } catch (_) {
      if (!mounted) return;
      showErr(context, 'Could not prepare WhatsApp for #${inv.sNo}');
    }
  }

  Future<void> _load() async {
    final list = await Store.loadAll();
    list.sort((a, b) => b.sNo.compareTo(a.sNo));
    if (!mounted) return;
    setState(() {
      _all = list;
      _filtered = list;
    });
  }

  void _applyFilter() {
    final query = _searchCtrl.text.toLowerCase();
    setState(() {
      if (query.isEmpty) {
        _filtered = _all;
      } else {
        _filtered = _all.where((inv) {
          return invoiceSummarySearchText(inv).contains(query);
        }).toList();
      }
    });
  }

  Widget _historyActionButton({
    required String tooltip,
    required Widget icon,
    required VoidCallback onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onPressed,
        child: Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFE1E7EF)),
          ),
          child: icon,
        ),
      ),
    );
  }

  Future<void> _editInvoice(Invoice inv) async {
    final updated =
        await Navigator.of(context).push<Invoice?>(MaterialPageRoute(
      builder: (_) => InvoiceScreen(editing: true, initialInvoice: inv),
    ));
    if (updated != null) {
      await _load();
      if (!mounted) return;
      // ignore: use_build_context_synchronously
      showOk(context, 'Invoice #${updated.sNo} updated');
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_all.isEmpty) return const Center(child: Text('No invoices yet'));
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        child: TextField(
          controller: _searchCtrl,
          decoration: InputDecoration(
            hintText: 'Search by name, invoice #, or address...',
            prefixIcon: const Icon(Icons.search),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            filled: true,
            fillColor: Colors.white,
            contentPadding:
                const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
          ),
        ),
      ),
      Expanded(
          child: ListView.builder(
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              itemCount: _filtered.length,
              itemBuilder: (_, i) {
                final inv = _filtered[i];
                return InvoiceSummaryCard(
                  invoice: inv,
                  showContactLine: true,
                  actions: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _historyActionButton(
                        tooltip: 'PDF',
                        icon: const Icon(Icons.picture_as_pdf,
                            color: Color(0xFF273247), size: 20),
                        onPressed: () async {
                          final bytes = await PdfBuilder.build(inv);
                          final dir = await subdir('invoices');
                          final file = File(
                              '${dir.path}${Platform.pathSeparator}invoice_${inv.sNo}.pdf');
                          await file.writeAsBytes(bytes, flush: true);
                          await OpenFilex.open(file.path);
                          if (!mounted) return;
                          showOk(context,
                              'Saved: ${file.path.split(Platform.pathSeparator).last}');
                        },
                      ),
                      _historyActionButton(
                        tooltip: 'WhatsApp',
                        icon: const FaIcon(FontAwesomeIcons.whatsapp,
                            color: Color(0xFF25D366), size: 19),
                        onPressed: () => _sendWhatsappForInvoice(inv),
                      ),
                      _historyActionButton(
                        tooltip: 'Edit',
                        icon: const Icon(Icons.edit_outlined,
                            color: Color(0xFF273247), size: 20),
                        onPressed: () => _editInvoice(inv),
                      ),
                      _historyActionButton(
                        tooltip: 'Delete',
                        icon: const Icon(Icons.delete_outline,
                            color: Color(0xFFB42318), size: 20),
                        onPressed: () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (_) => AlertDialog(
                              title: const Text('Delete Invoice'),
                              content: Text('Delete invoice #${inv.sNo}?'),
                              actions: [
                                TextButton(
                                    onPressed: () =>
                                        Navigator.pop(context, false),
                                    child: const Text('Cancel')),
                                FilledButton(
                                    onPressed: () =>
                                        Navigator.pop(context, true),
                                    child: const Text('Delete')),
                              ],
                            ),
                          );
                          if (!mounted) return;
                          if (ok != true) return;
                          final removed = await Store.deleteInvoice(inv.sNo);
                          if (removed == null) {
                            if (!mounted) return;
                            // ignore: use_build_context_synchronously
                            showErr(context, 'Invoice #${inv.sNo} not found');
                            return;
                          }

                          // Rebuild affected sales/customer files
                          final removedDate = parseInvoiceDate(removed.date);
                          await exportDailySalesExcel(removedDate);
                          await exportMonthlySalesExcel(removedDate);
                          final key = (removed.customerId.isNotEmpty
                                  ? removed.customerId
                                  : removed.customer)
                              .trim();
                          if (key.isNotEmpty) {
                            await rebuildCustomerWorkbookForKey(key);
                          }
                          await exportGodownDailyRemainingExcel();

                          // Remove payments and refresh monthly payments files for affected months
                          try {
                            final removedPays =
                                await PaymentStore.deleteForInvoice(inv.sNo);
                            if (removedPays.isNotEmpty) {
                              await syncInvoicesPaidFromPayments();
                              final seen = <String>{};
                              for (final p in removedPays) {
                                try {
                                  final d = parseInvoiceDate(p.date);
                                  final tag =
                                      '${d.year}-${d.month.toString().padLeft(2, '0')}';
                                  if (seen.add(tag)) {
                                    await rebuildMonthlyPaymentsExcels(
                                        DateTime(d.year, d.month));
                                  }
                                } catch (_) {}
                              }
                            }
                          } catch (_) {}

                          // Delete PDFs for this invoice
                          try {
                            final dir = await subdir('invoices');
                            final entries = await dir.list().toList();
                            final rx = RegExp(
                                '^invoice_${removed.sNo}(?:_\\d+)?\\.pdf\$',
                                caseSensitive: false);
                            for (final e in entries) {
                              final name =
                                  e.path.split(Platform.pathSeparator).last;
                              if (rx.hasMatch(name)) {
                                try {
                                  await File(e.path).delete();
                                } catch (_) {}
                              }
                            }
                          } catch (_) {}

                          await _load();
                          if (!mounted) return;
                          showOk(context, 'Invoice deleted');
                        },
                      ),
                    ],
                  ),
                );
              }))
    ]);
  }
}
