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

/// One line on the receipt. [price] is the line total, not the unit price.
class TxnItem {
  final String name;
  final double qty;
  final double price;
  const TxnItem({required this.name, this.qty = 1, required this.price});

  Map<String, dynamic> toMap() => {'name': name, 'qty': qty, 'price': price};

  factory TxnItem.fromMap(Map<String, dynamic> m) =>
      TxnItem(name: (m['name'] ?? '').toString(), qty: _num(m['qty']) ?? 1, price: _num(m['price']) ?? 0);
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
  final double? tax; // SST
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
    this.tax,
    this.serviceCharge,
    this.discount,
    this.items = const [],
  });

  /// Fields saved to Firestore. `createdAt` is only added for new documents (see Repo.add).
  Map<String, dynamic> toMap() => {
        'store': store,
        'amount': amount,
        'date': Timestamp.fromDate(date),
        'category': category,
        'rawText': rawText,
        'payment': payment,
        'receiptNo': receiptNo,
        'tax': tax,
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
      tax: _num(m['tax']),
      serviceCharge: _num(m['serviceCharge']),
      discount: _num(m['discount']),
      items: [
        for (final i in (m['items'] as List?) ?? const []) TxnItem.fromMap(Map<String, dynamic>.from(i as Map))
      ],
    );
  }
}
