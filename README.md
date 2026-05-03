# QuickBill by Abdullah (Custom Project for Kissan Traders)

A Flutter desktop app for invoicing, payment tracking, and Excel/PDF exports. Built for Kissan Traders, and adaptable to other shops with minor tweaks (branding, fields, exports).

## What it does
- Create invoices with shipment site, cartage, and item-level summaries.
- Track payments (cash/cheque/bank) with statuses (cleared/pending/bounced/returned).
- Manage customers (add/edit/deactivate, auto-generated IDs).
- Export daily/monthly sales, customer workbooks, and payment detail/summary Excel files.
- One-click re-export/repair of existing reports; native window controls for desktop.

## Tech stack
- Flutter (Material 3), window_manager, excel, intl, open_filex.
- Local JSON storage; PDF/Excel builders.

## Structure
- `lib/main.dart`, `lib/app.dart`: bootstrap, theme, nav.
- `lib/screens/`: invoice, reports, payments, customer master, history.
- `lib/services/`: storage (JSON), Excel/PDF, paths.
- `lib/models/`: invoice, payment, customer.
- `assets/`: templates, fonts.

## Dev setup
flutter pub get
flutter run -d windows # or macos/linux
## Build (desktop)
flutter build windows # adjust for macos/linux

## Release (desktop installer + git push + tag push)
Use the helper script to bump version, build the installer, commit, push, and push the release tag:

```powershell
powershell -ExecutionPolicy Bypass -File tools\prepare_release.ps1 -Version 1.0.3
```

Optional:
- `-BuildNumber 4`
- `-CommitMessage "Release v1.0.3"`

After the script finishes, create a GitHub Release for the new tag and upload:
- `dist\QuickBill_By_Abdullah_Installer.exe`

## Adapting for another shop
- Update branding/title/icons/templates (`lib/app.dart`, assets).
- Adjust item types/sites (`lib/core/constants.dart`).
- Tweak exports in `lib/services/excel_service.dart` and PDF builder.
- Change data paths in `lib/services/paths.dart` if needed.

## Data & reports
- Data stored as JSON under the app data dir (QuickBill folder).
- Exports/PDFs in `daily_sales`, `monthly_sales`, `customers`, `payments`.

## Licensing/visibility
Private by default (client project). Open-source later by removing client-specific assets/names and adding a license if you wish.
