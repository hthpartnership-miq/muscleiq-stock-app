// Stock data API for the MuscleIQ stock app.
// Every request is checked against the staff passcode, then passed to a database
// function in Supabase (see supabase/migrations/002_app_storage.sql). No npm packages needed.
//
// Environment variables (Vercel > Project > Settings > Environment Variables):
//   APP_PASSCODE                 required  the passcode staff type to open the app
//   SUPPLIER_PASSCODE            optional  a second passcode for suppliers. It only reads and changes Spare parts;
//                                          every other tab's data is filtered out here, on the server.
//   SUPABASE_URL                 added by Vercel's Supabase integration (https://<project>.supabase.co)
//   SUPABASE_SERVICE_ROLE_KEY    added by Vercel's Supabase integration. Server-side only, never sent to the browser.

const crypto = require("crypto");

const { SUPABASE_URL, SUPABASE_KEY, PASSCODE, SUPPLIER_PASSCODE } = require("./_config");
const SUPPLIER_COLS = ["parts"];

async function rpc(fn, args) {
  const r = await fetch(SUPABASE_URL + "/rest/v1/rpc/" + fn, {
    method: "POST",
    headers: { apikey: SUPABASE_KEY, authorization: "Bearer " + SUPABASE_KEY, "content-type": "application/json" },
    body: JSON.stringify(args || {})
  });
  if (!r.ok) throw new Error("database responded " + r.status + ": " + (await r.text()).slice(0, 300));
  return r.json();
}

function same(given, secret) {
  const a = crypto.createHash("sha256").update(String(given || "")).digest();
  const b = crypto.createHash("sha256").update(String(secret)).digest();
  return crypto.timingSafeEqual(a, b);
}
// "staff" for the main passcode, "supplier" for the supplier passcode, otherwise null.
function roleOf(given) {
  if (!given) return null;
  if (same(given, PASSCODE)) return "staff";
  if (SUPPLIER_PASSCODE && SUPPLIER_PASSCODE !== PASSCODE && same(given, SUPPLIER_PASSCODE)) return "supplier";
  return null;
}
function forbidden(res) { return res.status(403).json({ code: "not_granted", message: "This passcode can only change Spare parts." }); }

const isObj = v => v !== null && typeof v === "object" && !Array.isArray(v);
function parse(s) { try { const v = JSON.parse(s); return isObj(v) ? v : null; } catch (_) { return null; } }
function bad(res, message) { return res.status(400).json({ code: "invalid_argument", message }); }
function reply(res, out) {
  if (out && out.error) return res.status(400).json(Object.assign({}, out, { code: out.error, message: out.message || "" }));
  return res.status(200).json(out);
}

module.exports = async (req, res) => {
  res.setHeader("cache-control", "no-store");
  res.setHeader("x-robots-tag", "noindex");
  if (!SUPABASE_URL || !SUPABASE_KEY || !PASSCODE) {
    return res.status(503).json({ code: "not_configured", message: "Connect Supabase to this Vercel project and add APP_PASSCODE, then redeploy. See README.md." });
  }
  const role = roleOf(req.headers["x-passcode"]);
  if (!role) return res.status(401).json({ code: "passcode", message: "Wrong passcode." });
  const supplier = role === "supplier";

  try {
    if (req.method === "GET") {
      const v = req.query && req.query.v;
      const known = v !== undefined && v !== "" && /^\d+$/.test(String(v)) ? Number(v) : null;
      const out = await rpc("app_read", { p_known: known });
      if (out && supplier && out.data) {
        const d = {}; for (const c of SUPPLIER_COLS) d[c] = out.data[c] || {};
        out.data = d;
      }
      if (out && !out.error) out.role = role;
      return reply(res, out);
    }
    if (req.method !== "POST") return res.status(405).json({ code: "invalid_argument", message: "Use GET or POST." });

    const b = typeof req.body === "string" ? parse(req.body) : req.body;
    if (!isObj(b)) return bad(res, "Body must be JSON.");
    const { op, col, id } = b;
    if (typeof col !== "string" || typeof id !== "string") return bad(res, "Missing collection or id.");

    if (supplier && !(SUPPLIER_COLS.includes(col) && ["acquire", "set", "update", "delete"].includes(op))) return forbidden(res);
    if (col === "parts" && (op === "set" || op === "update" || op === "delete")) {
      if (op !== "delete" && !isObj(b.data)) return bad(res, "Document must be an object.");
      return reply(res, await rpc("app_part_write", { p_op: op, p_id: id, p_data: op === "delete" ? null : b.data, p_who: supplier ? "Supplier" : "Staff" }));
    }
    if (op === "acquire") {
      return reply(res, await rpc("app_acquire", { p_col: col, p_id: id, p_holder: String(b.holder || ""), p_ttl_ms: Math.round(Number(b.ttlMs) || 30000) }));
    }
    if (op === "item-move") {
      return reply(res, await rpc("app_item_move", { p_code: id, p_kind: String(b.kind || ""), p_qty: Math.round(Number(b.qty)), p_note: b.note == null ? null : String(b.note) }));
    }
    if (op === "item-change") {
      return reply(res, await rpc("app_item_change", { p_code: id, p_kind: String(b.kind || ""), p_qty: Math.round(Number(b.qty)), p_note: b.note == null ? null : String(b.note), p_preorder: b.preorder === true }));
    }
    if (op === "item-alert") {
      const on = b.on !== false;
      return reply(res, await rpc("app_item_alert", { p_code: id, p_on: on, p_threshold: on ? Math.round(Number(b.threshold)) : null }));
    }
    if (op === "item-decide") {
      return reply(res, await rpc("app_item_decide", { p_code: id, p_choice: String(b.choice || "") }));
    }
    if (op === "item-incoming") {
      const qty = b.qty == null ? null : Math.round(Number(b.qty));
      const arrive = typeof b.arrive === "string" && /^\d{4}-\d{2}-\d{2}$/.test(b.arrive) ? b.arrive : null;
      const inId = b.incomingId == null ? null : Math.round(Number(b.incomingId));
      return reply(res, await rpc("app_incoming", { p_action: String(b.action || ""), p_code: id, p_id: inId, p_qty: qty, p_arrive: arrive, p_note: b.note == null ? null : String(b.note) }));
    }
    if (op === "collection") {
      const cid = b.collectionId == null ? null : Math.round(Number(b.collectionId));
      return reply(res, await rpc("app_collection", { p_action: String(b.action || ""), p_id: cid, p_name: b.name == null ? null : String(b.name) }));
    }
    if (op === "item-collection") {
      const cid = b.collectionId == null || b.collectionId === "" ? null : Math.round(Number(b.collectionId));
      return reply(res, await rpc("app_item_collection", { p_code: id, p_collection: cid }));
    }
    if (op === "item-hide") {
      return reply(res, await rpc("app_item_hide", { p_code: id, p_hidden: b.hidden === true }));
    }
    if (op === "item-type") {
      return reply(res, await rpc("app_item_type", { p_code: id, p_type: String(b.type || "") }));
    }
    if (op === "item-history") {
      return reply(res, { rows: await rpc("app_item_history", { p_code: id }) });
    }
    if (op === "set" || op === "update" || op === "delete") {
      if (op !== "delete" && !isObj(b.data)) return bad(res, "Document must be an object.");
      return reply(res, await rpc("app_write", { p_op: op, p_col: col, p_id: id, p_data: op === "delete" ? null : b.data }));
    }
    return bad(res, "Unknown operation.");
  } catch (e) {
    console.error(e);
    return res.status(502).json({ code: "unavailable", message: "Stock storage did not respond." });
  }
};
