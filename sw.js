// AI-UK 提词器 · Service Worker
// HTML 优先网络请求（保证更新即时生效），其他资源缓存优先（离线可用）

const CACHE = 'ai-uk-teleprompter-v6';

const PRECACHE = [
  './teleprompter.html',
  './manifest.json',
  './icon-192.png',
  './icon-512.png',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE).then((cache) => cache.addAll(PRECACHE))
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET') return;

  const url = new URL(event.request.url);
  const isHTML = url.pathname.endsWith('teleprompter.html') || url.pathname.endsWith('/');
  const isStatic = ['manifest.json', '.png'].some(ext => url.pathname.endsWith(ext));

  if (isHTML) {
    // HTML: always try the network first, then save the fresh copy as an
    // offline fallback. This avoids stale-first updates without breaking PWA
    // launch after the device goes offline.
    event.respondWith((async () => {
      try {
        const response = await fetch(event.request, { cache: 'no-store' });
        if (response && response.ok) {
          try {
            const cache = await caches.open(CACHE);
            await cache.put(event.request, response.clone());
          } catch (cacheError) {
            console.warn('HTML offline cache skipped:', cacheError);
          }
        }
        return response;
      } catch (networkError) {
        const cached = await caches.match(event.request);
        if (cached) return cached;
        // The root path is not the canonical launch URL, but map it to the
        // precached document when possible.
        return caches.match('./teleprompter.html');
      }
    })());
  } else if (isStatic) {
    // Static assets: cache-first → network fallback
    event.respondWith(
      caches.match(event.request).then((cached) => {
        const fetched = fetch(event.request).then((response) => {
          if (response && response.status === 200) {
            const clone = response.clone();
            caches.open(CACHE).then((cache) => cache.put(event.request, clone));
          }
          return response;
        });
        return cached || fetched;
      })
    );
  } else {
    // Everything else: network first
    event.respondWith(fetch(event.request));
  }
});
