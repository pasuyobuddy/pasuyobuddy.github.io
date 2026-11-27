// Massage Buddy: send a GCash refund through PayMongo (Edge Function "mb-refund")
//
// Called by a Database Webhook every time a row is added to mb_refunds
// (the database decides the amount from the Refund & Cancellation Policy).
// Safety: only the refund id is taken from the request; the row is re-read and claimed
// (pending -> processing) so each refund is sent only once.
//
// Secrets: PAYMONGO_SECRET_KEY (same as mb-pay). SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY are automatic.

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SB_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const PM_KEY = Deno.env.get("PAYMONGO_SECRET_KEY") || "";
const PM_API = Deno.env.get("PAYMONGO_API_URL") || "https://api.paymongo.com";
const sb = { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}`, "Content-Type": "application/json" };
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

async function result(id: number, ok: boolean, refundId: string, error: string) {
  await fetch(`${SB_URL}/rest/v1/rpc/mb_refund_result`, {
    method: "POST", headers: sb,
    body: JSON.stringify({ p_refund: id, p_ok: ok, p_paymongo_refund_id: refundId, p_error: error }),
  });
}

Deno.serve(async (req) => {
  try {
    if (!PM_KEY) return json({ skipped: "PAYMONGO_SECRET_KEY not set" });
    const payload = await req.json().catch(() => ({}));
    const id = Number(payload && payload.record && payload.record.id);
    if (!Number.isFinite(id) || id <= 0) return json({ skipped: "no refund id" });

    // claim it (only once)
    const c = await fetch(`${SB_URL}/rest/v1/mb_refunds?id=eq.${id}&status=eq.pending`, {
      method: "PATCH", headers: { ...sb, Prefer: "return=representation" }, body: JSON.stringify({ status: "processing" }),
    });
    const rows = await c.json();
    if (!Array.isArray(rows) || !rows.length) return json({ skipped: "already handled" });
    const r = rows[0];

    const res = await fetch(`${PM_API}/v1/refunds`, {
      method: "POST", headers: { Authorization: "Basic " + btoa(PM_KEY + ":"), "Content-Type": "application/json" },
      body: JSON.stringify({ data: { attributes: {
        amount: Math.round(Number(r.amount) * 100),
        payment_id: r.payment_id,
        reason: "requested_by_customer",
        notes: `Massage Buddy booking #${r.booking_id}: ${r.reason}`.slice(0, 200),
      } } }),
    });
    const body = await res.json().catch(() => ({}));
    if (res.ok && body.data) {
      await result(id, true, body.data.id, "");
      return json({ ok: true, refund: body.data.id });
    }
    const err = (body.errors && body.errors.map((e: any) => e.detail || e.code).join("; ")) || `HTTP ${res.status}`;
    console.error("PayMongo refund error", res.status, JSON.stringify(body));
    await result(id, false, "", err);
    return json({ ok: false, error: err });
  } catch (e) {
    console.error(e);
    return json({ error: String(e) }, 500);
  }
});
