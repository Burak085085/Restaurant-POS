# Restaurant-POS audit and continuation tracker

Repo: Burak085085/Restaurant-POS, target branch main. Flutter Android + Windows, offline-first SQLite, Turkish UI, manat (₼) stored as integer qəpik. Roles: Yönetici, Garson, Kasiyer, Mutfak.

## Permanent constraints
- Real-time synchronization is out of scope.
- Preserve offline SQLite and all four roles.
- Never commit PINs, keystores, signing keys, or any secret.
- Android and Windows analyze/test/build must pass before feature work proceeds.
- Ask Burak before major architecture changes, especially Y12 database-location migration.
- Every fix needs tests; verify changes on main before reporting.
- CI green is not proof that every audit item is complete.

## Baseline before batch 01
- Starting main SHA: 701a7a5694efde6c27a1884d404e39d6e5cfd49e.
- Workflow run 44964194048 passed Android analyze/test/release APK and Windows analyze/test/release build.
- K3 negative money formatting already fixed and tested.
- Y1 cash sales require an open register.
- Y2 cancellation/refund features exist; audit detail and edge tests remain.
- Y5 UTC/Baku display conversion exists; audit remaining time paths.
- Y9 PBKDF2 and persistent lockout data exist; verify every PIN path/expiry.
- K2 recovery mode exists, but recovery edge cases remain.
- K4 repository-backed manual export, manual listing, restore validation and atomic write are implemented on main.
- K1 remains incomplete: android/windows runners are generated in CI, release identity/signing/versioning unresolved.
- These are partial statuses, not blanket closure.

## Batch 01 (branch fix/audit-batch-01)
- [x] O14 strict localized money parser and validation.
- [x] O3 blind cash count and invalid amount feedback.
- [x] O12 flush pending writes on paused/detached.
- [x] O5 Turkish Material localization and register text cleanup.
- [x] Y11 atomic backup write and Baku calendar date.
- [x] Run analyze, all tests, Android APK, Windows build in Actions.
- [x] Merged to main after green CI. Final batch commit: `5a8c6178019524952c868ec53fe4c1d095f9318b`; workflow run `45013742998` passed Android + Windows.

## Batch 03 (branch feature/priority-audit-hardening) — merged to main; CI passed
- [x] K4: repository-backed manual export, atomic temporary-file rename, discoverability/readback test; restore now runs integrity validation before replacing live data.
- [x] Y2 partial: sent-line cancellation records reason, supervisor PIN, product, quantity, amount, actor and kitchen notice; existing refund flow records negative sale and cash movement with admin PIN/reason. Additional refund edge cases and stock-return audit remain open.
- [x] Y8 partial: supplier purchase writes a stock movement and weighted-average unit cost uses integer arithmetic. Ingredient stock movement ledger and full reconciliation remain open.
- [x] Y9 partial: PBKDF2 and persistent escalating PIN lockouts were already present; app background now flushes and locks the session with an audit event. Configurable inactivity timeout and cross-platform lifecycle smoke tests remain open.
- [ ] K1: release identity/signing and committed platform runners remain blocked on owner-confirmed Android application ID and user-owned keystore/GitHub Secrets. No signing secret was created or committed.
- [ ] Android and Windows CI for this batch must both pass before merge.

