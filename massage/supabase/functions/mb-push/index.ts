// Massage Buddy push sender (Supabase Edge Function "mb-push")
//
// Called by a Database Webhook every time a row is added to mb_notifications.
// It sends that notification to the person's phones through Firebase Cloud Messaging (free).
//
// Secrets it needs (Supabase > Edge Functions > Secrets):
//   FIREBASE_SERVICE_ACCOUNT  = the whole JSON file from Firebase > Project settings > Service accounts > Generate new private key
//   MB_SITE_URL               = https://pasuyobuddy.com/massage/   (optional, this is the default)
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase automatically.
//
// Safety: the function ignores everything in the request except the notification id,
// re-reads the notification from the database, and sends each one only once.

const SB_URL = Deno.env.get("SUPABASE_URL")!;
const SB_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SITE = (Deno.env.get("MB_SITE_URL") || "https://pasuyobuddy.com/massage/").replace(/\/?$/, "/");

const sbHeaders = { apikey: SB_KEY, Authorization: `Bearer ${SB_KEY}`, "Content-Type": "application/json" };
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

function b64url(data: ArrayBuffer | string): string {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : new Uint8Array(data);
  let s = ""; for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

let cachedToken: { token: string; exp: number } | null = null;
async function googleAccessToken(sa: { client_email: string; private_key: string }): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && cachedToken.exp > now + 60) return cachedToken.token;
  const header = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claim = b64url(JSON.stringify({
    iss: sa.client_email, scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token", iat: now, exp: now + 3600,
  }));
  const pem = sa.private_key.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(`${header}.${claim}`));
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: `${header}.${claim}.${b64url(sig)}` }),
  });
  const data = await res.json();
  if (!res.ok) throw new Error("Google token error: " + JSON.stringify(data));
  cachedToken = { token: data.access_token, exp: now + (data.expires_in || 3600) };
  return cachedToken.token;
}

Deno.serve(async (req) => {
  try {
    const raw = Deno.env.get("FIREBASE_SERVICE_ACCOUNT");
    if (!raw) return json({ skipped: "FIREBASE_SERVICE_ACCOUNT secret not set" });
    const sa = JSON.parse(raw);

    const payload = await req.json().catch(() => ({}));
    const id = Number(payload?.record?.id);
    if (!Number.isFinite(id) || id <= 0) return json({ skipped: "no notification id" });

    // claim the notification (only once)
    const claim = await fetch(`${SB_URL}/rest/v1/mb_notifications?id=eq.${id}&push_sent=eq.false`, {
      method: "PATCH", headers: { ...sbHeaders, Prefer: "return=representation" }, body: JSON.stringify({ push_sent: true }),
    });
    const rows = await claim.json();
    if (!Array.isArray(rows) || !rows.length) return json({ skipped: "already sent or not found" });
    const n = rows[0];

    const tRes = await fetch(`${SB_URL}/rest/v1/mb_push_tokens?user_id=eq.${n.user_id}&select=token`, { headers: sbHeaders });
    const tokens: { token: string }[] = await tRes.json();
    if (!tokens.length) return json({ sent: 0, reason: "no phones registered" });

    const access = await googleAccessToken(sa);
    const link = new URL(n.link || "", SITE).href;
    let sent = 0;
    for (const { token } of tokens) {
      const r = await fetch(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`, {
        method: "POST", headers: { Authorization: `Bearer ${access}`, "Content-Type": "application/json" },
        body: JSON.stringify({ message: {
          token,
          notification: { title: n.title, body: n.body },
          data: { link },
          webpush: {
            notification: { icon: SITE + "icon-192.png", badge: SITE + "icon-192.png", tag: "mb-" + n.id },
            fcm_options: { link },
          },
          android: { priority: "high", notification: { sound: "default" } },
        } }),
      });
      if (r.ok) { sent++; continue; }
      const err = await r.text();
      // phone uninstalled / token expired: forget it
      if (r.status === 404 || /UNREGISTERED|registration-token-not-registered|INVALID_ARGUMENT/.test(err)) {
        await fetch(`${SB_URL}/rest/v1/mb_push_tokens?token=eq.${encodeURIComponent(token)}`, { method: "DELETE", headers: sbHeaders });
      } else {
        console.error("FCM error", r.status, err);
      }
    }
    return json({ sent });
  } catch (e) {
    console.error(e);
    return json({ error: String(e) }, 500);
  }
});
