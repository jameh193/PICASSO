const CACHE='rish-o-ghaichi-v6';
const SHELL=['./','index.html','manifest.json','icon-192.png','icon-512.png','supabase-config.js'];
const HOSTS=['fonts.googleapis.com','fonts.gstatic.com','cdn.jsdelivr.net','esm.sh'];
self.addEventListener('install',e=>{e.waitUntil(caches.open(CACHE).then(c=>c.addAll(SHELL)).then(()=>self.skipWaiting()))});
self.addEventListener('activate',e=>{e.waitUntil(caches.keys().then(k=>Promise.all(k.filter(x=>x!==CACHE).map(x=>caches.delete(x)))).then(()=>self.clients.claim()))});
self.addEventListener('fetch',e=>{
  if(e.request.method!=='GET'||!e.request.url.startsWith('http'))return;
  const u=new URL(e.request.url);
  if(u.origin!==location.origin&&!HOSTS.includes(u.hostname))return; // درخواست‌های Supabase هرگز کش نمی‌شوند
  e.respondWith(fetch(e.request).then(r=>{const c=r.clone();caches.open(CACHE).then(x=>x.put(e.request,c)).catch(()=>{});return r}).catch(()=>caches.match(e.request).then(r=>r||caches.match('index.html'))));
});
