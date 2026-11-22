// Massage Buddy service worker
// - makes the apps installable and opens the last good copy when offline
// - shows phone notifications sent through Firebase (only if Firebase is set in config.js)
// Pages are always fetched fresh first, so updates appear right away.
const CACHE = "massagebuddy-v1.06";
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));
self.addEventListener("fetch", (e) => {
  const req = e.request;
  if (req.method !== "GET" || new URL(req.url).origin !== self.location.origin) return; // never touch Supabase/Firebase
  if (req.mode !== "navigate") return;
  e.respondWith(
    fetch(req.url, { cache: "no-cache", credentials: "same-origin" }).then((res) => {
      if (!res.ok) return caches.match(req, { ignoreSearch: true }).then((hit) => hit || res);
      const copy = res.clone(); caches.open(CACHE).then((c) => c.put(req, copy)); return res;
    }).catch(() => caches.match(req, { ignoreSearch: true }).then((hit) => hit ||
      new Response("<h2 style='font-family:sans-serif;text-align:center;margin-top:40vh'>No internet connection.<br>Please try again.</h2>", { headers: { "Content-Type": "text/html" } })))
  );
});

// ---- Firebase push (background) ----
try {
  importScripts("config.js");
  if (self.MB_CONFIG && self.MB_CONFIG.firebase) {
    importScripts("https://www.gstatic.com/firebasejs/10.14.1/firebase-app-compat.js",
                  "https://www.gstatic.com/firebasejs/10.14.1/firebase-messaging-compat.js");
    firebase.initializeApp(self.MB_CONFIG.firebase);
    firebase.messaging(); // messages with a "notification" part are shown automatically
  }
} catch (e) { /* push not set up: app still works */ }

self.addEventListener("notificationclick", (e) => {
  const link = (e.notification.data && (e.notification.data.link || (e.notification.data.FCM_MSG && e.notification.data.FCM_MSG.fcmOptions && e.notification.data.FCM_MSG.fcmOptions.link))) || "./";
  e.notification.close();
  const url = new URL(link, self.registration.scope).href;
  e.waitUntil(self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((list) => {
    for (const c of list) if (c.url.split("#")[0] === url.split("#")[0] && "focus" in c) { c.navigate(url); return c.focus(); }
    return self.clients.openWindow(url);
  }));
});
