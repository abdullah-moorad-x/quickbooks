class LedgerEntry {
  final String id;
  final String date; // yyyy-MM-dd
  final String particulars;
  final double qty;
  final double rate;
  final double debit;
  final double credit;
  final String? note;

  const LedgerEntry({
    required this.id,
    required this.date,
    required this.particulars,
    required this.qty,
    required this.rate,
    required this.debit,
    required this.credit,
    this.note,
  });

  double get net => debit - credit;

  LedgerEntry copyWith({
    String? id,
    String? date,
    String? particulars,
    double? qty,
    double? rate,
    double? debit,
    double? credit,
    String? note,
  }) {
    return LedgerEntry(
      id: id ?? this.id,
      date: date ?? this.date,
      particulars: particulars ?? this.particulars,
      qty: qty ?? this.qty,
      rate: rate ?? this.rate,
      debit: debit ?? this.debit,
      credit: credit ?? this.credit,
      note: note ?? this.note,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date,
        'particulars': particulars,
        'qty': qty,
        'rate': rate,
        'debit': debit,
        'credit': credit,
        'note': note,
      };

  static LedgerEntry fromJson(Map<String, dynamic> j) {
    double asDouble(dynamic v) => (v as num?)?.toDouble() ?? 0.0;
    return LedgerEntry(
      id: (j['id'] ?? '').toString(),
      date: (j['date'] ?? '').toString(),
      particulars: (j['particulars'] ?? '').toString(),
      qty: asDouble(j['qty']),
      rate: asDouble(j['rate']),
      debit: asDouble(j['debit']),
      credit: asDouble(j['credit']),
      note: (j['note'] ?? '') == '' ? null : (j['note'] ?? '').toString(),
    );
  }
}
