// Massage Buddy: start a GCash payment (Supabase Edge Function "mb-pay")
//
// Called by the app with the customer's login. Creates a PayMongo checkout for one
// "awaiting_payment" GCash booking and returns the PayMongo page to open.
//
// Admin-only extra: { "action": "setup-webhook" } registers the PayMongo webhook that
// tells us when a payment is done, and saves its secret in mb_private_settings
// (so no secret ever has to be copied by hand).
//
// Secrets (Supabase > Edge Functions > Secrets):
//   PAYMONGO_SECRET_KEY = sk_test_... (test) or sk_live_... (live)   <- typed by the owner, never shared
//   MB_SITE_URL         = https://pasuyobuddy.com/massage/            (optional, this is the default)
// SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase automatically.

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SB_ANON = Deno.env.get("SUPABASE_ANON_KEY")!;
const SB_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const PM_KEY = Deno.env.get("PAYMONGO_SECRET_KEY") || "";
const PM_API = Deno.env.get("PAYMONGO_API_URL") || "https://api.paymongo.com";
const SITE = (Deno.env.get("MB_SITE_URL") || "https://pasuyobuddy.com/massage/").replace(/\/?$/, "/");

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const sb = { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}`, "Content-Type": "application/json" };
const pmAuth = () => "Basic " + btoa(PM_KEY + ":");

async function currentUser(req: Request): Promise<{ id: string } | null> {
  const auth = req.headers.get("Authorization") || "";
  if (!auth.startsWith("Bearer ")) return null;
  const r = await fetch(`${SB_URL}/auth/v1/user`, { headers: { apikey: SB_ANON, Authorization: auth } });
  if (!r.ok) return null;
  const u = await r.json();
  return u && u.id ? { id: u.id } : null;
}

async function setupWebhook(userId: string) {
  const a = await fetch(`${SB_URL}/rest/v1/mb_admins?user_id=eq.${userId}&select=user_id`, { headers: sb });
  const admins = await a.json();
  if (!Array.isArray(admins) || !admins.length) return json({ error: "Admins only." }, 403);

  const url = `${SB_URL}/functions/v1/mb-paymongo-webhook`;
  const events = ["checkout_session.payment.paid"];
  let wh: any = null;
  const c = await fetch(`${PM_API}/v1/webhooks`, {
    method: "POST", headers: { Authorization: pmAuth(), "Content-Type": "application/json" },
    body: JSON.stringify({ data: { attributes: { url, events } } }),
  });
  const cBody = await c.json().catch(() => ({}));
  if (c.ok) wh = cBody.data;
  else {
    // already registered before? find it and re-use it
    const l = await fetch(`${PM_API}/v1/webhooks`, { headers: { Authorization: pmAuth() } });
    const lBody = await l.json().catch(() => ({}));
    wh = (lBody.data || []).find((w: any) => w.attributes && w.attributes.url === url) || null;
    if (!wh) return json({ error: "PayMongo did not accept the webhook.", detail: cBody }, 502);
    if (wh.attributes.status === "disabled") {
      await fetch(`${PM_API}/v1/webhooks/${wh.id}/enable`, { method: "POST", headers: { Authorization: pmAuth() } });
    }
  }
  const secret = wh && wh.attributes && wh.attributes.secret_key;
  if (!secret) return json({ error: "PayMongo did not return a webhook secret." }, 502);
  for (const [key, value] of [["paymongo_webhook_secret", secret], ["paymongo_webhook_id", wh.id]]) {
    await fetch(`${SB_URL}/rest/v1/mb_private_settings?on_conflict=key`, {
      method: "POST", headers: { ...sb, Prefer: "resolution=merge-duplicates" }, body: JSON.stringify({ key, value }),
    });
  }
  return json({ ok: true, webhook_id: wh.id, mode: PM_KEY.startsWith("sk_live_") ? "live" : "test" });
}

async function startPayment(userId: string, bookingId: number) {
  const r = await fetch(`${SB_URL}/rest/v1/mb_bookings?id=eq.${bookingId}&select=id,customer_id,price,deposit_amount,paid_at,status,payment_method,payment_status,type_name,duration_min,start_at`, { headers: sb });
  const rows = await r.json();
  const b = Array.isArray(rows) ? rows[0] : null;
  if (!b || b.customer_id !== userId) return json({ error: "Booking not found." }, 404);
  const deposit = b.payment_method !== "gcash";   // cash booking: only the deposit is paid online
  if (deposit && !(Number(b.deposit_amount) > 0)) return json({ error: "Nothing to pay online for this booking." }, 400);
  if (b.paid_at) return json({ error: "This booking is already paid." }, 400);
  if (b.status !== "awaiting_payment") return json({ error: "This booking can no longer be paid. Please book again." }, 400);

  const amount = Math.round(Number(deposit ? b.deposit_amount : b.price) * 100);
  const res = await fetch(`${PM_API}/v1/checkout_sessions`, {
    method: "POST", headers: { Authorization: pmAuth(), "Content-Type": "application/json" },
    body: JSON.stringify({ data: { attributes: {
      line_items: [{ name: deposit ? `Deposit: ${b.type_name} massage, ${b.duration_min} min (rest paid in cash)` : `${b.type_name} massage, ${b.duration_min} min`, amount, currency: "PHP", quantity: 1 }],
      payment_method_types: ["gcash"],
      description: deposit ? `Massage Buddy booking #${b.id} deposit` : `Massage Buddy booking #${b.id}`,
      reference_number: `MB-${b.id}`,
      success_url: `${SITE}#paid/${b.id}`,
      cancel_url: `${SITE}#payfail/${b.id}`,
      send_email_receipt: false,
      show_description: true,
      show_line_items: true,
      metadata: { booking_id: String(b.id) },
    } } }),
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok || !body.data) {
    console.error("PayMongo checkout error", res.status, JSON.stringify(body));
    return json({ error: "Could not start GCash payment. Please try again.", detail: body.errors || body }, 502);
  }
  const session = body.data;
  await fetch(`${SB_URL}/rest/v1/mb_bookings?id=eq.${b.id}`, {
    method: "PATCH", headers: sb, body: JSON.stringify({ paymongo_session_id: session.id }),
  });
  return json({ ok: true, checkout_url: session.attributes.checkout_url, session_id: session.id });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    if (!PM_KEY) return json({ error: "GCash is not set up yet (PAYMONGO_SECRET_KEY missing)." }, 503);
    const user = await currentUser(req);
    if (!user) return json({ error: "Please log in first." }, 401);
    const body = await req.json().catch(() => ({}));
    if (body.action === "setup-webhook") return await setupWebhook(user.id);
    const id = Number(body.booking_id);
    if (!Number.isFinite(id) || id <= 0) return json({ error: "Missing booking." }, 400);
    return await startPayment(user.id, id);
  } catch (e) {
    console.error(e);
    return json({ error: String(e) }, 500);
  }
});
