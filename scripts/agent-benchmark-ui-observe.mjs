#!/usr/bin/env node
// Disposable browser observation for a benchmark checkout. The independent
// scorer's assertions are deliberately absent from this command.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { spawn } from 'node:child_process';

function argumentsFrom(argv) {
  const opts = { ui: '/work/ui', fixtures: true };
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === '--ui' || argv[i] === '--probe' || argv[i] === '--out') {
      opts[argv[i].slice(2)] = argv[++i];
    } else if (argv[i] === '--no-fixtures') {
      opts.fixtures = false;
    } else {
      throw new Error(`unknown argument: ${argv[i]}`);
    }
  }
  return opts;
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
    const child = spawn('chromium', ['--headless=new', '--no-sandbox', '--disable-gpu',
      '--disable-dev-shm-usage', '--virtual-time-budget=10000',
      `--user-data-dir=${profile}`, '--window-size=1280,900',
      `--screenshot=${screenshot}`, '--dump-dom', url], {
      stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...process.env, HOME: browserHome, XDG_CACHE_HOME: browserHome },
    });
    const chunks = [];
    let size = 0;
    child.stdout.on('data', chunk => {
      size += chunk.length;
      if (size <= 16 * 1024 * 1024) chunks.push(chunk);
      else child.kill();
    });
    const errors = fs.createWriteStream(browserLog);
    child.stderr.pipe(errors);
    const timer = setTimeout(() => child.kill(), 60000);
    browser = await new Promise(resolve => {
      child.once('error', error => resolve({ status: null, error }));
      child.once('close', (status, signal) => resolve({ status, signal, error: null }));
    });
    clearTimeout(timer);
    fs.writeFileSync(dom, Buffer.concat(chunks));
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
  const result = { ok: !browser.error && browser.status === 0 && fs.existsSync(screenshot)
    && (!opts.probe || status === 'pass'), browserExit: browser.status,
    browserSignal: browser.signal || null, browserError: browser.error?.message || null,
    probeStatus: status, probeText: probe?.[2]?.slice(0, 2000) || null,
    dom, screenshot, browserLog };
  console.log(JSON.stringify(result));
  if (!result.ok) process.exitCode = 1;
}

main().catch(error => {
  console.error(JSON.stringify({ ok: false, error: error.message }));
  process.exitCode = 1;
});
