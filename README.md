# Restaurant POS

A mobile-friendly, browser-based restaurant POS prototype in Turkish.

## Included in this prototype
- 20-table dashboard with free, occupied and bill-requested states.
- Menu categories and predefined products, with prices stored as integer qəpik.
- Add products, change quantities, remove lines and replace selected quantities with another product.
- Cash collection keypad with short-payment validation and change calculation.
- Completed cash sales are stored in the browser's local storage.
- Open table orders are saved to browser local storage after UI actions.
- Local calendar date is used for the daily sales figure.

## Run
Open `index.html` in a modern browser on a phone, tablet or computer.

## Important limitations
- This is a browser prototype, not a native Android APK.
- Data is stored only in the current browser profile on the current device. Clearing browser data, using another browser/device, or device failure can cause data loss. There is no backup/restore or cloud synchronization in this version.
- Sales are recorded internally, but this version does not yet include a sales-history or reports screen.
- Only cash payment is implemented. Card processing, split payments and bank-terminal integration are not implemented.
- Menu items are currently defined in source code; there is no menu editor.
- Kitchen queue, inventory, discounts, staff accounts, permissions, audit log, receipt printing and production-grade database recovery are not implemented.

## Planned next modules
1. Kitchen order queue and preparation statuses.
2. Inventory tracking and low-stock alerts.
3. Percentage/fixed discounts with audit trail.
4. Split payments across cash and card.
5. Staff accounts, permissions and action history.

## Target production architecture
Native Android app using Kotlin, Jetpack Compose and Room/SQLite, with transactional persistence, migration tests and reliable export/restore.
