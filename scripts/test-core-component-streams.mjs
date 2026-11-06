// A2.2 parity for the Lua core's streams and console capabilities (docs/KERNEL.md).
//
// scripts/fixtures/core-component-streams.lua runs against a local SSE stub (127.0.0.1, no internet)
// twice: once natively (`WA_SCRIPT`), once inside the agent-core component (`wa --core-component`).
// The two answers must be **identical**, which is the claim A2.2 makes: the Lua-facing API did not
// change when `host.http_sse`, table arguments and the console's output capabilities started
// crossing the component bridge.
//
//   WA_BIN=<wa> AGENT_CORE=<agent_core.wasm> node scripts/test-core-component-streams.mjs
//
// Prints `core streams parity ok (<n> checks, native <a> ms, component <b> ms)` and exits 0, or
// prints what differed and exits 1. Isolated homes and ledgers under the system temp; nothing is
// deployed and no service is contacted.
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { mkdtempSync, mkdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = dirname(here);
const script = join(here, 'fixtures', 'core-component-streams.lua');
const bin = process.env.WA_BIN;
const core = process.env.AGENT_CORE;
if (!bin) {
  console.error('test-core-component-streams: WA_BIN is not set');
  process.exit(2);
}
if (!core) {
  console.error('test-core-component-streams: AGENT_CORE is not set');
  process.exit(2);
}

// The recorded shape of a real SSE body: events separated by a blank line, so the reader's line
// count includes those blank lines (native `read_sse_lines` counts them, and so must the bridge).
const EVENTS = 'data: {"n":1}\n\ndata: {"n":2}\n\ndata: done\n\n';
const HELD = 'data: held\n';

const server = createServer((request, response) => {
  let body = '';
  request.on('data', (chunk) => { body += chunk; });
  request.on('end', () => {
    if (request.method !== 'POST') {
      response.writeHead(405).end('POST only');
      return;
    }
    if (request.url === '/error') {
      response.writeHead(500, { 'content-type': 'text/plain' }).end('upstream exploded');
      return;
    }
    if (request.url === '/stream') {
      // Held open after the first line: a reader that buffered the body would not see line one
      // until the end, which scripts/fixtures/core-component-streams.lua times.
      response.writeHead(200, { 'content-type': 'text/event-stream' });
      response.write(HELD);
      setTimeout(() => response.end('data: late\n\n'), 250);
      return;
    }
    response.writeHead(200, { 'content-type': 'text/event-stream' });
    response.end(EVENTS);
  });
});

// Asynchronous on purpose: the stub server lives in this process, so a synchronous child would
// block the event loop that has to answer it.
function run(label, args, env) {
  const started = process.hrtime.bigint();
  return new Promise((resolve, reject) => {
    const child = spawn(bin, args, {
      env: {
        ...process.env,
        WASM_AGENT_LUA_ROOT: process.env.WASM_AGENT_LUA_ROOT || root,
        WASM_AGENT_CLI_TICKER: 'off',
        WA_SSE_STUB_URL: `http://127.0.0.1:${server.address().port}`,
        ...env,
      },
    });
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    const timer = setTimeout(() => { child.kill(); reject(new Error(`${label}: timed out after 180000 ms`)); }, 180_000);
    child.on('error', (error) => { clearTimeout(timer); reject(new Error(`${label}: ${error.message}`)); });
    child.on('close', (status) => {
      clearTimeout(timer);
      resolve({ label, status, stdout, stderr, millis: Number(process.hrtime.bigint() - started) / 1e6 });
    });
  });
}

await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
const scratch = mkdtempSync(join(tmpdir(), 'wa-core-streams-'));
let native;
let component;
try {
  const nativeHome = join(scratch, 'native-home');
  const componentHome = join(scratch, 'component-home');
  mkdirSync(nativeHome, { recursive: true });
  mkdirSync(componentHome, { recursive: true });
  native = await run('native', ['--db', join(scratch, 'native.db')], {
    WASM_AGENT_HOME: nativeHome,
    WA_SCRIPT: script,
  });
  component = await run('component', ['--db', join(scratch, 'component.db'), '--core-component', core, script], {
    WASM_AGENT_HOME: componentHome,
  });
  for (const result of [native, component]) {
    if (result.status !== 0) {
      console.error(`test-core-component-streams: the ${result.label} run exited ${result.status}`);
      console.error(result.stdout.trim());
      console.error(result.stderr.trim());
      process.exit(1);
    }
  }
  const verdict = /^core streams ok \((\d+) checks\)$/m.exec(native.stdout);
  if (!verdict) {
    console.error('test-core-component-streams: the native run printed no verdict');
    console.error(native.stdout.trim());
    process.exit(1);
  }
  // Line endings differ by construction: the native interpreter's stdio is in text mode on Windows
  // (LF becomes CRLF) and the guest's WASI stdout is not, so the comparison is of content.
  const normalize = (text) => text.split(String.fromCharCode(13)).join('');
  if (normalize(native.stdout) !== normalize(component.stdout)) {
    console.error('test-core-component-streams: native and component outputs differ');
    console.error(`native   : ${JSON.stringify(normalize(native.stdout))}`);
    console.error(`component: ${JSON.stringify(normalize(component.stdout))}`);
    process.exit(1);
  }
  // A skipped or truncated run must not read as a pass.
  if (native.stdout.includes('skipped')) {
    console.error('test-core-component-streams: the script skipped its own checks');
    process.exit(1);
  }
  console.log(`core streams parity ok (${verdict[1]} checks, native ${native.millis.toFixed(0)} ms, component ${component.millis.toFixed(0)} ms)`);
} finally {
  server.close();
  rmSync(scratch, { recursive: true, force: true });
}
