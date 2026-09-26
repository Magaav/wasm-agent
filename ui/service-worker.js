// The agent itself is local and stateful, so requests must always reach the live node.
// This service worker supplies the installable app boundary without caching stale UI or API data.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (event) => event.waitUntil(self.clients.claim()));
self.addEventListener("fetch", (event) => event.respondWith(fetch(event.request)));
