class Customer {
  String id;
  String name; // Internal/system name used for reports and khata
  String displayName; // Customer-facing name shown on invoices/ledger shared with customer
  String contact;
  bool active;

  Customer({
    required this.id,
    required this.name,
    String? displayName,
    this.contact = '',
    this.active = true,
  }) : displayName = displayName ?? name;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'displayName': displayName,
        'contact': contact,
        'active': active,
      };

  static Customer fromJson(Map<String, dynamic> j) => Customer(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        displayName: ((j['displayName'] ?? j['name']) ?? '').toString(),
        contact: (j['contact'] ?? '').toString(),
        active: j['active'] is bool ? (j['active'] as bool) : true,
      );
}
