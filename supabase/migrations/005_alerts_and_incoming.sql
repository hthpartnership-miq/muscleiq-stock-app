-- Shopify stock: low-stock alerts, "needs a decision" flags, stock coming in, and the units hint.
--
-- Alerts are decided here in the database, so they fire the same way whether stock went down
-- because of a Shopify order (n8n) or a change made in the app. Each alert is written to
-- alert_outbox and posted to an n8n webhook, which sends the email.
-- The webhook address and its shared secret live in app_settings (set them outside git):
--   INSERT INTO app_settings VALUES ('alert_webhook_url', 'https://.../webhook/...'), ('alert_webhook_secret', '...')
--   ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;

CREATE EXTENSION IF NOT EXISTS pg_net;

ALTER TABLE stock_items ADD COLUMN IF NOT EXISTS alert_on boolean NOT NULL DEFAULT true;
ALTER TABLE stock_items ADD COLUMN IF NOT EXISTS needs_decision text;          -- null, 'low' or 'zero'
ALTER TABLE stock_items ADD COLUMN IF NOT EXISTS decision_since timestamptz;

CREATE TABLE IF NOT EXISTS app_settings (
  key   text PRIMARY KEY,
  value text NOT NULL
);

CREATE TABLE IF NOT EXISTS item_incoming (
  id         bigserial PRIMARY KEY,
  item_code  text NOT NULL,
  qty        integer NOT NULL CHECK (qty > 0),
  arrive     date,
  note       text,
  status     text NOT NULL DEFAULT 'due',      -- 'due', 'arrived' or 'removed'
  created_at timestamptz NOT NULL DEFAULT now(),
  closed_at  timestamptz
);
CREATE INDEX IF NOT EXISTS item_incoming_due_idx ON item_incoming (item_code) WHERE status = 'due';

CREATE TABLE IF NOT EXISTS alert_outbox (
  id         bigserial PRIMARY KEY,
  created_at timestamptz NOT NULL DEFAULT now(),
  kind       text NOT NULL,                     -- 'low' or 'zero'
  item_code  text NOT NULL,
  payload    jsonb NOT NULL,
  request_id bigint                             -- pg_net request id, null if no webhook is set
);

ALTER TABLE app_settings  ENABLE ROW LEVEL SECURITY;
ALTER TABLE item_incoming ENABLE ROW LEVEL SECURITY;
ALTER TABLE alert_outbox  ENABLE ROW LEVEL SECURITY;

-- Watches every stock change on stocked items (pre-order items are left alone):
--   * falls to or below its alert level  -> needs_decision = 'low'
--   * goes from 0 or more to below zero  -> needs_decision = 'zero'
-- Then records the alert and posts it to the n8n webhook.
CREATE OR REPLACE FUNCTION stock_items_watch() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE kind text; url text; secret text; body jsonb; req bigint; src text;
BEGIN
  IF NEW.item_type <> 'stocked' OR NEW.current_stock >= OLD.current_stock THEN RETURN NEW; END IF;

  IF OLD.current_stock >= 0 AND NEW.current_stock < 0 THEN kind := 'zero';
  ELSIF NEW.alert_on AND OLD.current_stock > NEW.stock_threshold AND NEW.current_stock <= NEW.stock_threshold THEN kind := 'low';
  END IF;
  IF kind IS NULL THEN RETURN NEW; END IF;

  NEW.needs_decision := kind;
  NEW.decision_since := now();

  src := COALESCE(NULLIF(current_setting('miq.source', true), ''), 'order');
  body := jsonb_build_object(
    'kind', kind, 'source', src,
    'item_code', NEW.item_code, 'item_name', NEW.item_name,
    'stock_before', OLD.current_stock, 'stock_after', NEW.current_stock,
    'threshold', NEW.stock_threshold, 'alert_on', NEW.alert_on, 'at', now());

  SELECT value INTO url FROM app_settings WHERE key = 'alert_webhook_url';
  SELECT value INTO secret FROM app_settings WHERE key = 'alert_webhook_secret';
  IF url IS NOT NULL AND to_regproc('net.http_post') IS NOT NULL THEN
    BEGIN
      EXECUTE 'SELECT net.http_post(url := $1, body := $2, headers := $3)'
        INTO req USING url, body, jsonb_build_object('content-type', 'application/json', 'x-miq-secret', COALESCE(secret, ''));
    EXCEPTION WHEN OTHERS THEN req := NULL;  -- never block a stock update because an alert could not be sent
    END;
  END IF;
  INSERT INTO alert_outbox (kind, item_code, payload, request_id) VALUES (kind, NEW.item_code, body, req);
  RETURN NEW;
END $$;

