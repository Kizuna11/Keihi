import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'memory.dart';
import 'models.dart';

/// UC05: on-device OCR with Google ML Kit.
class OcrService {
  Future<String> read(File image) async {
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      return layout(await recognizer.processImage(InputImage.fromFile(image)));
    } finally {
      recognizer.close();
    }
  }

  /// ML Kit returns text in blocks, so a label ("TOTAL") and its amount ("23.40") often end up far apart.
  /// This puts lines that sit at the same height back on one row, left to right, like the printed receipt.
  static String layout(RecognizedText r) {
    final lines = [for (final b in r.blocks) ...b.lines]
      ..sort((a, b) => a.boundingBox.center.dy.compareTo(b.boundingBox.center.dy));
    final rows = <List<TextLine>>[];
    for (final l in lines) {
      if (rows.isNotEmpty) {
        final ref = rows.last.first.boundingBox;
        final box = l.boundingBox;
        final tolerance = (ref.height < box.height ? ref.height : box.height) * 0.6;
        if ((box.center.dy - ref.center.dy).abs() <= tolerance) {
          rows.last.add(l);
          continue;
        }
      }
      rows.add([l]);
    }
    return [
      for (final row in rows)
        (row..sort((a, b) => a.boundingBox.left.compareTo(b.boundingBox.left))).map((l) => l.text).join('   ')
    ].join('\n');
  }
}

/// Money amounts with exactly two decimals, e.g. "23.40" or "1,234.50".
final _amountRe = RegExp(r'(\d{1,3}(?:,\d{3})+|\d+)\s?[.,]\s?(\d{2})(?!\d)');

List<double> amountsIn(String s) => [
      for (final m in _amountRe.allMatches(s)) double.parse('${m.group(1)!.replaceAll(',', '')}.${m.group(2)}')
    ];

class ParsedReceipt {
  final String store;
  final double? total;
  final String totalLabel; // the printed row the total was read from
  final bool totalInText; // false when the total isn't anywhere in the OCR text, so it needs checking
  final DateTime? date;
  final String category;
  final String payment; // one of kPayments, or ''
  final String receiptNo;
  final double? serviceCharge, discount;
  final List<TxnItem> items;
  final bool fromAi; // false when Gemini failed and the regex fallback was used
  final bool isReceipt; // false for photos that aren't a receipt (a selfie, a screenshot of a chat, a menu...)
  final String notReceiptReason; // short explanation shown to the user when isReceipt is false
  /// Fields filled from the user's past receipts at this store (see applyMemory): 'category', 'payment',
  /// 'total', 'relief'.
  final Set<String> remembered;
  const ParsedReceipt({
    this.isReceipt = true,
    this.notReceiptReason = '',
    this.store = '',
    this.total,
    this.totalLabel = '',
    this.totalInText = true,
    this.date,
    this.category = 'Others',
    this.payment = '',
    this.receiptNo = '',
    this.serviceCharge,
    this.discount,
    this.items = const [],
    this.fromAi = false,
    this.remembered = const {},
  });

  ParsedReceipt copyWith({
    String? category,
    String? payment,
    double? total,
    String? totalLabel,
    bool? totalInText,
    List<TxnItem>? items,
    Set<String>? remembered,
  }) =>
      ParsedReceipt(
        isReceipt: isReceipt,
        notReceiptReason: notReceiptReason,
        store: store,
        total: total ?? this.total,
        totalLabel: totalLabel ?? this.totalLabel,
        totalInText: totalInText ?? this.totalInText,
        date: date,
        category: category ?? this.category,
        payment: payment ?? this.payment,
        receiptNo: receiptNo,
        serviceCharge: serviceCharge,
        discount: discount,
        items: items ?? this.items,
        fromAi: fromAi,
        remembered: remembered ?? this.remembered,
      );
}

/// UC06: Gemini turns the receipt photo + OCR text into the receipt details, a category and tax relief tags.
/// Called through Firebase AI Logic, so no API key ships in the app.
class GeminiService {
  static final _aiReliefs = kReliefs.where((r) => r.ai).toList();

