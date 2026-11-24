# Restaurant POS

Offline-first Flutter point-of-sale application for **Android and Windows**.

## Main modules

- 20-table order management and separate kitchen order batches.
- Editable product menu, stock reservation, low-stock warnings and stock deduction at checkout.
- Cash, card and split payments with validated tender amounts and change calculation.
- Cash register shifts with opening float, cash-in/cash-out reasons, sales linked to the active shift, expected cash and closing reconciliation.
- Fixed and percentage discounts with required reason and audit history.
- Refunds (administrator PIN, reason, open register required) and cancellation of already-sent kitchen lines (reason and supervisor PIN, kitchen is notified).
- Daily cash/card totals, 7-day revenue, best-selling products and transaction history.
- Administrator access protected by a salted PIN hash, PIN changes and failed-attempt lockout.
- Staff roster with role-based permissions: waiters can enter without a PIN and manage orders, cashiers use PIN sign-in for orders and register operations, and kitchen staff use PIN sign-in for kitchen status updates.
- Azerbaijani manat (AZN) with qəpik precision and Azerbaijan UTC+4 business dates.

## Storage, migration and backups

- Primary storage is normalized SQLite tables: `products`, `pos_tables`, `order_lines`, `sales`, `sale_items`, `payments`, `register_sessions`, `cash_movements`, `staff`, `expenses`, `stock_movements`, `audit` and `app_meta`.
- Values without their own table are stored as JSON in `app_meta`: ingredients, recipes, advanced records (suppliers, purchases, customers, reservations, barcodes), PIN lockout state, kitchen cancellation notices, the timestamp format version and the extra sale fields (refund link, refund reason, stock-returned flag, ingredient usage).
- Order lines, sale items and payments use foreign keys and explicit positions so item and transaction order survives reloads.
- State writes replace the normalized records inside one database transaction. SQLite uses WAL journaling, `synchronous=FULL` and foreign-key enforcement.
- Existing version-1 `app_state` JSON and `restaurant_pos_v2` SharedPreferences data remain readable. They are converted to normalized records on the first successful save; the old SharedPreferences key is removed only after the SQLite transaction commits.
- The database uses schema version 5. Version 3 adds cash-register sessions and cash movements; version 4 adds product cost, sale-item cost snapshots, expenses and stock movement history; version 5 adds the discount reason and percentage flag to sales. Historical sales remain valid with no assigned shift.
- A daily JSON snapshot is written under the app documents directory in `backups/` (temporary file, then rename). The seven most recent daily backups are retained.
- If stored data cannot be read, the corrupt payload is preserved as a separate recovery file and the app enters a read-only recovery mode: nothing is replaced with default data and nothing is saved until a valid backup is restored.
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

The administrator PIN and PIN-protected cashier/kitchen staff credentials are stored as salted PBKDF2-HMAC-SHA256 hashes (120,000 iterations), not plaintext; older SHA-256 hashes are upgraded after the next successful login. Waiters use PIN-free sign-in and can enter orders only; cashiers can enter orders and use the cash register; kitchen staff can update kitchen order states only. Staff can sign in only with a supported, active role. Administrator-only operations remain unavailable to staff. This is local application-level protection, not a replacement for operating-system account security or encrypted device storage.

Backup files contain the PIN hashes and the full sales history. A 4-digit PIN can be brute-forced offline from a hash, so treat exported backups as confidential.

Local databases, backups and CSV exports are listed in `.gitignore` and must never be committed.


## Maliyet, gider ve stok geçmişi (SQLite şema v4)

- Ürün alış maliyeti satıştan ayrı saklanır; satış tamamlandığında birim maliyet satış satırına kopyalanır. Eski satışların bilinmeyen maliyeti sıfır kalır, geriye dönük tahmin yapılmaz.
- İşletme giderleri tarih, kategori, tutar ve açıklamayla kaydedilir. Raporlar kayıtlı satış maliyeti, brüt kâr, gider ve net kârı gösterir.
- Manuel stok giriş/çıkışları ve satıştan kaynaklanan stok düşüşleri önce/sonra miktarlarıyla kaydedilir. CSV raporu uygulama belge klasörüne yazılır.
