// Reads the settings the app needs from Vercel's environment variables.
// Vercel's Supabase integration can add its variables with a prefix (for example STORAGE_SUPABASE_URL),
// so match on how the name ends rather than on one exact name.
function pick(endings) {
  for (const end of endings) {
    if (process.env[end]) return process.env[end];
    const key = Object.keys(process.env).find(k => k.endsWith("_" + end) && !k.startsWith("NEXT_PUBLIC_") && process.env[k]);
    if (key) return process.env[key];
  }
  return "";
}

const publicUrl = Object.keys(process.env).find(k => k.endsWith("SUPABASE_URL") && process.env[k]);

module.exports = {
  SUPABASE_URL: (pick(["SUPABASE_URL"]) || (publicUrl ? process.env[publicUrl] : "")).replace(/\/+$/, ""),
  SUPABASE_KEY: pick(["SUPABASE_SERVICE_ROLE_KEY", "SUPABASE_SECRET_KEY"]),
  PASSCODE: process.env.APP_PASSCODE || "",
  // Optional second passcode for suppliers: opens the Spare parts tab only (see api/db.js).
  SUPPLIER_PASSCODE: process.env.SUPPLIER_PASSCODE || ""
};
