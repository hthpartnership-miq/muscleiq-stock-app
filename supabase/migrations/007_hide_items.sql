-- Remove from list: hide a Shopify stock item from the app without deleting it.
-- A hidden item stays in stock_items, so n8n keeps deducting it if the variant mapping still points at it,
-- but the app does not list it and the database raises no alerts or decisions for it.
-- Hidden items can be brought back from "Removed items" at the bottom of the Shopify stock tab.

ALTER TABLE stock_items ADD COLUMN IF NOT EXISTS hidden boolean NOT NULL DEFAULT false;

-- Alerts: skip hidden items (otherwise unchanged from 005).
CREATE OR REPLACE FUNCTION stock_items_watch() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE kind text; url text; secret text; body jsonb; req bigint; src text;
BEGIN
  IF NEW.hidden OR NEW.item_type <> 'stocked' OR NEW.current_stock >= OLD.current_stock THEN RETURN NEW; END IF;

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

CREATE OR REPLACE FUNCTION app_item_hide(p_code text, p_hidden boolean) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  UPDATE stock_items SET hidden = COALESCE(p_hidden, false),
         needs_decision = CASE WHEN COALESCE(p_hidden, false) THEN NULL ELSE needs_decision END,
         decision_since = CASE WHEN COALESCE(p_hidden, false) THEN NULL ELSE decision_since END
   WHERE item_code = p_code;
  IF NOT FOUND THEN RETURN jsonb_build_object('error', 'invalid_argument', 'message', 'Unknown item.'); END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

-- Everything the app shows, now with hidden and how many Shopify variants map to each item.
CREATE OR REPLACE FUNCTION app_read(p_known bigint DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v bigint; docs jsonb; items jsonb; cols jsonb;
BEGIN
  SELECT ver INTO v FROM app_version WHERE only_row;
  IF p_known IS NOT NULL AND p_known = v THEN RETURN jsonb_build_object('ver', v, 'same', true); END IF;
  SELECT COALESCE(jsonb_object_agg(collection, d), '{}'::jsonb) INTO docs
    FROM (SELECT collection, jsonb_object_agg(id, body) AS d FROM app_docs GROUP BY collection) t;
  SELECT COALESCE(jsonb_object_agg(s.item_code, jsonb_build_object(
           'name', s.item_name, 'stock', s.current_stock, 'threshold', s.stock_threshold,
           'alert', s.alert_on, 'updated', s.last_updated, 'type', s.item_type,
           'decision', s.needs_decision, 'decision_since', s.decision_since,
           'collection', s.collection_id, 'hidden', s.hidden,
           'mapped', (SELECT count(DISTINCT m.shopify_variant_id) FROM variant_mapping m WHERE trim(m.item_code) = s.item_code),
           'per_sale', (SELECT jsonb_build_object('min', min(q), 'max', max(q), 'most', mode() WITHIN GROUP (ORDER BY q))
                          FROM (SELECT DISTINCT shopify_variant_id, qty_deduct_per_sale AS q FROM variant_mapping m
                                 WHERE trim(m.item_code) = s.item_code) mm),
           'incoming', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', i.id, 'qty', i.qty, 'arrive', i.arrive, 'note', i.note)
                                                   ORDER BY i.arrive NULLS LAST, i.id), '[]'::jsonb)
                          FROM item_incoming i WHERE i.item_code = s.item_code AND i.status = 'due'))), '{}'::jsonb)
    INTO items FROM stock_items s;
  SELECT COALESCE(jsonb_object_agg(c.id::text, jsonb_build_object('name', c.name, 'sort', c.sort)), '{}'::jsonb)
    INTO cols FROM item_collections c WHERE NOT c.archived;
  RETURN jsonb_build_object('ver', v, 'data', docs || jsonb_build_object('items', items, 'collections', cols));
END $$;

REVOKE ALL ON FUNCTION app_item_hide(text, boolean), app_read(bigint), stock_items_watch() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION app_item_hide(text, boolean), app_read(bigint) TO service_role;