  static final _instructions = '''
You extract data from photos of Malaysian printed receipts. You get the photo and the OCR text read from it.
The photo is the source of truth. The OCR text is rebuilt row by row, top to bottom, with the parts of one printed
row separated by spaces, so a label and its amount are usually on the same row. It can contain misread characters.

isReceipt: first decide whether the image is a receipt at all. Users sometimes pick a random photo by mistake.
- true: a printed or handwritten receipt, cash bill, tax invoice, utility or phone bill, payment slip, or a screenshot
  or photo of a digital receipt / e-receipt / order confirmation (Grab, Shopee, Lazada, foodpanda, online banking)
  that shows what was paid. A receipt that is crumpled, faded, partly cut off or photographed at an angle is still true.
- false: anything else, e.g. people, selfies, pets, food, scenery, a product or price tag, a restaurant menu, a flyer
  or advertisement, a chat screenshot, a document or letter, an ID card, a bank card, a QR code alone, a blank page,
  or an image too blurry or dark to tell what it is.
notReceiptReason: when isReceipt is false, one short sentence for the user saying what the image looks like,
e.g. "This looks like a photo of food, not a receipt." or "The image is too blurry to read." Empty when isReceipt is true.
When isReceipt is false, leave every other field empty or null and items as an empty list.

The user's past receipts: you may get a list of stores this user saved before, with the name they prefer, the
category they chose, how they last paid, which printed row held the real total, and their tax relief choices.
These are the user's own corrections, so when this receipt is from one of those stores, follow them
(use their store name spelling, their category, their total row, and their relief choice for the same items).
For other stores, use the list as examples of what this user prefers.

total: the most important field. It is the final amount the customer paid, in MYR.
1. Use the amount on the row labelled with the final total, usually after the items and tax lines:
   "GRAND TOTAL", "TOTAL", "NETT TOTAL", "NET TOTAL", "TOTAL (RM)", "TOTAL INCL. SST", "TOTAL PAYABLE", "AMOUNT DUE",
   "TOTAL DUE", "JUMLAH", "JUMLAH BESAR", "JUMLAH BAYARAN", "ROUNDED TOTAL".
2. Never use: SUBTOTAL / SUB-TOTAL / TOTAL EXCL. SST / TOTAL BEFORE TAX, the SST or service tax line, CASH / TUNAI,
   TENDERED, CHANGE / BAKI, TOTAL QTY / TOTAL ITEMS / NO. OF ITEMS, TOTAL SAVINGS / YOU SAVED, points or card balances,
   or the totals in a tax summary table at the bottom of the receipt.
3. If there is a rounding line (ROUNDING, ROUNDING ADJ, PELARASAN), use the amount after rounding.
4. Check the answer before returning it: subtotal + tax + service charge - discount + rounding = total;
   the amount charged to a card, e-wallet or QR usually equals the total; cash tendered - change = total.
   If a check fails, read the photo again; the photo decides.
5. Read the digits carefully: OCR often confuses 1 and 7, 5, 6 and 8, 0 and 8, and loses or adds the decimal point.
   Amounts have exactly 2 decimals. "1,234.50" is 1234.50. Null only if no total is visible at all.
totalLabel: the label and amount exactly as printed on the row you used, e.g. "GRAND TOTAL RM 23.40".

store: the brand or trading name a customer would recognise, usually the large text or logo at the top.
- Prefer the brand over the legal company name: "99 Speedmart", not "99 SPEED MART SDN BHD (519537-X)".
- Drop "Sdn Bhd", "Bhd", "Enterprise", registration numbers, branch names and outlet codes.
- Never use "TAX INVOICE", "RECEIPT", "CASH BILL", "SIMPLIFIED INVOICE", addresses, phone numbers, SST or GST lines.
- Write it in normal title case unless the brand is styled differently (KFC, myNEWS, AEON, MR. D.I.Y.).
- If the user's past receipts list has the same store, return the name they prefer, exactly as written.
- Use an empty string if no store name is visible.
date: the transaction date as YYYY-MM-DD. Malaysian receipts write dates day first (05/03/2026 is 5 March 2026). Null if none.

category: the spending category that best describes the whole receipt.
- First choose from the user's categories if one fits well.
- If none fits well, suggest a new category: 1-2 words, Title Case, general enough to reuse for other stores
  (good: "Groceries", "Petrol", "Bills", "Health", "Education", "Personal Care", "Home"; bad: "KFC Meal", "Tuesday Lunch").
- Hints: restaurants, cafes, mamak, food courts and food delivery (GrabFood, foodpanda) are Food;
  petrol, tolls, parking, e-hailing (Grab, inDrive), LRT/MRT/bus are Transport;
  clothes, electronics, department stores and online shopping are Shopping; cinema, games, events and streaming are Entertainment.
- Use "Others" only if you really cannot tell.

payment: how it was paid. Look for words like CASH, VISA, MASTERCARD, DEBIT, CREDIT, "TNG", "Touch n Go", "DuitNow", "QR",
"GrabPay", "Boost", "ShopeePay", "FPX". A card line with only a masked number (XXXX1234) is "Debit/Credit card".
Use "Unknown" if the receipt does not say.
receiptNo: the receipt, invoice, bill or order number exactly as printed (e.g. "INV-00012345", "#A123"). Null if none.
serviceCharge: the service charge amount in MYR (often "SC 10%"). Null if not shown.
discount: the total discount or voucher amount in MYR as a positive number. Null if none.

items: each purchased line item with its name as printed (clean up obvious OCR errors and expand obvious abbreviations),
quantity (1 if not shown) and line total in MYR (quantity x unit price, after any discount on that line).
Leave out subtotal, tax, service charge, rounding, payment and change lines. Empty list if items cannot be read.
If the whole receipt is for one thing that qualifies for tax relief (a gym membership, school fees, a dental bill)
but no item lines are printed, return one item for it with the total as its price.

relief: for each item, the Malaysian personal income tax relief for year of assessment $kReliefYear (LHDN) it
qualifies for, or "None". Be strict and only tag items that clearly fit; most groceries, food and household items are "None".
Use the store type for context (bookshop, clinic, pharmacy, sports shop, phone shop, childcare centre).
${_aiReliefs.map((r) => '- ${r.key} (up to RM${r.limit.toStringAsFixed(0)} a year): ${r.covers}.').join('\n')}
Do not tag: phone cases, chargers, cables, earphones, screen protectors and other accessories; stationery; video games;
TVs and household appliances; sportswear, sports shoes and supplements; vitamins, over-the-counter medicine,
cosmetics and face masks; a normal GP visit for a minor illness; food and drinks.

Examples:
"99 SPEED MART SDN BHD (519537-X) ... SUB TOTAL 23.40 ... TOTAL RM 23.40 ... CASH 50.00 ... CHANGE 26.60"
  -> store "99 Speedmart", total 23.40, totalLabel "TOTAL RM 23.40", category "Food" or "Groceries", payment "Cash"
"KFC HOLDINGS (MALAYSIA) BHD KFC JALAN TAR ... SUBTOTAL 17.85 ... SST 6% 1.07 ... ROUNDING ADJ -0.02 ... TOTAL 18.90 ... TNG EWALLET 18.90"
  -> store "KFC", total 18.90 (17.85 + 1.07 - 0.02), category "Food", payment "Touch 'n Go eWallet"
"POPULAR BOOKSTORE ... ATOMIC HABITS 59.90 ... A4 NOTEBOOK 8.50 ... TOTAL 68.40"
  -> items "Atomic Habits" relief "Lifestyle", "A4 Notebook" relief "None"
"DECATHLON ... BADMINTON RACKET 129.00 ... SPORTS SOCKS 19.90" -> racket "Sports", socks "None"
"KLINIK PERGIGIAN ... SCALING & POLISHING 120.00" -> one item, relief "Medical"
"PETRONAS DAGANGAN BHD STESEN MINYAK ... RON95 ... VISA XXXX4321" -> store "Petronas", category "Transport" or "Petrol", payment "Debit/Credit card"''';