## Critical
- [ ] K1: commit Android/Windows runner projects; fixed applicationId; user-owned keystore through GitHub Secrets; generate key.properties in CI; increase versionCode. Never create/commit Burak's keystore.
- [ ] K2: recovery mode on corrupt DB; no writes before choice; inspect/restore; preserve admin hash; atomic load; preserve suppliers, purchases, customers, reservations, barcodes.
- [x] K3: negative money formatting fixed; keep tests for -1, -30, -99, -100, -120, -250.
- [x] K4: file backup import, manual listing, repository-backed atomic export, integrity-validated restore.
## High
- [x] Y1: open register required for cash checkout.
- [x] Y2 core: sent-line cancellation reason/elevated PIN/audit product+qty+amount/user/kitchen alert; refund with admin PIN/reason/negative sale/cash ledger/optional stock. Remaining refund edge cases and reconciliation tests stay open.
- [ ] Y3: Sale discountReason/discountPercent, schema migration, critical vs ordinary audit retention.
- [ ] Y4: differential SQLite writes, debounced backups, batch reads, paginated/date-filtered reports.
- [ ] Y5: consistent Baku/UTC timestamps, legacy conversion and timezone tests.
- [ ] Y6: precise ingredient unit costs and migration.
- [ ] Y7: ingredient stock ledger/purchasing/weighted average/waste and unambiguous costing.
- [ ] Y8: stock movement for all edits/purchases; bool upsert result; ledger continuity and sale-total integrity checks.
- [x] Y9 core: PBKDF2 PIN hashes, persistent escalating lockout for admin/staff/supervisor verification paths and audit of attempts. Remaining payment-PIN path verification and lifecycle smoke tests stay open.
- [ ] Y10: background/inactivity session lock with configurable timeout.
- [ ] Y11: atomic temp+rename; daily + hourly retention; Baku date; surfaced backup failures; last successful backup; cleanup policy.
- [ ] Y12: verify Windows sqlite3.dll and smoke test. Move DB to Application Support only after Burak's explicit approval.
- [ ] Y13: split main.dart into models/business logic/pages/storage, typed permissions, single serializer, lint/format, remove dead code.
- [ ] Y14: exact integer qəpik parsing, locale separators, invalid-input feedback.
- [ ] Y15: deduplicate CI tests, pin Flutter version, Windows icon, shorter artifact retention, VC++ README.
## Medium
- [ ] O1 stock tracking mode, sold-out label, sensible default.
- [ ] O2 backup permission/PIN recheck/admin identity protection/shared-backup PIN warning or encryption.
- [ ] O3 blind count, invalid amount feedback, warn about open tables/unpaid orders on close.
- [ ] O4 validate active/authorized staff and PIN inside checkout logic.
- [ ] O5 Turkish UI/localization and language-independent movement codes with migration.
- [ ] O6 reservation/customer table badge, seat/edit/cancel/history, sales-linked visits/spend.
- [ ] O7 order-screen barcode, optional Android camera scan, label generation/print.
- [ ] O8 kitchen FIFO/sentAt/wait time/new-order/cancel signal and meaningful table states.
- [ ] O9 line notes and dine-in/takeaway type.
- [ ] O10 edit/cancel suppliers/purchases/expenses/reservations/customers; staff PIN reset/rename; admin recovery.
- [ ] O11 WAL PRAGMA rawQuery and device verification; propose normalized ingredient/recipe tables separately.
- [ ] O12 flush pending writes on paused/detached.
- [ ] O13 modularization, typed permissions, serializer, lint, dead code.
- [ ] O14 strict localized money parser.
- [ ] O15 deduplicated CI, pinned Flutter, Windows icon, retention and runtime docs.
## Low
- [ ] PaymentDialog handles inactive/missing current user without Dropdown assertion.
- [ ] Admin login/logout audit (coordinate Y9).
- [ ] Confirmations for logout, product deactivation, discount removal.
- [ ] Live date refresh on tables.
- [ ] Simplify Staff default PIN/pinRequired.
- [ ] GitHub noreply commit email.
- [ ] Verify a6c50aa unique-PIN change against code.
- [ ] Verify Windows share_plus.
- [ ] Update README.
- [ ] Document e-kassa compliance check; POS is not a substitute.
## Required test coverage
- [ ] Negative money, date/time and week/month boundaries, discount rounding, CSV.
- [ ] Closed-register cash sale, atomic insufficient-ingredient rollback, refund, sent-line cancellation permission/reason/audit.
- [ ] Admin/staff/payment PIN lockout and persistence; staff-less backup preserves admin; role permission matrix.
- [ ] Corrupt DB recovery; FK/write fault injection; v1-v5 migrations including v2/v3 products ALTER.
- [ ] Backup retention/export/import/temp+rename.
- [ ] IntegrityCheck negative fixtures.
- [ ] PDF Turkish/Azerbaijani glyphs.
- [ ] Payment/register/table widget tests; small screens/large text; role-based home.
- [ ] Android and Windows launch/basic-flow smoke tests.

## Next chat handoff
Read this tracker first, inspect current main SHA and latest Actions run, compare each item to code/tests, and continue only with open findings. Do not ask Burak to paste the audit again. Preserve all constraints above.


## Batch 04 (branch fix/critical-recovery-audit) — merged to main
- [x] Cleanup: closed stale PR #5 as superseded by merged PR #6; no code was removed from main.
- [x] Added regression test for restore preserving supplier, purchase, customer, reservation, barcode and hashed administrator PIN data.
- [x] Android + Windows analyze/test/release builds passed before merge; PR #7 merged as `59c633c4c0310aab50dec3a8f3d3e1280ebf6412`.
- [x] Reconciled README security wording and audit tracker against current implementation.

