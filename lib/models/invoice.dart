import 'package:flutter/material.dart';
import '../core/constants.dart';
import 'payment.dart';

class ItemLine {
  final String typeLabel;
  String brand;
  int qty;
  double rate;

  final TextEditingController brandCtrl = TextEditingController();
  final FocusNode brandFocus = FocusNode();
  final TextEditingController qtyCtrl = TextEditingController();
  final TextEditingController rateCtrl = TextEditingController();
  final FocusNode rateFocus = FocusNode();

  ItemLine(this.typeLabel, {this.brand = '', this.qty = 0, this.rate = 0}) {
    brandCtrl.text = brand;
    qtyCtrl.text = qty == 0 ? '' : '$qty';
    rateCtrl.text = rate == 0 ? '' : rate.toStringAsFixed(0);
  }
  double get amount => qty * rate;

  Map<String, dynamic> toJson() => {
        'type': typeLabel,
        'brand': brand,
        'qty': qty,
        'rate': rate,
        'amount': amount,
      };
  void dispose() {
    brandCtrl.dispose();
    brandFocus.dispose();
    qtyCtrl.dispose();
    rateCtrl.dispose();
    rateFocus.dispose();
  }
}

class Invoice {
  int sNo;
  String date;
  String customer;
  String? customerDisplay;
  String customerId;
  String contact;
  String address;
  String site;
  List<ItemLine> lines;
  double cartage;
  double paid;
  bool walkIn;
  bool isReturn;
  int? returnOfInvoiceNo;
  String? sourceOrderId;
  String? sourceReturnId;
  PaymentType? walkInPaymentType;
  String? walkInPaymentNote;
  String? walkInBank;
  String? walkInChequeNo;
  String? walkInTxnId;
  String? walkInBankMode;
  Invoice({
    required this.sNo,
    required this.date,
    required this.customer,
    this.customerDisplay,
    required this.customerId,
    required this.contact,
    required this.address,
    this.site = '',
    required this.lines,
    this.cartage = 0,
    this.paid = 0,
    this.walkIn = false,
    this.isReturn = false,
    this.returnOfInvoiceNo,
    this.sourceOrderId,
    this.sourceReturnId,
    this.walkInPaymentType,
    this.walkInPaymentNote,
    this.walkInBank,
    this.walkInChequeNo,
    this.walkInTxnId,
    this.walkInBankMode,
  });
  double get total => lines.fold(0.0, (s, it) => s + it.amount);
  double get balance => total + cartage;
  double get remaining =>
      balance <= 0 ? 0 : (balance - paid).clamp(0, double.infinity);

  Map<String, dynamic> toJson() => {
        'sNo': sNo,
        'date': date,
        'customer': customer,
        'customerDisplay': customerDisplay,
        'customerId': customerId,
        'contact': contact,
        'address': address,
        'site': site,
        'cartage': cartage,
        'total': total,
        'balance': balance,
        'paid': paid,
        'remaining': remaining,
        'walkIn': walkIn,
        'isReturn': isReturn,
        'returnOfInvoiceNo': returnOfInvoiceNo,
        'sourceOrderId': sourceOrderId,
        'sourceReturnId': sourceReturnId,
        'walkInPaymentType': walkInPaymentType == null
            ? null
            : paymentTypeLabel(walkInPaymentType!),
        'walkInPaymentNote': walkInPaymentNote,
        'walkInBank': walkInBank,
        'walkInChequeNo': walkInChequeNo,
        'walkInTxnId': walkInTxnId,
        'walkInBankMode': walkInBankMode,
        'lines': lines.map((e) => e.toJson()).toList(),
      };

  static Invoice fromJson(Map<String, dynamic> j) => Invoice(
        sNo: j['sNo'],
        date: j['date'],
        customer: j['customer'],
        customerDisplay: (j['customerDisplay'] ?? j['customer'])?.toString(),
        customerId: (j['customerId'] ?? '').toString(),
        contact: j['contact'],
        address: j['address'],
        site: (j['site'] ?? '').toString(),
        lines: (j['lines'] as List).map((x) {
          final m = x as Map<String, dynamic>;
          return ItemLine(
            (m['type'] ?? '').toString(),
            brand: (m['brand'] ?? '').toString(),
            qty: (m['qty'] as num?)?.toInt() ?? 0,
            rate: (m['rate'] as num?)?.toDouble() ?? 0,
          );
        }).toList(),
        cartage: (j['cartage'] as num?)?.toDouble() ?? 0.0,
        paid: (j['paid'] as num?)?.toDouble() ?? 0.0,
        walkIn: j['walkIn'] == true ||
            (j['walkIn']?.toString().toLowerCase() == 'true'),
        isReturn: j['isReturn'] == true ||
            (j['isReturn']?.toString().toLowerCase() == 'true'),
        returnOfInvoiceNo: (j['returnOfInvoiceNo'] as num?)?.toInt(),
        sourceOrderId: (j['sourceOrderId'] ?? '').toString().trim().isEmpty
            ? null
            : (j['sourceOrderId'] ?? '').toString(),
        sourceReturnId: (j['sourceReturnId'] ?? '').toString().trim().isEmpty
            ? null
            : (j['sourceReturnId'] ?? '').toString(),
        walkInPaymentType: ((j['walkInPaymentType'] ?? '')
                .toString()
                .trim()
                .isEmpty)
            ? null
            : paymentTypeFromString((j['walkInPaymentType'] ?? '').toString()),
        walkInPaymentNote:
            ((j['walkInPaymentNote'] ?? '').toString().trim().isEmpty)
                ? null
                : (j['walkInPaymentNote'] ?? '').toString(),
        walkInBank: ((j['walkInBank'] ?? '').toString().trim().isEmpty)
            ? null
            : (j['walkInBank'] ?? '').toString(),
        walkInChequeNo: ((j['walkInChequeNo'] ?? '').toString().trim().isEmpty)
            ? null
            : (j['walkInChequeNo'] ?? '').toString(),
        walkInTxnId: ((j['walkInTxnId'] ?? '').toString().trim().isEmpty)
            ? null
            : (j['walkInTxnId'] ?? '').toString(),
        walkInBankMode: ((j['walkInBankMode'] ?? '').toString().trim().isEmpty)
            ? null
            : (j['walkInBankMode'] ?? '').toString(),
      );
}

List<ItemLine> summarizeInvoiceLines(List<ItemLine> lines) {
  final out = <ItemLine>[];
  for (final t in kItemTypes) {
    final same = lines.where((l) => l.typeLabel == t).toList();
    if (same.isEmpty) {
      out.add(ItemLine(t));
      continue;
    }
    int qtyTotal = 0;
    double amountTotal = 0.0;
    final parts = <String>[];
    for (final l in same) {
      final q = l.qty;
      final r = l.rate;
      qtyTotal += q;
      amountTotal += q * r;
      if (q > 0) {
        final b = l.brand.trim();
        if (b.isNotEmpty) {
          if (r > 0) {
            parts.add('$b ($q @ ${r.toStringAsFixed(0)})');
          } else {
            parts.add(b);
          }
        }
      }
    }
    final rate = qtyTotal > 0 ? (amountTotal / qtyTotal) : 0.0;
    final brand = qtyTotal > 0 ? parts.join(', ') : '';
    out.add(ItemLine(t, brand: brand, qty: qtyTotal, rate: rate));
  }
  return out;
}
