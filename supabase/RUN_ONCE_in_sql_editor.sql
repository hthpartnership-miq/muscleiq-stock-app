-- ONE-OFF: paste this whole file into Supabase > SQL Editor and click Run.
-- It finishes the app setup. These statements delete things, which Supabase only lets the project owner approve.
-- Safe to run more than once.

-- 1. Let the app notice when n8n changes a stock count.
CREATE OR REPLACE TRIGGER stock_items_bump AFTER INSERT OR UPDATE OR DELETE ON stock_items
  FOR EACH STATEMENT EXECUTE FUNCTION app_bump_trigger();

-- 2. Saving, changing and removing entries from the app.
CREATE OR REPLACE FUNCTION app_write(p_op text, p_col text, p_id text, p_data jsonb DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE cur jsonb; doc jsonb;
BEGIN
  IF p_col NOT IN ('stock','out','incoming','extra','parts','log') THEN
    RETURN jsonb_build_object('error', 'invalid_argument', 'message', 'Unknown collection.'); END IF;
  IF p_id IS NULL OR p_id !~ '^[A-Za-z0-9_.~:@+-]{1,200}$' THEN
    RETURN jsonb_build_object('error', 'invalid_argument', 'message', 'Bad document id.'); END IF;

  IF p_op = 'delete' THEN
    DELETE FROM app_docs WHERE collection = p_col AND id = p_id;
    RETURN jsonb_build_object('ok', true, 'ver', app_bump());
  END IF;

  IF p_op NOT IN ('set','update') THEN
    RETURN jsonb_build_object('error', 'invalid_argument', 'message', 'Unknown operation.'); END IF;
  IF p_data IS NULL OR jsonb_typeof(p_data) <> 'object' THEN
    RETURN jsonb_build_object('error', 'invalid_argument', 'message', 'Document must be an object.'); END IF;

  doc := p_data;
  IF p_op = 'update' THEN
    SELECT body INTO cur FROM app_docs WHERE collection = p_col AND id = p_id FOR UPDATE;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('error', 'invalid_argument', 'message', 'Document does not exist.'); END IF;
    doc := app_merge(cur, p_data);
  END IF;
  IF octet_length(doc::text) > 262144 THEN
    RETURN jsonb_build_object('error', 'invalid_argument', 'message', 'Document too large.'); END IF;

  INSERT INTO app_docs (collection, id, body) VALUES (p_col, p_id, doc)
    ON CONFLICT (collection, id) DO UPDATE SET body = EXCLUDED.body, updated_at = now();
  RETURN jsonb_build_object('ok', true, 'ver', app_bump());
END $$;

-- 3. The nightly backup.
CREATE OR REPLACE FUNCTION app_backup() RETURNS void
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  INSERT INTO app_backups (day, snapshot)
  SELECT current_date, jsonb_build_object(
    'app_docs',        (SELECT COALESCE(jsonb_agg(to_jsonb(d)), '[]'::jsonb) FROM app_docs d),
    'stock_items',     (SELECT COALESCE(jsonb_agg(to_jsonb(s)), '[]'::jsonb) FROM stock_items s),
    'variant_mapping', (SELECT COALESCE(jsonb_agg(to_jsonb(m)), '[]'::jsonb) FROM variant_mapping m))
  ON CONFLICT (day) DO UPDATE SET snapshot = EXCLUDED.snapshot, taken_at = now();
  DELETE FROM app_backups WHERE day < current_date - 30;
$$;

-- 4. Only the server may call these.
REVOKE ALL ON FUNCTION app_write(text, text, text, jsonb), app_backup() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION app_write(text, text, text, jsonb), app_backup() TO service_role;

-- 5. Tidy up from setup day: the test order and a temporary loading table.
DELETE FROM stock_log WHERE order_id = 'TEST-001';
DELETE FROM processed_orders WHERE shopify_order_id = 'TEST-001';
DROP TABLE IF EXISTS _map_load;

-- 6. Take the first backup now, and show what is in place.
SELECT app_backup();
SELECT (SELECT count(*) FROM app_docs) AS app_entries,
       (SELECT count(*) FROM stock_items) AS stock_items,
       (SELECT count(*) FROM app_backups) AS backups,
       (SELECT count(*) FROM processed_orders WHERE shopify_order_id = 'TEST-001') AS test_orders_left;
