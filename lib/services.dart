import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_ai/firebase_ai.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'models.dart';

/// UC05: on-device OCR with Google ML Kit.
class OcrService {
  Future<String> read(File image) async {
    final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
    try {
      final result = await recognizer.processImage(InputImage.fromFile(image));
      return result.text;
    } finally {
      recognizer.close();
    }
  }
}

class ParsedReceipt {
  final String store;
  final double? total;
  final DateTime? date;
  final String category;
  final String payment; // one of kPayments, or ''
  final String receiptNo;
  final double? tax, serviceCharge, discount;
  final List<TxnItem> items;
  final bool fromAi; // false when Gemini failed and the regex fallback was used
  const ParsedReceipt({
    this.store = '',
    this.total,
    this.date,
    this.category = 'Others',
    this.payment = '',
    this.receiptNo = '',
    this.tax,
    this.serviceCharge,
    this.discount,
    this.items = const [],
    this.fromAi = false,
  });
}

/// UC06: Gemini turns the receipt photo + OCR text into the receipt details and a category.
/// Called through Firebase AI Logic, so no API key ships in the app.
class GeminiService {
  static const _instructions = '''
You extract data from photos of Malaysian printed receipts. You get the photo and the OCR text read from it.
The photo is the source of truth; the OCR text helps with small print but can contain misread characters.

store: the brand or trading name a customer would recognise, usually the large text or logo at the top.
- Prefer the brand over the legal company name: "99 Speedmart", not "99 SPEED MART SDN BHD (519537-X)".
- Drop "Sdn Bhd", "Bhd", "Enterprise", registration numbers, branch names and outlet codes.
- Never use "TAX INVOICE", "RECEIPT", "CASH BILL", "SIMPLIFIED INVOICE", addresses, phone numbers, SST or GST lines.
- Write it in normal title case unless the brand is styled differently (KFC, myNEWS, AEON, MR. D.I.Y.).
- If the user's known stores list has the same store, return that exact spelling.
- Use an empty string if no store name is visible.
date: the transaction date as YYYY-MM-DD. Malaysian receipts write dates day first (05/03/2026 is 5 March 2026). Null if none.
total: the final amount paid in MYR after tax, rounding and discounts (not the subtotal, cash tendered or change). Null if none.

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
tax: the SST amount in MYR (often "SST 6%", "SST 8%", "Service Tax"). Null if not shown.
serviceCharge: the service charge amount in MYR (often "SC 10%"). Null if not shown.
discount: the total discount or voucher amount in MYR as a positive number. Null if none.
items: each purchased line item with its name as printed (clean up obvious OCR errors), quantity (1 if not shown)
and line total in MYR. Leave out subtotal, tax, rounding, payment and change lines. Empty list if items cannot be read.

Examples:
"99 SPEED MART SDN BHD (519537-X) ... TOTAL RM 23.40 ... CASH 50.00" -> store "99 Speedmart", category "Food" or "Groceries", payment "Cash"
"KFC HOLDINGS (MALAYSIA) BHD KFC JALAN TAR ... SST 6% 1.07 ... ROUNDING ADJ -0.02 TOTAL 18.90 ... TNG EWALLET"
  -> store "KFC", total 18.90, tax 1.07, category "Food", payment "Touch 'n Go eWallet"
"PETRONAS DAGANGAN BHD STESEN MINYAK ... RON95 ... VISA XXXX4321" -> store "Petronas", category "Transport" or "Petrol", payment "Debit/Credit card"
"TNB ... BIL ELEKTRIK ... JUMLAH RM 120.50 ... FPX" -> store "TNB", category "Bills", payment "Online banking"''';

