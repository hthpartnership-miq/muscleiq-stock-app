// Stock data API for the MuscleIQ stock app.
// Every request is checked against the staff passcode, then passed to a database
// function in Supabase (see supabase/migrations/002_app_storage.sql). No npm packages needed.
//
// Environment variables (Vercel > Project > Settings > Environment Variables):
//   APP_PASSCODE                 required  the passcode staff type to open the app
//   SUPABASE_URL                 added by Vercel's Supabase integration (https://<project>.supabase.co)
//   SUPABASE_SERVICE_ROLE_KEY    added by Vercel's Supabase integration. Server-side only, never sent to the browser.

const crypto = require("crypto");

const { SUPABASE_URL, SUPABASE_KEY, PASSCODE } = require("./_config");

async function rpc(fn, args) {
  const r = await fetch(SUPABASE_URL + "/rest/v1/rpc/" + fn, {
    method: "POST",
    headers: { apikey: SUPABASE_KEY, authorization: "Bearer " + SUPABASE_KEY, "content-type": "application/json" },
    body: JSON.stringify(args || {})
  });
  if (!r.ok) throw new Error("database responded " + r.status + ": " + (await r.text()).slice(0, 300));
  return r.json();
}

function passOk(given) {
  const a = crypto.createHash("sha256").update(String(given || "")).digest();
  const b = crypto.createHash("sha256").update(PASSCODE).digest();
  return crypto.timingSafeEqual(a, b);
}

const isObj = v => v !== null && typeof v === "object" && !Array.isArray(v);
function parse(s) { try { const v = JSON.parse(s); return isObj(v) ? v : null; } catch (_) { return null; } }
function bad(res, message) { return res.status(400).json({ code: "invalid_argument", message }); }
function reply(res, out) {
  if (out && out.error) return res.status(400).json({ code: out.error, message: out.message || "" });
  return res.status(200).json(out);
}

module.exports = async (req, res) => {
  res.setHeader("cache-control", "no-store");
  res.setHeader("x-robots-tag", "noindex");
  if (!SUPABASE_URL || !SUPABASE_KEY || !PASSCODE) {
    return res.status(503).json({ code: "not_configured", message: "Connect Supabase to this Vercel project and add APP_PASSCODE, then redeploy. See README.md." });
  }
  if (!passOk(req.headers["x-passcode"])) return res.status(401).json({ code: "passcode", message: "Wrong passcode." });

  try {
    if (req.method === "GET") {
      const v = req.query && req.query.v;
      const known = v !== undefined && v !== "" && /^\d+$/.test(String(v)) ? Number(v) : null;
      return reply(res, await rpc("app_read", { p_known: known }));
    }
    if (req.method !== "POST") return res.status(405).json({ code: "invalid_argument", message: "Use GET or POST." });

    const b = typeof req.body === "string" ? parse(req.body) : req.body;
    if (!isObj(b)) return bad(res, "Body must be JSON.");
    const { op, col, id } = b;
    if (typeof col !== "string" || typeof id !== "string") return bad(res, "Missing collection or id.");

    if (op === "acquire") {
      return reply(res, await rpc("app_acquire", { p_col: col, p_id: id, p_holder: String(b.holder || ""), p_ttl_ms: Math.round(Number(b.ttlMs) || 30000) }));
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
