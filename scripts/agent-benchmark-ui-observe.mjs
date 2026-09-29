#!/usr/bin/env node
// Disposable browser observation for a checkout. The independent scorer's assertions are
// deliberately absent from this command.
//
// Runs inside the benchmark image (chromium on PATH, UI at /work/ui) and on a developer
// host (installed Chrome, UI defaulting to ./ui). It serves a *copy* of --ui, stubs the
// HTTP layer with test-fixtures.js, and writes dom.html + screenshot.png to --out. It
// never starts, stops or writes to the node, and never writes into --ui.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { spawn } from 'node:child_process';

// Which browser to render with: an explicit --chrome wins, then WA_CHROME, then the
// platform's standard install, then PATH - which is what the benchmark image provides.
function browserCandidates(opts) {
  const candidates = [];
  if (opts.chrome) candidates.push(opts.chrome);
  if (process.env.WA_CHROME) candidates.push(process.env.WA_CHROME);
  if (process.platform === 'win32') {
    for (const root of [process.env.PROGRAMFILES, process.env['PROGRAMFILES(X86)'],
      process.env.LOCALAPPDATA]) {
      if (root) candidates.push(path.join(root, 'Google', 'Chrome', 'Application', 'chrome.exe'));
    }
  }
  candidates.push('chromium', 'chromium-browser', 'google-chrome', 'google-chrome-stable', 'chrome');
  return [...new Set(candidates)];
}

function escapeRegExp(text) { return text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); }

function argumentsFrom(argv) {
  const opts = { fixtures: true, require: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--ui' || arg === '--probe' || arg === '--out' || arg === '--chrome') {
      opts[arg.slice(2)] = argv[++i];
    } else if (arg === '--require') {
      opts.require.push(argv[++i]);
    } else if (arg === '--no-fixtures') {
      opts.fixtures = false;
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }
  // Default to the checkout the caller is standing in, so a worker renders its own
  // files rather than the installed copy. The benchmark image has no ./ui, so it keeps
  // the path its Dockerfile documents.
  if (!opts.ui) opts.ui = fs.existsSync('ui') ? 'ui' : '/work/ui';
  return opts;
}

// Try each candidate until one actually starts. A missing binary is a launch failure and
// the next candidate is tried; a browser that ran and exited badly is the verdict itself
// and must not be re-run against another candidate.
async function runBrowser(candidates, args, browserLog, browserHome) {
  let last = null;
  for (const candidate of candidates) {
    const child = spawn(candidate, args, {
      stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...process.env, HOME: browserHome, XDG_CACHE_HOME: browserHome },
      windowsHide: true,
    });
    const chunks = [];
    let size = 0;
    child.stdout.on('data', chunk => {
      size += chunk.length;
      if (size <= 16 * 1024 * 1024) chunks.push(chunk);
      else child.kill();
    });
    const errors = fs.createWriteStream(browserLog, { flags: 'a' });
    child.stderr.pipe(errors);
    const timer = setTimeout(() => child.kill(), 120000);
    const outcome = await new Promise(resolve => {
      child.once('error', error => resolve({ status: null, signal: null, error }));
      child.once('close', (status, signal) => resolve({ status, signal, error: null }));
    });
    clearTimeout(timer);
    errors.end();
    last = { ...outcome, command: candidate, dom: Buffer.concat(chunks) };
    if (!(outcome.error && outcome.error.code === 'ENOENT')) break;
  }
  return last;
}

function contentType(file) {
  return { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css',
    '.json': 'application/json', '.wasm': 'application/wasm', '.png': 'image/png',
  }[path.extname(file)] || 'application/octet-stream';
}

