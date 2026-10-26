/* Alavancagem VNG — service worker: abre o app mesmo com sinal fraco; dados sempre vêm do servidor. */
var CACHE = 'alav-v1';
var SHELL = ['/', '/manifest.webmanifest', '/icons/icon-192.png', '/icons/icon-512.png', '/icons/apple-touch-icon.png',
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4/dist/umd/supabase.min.js'];
self.addEventListener('install', function(e){
  e.waitUntil(caches.open(CACHE).then(function(c){ return c.addAll(SHELL); }).then(function(){ return self.skipWaiting(); }));
});
self.addEventListener('activate', function(e){
  e.waitUntil(caches.keys().then(function(ks){ return Promise.all(ks.filter(function(k){ return k!==CACHE; }).map(function(k){ return caches.delete(k); })); }).then(function(){ return self.clients.claim(); }));
});
self.addEventListener('fetch', function(e){
  var req = e.request, url = new URL(req.url);
  if(req.method !== 'GET' || url.hostname.endsWith('supabase.co')) return;
  if(req.mode === 'navigate'){
    e.respondWith(fetch(req).then(function(r){ var cp=r.clone(); caches.open(CACHE).then(function(c){ c.put('/', cp); }); return r; })
      .catch(function(){ return caches.match('/'); }));
    return;
  }
  e.respondWith(caches.match(req).then(function(hit){
    var net = fetch(req).then(function(r){ if(r && (r.ok || r.type==='opaque')){ var cp=r.clone(); caches.open(CACHE).then(function(c){ c.put(req, cp); }); } return r; }).catch(function(){ return hit; });
    return hit || net;
  }));
});
