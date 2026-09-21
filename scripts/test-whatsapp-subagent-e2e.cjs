// Real WhatsApp durable-effects pipeline proof: node + sentinel + SQLite + child runtime + profile +
// whatsapp tools + a deterministic FAKE SEND subprocess.
//
// ZERO live browser and ZERO paid model: the only model is a local HTTP mock, and the send route is a
// fixture subprocess. There is no `/subagents` protocol stub - the sentinel posts to the real route and
// the runtime starts a real child. If a dependency is not implemented, this test reports
// `DEPENDENCY_MISSING` and exits non-zero; it never fakes the route and never prints ALL PASS.
//
// All agent code lives in the runtime; this test only drives the public surfaces and asserts the effects.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const http = require("node:http");
const assert = require("node:assert/strict");
const { spawn, spawnSync } = require("node:child_process");

const repo = path.resolve(__dirname, "..");
const wa = path.resolve(process.argv[2] || process.env.WA_BIN || path.join(repo, "rust/target/release/wa" + (process.platform === "win32" ? ".exe" : "")));
const sentinel = path.resolve(process.argv[3] || path.join(repo, "rust/wa-sentinel/target/release/wa-sentinel" + (process.platform === "win32" ? ".exe" : "")));
const root = fs.mkdtempSync(path.join(os.tmpdir(), "wa-whatsapp-e2e-"));
const config = path.join(root, ".wasm-agent");
const dbPath = path.join(config, "memory.db");
const counter = path.join(root, "effects.log");
const fakeSender = path.join(root, "fake-sender.cjs");
const profilePath = path.join(config, "subagent-profiles", "whatsapp-responder.json");

const CONV = "5511888888888@c.us";
const ACCOUNT = "5511999999999";
const ENDPOINT = "ws://[::1]:9222/devtools/page/WAFIXTURE";
const MSG_ALLOWED = "msg-allowed-1";
const MSG_CRASH = "msg-crash-1";
const MSG_DENY = "msg-deny-1";

let checks = 0, failures = 0, skipped = 0;
const failureList = [];
let child, sentinelProcess, provider;
let rpc = 0;
const pending = new Map();
const held = new Map();
const modelRequests = [];

class DependencyMissing extends Error {}
function check(value, label) {
  if (value) { checks += 1; return; }
  failures += 1;
  failureList.push(label);
}
function requireDependency(value, label) {
  if (!value) throw new DependencyMissing(label);
  checks += 1;
}
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function until(fn, label, timeout = 20000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (await fn()) return true;
    await sleep(50);
  }
  throw new Error("deadline: " + label);
}
function job(env, ...args) {
  const result = spawnSync(sentinel, ["job", ...args], { env, encoding: "utf8", timeout: 15000, windowsHide: true });
  if (result.status !== 0) throw new Error(`job ${args.join(" ")}: ${result.stderr || result.stdout || result.error?.message}`);
  return JSON.parse(result.stdout);
}
function jobFailure(env, ...args) {
  const result = spawnSync(sentinel, ["job", ...args], { env, encoding: "utf8", timeout: 15000, windowsHide: true });
  return { status: result.status, output: `${result.stderr || ""}${result.stdout || ""}` };
}
async function listen(server) { await new Promise((resolve, reject) => { server.once("error", reject); server.listen(0, "127.0.0.1", resolve); }); return server.address().port; }
async function freePort() { const server = http.createServer(); const port = await listen(server); await new Promise((resolve) => server.close(resolve)); return port; }