async function main() {
  const opts = argumentsFrom(process.argv.slice(2));
  const ui = path.resolve(opts.ui);
  if (!fs.existsSync(path.join(ui, 'index.html'))) throw new Error(`no UI index at ${ui}`);
  const out = opts.out ? path.resolve(opts.out) : fs.mkdtempSync(path.join(os.tmpdir(), 'wa-ui-observe-'));
  // The observer only ever reads --ui and writes into --out; refuse the one shape that
  // would put its stage, profile and screenshot back inside the tree it is observing.
  if (out === ui || out.startsWith(ui + path.sep)) {
    throw new Error(`--out must be outside --ui: ${out} is inside ${ui}`);
  }
  fs.mkdirSync(out, { recursive: true });
  const stage = path.join(out, 'stage');
  const profile = path.join(out, 'browser-profile');
  const browserHome = path.join(out, 'browser-home');
  fs.mkdirSync(browserHome, { recursive: true });
  fs.cpSync(ui, stage, { recursive: true });
  let html = fs.readFileSync(path.join(stage, 'index.html'), 'utf8');
  if (opts.fixtures && fs.existsSync(path.join(stage, 'test-fixtures.js'))) {
    const marker = '<script src="app.js"></script>';
    if (!html.includes(marker)) throw new Error('app.js script marker absent');
    html = html.replace(marker, '<script src="test-fixtures.js"></script>\n' + marker);
  }
  if (opts.probe) {
    const probe = path.resolve(opts.probe);
    if (!fs.statSync(probe).isFile()) throw new Error(`probe is not a file: ${probe}`);
    fs.copyFileSync(probe, path.join(stage, 'wa-observe-probe.js'));
    if (!html.includes('</body>')) throw new Error('UI body end marker absent');
    html = html.replace('</body>', '<script src="wa-observe-probe.js"></script>\n</body>');
  }
  fs.writeFileSync(path.join(stage, 'index.html'), html);

  const server = http.createServer((request, response) => {
    let pathname;
    try { pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname); }
    catch { response.writeHead(400).end(); return; }
    const file = path.resolve(stage, '.' + (pathname === '/' ? '/index.html' : pathname));
    if (file !== stage && !file.startsWith(stage + path.sep)) {
      response.writeHead(403).end(); return;
    }
    fs.readFile(file, (error, bytes) => {
      if (error) { response.writeHead(404).end(); return; }
      response.writeHead(200, { 'content-type': contentType(file) });
      response.end(bytes);
    });
  });
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const url = `http://127.0.0.1:${server.address().port}/`;
  const dom = path.join(out, 'dom.html');
  const screenshot = path.join(out, 'screenshot.png');
  const browserLog = path.join(out, 'browser.log');
  let browser;
  try {
    const args = ['--headless=new', '--no-sandbox', '--disable-gpu',
      '--disable-dev-shm-usage', '--virtual-time-budget=10000', '--hide-scrollbars',
      `--user-data-dir=${profile}`, '--window-size=1280,900',
      `--screenshot=${screenshot}`, '--dump-dom', url];
    browser = await runBrowser(browserCandidates(opts), args, browserLog, browserHome);
    fs.writeFileSync(dom, browser.dom);
  } finally {
    await new Promise(resolve => server.close(resolve));
    // Only the observation's own disposable browser state is removed here.
    for (const dir of [stage, profile, browserHome]) {
      if (path.dirname(path.resolve(dir)) !== path.resolve(out)) throw new Error('unsafe UI observation cleanup');
      fs.rmSync(dir, { recursive: true, force: true });
    }
  }
  const page = fs.readFileSync(dom, 'utf8');
  const probe = page.match(/<pre\b(?=[^>]*\bid="wa-probe")(?=[^>]*\bdata-status="([^"]+)")[^>]*>([\s\S]*?)<\/pre>/);
  const status = opts.probe ? (probe?.[1] || 'missing') : 'not-requested';
  // "It rendered" is checked, not assumed. A wrong --ui, a 404 or a page that navigated
  // away all still exit 0 and still write a screenshot; a blank screenshot read as
  // success is worse than no screenshot at all.
  const title = html.match(/<title[^>]*>([\s\S]*?)<\/title>/i);
  const markers = [];
  if (title) markers.push({ kind: 'title', text: title[1].trim() });
  for (const text of opts.require) markers.push({ kind: 'require', text });
  const missing = markers
    .filter(marker => (marker.kind === 'title'
      ? !new RegExp(`<title[^>]*>\\s*${escapeRegExp(marker.text)}\\s*<\\/title>`, 'i').test(page)
      : !page.includes(marker.text)))
    .map(marker => marker.text);
  const renderError = missing.length
    ? `page did not render: missing ${missing.map(text => JSON.stringify(text)).join(', ')}` : null;
  const probeError = opts.probe && status !== 'pass' ? `probe ${status}` : null;
  const result = { ok: !browser.error && browser.status === 0 && fs.existsSync(screenshot)
    && !renderError && !probeError, browser: browser.command, ui,
    browserExit: browser.status,
    browserSignal: browser.signal || null, browserError: browser.error?.message || null,
    probeStatus: status, probeText: probe?.[2]?.slice(0, 2000) || null,
    requiredMarkers: markers.map(marker => marker.text), missingMarkers: missing,
    renderError, probeError,
    dom, screenshot, browserLog };
  console.log(JSON.stringify(result));
  if (!result.ok) process.exitCode = 1;
}

main().catch(error => {
  console.error(JSON.stringify({ ok: false, error: error.message }));
  process.exitCode = 1;
});
