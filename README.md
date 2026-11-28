# Restaurant POS

Offline-first Flutter point-of-sale application for **Android and Windows**.

## Main modules

- 20-table order management and separate kitchen order batches.
- Editable product menu, stock reservation, low-stock warnings and stock deduction at checkout.
- Cash, card and split payments with validated tender amounts and change calculation.
- Cash register shifts with opening float, cash-in/cash-out reasons, sales linked to the active shift, expected cash and closing reconciliation.
- Fixed and percentage discounts with required reason and audit history.
- Daily cash/card totals, 7-day revenue, best-selling products and transaction history.
- Administrator access protected by a salted PIN hash, PIN changes and failed-attempt lockout.
- Staff roster with role-based permissions: waiters can enter without a PIN and manage orders, cashiers use PIN sign-in for orders and register operations, and kitchen staff use PIN sign-in for kitchen status updates.
- Azerbaijani manat (AZN) with qəpik precision and Azerbaijan UTC+4 business dates.

## Storage, migration and backups

- Primary storage is normalized SQLite tables: `products`, `pos_tables`, `order_lines`, `sales`, `sale_items`, `payments`, `register_sessions`, `cash_movements`, `staff`, `expenses`, `stock_movements`, `audit` and `app_meta`. Ingredient and recipe definitions are stored as JSON values in `app_meta`.
- Order lines, sale items and payments use foreign keys and explicit positions so item and transaction order survives reloads.
- State writes replace the normalized records inside one database transaction. SQLite uses WAL journaling, `synchronous=FULL` and foreign-key enforcement.
- Existing version-1 `app_state` JSON and `restaurant_pos_v2` SharedPreferences data remain readable. They are converted to normalized records on the first successful save; the old SharedPreferences key is removed only after the SQLite transaction commits.
- The database uses schema version 7. Version 5 preserves discount reason and percentage on completed sales; version 6 adds refund audit and stock-return fields; version 7 adds ingredient-usage snapshots to order lines. Older databases are upgraded sequentially. Version 3 adds cash-register sessions and cash movements; version 4 adds product cost, sale-item cost snapshots, expenses and product stock movement history. Ingredient stock movements, recipe snapshots and weighted-average ingredient costing are also persisted. Historical sales remain valid with no assigned shift.
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

The administrator PIN and PIN-protected cashier/kitchen staff credentials are stored using salted PBKDF2-HMAC-SHA256 hashes (120,000 iterations), not plaintext. Legacy salted SHA-256 hashes are upgraded to PBKDF2 after successful verification. Waiters use PIN-free sign-in and can enter orders only; cashiers can enter orders and use the cash register; kitchen staff can update kitchen order states only. Staff can sign in only with a supported, active role. Administrator-only operations remain unavailable to staff. This is local application-level protection, not a replacement for operating-system account security or encrypted device storage.


## Maliyet, gider ve stok geçmişi

- Ürün alış maliyeti satıştan ayrı saklanır; satış tamamlandığında birim maliyet satış satırına kopyalanır. Eski satışların bilinmeyen maliyeti sıfır kalır, geriye dönük tahmin yapılmaz.
- İşletme giderleri tarih, kategori, tutar ve açıklamayla kaydedilir. Raporlar kayıtlı satış maliyeti, brüt kâr, gider ve net kârı gösterir.
- Manuel stok giriş/çıkışları ve satıştan kaynaklanan stok düşüşleri önce/sonra miktarlarıyla kaydedilir. CSV raporu uygulama belge klasörüne yazılır.

## İade ve raporlar

- İade, orijinal ödeme yöntemine göre yapılır: önce nakit kısmı (kasadan nakit çıkışı, açık kasa gerekir), sonra kart kısmı (karta iade, kasaya dokunmaz). İade ödemeleri negatif Nakit/Kart satırı olarak saklanır; günlük, personel ve analiz Nakit/Kart toplamları iadeleri düşer. Eski `İade` kayıtları nakit iade sayılır.
- Gelişmiş analiz ekranında Bugün, Bu hafta (Pazartesi–Pazar), Bu ay, Bu yıl ve Son 30 gün dönemleri Bakü (UTC+4) iş tarihine göre hesaplanır.
- Denetim kayıtlarında yalnızca sıradan işlemler 2000 kayıtla sınırlıdır; ödeme, indirim, iade, kasa, gider, stok, personel ve güvenlik kayıtları silinmez.

## Restoranda yerel kurulum (mağaza yok)

- **Android:** GitHub Actions çalışmasının "Artifacts" bölümünden `restaurant-pos-android-apk` indirilir, ZIP içindeki `app-release.apk` cihaza kopyalanıp "bilinmeyen kaynaklardan yükleme" izniyle kurulur. Her CI çalışması daha büyük bir sürüm kodu (versionCode) üretir.
- **Windows:** `restaurant-pos-windows` ZIP'i bir klasöre (ör. `C:\RestaurantPOS`) açılır ve `restaurant_pos.exe` çalıştırılır. Çalışmazsa Microsoft Visual C++ Redistributable (x64) kurulmalıdır. Veriler Belgeler klasöründeki `restaurant_pos.sqlite3` dosyasındadır; güncellemede yalnızca program klasörü değiştirilir.
- **Android imzası:** Güncellemenin eski sürümün üzerine (veri kaybı olmadan) kurulabilmesi için tüm APK'lar aynı anahtarla imzalanmalıdır. Sahip bir kez şu adımları yapar; anahtar ve parolalar asla depoya veya sohbete konmaz:
  1. `keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 -validity 10000 -alias restaurantpos`
  2. Dosyayı güvenli yerde (iki kopya) saklayın; base64'e çevirin: Windows PowerShell'de `[Convert]::ToBase64String([IO.File]::ReadAllBytes("upload-keystore.jks"))`.
  3. GitHub → Settings → Secrets and variables → Actions: `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` (`restaurantpos`), `ANDROID_KEY_PASSWORD`.
  Secret'lar yoksa APK geçici hata ayıklama anahtarıyla imzalanır; böyle bir APK'dan imzalı sürüme geçişte uygulama bir kez kaldırılmalıdır. Bu yüzden önce yedek alın, sonra yedeği geri yükleyin.
