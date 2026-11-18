# Restaurant POS

Offline-first restaurant point-of-sale prototype.

## Current prototype
- 20-table dashboard with free, occupied and bill-requested states.
- Editable product menu and categories.
- Add, remove and change order quantities; move orders between tables.
- Cash/card payment recording and cash change calculation.
- Sales history, daily totals and CSV export.
- Local browser persistence and JSON backup/restore.

## Run
Open `index.html` in a modern browser. The prototype is designed for phone/tablet screens and stores data in that browser's local storage.

## Important limitations
This is an early browser prototype, not a production Android APK. Local browser storage is not a substitute for a tested database and off-device backup. Card payments are recorded only; no bank terminal or payment processor is connected. Do not use it as the sole record system for a live restaurant.

## Planned next modules
1. Kitchen order queue and preparation statuses.
2. Inventory tracking and low-stock alerts.
3. Percentage/fixed discounts with audit trail.
4. Split payments across cash and card.
5. Staff accounts, permissions and action history.

## Target production architecture
Native Android app using Kotlin, Jetpack Compose and Room/SQLite, with transactional persistence, migration tests and export/restore.
