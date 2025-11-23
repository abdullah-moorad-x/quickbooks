QuickBill by Abdullah (Custom Project for Kissan Traders)
A Flutter desktop app for invoicing, payment tracking, and Excel/PDF exports. Built for Kissan Traders, but the code is structured so you can adapt it to any shop with small tweaks (branding, fields, export templates).

What it does
Create invoices with shipment site, cartage, and item-level summaries.
Track payments by method (cash/cheque/bank) with statuses (cleared/pending/bounced/returned).
Manage customers (add/edit/deactivate, auto-generated IDs).
Export daily/monthly sales to Excel, customer workbooks, and payment detail/summary files.
One-click re-export/repair of reports for existing data.
Desktop-friendly UI (Windows/macOS/Linux) with native window controls.
Tech stack
Flutter (Material 3), window_manager, excel, intl, open_filex.
Local JSON storage for invoices/customers/payments.
PDF/Excel builders, window-manager integration for desktop.
Project structure (high level)
lib/main.dart / lib/app.dart: app bootstrap, theme, navigation.
lib/screens/: invoice, daily/monthly reports, payments, customer master, history.
lib/services/: storage (JSON), Excel/PDF generation, paths.
lib/models/: invoice, payment, customer.
assets/: templates, fonts.
build/, dist/: generated artifacts (ignore in git).
Setup & run (dev)
flutter pub get
flutter run -d windows   # or linux/macos
Build (desktop)
flutter build windows    # adjust for macos/linux as needed
Adapting for another shop
Update branding (app title, icons, templates) in lib/app.dart and assets.
Adjust item types/shipment sites in lib/core/constants.dart.
Tweak export formatting in lib/services/excel_service.dart and PDF builder.
Change default data paths in lib/services/paths.dart if desired.
Data & storage
Invoices/customers/payments stored as JSON under the app data directory (QuickBill folder via paths.dart).
Reports/PDFs are written to subfolders like daily_sales, monthly_sales, customers, payments.
Reports & payments
Daily/Monthly sales: generated via buttons in Reports screens; re-export logic handles existing data.
Customer workbooks: per-customer Excel with yearly tabs.
Payments: cash/cheque/bank with status changes reflected in summaries and invoice balances.
