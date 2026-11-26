#!/usr/bin/env node
// Slice 1 of `ready-serve-own-program.md` (move-list row 8): the door's STATIC tier answered by its own
// program.
//
// Two real processes on one machine, and a third observation that makes the proof decisive:
//   * `wa serve-static` in its own scratch home, owning the UI files;
//   * `wa serve` with `WASM_AGENT_SERVE_STATIC` naming it, answering the door;
//   * then the program is stopped and the SAME door request must answer a NAMED refusal - which is how we
//     know the bytes came from the program and not from the door reading the file itself.
//
// The comparison is the same door, twice: once in-process (the switch unset - today's path, what every
// node runs) and once forwarded. Same status, same content-type, same sha256 of the body. A traversal
// attempt (`/../etc/passwd`) must be refused identically on both paths, and a path the UI does not hold
// must fall through on both (answered by the route table, not by the file reader).
//
// Usage: node scripts/test-serve-static.cjs [path/to/wa]
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const http = require('node:http');
const net = require('node:net');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');
const assert = require('node:assert/strict');

const repo = path.resolve(__dirname, '..');
const wa = path.resolve(process.argv[2] || path.join(repo, 'rust', 'target', 'release', 'wa'));
const ui = path.join(repo, 'ui');
// A real temp directory, never the node's own state root.
const tempBase = fs.existsSync('/tmp') ? '/tmp' : os.tmpdir();
const root = fs.mkdtempSync(path.join(tempBase, 'wa-serve-static-'));
const sleep = ms => new Promise(done => setTimeout(done, ms));

let checks = 0;
const children = [];
function check(value, label) { assert.ok(value, label); checks += 1; }

function baseEnv(home) {
  return {
    ...process.env,
    HOME: home,
    WASM_AGENT_HOME: home,
    WASM_AGENT_MANAGED: '0',
    WASM_AGENT_RELAY: '',
    WASM_AGENT_RENDEZVOUS: '',
    WASM_AGENT_CLIENT_PORT: '0',
    WASM_AGENT_BIND: '127.0.0.1',
  };
}

function freePort() {
  return new Promise((resolve, reject) => {
    const server = http.createServer();
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
    server.on('error', reject);
  });
}

// One raw GET, so a path is sent verbatim (no client library normalising `..`) and a refusal is read as
// the bytes the door really sent. The answer is complete when the headers say how long the body is: the
// door may keep the socket open, so waiting for a close would wait out the timeout on a good answer.
function get(port, rawPath) {
  return new Promise(resolve => {
    const chunks = [];
    let settled = false;
    const finish = value => {
      if (settled) return;
      settled = true;
      resolve(value);
      socket.destroy();
    };
    const parse = () => {
      const answer = Buffer.concat(chunks);
      const split = answer.indexOf('\r\n\r\n');
      if (split < 0) return null;
      const head = answer.slice(0, split).toString('latin1');
      const lengthLine = head.split('\r\n')
        .find(line => line.toLowerCase().startsWith('content-length:')) || '';
      const length = Number(lengthLine.split(':').slice(1).join(':').trim() || '0');
      const body = answer.slice(split + 4);
      if (body.length < length) return null;
      const status = Number(head.split(' ')[1] || '0');
      const type = (head.split('\r\n').find(line => line.toLowerCase().startsWith('content-type:')) || '')
        .split(':').slice(1).join(':').trim();
      const bodyBytes = body.slice(0, length);
      return { status, type, body: bodyBytes, sha256: crypto.createHash('sha256').update(bodyBytes).digest('hex') };
    };
    const socket = net.connect(port, '127.0.0.1', () => {
      // The port is part of the identity the door admits: a request without it is refused (`host`).
      socket.write('GET ' + rawPath + ' HTTP/1.1\r\nhost: 127.0.0.1:' + port + '\r\nconnection: close\r\n\r\n');
    });
    socket.on('data', chunk => {
      chunks.push(chunk);
      const answer = parse();
      if (answer) finish(answer);
    });
    socket.on('error', () => finish(null));
    socket.on('close', () => finish(parse()));
    socket.setTimeout(15000, () => finish(parse()));
  });
}

async function waitFor(probe, label, budget = 30000) {
  const end = Date.now() + budget;
  while (Date.now() < end) {
    const value = await probe();
    if (value) return value;
    await sleep(100);
  }
  throw new Error('timeout: ' + label);
}

async function startDoor(home, port, extraEnv) {
  const log = fs.openSync(path.join(home, 'door.log'), 'a');
  const child = spawn(wa, ['--db', path.join(home, 'memory.db'), 'serve', '--port', String(port), '--ui', ui], {
    cwd: repo,
    env: { ...baseEnv(home), ...extraEnv },
    stdio: ['ignore', log, log],
  });
  children.push(child);
  try {
    await waitFor(async () => {
      const answer = await get(port, '/health');
      return answer && answer.status === 200;
    }, 'door on ' + port);
  } catch (error) {
    // A door that never answered is not a mystery: its own log says why.
    let logText = '';
    try { logText = fs.readFileSync(path.join(home, 'door.log'), 'utf8').slice(-2000); } catch { /* none */ }
    throw new Error(error.message + '; door log: ' + logText);
  }
  return child;
}

