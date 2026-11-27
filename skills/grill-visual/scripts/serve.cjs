// grill-visual のローカルサーバー。Node 標準だけで動く(外部へのリクエストはしない)。
// ブラウザとの間でやり取りするのは 3 つだけ: 新しい画面ができたときの reload(SSE)、
// クリックなどのイベント(POST)、frame が組み立てた指示文(POST)。
//
// 設定は環境変数で受ける。起動・停止は start.sh / stop.sh が包む。
// ブラウザは開かない。URL はエージェントが open-url で渡す(開き方の正本を open-url の 1 か所にする)。
//   GRILL_VISUAL_DIR          セッションのディレクトリ(必須。中に content/ と state/ を作る)
//   GRILL_VISUAL_OWNER_PID    この pid が消えたら止まる(任意)
//   GRILL_VISUAL_IDLE_MINUTES 何も操作がなければ止まるまでの分(既定 240)
//   GRILL_VISUAL_SCAN_MS / GRILL_VISUAL_CHECK_MS  画面の走査と停止判定の間隔(テストで短くする)
'use strict';

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

const SESSION_DIR = process.env.GRILL_VISUAL_DIR;
if (!SESSION_DIR) {
  console.log(JSON.stringify({ error: 'GRILL_VISUAL_DIR is required' }));
  process.exit(1);
}
const SCREEN_DIR = path.join(SESSION_DIR, 'content');
const STATE_DIR = path.join(SESSION_DIR, 'state');
const EVENTS_FILE = path.join(STATE_DIR, 'events');
const INSTRUCTION_FILE = path.join(STATE_DIR, 'instruction.md');
const INFO_FILE = path.join(STATE_DIR, 'server-info');
const STOPPED_FILE = path.join(STATE_DIR, 'server-stopped');
const FRAME_FILE = path.join(__dirname, 'frame-template.html');

const IDLE_MS = Number(process.env.GRILL_VISUAL_IDLE_MINUTES || 240) * 60 * 1000;
const SCAN_MS = Number(process.env.GRILL_VISUAL_SCAN_MS || 400);
const CHECK_MS = Number(process.env.GRILL_VISUAL_CHECK_MS || 30000);
// 指示文は画面 1 枚分の文章なので、1 MiB を超える POST は誤りか悪用として弾く
const MAX_BODY = 1024 * 1024;
// 画面から配る script はこの 2 つだけ(任意のファイルを scripts/ から読ませない)
const CLIENT_SCRIPTS = new Set(['client.js', 'companion-ui.js']);
const MIME = {
  '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.webp': 'image/webp', '.ico': 'image/x-icon', '.woff2': 'font/woff2',
  '.txt': 'text/plain; charset=utf-8', '.md': 'text/plain; charset=utf-8',
};

const KEY = crypto.randomBytes(16).toString('hex');
let port = 0;
let lastActivity = Date.now();
let stopping = false;
const streams = new Set();

fs.mkdirSync(SCREEN_DIR, { recursive: true });
fs.mkdirSync(STATE_DIR, { recursive: true });
fs.rmSync(STOPPED_FILE, { force: true });

// ===== 認証・Origin =====
const cookieName = () => `grill-visual-${port}`;
const sameKey = (a, b) => {
  const x = Buffer.from(String(a));
  const y = Buffer.from(String(b));
  return x.length === y.length && crypto.timingSafeEqual(x, y);
};
function cookieOf(req, name) {
  for (const part of String(req.headers.cookie || '').split(';')) {
    const i = part.indexOf('=');
    if (i > 0 && part.slice(0, i).trim() === name) return decodeURIComponent(part.slice(i + 1).trim());
  }
  return '';
}
// DNS rebinding で別名のページから叩かれないよう、Host と Origin は自分の 2 つの名前だけ通す
const allowedHosts = () => new Set([`127.0.0.1:${port}`, `localhost:${port}`]);
const hostOk = (req) => allowedHosts().has(String(req.headers.host || ''));
function originOk(req) {
  const origin = req.headers.origin;
  if (origin === undefined) return req.method === 'GET' || req.method === 'HEAD';
  return [...allowedHosts()].some((h) => origin === `http://${h}`);
}