  static final _model = FirebaseAI.googleAI().generativeModel(
    model: 'gemini-2.5-flash', // check the current model name in the Firebase AI Logic docs
    systemInstruction: Content.system(_instructions),
    generationConfig: GenerationConfig(
      temperature: 0,
      responseMimeType: 'application/json',
      responseSchema: Schema.object(
        // totalLabel comes before total so the model reads the printed row before it writes the number.
        // isReceipt comes first so the model decides that before extracting anything.
        propertyOrdering: const [
          'isReceipt', 'notReceiptReason', 'store', 'date', 'totalLabel', 'total', 'category', 'payment', 'receiptNo',
          'serviceCharge', 'discount', 'items'
        ],
        properties: {
          'isReceipt': Schema.boolean(description: 'false if the image is not a receipt, bill or invoice'),
          'notReceiptReason': Schema.string(description: 'One short sentence; empty when isReceipt is true'),
          'store': Schema.string(),
          'date': Schema.string(description: 'YYYY-MM-DD', nullable: true),
          'totalLabel': Schema.string(description: 'The printed row the total was read from', nullable: true),
          'total': Schema.number(description: 'Final amount paid in MYR', nullable: true),
          'category': Schema.string(description: "One of the user's categories, or a new 1-2 word category"),
          'payment': Schema.enumString(enumValues: [...kPayments, 'Unknown']),
          'receiptNo': Schema.string(nullable: true),
          'serviceCharge': Schema.number(nullable: true),
          'discount': Schema.number(nullable: true),
          'items': Schema.array(
            items: Schema.object(
              propertyOrdering: const ['name', 'qty', 'price', 'relief'],
              properties: {
                'name': Schema.string(),
                'qty': Schema.number(),
                'price': Schema.number(description: 'Line total in MYR'),
                'relief': Schema.enumString(enumValues: ['None', for (final r in _aiReliefs) r.key]),
              },
            ),
          ),
        },
      ),
    ),
  );

