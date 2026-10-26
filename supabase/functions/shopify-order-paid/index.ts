// MuscleIQ stock: Shopify order webhooks -> take stock off in this database.
// Replaces the n8n workflow "Muscle IQ Stock Automation (Database)" (moved here on 26 Oct 2026 to save n8n runs).
// Shopify calls https://<project>.supabase.co/functions/v1/shopify-order-paid?key=<token>.
// The token lives in app_settings (key shopify_webhook_token); requests without it are refused.
//
// Topics:
//   orders/paid   -> always processed (normal web checkout).
//   orders/create -> processed only when the order is already paid (TikTok Shop and other channels
//                    create orders as paid, so "orders/paid" may never fire for them).
// Both can arrive for the same order; process_shopify_order records each order once, so it is only deducted once.
//
// The stock logic is the SQL function public.process_shopify_order (same query n8n used):
//   - records the order once (processed_orders); a repeated webhook does nothing
//   - maps each line's variant ID through variant_mapping, skipping unmapped variants
//   - takes the stock off and writes stock_log rows
// Low-stock and below-zero emails come from the stock_items trigger -> n8n "Stock Alerts", as before.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

let token: string | null = null;
async function getToken(): Promise<string | null> {
  if (token) return token;
  const { data, error } = await sb.from("app_settings").select("value").eq("key", "shopify_webhook_token").maybeSingle();
  if (error) throw error;
  token = data?.value ?? null;
  return token;
}

function same(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

const TOPICS = new Set(["orders/paid", "orders/create"]);

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ ok: false, error: "POST only" }, 405);

  let expected: string | null;
  try {
    expected = await getToken();
  } catch (e) {
    console.error("token lookup failed", e);
    return json({ ok: false, error: "server error" }, 500);
  }
  const key = new URL(req.url).searchParams.get("key") ?? "";
  if (!expected || !same(key, expected)) return json({ ok: false, error: "forbidden" }, 403);

  const topic = req.headers.get("x-shopify-topic");
  if (topic && !TOPICS.has(topic)) return json({ ok: true, skipped: "topic " + topic });

  let order: any;
  try {
    order = await req.json();
  } catch {
    return json({ ok: false, error: "bad json" }, 400);
  }
  if (!order || order.id == null) return json({ ok: false, error: "no order id" }, 400);

  // A new order that is not paid yet (normal checkout): orders/paid will follow, so do nothing now.
  if (topic === "orders/create" && order.financial_status !== "paid") {
    return json({ ok: true, order: order.name, skipped: "created, not paid yet (" + (order.financial_status ?? "unknown") + ")" });
  }

  const lines = (Array.isArray(order.line_items) ? order.line_items : [])
    .filter((it: any) => it && it.variant_id != null)
    .map((it: any) => ({
      order_id: String(order.id),
      order_name: order.name ?? null,
      variant_id: String(it.variant_id),
      sku: it.sku ?? null,
      quantity_sold: Number(it.quantity) || 0,
    }));
  if (!lines.length) return json({ ok: true, order: order.name, skipped: "no lines" });

  const { data, error } = await sb.rpc("process_shopify_order", { p_lines: lines });
  if (error) {
    console.error("process_shopify_order failed", order.name, topic, error);
    return json({ ok: false, error: "stock update failed" }, 500); // Shopify retries; a retry can't deduct twice
  }
  const rows = Array.isArray(data) ? data : [];
  console.log("order", order.name, topic ?? "no topic", "items updated", rows.length);
  return json({ ok: true, order: order.name, items: rows.length });
});
