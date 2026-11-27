#!/usr/bin/env node
// Live preview for the WebDoc site. No dependencies.
//
//   node tool/webdoc_dev.cjs [port]        (default port 8080)
//
// Serves WebDoc/ the way the host does (clean URLs, 404.html, _redirects) and
// reloads every open browser tab whenever a file under WebDoc/ changes. CSS
// changes swap in place without a full reload. The reload script is added to
// pages as they are served; nothing is written to the files themselves.
const http = require('http');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', 'WebDoc');
const PORT = Number(process.argv[2] || process.env.PORT || 8080);
const TYPES = {
  '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8', '.json': 'application/json',
  '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg',
  '.webp': 'image/webp', '.woff2': 'font/woff2', '.xml': 'application/xml',
  '.txt': 'text/plain; charset=utf-8', '.ico': 'image/x-icon',
};

const redirects = () => {
  try {
    return fs.readFileSync(path.join(ROOT, '_redirects'), 'utf8').split(/\r?\n/)
      .map((l) => l.trim().split(/\s+/)).filter((p) => p.length >= 2 && p[0].startsWith('/') && !p[0].includes('*'))
      .map(([from, to, code]) => ({ from, to, code: Number(code) || 301 }));
  } catch { return []; }
};

const CLIENT = `<script>(()=>{const es=new EventSource('/__live');
es.onmessage=e=>{const m=JSON.parse(e.data);
if(m.css){document.querySelectorAll('link[rel=stylesheet]').forEach(l=>{const u=new URL(l.href);u.searchParams.set('_live',Date.now());l.href=u.href;});}
else location.reload();};
es.onerror=()=>{};})();</script>`;

const clients = new Set();
let timer;
const notify = (file) => {
  clearTimeout(timer);
  timer = setTimeout(() => {
    const msg = JSON.stringify({ css: /\.css$/.test(file) });
    for (const res of clients) res.write(`data: ${msg}\n\n`);
    console.log(new Date().toLocaleTimeString(), 'changed', file, '→ reloaded', clients.size, 'tab(s)');
  }, 60);
};

// fs.watch recursive works on Windows and macOS; on Linux it needs Node 20+.
fs.watch(ROOT, { recursive: true }, (_, file) => { if (file && !file.includes('.git')) notify(file.replace(/\\/g, '/')); });

const resolve = (urlPath) => {
  let p = decodeURIComponent(urlPath);
  if (p.endsWith('/')) p += 'index';
  const base = path.join(ROOT, p);
  if (!base.startsWith(ROOT)) return null;
  for (const c of [base, base + '.html', path.join(base, 'index.html')]) {
    try { if (fs.statSync(c).isFile()) return c; } catch { /* next */ }
  }
  return null;
};

http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x');
  if (url.pathname === '/__live') {
    res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-cache', Connection: 'keep-alive' });
    res.write(': ok\n\n');
    clients.add(res);
    req.on('close', () => clients.delete(res));
    return;
  }
  const hit = redirects().find((r) => r.from === url.pathname);
  if (hit) { res.writeHead(hit.code, { Location: hit.to }); return res.end(); }

  let file = resolve(url.pathname);
  let status = 200;
  if (!file) { file = path.join(ROOT, '404.html'); status = 404; }
  fs.readFile(file, (err, data) => {
    if (err) { res.writeHead(404); return res.end('Not found'); }
    const ext = path.extname(file).toLowerCase();
    // No caching while editing, unlike the 7 days the live host allows.
    const headers = { 'Content-Type': TYPES[ext] || 'application/octet-stream', 'Cache-Control': 'no-store' };
    if (ext === '.html') {
      let html = data.toString('utf8');
      // Headless browsers (screenshots) would wait forever on the live stream.
      if (/HeadlessChrome/.test(req.headers['user-agent'] || '')) {
        res.writeHead(status, headers);
        return res.end(html);
      }
      html = html.includes('</body>') ?html.replace('</body>', CLIENT + '</body>') : html + CLIENT;
      res.writeHead(status, headers);
      return res.end(html);
    }
    res.writeHead(status, headers);
    res.end(data);
  });
}).listen(PORT, () => {
  console.log(`WebDoc live preview: http://localhost:${PORT}`);
  console.log('Watching', ROOT, '(Ctrl+C to stop)');
});
