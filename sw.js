// PasuyoBuddy service worker: makes the apps installable, shows a friendly page when offline,
// and shows job alerts on the rider's phone even when the app is closed.
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

// ---- Job alerts ----
self.addEventListener("push", (e) => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (x) { d = { title: "PasuyoBuddy", body: e.data ? e.data.text() : "" }; }
  e.waitUntil(self.registration.showNotification(d.title || "PasuyoBuddy: new job", {
    body: d.body || "Open the app to see the job.",
    tag: d.tag || "pasuyobuddy", renotify: true, requireInteraction: true,
    vibrate: [300, 150, 300, 150, 300],
    icon: "rider-icon-192.png", badge: "rider-icon-192.png",
    data: { url: d.url || "/rider.html" }
  }));
});
self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  const url = new URL((e.notification.data && e.notification.data.url) || "/rider.html", self.location.origin).href;
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((list) => {
    for (const c of list) { if (c.url.split("?")[0] === url && "focus" in c) return c.focus(); }
    return self.clients.openWindow(url);
  }));
});
