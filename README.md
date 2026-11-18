# Restaurant POS

Offline-first Flutter point-of-sale application targeting **Android first** and **Windows desktop** from the same Dart codebase. This repository contains Flutter source code, not a prebuilt APK.

## Implemented modules

- 20-table order management with item quantity changes.
- Editable menu: create products, edit names/categories/prices, stock levels and low-stock thresholds.
- Kitchen queue with queued, preparing, ready and served states.
- Inventory reservation across open tables, stock-safe quantity controls, deduction after completed sales and manual stock adjustments.
- Fixed-amount and percentage discounts with reason and audit entry.
- Cash, card and split payments with cash tender and automatic change calculation; payment parts must exactly cover the final bill.
- Daily sales report with transaction history, staff attribution and payment-method totals.
- Staff profiles and role labels (Manager, Waiter, Kitchen), PIN-verified operator switching, salted SHA-256 PIN storage and account activation controls.
- Audit history for order, discount, menu, stock, payment, staff and operator actions.
- Azerbaijani manat (AZN) in qəpik precision and Azerbaijan UTC+4 business date.
- Local persistence with serialized asynchronous writes; no network connection is required for normal use.

## Build

Install the stable Flutter SDK, then run:

```bash
flutter create --platforms=android,windows --project-name restaurant_pos .
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

APK output: `build/app/outputs/flutter-apk/app-release.apk`.

On Windows, enable desktop support and run `flutter build windows --release`. GitHub Actions runs analysis/tests and builds the Android APK and Windows desktop artifact on pushes to `main`.

## Data and security notes

Data is stored locally through `shared_preferences`; phone and Windows installations keep separate independent data and work offline. This storage is suitable for a single-device personal-use prototype, but it is not yet a transactional SQLite database. The next reliability stage should move it to SQLite with WAL, full synchronous writes, atomic transactions and rotating local backups to better protect against sudden power loss. PINs are salted SHA-256 hashes rather than plaintext, but this remains local application-level protection, not enterprise-grade authentication. Back up device data before reinstalling or clearing app storage.