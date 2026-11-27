// grill-visual のサーバーを実際に起動して HTTP で確かめる。
// 実行: bun test tests/grill-visual
import { afterAll, beforeAll, describe, expect, test } from 'bun:test';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const scripts = path.resolve(import.meta.dir, '../../skills/grill-visual/scripts');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'gv-test-'));
const sessionDir = path.join(tmp, 'session');
const outside = path.join(tmp, 'secret.txt');
let child;
let info;
let base;
let cookie;

const screens = () => path.join(sessionDir, 'content');
const state = (name) => path.join(sessionDir, 'state', name);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function until(fn, ms = 4000) {
  const end = Date.now() + ms;
  while (Date.now() < end) { const v = await fn(); if (v) return v; await sleep(50); }
  throw new Error('timeout');
}
const asBrowser = (extra = {}) => ({ headers: { cookie, ...extra } });
const post = (url, body, headers = {}) => fetch(base + url, {
  method: 'POST', headers: { cookie, origin: base, 'content-type': 'application/json', ...headers }, body: JSON.stringify(body),
});

function startServer(env, dir) {
  const p = spawn('node', [path.join(scripts, 'serve.cjs')], {
    env: { ...process.env, GRILL_VISUAL_DIR: dir, GRILL_VISUAL_SCAN_MS: '50', GRILL_VISUAL_CHECK_MS: '100', ...env },
    stdio: ['ignore', 'pipe', 'inherit'],
  });
  const first = new Promise((resolve) => {
    let buf = '';
    p.stdout.on('data', (d) => { buf += d; if (buf.includes('\n')) resolve(JSON.parse(buf.split('\n')[0])); });
  });
  return { p, first };
}

beforeAll(async () => {
  fs.writeFileSync(outside, 'SECRET');
  const s = startServer({}, sessionDir);
  child = s.p;
  info = await s.first;
  base = `http://127.0.0.1:${info.port}`;
  const r = await fetch(info.url);
  cookie = r.headers.get('set-cookie').split(';')[0];
});
afterAll(() => { child.kill(); fs.rmSync(tmp, { recursive: true, force: true }); });

describe('起動の返り値', () => {
  test('url・screen_dir・state_dir を返し、127.0.0.1 の鍵付き URL になる', () => {
    expect(info.url).toMatch(/^http:\/\/127\.0\.0\.1:\d+\/\?key=[0-9a-f]{32}$/);
    expect(info.screen_dir).toBe(screens());
    expect(info.state_dir).toBe(path.join(sessionDir, 'state'));
  });
});

describe('認証', () => {
  test('鍵も cookie もなければ 403', async () => {
    expect((await fetch(base + '/')).status).toBe(403);
    expect((await fetch(base + '/?key=wrong')).status).toBe(403);
  });
  test('鍵付きの URL は 200 で、cookie(HttpOnly)に鍵を移す', async () => {
    const r = await fetch(info.url);
    expect(r.status).toBe(200);
    expect(r.headers.get('set-cookie')).toContain('HttpOnly');
  });
  test('cookie があれば 200(画面が無い間は待機の文面)', async () => {
    const r = await fetch(base + '/', asBrowser());
    expect(r.status).toBe(200);
    expect(await r.text()).toContain('画面を待っています');
  });
  test('別の Host 名(DNS rebinding)は 403', async () => {
    const r = await fetch(base + '/', asBrowser({ host: 'evil.example' }));
    expect(r.status).toBe(403);
  });
});

describe('画面', () => {
  test('断片は frame で包み、script を差し込む', async () => {
    fs.writeFileSync(path.join(screens(), 'a.html'), '<h2>案を選ぶ</h2>');
    await until(async () => (await (await fetch(base + '/', asBrowser())).text()).includes('案を選ぶ'));
    const html = await (await fetch(base + '/', asBrowser())).text();
    expect(html).toContain('id="frame-content"');
    expect(html).toContain('/_gv/companion-ui.js');
    expect(html).toContain(path.join(screens(), 'a.html'));
  });
  test('<html> で始まる完全な文書は包まない', async () => {
    fs.writeFileSync(path.join(screens(), 'full.html'), '<!doctype html><html><body><p>全体</p></body></html>');
    await until(async () => (await (await fetch(base + '/', asBrowser())).text()).includes('<p>全体</p>'));
    const html = await (await fetch(base + '/', asBrowser())).text();
    expect(html).not.toContain('frame-content');
    expect(html).toContain('/_gv/client.js');
  });
});

describe('画面の追加で SSE に reload が届く', () => {
  test('新しい画面ファイルを置くと reload を push する', async () => {
    const res = await fetch(base + '/_gv/stream', asBrowser());
    const reader = res.body.getReader();
    await reader.read(); // ": connected"
    fs.writeFileSync(path.join(screens(), 'b.html'), '<h2>次</h2>');
    let text = '';
    const end = Date.now() + 4000;
    while (!text.includes('event: reload') && Date.now() < end) {
      const { value } = await reader.read();
      text += new TextDecoder().decode(value);
    }
    expect(text).toContain('event: reload');
    await reader.cancel();
  });
  test('別の画面に移ると前の events と instruction.md は消える', async () => {
    await post('/_gv/event', { type: 'click', choice: 'a' });
    await post('/_gv/instruction', { text: '古い指示' });
    fs.writeFileSync(path.join(screens(), 'c.html'), '<h2>さらに次</h2>');
    await until(() => !fs.existsSync(state('events')) && !fs.existsSync(state('instruction.md')));
  });
});

