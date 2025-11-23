import 'package:flutter/material.dart';
import '../core/enums.dart';
import '../models/customer.dart';
import '../models/invoice.dart';
import '../services/excel_service.dart';
import '../services/storage.dart';
import '../utils/date.dart';
import '../utils/snackbar.dart';
import 'package:open_filex/open_filex.dart';

class CustomerMasterScreen extends StatefulWidget {
  const CustomerMasterScreen({super.key});
  @override State<CustomerMasterScreen> createState()=>_CustomerMasterScreenState();
}

class _CustomerMasterScreenState extends State<CustomerMasterScreen> with AutomaticKeepAliveClientMixin {
  List<Customer> _customers = []; final _q = TextEditingController();
  List<Invoice> _allInvoices = [];
  SortMode _sortCustomers = SortMode.mostSales;
  Map<String, DateTime> _customerCreatedAt = {};
  final FocusNode _sortFocusCustomers = FocusNode(skipTraversal: true, canRequestFocus: false);
  @override bool get wantKeepAlive => true;

  @override void initState(){ super.initState(); _load(); }

  Future<void> _load() async {
    final list=await CustomerStore.loadAll(); final invs=await Store.loadAll();
    list.sort((a,b)=>a.id.toLowerCase().compareTo(b.id.toLowerCase()));
    final createdAt = <String, DateTime>{};
    for (final c in list) {
      try {
        final file = await customerWorkbookFileFromKey(c.id);
        if (await file.exists()) {
          final stat = await file.stat();
          createdAt[_keyOf(c).toLowerCase()] = stat.changed;
        }
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() { _customers = list; _allInvoices = invs; _customerCreatedAt = createdAt; });
  }

  String _keyOf(Customer c)=> (c.id.isNotEmpty?c.id:c.name).trim();
  double _sumSalesForKey(String key){ double s=0; for(final inv in _allInvoices){ final k=(inv.customerId.isNotEmpty?inv.customerId:inv.customer).trim(); if(k.toLowerCase()==key.toLowerCase()){ s+=inv.total; } } return s; }
  double _sumPaidForKey(String key){ double s=0; for(final inv in _allInvoices){ final k=(inv.customerId.isNotEmpty?inv.customerId:inv.customer).trim(); if(k.toLowerCase()==key.toLowerCase()){ s+=inv.paid; } } return s; }
  double _sumRemainForKey(String key){ double s=0; for(final inv in _allInvoices){ final k=(inv.customerId.isNotEmpty?inv.customerId:inv.customer).trim(); if(k.toLowerCase()==key.toLowerCase()){ s+=inv.remaining; } } return s; }
  DateTime _latestDateForKey(String key){
    final k = key.toLowerCase();
    final fromFile = _customerCreatedAt[k];
    if (fromFile != null) return fromFile;
    DateTime latest = DateTime.fromMillisecondsSinceEpoch(0);
    for (final inv in _allInvoices) {
      final invKey = (inv.customerId.isNotEmpty ? inv.customerId : inv.customer).trim();
      if (invKey.toLowerCase() == k) {
        final d = parseInvoiceDate(inv.date);
        if (d.isAfter(latest)) latest = d;
      }
    }
    return latest;
  }

  Future<void> _addDialog() async {
    final idCtrl = TextEditingController(text: await CustomerStore.nextCustomerId());
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    if (!mounted) return;
    // ignore: use_build_context_synchronously
    final ok = await showDialog<bool>(context: context, builder: (_)=>AlertDialog(
      title: const Text('Add Customer'),
      content: SizedBox(width:420, child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: idCtrl, enabled:false, decoration: const InputDecoration(labelText:'Customer ID')),
        const SizedBox(height:8),
        TextField(controller: nameCtrl, decoration: const InputDecoration(labelText:'Name')),
        const SizedBox(height:8),
        TextField(controller: phoneCtrl, decoration: const InputDecoration(labelText:'Phone')),
      ])),
      actions: [ TextButton(onPressed: ()=>Navigator.pop(context,false), child: const Text('Cancel')),
        FilledButton(onPressed: ()=>Navigator.pop(context,true), child: const Text('Add')) ],
    ));
    if (!mounted) return;
    if (ok==true){ await CustomerStore.addCustomer(idCtrl.text.trim(), nameCtrl.text.trim(), phoneCtrl.text.trim()); await _load(); }
  }

  Future<void> _editDialog(Customer c) async {
    final nameCtrl=TextEditingController(text:c.name), phoneCtrl=TextEditingController(text:c.contact);
    final ok = await showDialog<bool>(context: context, builder: (_)=>AlertDialog(
      title: const Text('Edit Customer'),
      content: SizedBox(width:420, child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(enabled:false, decoration: InputDecoration(labelText:'Customer ID', hintText:c.id)),
        const SizedBox(height:8),
        TextField(controller: nameCtrl, decoration: const InputDecoration(labelText:'Name')),
        const SizedBox(height:8),
        TextField(controller: phoneCtrl, decoration: const InputDecoration(labelText:'Phone')),
      ])),
      actions: [ TextButton(onPressed: ()=>Navigator.pop(context,false), child: const Text('Cancel')),
        FilledButton(onPressed: ()=>Navigator.pop(context,true), child: const Text('Save')) ],
    ));
    if (!mounted) return;
    if (ok==true){ final okEdit = await CustomerStore.updateNamePhone(c.id, nameCtrl.text.trim(), phoneCtrl.text.trim()); if(okEdit) await _load(); }
  }

  Future<void> _deleteCustomer(Customer c) async {
    final ok = await showDialog<bool>(context: context, builder: (_)=>AlertDialog(
      title: const Text('Deactivate Customer?'),
      content: Text('Remove "${c.id} - ${c.name}" from master. This does NOT delete old invoices.'),
      actions: [ TextButton(onPressed: ()=>Navigator.pop(context,false), child: const Text('Cancel')),
        FilledButton(onPressed: ()=>Navigator.pop(context,true), child: const Text('Deactivate')) ],
    ));
    if (!mounted) return;
    if (ok == true) { await CustomerStore.deleteById(c.id); await _load(); }
  }

  @override
  void dispose() { _q.dispose(); _sortFocusCustomers.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final q=_q.text.trim().toLowerCase();
    var filtered = q.isEmpty ? _customers : _customers.where((c)=>c.id.toLowerCase().contains(q) || c.name.toLowerCase().contains(q) || c.contact.toLowerCase().contains(q)).toList();

    // Apply sorting based on selected mode
    int cmpNumDesc(num a, num b) => b.compareTo(a);
    int cmpNumAsc(num a, num b) => a.compareTo(b);
    switch (_sortCustomers) {
      case SortMode.mostUnpaid:
        filtered.sort((a,b)=>cmpNumDesc(_sumRemainForKey(_keyOf(a)), _sumRemainForKey(_keyOf(b))));
        break;
      case SortMode.mostPaid:
        filtered.sort((a,b)=>cmpNumDesc(_sumPaidForKey(_keyOf(a)), _sumPaidForKey(_keyOf(b))));
        break;
      case SortMode.mostSales:
        filtered.sort((a,b)=>cmpNumDesc(_sumSalesForKey(_keyOf(a)), _sumSalesForKey(_keyOf(b))));
        break;
      case SortMode.leastSales:
        filtered.sort((a,b)=>cmpNumAsc(_sumSalesForKey(_keyOf(a)), _sumSalesForKey(_keyOf(b))));
        break;
      case SortMode.newestFirst:
        filtered.sort((a,b)=>_latestDateForKey(_keyOf(b)).compareTo(_latestDateForKey(_keyOf(a))));
        break;
      case SortMode.oldestFirst:
        filtered.sort((a,b)=>_latestDateForKey(_keyOf(a)).compareTo(_latestDateForKey(_keyOf(b))));
        break;
    }
    return Column(children: [
      Row(children: [
        Expanded(child: TextField(controller:_q, decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search ID/Name/Phone'), onChanged: (_)=>setState((){}))),
        const SizedBox(width:12),
        DropdownButton<SortMode>(
          focusNode: _sortFocusCustomers,
          value: _sortCustomers,
          onChanged: (v){ if(v!=null){ setState(()=>_sortCustomers=v); FocusScope.of(context).unfocus(); _sortFocusCustomers.unfocus(); FocusManager.instance.primaryFocus?.unfocus(); } },
          items: const [
            DropdownMenuItem(value: SortMode.mostUnpaid, child: Text('Most Unpaid')),
            DropdownMenuItem(value: SortMode.mostPaid, child: Text('Most Paid')),
            DropdownMenuItem(value: SortMode.mostSales, child: Text('Most Sales')),
            DropdownMenuItem(value: SortMode.leastSales, child: Text('Least Sales')),
            DropdownMenuItem(value: SortMode.newestFirst, child: Text('Newest First')),
            DropdownMenuItem(value: SortMode.oldestFirst, child: Text('Oldest First')),
          ],
        ),
        const SizedBox(width:12),
        FilledButton.icon(onPressed: _addDialog, icon: const Icon(Icons.add), label: const Text('Add Customer')),
      ]),
      const SizedBox(height: 12),
      Expanded(child: Card(child: ListView.separated(
        physics: const ClampingScrollPhysics(),
        itemCount: filtered.length, separatorBuilder: (_, __)=>const Divider(height:1),
        itemBuilder: (_, i){ final c=filtered[i]; return ListTile(
          title: Text('${c.id} - ${c.name}'), subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(c.contact),
              const SizedBox(height: 2),
              Builder(builder: (_){
                final key = _keyOf(c);
                final t = _sumSalesForKey(key).toStringAsFixed(0);
                final p = _sumPaidForKey(key).toStringAsFixed(0);
                final r = _sumRemainForKey(key).toStringAsFixed(0);
                return Text('Total: Rs $t   |   Paid: Rs $p   |   Remaining: Rs $r', style: const TextStyle(fontSize: 12, color: Colors.black87));
              }),
            ],
          ),
          trailing: Wrap(spacing:8, children: [
            OutlinedButton.icon(
              onPressed: () async {
                final file = await customerWorkbookFileFromKey(c.id);
                final exists = await file.exists();
                if (!mounted) return;
                if (exists) { await OpenFilex.open(file.path); } else {
                  // ignore: use_build_context_synchronously
                  showErr(context, 'Customer Excel not found.');
                }
              },
              icon: const Icon(Icons.open_in_new, size:16),
              label: const Text('Open'),
            ),
            OutlinedButton.icon(onPressed: ()=>_editDialog(c), icon: const Icon(Icons.edit, size:16), label: const Text('Edit')),
            OutlinedButton.icon(onPressed: ()=>_deleteCustomer(c), icon: const Icon(Icons.delete_outline, size:16), label: const Text('Deactivate')),
          ]),
        ); },
      ))),
      const SizedBox(height:8),
      const Text('Note: Editing master updates future invoices/search. Old invoices are kept unchanged.'),
    ]);
  }
}
