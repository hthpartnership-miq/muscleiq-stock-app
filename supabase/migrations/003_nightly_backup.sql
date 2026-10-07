-- Saves a copy of all app and stock data into app_backups every night at 02:15 UTC, keeping 30 days.
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('miq-nightly-backup', '15 2 * * *', 'select public.app_backup()');
