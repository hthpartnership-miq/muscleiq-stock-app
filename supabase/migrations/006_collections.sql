-- Collections: group Shopify stock items on the app's Shopify stock tab.
-- App-only grouping. Not used by n8n, the variant mapping, Shopify or the Google Sheet.
-- Each item sits in at most one collection. Removing a collection never removes items:
-- the collection is archived and its items go back to "Not in a collection".

CREATE TABLE IF NOT EXISTS item_collections (
  id         bigserial PRIMARY KEY,
  name       text NOT NULL,
  sort       integer NOT NULL DEFAULT 0,
  archived   boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS item_collections_name_idx ON item_collections (lower(name)) WHERE NOT archived;
ALTER TABLE item_collections ENABLE ROW LEVEL SECURITY;

ALTER TABLE stock_items ADD COLUMN IF NOT EXISTS collection_id bigint REFERENCES item_collections(id);

-- Add, rename or remove a collection.
CREATE OR REPLACE FUNCTION app_collection(p_action text, p_id bigint DEFAULT NULL, p_name text DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE nm text := left(btrim(COALESCE(p_name, '')), 60); new_id bigint;
BEGIN
  IF p_action IN ('add', 'rename') THEN
    IF nm = '' THEN RETURN jsonb_build_object('error', 'invalid_argument', 'message', 'Type a name for the section.'); END IF;
    IF EXISTS (SELECT 1 FROM item_collections WHERE NOT archived AND lower(name) = lower(nm) AND id IS DISTINCT FROM p_id) THEN
      RETURN jsonb_build_object('error', 'invalid_argument', 'message', 'That section is already listed.'); END IF;
  END IF;

  IF p_action = 'add' THEN
    INSERT INTO item_collections (name, sort)
      VALUES (nm, COALESCE((SELECT max(sort) FROM item_collections WHERE NOT archived), 0) + 10)
      RETURNING id INTO new_id;
    PERFORM app_bump();
    RETURN jsonb_build_object('ok', true, 'id', new_id);
  ELSIF p_action = 'rename' THEN
    UPDATE item_collections SET name = nm WHERE id = p_id AND NOT archived;
    IF NOT FOUND THEN RETURN jsonb_build_object('error', 'invalid_argument', 'message', 'That section is no longer listed.'); END IF;
    PERFORM app_bump();
    RETURN jsonb_build_object('ok', true);
  ELSIF p_action = 'remove' THEN
    UPDATE item_collections SET archived = true WHERE id = p_id AND NOT archived;
    IF NOT FOUND THEN RETURN jsonb_build_object('error', 'invalid_argument', 'message', 'That section is no longer listed.'); END IF;
    UPDATE stock_items SET collection_id = NULL WHERE collection_id = p_id;
    PERFORM app_bump();
    RETURN jsonb_build_object('ok', true);
  END IF;
  RETURN jsonb_build_object('error', 'invalid_argument', 'message', 'Unknown action.');
END $$;

-- Put an item in a collection, or take it out (p_collection null).
CREATE OR REPLACE FUNCTION app_item_collection(p_code text, p_collection bigint DEFAULT NULL) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF p_collection IS NOT NULL AND NOT EXISTS (SELECT 1 FROM item_collections WHERE id = p_collection AND NOT archived) THEN
    RETURN jsonb_build_object('error', 'invalid_argument', 'message', 'That section is no longer listed.'); END IF;
  UPDATE stock_items SET collection_id = p_collection WHERE item_code = p_code;
  IF NOT FOUND THEN RETURN jsonb_build_object('error', 'invalid_argument', 'message', 'Unknown item.'); END IF;
  RETURN jsonb_build_object('ok', true);
END $$;

-- Everything the app shows, now with collections.
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
           'collection', s.collection_id,
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

REVOKE ALL ON FUNCTION app_collection(text, bigint, text), app_item_collection(text, bigint), app_read(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION app_collection(text, bigint, text), app_item_collection(text, bigint), app_read(bigint) TO service_role;
