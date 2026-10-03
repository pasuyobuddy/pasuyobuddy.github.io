// PasuyoBuddy service worker: makes the apps installable and shows a friendly page when offline.
// Pages are always fetched fresh from the network first, so updates appear right away.
const CACHE = "pasuyobuddy-shell-v1";
self.addEventListener("install", (e) => { self.skipWaiting(); });
self.addEventListener("activate", (e) => { e.waitUntil(self.clients.claim()); });
self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET" || new URL(req.url).origin !== self.location.origin) return;   // never touch Supabase or map requests
  if (req.mode !== "navigate") return;
  e.respondWith(
    fetch(req).then((res) => { const copy = res.clone(); caches.open(CACHE).then((c) => c.put(req, copy)); return res; })
      .catch(() => caches.match(req).then((hit) => hit || new Response("<h2 style='font-family:sans-serif;text-align:center;margin-top:40vh'>No internet connection.<br>Please try again.</h2>", { headers: { "Content-Type": "text/html" } })))
  );
});
