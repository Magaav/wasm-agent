#!/usr/bin/env node
// A copy of `ui/` served to a browser, driven by one probe, with no node and no installed UI involved.
//
//   node review/ui-residues/probe-runner.mjs review/ui-residues/probe-incident.js [--budget 60000]
//
// Why this exists rather than another `scripts/test-ui.ps1` run: that harness's browser is launched with a
// 10-second virtual-time budget, and its checks are driven through the one seam the delivery added
// (`window.__watchNow`). The claim under review is about the *timer* as well - the watchdog asks /health
// after 30 seconds of silence - so this runner lets a probe hold a stream, load fixture answers and be
// given a virtual-time budget long enough for the real interval to fire, and it can see whether virtual
// time advanced at all (a probe that reports no ticks is an inconclusive run, not a passed check).
//
// What it stages: `ui/*` copied to a temp directory, `ui/test-fixtures.js` as `fixtures.js` loaded before
// app.js, one line appended to app.js exposing the decision to the probe (the same seam the delivered
// harness uses), and the probe script before `</body>`. Nothing outside the temp directory is written.
import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, '..', '..');
const args = process.argv.slice(2);
const probeArg = args.find((arg) => !arg.startsWith('--'));
const flag = (name, fallback) => {
  const index = args.indexOf(`--${name}`);
  return index < 0 ? fallback : args[index + 1];
};
if (!probeArg) {
  console.error('usage: probe-runner.mjs <probe.js> [--budget ms] [--ui dir] [--screenshot file] [--keep]');
  process.exit(2);
}
const uiDir = flag('ui', path.join(repo, 'ui'));
const budget = Number(flag('budget', '60000'));
const screenshot = flag('screenshot', null);
const keep = args.includes('--keep');

const copy = ['index.html', 'style.css', 'app.js', 'components.js', 'render.wasm', 'manifest.webmanifest', 'service-worker.js', 'icon-192.png', 'icon-512.png'];
const stage = fs.mkdtempSync(path.join(os.tmpdir(), 'wa-probe-'));
for (const name of copy) fs.copyFileSync(path.join(uiDir, name), path.join(stage, name));
fs.writeFileSync(path.join(stage, 'fixtures.js'), fs.readFileSync(path.join(repo, 'ui', 'test-fixtures.js')));

// The same three lines the delivered harness injects: no default session, fixtures first, and the
// decision exposed for a probe. Kept identical so the probe measures the delivered code, not a variant.
const app = fs.readFileSync(path.join(stage, 'app.js'), 'utf8');
fs.writeFileSync(path.join(stage, 'app.js'), app
  + `\nwindow.__watchNow = () => checkWatchedRun && checkWatchedRun(); window.__runStanding = runStanding;`
  + `\nwindow.__chatThread = () => chatSession; window.__send = send; window.__handleEvent = handleEvent; window.__stopLiveness = stopLiveness;`
  + `\nwindow.__setNodeHealth = (body) => { window.__fixtures.health = body; };`
  + `\nwindow.__refreshPane = refreshAgentPane; window.__setPaneRows = rows => { paneMessages = async () => ({rows}); };`);
let html = fs.readFileSync(path.join(stage, 'index.html'), 'utf8');
if (!html.includes('<script src="app.js"></script>')) throw Error('index.html does not load app.js the way this staging expects');
html = html.replace('<script src="app.js"></script>',
  '<script>window.__waNoDefaultSession = true;'
  + 'try { localStorage.setItem("wa-chat-session", "aaaaaaaa-0000-0000-0000-000000000001");'
  + ' localStorage.setItem("wa-session", "probe-session"); } catch (error) {}</script>\n'
  + '<script src="fixtures.js"></script>\n<script src="app.js"></script>');
const probe = fs.readFileSync(path.resolve(probeArg), 'utf8');
if (/<\/script/i.test(probe)) throw Error('the probe must not contain a closing script tag');
html = html.replace('</body>', `<script>\n${probe}\n</script>\n</body>`);
fs.writeFileSync(path.join(stage, 'index.html'), html);

const mime = {'.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.wasm': 'application/wasm', '.png': 'image/png', '.json': 'application/json', '.webmanifest': 'application/manifest+json'};
const server = http.createServer((request, response) => {
  const name = decodeURIComponent(request.url.split('?')[0]).replace(/^\/+/, '') || 'index.html';
  const file = path.join(stage, name);
  if (!file.startsWith(stage) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
    response.writeHead(404).end('not found');
    return;
  }
  response.writeHead(200, {'content-type': mime[path.extname(file)] || 'application/octet-stream'});
  response.end(fs.readFileSync(file));
});

const freePort = () => new Promise((resolve, reject) => {
  const socket = net.createServer();
  socket.once('error', reject);
  socket.listen(0, '127.0.0.1', () => {
    const {port} = socket.address();
    socket.close(() => resolve(port));
  });
});
// Edge first, exactly as scripts/test-ui.ps1 chooses: that is the browser the delivered suite proved
// itself on in this environment. Never a browser without --headless=new: this machine has a live Chrome
// session, and a bare `chrome.exe` argument opens a tab in it.
const candidates = [
  'C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe',
  'C:/Program Files/Microsoft/Edge/Application/msedge.exe',
  'C:/Program Files/Google/Chrome/Application/chrome.exe',
  'C:/Program Files (x86)/Google/Chrome/Application/chrome.exe',
];
const browser = candidates.find((candidate) => fs.existsSync(candidate));
if (!browser) { console.error('no Chrome or Edge found'); process.exit(1); }

const port = await freePort();
await new Promise((resolve) => server.listen(port, '127.0.0.1', resolve));
const url = `http://127.0.0.1:${port}/`;
const chromeArgs = ['--headless=new', '--disable-gpu', '--no-first-run', '--disable-extensions', '--window-size=900,700',
  `--user-data-dir=${path.join(stage, 'profile')}`, `--virtual-time-budget=${budget}`, '--dump-dom', url];
if (screenshot) chromeArgs.splice(chromeArgs.length - 2, 0, `--screenshot=${path.resolve(screenshot)}`);
const child = spawn(browser, chromeArgs, {stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true});
let out = '', err = '';
child.stdout.on('data', (chunk) => { out += chunk; });
child.stderr.on('data', (chunk) => { err += chunk; });
const exit = await new Promise((resolve) => child.on('close', resolve));

const pre = out.match(/<pre\b(?=[^>]*\bid="wa-probe")[^>]*>([\s\S]*?)<\/pre>/);
const unescape = (text) => text.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"').replace(/&amp;/g, '&');
console.log(`stage ${stage}  browser ${path.basename(browser)}  exit ${exit}  dom ${out.length} bytes`);
if (!pre) {
  console.log('PROBE MISSING - the page did not write #wa-probe. This is an inconclusive run, not a pass.');
  console.log(out.slice(0, 2000));
} else {
  const text = unescape(pre[1]).trim();
  console.log('---- probe result ----');
  try { console.log(JSON.stringify(JSON.parse(text), null, 2)); }
  catch (error) { console.log(text); }
}
if (err.trim()) console.log(`---- browser stderr (first 800 chars) ----\n${err.slice(0, 800)}`);
if (!keep) fs.rmSync(stage, {recursive: true, force: true});
else console.log(`kept: ${stage}`);
// The listening server is the last thing holding the event loop; close it and go, so a finished probe exits.
server.close();
process.exit(exit===0 && pre && /id="wa-probe"[^>]*data-status="pass"/.test(out) ? 0 : 1);
