import '../models/customer.dart';
import '../models/invoice.dart';
import 'godown_stock_store.dart';
import 'storage.dart';
import '../utils/date.dart';

class InvoiceDraftSuggestions {
  final List<Customer> customers;
  final List<String> unifiedCustomers;
  final List<String> brandSuggestions;
  final List<GodownSku> godownSkus;
  final List<String> addressSuggestions;
  final Map<String, Map<String, List<String>>> rateSuggestionsById;
  final Map<String, Map<String, List<String>>> rateSuggestionsByName;

  const InvoiceDraftSuggestions({
    required this.customers,
    required this.unifiedCustomers,
    required this.brandSuggestions,
    required this.godownSkus,
    required this.addressSuggestions,
    required this.rateSuggestionsById,
    required this.rateSuggestionsByName,
  });

  const InvoiceDraftSuggestions.empty()
      : customers = const [],
        unifiedCustomers = const [],
        brandSuggestions = const [],
        godownSkus = const [],
        addressSuggestions = const [],
        rateSuggestionsById = const {},
        rateSuggestionsByName = const {};

  static Future<InvoiceDraftSuggestions> load() async {
    final results = await Future.wait<dynamic>([
      CustomerStore.loadActive(),
      Store.loadAll(),
      GodownStockStore.loadConfig(),
    ]);
    final customers = results[0] as List<Customer>;
    final invoices = results[1] as List<Invoice>;
    final godownCfg = results[2] as GodownConfig;

    final unifiedCustomers = customers
        .map((customer) {
          final parts = <String>[];
          if (customer.id.trim().isNotEmpty) parts.add(customer.id.trim());
          if (customer.name.trim().isNotEmpty) parts.add(customer.name.trim());
          if (customer.contact.trim().isNotEmpty) {
            parts.add(customer.contact.trim());
          }
          return parts.join(' - ');
        })
        .where((value) => value.isNotEmpty)
        .toList();

    final brandSuggestions = invoices
        .expand((invoice) => invoice.lines.map((line) => line.brand.trim()))
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList();

    final addressSuggestions = invoices
        .map((invoice) => invoice.address.trim())
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList();

    final sortedInvoices = List<Invoice>.from(invoices)
      ..sort(
        (a, b) => parseInvoiceDate(b.date).compareTo(parseInvoiceDate(a.date)),
      );

    final rateById = <String, Map<String, List<String>>>{};
    final rateByName = <String, Map<String, List<String>>>{};
    for (final invoice in sortedInvoices) {
      final idKey = invoice.customerId.trim().toLowerCase();
      final nameKey = invoice.customer.trim().toLowerCase();
      for (final line in invoice.lines) {
        if (line.rate <= 0) continue;
        final rate = line.rate.toStringAsFixed(0);
        if (idKey.isNotEmpty) {
          final byType =
              rateById.putIfAbsent(idKey, () => <String, List<String>>{});
          final values = byType.putIfAbsent(line.typeLabel, () => <String>[]);
          if (!values.contains(rate)) values.add(rate);
        }
        if (nameKey.isNotEmpty) {
          final byType =
              rateByName.putIfAbsent(nameKey, () => <String, List<String>>{});
          final values = byType.putIfAbsent(line.typeLabel, () => <String>[]);
          if (!values.contains(rate)) values.add(rate);
        }
      }
    }

    return InvoiceDraftSuggestions(
      customers: customers,
      unifiedCustomers: unifiedCustomers,
      brandSuggestions: brandSuggestions,
      godownSkus: godownCfg.skus,
      addressSuggestions: addressSuggestions,
      rateSuggestionsById: rateById,
      rateSuggestionsByName: rateByName,
    );
  }

  List<String> rateOptionsFor(
    String customerId,
    String customerName,
    String typeLabel,
  ) {
    final idKey = customerId.trim().toLowerCase();
    final nameKey = customerName.trim().toLowerCase();
    if (idKey.isNotEmpty) {
      final values = rateSuggestionsById[idKey]?[typeLabel];
      if (values != null) return values;
    }
    if (nameKey.isNotEmpty) {
      final values = rateSuggestionsByName[nameKey]?[typeLabel];
      if (values != null) return values;
    }
    return const [];
  }

  Iterable<String> brandOptionsFor(
    String site,
    String typeLabel,
    String query,
  ) {
    final q = query.trim().toLowerCase();
    final source = site.trim().toLowerCase() == 'godown'
        ? godownSkus
            .where((sku) => sku.category.isEmpty || sku.category == typeLabel)
            .map((sku) => sku.name)
            .toSet()
            .toList()
        : brandSuggestions;
    if (q.isEmpty) return source;
    return source.where((value) => value.toLowerCase().contains(q));
  }
}
