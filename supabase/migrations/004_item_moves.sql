-- Stock in, stock takes and pre-order marking for the Shopify stock items, from the app.

ALTER TABLE stock_items ADD COLUMN IF NOT EXISTS item_type text NOT NULL DEFAULT 'stocked';
ALTER TABLE stock_log   ADD COLUMN IF NOT EXISTS kind text NOT NULL DEFAULT 'order';
ALTER TABLE stock_log   ADD COLUMN IF NOT EXISTS note text;

-- Everything the app shows (now including each item's type).
CREATE OR REPLACE FUNCTION app_read(p_known bigint DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v bigint; docs jsonb; items jsonb;
BEGIN
  SELECT ver INTO v FROM app_version WHERE only_row;
  IF p_known IS NOT NULL AND p_known = v THEN RETURN jsonb_build_object('ver', v, 'same', true); END IF;
  SELECT COALESCE(jsonb_object_agg(collection, d), '{}'::jsonb) INTO docs
    FROM (SELECT collection, jsonb_object_agg(id, body) AS d FROM app_docs GROUP BY collection) t;
  SELECT COALESCE(jsonb_object_agg(item_code, jsonb_build_object(
           'name', item_name, 'stock', current_stock, 'threshold', stock_threshold,
           'updated', last_updated, 'type', item_type)), '{}'::jsonb)
    INTO items FROM stock_items;
  RETURN jsonb_build_object('ver', v, 'data', docs || jsonb_build_object('items', items));
END $$;

-- One stock movement made by staff: 'in' (delivery), 'out' (taken out), 'count' (stock take).
CREATE OR REPLACE FUNCTION app_item_move(p_code text, p_kind text, p_qty integer, p_note text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE before integer; after integer; label text;
BEGIN
  IF p_kind NOT IN ('in','out','count') THEN
    RETURN jsonb_build_object('error', 'invalid_argument', 'message', 'Unknown movement.'); END IF;
  IF p_qty IS NULL OR p_qty < 0 OR p_qty > 100000 OR (p_kind <> 'count' AND p_qty = 0) THEN
    RETURN jsonb_build_object('error', 'invalid_argument', 'message', 'Enter a whole number above 0.'); END IF;

  SELECT current_stock INTO before FROM stock_items WHERE item_code = p_code FOR UPDATE;
  IF NOT FOUND THEN RETURN jsonb_build_object('error', 'invalid_argument', 'message', 'Unknown item.'); END IF;

  after := CASE p_kind WHEN 'in' THEN before + p_qty WHEN 'out' THEN before - p_qty ELSE p_qty END;
  label := CASE p_kind WHEN 'in' THEN 'Delivery in' WHEN 'out' THEN 'Taken out' ELSE 'Stock take' END;
  IF after = before AND p_kind = 'count' THEN
    RETURN jsonb_build_object('ok', true, 'stock', after, 'unchanged', true); END IF;

  UPDATE stock_items SET current_stock = after, last_updated = now() WHERE item_code = p_code;
  INSERT INTO stock_log (order_name, item_code, deduct_qty, stock_before, stock_after, kind, note)
    VALUES (label, p_code, before - after, before, after, p_kind, NULLIF(left(btrim(COALESCE(p_note, '')), 120), ''));
  RETURN jsonb_build_object('ok', true, 'stock', after);
END $$;

-- Mark an item as stocked or pre-order.
CREATE OR REPLACE FUNCTION app_item_type(p_code text, p_type text) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_type NOT IN ('stocked','pre-order') THEN
    RETURN jsonb_build_object('error', 'invalid_argument', 'message', 'Unknown type.'); END IF;
  UPDATE stock_items SET item_type = p_type WHERE item_code = p_code;
  IF NOT FOUND THEN RETURN jsonb_build_object('error', 'invalid_argument', 'message', 'Unknown item.'); END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

-- The last 20 movements of one item: orders from n8n and staff changes alike.
CREATE OR REPLACE FUNCTION app_item_history(p_code text) RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(jsonb_agg(r ORDER BY r.t DESC), '[]'::jsonb) FROM (
    SELECT "time" AS t, kind, order_name, sku, deduct_qty, stock_before, stock_after, note
    FROM stock_log WHERE item_code = p_code ORDER BY "time" DESC LIMIT 20) r;
$$;

REVOKE ALL ON FUNCTION app_read(bigint), app_item_move(text, text, integer, text), app_item_type(text, text), app_item_history(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION app_read(bigint), app_item_move(text, text, integer, text), app_item_type(text, text), app_item_history(text) TO service_role;
