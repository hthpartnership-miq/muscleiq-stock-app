# MuscleIQ Stock App

Warehouse stock app for MuscleIQ. Staff count racks, reserve and sell them, track containers coming in, and see the stock items that Shopify orders deduct from.

## How it fits together

```
Shopify order paid
      |
     n8n  "Muscle IQ Stock Automation (Database)"  ---->  Supabase (Postgres)  <----  this app on Vercel
      |                                                    the master copy            staff phones, QR codes
     n8n  "Muscle IQ Stock Automation"  -------------->  Google Sheet (overwatch copy, unchanged)
```

- **Supabase** project "MuscleIQ Stock" holds all data. It is the master copy.
- **This app** (Vercel) reads and writes Supabase through `api/db.js`.
- **n8n** takes stock off in Supabase when a Shopify order is paid.
- **GitHub** holds code only. Deploying never touches data.

## What is in this repo

| Path | What it is |
| --- | --- |
| `public/index.html` | The app: all screens and their logic |
| `public/backend.js` | Connects the app to `/api/db`, shows the passcode screen |
| `api/db.js` | Server function: checks the passcode, calls the database |
| `supabase/migrations/` | The database tables and functions, in the order they were applied |
| `supabase/RUN_ONCE_in_sql_editor.sql` | One-off script to paste into Supabase's SQL Editor (see below) |
| `n8n/` | The n8n workflow that deducts stock in the database |

## Database tables

| Table | Holds | Written by |
| --- | --- | --- |
| `stock_items` | The Shopify stock list: item code, name, count, alert level | n8n |
| `variant_mapping` | Which items each Shopify variant takes off, and how many | You, by hand (keep in step with the sheet) |
| `processed_orders` | Orders already counted, so none is counted twice | n8n |
| `stock_log` | Every deduction with stock before and after | n8n |
| `app_docs` | Rack counts, reserved/sold, containers, spare parts, history (and the retired Other stock tab's notes, kept for reference) | The app |
| `item_incoming` | Shopify stock coming in (date, quantity, note) | The app |
| `alert_outbox` | Every low-stock / below-zero alert sent | Database trigger |
| `app_backups` | A full copy taken every night at 02:15 UTC, kept 30 days | Supabase schedule |

All tables are closed to Supabase's public API. Only the app's server function and n8n can reach them.

## Setup on Vercel

1. Import this repo as a Vercel project (framework preset: Other, no build step).
2. Connect Supabase: in the Vercel project, Storage (or Integrations) > Supabase > connect the existing "MuscleIQ Stock" project. This adds `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`.
3. Add `APP_PASSCODE` under Settings > Environment Variables. Make it long; everyone with the link and passcode can change stock.
4. Redeploy so the function picks the variables up.

Until steps 2 and 3 are done the site shows "Stock storage is not set up yet".

## One-off database step

Paste `supabase/RUN_ONCE_in_sql_editor.sql` into Supabase > SQL Editor and run it. It adds the functions that save and remove entries, takes the first backup, and removes the setup-day test order. Until it has run, the app can show data but cannot save changes.

## Working on it

- Push to `main` and Vercel deploys. Other branches get their own preview address.
- Never commit passwords, keys or the passcode. They live in Vercel's environment variables.
- QR labels point at the site's own address. Reprint them if the address changes.

## Shopify stock page

Each item shows its count, any low-stock or coming-in notes, an **Open** button and a **bell**, the same as Other stock.

- **Open**: take out, put in stock, set an exact count (stock take), add stock coming in and mark it arrived, tick Pre-order, and see recent movements. The hint under the count says how many units each Shopify sale takes off, from the variant mapping.
- **Bell**: the low stock alert. Its number is `stock_items.stock_threshold`, the same alert level n8n uses. "Turn alert off" sets `alert_on` to false.
- **Below zero**: taking a stocked item below zero asks for confirmation first and then marks it pre-order.
- **Needs a decision**: when a stocked item falls to or below its alert level, or goes below zero, the database flags it (`needs_decision`) and the box at the top of the page asks to switch it to pre-order or keep it as stocked. Nothing switches by itself.

### Alerts

The check runs inside the database (trigger `stock_items_watch`), so it catches orders from n8n and changes made in the app alike. Each alert is saved in `alert_outbox` and posted to the n8n workflow "Muscle IQ Stock Alerts (Database)", which emails hthpartnership@gmail.com. The webhook address and its shared secret are in `app_settings` (not in this repo). To add WhatsApp later, add a step to that workflow.

The n8n order flow still sends its own low-stock email as well, kept for now for debugging.

App changes are not copied to the Google Sheet; update the sheet by hand if you want it to match.

## Not built yet

- Named staff logins. Everyone shares one passcode.
- Adding new item codes or mapping rows from the app (done in Supabase for now). Everyone shares one passcode, so History shows "Someone".
