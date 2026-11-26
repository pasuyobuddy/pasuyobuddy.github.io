// Supabase Edge Function: pos-manifest
// Gives every store its own installable app (name + logo) for Android, Windows/Mac (Chrome/Edge).
//
//   GET /functions/v1/pos-manifest?s=<store-slug>          -> web app manifest JSON
//   GET /functions/v1/pos-manifest?s=<store-slug>&icon=1   -> the store logo as an image
//
// Deploy: Supabase Dashboard > Edge Functions > Deploy a new function > name "pos-manifest",
// paste this file, and turn OFF "Verify JWT" (browsers fetch manifests without a login).
// Optional secret APP_URL (default https://pasuyobuddy.com).

import { createClient } from "jsr:@supabase/supabase-js@2";

const APP_URL = (Deno.env.get("APP_URL") || "https://pasuyobuddy.com").replace(/\/$/, "");
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  const url = new URL(req.url);
  const slug = (url.searchParams.get("s") || "").toLowerCase().replace(/[^a-z0-9-]/g, "").slice(0, 40);

  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!);
  const { data } = slug ? await sb.rpc("pos_public_brand", { p_slug: slug }) : { data: null };
  const brand = Array.isArray(data) ? data[0] : null;

  // ---- icon
  if (url.searchParams.has("icon")) {
    const m = brand?.logo?.match(/^data:(image\/[a-z+]+);base64,(.+)$/);
    if (!m) return Response.redirect(`${APP_URL}/pos/icon-512.png`, 302);
    const bytes = Uint8Array.from(atob(m[2]), (c) => c.charCodeAt(0));
    return new Response(bytes, {
      headers: { ...cors, "Content-Type": m[1], "Cache-Control": "public, max-age=600" },
    });
  }

  // ---- manifest
  const name = brand?.name || "Buddy POS";
  const color = /^#[0-9a-f]{6}$/i.test(brand?.theme_color || "") ? brand.theme_color : "#1E3A8A";
  const self = `${url.origin}${url.pathname}`;
  const start = brand ? `${APP_URL}/pos/?s=${encodeURIComponent(brand.slug)}` : `${APP_URL}/pos/`;
  const icons = brand?.logo
    ? [
        { src: `${self}?s=${brand.slug}&icon=1&v=${brand.logo.length}`, sizes: "512x512", type: brand.logo.slice(5, brand.logo.indexOf(";")), purpose: "any" },
      ]
    : [
        { src: `${APP_URL}/pos/icon-192.png`, sizes: "192x192", type: "image/png" },
        { src: `${APP_URL}/pos/icon-512.png`, sizes: "512x512", type: "image/png" },
      ];
  const manifest = {
    id: start,
    name,
    short_name: name.length > 14 ? name.slice(0, 14).trim() : name,
    description: `${name} – point of sale`,
    start_url: start,
    scope: `${APP_URL}/pos/`,
    display: "standalone",
    orientation: "any",
    background_color: "#ffffff",
    theme_color: color,
    icons,
  };
  return new Response(JSON.stringify(manifest), {
    headers: { ...cors, "Content-Type": "application/manifest+json", "Cache-Control": "public, max-age=300" },
  });
});