// ===== 画面 =====
// 画面は screen_dir の直下の .html。いちばん新しい 1 枚だけを出す(同時刻なら名前の大きい方)
function newestScreen() {
  let best = null;
  for (const name of fs.readdirSync(SCREEN_DIR)) {
    if (!name.endsWith('.html')) continue;
    const file = path.join(SCREEN_DIR, name);
    let st;
    try { st = fs.statSync(file); } catch { continue; }
    if (!st.isFile()) continue;
    if (!best || st.mtimeMs > best.mtimeMs || (st.mtimeMs === best.mtimeMs && name > best.name)) best = { name, file, mtimeMs: st.mtimeMs };
  }
  return best;
}

const WAITING = '<h2>画面を待っています</h2><p class="subtitle">エージェントが次の画面を出すと、このページが切り替わります。</p>';
const isFullDocument = (html) => /^\s*<(!doctype|html)\b/i.test(html);

function scripts(screenFile, withUi) {
  const screen = JSON.stringify(screenFile || '').replace(/</g, '\\u003c');
  return `<script>window.GRILL_SCREEN = ${screen};</script>\n<script src="/_gv/client.js"></script>\n` +
    (withUi ? '<script src="/_gv/companion-ui.js"></script>\n' : '');
}
function render(screen) {
  const fragment = screen ? fs.readFileSync(screen.file, 'utf-8') : WAITING;
  if (screen && isFullDocument(fragment)) {
    const tag = scripts(screen.file, false);
    return /<\/body>/i.test(fragment) ? fragment.replace(/<\/body>/i, () => `${tag}</body>`) : fragment + tag;
  }
  const frame = fs.readFileSync(FRAME_FILE, 'utf-8');
  return frame
    .replace('<!-- CONTENT -->', () => fragment)
    .replace('</body>', () => `${scripts(screen && screen.file, true)}</body>`);
}

let shownName = null;
let shownSig = null;
function scan() {
  const screen = newestScreen();
  const sig = screen ? `${screen.name}:${screen.mtimeMs}` : null;
  if (sig === shownSig) return;
  const newScreen = (screen && screen.name) !== shownName;
  shownSig = sig;
  shownName = screen && screen.name;
  // 別の画面に移ったら、前の画面への操作の記録と指示文は捨てる(読み違えを避ける)
  if (newScreen) {
    fs.rmSync(EVENTS_FILE, { force: true });
    fs.rmSync(INSTRUCTION_FILE, { force: true });
  }
  for (const res of streams) res.write('event: reload\ndata: {}\n\n');
}

