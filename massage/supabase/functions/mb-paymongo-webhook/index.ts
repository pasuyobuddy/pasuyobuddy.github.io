// Massage Buddy: PayMongo tells us a GCash payment is done (Edge Function "mb-paymongo-webhook")
//
// IMPORTANT: in Supabase, turn OFF "Verify JWT" (Enforce JWT verification) for this function.
// PayMongo cannot send a Supabase login; instead every call is checked with PayMongo's
// signature (header "Paymongo-Signature"), using the webhook secret saved by mb-pay "setup-webhook".
//
// Signature: header "t=<timestamp>,te=<test signature>,li=<live signature>".
// signature = HMAC-SHA256( "<timestamp>.<raw request body>", webhook secret ) in hex.

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SB_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const sb = { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}`, "Content-Type": "application/json" };
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

async function webhookSecret(): Promise<string> {
  const r = await fetch(`${SB_URL}/rest/v1/mb_private_settings?key=eq.paymongo_webhook_secret&select=value`, { headers: sb });
  const rows = await r.json();
  return Array.isArray(rows) && rows[0] ? rows[0].value : "";
}

async function hmacHex(secret: string, text: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(text));
  return Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function safeEqual(a: string, b: string): boolean {
  if (!a || !b || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

Deno.serve(async (req) => {
  try {
    const raw = await req.text();
    const header = req.headers.get("paymongo-signature") || "";
    const parts: Record<string, string> = {};
    for (const p of header.split(",")) { const i = p.indexOf("="); if (i > 0) parts[p.slice(0, i).trim()] = p.slice(i + 1).trim(); }
    const secret = await webhookSecret();
    if (!secret) return json({ error: "webhook not set up" }, 503);

    let event: any;
    try { event = JSON.parse(raw); } catch { return json({ error: "bad json" }, 400); }
    const attrs = event && event.data && event.data.attributes || {};
    const expected = await hmacHex(secret, `${parts.t}.${raw}`);
    const given = attrs.livemode ? parts.li : parts.te;
    if (!parts.t || !safeEqual(expected, given || "")) return json({ error: "bad signature" }, 401);
    // ignore very old deliveries (replays)
    if (Math.abs(Date.now() / 1000 - Number(parts.t)) > 60 * 60 * 24) return json({ error: "too old" }, 400);

    if (attrs.type !== "checkout_session.payment.paid") return json({ ok: true, ignored: attrs.type });

    const cs = attrs.data || {};
    const csa = cs.attributes || {};
    const bookingId = Number((csa.metadata && csa.metadata.booking_id) || String(csa.reference_number || "").replace(/^MB-/, ""));
    const payment = (csa.payments || [])[0] || {};
    const amount = Number(payment.attributes && payment.attributes.amount);
    if (!bookingId || !payment.id || !Number.isFinite(amount)) return json({ error: "missing booking or payment" }, 400);

    const r = await fetch(`${SB_URL}/rest/v1/rpc/mb_mark_paid`, {
      method: "POST", headers: sb,
      body: JSON.stringify({ p_booking: bookingId, p_session: cs.id || "", p_payment_id: payment.id, p_amount_centavos: amount }),
    });
    const result = await r.json().catch(() => ({}));
    if (!r.ok) { console.error("mb_mark_paid failed", r.status, JSON.stringify(result)); return json({ error: "db error" }, 500); }
    if (result && result.ok === false) console.error("mb_mark_paid refused", bookingId, JSON.stringify(result));
    return json({ ok: true, booking: bookingId, result });
  } catch (e) {
    console.error(e);
    return json({ error: String(e) }, 500);
  }
});
