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
| `app_docs` | Rack counts, reserved/sold, containers, other stock, spare parts, history | The app |
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

Tap an item to:
- **Delivery in**: add stock that arrived (note the container or supplier).
- **Stock take**: set the counted number.
- **Take out**: remove stock for damage, samples or sales outside Shopify.
- **Pre-order**: mark items you don't keep in stock. Their minus number shows as "owed to customers" and they never count as low stock.

Every change is written to `stock_log` with the note, alongside the n8n order deductions, and shows under "Recent movements". These changes are not copied to the Google Sheet; update the sheet by hand if you want it to match.

## Not built yet

- Named staff logins. Everyone shares one passcode.
- Adding new item codes or mapping rows from the app (done in Supabase for now). Everyone shares one passcode, so History shows "Someone".
