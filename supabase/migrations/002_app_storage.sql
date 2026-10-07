-- Storage for the stock app itself (rack counts, reserved/sold, containers, other stock, spare parts, history).
-- The app keeps small JSON documents grouped into collections, so one table holds them all.
-- The Vercel API calls the functions below through Supabase's REST API with the service role key.

CREATE TABLE IF NOT EXISTS app_docs (
  collection text NOT NULL,
  id         text NOT NULL,
  body       jsonb NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (collection, id)
);

-- One counter that goes up on every change, so the app can ask "anything new since version N?"
CREATE TABLE IF NOT EXISTS app_version (
  only_row boolean PRIMARY KEY DEFAULT true CHECK (only_row),
  ver      bigint NOT NULL DEFAULT 0
);
INSERT INTO app_version (only_row, ver) VALUES (true, 0) ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS app_leases (
  path       text PRIMARY KEY,
  holder     text NOT NULL,
  expires_at timestamptz NOT NULL
);

CREATE TABLE IF NOT EXISTS app_backups (
  day      date PRIMARY KEY,
  taken_at timestamptz NOT NULL DEFAULT now(),
  snapshot jsonb NOT NULL
);

ALTER TABLE app_docs    ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_version ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_leases  ENABLE ROW LEVEL SECURITY;
ALTER TABLE app_backups ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION app_bump() RETURNS bigint
LANGUAGE sql SET search_path = public AS $$
  UPDATE app_version SET ver = ver + 1 WHERE only_row RETURNING ver;
$$;

-- n8n changes stock_items directly, so bump the version there too and the app picks it up.
CREATE OR REPLACE FUNCTION app_bump_trigger() RETURNS trigger
LANGUAGE plpgsql SET search_path = public AS $$
BEGIN
  PERFORM app_bump();
  RETURN NULL;
END $$;
CREATE OR REPLACE TRIGGER stock_items_bump AFTER INSERT OR UPDATE OR DELETE ON stock_items
  FOR EACH STATEMENT EXECUTE FUNCTION app_bump_trigger();

-- Objects merge key by key, anything else replaces (same rule the app was built on).
CREATE OR REPLACE FUNCTION app_merge(base jsonb, patch jsonb) RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path = public AS $$
DECLARE k text; v jsonb; out jsonb := base;
BEGIN
  IF jsonb_typeof(base) <> 'object' OR jsonb_typeof(patch) <> 'object' THEN RETURN patch; END IF;
  FOR k, v IN SELECT * FROM jsonb_each(patch) LOOP
    IF jsonb_typeof(v) = 'object' AND jsonb_typeof(out -> k) = 'object'
      THEN out := jsonb_set(out, ARRAY[k], app_merge(out -> k, v));
      ELSE out := jsonb_set(out, ARRAY[k], v);
    END IF;
  END LOOP;
  RETURN out;
END $$;

-- Everything the app shows, or just {same:true} when nothing changed since version p_known.
CREATE OR REPLACE FUNCTION app_read(p_known bigint DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE v bigint; docs jsonb; items jsonb;
BEGIN
  SELECT ver INTO v FROM app_version WHERE only_row;
  IF p_known IS NOT NULL AND p_known = v THEN RETURN jsonb_build_object('ver', v, 'same', true); END IF;
  SELECT COALESCE(jsonb_object_agg(collection, d), '{}'::jsonb) INTO docs
    FROM (SELECT collection, jsonb_object_agg(id, body) AS d FROM app_docs GROUP BY collection) t;
  SELECT COALESCE(jsonb_object_agg(item_code, jsonb_build_object(
           'name', item_name, 'stock', current_stock, 'threshold', stock_threshold, 'updated', last_updated)), '{}'::jsonb)
    INTO items FROM stock_items;
  RETURN jsonb_build_object('ver', v, 'data', docs || jsonb_build_object('items', items));
END $$;

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

-- Short cooperative lock so two phones changing the same count take turns.
CREATE OR REPLACE FUNCTION app_acquire(p_col text, p_id text, p_holder text, p_ttl_ms integer DEFAULT 30000) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE ttl integer := LEAST(600000, GREATEST(1000, COALESCE(p_ttl_ms, 30000))); got text;
BEGIN
  IF COALESCE(p_holder, '') = '' THEN
    RETURN jsonb_build_object('error', 'invalid_argument', 'message', 'Missing holder.'); END IF;
  INSERT INTO app_leases (path, holder, expires_at)
    VALUES (p_col || '/' || p_id, left(p_holder, 100), now() + make_interval(secs => ttl / 1000.0))
    ON CONFLICT (path) DO UPDATE SET holder = EXCLUDED.holder, expires_at = EXCLUDED.expires_at
      WHERE app_leases.expires_at < now() OR app_leases.holder = EXCLUDED.holder
    RETURNING holder INTO got;
  IF got IS NULL THEN RETURN jsonb_build_object('acquired', false); END IF;
  RETURN jsonb_build_object('acquired', true, 'holder', got);
END $$;

-- Nightly copy of everything, kept for 30 days.
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

-- Only the server (service role) may call these; the public web API cannot.
REVOKE ALL ON FUNCTION app_read(bigint), app_write(text, text, text, jsonb), app_acquire(text, text, text, integer), app_backup(), app_bump(), app_merge(jsonb, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION app_read(bigint), app_write(text, text, text, jsonb), app_acquire(text, text, text, integer), app_backup() TO service_role;