CREATE OR REPLACE TRIGGER stock_items_watch BEFORE UPDATE OF current_stock ON stock_items
  FOR EACH ROW EXECUTE FUNCTION stock_items_watch();

-- Everything the app shows. Items now carry alert settings, the decision flag,
-- what orders take off per sale (for the units hint) and stock coming in.
CREATE OR REPLACE FUNCTION app_read(p_known bigint DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v bigint; docs jsonb; items jsonb;
BEGIN
  SELECT ver INTO v FROM app_version WHERE only_row;
  IF p_known IS NOT NULL AND p_known = v THEN RETURN jsonb_build_object('ver', v, 'same', true); END IF;
  SELECT COALESCE(jsonb_object_agg(collection, d), '{}'::jsonb) INTO docs
    FROM (SELECT collection, jsonb_object_agg(id, body) AS d FROM app_docs GROUP BY collection) t;
  SELECT COALESCE(jsonb_object_agg(s.item_code, jsonb_build_object(
           'name', s.item_name, 'stock', s.current_stock, 'threshold', s.stock_threshold,
           'alert', s.alert_on, 'updated', s.last_updated, 'type', s.item_type,
           'decision', s.needs_decision, 'decision_since', s.decision_since,
           'per_sale', (SELECT jsonb_build_object('min', min(q), 'max', max(q), 'most', mode() WITHIN GROUP (ORDER BY q))
                          FROM (SELECT DISTINCT shopify_variant_id, qty_deduct_per_sale AS q FROM variant_mapping m
                                 WHERE trim(m.item_code) = s.item_code) mm),
           'incoming', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', i.id, 'qty', i.qty, 'arrive', i.arrive, 'note', i.note)
                                                   ORDER BY i.arrive NULLS LAST, i.id), '[]'::jsonb)
                          FROM item_incoming i WHERE i.item_code = s.item_code AND i.status = 'due'))), '{}'::jsonb)
    INTO items FROM stock_items s;
  RETURN jsonb_build_object('ver', v, 'data', docs || jsonb_build_object('items', items));
END $$;

-- A stock change made by staff in the app: 'in', 'out' or 'count'.
-- p_preorder = true is sent after staff confirm the "goes below zero" warning:
-- the item is switched to pre-order in the same step, so no decision flag is raised.
CREATE OR REPLACE FUNCTION app_item_change(p_code text, p_kind text, p_qty integer, p_note text DEFAULT NULL, p_preorder boolean DEFAULT false) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE before integer; after integer; typ text; label text;
BEGIN
  IF p_kind NOT IN ('in','out','count') THEN
    RETURN jsonb_build_object('error', 'invalid_argument', 'message', 'Unknown movement.'); END IF;
  IF p_qty IS NULL OR p_qty < 0 OR p_qty > 100000 OR (p_kind <> 'count' AND p_qty = 0) THEN
    RETURN jsonb_build_object('error', 'invalid_argument', 'message', 'Enter a whole number, 1 or more.'); END IF;

  SELECT current_stock, item_type INTO before, typ FROM stock_items WHERE item_code = p_code FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('error', 'invalid_argument', 'message', 'Unknown item.'); END IF;

  after := CASE p_kind WHEN 'in' THEN before + p_qty WHEN 'out' THEN before - p_qty ELSE p_qty END;
  IF after = before THEN RETURN jsonb_build_object('ok', true, 'stock', after, 'unchanged', true); END IF;
  IF typ = 'stocked' AND after < 0 AND NOT p_preorder THEN
    RETURN jsonb_build_object('error', 'needs_preorder', 'message', 'This takes the item below zero. Confirm to mark it as pre-order.', 'stock', before, 'after', after);
  END IF;

  PERFORM set_config('miq.source', 'app', true);
  label := CASE p_kind WHEN 'in' THEN 'Put in stock' WHEN 'out' THEN 'Taken out' ELSE 'Stock take' END;
  IF typ = 'stocked' AND after < 0 THEN
    -- switch to pre-order first, so the watch trigger sees a pre-order item and stays quiet
    UPDATE stock_items SET item_type = 'pre-order', needs_decision = NULL, decision_since = NULL WHERE item_code = p_code;
  END IF;
  UPDATE stock_items SET current_stock = after, last_updated = now() WHERE item_code = p_code;
  INSERT INTO stock_log (order_name, item_code, deduct_qty, stock_before, stock_after, kind, note)
    VALUES (label, p_code, before - after, before, after, p_kind, NULLIF(left(btrim(COALESCE(p_note, '')), 120), ''));
  RETURN jsonb_build_object('ok', true, 'stock', after, 'preorder', typ = 'stocked' AND after < 0);
END $$;

