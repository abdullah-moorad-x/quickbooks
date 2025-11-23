enum PaymentType { cash, cheque, bank }
enum PaymentStatus { cleared, pending, bounced }

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

String paymentStatusLabel(PaymentStatus s) {
  switch (s) {
    case PaymentStatus.cleared:
      return 'Cleared';
    case PaymentStatus.pending:
      return 'Pending';
    case PaymentStatus.bounced:
      return 'Bounced';
  }
}

String statusTextForEntry(PaymentEntry e) {
  if (e.type == PaymentType.bank && e.status == PaymentStatus.bounced) {
    return 'Returned';
  }
  return paymentStatusLabel(e.status);
}

PaymentStatus paymentStatusFromString(String s) {
  final v = s.toLowerCase().trim();
  if (v == 'cleared') return PaymentStatus.cleared;
  if (v == 'pending') return PaymentStatus.pending;
  if (v == 'bounced') return PaymentStatus.bounced;
  return PaymentStatus.pending;
}

PaymentType paymentTypeFromString(String s) {
  final v = s.toLowerCase().trim();
  if (v == 'cash') return PaymentType.cash;
  if (v == 'cheque') return PaymentType.cheque;
  if (v == 'bank') return PaymentType.bank;
  return PaymentType.cash;
}

class PaymentEntry {
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
  PaymentStatus status;
  final String batchId;
  final String groupId;

  PaymentEntry({
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

  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date,
        'invoiceNo': invoiceNo,
        'invoiceDate': invoiceDate,
        'customer': customer,
        'type': paymentTypeLabel(type),
        'amount': amount,
        'chequeNo': chequeNo,
        'bank': bank,
        'txnId': txnId,
        'bankMode': bankMode,
        'status': paymentStatusLabel(status),
        'batchId': batchId,
        'groupId': groupId,
      };

  static PaymentEntry fromJson(Map<String, dynamic> j) => PaymentEntry(
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
        status: paymentStatusFromString((j['status'] ?? 'Pending').toString()),
        batchId: (j['batchId'] ?? '').toString(),
        groupId: (j['groupId'] ?? '').toString(),
      );
}

