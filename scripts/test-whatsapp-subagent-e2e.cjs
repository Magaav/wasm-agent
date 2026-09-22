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

// The mock model: drives the child's allowed and denied tool sequences, answers interactive turns with
// isolated markers, and can hold child inference so the pool can be saturated while interactive runs
// finish. It is a local HTTP server and nothing here is paid inference.
let holdChildren = false;
const held = [];
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
      const userText = messages.filter((message) => message.role === "user")
        .map((message) => (typeof message.content === "string" ? message.content : JSON.stringify(message.content))).join("\n");
      const usage = { prompt_tokens: 8, completion_tokens: 2, total_tokens: 10 };
      const respond = (payload) => {
        if (res.destroyed || res.writableEnded) return;
        res.writeHead(200, { "content-type": "text/event-stream" });
        res.end("data: " + JSON.stringify({ id: "mock", choices: [payload], usage }) + "\n\ndata: [DONE]\n\n");
      };
      const text = (content) => ({ delta: { content }, finish_reason: "stop" });
      let payload;
      if (!isChild) {
        const marker = userText.includes("INTERACTIVE_A") ? "ANSWER_A" : userText.includes("INTERACTIVE_B") ? "ANSWER_B" : "OPERATOR_ACK";
        payload = text(marker);
      } else if (!childText.includes("MODE:")) {
        // A no-op child (no WhatsApp mode) used only to fill the child pool.
        payload = text("noop-done");
      } else {
        const toolResults = messages.filter((message) => message.role === "tool");
        const steps = toolResults.length;
        const toolCall = (name, args) => ({ index: 0, id: "call-" + (++rpc), type: "function", function: { name, arguments: JSON.stringify(args || {}) } });
        const call = (name, args) => ({ delta: { tool_calls: [toolCall(name, args)] }, finish_reason: "tool_calls" });
        if (childText.includes("MODE:crash")) {
          if (steps === 0) payload = call("whatsapp_read", {});
          else if (steps === 1) payload = call("whatsapp_send", { body: "crash-body", confirm: true });
          else {
            const sendResult = String((toolResults[1] && toolResults[1].content) || "");
            payload = text(/ambiguous|already_sent|"error"/.test(sendResult) ? "child-crash-refused" : "child-crash-sent");
          }
        } else if (childText.includes("MODE:deny")) {
          if (steps === 0) payload = call("bash", { command: "echo pwned > " + path.join(root, "pwned.txt").replaceAll("\\", "/") });
          else if (steps === 1) payload = call("whatsapp_send", { conversation_id: "9999999999@c.us", body: "foreign", confirm: true });
          else payload = text("child-denied-done");
        } else {
          if (steps === 0) payload = call("whatsapp_read", {});
          else if (steps === 1) payload = call("whatsapp_decide", { decision: "reply", reason: "waiting on them" });
          else if (steps === 2) payload = call("whatsapp_send", { body: "yes, 3pm", confirm: true });
          else payload = text("child-sent-done");
        }
      }
      if (isChild && holdChildren) { held.push({ res, deliver: () => respond(payload) }); return; }
      respond(payload);
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
  // A no-op child with no tools, used only to fill the second child-pool slot during the saturation proof.
  fs.writeFileSync(path.join(config, "subagent-profiles", "proof-lean.json"), JSON.stringify({
    schema_version: 1,
    id: "proof-lean",
    description: "no-op pool filler",
    instructions: "Say done.",
    allowed_tools: [],
    resources: {},
    limits: { max_depth: 0, timeout_seconds: 30, max_output_bytes: 4096, max_tokens: 8000 },
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
    WASM_AGENT_SUBAGENT_CONCURRENCY: "2",
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

async function api(base, body, headers = {}) {
  const response = await fetch(base + "/subagents", { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body), signal: AbortSignal.timeout(15000) });
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

  // The real job pipeline: one portable artifact per scenario, imported disabled, enabled, and driven by
  // real emitted events. The event the sentinel forwards names only the message id; the runtime resolves
  // the conversation from the ledger, so no raw event field can widen the scope.
  const jobEnv = sendEnv(port);
  const bindingsFile = path.join(root, "bindings.json");
  fs.writeFileSync(bindingsFile, "{}");
  for (const [id, topic, prompt] of [
    ["wa-allowed", "wa.allowed", "MODE:allowed Read the conversation, decide, and send the reply."],
    ["wa-deny", "wa.deny", "MODE:deny Follow the mode."],
    ["wa-crash", "wa.crash", "MODE:crash Follow the mode."],
  ]) {
    const file = path.join(root, id + ".json");
    fs.writeFileSync(file, JSON.stringify({ id, name: id, trigger: { kind: "event", topic }, action: { kind: "subagent", profile: "whatsapp-responder", prompt, timeout_seconds: 60 } }));
    job(jobEnv, "put", file);
    const artifactFile = path.join(root, id + ".artifact.json");
    fs.writeFileSync(artifactFile, JSON.stringify(job(jobEnv, "export", id)));
    check(job(jobEnv, "import", artifactFile, "--bindings", bindingsFile, "--approve").job.enabled === false, `${id}: artifact import installs disabled`);
    const guestImport = jobFailure(jobEnv, "import", artifactFile, "--bindings", bindingsFile, "--approve", "--as-role", "guest");
    check(guestImport.status !== 0 && guestImport.output.includes("guest_subagent_requires_principal_binding"), `${id}: a guest cannot import a subagent artifact`);
    job(jobEnv, "enable", id);
  }
  const watcherLog = fs.openSync(path.join(root, "sentinel.log"), "a");
  sentinelProcess = spawn(sentinel, ["watch"], { env: jobEnv, stdio: ["ignore", watcherLog, watcherLog], windowsHide: true });
  sentinelProcess.on("error", (error) => failureList.push("sentinel spawn: " + error.message));

  const emit = (topic, eventId, payload) => {
    const file = path.join(root, `${topic.replaceAll(".", "-")}-${eventId}.json`);
    fs.writeFileSync(file, JSON.stringify(payload));
    return job(jobEnv, "emit", topic, eventId, file);
  };

  // ---- allowed run under child saturation: hold child inference, prove two interactive /chat runs
  // finish with isolated markers and exactly one done while the WhatsApp child (plus a pool-filling
  // no-op child) are held, then release and let the real read/decide/send chain finish.
  holdChildren = true;
  check(emit("wa.allowed", "allowed-1", { message_id: MSG_ALLOWED }).queued === 1, "allowed event enqueued");
  await until(() => held.length >= 1, "the WhatsApp child's first model request is held");
  const noop = await api(base, { action: "start", profile: "proof-lean", prompt: "noop", idempotency_key: "noop-1" });
  check(noop.status === 200 && noop.value && noop.value.subagent_id && !noop.value.error, `a second child fills the second pool slot: ${JSON.stringify(noop.value)}`);
  await until(() => held.length >= 2, "the second child's model request is held");
  check((await fetch(base + "/health", { signal: AbortSignal.timeout(3000) })).ok, "health is responsive while both child slots are held");
  const heldList = await api(base, { action: "list" });
  check(heldList.status === 200 && heldList.value && (heldList.value.subagents || []).length >= 2, "the control plane lists the two held children while inference is saturated");
  check(effectLines().every((line) => line.body !== "yes, 3pm"), "the WhatsApp effect is not sent while the child is held");
  const chats = await Promise.all(["A", "B"].map(async (name) => {
    const response = await fetch(base + "/chat", {
      method: "POST",
      headers: { "content-type": "application/json", accept: "text/event-stream" },
      body: JSON.stringify({ thread: "wa-fixture-" + name, text: "INTERACTIVE_" + name }),
      signal: AbortSignal.timeout(15000),
    });
    return { name, status: response.status, text: await response.text() };
  }));
  for (const chat of chats) {
    check(chat.status === 200 && chat.text.includes("ANSWER_" + chat.name), `interactive ${chat.name} answered while both child slots are held`);
    check(!chat.text.includes("ANSWER_" + (chat.name === "A" ? "B" : "A")), `interactive ${chat.name} has no other session's marker`);
    check((chat.text.match(/"type"\s*:\s*"done"/g) || []).length === 1, `interactive ${chat.name} has exactly one terminal done`);
  }
  // Release the held children; the actual WhatsApp chain then runs to completion.
  holdChildren = false;
  for (const item of held) item.deliver();
  held.length = 0;
  await until(() => effectLines().some((line) => line.body === "yes, 3pm"), "fake send invoked once");
  await until(() => job(jobEnv, "history").some((delivery) => delivery.job_id === "wa-allowed" && delivery.state === "completed"), "allowed delivery completed");
  const allowedEffects = effectLines().filter((line) => line.body === "yes, 3pm");
  check(allowedEffects.length === 1, `exactly one durable effect for the allowed message (got ${allowedEffects.length})`);
  check(allowedEffects[0] && allowedEffects[0].chat === CONV, "the fake send received the exact recipient");
  check(allowedEffects[0] && allowedEffects[0].account === ACCOUNT, "the fake send proved the bound account");
  const allowedChild = fs.existsSync(path.join(config, "subagents")) ? fs.readdirSync(path.join(config, "subagents")) : [];
  requireDependency(allowedChild.length > 0, "child_root_uses_WASM_AGENT_HOME (no records under the isolated config)");
  emit("wa.allowed", "allowed-1", { message_id: MSG_ALLOWED });
  await sleep(800);
  check(effectLines().filter((line) => line.body === "yes, 3pm").length === 1, "a repeated delivery does not send a second effect");

  // ---- denied run: general bash and a foreign chat are refused by actual dispatch ------------------
  check(emit("wa.deny", "deny-1", { message_id: MSG_DENY }).queued === 1, "denial event enqueued");
  await until(() => job(jobEnv, "history").some((delivery) => delivery.job_id === "wa-deny" && ["completed", "failed", "unknown", "cancelled"].includes(delivery.state)), "denial delivery settled");
  check(!fs.existsSync(path.join(root, "pwned.txt")), "the general shell was never executed");
  check(effectLines().every((line) => line.body !== "foreign"), "a foreign conversation was never sent to");

  // ---- restart ambiguity: a reservation persists across a node restart -----------------------------
  check(effectLines().filter((line) => line.body === "crash-body").length === 0, "no crash effect before the scenario");
  if (child && child.exitCode === null) child.kill();
  await Promise.race([new Promise((resolve) => child.once("exit", resolve)), sleep(5000)]);
  child = startNode({ ...env, WA_FAKE_MODE: "block" }, port);
  await until(async () => { try { return (await fetch(base + "/health", { signal: AbortSignal.timeout(500) })).ok; } catch { return false; } }, "node restarted", 15000);
  check(emit("wa.crash", "crash-1", { message_id: MSG_CRASH }).queued === 1, "crash event enqueued after restart");
  await until(() => effectLines().filter((line) => line.body === "crash-body").length === 1, "crash send began and blocked", 20000);
  await sleep(1500);
  // The send is blocked before confirmation. Kill only the test-owned node and the blocked fake sender.
  const crashChild = child;
  if (crashChild && crashChild.exitCode === null) crashChild.kill();
  await Promise.race([new Promise((resolve) => crashChild.once("exit", resolve)), sleep(5000)]);
  // The node died WHILE the fake sender was still blocked after recording the effect: that is the crash
  // window. Only now clean up the orphaned fake sender.
  const pidFile = counter + ".pid";
  if (fs.existsSync(pidFile)) { try { process.kill(Number(fs.readFileSync(pidFile, "utf8"))); } catch { /* already gone */ } }
  // Restart the same home and resubmit the same source message under a fresh delivery.
  child = startNode({ ...env, WA_FAKE_MODE: "ok" }, port);
  await until(async () => { try { return (await fetch(base + "/health", { signal: AbortSignal.timeout(500) })).ok; } catch { return false; } }, "node restarted for replay", 15000);
  check(emit("wa.crash", "crash-2", { message_id: MSG_CRASH }).queued === 1, "replay event enqueued with a fresh delivery");
  const findRecord = (key) => {
    const records = fs.existsSync(path.join(config, "subagents")) ? fs.readdirSync(path.join(config, "subagents")) : [];
    for (const name of records) {
      try {
        const record = JSON.parse(fs.readFileSync(path.join(config, "subagents", name, "record.json"), "utf8"));
        if (record.idempotency_key === key || String(record.idempotency_key || "").endsWith(key)) return record;
      } catch { /* not it */ }
    }
    return null;
  };
  await until(() => { const record = findRecord(":crash-2"); return record && record.result && record.result.reply; }, "replay child settled", 30000);
  const replayRecord = findRecord(":crash-2");
  check(replayRecord && String((replayRecord.result || {}).reply) === "child-crash-refused", "the replay refused the pending reservation instead of sending");
  check(effectLines().filter((line) => line.body === "crash-body").length === 1, "a pending reservation is never sent twice");
  const killedRecord = findRecord(":crash-1");
  check(killedRecord && killedRecord.state !== "completed", "the child killed mid-send is never reported completed");

  // ---- an unknown credential cannot spawn the operator whatsapp profile ----------------------------
  const guestProbe = await api(base, { action: "start", profile: "whatsapp-responder", prompt: "guest", idempotency_key: "guest-1" }, { "x-wa-session": "definitely-not-a-credential" });
  check(guestProbe.status !== 200 || (guestProbe.value && (guestProbe.value.error || !guestProbe.value.subagent_id)), "an unknown credential cannot spawn the operator profile");

  if (failures > 0) {
    writeVerdict("failed", { error: failureList.join(" | ") });
    console.error(`FAILED: ${failures} check(s): ${failureList.join(" | ")}`);
    console.error("evidence: " + root);
    process.exitCode = 1;
    return;
  }
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