-- The bell: set the alert level, or turn the alert off.
CREATE OR REPLACE FUNCTION app_item_alert(p_code text, p_on boolean, p_threshold integer DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_on AND (p_threshold IS NULL OR p_threshold < 0 OR p_threshold > 100000) THEN
    RETURN jsonb_build_object('error', 'invalid_argument', 'message', 'Type the stock number to be warned at, 0 or more.'); END IF;
  UPDATE stock_items SET alert_on = p_on, stock_threshold = CASE WHEN p_on THEN p_threshold ELSE stock_threshold END
    WHERE item_code = p_code;
  IF NOT FOUND THEN RETURN jsonb_build_object('error', 'invalid_argument', 'message', 'Unknown item.'); END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

-- The "Needs a decision" box: switch to pre-order, or keep the item as stocked.
CREATE OR REPLACE FUNCTION app_item_decide(p_code text, p_choice text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_choice NOT IN ('pre-order','keep') THEN
    RETURN jsonb_build_object('error', 'invalid_argument', 'message', 'Unknown choice.'); END IF;
  UPDATE stock_items SET needs_decision = NULL, decision_since = NULL,
         item_type = CASE WHEN p_choice = 'pre-order' THEN 'pre-order' ELSE item_type END
    WHERE item_code = p_code;
  IF NOT FOUND THEN RETURN jsonb_build_object('error', 'invalid_argument', 'message', 'Unknown item.'); END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

-- Pre-order tick box. Ticking it also clears any open decision.
CREATE OR REPLACE FUNCTION app_item_type(p_code text, p_type text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_type NOT IN ('stocked','pre-order') THEN
    RETURN jsonb_build_object('error', 'invalid_argument', 'message', 'Unknown type.'); END IF;
  UPDATE stock_items SET item_type = p_type,
         needs_decision = CASE WHEN p_type = 'pre-order' THEN NULL ELSE needs_decision END,
         decision_since = CASE WHEN p_type = 'pre-order' THEN NULL ELSE decision_since END
    WHERE item_code = p_code;
  IF NOT FOUND THEN RETURN jsonb_build_object('error', 'invalid_argument', 'message', 'Unknown item.'); END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

-- Stock coming in: add, mark arrived (adds it to stock), or remove.
CREATE OR REPLACE FUNCTION app_incoming(p_action text, p_code text, p_id bigint DEFAULT NULL, p_qty integer DEFAULT NULL, p_arrive date DEFAULT NULL, p_note text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r item_incoming; res jsonb;
BEGIN
  IF p_action = 'add' THEN
    IF p_qty IS NULL OR p_qty < 1 OR p_qty > 100000 THEN
      RETURN jsonb_build_object('error', 'invalid_argument', 'message', 'Enter how many are coming in, 1 or more.'); END IF;
    PERFORM 1 FROM stock_items WHERE item_code = p_code;
    IF NOT FOUND THEN RETURN jsonb_build_object('error', 'invalid_argument', 'message', 'Unknown item.'); END IF;
    INSERT INTO item_incoming (item_code, qty, arrive, note) VALUES (p_code, p_qty, p_arrive, NULLIF(left(btrim(COALESCE(p_note, '')), 120), ''));
    PERFORM app_bump();
    RETURN jsonb_build_object('ok', true);
  END IF;

  SELECT * INTO r FROM item_incoming WHERE id = p_id AND item_code = p_code AND status = 'due' FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('error', 'invalid_argument', 'message', 'That delivery is no longer listed.'); END IF;

  IF p_action = 'arrived' THEN
    UPDATE item_incoming SET status = 'arrived', closed_at = now() WHERE id = r.id;
    res := app_item_change(p_code, 'in', r.qty, 'Arrived' || CASE WHEN r.note IS NOT NULL THEN ': ' || r.note ELSE '' END, false);
    RETURN res;
  ELSIF p_action = 'remove' THEN
    UPDATE item_incoming SET status = 'removed', closed_at = now() WHERE id = r.id;
    PERFORM app_bump();
    RETURN jsonb_build_object('ok', true);
  END IF;
  RETURN jsonb_build_object('error', 'invalid_argument', 'message', 'Unknown action.');
END $$;

REVOKE ALL ON FUNCTION stock_items_watch(), app_read(bigint), app_item_change(text, text, integer, text, boolean),
  app_item_alert(text, boolean, integer), app_item_decide(text, text), app_item_type(text, text),
  app_incoming(text, text, bigint, integer, date, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION app_read(bigint), app_item_change(text, text, integer, text, boolean),
  app_item_alert(text, boolean, integer), app_item_decide(text, text), app_item_type(text, text),
  app_incoming(text, text, bigint, integer, date, text) TO service_role;
