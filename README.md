# Keihi

Keihi (経費, "expenses") is a Flutter app for tracking spending from printed receipts. You photograph a receipt, the text is read on the device, Gemini pulls out the store, date, total and a category, and you check the result before it is saved to your own ledger in Firebase.

The app is written for Malaysian receipts, so amounts are shown in RM (MYR).

## Features

- **Account login.** You register and log in with email and password (Firebase Auth).
- **Receipt scanning.** You take a photo or pick one from the gallery. Google ML Kit reads the text on the device.
- **AI parsing.** Gemini gets both the receipt photo and the OCR text, with instructions tuned for Malaysian receipts and a fixed JSON schema. It returns the store name, date, total, payment method (cash, card, Touch 'n Go eWallet, DuitNow QR, GrabPay, Boost, ShopeePay, online banking), receipt number, SST, service charge, discount, line items, and a category. Gemini picks one of your categories or suggests a new one (for example Groceries, Petrol or Bills), and you can keep it, pick another, or create your own. If the Gemini call fails, a regex fallback guesses the store and total, and the category is set to Others.
- **Review before saving.** Shows the receipt photo and whether the details came from AI or the fallback. You can edit every field, including payment method and line items. Tap any saved transaction to edit or delete it later. Before saving, the app warns you about duplicates: the same store and receipt number, or (without a receipt number) the same store, date and amount.
- **Ledger dashboard.** Shows this month's total against your budget, cards for today, the last 7 days, the daily average and the receipt count, a category breakdown, recent transactions, and a bar chart of daily spending for the month. Swipe a transaction to delete it, with undo.
- **Profile.** Set your name, profile picture and monthly budget. Choose light, dark or system theme and an accent colour. Log out, or delete your account and all its data. The profile picture is stored as a small base64 image in the Firestore profile, because Firebase Storage needs the paid Blaze plan.
- **Offline saving.** Saves go to Firestore's local cache and sync when the device is back online.

## Project layout

```
lib/
  main.dart       App entry point, Firebase init, login/home switch on auth state
  models.dart     Txn model and the category list (kCategories)
  services.dart   OcrService (ML Kit), GeminiService (parsing + fallback), Repo (Firestore)
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
  tax, serviceCharge, discount: number | null
  items: [{name, qty, price}]  (price is the line total)
  createdAt: timestamp   (server time)

users/{uid}/stores/{storeKey(detected name)}
  from: string           (store name as Gemini or the fallback read it)
  to: string             (the name the user corrected it to)
  updatedAt: timestamp
```

Store corrections are learned automatically: when you change the store name on the review screen, the next receipt with the same detected name is filled in with your version, and your saved names are sent to Gemini as hints.

## Development

```sh
flutter analyze      # lints (flutter_lints)
flutter test         # there is no test/ folder yet
flutter build appbundle --release   # needs android/key.properties for signing
```