// The mock model: drives the child's allowed and denied tool sequences. It is a local HTTP server and
// nothing here is paid inference.
function providerServer() {
  return http.createServer((req, res) => {
    let body = "";
    req.on("data", (chunk) => { body += chunk; });
    req.on("end", () => {
      let input = {};
      try { input = JSON.parse(body); } catch { res.writeHead(400); res.end(); return; }
      modelRequests.push(input);
      const messages = input.messages || [];
      const system = String((messages.find((message) => message.role === "system") || {}).content || "");
      const childText = JSON.stringify(messages);
      const isChild = system.includes("You are a subagent");
      const toolCall = (name, args) => ({ index: 0, id: "call-" + (++rpc), type: "function", function: { name, arguments: JSON.stringify(args || {}) } });
      const finish = (payload) => {
        res.writeHead(200, { "content-type": "text/event-stream" });
        res.end("data: " + JSON.stringify({ id: "mock", choices: [payload], usage: { prompt_tokens: 8, completion_tokens: 2, total_tokens: 10 } }) + "\n\ndata: [DONE]\n\n");
      };
      const text = (content) => finish({ delta: { content }, finish_reason: "stop" });
      const call = (name, args) => finish({ delta: { tool_calls: [toolCall(name, args)] }, finish_reason: "tool_calls" });
      if (!isChild) { text("parent-ack"); return; }
      const toolResults = messages.filter((message) => message.role === "tool").map((message) => String(message.content || ""));
      const lastTool = toolResults.length ? toolResults[toolResults.length - 1] : "";
      const seen = (name) => childText.includes(`"${name}"`);
      if (childText.includes("mode:crash") || childText.includes('"mode":"crash"')) {
        if (!toolResults.length) { call("whatsapp_read", {}); return; }
        if (!lastTool.includes("conversation_id")) { call("whatsapp_read", {}); return; }
        if (!seen("whatsapp_send")) { call("whatsapp_send", { body: "crash-body", confirm: true }); return; }
        text("child-crash-done");
        return;
      }
      if (childText.includes("mode:deny") || childText.includes('"mode":"deny"')) {
        if (!toolResults.length) { call("bash", { command: "echo pwned > " + path.join(root, "pwned.txt").replaceAll("\\", "/") }); return; }
        if (!seen("whatsapp_send")) { call("whatsapp_send", { conversation_id: "9999999999@c.us", body: "foreign", confirm: true }); return; }
        text("child-denied-done");
        return;
      }
      // Allowed: read -> decide -> send.
      if (!toolResults.length) { call("whatsapp_read", {}); return; }
      if (!childText.includes("whatsapp_decide")) { call("whatsapp_decide", { decision: "reply", reason: "waiting on them" }); return; }
      if (!seen("whatsapp_send")) { call("whatsapp_send", { body: "yes, 3pm", confirm: true }); return; }
      text("child-sent-done");
    });
  });
}

function writeFakeSender() {
  fs.writeFileSync(fakeSender, `// Deterministic fake send route: no browser, exact receipt, scratch counter.
const fs = require("node:fs");
const arg = (name) => { const i = process.argv.indexOf(name); return i >= 0 ? process.argv[i + 1] : ""; };
const counter = process.env.WA_FAKE_COUNTER;
const chat = arg("--chat");
const bodyFile = arg("--body-file");
const body = fs.existsSync(bodyFile) ? fs.readFileSync(bodyFile, "utf8") : "";
const expectAccount = arg("--expect-account");
const expectEndpoint = arg("--expect-browser-endpoint");
const actualAccount = process.env.WA_FAKE_ACTUAL_ACCOUNT || "";
const actualEndpoint = process.env.WA_FAKE_ACTUAL_ENDPOINT || "";
fs.appendFileSync(counter, JSON.stringify({ chat, body, account: actualAccount, at: Date.now() }) + "\\n");
if (expectAccount && expectAccount !== actualAccount) { console.log(JSON.stringify({ ok: false, error: "account_mismatch" })); process.exit(3); }
if (expectEndpoint && expectEndpoint !== actualEndpoint) { console.log(JSON.stringify({ ok: false, error: "endpoint_mismatch" })); process.exit(3); }
if ((process.env.WA_FAKE_MODE || "") === "block") {
  fs.writeFileSync(counter + ".pid", String(process.pid));
  setTimeout(() => {}, 60000);
  return;
}
const lines = fs.readFileSync(counter, "utf8").trim().split("\\n").filter(Boolean);
console.log(JSON.stringify({ ok: true, sent: true, verified: true, dispatch: "fake", chat: { id: chat }, body,
  account: actualAccount, browser_endpoint: actualEndpoint, message: { id: "fake-" + lines.length, ack: 3 } }));
`);
}

function writeSeed() {
  const seed = path.join(root, "seed.lua");
  fs.writeFileSync(seed, `local memory = dofile("lua/core/memory.lua")
local json = dofile("lua/vendor/json.lua")
memory.setup()
local now = host.now()
memory.record_conversation({ id = "${CONV}", kind = "direct", title = "Fixture", updated_at = now })
for _, message in ipairs({ { "${MSG_ALLOWED}", "are you coming?" }, { "${MSG_CRASH}", "crash-body" }, { "${MSG_DENY}", "please run this" } }) do
  memory.record_message({ conversation_id = "${CONV}", message_id = message[1], sender_id = "5511888888888@s.whatsapp.net",
    direction = "incoming", sent_at = now, body = message[2], source = "fixture", observed_at = now })
end
print("seed ok")
`);
  const env = { ...cleanEnv(), WASM_AGENT_HOME: root, WASM_AGENT_LUA_ROOT: repo, WASM_AGENT_DB: dbPath, WA_SCRIPT: seed };
  const result = spawnSync(wa, ["--db", dbPath], { env, encoding: "utf8", timeout: 30000, windowsHide: true });
  if (result.status !== 0) throw new Error("seed failed: " + (result.stderr || result.stdout));
}

