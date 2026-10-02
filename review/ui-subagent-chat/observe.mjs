#!/usr/bin/env node
// Reviewer's own headless observer for the orchestrator UI.
//
// Why not scripts/agent-benchmark-ui-observe.mjs: it hardcodes --window-size=1280,900 and the review
// has to also run a SMALL viewport (claim 1). Everything else it does, this does too, and for the same
// reason: a *copy* of ui/ is staged, ui/test-fixtures.js stubs the HTTP layer, the probe is injected
// last, and nothing is ever written into ui/ or into the served UI directory.
//
// The staged app.js gets the same window-level hooks scripts/test-ui.ps1 appends to its own temp copy
// (`__refreshOrchestrator`, `__repaintMessages`, `__paintChildTranscript`), because the app keeps
// module scope and a probe has to drive the real entry points. Only the temp copy is touched.
//
// Usage:
//   node review/ui-subagent-chat/observe.mjs --ui <dir> --probe <file> --out <dir>
//        [--window 1280x900] [--query "?view=orchestrator"] [--allow-fail] [--require <text>]
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import {spawn} from 'node:child_process';

const opts = {window: '1280x900', query: '?view=orchestrator', allowFail: false, require: [],
  headless: 'new', vt: '20000', scale: ''};
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i += 1) {
  const a = argv[i];
  if (a === '--ui' || a === '--probe' || a === '--out' || a === '--window' || a === '--query'
      || a === '--headless' || a === '--vt' || a === '--scale') opts[a.slice(2)] = argv[++i];
  else if (a === '--require') opts.require.push(argv[++i]);
  else if (a === '--allow-fail') opts.allowFail = true;
  else throw new Error(`unknown argument: ${a}`);
}
if (!opts.ui || !opts.probe || !opts.out) throw new Error('--ui, --probe and --out are required');

const TYPES = {'.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript',
  '.css': 'text/css', '.png': 'image/png', '.wasm': 'application/wasm', '.json': 'application/json',
  '.webmanifest': 'application/manifest+json', '.svg': 'image/svg+xml', '.ico': 'image/x-icon'};

function browsers() {
  const list = [];
  if (process.env.WA_CHROME) list.push(process.env.WA_CHROME);
  for (const root of [process.env['PROGRAMFILES(X86)'], process.env.PROGRAMFILES, process.env.LOCALAPPDATA]) {
    if (root) list.push(path.join(root, 'Microsoft', 'Edge', 'Application', 'msedge.exe'));
    if (root) list.push(path.join(root, 'Google', 'Chrome', 'Application', 'chrome.exe'));
  }
  list.push('chromium', 'google-chrome', 'chrome');
  return list.filter(p => p.includes(path.sep) ? fs.existsSync(p) : true);
}

const ui = path.resolve(opts.ui);
if (!fs.existsSync(path.join(ui, 'index.html'))) throw new Error(`no index.html in ${ui}`);
const out = path.resolve(opts.out);
fs.mkdirSync(out, {recursive: true});
const stage = path.join(out, 'stage');
const profile = path.join(out, 'profile');
fs.rmSync(stage, {recursive: true, force: true});
fs.cpSync(ui, stage, {recursive: true});

