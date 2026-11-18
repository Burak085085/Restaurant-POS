# Restaurant POS

Offline-first Flutter point-of-sale application targeting **Android first** and **Windows desktop** from the same Dart codebase. This repository contains Flutter source code, not a prebuilt APK.

## Implemented modules

- 20-table order management with item quantity changes.
- Editable menu: create products, edit names/categories/prices, stock levels and low-stock thresholds.
- Kitchen queue with queued, preparing, ready and served states.
- Inventory deduction after completed sales and manual stock adjustments.
- Fixed-amount and percentage discounts with reason and audit entry.
- Cash, card and split payments. Payment parts must exactly cover the final bill.
- Daily sales report with transaction history, staff attribution and payment-method totals.
- Staff profiles and role labels (Manager, Waiter, Kitchen), plus a current-operator selector.
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

Data is stored locally through `shared_preferences`; it is suitable for a single-device/offline prototype and is not a transactional multi-terminal database. For production use across several tills, migrate to a database-backed repository (SQLite/Drift) and authenticated staff accounts with salted PIN hashes. Current staff roles are application-level UI permissions, not a security boundary. Back up device data before reinstalling or clearing app storage.