## Batch 05 (branch fix/restore-rollback-safety) — merged to main
- [x] Make backup replacement roll back to the previous valid snapshot after a partial write, reload failure, post-restore integrity failure, or final persistence failure.
- [x] Add simulated partial-write and final-persistence failure regression tests proving previous POS data remains available.
- [x] Add Baku midnight, month-end and year-boundary conversion coverage.
- [x] Android + Windows analyze/test/release builds passed; PR #8 merged as `9069988db4ab231749e0ee4617f1af410895668c`.
- [ ] Extend malformed/partial legacy backup fixtures and verify rollback against SQLite write faults.

## Batch 06 (branch fix/stock-ledger-integrity) — covered on main; stale branch superseded
- [x] Validate stock movement direction, quantity, before/after balances, product references and cost values.
- [x] Validate continuity between consecutive product stock movements and reconcile the latest movement against current stock.
- [x] Regression coverage for malformed stock movement quantities is present on main.
- [x] Ingredient movement integrity validation and reconciliation are also present on main through the merged ingredient-ledger work (PR #16).
- [x] No separate merge required; the older branch is behind main and does not contain the newer ingredient-ledger implementation.

## Owner inputs required before release signing (K1)
- [ ] Burak must confirm the final Android application ID/package name.
- [ ] Burak must provide/create and retain ownership of the Android upload/signing keystore; credentials must be entered directly into GitHub Secrets by the owner. Never request or commit the keystore or passwords in chat/repository.
- [ ] After owner inputs, commit stable Android/Windows runner projects, configure signing in CI and set versionCode/versionName.

## Cleanup notes
- PR #5 (manual backup export) was closed on 2026-11-25 because the same implementation had already landed through merged PR #6 and is present on main.
- The project in scope is exclusively this Restaurant-POS repository. Do not switch to or perform work on any unrelated/abandoned project.


## Batch 07 (PR #18) — merged to main
- [x] Test sequential partial and final refunds, including remaining refundable amount and duplicate-refund rejection.
- [x] Verify stock is returned once, cash outflow reconciles, and refund/stock state survives reload.
- [x] Verify insufficient register cash rejects a refund without changing sales, cash movements or stock.
- [x] Android + Windows analyze/test/build passed before merge; PR #18 merged as `7e6f57f9be8ad43d705b2958a33918e1378cc595`.
- [x] Post-merge main workflow run `45715458770` is currently running; verify both platform jobs before marking main green.

## Batch 08 (PR #19) — merged to main
- [x] Reject malformed nested legacy backup records without replacing live data.
- [x] Exercise a real SQLite transaction failure during restore and verify the previous database remains loadable and passes integrity checks.
- [x] Correct rollback test to compare the restored product count with the actual `Pos()` defaults (11 products), rather than incorrectly assuming a single product.
- [x] Android + Windows analyze/test/release builds passed before merge; PR #19 squash-merged as `f8087dd6bea1dfba050003975d7f41da8da07561`.
- [x] Post-merge main workflow run `45724714225` passed Android and Windows analyze/test/release builds.


## Batch 09 (branch fix/final-release-audit-batch-09) — in progress
- [x] Confirm post-merge main workflow run `45724714225` completed successfully for Android APK and Windows desktop release builds.
- [x] Reconcile README SQLite schema version with the actual schema version 7 and document refund/ingredient-ledger evolution.
- [x] Rename the legacy migration test description so it accurately states that the v4 fixture is upgraded through schema v7.
- [ ] Add a focused v6-to-v7 migration regression test for the `order_lines.ingredient_usage` column.
- [ ] Android + Windows analyze/test/release builds must pass before merge.

## Current release gate (remaining owner input)
- [ ] Confirm final Android application ID/package name.
- [ ] Owner creates and retains the Android signing keystore; enter signing credentials directly into GitHub Secrets. Never send or commit signing material.
- [ ] Confirm whether the Windows deliverable should be a zipped portable build or installer; the CI artifact currently contains the built desktop output.

## Batch 10 (branch feature/priority-enhancements-batch-10) — in progress
- [x] Supplier purchase records now retain an optional invoice/dispatch-note reference, show it in purchase history, and preserve old records without the field.
- [x] Reservation records can link to an existing customer; completing a linked reservation increments that customer's visit count once, with the link and counted state persisted.
- [x] Extend the 30-day analytics panel with hourly revenue and per-product revenue, cost and profit after proportional discount allocation.
- [x] Add regression tests for purchase invoice persistence and weighted-average cost, once-only reservation visit accounting, and hourly/product-profit calculations.
- [x] Android and Windows analyze/test/release builds passed on PR #21 head `4be8c5947e22f768f63828ee44a988b6fd13df46` (workflow `45900305709`).
- [x] PR #21 merged to main as `e1029acdc0ce1051027a8bca73da698a59ee1c80`.
- [x] Verify post-merge main CI run `45901388025`: Android APK and Windows desktop build both passed.

## Five major feature workstreams — current implementation audit
- [x] Receipt/PDF printing entry point and 80 mm roll layout exist; verify real printer and Azerbaijani/Turkish glyph rendering during device testing.
- [x] Supplier and purchase workflows exist; invoice reference added in Batch 10.
- [x] Customer and reservation workflows exist; customer-linked reservation history and visit count added in Batch 10. Direct sales-to-customer order history and monetary loyalty balance remain open.
- [x] Advanced analytics already had a 30-day daily summary; Batch 10 adds hourly revenue and per-product profitability.
- [x] USB/Bluetooth keyboard-wedge barcode scanning, product matching, integrity checks and backup export/import exist. Camera scanning is not implemented and is not required for keyboard-wedge scanners.


## Batch 11 (branch fix/checkout-seller-authorization) — in progress
- [x] Model-level checkout now rejects unknown, inactive, and kitchen-role sellers; only active Yönetici/Garson/Kasiyer records may be attributed to a sale.
- [x] Alternate PIN-required cashier sales are re-verified inside the checkout business method, not only in the payment dialog; payment dialog excludes kitchen-role sellers and passes the PIN for model-level verification.
- [x] Regression test covers unknown/inactive/kitchen sellers, missing/wrong alternate-cashier PIN, and successful authorized cashier checkout.
- [x] Android and Windows analyze/test/release CI passed on PR #22 head `42f975edbd3b91f0cda921f7623e5425a8acf29d` (workflow `45901992718`).
- [x] PR #22 squash-merged to main as `6fb6d193a71fcbbed4d4be302dbb2e3d0e97dead`.
- [x] Verify post-merge main CI run `45904803519`: Android APK and Windows desktop builds both passed.

## Six-stage opening-readiness plan (single source of truth)
- [ ] 1. Payment and staff authorization: Batch 11 checkout seller validation is merged as `6fb6d193a71fcbbed4d4be302dbb2e3d0e97dead`; PR and post-merge main CI are green (`45904803519`). Complete the remaining full role/PIN/payment regression matrix before closing this stage.
- [x] 2. Supplier purchasing: purchase records, supplier association, invoice/dispatch reference, stock movement and weighted-average costing are implemented; retain regression coverage.
- [x] 3. Customers and reservations: customer records, customer-linked reservations, reservation history and once-only visit counting are implemented. Remaining optional enhancement: attach direct sales to customer profiles and add spend-based loyalty.
- [x] 4. Analytics: daily/30-day summaries, hourly revenue and product-level revenue/cost/profit are implemented with refund reversal coverage.
- [ ] 5. Receipt/PDF printing: code and 80 mm layout exist; run actual printer tests and verify Azerbaijani/Turkish glyphs on the target device.
- [ ] 6. Barcode and data integrity: keyboard-wedge barcode flow, product matching, backup/restore and integrity validation exist; verify with the actual USB/Bluetooth scanner and run backup/restore acceptance tests on target devices.

Do not mark stages 5 or 6 complete from CI alone: they require the owner's physical printer/scanner/device acceptance tests. Language expansion is explicitly deferred until opening-readiness stages and acceptance testing are complete.


## Batch 12 (PR #23, branch feat/printer-barcode-acceptance) — merged to main
- [x] Bundle Noto Sans under the SIL Open Font License so receipt PDFs can render Turkish and Azerbaijani glyphs without downloading fonts at first print; include the license file.
- [x] Refactor receipt generation into a testable PDF builder; use the bundled font for all receipt text and return the actual print-dialog result instead of reporting success when printing is cancelled.
- [x] Add regression coverage for a PDF containing Turkish/Azerbaijani product text and for barcode assignment persistence after save/reload.
- [x] Android and Windows analyze/test/build passed on final PR head `95a3ddd3b300c9281a663dea8a6cbe894a200535` (workflow `45906281698`). Earlier failures were fixed: redundant import removed; Flutter test binding initialized; arbitrary PDF size threshold replaced with PDF signature/font-embedding assertions.
- [x] PR #23 squash-merged to main as `288cb0b7e1f231a398d25974e0c1f4c742563d56`.
- [x] Verify post-merge main CI run `45907013884`: Android APK and Windows desktop builds both passed.
- [ ] Physical acceptance still required: print from the target Android/Windows device to the actual 80 mm printer, verify paper width/cut/feed and the glyphs (ə, ı, İ, ş, ğ, ç, ö, ü, Ə); test the real USB/Bluetooth scanner with the actual barcode labels.

## Current verified continuation state (2026-11-27)
- PR #21 post-merge main workflow `45901388025`: Android and Windows both passed.
- PR #22 post-merge main workflow `45904803519`: Android APK and Windows desktop builds both passed.
- PR #23 final PR workflow `45906281698`: Android and Windows analyze/test/build both passed.
- PR #23 merged to main as `288cb0b7e1f231a398d25974e0c1f4c742563d56`.
- PR #23 post-merge main workflow `45907013884`: Android APK and Windows desktop builds both passed.
- Current main SHA: `288cb0b7e1f231a398d25974e0c1f4c742563d56`.
- Batch 12 software implementation and CI are complete. Physical printer/scanner acceptance remains open and must not be inferred from CI.
- Next work: continue opening-readiness audit from the remaining High items, starting with Y3 discount/audit retention and Y5 timezone consistency. Keep K1 signing blocked until owner confirms package ID and manages their own keystore; do not change DB location for Y12 without explicit approval.


## Batch 13 (branch fix/opening-readiness-batch-13) — prepared, NOT yet CI-verified
Base: main `b971969`. Prepared offline without a Flutter SDK; must pass Android + Windows CI before merge.
- [x] K5 (new, critical): record ids came from `DateTime.now().microsecondsSinceEpoch` inside loops. A multi-product checkout or stock-returning refund creates several `stock_movements` rows in the same clock tick; Windows clock resolution is coarse, so ids can repeat, the SQLite `PRIMARY KEY` insert fails, the whole save rolls back and the app enters "Kayıt başarısız" lockdown. Added `Pos.nextRecordId()` (strictly increasing, seeded from loaded records) for stock/ingredient/cash movements, register sessions, expenses and kitchen notices. No schema change.
- [x] Y3 audit retention: the 2000-row cap deleted the oldest rows regardless of type. Now only ordinary operational rows are capped at 2000; financial/stock/staff/security actions (Ödeme, İndirim*, Satış iadesi, Kasa*, Gider, alımlar, Stok, Menü, Reçete, Barkod, Personel, Güvenlik, Giriş, Yedek geri yüklendi, Gönderilmiş ürün iptali) are never trimmed. No schema change.
- [x] Tests: `test/opening_readiness_test.dart` (monotonic ids, ids above loaded records, 6-product SQLite checkout reload, audit cap/critical retention, SQLite reload + backup restore retention).
- [ ] Android + Windows analyze/test/release CI on the batch branch, merge, post-merge main CI.

## Open findings from the 2026-11-28 audit (not fixed in Batch 13)
- [ ] R1 (high): `refundSale` always books a cash outflow (`Çıxış`) and requires an open register, even when the original sale was paid by card. Card refunds therefore reduce expected drawer cash. Needs owner decision: refund method follows original payment split.
- [ ] R2 (high): refund payment parts use method `İade`, so daily/staff/analytics Nakit/Kart totals ignore refunds and are overstated. Fix together with R1.
- [ ] R3 (medium): a wrong supervisor PIN records a failure for every eligible supervisor (Admin + all cashiers). Five wrong cancellation PIN entries by anyone lock Admin and all cashiers out (30 s → 60 s → 5 min). Consider a single shared supervisor lock scope.
- [ ] R4 (medium): reports offer "today", "last 7 days" and "30 days" only; calendar week (Mon–Sun) and calendar month/year reports in Baku time are missing.
- [ ] R5 (medium): `setReservationStatus` lets a cancelled/completed reservation return to `Bekliyor` without re-running the overlap check.
- [ ] Y4 (performance, growing): every save deletes and re-inserts all sales, items, payments, movements and audit rows. Fine at opening volume; will slow down over months. Needs differential writes (no schema change required) before the database grows large.
- [ ] Customer sales history / spend total: not implemented (sales are not linked to customers).
- [ ] K1: platform runners are generated in CI; for local installs a stable applicationId and owner-held signing key are needed so APK updates install over the previous version without data loss. Debug-signed CI APKs from different runners may refuse to update in place.
- [ ] Physical acceptance (printer 80 mm, glyphs, USB/Bluetooth scanner, Android/Windows device smoke tests) still pending — never inferred from CI.
