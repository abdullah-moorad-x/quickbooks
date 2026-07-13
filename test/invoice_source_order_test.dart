import 'package:flutter_test/flutter_test.dart';
import 'package:quickbill_by_abdullah/models/invoice.dart';

void main() {
  test('invoice keeps its source mobile order ID through JSON', () {
    final invoice = Invoice(
      sNo: 42,
      date: '13/07/2026',
      customer: 'Test Customer',
      customerId: 'C-1',
      contact: '',
      address: 'Plot 1',
      site: 'Godown',
      lines: [ItemLine('Cement', brand: 'Test Brand', qty: 10, rate: 100)],
      sourceOrderId: 'ord-stable-request-id',
      sourceReturnId: 'return-stable-request-id',
    );

    final restored = Invoice.fromJson(invoice.toJson());

    expect(restored.sourceOrderId, 'ord-stable-request-id');
    expect(restored.sourceReturnId, 'return-stable-request-id');
  });
}