  /// [pastReceipts] describe stores the user saved before (see memoryHints), so Gemini can follow their choices.
  /// [categories] are the user's categories, built-in and custom; Gemini prefers these.
  Future<ParsedReceipt> parse(String ocr,
      {File? image, List<String> pastReceipts = const [], List<String> categories = kCategories}) async {
    try {
      final prompt = StringBuffer()..writeln("User's categories: ${categories.join('; ')}\n");
      if (pastReceipts.isNotEmpty) {
        prompt.writeln("The user's past receipts:\n${pastReceipts.map((h) => '- $h').join('\n')}\n");
      }
      prompt.write('OCR TEXT:\n$ocr');
      final res = await _model.generateContent([
        Content.multi([
          TextPart(prompt.toString()),
          if (image != null) InlineDataPart('image/jpeg', await image.readAsBytes()),
        ])
      ]).timeout(const Duration(seconds: 45));
      final m = jsonDecode(res.text!) as Map<String, dynamic>;
      double? n(String k) => (m[k] as num?)?.toDouble();
      if (m['isReceipt'] == false) {
        final why = (m['notReceiptReason'] ?? '').toString().trim();
        return ParsedReceipt(
            isReceipt: false, notReceiptReason: why.isEmpty ? 'This image doesn\'t look like a receipt.' : why);
      }
      final total = n('total');
      return ParsedReceipt(
        store: (m['store'] ?? '').toString(),
        total: total,
        totalLabel: (m['totalLabel'] ?? '').toString().trim(),
        totalInText: total == null || _seen(total, ocr),
        date: DateTime.tryParse((m['date'] ?? '').toString()),
        category: _cleanCategory((m['category'] ?? '').toString(), categories),
        payment: kPayments.contains(m['payment']) ? m['payment'] as String : '',
        receiptNo: (m['receiptNo'] ?? '').toString().trim(),
        serviceCharge: n('serviceCharge'),
        discount: n('discount'),
        items: [
          for (final i in (m['items'] as List?) ?? const [])
            if (i is Map && (i['name'] ?? '').toString().trim().isNotEmpty)
              TxnItem.fromMap(Map<String, dynamic>.from(i)),
        ],
        fromAi: true,
      );
    } catch (_) {
      return fallback(ocr); // UC06 exception flow: default to "Others", user edits manually
    }
  }

  static bool _seen(double v, String ocr) => amountsIn(ocr).any((a) => (a - v).abs() < 0.005);