  static final _model = FirebaseAI.googleAI().generativeModel(
    model: 'gemini-2.5-flash', // check the current model name in the Firebase AI Logic docs
    systemInstruction: Content.system(_instructions),
    generationConfig: GenerationConfig(
      responseMimeType: 'application/json',
      responseSchema: Schema.object(properties: {
        'store': Schema.string(),
        'date': Schema.string(description: 'YYYY-MM-DD', nullable: true),
        'total': Schema.number(nullable: true),
        'category': Schema.string(description: "One of the user's categories, or a new 1-2 word category"),
        'payment': Schema.enumString(enumValues: [...kPayments, 'Unknown']),
        'receiptNo': Schema.string(nullable: true),
        'tax': Schema.number(nullable: true),
        'serviceCharge': Schema.number(nullable: true),
        'discount': Schema.number(nullable: true),
        'items': Schema.array(
          items: Schema.object(properties: {
            'name': Schema.string(),
            'qty': Schema.number(),
            'price': Schema.number(description: 'Line total in MYR'),
          }),
        ),
      }),
    ),
  );

  /// [knownStores] are names the user corrected before, so Gemini can reuse their spelling.
  /// [categories] are the user's categories, built-in and custom; Gemini prefers these.
  Future<ParsedReceipt> parse(String ocr,
      {File? image, List<String> knownStores = const [], List<String> categories = kCategories}) async {
    try {
      final prompt = StringBuffer()..writeln("User's categories: ${categories.join('; ')}\n");
      if (knownStores.isNotEmpty) prompt.writeln('Known stores for this user: ${knownStores.join('; ')}\n');
      prompt.write('OCR TEXT:\n$ocr');
      final res = await _model.generateContent([
        Content.multi([
          TextPart(prompt.toString()),
          if (image != null) InlineDataPart('image/jpeg', await image.readAsBytes()),
        ])
      ]).timeout(const Duration(seconds: 30));
      final m = jsonDecode(res.text!) as Map<String, dynamic>;
      double? n(String k) => (m[k] as num?)?.toDouble();
      return ParsedReceipt(
        store: (m['store'] ?? '').toString(),
        total: n('total'),
        date: DateTime.tryParse((m['date'] ?? '').toString()),
        category: _cleanCategory((m['category'] ?? '').toString(), categories),
        payment: kPayments.contains(m['payment']) ? m['payment'] as String : '',
        receiptNo: (m['receiptNo'] ?? '').toString().trim(),
        tax: n('tax'),
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
      return _fallback(ocr); // UC06 exception flow: default to "Others", user edits manually
    }
  }

  /// Reuses the user's spelling of an existing category ("groceries" → "Groceries") and trims odd output.
  static String _cleanCategory(String c, List<String> categories) {
    c = c.trim();
    if (c.isEmpty) return 'Others';
    for (final k in categories) {
      if (k.toLowerCase() == c.toLowerCase()) return k;
    }
    return c.length > 24 ? c.substring(0, 24).trim() : c;
  }

  ParsedReceipt _fallback(String ocr) {
    final lines = ocr.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty);
    final m = RegExp(r'total[^0-9]*([0-9]+[.,][0-9]{2})', caseSensitive: false).firstMatch(ocr);
    return ParsedReceipt(
      store: lines.isEmpty ? '' : lines.first,
      total: m == null ? null : double.tryParse(m.group(1)!.replaceAll(',', '.')),
    );
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
  static Future<void> update(Txn t) => _txns.doc(t.id).update(t.toMap());
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

  /// Store names the user corrected on the review screen, at users/{uid}/stores/{storeKey(detected)}.
  static CollectionReference<Map<String, dynamic>> get _stores => _profile.collection('stores');

  /// Matches "99 SPEED MART" and "99 Speed Mart." to the same alias.
  static String storeKey(String name) {
    final k = name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return k.length > 100 ? k.substring(0, 100) : k;
  }

  /// Detected-name key → the name the user wants instead. Empty if offline with no cache.
  static Future<Map<String, String>> storeAliases() async {
    try {
      final q = await _stores.get();
      return {for (final d in q.docs) d.id: (d.data()['to'] ?? '') as String};
    } catch (_) {
      return {};
    }
  }

  /// Remember that [detected] should be shown as [corrected]; forget it if they match again.
  static Future<void> learnStore(String detected, String corrected) {
    final key = storeKey(detected);
    if (key.isEmpty) return Future.value();
    final doc = _stores.doc(key);
    if (corrected.isEmpty || corrected == detected) return doc.delete();
    return doc.set({'from': detected, 'to': corrected, 'updatedAt': FieldValue.serverTimestamp()});
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
