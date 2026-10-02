#!/usr/bin/env node
// The reviewer's own observation runner for delivery change/ui-action-row-binding.
//
// It serves a *copy* of --ui (never the running node's directory, never the installed
// UI) with the repository's own fixtures injected, runs a real headless Chrome at a
// chosen viewport, and writes dom.html + screenshot.png into --out. The probe is a file
// of mine, injected as a classic script after app.js, and it must write
// <pre id="wa-probe" data-status="pass|fail">.
//
// Deliberately not the producer's instrument (scripts/agent-benchmark-ui-observe.mjs):
// that one has a fixed viewport and no way to choose a query string, and the point of
// this review is an independent measurement, not a rerun of theirs.
//
// usage: node run.mjs --ui <dir> --probe <file> [--query "?view=inspect"]
//                     [--size 1280x900] [--out <dir>] [--tag label]
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { spawn } from 'node:child_process';

function opts(argv) {
  const out = { size: '1280x900', query: '', tag: '' };
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i];
    if (key === '--ui' || key === '--probe' || key === '--out' || key === '--size' ||
        key === '--query' || key === '--tag' || key === '--chrome') {
      out[key.slice(2)] = argv[++i];
    } else throw new Error(`unknown argument: ${key}`);
  }
  if (!out.ui || !out.probe) throw new Error('--ui and --probe are required');
  return out;
}

function findChrome(explicit) {
  const list = [];
  if (explicit) list.push(explicit);
  if (process.env.WA_CHROME) list.push(process.env.WA_CHROME);
  for (const root of [process.env.PROGRAMFILES, process.env['PROGRAMFILES(X86)'], process.env.LOCALAPPDATA]) {
    if (root) list.push(path.join(root, 'Google', 'Chrome', 'Application', 'chrome.exe'));
  }
  list.push('chromium', 'google-chrome', 'chrome');
  return list;
}

function typeOf(file) {
  return { '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css',
    '.json': 'application/json', '.wasm': 'application/wasm', '.png': 'image/png',
    '.svg': 'image/svg+xml' }[path.extname(file)] || 'application/octet-stream';
}

async function main() {
  const o = opts(process.argv.slice(2));
  const ui = path.resolve(o.ui);
  const probeFile = path.resolve(o.probe);
  if (!fs.existsSync(path.join(ui, 'index.html'))) throw new Error(`no index.html in ${ui}`);
  if (!fs.statSync(probeFile).isFile()) throw new Error(`no probe at ${probeFile}`);
  const out = path.resolve(o.out || fs.mkdtempSync(path.join(os.tmpdir(), 'wa-review-')));
  if (out === ui || out.startsWith(ui + path.sep)) throw new Error(`--out inside --ui: ${out}`);
  fs.mkdirSync(out, { recursive: true });

  const stage = path.join(out, 'stage');
  const profile = path.join(out, 'profile');
  fs.cpSync(ui, stage, { recursive: true });
  let html = fs.readFileSync(path.join(stage, 'index.html'), 'utf8');
  const marker = '<script src="app.js"></script>';
  if (!html.includes(marker)) throw new Error('app.js script marker absent from index.html');
  html = html.replace(marker, '<script src="test-fixtures.js"></script>\n' + marker);
  if (!html.includes('</body>')) throw new Error('</body> absent from index.html');
  fs.copyFileSync(probeFile, path.join(stage, 'wa-review-probe.js'));
  html = html.replace('</body>', '<script src="wa-review-probe.js"></script>\n</body>');
  fs.writeFileSync(path.join(stage, 'index.html'), html);

  const server = http.createServer((request, response) => {
    let pathname;
    try { pathname = decodeURIComponent(new URL(request.url, 'http://x').pathname); }
    catch { response.writeHead(400).end(); return; }
    const file = path.resolve(stage, '.' + (pathname === '/' ? '/index.html' : pathname));
    if (file !== stage && !file.startsWith(stage + path.sep)) { response.writeHead(403).end(); return; }
    fs.readFile(file, (error, bytes) => {
      if (error) { response.writeHead(404).end(); return; }
      response.writeHead(200, { 'content-type': typeOf(file) });
      response.end(bytes);
    });
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  const url = `http://127.0.0.1:${server.address().port}/${o.query}`;

  const domFile = path.join(out, 'dom.html');
  const shot = path.join(out, 'screenshot.png');
  const logFile = path.join(out, 'browser.log');
  let outcome = null;
  try {
    const args = ['--headless=new', '--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage',
      '--virtual-time-budget=15000', '--hide-scrollbars', '--force-device-scale-factor=1',
      `--window-size=${o.size.replace('x', ',')}`, `--user-data-dir=${profile}`,
      `--screenshot=${shot}`, '--dump-dom', url];
    for (const candidate of findChrome(o.chrome)) {
      const child = spawn(candidate, args, { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
      const chunks = [];
      child.stdout.on('data', (c) => chunks.push(c));
      child.stderr.pipe(fs.createWriteStream(logFile, { flags: 'a' }));
      const timer = setTimeout(() => child.kill(), 180000);
      outcome = await new Promise((resolve) => {
        child.once('error', (error) => resolve({ status: null, error }));
        child.once('close', (status) => resolve({ status, error: null }));
      });
      clearTimeout(timer);
      outcome.command = candidate;
      outcome.dom = Buffer.concat(chunks).toString('utf8');
      if (!(outcome.error && outcome.error.code === 'ENOENT')) break;
    }
  } finally {
    await new Promise((resolve) => server.close(resolve));
    fs.rmSync(stage, { recursive: true, force: true });
    fs.rmSync(profile, { recursive: true, force: true });
  }
  fs.writeFileSync(domFile, outcome.dom || '');
  const page = outcome.dom || '';
  const probe = page.match(/<pre\b(?=[^>]*\bid="wa-probe")(?=[^>]*\bdata-status="([^"]+)")[^>]*>([\s\S]*?)<\/pre>/);
  const status = probe ? probe[1] : 'missing';
  const text = probe ? probe[2].replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&').trim() : null;
  const result = { tag: o.tag, ui, size: o.size, query: o.query, url,
    browser: outcome.command, browserExit: outcome.status,
    browserError: outcome.error ? outcome.error.message : null,
    rendered: fs.existsSync(shot) && page.includes('<title'),
    probeStatus: status, probeText: text,
    dom: domFile, screenshot: shot, browserLog: logFile };
  console.log(JSON.stringify(result, null, 2));
  if (status !== 'pass' || !result.rendered) process.exitCode = 1;
}

main().catch((error) => { console.error(JSON.stringify({ ok: false, error: error.message })); process.exitCode = 1; });