// ===== 応答 =====
function send(res, status, body, type = 'text/plain; charset=utf-8', extra = {}) {
  res.writeHead(status, { 'Content-Type': type, 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', ...extra });
  res.end(body);
}
const deny = (res, status, why) => send(res, status, `${why}\n`);

function readJson(req, res, then) {
  const chunks = [];
  let size = 0;
  req.on('data', (c) => {
    size += c.length;
    if (size > MAX_BODY) { deny(res, 413, 'too large'); req.destroy(); return; }
    chunks.push(c);
  });
  req.on('end', () => {
    if (res.writableEnded) return;
    let value;
    try { value = JSON.parse(Buffer.concat(chunks).toString('utf-8')); } catch { deny(res, 400, 'invalid json'); return; }
    if (!value || typeof value !== 'object' || Array.isArray(value)) { deny(res, 400, 'object expected'); return; }
    then(value);
  });
}

function serveFile(res, rel) {
  let decoded;
  try { decoded = decodeURIComponent(rel); } catch { return deny(res, 400, 'bad path'); }
  if (decoded.includes('\0')) return deny(res, 400, 'bad path');
  // symlink 経由で外へ出られないよう、実体のパスで screen_dir の内側かを確かめる
  let real;
  try { real = fs.realpathSync(path.resolve(SCREEN_DIR, decoded)); } catch { return deny(res, 404, 'not found'); }
  const root = fs.realpathSync(SCREEN_DIR);
  if (!real.startsWith(root + path.sep) || !fs.statSync(real).isFile()) return deny(res, 404, 'not found');
  send(res, 200, fs.readFileSync(real), MIME[path.extname(real).toLowerCase()] || 'application/octet-stream');
}

function handle(req, res) {
  if (!hostOk(req) || !originOk(req)) return deny(res, 403, 'forbidden');
  const url = new URL(req.url, `http://127.0.0.1:${port}`);

  // ?key= は初回の入口。cookie に移したうえでそのまま画面を返す(curl で 200 を確かめられるよう redirect しない)
  const keyed = req.method === 'GET' && url.pathname === '/' && url.searchParams.has('key');
  if (keyed && !sameKey(url.searchParams.get('key'), KEY)) return deny(res, 403, 'forbidden');
  if (keyed) {
    lastActivity = Date.now();
    return send(res, 200, render(newestScreen()), 'text/html; charset=utf-8', {
      'Set-Cookie': `${cookieName()}=${KEY}; Path=/; HttpOnly; SameSite=Strict`,
    });
  }
  if (!sameKey(cookieOf(req, cookieName()), KEY)) {
    return deny(res, 403, 'forbidden: 鍵付きの URL(?key=…)をそのまま開いてください');
  }
  lastActivity = Date.now();

  if (req.method === 'GET' && url.pathname === '/') return send(res, 200, render(newestScreen()), 'text/html; charset=utf-8');
  if (req.method === 'GET' && url.pathname.startsWith('/files/')) return serveFile(res, url.pathname.slice('/files/'.length));
  if (req.method === 'GET' && url.pathname.startsWith('/_gv/')) {
    const name = url.pathname.slice('/_gv/'.length);
    if (name === 'stream') {
      res.writeHead(200, { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store', Connection: 'keep-alive' });
      res.write(': connected\n\n');
      streams.add(res);
      req.on('close', () => streams.delete(res));
      return undefined;
    }
    if (CLIENT_SCRIPTS.has(name)) return send(res, 200, fs.readFileSync(path.join(__dirname, name)), MIME['.js']);
    return deny(res, 404, 'not found');
  }
  if (req.method === 'POST' && url.pathname === '/_gv/event') {
    return readJson(req, res, (event) => {
      if (typeof event.type !== 'string') return deny(res, 400, 'type required');
      fs.appendFileSync(EVENTS_FILE, `${JSON.stringify({ timestamp: Date.now(), ...event })}\n`);
      send(res, 204, '');
    });
  }
  if (req.method === 'POST' && url.pathname === '/_gv/instruction') {
    return readJson(req, res, ({ text }) => {
      if (typeof text !== 'string') return deny(res, 400, 'text required');
      // 読み手が書きかけを読まないよう、書いてから置き換える
      const tmp = `${INSTRUCTION_FILE}.tmp`;
      fs.writeFileSync(tmp, text.endsWith('\n') ? text : `${text}\n`);
      fs.renameSync(tmp, INSTRUCTION_FILE);
      send(res, 204, '');
    });
  }
  return deny(res, 404, 'not found');
}

// ===== 停止 =====
function shutdown(reason) {
  if (stopping) return;
  stopping = true;
  fs.writeFileSync(STOPPED_FILE, `${JSON.stringify({ type: 'server-stopped', reason })}\n`);
  fs.rmSync(INFO_FILE, { force: true });
  console.log(JSON.stringify({ type: 'server-stopped', reason }));
  for (const res of streams) res.end();
  server.close();
  setTimeout(() => process.exit(0), 200).unref();
}
const ownerPid = Number(process.env.GRILL_VISUAL_OWNER_PID) || null;
const alive = (pid) => {
  try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; }
};

const server = http.createServer((req, res) => {
  try { handle(req, res); } catch (e) { if (!res.headersSent) deny(res, 500, 'internal error'); }
});

server.on('error', (e) => {
  console.log(JSON.stringify({ error: `listen failed: ${e.message}` }));
  process.exit(1);
});

server.listen(0, '127.0.0.1', () => {
  port = server.address().port;
  const info = {
    type: 'server-started', pid: process.pid, port,
    url: `http://127.0.0.1:${port}/?key=${KEY}`, screen_dir: SCREEN_DIR, state_dir: STATE_DIR,
  };
  // 鍵を含むので本人だけが読めるようにする
  fs.writeFileSync(INFO_FILE, `${JSON.stringify(info)}\n`, { mode: 0o600 });
  console.log(JSON.stringify(info));
  scan();
  setInterval(scan, SCAN_MS).unref();
  // SSE がプロキシや OS に切られないよう、定期的にコメント行を流す
  setInterval(() => { for (const res of streams) res.write(': ping\n\n'); }, 15000).unref();
  setInterval(() => {
    if (ownerPid && !alive(ownerPid)) shutdown('owner process exited');
    else if (Date.now() - lastActivity > IDLE_MS) shutdown('idle timeout');
  }, CHECK_MS).unref();
});

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
