// Offline cache for the Lane 2 tester. Only registers on https/localhost.
const CACHE = "gujlish-fix-v1";
const ORT = "https://cdn.jsdelivr.net/npm/onnxruntime-web@1.30.0/dist/";
const SHELL = ["./", "./index.html", "./manifest.webmanifest", "./icon.svg",
  "./model/encoder_int8.onnx", "./model/decoder_int8.onnx", "./model/vocab.json",
  ORT + "ort.min.js", ORT + "ort-wasm-simd-threaded.wasm", ORT + "ort-wasm-simd-threaded.mjs"];
self.addEventListener("install", e => {
  e.waitUntil(caches.open(CACHE).then(c => Promise.allSettled(SHELL.map(u => c.add(u)))));
  self.skipWaiting();
});
self.addEventListener("activate", e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))));
  self.clients.claim();
});
self.addEventListener("fetch", e => {
  e.respondWith(caches.match(e.request, {ignoreSearch: true}).then(hit => hit || fetch(e.request).then(res => {
    if (res.ok && (e.request.url.startsWith(self.location.origin) || e.request.url.startsWith(ORT))) {
      const copy = res.clone();
      caches.open(CACHE).then(c => c.put(e.request, copy));
    }
    return res;
  })));
});
