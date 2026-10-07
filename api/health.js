// Setup check. Says which settings are present (yes/no only, never their values)
// and whether the database answers. Safe to open without the passcode.
const { SUPABASE_URL, SUPABASE_KEY, PASSCODE } = require("./_config");

module.exports = async (req, res) => {
  res.setHeader("cache-control", "no-store");
  const out = { supabaseUrl: !!SUPABASE_URL, supabaseKey: !!SUPABASE_KEY, passcode: !!PASSCODE, database: "not checked" };
  if (SUPABASE_URL && SUPABASE_KEY) {
    try {
      const r = await fetch(SUPABASE_URL + "/rest/v1/rpc/app_read", {
        method: "POST",
        headers: { apikey: SUPABASE_KEY, authorization: "Bearer " + SUPABASE_KEY, "content-type": "application/json" },
        body: JSON.stringify({ p_known: 9007199254740991 })
      });
      out.database = r.ok ? "ok" : "error " + r.status;
    } catch (_) { out.database = "unreachable"; }
  }
  res.status(200).json(out);
};