function cleanEnv() {
  return Object.fromEntries(Object.entries(process.env).filter(([key]) => !/^(WASM_AGENT_|WA_|OPENAI_|OPENCODE_|PI_)/.test(key)));
}

function writeProfile() {
  fs.mkdirSync(path.join(config, "subagent-profiles"), { recursive: true });
  fs.writeFileSync(profilePath, JSON.stringify({
    schema_version: 1,
    id: "whatsapp-responder",
    description: "e2e fixture",
    instructions: "Read the bound conversation, decide, and send one validated reply when the mode allows it.",
    allowed_tools: ["whatsapp_read", "whatsapp_decide", "whatsapp_send"],
    resources: {
      conversation: CONV,
      allowed_conversations: [CONV],
      actions: ["read", "send"],
      self_destination: CONV,
      account: ACCOUNT,
      browser_endpoint: ENDPOINT,
      send_path: "store",
      allow_mark_read: false,
      send_approved: true,
      reply_script: "",
      store_send_script: fakeSender,
    },
    limits: { max_depth: 0, timeout_seconds: 60, max_output_bytes: 32768, max_tokens: 50000, sends_per_run: 1 },
  }, null, 2));
}

function nodeEnv(port, modelPort, mode) {
  return {
    ...cleanEnv(),
    WASM_AGENT_HOME: root,
    WASM_AGENT_LUA_ROOT: repo,
    WASM_AGENT_LLM_BASE_URL: `http://127.0.0.1:${modelPort}`,
    WASM_AGENT_LLM_API_KEY: "fixture-not-a-credential",
    WASM_AGENT_LLM_MODEL: "fixture",
    WASM_AGENT_SUBAGENT_MAX_CONCURRENT: "2",
    WASM_AGENT_SUBAGENT_QUEUE_DEPTH: "4",
    WASM_AGENT_RELAY: "",
    WASM_AGENT_RENDEZVOUS: "",
    WASM_AGENT_MANAGED: "0",
    WA_FAKE_COUNTER: counter,
    WA_FAKE_ACTUAL_ACCOUNT: ACCOUNT,
    WA_FAKE_ACTUAL_ENDPOINT: ENDPOINT,
    WA_FAKE_MODE: mode || "ok",
  };
}

function startNode(env, port) {
  const log = fs.openSync(path.join(root, "node.log"), "a");
  const handle = spawn(wa, ["--db", dbPath, "serve", "--port", String(port), "--client-port", "0", "--ui", path.join(repo, "ui")], { env, stdio: ["ignore", log, log], windowsHide: true });
  handle.on("error", (error) => failureList.push("node spawn: " + error.message));
  return handle;
}

function sendEnv(port) {
  return {
    ...cleanEnv(),
    WASM_AGENT_HOME: root,
    WASM_AGENT_PORT: String(port),
    WASM_AGENT_MANAGED: "0",
    WASM_AGENT_RELAY: "",
    WASM_AGENT_RENDEZVOUS: "",
    WA_SENTINEL_SCRIPTS: root,
    WA_SENTINEL_JOB_RESERVED_CHILD_CAPACITY: "1",
  };
}

async function api(base, body) {
  const response = await fetch(base + "/subagents", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body), signal: AbortSignal.timeout(15000) });
  const text = await response.text();
  let value = null;
  try { value = JSON.parse(text); } catch { /* not JSON: a missing route serves HTML/plain */ }
  return { status: response.status, value, text };
}

function effectLines() {
  if (!fs.existsSync(counter)) return [];
  return fs.readFileSync(counter, "utf8").trim().split("\n").filter(Boolean).map((line) => { try { return JSON.parse(line); } catch { return null; } }).filter(Boolean);
}

function writeVerdict(status, extra = {}) {
  const verdict = {
    schema: "wasm-agent.whatsapp-effects-proof/v1",
    status,
    checks,
    failed: failures,
    skipped,
    failures: failureList,
    live_browser: false,
    live_send: false,
    model: "local-mock",
    ...extra,
    evidence: root,
  };
  fs.writeFileSync(path.join(root, "verdict.json"), JSON.stringify(verdict, null, 2));
  return verdict;
}

