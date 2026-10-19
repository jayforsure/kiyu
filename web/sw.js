// Kiyu service worker: a small script the phone keeps for this site, even when Kiyu is closed.
// Job 1: lets Kiyu open even with a bad connection.
// Job 2: shows payment alerts sent by the Kiyu alerts server.
const CACHE = "kiyu-v3";                       // change the number to throw away old saved files

self.addEventListener("install", () => self.skipWaiting());          // use a new version right away
self.addEventListener("activate", (e) => e.waitUntil((async () => {
  for (const key of await caches.keys()) if (key !== CACHE) await caches.delete(key);   // clean up old versions
  await self.clients.claim();
})()));

self.addEventListener("fetch", (e) => {
  const req = e.request, url = new URL(req.url);
  if (req.method !== "GET") return;                                   // blockchain calls (POST): never touch

  // Our own pages and files: try the internet first so you always get the newest version,
  // and only use the saved copy when you're offline.
  if (url.origin === location.origin) {
    e.respondWith(fetch(req).then((res) => {
      if (res.ok) { const copy = res.clone(); caches.open(CACHE).then((c) => c.put(req, copy)); }
      return res;
    }).catch(() => caches.match(req).then((hit) => hit || caches.match("/"))));
    return;
  }
  // Libraries and fonts have fixed versions in their address, so a saved copy is always right.
  if (/esm\.sh|fonts\.(googleapis|gstatic)\.com/.test(url.host)) {
    e.respondWith(caches.match(req).then((hit) => hit || fetch(req).then((res) => {
      const copy = res.clone(); caches.open(CACHE).then((c) => c.put(req, copy)); return res;
    })));
  }
});

// ---------- Payment alerts ----------
// The alerts server sends { title, body, url, tag }. We show it as a phone notification.
self.addEventListener("push", (e) => {
  let a = {};
  try { a = e.data?.json() ?? {}; } catch { a = { body: e.data?.text() }; }
  e.waitUntil(self.registration.showNotification(a.title || "Kiyu", {
    body: a.body || "",
    icon: "/icons/icon-192.png",
    badge: "/icons/badge-96.png",                // small status-bar icon: Android only uses its shape
    tag: a.tag,                                   // same payment again: replace, don't stack
    data: { url: a.url || "/" },
  }));
});

// Tapping the alert: bring Kiyu to the front, or open it
self.addEventListener("notificationclick", (e) => {
  e.notification.close();
  e.waitUntil((async () => {
    const open = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    const kiyu = open.find((c) => new URL(c.url).origin === self.location.origin);
    if (kiyu) return kiyu.focus();
    return self.clients.openWindow(e.notification.data?.url || "/");
  })());
});
