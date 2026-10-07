-- MuscleIQ stock database: tables that mirror the four tabs of the "MIQ Stock Automation" sheet.
-- Works on any Postgres (Supabase or Neon). Run once in the SQL editor.

CREATE TABLE IF NOT EXISTS stock_items (
  item_code       text PRIMARY KEY,
  item_name       text NOT NULL DEFAULT '',
  current_stock   integer NOT NULL DEFAULT 0,
  stock_threshold integer NOT NULL DEFAULT 0,
  last_updated    timestamptz
);

-- No link to stock_items on purpose: same as the sheet, a mapping row whose
-- item code is not in the stock list is simply skipped when an order comes in.
CREATE TABLE IF NOT EXISTS variant_mapping (
  id                  bigserial PRIMARY KEY,
  shopify_variant_id  text NOT NULL,
  shopify_sku         text,
  item_code           text NOT NULL,
  qty_deduct_per_sale integer NOT NULL DEFAULT 1
);
CREATE INDEX IF NOT EXISTS variant_mapping_variant_idx ON variant_mapping (shopify_variant_id);

CREATE TABLE IF NOT EXISTS processed_orders (
  shopify_order_id text PRIMARY KEY,          -- the primary key is what stops an order being counted twice
  order_name       text,
  processed_at     timestamptz NOT NULL DEFAULT now(),
  status           text NOT NULL
);

CREATE TABLE IF NOT EXISTS stock_log (
  id           bigserial PRIMARY KEY,
  "time"       timestamptz NOT NULL DEFAULT now(),
  order_id     text,
  order_name   text,
  variant_id   text,
  sku          text,
  item_code    text NOT NULL,
  sold_qty     integer,
  deduct_qty   integer NOT NULL,
  stock_before integer NOT NULL,
  stock_after  integer NOT NULL
);
CREATE INDEX IF NOT EXISTS stock_log_item_idx ON stock_log (item_code, "time" DESC);

-- Supabase publishes tables in the public schema through its web API.
-- Row level security with no policies keeps them closed to that API;
-- n8n and the app connect with the database password and are not affected.
ALTER TABLE stock_items      ENABLE ROW LEVEL SECURITY;
ALTER TABLE variant_mapping  ENABLE ROW LEVEL SECURITY;
ALTER TABLE processed_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE stock_log        ENABLE ROW LEVEL SECURITY;
