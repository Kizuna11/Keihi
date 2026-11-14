# Keihi

Keihi (経費, "expenses") is a Flutter app for tracking spending from printed receipts. You photograph a receipt, the text is read on the device, Gemini pulls out the store, date, total and a category, and you check the result before it is saved to your own ledger in Firebase.

The app is written for Malaysian receipts, so amounts are shown in RM (MYR).

## Features

- **Account login.** You register and log in with email and password (Firebase Auth). Mistakes such as a wrong password or unknown email are shown under the field. "Forgot password?" sends a Firebase reset link by email, and Profile > Change password sets a new one after checking the current password.
- **Receipt scanning.** You take a photo or pick one from the gallery. Google ML Kit reads the text on the device, and the app rebuilds it row by row so each label (TOTAL, SUBTOTAL, CASH) stays next to its amount.
- **Receipt check.** Gemini first decides whether the image is a receipt (printed, handwritten or a digital e-receipt). For anything else, such as a selfie, food, a menu or a chat screenshot, the app shows "Invalid image" with the reason and offers to scan again or upload another. Without Gemini, an offline check looks for prices and receipt wording.
- **AI parsing.** Gemini gets both the receipt photo and the OCR text, with instructions tuned for Malaysian receipts and a fixed JSON schema. It returns the store name, date, total, payment method (cash, card, Touch 'n Go eWallet, DuitNow QR, GrabPay, Boost, ShopeePay, online banking), receipt number, service charge, discount, line items (each tagged with a YA 2026 tax relief where it qualifies), and a category. The total is checked against subtotal, rounding and payment lines, and the review screen shows the printed row it came from, with a warning if that amount is not in the OCR text. Gemini picks one of your categories or suggests a new one (for example Groceries, Petrol or Bills), and you can keep it, pick another, or create your own. If the Gemini call fails, a fallback takes the first row as the store and the amount on the GRAND TOTAL or TOTAL row (skipping subtotal, cash and change), and the category is set to Others.
- **Review before saving.** Shows the receipt photo and whether the details came from AI or the fallback. You can edit the store, total, date, category, payment method and line items. The receipt number, service charge and discount are not shown but are still saved; the receipt number is used for the duplicate check. Tap any saved transaction to edit or delete it later. Before saving, the app warns you about duplicates: the same store and receipt number, or (without a receipt number) the same store, date and amount.
- **Ledger dashboard.** Pick any month with the arrows or the month picker. Shows that month's total against your budget, stat cards (today and the last 7 days for the current month, the highest day for past months, plus the daily average and tax relief items), a category breakdown, a tax relief summary for the year, the month's transactions, and a bar chart of daily spending. Tap the total card to open the transactions list, which filters by month (or all time) and category and shows the total for the filter. Swipe a transaction to delete it, with undo.
- **Tax relief (LHDN, YA 2026).** Items are tagged with reliefs such as Lifestyle, Sports, Medical, Childcare, Education, Tourism and EV & home. The Tax relief page lists the tagged items for each relief against its yearly limit. Tag or untag any item on the review screen. Parents' medical bills are only tagged by hand. Limits are in `kReliefs` in `lib/models.dart`.
- **Profile.** Set your name, profile picture and monthly budget. Choose light, dark or system theme and an accent colour. Log out, or delete your account and all its data. The profile picture is stored as a small base64 image in the Firestore profile, because Firebase Storage needs the paid Blaze plan.
- **Offline saving.** Saves go to Firestore's local cache and sync when the device is back online.

## Project layout

```
lib/
  main.dart       App entry point, Firebase init, login/home switch on auth state
  models.dart     Txn model, the category list (kCategories) and YA 2026 tax reliefs (kReliefs)
  services.dart   OcrService (ML Kit), GeminiService (parsing + fallback), Repo (Firestore)
  memory.dart     StoreMemory: what the app learns per store from saved receipts, and how it is applied
  screens.dart    Login, HomeShell (bottom nav), Ledger, Scan, Review and Profile screens
android/          Android host project (the only platform set up so far)
```

The `UCxx` comments in the code point to the use cases in the project design (for example, UC05 is OCR and UC06 is categorisation).

## Prerequisites

- Flutter SDK with Dart `^3.13.5` (see `pubspec.yaml`)
- Android SDK and an Android device or emulator. ML Kit needs a real device or a Google Play emulator image.
- A Firebase project with **Email/Password** sign-in, **Cloud Firestore**, and **AI Logic** (Gemini Developer API) turned on
- The FlutterFire CLI: `dart pub global activate flutterfire_cli`

## Setup

1. **Install dependencies**

   ```sh
   flutter pub get
   ```

2. **Connect Firebase.** The file `lib/firebase_options.dart` is not in the repo, so the app will not compile until you generate it:

   ```sh
   flutterfire configure --platforms=android
   ```

   This command creates `lib/firebase_options.dart` and `android/app/google-services.json`, and adds the Google Services Gradle plugin.

3. **Add Firestore security rules** so each user can only read and write their own data:

   ```
   rules_version = '2';
   service cloud.firestore {
     match /databases/{db}/documents {
       match /users/{uid}/{document=**} {
         allow read, write: if request.auth != null && request.auth.uid == uid;
       }
     }
   }
   ```

4. **Run the app:**

   ```sh
   flutter run
   ```

   Gemini is called through Firebase AI Logic, so the app needs no API key. If AI Logic isn't enabled or the call fails, parsing uses the regex fallback, which only finds the store and total.

## Configuration

| Setting | Where | Notes |
| --- | --- | --- |
| Gemini model | `_model` in `lib/services.dart` | Currently `gemini-2.5-flash`. Check the Firebase AI Logic docs for current model names. |
| App icon | `assets/icon/icon.png`, then `dart run flutter_launcher_icons` | 1024×1024 PNG. Settings are in `pubspec.yaml`. |
| Built-in categories | `kCategories` in `lib/models.dart` | Users can add more in the app. Icons for common names are in `_catIcons` in `lib/screens.dart`. |
| Payment methods | `kPayments` in `lib/models.dart` | Gemini can only return these (or Unknown). |
| Tax reliefs | `kReliefs` and `kReliefYear` in `lib/models.dart` | Update the limits and descriptions each year from LHDN. Gemini is told what each relief covers. |
| Gemini instructions | `_instructions` in `lib/services.dart` | Plain-English rules and examples. Rebuild the APK after editing. |

## Data model

The data lives in Firestore:

```
users/{uid}
  name: string
  currency: "MYR"
  monthlyBudget: number
  photo: string          (base64 JPEG, max 256 px; "" when removed)
  themeMode: string      ("system", "light" or "dark")
  themeColor: string     (a key of kThemeColors)
  customCategories: string[]  (added by the user or accepted from Gemini)

users/{uid}/transactions/{id}
  store: string
  amount: number
  date: timestamp        (time is set to midnight)
  category: string       (one of kCategories)
  rawText: string        (full OCR output)
  payment: string        (one of kPayments, or "")
  receiptNo: string
  serviceCharge, discount: number | null   (older documents may still have tax, the SST amount)
  items: [{name, qty, price, relief}]  (price is the line total; relief is a kReliefs key or "")
  createdAt: timestamp   (server time)

users/{uid}/stores/{storeKey(detected name)}
  from: string           (store name as Gemini or the fallback read it)
  to: string             (the name the user corrected it to; "" if they kept it)
  category: string       (the category last saved for this store)
  payment: string        (the payment method last saved)
  totalLabel: string     (words of the printed row that held the saved total, e.g. "NETT AMT")
  items: {itemKey: {n: name, r: relief}}  (the user's tax relief choice per item; r "" = none)
  scans: number          (receipts saved from scans)
  updatedAt: timestamp
```

**Learning from saved receipts.** Gemini itself is not trained. Instead, each time a receipt is saved, `Repo.remember` stores the user's choices for that store (above). On the next scan from the same store, `applyMemory` in `lib/memory.dart` fills in the remembered category, the payment method (only if the receipt doesn't print one), the amount on the remembered total row, and the item tax relief tags, and the review screen marks those fields "From your past receipts". The 30 most recent stores are also sent to Gemini as examples (`memoryHints`). Users can forget one store or everything in Profile > Learned stores.

## Development

```sh
flutter analyze      # lints (flutter_lints)
flutter test         # tests in test/ (parsing and store memory)
flutter build appbundle --release   # needs android/key.properties for signing
```
