// Prevention, hermetically: the two ways this lane could go quiet again while every other check said
// "green". A fake DevTools endpoint stands in for the browser (HTTP discovery + one WebSocket speaking the
// CDP calls the adapter makes), so the real adapter, the real trigger, the real preflight and the real
// sentinel CLI all run - nothing about the chain under test is stubbed except the browser and the install
// directory.
//
//   1. step 1 of the copilot pipeline used to answer `already-up` and exit before ever asking about the
//      document-start hook, so the hook was only ever rebound when the browser was restarted. The fast path
//      must ask the preflight - and a preflight that cannot bind the hook must be a named refusal, not a
//      green line.
//   2. a pin that names a target which is not there (`drift=yes`: a browser restart replaced the target id)
//      used to be reported and nothing more, so no page event arrived and nothing installed the hook. The
//      repair has to actually re-pin the installed job - and a repair that cannot be handed to the sentinel
//      has to say so by name.
//
// The fake browser is a separate process on purpose: the checks below run commands with `spawnSync`, which
// blocks this process's event loop, and a server living here would never answer them.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const assert = require("node:assert/strict");
const { spawn, spawnSync } = require("node:child_process");

const repo = path.resolve(__dirname, "..");
const sourceEnsure = path.join(repo, "scripts", "whatsapp-source-ensure.sh");
const preflight = path.join(repo, "scripts", "whatsapp-preflight.sh");
const trigger = path.join(repo, "scripts", "whatsapp-trigger.mjs");
const sentinelSource = path.resolve(process.argv[2] || path.join(repo, "rust/wa-sentinel/target/release",
  process.platform === "win32" ? "wa-sentinel.exe" : "wa-sentinel"));

const LIVE_TARGET = "FIXTURELIVE0000000000000000000000";
const STALE_TARGET = "FIXTURESTALE000000000000000000000";
const root = fs.mkdtempSync(path.join(os.tmpdir(), "wa-rebind-"));
const install = path.join(root, "install");
const installBare = path.join(root, "install-bare");
const home = path.join(root, "home");
for (const dir of [install, installBare, home]) fs.mkdirSync(dir, { recursive: true });
let checks = 0;
let skipped = 0;
const check = (value, label) => { assert.ok(value, label); checks += 1; };
const skip = (label) => { console.log("SKIP: " + label); skipped += 1; };

