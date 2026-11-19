# Restaurant POS

Offline-first Flutter point-of-sale application for **Android and Windows**.

## Main modules

- 20-table order management and separate kitchen order batches.
- Editable product menu, stock reservation, low-stock warnings and stock deduction at checkout.
- Cash, card and split payments with validated tender amounts and change calculation.
- Fixed and percentage discounts with required reason and audit history.
- Daily cash/card totals, 7-day revenue, best-selling products and transaction history.
- Single administrator account with salted PIN hash, PIN change and failed-attempt lockout.
- Azerbaijani manat (AZN) with qəpik precision and Azerbaijan UTC+4 business dates.

## Storage, migration and backups

- Primary storage is SQLite. State writes are committed in a database transaction.
- SQLite uses WAL journaling and `synchronous=FULL` for stronger crash durability.
- Existing `restaurant_pos_v2` SharedPreferences data is migrated automatically on first launch. The old key is removed only after the SQLite write succeeds.
- A daily JSON snapshot is written under the app documents directory in `backups/`. The seven most recent daily backups are retained.
- Corrupt legacy JSON is preserved as a separate recovery file before the app starts with safe defaults.
- Android and Windows devices keep separate local databases. This is not cloud synchronization.

## Build and test

```bash
flutter create --platforms=android,windows --project-name restaurant_pos .
flutter pub get
flutter analyze
flutter test
flutter build apk --release
```

On Windows, enable desktop support and run `flutter build windows --release`. GitHub Actions analyzes, tests and builds both platforms on every push to `main`.

## Security notes

The app is deliberately restricted to one administrator account. Staff switching and staff account creation are disabled. The administrator PIN is stored as a salted SHA-256 hash, not plaintext. This is local application-level protection, not a replacement for operating-system account security or encrypted device storage.
