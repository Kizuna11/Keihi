import 'package:flutter_test/flutter_test.dart';
import 'package:keihi/models.dart';
import 'package:keihi/services.dart';

void main() {
  test('amountsIn reads two-decimal amounts and thousand separators', () {
    expect(amountsIn('TOTAL RM 23.40'), [23.40]);
    expect(amountsIn('GRAND TOTAL 1,234.50'), [1234.50]);
    expect(amountsIn('JUMLAH 18,90'), [18.90]);
    expect(amountsIn('QTY 3   ITEMS 12'), isEmpty);
  });

  test('fallback skips subtotal, cash and change rows', () {
    const ocr = '99 SPEED MART\n'
        'SUB TOTAL   22.50\n'
        'SST 6%   1.35\n'
        'ROUNDING   -0.05\n'
        'TOTAL   RM 23.80\n'
        'CASH   50.00\n'
        'CHANGE   26.20';
    final p = GeminiService.fallback(ocr);
    expect(p.store, '99 SPEED MART');
    expect(p.total, 23.80);
    expect(p.totalLabel, 'TOTAL   RM 23.80');
  });

  test('fallback prefers GRAND TOTAL over a plain TOTAL row', () {
    const ocr = 'CAFE\nTOTAL QTY 3\nTOTAL   40.00\nSERVICE CHARGE 10%   4.00\nGRAND TOTAL   44.00';
    expect(GeminiService.fallback(ocr).total, 44.00);
  });

  test('offline check rejects text that is not a receipt', () {
    expect(GeminiService.looksLikeReceipt('HAPPY BIRTHDAY\nLove you mum'), isFalse);
    expect(GeminiService.looksLikeReceipt('Meeting at 10.30 tomorrow'), isFalse);
    expect(GeminiService.fallback('Welcome to Langkawi').isReceipt, isFalse);
    expect(GeminiService.looksLikeReceipt('KEDAI RUNCIT\nMILO 1KG 25.90\nTOTAL 25.90\nCASH 30.00'), isTrue);
  });

  test('items keep their tax relief; unknown relief keys are dropped', () {
    expect(TxnItem.fromMap({'name': 'Book', 'price': 59.9, 'relief': 'Lifestyle'}).relief, 'Lifestyle');
    expect(TxnItem.fromMap({'name': 'Milk', 'price': 7.5, 'relief': 'None'}).relief, '');
    expect(TxnItem.fromMap({'name': 'Old item', 'price': 1}).relief, '');
  });
}