  /// Reuses the user's spelling of an existing category ("groceries" → "Groceries") and trims odd output.
  static String _cleanCategory(String c, List<String> categories) {
    c = c.trim();
    if (c.isEmpty) return 'Others';
    for (final k in categories) {
      if (k.toLowerCase() == c.toLowerCase()) return k;
    }
    return c.length > 24 ? c.substring(0, 24).trim() : c;
  }

  static final _finalTotal = RegExp(
      r'grand\s*total|net+\s*total|total\s*payable|amount\s*due|total\s*due|jumlah|rounded\s*total',
      caseSensitive: false);
  static final _anyTotal = RegExp(r'total', caseSensitive: false);
  static final _notTotal = RegExp(
      r'sub\s*-?\s*total|total\s*(qty|quantity|item|items|saving|savings|disc|discount|excl|before|sst|gst|tax)'
      r'|tender|change|baki|cash|tunai|point',
      caseSensitive: false);

  static final _receiptWords = RegExp(
      r'total|jumlah|amount|subtotal|cash|tunai|change|baki|receipt|resit|invoice|invois|\bbill\b|\bbil\b|'
      r'\bsst\b|\btax\b|cukai|\bqty\b|paid|payment|\brm\s?\d',
      caseSensitive: false);

  /// Without Gemini, a rough check: a receipt has money amounts and some receipt wording.
  static bool looksLikeReceipt(String ocr) {
    final amounts = amountsIn(ocr).length;
    return amounts >= 1 && (_receiptWords.hasMatch(ocr) || amounts >= 3);
  }

  /// Without Gemini: the store is the first row and the total is the last amount on the best total row.
  static ParsedReceipt fallback(String ocr) {
    if (!looksLikeReceipt(ocr)) {
      return const ParsedReceipt(
          isReceipt: false, notReceiptReason: 'No prices or totals were found, so this doesn\'t look like a receipt.');
    }
    final rows = ocr.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    double? total;
    String label = '';
    for (final re in [_finalTotal, _anyTotal]) {
      for (final r in rows) {
        if (!re.hasMatch(r) || _notTotal.hasMatch(r)) continue;
        final a = amountsIn(r);
        if (a.isNotEmpty) {
          total = a.last;
          label = r;
          break;
        }
      }
      if (total != null) break;
    }
    return ParsedReceipt(store: rows.isEmpty ? '' : rows.first, total: total, totalLabel: label);
  }
}

/// UC08 + UC09: Firestore at users/{uid} and users/{uid}/transactions/{id}.
class Repo {
  static final _db = FirebaseFirestore.instance;
  static String get uid => FirebaseAuth.instance.currentUser!.uid;
  static DocumentReference<Map<String, dynamic>> get _profile => _db.collection('users').doc(uid);
  static CollectionReference<Map<String, dynamic>> get _txns => _profile.collection('transactions');

  static Stream<List<Txn>> txns() =>
      _txns.orderBy('date', descending: true).snapshots().map((s) => s.docs.map(Txn.fromDoc).toList());

  static Future<void> add(Txn t) => _txns.add({...t.toMap(), 'createdAt': FieldValue.serverTimestamp()});
  // 'tax' (SST) is no longer recorded; remove it from older transactions when they are edited.
  static Future<void> update(Txn t) => _txns.doc(t.id).update({...t.toMap(), 'tax': FieldValue.delete()});
  static Future<void> remove(String id) => _txns.doc(id).delete();

  /// Built-in categories followed by the user's own (profile `customCategories`).
  static List<String> categoriesOf(Map<String, dynamic>? profile) => [
        ...kCategories,
        for (final c in (profile?['customCategories'] as List?) ?? const [])
          if (!kCategories.contains(c)) c as String,
      ];
  static Future<List<String>> categories() async => categoriesOf(await profile().first);
  static Future<void> addCategory(String c) =>
      saveProfile({'customCategories': FieldValue.arrayUnion([c])});
  static Future<void> removeCategory(String c) =>
      saveProfile({'customCategories': FieldValue.arrayRemove([c])});

  /// What the app learned per store from saved receipts, at users/{uid}/stores/{storeKey(detected)}.
  /// See StoreMemory in memory.dart.
  static CollectionReference<Map<String, dynamic>> get _stores => _profile.collection('stores');