// The fake browser: /json/version (with the Browser field the keeper insists on), /json/list in the shape
// Chrome prints it (one field per line, `type` before `url`, because the keeper parses it with awk), and a
// CDP websocket whose `Runtime.evaluate` answer is the page's own report of the store, the chat count and
// the hook.
const FAKE_CDP = `
import http from "node:http";
import crypto from "node:crypto";
const LIVE = process.env.FAKE_LIVE_TARGET;
function pageList(port) {
  return ["[ {",
    '   "description": "",',
    '   "devtoolsFrontendUrl": "https://chrome-devtools-frontend.appspot.com/serve_rev/@fixture/inspector.html?ws=127.0.0.1:' + port + '/devtools/page/' + LIVE + '",',
    '   "faviconUrl": "",',
    '   "id": "' + LIVE + '",',
    '   "title": "WhatsApp",',
    '   "type": "page",',
    '   "url": "https://web.whatsapp.com/",',
    '   "webSocketDebuggerUrl": "ws://127.0.0.1:' + port + '/devtools/page/' + LIVE + '"',
    "} ]"].join("\\r\\n");
}
function frame(payload) {
  const body = Buffer.from(payload, "utf8");
  if (body.length < 126) return Buffer.concat([Buffer.from([0x81, body.length]), body]);
  return Buffer.concat([Buffer.from([0x81, 126, body.length >> 8, body.length & 0xff]), body]);
}
const server = http.createServer((request, response) => {
  response.setHeader("content-type", "application/json");
  if (request.url.startsWith("/json/version")) {
    response.end(JSON.stringify({ Browser: "Chrome/154.0.0.0", "Protocol-Version": "1.3",
      webSocketDebuggerUrl: "ws://127.0.0.1:" + server.address().port + "/devtools/browser/fixture" }));
    return;
  }
  response.end(pageList(server.address().port));
});
server.on("upgrade", (request, socket) => {
  const accept = crypto.createHash("sha1")
    .update(String(request.headers["sec-websocket-key"]) + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest("base64");
  socket.write("HTTP/1.1 101 Switching Protocols\\r\\nUpgrade: websocket\\r\\nConnection: Upgrade\\r\\n"
    + "Sec-WebSocket-Accept: " + accept + "\\r\\n\\r\\n");
  let buffer = Buffer.alloc(0);
  socket.on("data", (chunk) => {
    buffer = Buffer.concat([buffer, chunk]);
    while (buffer.length >= 2) {
      const opcode = buffer[0] & 0x0f;
      let length = buffer[1] & 0x7f;
      let offset = 2;
      if (length === 126) { if (buffer.length < 4) return; length = buffer.readUInt16BE(2); offset = 4; }
      else if (length === 127) { if (buffer.length < 10) return; length = Number(buffer.readBigUInt64BE(2)); offset = 10; }
      const masked = (buffer[1] & 0x80) !== 0;
      const mask = masked ? buffer.subarray(offset, offset + 4) : null;
      if (masked) offset += 4;
      if (buffer.length < offset + length) return;
      const payload = Buffer.from(buffer.subarray(offset, offset + length));
      buffer = buffer.subarray(offset + length);
      if (opcode === 0x8) { socket.end(); return; }
      if (opcode !== 0x1) continue;
      if (mask) for (let i = 0; i < payload.length; i += 1) payload[i] ^= mask[i % 4];
      let message = {};
      try { message = JSON.parse(payload.toString("utf8")); } catch { /* answered below either way */ }
      const value = JSON.stringify({ store: true, chats: 7, hook: true, names: 3,
        title: "WhatsApp", url: "https://web.whatsapp.com/" });
      const reply = message.method === "Runtime.evaluate"
        ? { id: message.id, result: { result: { type: "string", value } } }
        : { id: message.id, result: {} };
      socket.write(frame(JSON.stringify(reply)));
    }
  });
  socket.on("error", () => {});
});
server.listen(0, "127.0.0.1", () => { console.log("PORT=" + server.address().port); });
`;

function run(command, args, env = {}) {
  const result = require('./lib/fixture-operation.cjs')(root,command, args, { encoding: "utf8", timeout: 120000, windowsHide: true,
    env: { ...process.env, ...env } });
  fs.writeFileSync(path.join(root,`run-${Date.now()}-${Math.random()}.json`),JSON.stringify(result));
  assert(!result.error && result.status!==null,'uncertain child: preserve evidence');
  const lines = String(result.stdout || "").trim().split(/\r?\n/).filter(Boolean);
  return { code: result.status, lines, stdout: result.stdout || "", stderr: result.stderr || "" };
}
const lastJson = (run_) => {
  for (let index = run_.lines.length - 1; index >= 0; index -= 1) {
    try { return JSON.parse(run_.lines[index]); } catch { /* keep looking */ }
  }
  return null;
};

async function startFakeCdp() {
  const file = path.join(root, "fake-cdp.mjs");
  fs.writeFileSync(file, FAKE_CDP);
  const child = spawn(process.execPath, [file], { env: { ...process.env, FAKE_LIVE_TARGET: LIVE_TARGET },
    stdio: ["ignore", "pipe", "inherit"], windowsHide: true });
  const port = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("the fake DevTools endpoint never reported a port")), 20000);
    let text = "";
    child.stdout.on("data", (chunk) => {
      text += String(chunk);
      const hit = /PORT=(\d+)/.exec(text);
      if (hit) { clearTimeout(timer); resolve(Number(hit[1])); }
    });
  });
  return { child, port };
}