// WS-aware backslash escape, so a probe stays readable while still being valid JS.
function esc(text) { return text.replace(/\\/g, '\\\\').replace(/'/g, "\\'").replace(/\r?\n/g, '\\n'); }

let html = fs.readFileSync(path.join(stage, 'index.html'), 'utf8');
const marker = '<script src="app.js"></script>';
if (!html.includes(marker)) throw new Error('app.js script marker absent');
if (fs.existsSync(path.join(stage, 'test-fixtures.js'))) {
  html = html.replace(marker, '<script src="test-fixtures.js"></script>\n' + marker);
}
const probeSource = fs.readFileSync(path.resolve(opts.probe), 'utf8');
fs.writeFileSync(path.join(stage, 'wa-review-probe.js'), probeSource);
if (!html.includes('</body>')) throw new Error('body end marker absent');
html = html.replace('</body>', '<script src="wa-review-probe.js"></script>\n</body>');
fs.writeFileSync(path.join(stage, 'index.html'), html);

const exposure = "window.__refreshOrchestrator = refreshOrchestrator; window.__repaintMessages = repaintMessages;"
  + " window.__paintChildTranscript = paintChildTranscript; window.__laneFacts = {tasks:null};\n";
fs.appendFileSync(path.join(stage, 'app.js'), '\n' + exposure);

const server = http.createServer((request, response) => {
  let pathname;
  try { pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname); }
  catch { response.writeHead(400).end(); return; }
  // A real (non-virtualized) delay: virtual time pauses while a resource load is pending, which is the
  // only way to let the browser apply --window-size before the probe measures the layout.
  if (pathname === '/_slow') {
    const ms = Number(new URL(request.url, 'http://localhost').searchParams.get('ms') || 250);
    setTimeout(() => { response.writeHead(200, {'content-type': 'text/plain'}); response.end('slow'); }, ms);
    return;
  }
  const file = path.resolve(stage, '.' + (pathname === '/' ? '/index.html' : pathname));
  if (file !== stage && !file.startsWith(stage + path.sep)) { response.writeHead(403).end(); return; }
  fs.readFile(file, (error, bytes) => {
    if (error) { response.writeHead(404).end(); return; }
    response.writeHead(200, {'content-type': TYPES[path.extname(file)] || 'application/octet-stream'});
    response.end(bytes);
  });
});
await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
const url = `http://127.0.0.1:${server.address().port}/${opts.query}`;

const screenshot = path.join(out, 'screenshot.png');
const dom = path.join(out, 'dom.html');
const browserLog = path.join(out, 'browser.log');
fs.rmSync(profile, {recursive: true, force: true});

function launch(command, args) {
  return new Promise(resolve => {
    const child = spawn(command, args, {stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true,
      env: {...process.env, HOME: profile, XDG_CACHE_HOME: profile}});
    const chunks = [];
    child.stdout.on('data', chunk => { if (chunks.reduce((n, c) => n + c.length, 0) < 64 * 1024 * 1024) chunks.push(chunk); });
    const errors = fs.createWriteStream(browserLog, {flags: 'a'});
    child.stderr.pipe(errors);
    const timer = setTimeout(() => child.kill(), 180000);
    child.once('error', error => { clearTimeout(timer); errors.end(); resolve({error, status: null, output: ''}); });
    child.once('close', status => { clearTimeout(timer); errors.end(); resolve({error: null, status, output: Buffer.concat(chunks).toString('utf8')}); });
  });
}

let result;
try {
  const args = [`--headless=${opts.headless}`, '--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage',
    '--hide-scrollbars', `--window-size=${opts.window}`,
    ...(opts.scale ? [`--force-device-scale-factor=${opts.scale}`] : []),
    ...(opts.vt && opts.vt !== '0' ? [`--virtual-time-budget=${opts.vt}`] : []),
    `--user-data-dir=${profile}`, `--screenshot=${screenshot}`, '--dump-dom', url];
  let chosen = null;
  for (const candidate of browsers()) {
    const attempt = await launch(candidate, args);
    if (!attempt.error) { chosen = {candidate, attempt}; break; }
    if (fs.existsSync(screenshot)) fs.rmSync(screenshot);
  }
  if (!chosen) throw new Error('no Chromium/Edge/Chrome binary could be launched');
  fs.writeFileSync(dom, chosen.attempt.output);
  const page = fs.readFileSync(dom, 'utf8');
  const match = page.match(/<pre\b(?=[^>]*\bid="wa-probe")(?=[^>]*\bdata-status="([^"]+)")[^>]*>([\s\S]*?)<\/pre>/);
  const status = match?.[1] || 'missing';
  const missing = opts.require.filter(text => !page.includes(text));
  result = {browser: chosen.candidate, browserExit: chosen.attempt.status, window: opts.window,
    query: opts.query, url, probeStatus: status, missingRequired: missing,
    screenshot: fs.existsSync(screenshot) ? screenshot : null, dom,
    probeText: match?.[2] || null};
  result.ok = chosen.attempt.status === 0 && fs.existsSync(screenshot) && missing.length === 0
    && (opts.allowFail || status === 'pass');
} finally {
  await new Promise(resolve => server.close(resolve));
}
console.log(JSON.stringify(result, null, 2));
if (!result.ok) process.exitCode = 1;
