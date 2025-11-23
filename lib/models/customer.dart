class Customer {
  String id;
  String name;
  String contact;
  bool active;

  Customer({
    required this.id,
    required this.name,
    this.contact = '',
    this.active = true,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'contact': contact,
        'active': active,
      };

  static Customer fromJson(Map<String, dynamic> j) => Customer(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        contact: (j['contact'] ?? '').toString(),
        active: j['active'] is bool ? (j['active'] as bool) : true,
      );
}