async function main() {
  check(fs.existsSync(sourceEnsure) && fs.existsSync(preflight) && fs.existsSync(trigger), "the chain exists");
  const { child, port } = await startFakeCdp();
  const base = { WA_CDP_PORT: String(port), WA_INSTALL_DIR: install, WASM_AGENT_HOME: home,
    LOCALAPPDATA: path.join(root, "localappdata") };

  // ---- 1. the fast path asks the preflight ------------------------------------------------------------
  const calls = path.join(root, "preflight-calls.log");
  const okPreflight = path.join(root, "preflight-ok.sh");
  fs.writeFileSync(okPreflight, "#!/usr/bin/env bash\n"
    + `echo "$0" >> ${JSON.stringify(calls)}\n`
    + `echo "whatsapp preflight ok cdp=127.0.0.1:${port} chats=7 bound=page hook=true"\n`);
  const fast = run("bash", [sourceEnsure, "--port", String(port), "--wait", "4"],
    { ...base, WA_PREFLIGHT_SCRIPT: okPreflight });
  check(fast.code === 0, `the fast path still succeeds with the chain up (exit ${fast.code}): ${fast.stdout}${fast.stderr}`);
  const fastVerdict = lastJson(fast);
  check(fastVerdict && fastVerdict.ok === true && fastVerdict.action === "already-up",
    `the fast path still answers already-up: ${JSON.stringify(fastVerdict)}`);
  check(fastVerdict && fastVerdict.reason === "preflight_ok",
    `and says the verdict came from the preflight, not from "DevTools answered": ${JSON.stringify(fastVerdict)}`);
  check(fs.existsSync(calls) && fs.readFileSync(calls, "utf8").trim().split("\n").length === 1,
    "the preflight (the hook rebind) was actually run on the already-up path - it used to be skipped here");

  // ---- 2. a preflight that cannot bind the hook is a named refusal, not a green line -------------------
  const badPreflight = path.join(root, "preflight-bad.sh");
  fs.writeFileSync(badPreflight, "#!/usr/bin/env bash\n"
    + "echo \"whatsapp preflight unavailable reason=hook_not_in_the_page_and_not_bound\"\n");
  const refused = run("bash", [sourceEnsure, "--port", String(port), "--wait", "4"],
    { ...base, WA_PREFLIGHT_SCRIPT: badPreflight });
  check(refused.code === 1, `an unbindable hook fails the step (exit ${refused.code})`);
  const refusedVerdict = lastJson(refused);
  check(refusedVerdict && refusedVerdict.ok === false && refusedVerdict.reason === "hook_not_in_the_page_and_not_bound",
    `the refusal is categorical: ${JSON.stringify(refusedVerdict)}`);
  check(refused.stderr.includes("hook_not_in_the_page_and_not_bound"),
    "the refusal names the reason on stderr, where a human reads it");

  // ---- 3. drift is repaired, not reported -------------------------------------------------------------
  if (!fs.existsSync(sentinelSource)) {
    skip("sentinel binary not built, so the re-pin was not exercised: " + sentinelSource);
  } else {
    const sentinel = path.join(install, process.platform === "win32" ? "wa-sentinel.exe" : "wa-sentinel");
    fs.copyFileSync(sentinelSource, sentinel);
    if (process.platform !== "win32") fs.chmodSync(sentinel, 0o755);
    const staleJob = path.join(root, "stale.job.json");
    fs.writeFileSync(staleJob, JSON.stringify({ id: "whatsapp-events", name: "stale pin",
      trigger: { kind: "cdp", websocket_url: `ws://localhost:9222/devtools/page/${STALE_TARGET}`,
        binding: "wa_event", setup_expression: "0" },
      action: { kind: "wake", session: "whatsapp-job", skill: "whatsapp-reply", prompt: "fixture" } }, null, 1));
    const seeded = run(sentinel, ["job", "put", staleJob], base);
    check(seeded.code === 0, `a stale pin is seeded in the install's own job store: ${seeded.stdout}${seeded.stderr}`);
    check(run(sentinel, ["job", "list"], base).stdout.includes(STALE_TARGET), "the seeded pin is installed");

    const status = run(process.execPath, [trigger, "status", "--line"], base);
    check(status.lines.some((line) => line.includes("drift=yes") && line.includes(STALE_TARGET) && line.includes(LIVE_TARGET)),
      `the dead pin is detected as drift: ${status.lines.join(" | ")}`);

    // The preflight is what runs the repair, on drift - this is the pipeline's step 1, end to end: the real
    // adapter (against the fake page), the real trigger, the real preflight and the real sentinel CLI.
    const preflightRun = run("bash", [preflight], base);
    check(preflightRun.lines.some((line) => line.startsWith("whatsapp preflight ok")),
      `the preflight is green with the chain up: ${preflightRun.lines.join(" | ")}`);
    check(preflightRun.lines.some((line) => line.includes("drift=yes")),
      `the preflight reports the drift it found: ${preflightRun.lines.join(" | ")}`);
    const repairedLine = preflightRun.lines.find((line) => line.startsWith("whatsapp preflight trigger-repair"));
    check(!!repairedLine, `the preflight repaired it rather than reporting it: ${preflightRun.lines.join(" | ")}`);
    check(repairedLine && repairedLine.includes('"action":"re-pin"') && repairedLine.includes('"ok":true'),
      `and the repair is the real one: ${repairedLine}`);
    const after = run(sentinel, ["job", "list"], base);
    check(after.stdout.includes(LIVE_TARGET) && !after.stdout.includes(STALE_TARGET),
      `the installed job now names the live target: ${after.stdout}`);

    const again = lastJson(run(process.execPath, [trigger, "repair"], base));
    check(again && again.action === "none", `a second repair is a no-op - no drift, no write: ${JSON.stringify(again)}`);

    // And the command's own contract, from a freshly seeded stale pin.
    run(sentinel, ["job", "put", staleJob], base);
    const direct = run(process.execPath, [trigger, "repair"], base);
    const directVerdict = lastJson(direct);
    check(direct.code === 0 && directVerdict && directVerdict.ok === true && directVerdict.action === "re-pin",
      `the repair re-pins: ${JSON.stringify(directVerdict)}`);
    check(directVerdict && directVerdict.pin === STALE_TARGET && directVerdict.live_target === LIVE_TARGET,
      `the repair says what it moved from and to: ${JSON.stringify(directVerdict)}`);
    check(run(sentinel, ["job", "list"], base).stdout.includes(LIVE_TARGET), "and the job store agrees");
  }

  // ---- 4. a repair that cannot reach the sentinel refuses by name --------------------------------------
  const bare = run(process.execPath, [trigger, "repair"], { ...base, WA_INSTALL_DIR: installBare });
  const bareVerdict = lastJson(bare);
  check(bare.code === 6, `a repair that could not be installed exits non-zero (exit ${bare.code})`);
  check(bareVerdict && bareVerdict.ok === false && bareVerdict.error === "job_put_failed",
    `the refusal is named: ${JSON.stringify(bareVerdict)}`);
  const written = path.join(installBare, "scripts", "whatsapp-events.job.json");
  check(fs.existsSync(written), `the job file was written even so: ${written}`);
  check(JSON.parse(fs.readFileSync(written, "utf8")).trigger.websocket_url.includes(LIVE_TARGET),
    "and it names the live target, so the next repair (or a human) installs the right one");
  const closed=new Promise((resolve,reject)=>{child.once('close',resolve);child.once('error',reject);});
  child.kill();
  await closed;
  assert(child.exitCode!==null || child.signalCode!==null,'fake server settled');
  console.log(`whatsapp hook rebind ok (${checks} checks, 0 failed, ${skipped} skipped; fake DevTools endpoint, real adapter/trigger/preflight, real sentinel CLI)`);
  console.log("evidence: " + root);
  assert.equal(fs.realpathSync(root),path.resolve(root));assert.equal(path.dirname(root),fs.realpathSync(os.tmpdir()));
  const git=spawnSync('git',['rev-parse','--git-common-dir'],{cwd:repo,encoding:'utf8'});assert.equal(git.status,0);
  const retained=path.resolve(repo,git.stdout.trim(),'fixture-evidence',path.basename(root)),mapping=[];
  function preserve(dir){for(const e of fs.readdirSync(dir,{withFileTypes:true})){const p=path.join(dir,e.name);assert(!fs.lstatSync(p).isSymbolicLink());assert.equal(fs.realpathSync(p),p,'no junction');if(e.isDirectory())preserve(p);else{const bytes=fs.readFileSync(p),target=path.join(retained,path.relative(root,p));fs.mkdirSync(path.dirname(target),{recursive:true});fs.writeFileSync(target,bytes,{flag:'wx'});assert(fs.readFileSync(target).equals(bytes));mapping.push({original:p,retained:target,sha256:require('node:crypto').createHash('sha256').update(bytes).digest('hex')});}}}
  preserve(root);fs.writeFileSync(path.join(retained,'retention-map.json'),JSON.stringify(mapping,null,2),{flag:'wx'});
  console.log('retained evidence: '+retained);fs.rmSync(root,{recursive:true});
}

main().then(() => process.exit(0)).catch((error) => {
  console.error(error.stack || String(error));
  console.error("evidence: " + root);
  process.exit(1);
});