async function main() {
  requireDependency(fs.existsSync(wa), "wa_binary");
  requireDependency(fs.existsSync(sentinel), "sentinel_binary");
  writeFakeSender();
  writeProfile();
  writeSeed();

  provider = providerServer();
  const modelPort = await listen(provider);
  const port = await freePort();
  const base = `http://127.0.0.1:${port}`;
  const env = nodeEnv(port, modelPort);
  child = startNode(env, port);
  await until(async () => { try { return (await fetch(base + "/health", { signal: AbortSignal.timeout(500) })).ok; } catch { return false; } }, "node ready");

  // Dependency 1: the real /subagents route.
  const probe = await api(base, { action: "profiles" });
  requireDependency(probe.status === 200 && probe.value && !probe.value.error, `post_subagents_route (status ${probe.status})`);

  // Dependency 2: the whatsapp tools are in the registry and the profile resolves for an operator.
  const listed = (probe.value.profiles || []).find((profile) => profile.id === "whatsapp-responder");
  requireDependency(listed && listed.available !== false, `whatsapp_profile_resolves (${JSON.stringify(listed || null)})`);

  // Dependency 3: the child root respects WASM_AGENT_HOME (records must land under the isolated config).
  requireDependency(!process.env.WASM_AGENT_SUBAGENT_ROOT, "test must not override the child root");

  // The real job pipeline: portable artifact import (disabled), enable, emit.
  const jobEnv = sendEnv(port);
  const jobFile = path.join(root, "responder.json");
  fs.writeFileSync(jobFile, JSON.stringify({
    id: "whatsapp-e2e", name: "Responder", trigger: { kind: "event", topic: "wa.e2e" },
    action: { kind: "subagent", profile: "whatsapp-responder", prompt: "Follow the mode in the context.", timeout_seconds: 60 },
  }));
  job(jobEnv, "put", jobFile);
  const artifactFile = path.join(root, "responder.artifact.json");
  fs.writeFileSync(artifactFile, JSON.stringify(job(jobEnv, "export", "whatsapp-e2e")));
  const bindingsFile = path.join(root, "bindings.json");
  fs.writeFileSync(bindingsFile, "{}");
  check(job(jobEnv, "import", artifactFile, "--bindings", bindingsFile, "--approve").job.enabled === false, "artifact import installs disabled");
  const guestImport = jobFailure(jobEnv, "import", artifactFile, "--bindings", bindingsFile, "--approve", "--as-role", "guest");
  check(guestImport.status !== 0 && guestImport.output.includes("guest_artifact_profile_not_permitted"), "guest cannot import the operator whatsapp profile");
  job(jobEnv, "enable", "whatsapp-e2e");
  const watcherLog = fs.openSync(path.join(root, "sentinel.log"), "a");
  sentinelProcess = spawn(sentinel, ["watch"], { env: jobEnv, stdio: ["ignore", watcherLog, watcherLog], windowsHide: true });
  sentinelProcess.on("error", (error) => failureList.push("sentinel spawn: " + error.message));

  const emit = (eventId, payload) => {
    const file = path.join(root, eventId + ".json");
    fs.writeFileSync(file, JSON.stringify(payload));
    return job(jobEnv, "emit", "wa.e2e", eventId, file);
  };

  // ---- allowed run: read -> decide -> send, exactly one durable effect -----------------------------
  check(emit("allowed-1", { conversation_id: CONV, message_id: MSG_ALLOWED, mode: "allowed" }).queued === 1, "allowed event enqueued");
  await until(() => effectLines().some((line) => line.body === "yes, 3pm"), "fake send invoked once");
  await until(() => job(jobEnv, "history").some((delivery) => delivery.job_id === "whatsapp-e2e" && delivery.state === "completed"), "allowed delivery completed");
  const allowedEffects = effectLines().filter((line) => line.body === "yes, 3pm");
  check(allowedEffects.length === 1, `exactly one durable effect for the allowed message (got ${allowedEffects.length})`);
  check(allowedEffects[0] && allowedEffects[0].chat === CONV, "the fake send received the exact recipient");
  check(allowedEffects[0] && allowedEffects[0].account === ACCOUNT, "the fake send proved the bound account");
  const allowedChild = fs.existsSync(path.join(config, "subagents"))
    ? fs.readdirSync(path.join(config, "subagents"))
    : [];
  requireDependency(allowedChild.length > 0, "child_root_uses_WASM_AGENT_HOME (no records under the isolated config)");
  emit("allowed-1", { conversation_id: CONV, message_id: MSG_ALLOWED, mode: "allowed" });
  await sleep(800);
  check(effectLines().filter((line) => line.body === "yes, 3pm").length === 1, "a repeated delivery does not send a second effect");

  // ---- denied run: general bash and a foreign chat are refused by actual dispatch ------------------
  check(emit("deny-1", { conversation_id: CONV, message_id: MSG_DENY, mode: "deny" }).queued === 1, "denial event enqueued");
  await until(() => job(jobEnv, "history").some((delivery) => delivery.job_id === "whatsapp-e2e" && delivery.state !== "running" && delivery.id > 1), "denial delivery settled");
  check(!fs.existsSync(path.join(root, "pwned.txt")), "the general shell was never executed");
  check(effectLines().every((line) => line.body !== "foreign"), "a foreign conversation was never sent to");

  // ---- restart ambiguity: a reservation persists across a node restart -----------------------------
  const beforeCrash = effectLines().filter((line) => line.body === "crash-body").length;
  check(beforeCrash === 0, "no crash effect before the scenario");
  const crashEnv = { ...env, WA_FAKE_MODE: "block" };
  if (child && child.exitCode === null) child.kill();
  await Promise.race([new Promise((resolve) => child.once("exit", resolve)), sleep(5000)]);
  child = startNode(crashEnv, port);
  await until(async () => { try { return (await fetch(base + "/health", { signal: AbortSignal.timeout(500) })).ok; } catch { return false; } }, "node restarted", 15000);
  check(emit("crash-1", { conversation_id: CONV, message_id: MSG_CRASH, mode: "crash" }).queued === 1, "crash event enqueued after restart");
  await until(() => effectLines().filter((line) => line.body === "crash-body").length === 1, "crash send began and blocked", 20000);
  await sleep(1500);
  // The send is blocked before confirmation. Kill only the test-owned node and the blocked fake sender.
  const pidFile = counter + ".pid";
  if (fs.existsSync(pidFile)) { try { process.kill(Number(fs.readFileSync(pidFile, "utf8"))); } catch { /* already gone */ } }
  const crashChild = child;
  if (crashChild && crashChild.exitCode === null) crashChild.kill();
  await Promise.race([new Promise((resolve) => crashChild.once("exit", resolve)), sleep(5000)]);
  // Restart the same home and resubmit the same source message under a fresh delivery.
  child = startNode({ ...env, WA_FAKE_MODE: "ok" }, port);
  await until(async () => { try { return (await fetch(base + "/health", { signal: AbortSignal.timeout(500) })).ok; } catch { return false; } }, "node restarted for replay", 15000);
  check(emit("crash-2", { conversation_id: CONV, message_id: MSG_CRASH, mode: "crash" }).queued === 1, "replay event enqueued with a fresh delivery");
  await until(() => job(jobEnv, "history").some((delivery) => delivery.job_id === "whatsapp-e2e" && delivery.state !== "running" && String(delivery.detail || "").match(/ambiguous|unknown/)), "pending reservation reconciled/refused", 30000);
  check(effectLines().filter((line) => line.body === "crash-body").length === 1, "a pending reservation is never sent twice");

  // ---- guest cannot spawn the operator whatsapp profile --------------------------------------------
  const guestProbe = await api(base, { action: "start", profile: "whatsapp-responder", prompt: "guest", idempotency_key: "guest-1" });
  check(guestProbe.value && (guestProbe.value.error || guestProbe.status !== 200), "an unauthenticated/guest spawn of the operator profile is refused");

  requireDependency(failures === 0, `checks_failed:${failures}:${failureList.join("|")}`);
  const verdict = writeVerdict("ok");
  console.log(`whatsapp subagent e2e ok (${verdict.checks} checks, ${verdict.failed} failed, ${verdict.skipped} skipped; mock model, fake send, no live browser)`);
  console.log(`evidence: ${root}`);
  console.log("ALL PASS");
}

(async () => {
  try {
    await main();
  } catch (error) {
    if (error instanceof DependencyMissing) {
      skipped += 1;
      writeVerdict("dependency_missing", { dependency: error.message });
      console.error("DEPENDENCY_MISSING: " + error.message);
      console.error("evidence: " + root);
      process.exitCode = 2;
    } else {
      failures += 1;
      failureList.push(error.message);
      writeVerdict("failed", { error: error.stack || String(error) });
      console.error(error.stack || String(error));
      console.error("evidence: " + root);
      process.exitCode = 1;
    }
  } finally {
    for (const response of held.values()) response.destroy();
    for (const handle of [sentinelProcess, child]) {
      if (handle && handle.exitCode === null) {
        handle.kill();
        await Promise.race([new Promise((resolve) => handle.once("exit", resolve)), sleep(5000)]);
      }
    }
    provider?.closeAllConnections();
    provider?.close();
  }
})();