describe('events と instruction.md', () => {
  test('POST したイベントが JSONL で追記される', async () => {
    expect((await post('/_gv/event', { type: 'click', choice: 'a', text: 'A' })).status).toBe(204);
    await post('/_gv/event', { type: 'click', choice: 'b', text: 'B' });
    const lines = fs.readFileSync(state('events'), 'utf-8').trim().split('\n').map((l) => JSON.parse(l));
    expect(lines.map((l) => l.choice)).toEqual(['a', 'b']);
    expect(typeof lines[0].timestamp).toBe('number');
  });
  test('指示文は instruction.md に最新の 1 本として書かれる', async () => {
    await post('/_gv/instruction', { screen: 'x', text: '1 本目' });
    await post('/_gv/instruction', { screen: 'x', text: '2 本目' });
    expect(fs.readFileSync(state('instruction.md'), 'utf-8').trim()).toBe('2 本目');
  });
  test('壊れた body は 400', async () => {
    const r = await fetch(base + '/_gv/event', { method: 'POST', headers: { cookie, origin: base }, body: 'not json' });
    expect(r.status).toBe(400);
  });
  test('別の Origin、または Origin の無い POST は拒否し、何も書かない', async () => {
    const before = fs.readFileSync(state('events'), 'utf-8');
    const evil = await post('/_gv/event', { type: 'x' }, { origin: 'http://evil.example' });
    const none = await fetch(base + '/_gv/event', { method: 'POST', headers: { cookie }, body: '{"type":"x"}' });
    expect(evil.status).toBe(403);
    expect(none.status).toBe(403);
    expect(fs.readFileSync(state('events'), 'utf-8')).toBe(before);
  });
  test('cookie の無い POST は 403', async () => {
    const r = await fetch(base + '/_gv/event', { method: 'POST', headers: { origin: base }, body: '{"type":"x"}' });
    expect(r.status).toBe(403);
  });
});

describe('/files と配る script', () => {
  test('screen_dir の中のファイルは読める', async () => {
    fs.writeFileSync(path.join(screens(), 'pic.svg'), '<svg xmlns="http://www.w3.org/2000/svg"/>');
    const r = await fetch(base + '/files/pic.svg', asBrowser());
    expect(r.status).toBe(200);
    expect(r.headers.get('content-type')).toContain('image/svg+xml');
  });
  test('screen_dir の外は読めない(.. も、エンコードした .. も)', async () => {
    for (const p of ['/files/../../secret.txt', '/files/..%2f..%2fsecret.txt', '/files/%2e%2e/%2e%2e/secret.txt']) {
      const r = await fetch(new URL(p, base), asBrowser());
      expect([400, 403, 404]).toContain(r.status);
      expect(await r.text()).not.toContain('SECRET');
    }
  });
  test('外を指す symlink 経由でも読めない', async () => {
    fs.symlinkSync(outside, path.join(screens(), 'link.txt'));
    const r = await fetch(base + '/files/link.txt', asBrowser());
    expect(r.status).toBe(404);
  });
  test('配る script は決まった 2 つだけ', async () => {
    expect((await fetch(base + '/_gv/client.js', asBrowser())).status).toBe(200);
    expect((await fetch(base + '/_gv/companion-ui.js', asBrowser())).status).toBe(200);
    expect((await fetch(base + '/_gv/serve.cjs', asBrowser())).status).toBe(404);
  });
});

describe('自動停止', () => {
  test('起動元のプロセスが消えると止まる', async () => {
    const owner = spawn('sleep', ['60']);
    const dir = path.join(tmp, 'owner');
    const s = startServer({ GRILL_VISUAL_OWNER_PID: String(owner.pid) }, dir);
    await s.first;
    const exited = new Promise((r) => s.p.on('exit', r));
    owner.kill();
    await Promise.race([exited, sleep(4000).then(() => { throw new Error('止まらない'); })]);
    expect(fs.readFileSync(path.join(dir, 'state', 'server-stopped'), 'utf-8')).toContain('owner process exited');
  });
  test('操作が無いまま時間がたつと止まる', async () => {
    const dir = path.join(tmp, 'idle');
    const s = startServer({ GRILL_VISUAL_IDLE_MINUTES: '0.002' }, dir);
    await s.first;
    const exited = new Promise((r) => s.p.on('exit', r));
    await Promise.race([exited, sleep(4000).then(() => { throw new Error('止まらない'); })]);
    expect(fs.readFileSync(path.join(dir, 'state', 'server-stopped'), 'utf-8')).toContain('idle timeout');
  });
});

describe('起動・停止スクリプト', () => {
  test('起動 → 200 → 停止。失敗時は error JSON', async () => {
    const proj = path.join(tmp, 'proj');
    fs.mkdirSync(proj);
    const run = (file, ...args) => Bun.spawnSync(['bash', path.join(scripts, file), ...args], { env: process.env });
    const started = JSON.parse(run('start.sh', '--project-dir', proj).stdout.toString());
    expect(started.url).toContain('?key=');
    expect(started.screen_dir.startsWith(path.join(proj, '.grill-visual'))).toBe(true);
    expect((await fetch(started.url)).status).toBe(200);
    const stopped = JSON.parse(run('stop.sh', path.dirname(started.state_dir)).stdout.toString());
    expect(stopped.status).toBe('stopped');
    await until(async () => fetch(started.url).then(() => false, () => true));
    expect(fs.existsSync(started.screen_dir)).toBe(true);

    const bad = run('start.sh', '--project-dir', path.join(tmp, 'nope'));
    expect(bad.exitCode).toBe(1);
    expect(JSON.parse(bad.stdout.toString()).error).toContain('存在しません');
  });
});
