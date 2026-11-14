import 'models.dart';
import 'services.dart';

/// What Keihi remembers about one store from the user's saved receipts, at users/{uid}/stores/{key}.
/// This is the app's own memory, not Gemini training: it is applied after Gemini reads a receipt,
/// and the recent ones are also sent to Gemini as examples of the user's preferences.
class StoreMemory {
  final String key; // Repo.storeKey of the name Gemini detected
  final String from; // the name as Gemini detected it
  final String to; // the name the user corrected it to, or '' if they kept it
  final String category, payment; // the user's last choices, '' if never saved
  final String totalLabel; // label of the printed row that held the real total, e.g. "NETT AMT"
  final Map<String, ({String name, String relief})> items; // itemKey → the user's tax relief choice ('' = none)
  final int scans;
  final DateTime? updatedAt;

  const StoreMemory({
    required this.key,
    this.from = '',
    this.to = '',
    this.category = '',
    this.payment = '',
    this.totalLabel = '',
    this.items = const {},
    this.scans = 0,
    this.updatedAt,
  });

  String get name => to.isNotEmpty ? to : from;

  factory StoreMemory.fromMap(String key, Map<String, dynamic> m) {
    String s(String k) => (m[k] ?? '').toString();
    final items = <String, ({String name, String relief})>{};
    final raw = m['items'];
    if (raw is Map) {
      for (final e in raw.entries) {
        final v = e.value;
        if (v is Map) {
          final r = (v['r'] ?? '').toString();
          items[e.key.toString()] = (name: (v['n'] ?? '').toString(), relief: reliefOf(r) == null ? '' : r);
        }
      }
    }
    final at = m['updatedAt'];
    return StoreMemory(
      key: key,
      from: s('from'),
      to: s('to'),
      category: s('category'),
      payment: kPayments.contains(m['payment']) ? s('payment') : '',
      totalLabel: s('totalLabel'),
      items: items,
      scans: (m['scans'] as num?)?.toInt() ?? 0,
      // Firestore Timestamp, kept loose so this file doesn't depend on Firestore.
      updatedAt: at == null ? null : (at as dynamic).toDate() as DateTime,
    );
  }
}

/// "Phone Charger 2.0" and "PHONE CHARGER 2.0" are the same item.
String itemKey(String name) {
  final k = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  return k.length > 60 ? k.substring(0, 60) : k;
}

/// The words of a receipt row without amounts or symbols: "NETT AMT   RM 23.40" → "NETT AMT".
String rowLabel(String row) {
  final words = row
      .toUpperCase()
      .replaceAll(RegExp(r'\bRM\b'), ' ')
      .replaceAll(RegExp(r'[^A-Z ]'), ' ')
      .split(' ')
      .where((w) => w.length > 1 || w == '&')
      .join(' ');
  return words.length > 40 ? words.substring(0, 40).trim() : words;
}

final _totalWords = RegExp(r'total|jumlah|amount|amt|nett|net|due|payable|bayar', caseSensitive: false);
final _payWords = RegExp(
    r'sub\s*-?\s*total|cash|tunai|tender|change|baki|card|visa|master|debit|credit|wallet|tng|touch|duitnow|'
    r'grab|boost|shopee|qr|fpx|paid|rounding|sst|tax|service',
    caseSensitive: false);

/// The label of the row that printed [amount] as the total, so the same store's next receipt can be read the
/// same way. Prefers rows that say TOTAL/JUMLAH/NETT, and skips payment rows (CASH, VISA, TNG...). Null if none.
String? totalLabelFor(String ocr, double amount) {
  final rows = [
    for (final r in ocr.split('\n'))
      if (amountsIn(r).any((a) => (a - amount).abs() < 0.005) && rowLabel(r).isNotEmpty) r
  ];
  for (final r in rows) {
    if (_totalWords.hasMatch(r) && !_payWords.hasMatch(r)) return rowLabel(r);
  }
  for (final r in rows) {
    if (!_payWords.hasMatch(r)) return rowLabel(r);
  }
  return null;
}

/// The last amount on the row whose label is [label], with that row, or null if this receipt has no such row.
(double, String)? amountForLabel(String ocr, String label) {
  if (label.isEmpty) return null;
  for (final r in ocr.split('\n')) {
    if (rowLabel(r) != label) continue;
    final a = amountsIn(r);
    if (a.isNotEmpty) return (a.last, r.trim());
  }
  return null;
}

/// Fills in what the user chose last time at this store. The receipt still wins for things that change per visit:
/// a payment method printed on the receipt is kept, and the remembered total row is only used if it is printed.
ParsedReceipt applyMemory(ParsedReceipt p, StoreMemory m, String ocr) {
  final used = <String>{};
  var category = p.category;
  if (m.category.isNotEmpty) {
    category = m.category;
    used.add('category');
  }
  var payment = p.payment;
  if (payment.isEmpty && m.payment.isNotEmpty) {
    payment = m.payment;
    used.add('payment');
  }
  var total = p.total, totalLabel = p.totalLabel, totalInText = p.totalInText;
  final found = amountForLabel(ocr, m.totalLabel);
  if (found != null) {
    used.add('total');
    total = found.$1;
    totalLabel = found.$2;
    totalInText = true;
  }
  final items = [
    for (final i in p.items)
      if (m.items[itemKey(i.name)] case final mi? when mi.relief != i.relief)
        TxnItem(name: i.name, qty: i.qty, price: i.price, relief: mi.relief)
      else
        i
  ];
  for (var n = 0; n < items.length; n++) {
    if (!identical(items[n], p.items[n])) used.add('relief');
  }
  return p.copyWith(
      category: category,
      payment: payment,
      total: total,
      totalLabel: totalLabel,
      totalInText: totalInText,
      items: items,
      remembered: used);
}

/// Short lines describing the user's most recent stores, sent to Gemini as examples.
List<String> memoryHints(Iterable<StoreMemory> memories, {int limit = 30}) {
  final list = memories.where((m) => m.name.isNotEmpty).toList()
    ..sort((a, b) => (b.updatedAt ?? DateTime(2000)).compareTo(a.updatedAt ?? DateTime(2000)));
  return [
    for (final m in list.take(limit))
      [
        m.name,
        if (m.to.isNotEmpty && m.from.isNotEmpty) 'printed as "${m.from}"',
        if (m.category.isNotEmpty) 'category ${m.category}',
        if (m.payment.isNotEmpty) 'last paid by ${m.payment}',
        if (m.totalLabel.isNotEmpty) 'total is on the row "${m.totalLabel}"',
        if (m.items.isNotEmpty)
          'tax relief: ${m.items.values.take(6).map((i) => '${i.name} = ${i.relief.isEmpty ? 'None' : i.relief}').join(', ')}',
      ].join('; ')
  ];
}
