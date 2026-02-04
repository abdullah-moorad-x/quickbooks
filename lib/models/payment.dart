enum PaymentType { cash, cheque, bank }

String paymentTypeLabel(PaymentType t) {
  switch (t) {
    case PaymentType.cash:
      return 'Cash';
    case PaymentType.cheque:
      return 'Cheque';
    case PaymentType.bank:
      return 'Bank';
  }
}

PaymentType paymentTypeFromString(String s) {
  final v = s.toLowerCase().trim();
  if (v == 'cash') return PaymentType.cash;
  if (v == 'cheque') return PaymentType.cheque;
  if (v == 'bank') return PaymentType.bank;
  return PaymentType.cash;
}

/// Customer-ledger (khata) entry.
/// Positive [amount] means money received from customer (reduces their debit).
class PaymentEntry {
  final String id;
  final String date;
  final String customerId;
  final String customer;
  final PaymentType type;
  final double amount;
  final double discount; // Optional discount applied with this payment.
  final String? note;
  final String? chequeNo;
  final String? bank;
  final String? txnId;
  final String? bankMode;

  const PaymentEntry({
    required this.id,
    required this.date,
    required this.customerId,
    required this.customer,
    required this.type,
    required this.amount,
    this.discount = 0,
    this.note,
    this.chequeNo,
    this.bank,
    this.txnId,
    this.bankMode,
  });

  double get effectiveAmount => amount + discount;

  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date,
        'customerId': customerId,
        'customer': customer,
        'type': paymentTypeLabel(type),
        'amount': amount,
        'discount': discount,
        'note': note,
        'chequeNo': chequeNo,
        'bank': bank,
        'txnId': txnId,
        'bankMode': bankMode,
      };

  static PaymentEntry fromJson(Map<String, dynamic> j) => PaymentEntry(
        id: (j['id'] ?? '').toString(),
        date: (j['date'] ?? '').toString(),
        customerId: (j['customerId'] ?? '').toString(),
        customer: (j['customer'] ?? '').toString(),
        type: paymentTypeFromString((j['type'] ?? '').toString()),
        amount: (j['amount'] as num?)?.toDouble() ?? 0.0,
        discount: (j['discount'] as num?)?.toDouble() ?? 0.0,
        note: (j['note'] ?? '') == '' ? null : (j['note'] ?? '').toString(),
        chequeNo: (j['chequeNo'] ?? '') == '' ? null : (j['chequeNo'] ?? '').toString(),
        bank: (j['bank'] ?? '') == '' ? null : (j['bank'] ?? '').toString(),
        txnId: (j['txnId'] ?? '') == '' ? null : (j['txnId'] ?? '').toString(),
        bankMode: (j['bankMode'] ?? '') == '' ? null : (j['bankMode'] ?? '').toString(),
      );
}

// ---- Legacy support for migrating old invoice-based payment records ----
enum LegacyPaymentStatus { cleared, pending, bounced }

LegacyPaymentStatus _legacyStatusFromString(String s) {
  final v = s.toLowerCase().trim();
  if (v == 'cleared') return LegacyPaymentStatus.cleared;
  if (v == 'bounced') return LegacyPaymentStatus.bounced;
  return LegacyPaymentStatus.pending;
}

class LegacyPaymentEntry {
  final String id;
  final String date;
  final int invoiceNo;
  final String invoiceDate;
  final String customer;
  final PaymentType type;
  final double amount;
  final String? chequeNo;
  final String? bank;
  final String? txnId;
  final String? bankMode;
  final LegacyPaymentStatus status;
  final String batchId;
  final String groupId;
  const LegacyPaymentEntry({
    required this.id,
    required this.date,
    required this.invoiceNo,
    required this.invoiceDate,
    required this.customer,
    required this.type,
    required this.amount,
    this.chequeNo,
    this.bank,
    this.txnId,
    this.bankMode,
    required this.status,
    required this.batchId,
    required this.groupId,
  });

  static LegacyPaymentEntry fromJson(Map<String, dynamic> j) => LegacyPaymentEntry(
        id: (j['id'] ?? '').toString(),
        date: (j['date'] ?? '').toString(),
        invoiceNo: (j['invoiceNo'] as num?)?.toInt() ?? 0,
        invoiceDate: (j['invoiceDate'] ?? '').toString(),
        customer: (j['customer'] ?? '').toString(),
        type: paymentTypeFromString((j['type'] ?? '').toString()),
        amount: (j['amount'] as num?)?.toDouble() ?? 0.0,
        chequeNo: (j['chequeNo'] ?? '') == '' ? null : (j['chequeNo'] ?? '').toString(),
        bank: (j['bank'] ?? '') == '' ? null : (j['bank'] ?? '').toString(),
        txnId: (j['txnId'] ?? '') == '' ? null : (j['txnId'] ?? '').toString(),
        bankMode: (j['bankMode'] ?? '') == '' ? null : (j['bankMode'] ?? '').toString(),
        status: _legacyStatusFromString((j['status'] ?? 'Pending').toString()),
        batchId: (j['batchId'] ?? '').toString(),
        groupId: (j['groupId'] ?? '').toString(),
      );
}
