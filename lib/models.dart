import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

/// Built-in categories every user starts with. Users and Gemini can add more
/// (stored in the profile as `customCategories`).
const kCategories = ['Food', 'Transport', 'Shopping', 'Entertainment', 'Others'];

/// Common ways Malaysians pay. '' in a Txn means not known.
const kPayments = [
  'Cash',
  'Debit/Credit card',
  "Touch 'n Go eWallet",
  'DuitNow QR',
  'GrabPay',
  'Boost',
  'ShopeePay',
  'Online banking',
  'Other',
];

/// Theme colours the user can pick on the Profile page (stored as `themeColor`).
const kThemeColors = <String, Color>{
  'Teal': Colors.teal,
  'Indigo': Colors.indigo,
  'Pink': Colors.pink,
  'Orange': Colors.deepOrange,
  'Green': Colors.green,
  'Purple': Colors.deepPurple,
};

/// Stored as `themeMode` in the profile: 'system', 'light' or 'dark'.
ThemeMode themeModeOf(Object? v) =>
    ThemeMode.values.firstWhere((m) => m.name == v, orElse: () => ThemeMode.system);

double? _num(Object? v) => (v as num?)?.toDouble();

/// A Malaysian personal income tax relief (LHDN) that receipts can count towards.
class Relief {
  final String key; // stored on TxnItem.relief
  final double limit; // RM per year of assessment
  final String covers; // shown in the app and sent to Gemini
  final bool ai; // false: only the user can pick it (Gemini can't tell who the patient is)
  const Relief(this.key, this.limit, this.covers, {this.ai = true});
}

/// Reliefs for year of assessment 2026 (Budget 2026). Check LHDN every year and update this list.
const kReliefYear = 2026;
const kReliefs = [
  Relief('Lifestyle', 2500,
      'Books, e-books, magazines, newspapers; personal computer, laptop, smartphone or tablet; '
      'internet subscription in your name; skill-improvement course fees'),
  Relief('Sports', 1000,
      'Sports equipment; gym membership; entry or rental fees for sports facilities; '
      'sports competition registration; sports training fees'),
  Relief('Medical', 10000,
      'Self, spouse or child: serious illness treatment, fertility treatment, NPRA-registered vaccines (up to RM1,000), '
      'dental treatment, full medical check-up, screening, self-test kits and health monitoring devices (up to RM1,000), '
      'mental health consultation, child learning disability diagnosis and therapy (up to RM10,000)'),
  Relief('Parents medical', 8000,
      'Medical treatment, special needs and carer costs for parents or grandparents (check-up up to RM1,000)',
      ai: false),
  Relief('Disability equipment', 6000,
      'Basic supporting equipment for a disabled self, spouse, child or parent (wheelchair, hearing aid, prosthetics)'),
  Relief('Education', 7000,
      'Your own fees at a recognised institution; upskilling and self-enhancement courses up to RM2,000'),
  Relief('Childcare', 3000,
      'Fees for a registered childcare centre, kindergarten, day care or after-school transit centre (child aged 12 or below)'),
  Relief('Breastfeeding', 1000, 'Breastfeeding equipment such as a breast pump and milk storage (once every 2 years)'),
  Relief('Tourism', 1000,
      'Entrance tickets to tourist attractions, arts and cultural programmes in Malaysia (YA 2026 only)'),
  Relief('EV & home', 2500,
      'EV charging facility installation, rental, purchase or subscription; food waste composting machine or grinder; '
      'home CCTV'),
  Relief('Insurance', 4000, 'Education or medical insurance or takaful premiums'),
];

Relief? reliefOf(String key) {
  for (final r in kReliefs) {
    if (r.key == key) return r;
  }
  return null;
}

/// One line on the receipt. [price] is the line total, not the unit price.
/// [relief] is a [Relief.key], or '' if the item doesn't count towards tax relief.
class TxnItem {
  final String name;
  final double qty;
  final double price;
  final String relief;
  const TxnItem({required this.name, this.qty = 1, required this.price, this.relief = ''});

  Map<String, dynamic> toMap() => {'name': name, 'qty': qty, 'price': price, 'relief': relief};

  factory TxnItem.fromMap(Map<String, dynamic> m) {
    final r = (m['relief'] ?? '').toString();
    return TxnItem(
        name: (m['name'] ?? '').toString(),
        qty: _num(m['qty']) ?? 1,
        price: _num(m['price']) ?? 0,
        relief: reliefOf(r) == null ? '' : r);
  }
}

class Txn {
  final String? id;
  final String store;
  final double amount;
  final DateTime date;
  final String category;
  final String rawText;
  final String payment; // one of kPayments, or ''
  final String receiptNo;
  final double? serviceCharge;
  final double? discount;
  final List<TxnItem> items;

  const Txn({
    this.id,
    required this.store,
    required this.amount,
    required this.date,
    required this.category,
    required this.rawText,
    this.payment = '',
    this.receiptNo = '',
    this.serviceCharge,
    this.discount,
    this.items = const [],
  });

  /// Sum of the line items tagged with a tax relief.
  double get reliefTotal => items.where((i) => i.relief.isNotEmpty).fold(0, (a, i) => a + i.price);

  /// Fields saved to Firestore. `createdAt` is only added for new documents (see Repo.add).
  Map<String, dynamic> toMap() => {
        'store': store,
        'amount': amount,
        'date': Timestamp.fromDate(date),
        'category': category,
        'rawText': rawText,
        'payment': payment,
        'receiptNo': receiptNo,
        'serviceCharge': serviceCharge,
        'discount': discount,
        'items': [for (final i in items) i.toMap()],
      };

  factory Txn.fromDoc(DocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data()!;
    return Txn(
      id: d.id,
      store: (m['store'] ?? '') as String,
      amount: (m['amount'] as num).toDouble(),
      date: (m['date'] as Timestamp).toDate(),
      category: (m['category'] ?? 'Others') as String,
      rawText: (m['rawText'] ?? '') as String,
      payment: (m['payment'] ?? '') as String,
      receiptNo: (m['receiptNo'] ?? '') as String,
      serviceCharge: _num(m['serviceCharge']),
      discount: _num(m['discount']),
      items: [
        for (final i in (m['items'] as List?) ?? const []) TxnItem.fromMap(Map<String, dynamic>.from(i as Map))
      ],
    );
  }
}
