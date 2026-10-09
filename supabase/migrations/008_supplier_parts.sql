-- Spare parts writes with a History line.
-- Used for every Spare parts change (staff and supplier passcode), so History shows who changed what:
-- "Staff" or "Supplier". The log entry goes into the same day document (Europe/London) the app already uses.

CREATE OR REPLACE FUNCTION app_part_write(p_op text, p_id text, p_data jsonb DEFAULT NULL, p_who text DEFAULT 'Staff') RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE old jsonb; res jsonb; body jsonb; kind text; day text; entry jsonb; who text;
BEGIN
  who := CASE WHEN p_who = 'Supplier' THEN 'Supplier' ELSE 'Staff' END;
  SELECT d.body INTO old FROM app_docs d WHERE d.collection = 'parts' AND d.id = p_id FOR UPDATE;

  res := app_write(p_op, 'parts', p_id, p_data);
  IF res ? 'error' THEN RETURN res; END IF;

  IF p_op = 'delete' THEN
    IF old IS NULL THEN RETURN res; END IF;
    kind := 'part-del'; body := old;
  ELSE
    SELECT d.body INTO body FROM app_docs d WHERE d.collection = 'parts' AND d.id = p_id;
    kind := CASE WHEN old IS NULL THEN 'part-add' ELSE 'part-edit' END;
  END IF;

  day := to_char(now() AT TIME ZONE 'Europe/London', 'YYYY-MM-DD');
  entry := jsonb_build_object(
    's', left(COALESCE(NULLIF(btrim(body ->> 'name'), ''), 'Part'), 80),
    'd', 0,
    'n', CASE WHEN COALESCE(body ->> 'qty', '') ~ '^-?\d{1,9}$' THEN (body ->> 'qty')::int ELSE 0 END,
    'q', 0, 'k', kind, 'part', true, 'who', who,
    't', to_char(now() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'));

  INSERT INTO app_docs (collection, id, body)
    VALUES ('log', day, jsonb_build_object('day', day, 'entries', jsonb_build_object(p_id || '-' || to_char(clock_timestamp(), 'HH24MISSUS'), entry)))
  ON CONFLICT (collection, id) DO UPDATE
    SET body = jsonb_set(app_docs.body, '{entries}', COALESCE(app_docs.body -> 'entries', '{}'::jsonb) || (EXCLUDED.body -> 'entries')),
        updated_at = now();
  PERFORM app_bump();
  RETURN res;
END $$;

REVOKE ALL ON FUNCTION app_part_write(text, text, jsonb, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION app_part_write(text, text, jsonb, text) TO service_role;
