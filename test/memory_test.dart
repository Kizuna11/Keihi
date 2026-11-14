import 'package:flutter_test/flutter_test.dart';
import 'package:keihi/memory.dart';
import 'package:keihi/models.dart';
import 'package:keihi/services.dart';

void main() {
  const ocr = 'KEDAI AH SENG\n'
      'MILO 1KG   25.90\n'
      'PHONE CHARGER   19.90\n'
      'SUB TOTAL   45.80\n'
      'NETT AMT   RM 45.80\n'
      'TNG EWALLET   45.80';

  test('rowLabel keeps only the words of a row', () {
    expect(rowLabel('NETT AMT   RM 45.80'), 'NETT AMT');
    expect(rowLabel('TOTAL (RM):  1,234.50'), 'TOTAL');
  });

  test('totalLabelFor finds the total row, not subtotal or payment rows', () {
    expect(totalLabelFor(ocr, 45.80), 'NETT AMT');
    expect(totalLabelFor(ocr, 99.99), isNull);
  });

  test('applyMemory uses the remembered total row, category and relief tags', () {
    const parsed = ParsedReceipt(
      store: 'Kedai Ah Seng',
      total: 25.90, // Gemini picked the wrong row
      category: 'Food',
      payment: '',
      items: [
        TxnItem(name: 'Milo 1kg', price: 25.90),
        TxnItem(name: 'Phone Charger', price: 19.90, relief: 'Lifestyle'),
      ],
      fromAi: true,
    );
    const memory = StoreMemory(
      key: 'kedaiahseng',
      from: 'Kedai Ah Seng',
      category: 'Groceries',
      payment: "Touch 'n Go eWallet",
      totalLabel: 'NETT AMT',
      items: {'phonecharger': (name: 'Phone Charger', relief: '')},
    );
    final p = applyMemory(parsed, memory, ocr);
    expect(p.total, 45.80);
    expect(p.totalLabel, 'NETT AMT   RM 45.80');
    expect(p.category, 'Groceries');
    expect(p.payment, "Touch 'n Go eWallet");
    expect(p.items[1].relief, ''); // the user untagged it last time
    expect(p.items[0].relief, ''); // unknown item keeps Gemini's answer
    expect(p.remembered, {'category', 'payment', 'total', 'relief'});
  });

  test('a payment method printed on the receipt beats the remembered one', () {
    const parsed = ParsedReceipt(store: 'X', total: 10, payment: 'Cash');
    const memory = StoreMemory(key: 'x', from: 'X', payment: 'GrabPay');
    final p = applyMemory(parsed, memory, 'X\nTOTAL 10.00');
    expect(p.payment, 'Cash');
    expect(p.remembered, isEmpty);
    expect(p.total, 10);
  });

  test('memoryHints describes stores for Gemini', () {
    final hints = memoryHints([
      StoreMemory(
          key: 'a',
          from: 'AEON CO (M) BHD',
          to: 'AEON',
          category: 'Groceries',
          totalLabel: 'TOTAL',
          updatedAt: DateTime(2026, 11, 1)),
    ]);
    expect(hints.single,
        'AEON; printed as "AEON CO (M) BHD"; category Groceries; total is on the row "TOTAL"');
  });
}