  /// Matches "99 SPEED MART" and "99 Speed Mart." to the same alias.
  static String storeKey(String name) {
    final k = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return k.length > 100 ? k.substring(0, 100) : k;
  }

  /// Store key → memory. Empty if offline with no cache.
  static Future<Map<String, StoreMemory>> storeMemories() async {
    try {
      final q = await _stores.get();
      return {for (final d in q.docs) d.id: StoreMemory.fromMap(d.id, d.data())};
    } catch (_) {
      return {};
    }
  }

  static Stream<List<StoreMemory>> storeMemoriesStream() => _stores.snapshots().map((s) =>
      [for (final d in s.docs) StoreMemory.fromMap(d.id, d.data())]..sort((a, b) => a.name.compareTo(b.name)));

  /// The memory for a store, by the name Gemini detected or by the user's corrected name.
  static StoreMemory? memoryFor(Map<String, StoreMemory> memories, String store) {
    final k = storeKey(store);
    if (k.isEmpty) return null;
    return memories[k] ?? memories.values.where((m) => m.to.isNotEmpty && storeKey(m.to) == k).firstOrNull;
  }

  /// Learns from a saved receipt: the store name, category, payment, which row held the total and the item tax
  /// relief choices. [detected] is the store name Gemini read (empty when editing a saved transaction).
  static Future<void> remember(Txn t, {String detected = ''}) async {
    var key = storeKey(detected.isNotEmpty ? detected : t.store);
    var from = detected;
    if (detected.isEmpty) {
      // Editing: find the memory this store's name came from, if any.
      try {
        final q = await _stores.where('to', isEqualTo: t.store).limit(1).get();
        if (q.docs.isNotEmpty) {
          key = q.docs.first.id;
          from = (q.docs.first.data()['from'] ?? '') as String;
        }
      } catch (_) {}
      if (from.isEmpty) from = t.store;
    }
    if (key.isEmpty) return;
    final label = totalLabelFor(t.rawText, t.amount);
    await _stores.doc(key).set({
      'from': from,
      'to': t.store == from ? '' : t.store,
      'category': t.category,
      if (t.payment.isNotEmpty) 'payment': t.payment,
      'totalLabel': ?label,
      // Merged into the existing map, so items from earlier receipts are kept.
      'items': {
        for (final i in t.items.take(40))
          if (itemKey(i.name).isNotEmpty) itemKey(i.name): {'n': i.name, 'r': i.relief},
      },
      if (detected.isNotEmpty) 'scans': FieldValue.increment(1),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }

  static Future<void> forgetStore(String key) => _stores.doc(key).delete();

  static Future<void> forgetAllStores() async {
    final batch = _db.batch();
    for (final d in (await _stores.get()).docs) {
      batch.delete(d.reference);
    }
    await batch.commit();
  }

  /// Same store + receipt number is a duplicate; without a receipt number, same store + date + amount.
  static Future<bool> isDuplicate(Txn t) async {
    final byStore = _txns.where('store', isEqualTo: t.store);
    final q = await (t.receiptNo.isNotEmpty
            ? byStore.where('receiptNo', isEqualTo: t.receiptNo)
            : byStore
                .where('amount', isEqualTo: t.amount)
                .where('date', isEqualTo: Timestamp.fromDate(t.date)))
        .limit(1)
        .get();
    return q.docs.isNotEmpty;
  }

  /// Play policy: users must be able to delete their account and data in-app.
  /// Throws FirebaseAuthException 'requires-recent-login' if the sign-in is old.
  static Future<void> deleteAccount() async {
    final batch = _db.batch();
    for (final d in [...(await _txns.get()).docs, ...(await _stores.get()).docs]) {
      batch.delete(d.reference);
    }
    batch.delete(_profile);
    await batch.commit();
    await FirebaseAuth.instance.currentUser!.delete();
  }

  static Stream<Map<String, dynamic>> profile() => _profile.snapshots().map((d) => d.data() ?? {});
  static Future<void> saveProfile(Map<String, dynamic> m) => _profile.set(m, SetOptions(merge: true));
}
