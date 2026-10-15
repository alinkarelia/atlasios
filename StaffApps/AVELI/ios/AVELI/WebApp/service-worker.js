/* AVELI: network-only private workspace. No mail, files, API responses or
 * authenticated HTML are saved in Cache Storage. Existing no-store is respected. */
'use strict';
const LEGACY_CACHE_PREFIX = 'aveli-pwa-';
const APP_NAVIGATIONS = new Set(['/', '/index.html', '/screens.html']);
const OFFLINE_HTML = `<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><meta name="theme-color" content="#111813"><title>AVELI · Нет соединения</title><style>html{color-scheme:dark}body{margin:0;min-height:100vh;display:grid;place-items:center;background:#111813;color:#edf4eb;font:16px/1.6 system-ui,sans-serif}main{max-width:420px;padding:32px;text-align:center}.mark{width:76px;height:76px;display:grid;place-items:center;margin:0 auto 22px;border:1px solid #548447;border-radius:23px;background:#254826;color:#adf491;font-size:38px;font-weight:600}h1{font-size:30px;letter-spacing:4px;margin:0 0 24px}p{color:#b4c1b2}a{display:inline-block;margin:14px 0 28px;padding:12px 20px;border-radius:12px;background:#a4e78c;color:#163014;font-weight:650;text-decoration:none}small{display:block;color:#7c907e;font-size:12px}</style></head><body><main><div class="mark" aria-hidden="true">A</div><h1>AVELI</h1><p>Соединение прервано</p><p>Проверьте интернет и откройте приложение снова. Почта, чат и файлы доступны после восстановления связи.</p><a href="/">Попробовать снова</a><small>Workspace by Семейный архив: Живая память</small></main></body></html>`;
self.addEventListener('install', event => { event.waitUntil(Promise.resolve()); });
self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    // Only caches created by this feature may be removed; cloud IndexedDB is untouched.
    for (const name of await caches.keys()) if (name.startsWith(LEGACY_CACHE_PREFIX)) await caches.delete(name);
    await self.clients.claim();
  })());
});
self.addEventListener('fetch', event => {
  const request = event.request;
  const url = new URL(request.url);
  if (request.method !== 'GET' || request.mode !== 'navigate' || url.origin !== self.location.origin || !APP_NAVIGATIONS.has(url.pathname)) return;
  event.respondWith((async () => {
    // A server denial is an ordinary response and must never become an offline login bypass.
    try { return await fetch(request); }
    catch {
      return new Response(OFFLINE_HTML, {status:503, headers:{
        'Content-Type':'text/html; charset=utf-8',
        'Cache-Control':'no-store',
        'Content-Security-Policy':"default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'self'",
        'X-Content-Type-Options':'nosniff',
        'Referrer-Policy':'no-referrer'
      }});
    }
  })());
});
