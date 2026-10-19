// Kiyu service worker: a small script the browser keeps for this site.
// For now it does one job: lets Kiyu open even with a bad connection.
// (Later it will also show push notifications.)
const CACHE = "kiyu-v1";                       // change the number to throw away old saved files

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
