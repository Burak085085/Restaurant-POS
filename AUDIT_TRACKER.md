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
- K4 file import/manual listing exist; export still needs repository-backed safe writing.
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

## Batch 03 (branch feature/priority-audit-hardening) — implementation in review
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
- [ ] K4: file backup import, manual listing, repository-backed export, validate restore.
## High
- [x] Y1: open register required for cash checkout.
- [ ] Y2: sent-line cancellation reason/elevated PIN/audit product+qty+amount/user/kitchen alert; refund with admin PIN/reason/negative sale/cash ledger/optional stock.
- [ ] Y3: Sale discountReason/discountPercent, schema migration, critical vs ordinary audit retention.
- [ ] Y4: differential SQLite writes, debounced backups, batch reads, paginated/date-filtered reports.
- [ ] Y5: consistent Baku/UTC timestamps, legacy conversion and timezone tests.
- [ ] Y6: precise ingredient unit costs and migration.
- [ ] Y7: ingredient stock ledger/purchasing/weighted average/waste and unambiguous costing.
- [ ] Y8: stock movement for all edits/purchases; bool upsert result; ledger continuity and sale-total integrity checks.
- [ ] Y9: persistent escalating lockout on every PIN path; PBKDF2; audit login/logout/failures.
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
