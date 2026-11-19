# Restaurant POS

Offline-first Flutter point-of-sale application for **Android and Windows**.

## Main modules

- 20-table order management and separate kitchen order batches.
- Editable product menu, stock reservation, low-stock warnings and stock deduction at checkout.
- Cash, card and split payments with validated tender amounts and change calculation.
- Cash register shifts with opening float, cash-in/cash-out reasons, sales linked to the active shift, expected cash and closing reconciliation.
- Fixed and percentage discounts with required reason and audit history.
- Daily cash/card totals, 7-day revenue, best-selling products and transaction history.
- Single administrator account with salted PIN hash, PIN change and failed-attempt lockout.
- Azerbaijani manat (AZN) with qəpik precision and Azerbaijan UTC+4 business dates.

## Storage, migration and backups

- Primary storage is normalized SQLite tables: `products`, `pos_tables`, `order_lines`, `sales`, `sale_items`, `payments`, `register_sessions`, `cash_movements`, `staff`, `audit` and `app_meta`.
- Order lines, sale items and payments use foreign keys and explicit positions so item and transaction order survives reloads.
- State writes replace the normalized records inside one database transaction. SQLite uses WAL journaling, `synchronous=FULL` and foreign-key enforcement.
- Existing version-1 `app_state` JSON and `restaurant_pos_v2` SharedPreferences data remain readable. They are converted to normalized records on the first successful save; the old SharedPreferences key is removed only after the SQLite transaction commits.
- The database is upgraded to schema version 3 without discarding the previous JSON payload. Version 3 adds cash-register sessions and cash movements; historical sales remain valid with no assigned shift.
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


## Maliyet, gider ve stok geçmişi (SQLite şema v4)

- Ürün alış maliyeti satıştan ayrı saklanır; satış tamamlandığında birim maliyet satış satırına kopyalanır. Eski satışların bilinmeyen maliyeti sıfır kalır, geriye dönük tahmin yapılmaz.
- İşletme giderleri tarih, kategori, tutar ve açıklamayla kaydedilir. Raporlar kayıtlı satış maliyeti, brüt kâr, gider ve net kârı gösterir.
- Manuel stok giriş/çıkışları ve satıştan kaynaklanan stok düşüşleri önce/sonra miktarlarıyla kaydedilir. CSV raporu uygulama belge klasörüne yazılır.