(async () => {
  try {
    check(fs.existsSync(wa), 'the binary under test exists: ' + wa);
    check(fs.existsSync(path.join(ui, 'index.html')), 'the UI directory has an index: ' + ui);

    // ---- the in-process path: today's door, switch unset ------------------------------------
    const plainHome = path.join(root, 'home-plain');
    fs.mkdirSync(plainHome, { recursive: true });
    const plainPort = await freePort();
    await startDoor(plainHome, plainPort, {});
    const plainIndex = await get(plainPort, '/index.html');
    const plainMissing = await get(plainPort, '/definitely-not-a-route.js');
    const plainTraversal = await get(plainPort, '/../etc/passwd');
    check(plainIndex && plainIndex.status === 200, 'the in-process door serves index.html');
    check(plainIndex && plainIndex.sha256 === crypto.createHash('sha256')
      .update(fs.readFileSync(path.join(ui, 'index.html'))).digest('hex'),
      'the in-process bytes are the file on disk');

    // ---- the program, and the same door with the switch on --------------------------------
    const programHome = path.join(root, 'home-program');
    fs.mkdirSync(programHome, { recursive: true });
    const rendezvous = path.join(root, 'static.json');
    const programLog = fs.openSync(path.join(root, 'program.log'), 'a');
    const program = spawn(wa, ['serve-static', '--root', ui, '--port', '0', '--rendezvous', rendezvous], {
      cwd: repo,
      env: baseEnv(programHome),
      stdio: ['ignore', programLog, programLog],
    });
    children.push(program);
    const announced = await waitFor(async () => {
      try { return JSON.parse(fs.readFileSync(rendezvous, 'utf8')); } catch { return null; }
    }, 'the program wrote its rendezvous');
    check(announced.pid === program.pid, 'the rendezvous names the process this row started');
    check((fs.statSync(rendezvous).mode & 0o777) === 0o600, 'the rendezvous file is 0600');

    const wiredHome = path.join(root, 'home-wired');
    fs.mkdirSync(wiredHome, { recursive: true });
    const wiredPort = await freePort();
    await startDoor(wiredHome, wiredPort, { WASM_AGENT_SERVE_STATIC: rendezvous });
    const wiredIndex = await get(wiredPort, '/index.html');
    const wiredMissing = await get(wiredPort, '/definitely-not-a-route.js');
    const wiredTraversal = await get(wiredPort, '/../etc/passwd');

    // ---- identical answers -----------------------------------------------------------------
    check(wiredIndex && wiredIndex.status === plainIndex.status,
      'index.html answers the same status (' + (wiredIndex && wiredIndex.status) + ' / ' + plainIndex.status + ')');
    check(wiredIndex && wiredIndex.type === plainIndex.type,
      'index.html answers the same content-type (' + (wiredIndex && wiredIndex.type) + ' / ' + plainIndex.type + ')');
    check(wiredIndex && wiredIndex.sha256 === plainIndex.sha256, 'index.html answers the same bytes');
    check(wiredMissing && plainMissing && wiredMissing.status === plainMissing.status,
      'a path the UI does not hold falls through identically (' + (wiredMissing && wiredMissing.status)
      + ' / ' + (plainMissing && plainMissing.status) + ')');
    check(plainTraversal && plainTraversal.status === 400 && plainTraversal.body.toString() === 'bad path',
      'the in-process door refuses a traversal (' + (plainTraversal && plainTraversal.status) + ')');
    check(wiredTraversal && wiredTraversal.status === 400 && wiredTraversal.body.toString() === 'bad path',
      'the forwarded door refuses the same traversal the same way (' + (wiredTraversal && wiredTraversal.status)
      + ' ' + JSON.stringify(wiredTraversal && wiredTraversal.body.toString()) + ')');

    // ---- the bytes really came from the program --------------------------------------------
    const exited = new Promise(resolve => program.once('exit', resolve));
    program.kill('SIGTERM');
    await exited;
    const afterStop = await get(wiredPort, '/index.html');
    check(afterStop && afterStop.status === 503,
      'the door refuses by name once the program is gone (' + (afterStop && afterStop.status) + ')');
    check(afterStop && afterStop.body.toString().includes('serve_static'),
      'the refusal names the seam (' + (afterStop && afterStop.body.toString().slice(0, 140)) + ')');

    console.log('serve static ok: ' + checks + ' checks');
    process.exitCode = 0;
  } catch (error) {
    console.error('FAIL serve-static: ' + (error && error.message ? error.message : error));
    process.exitCode = 1;
  } finally {
    for (const child of children) {
      if (child.exitCode === null) {
        try { child.kill('SIGTERM'); } catch { /* already gone */ }
      }
    }
    try { fs.rmSync(root, { recursive: true, force: true }); } catch { /* best effort */ }
  }
})();
