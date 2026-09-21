// Hermetic integration proof for the `subagent` job action and portable artifact import.
//
// It starts a real sentinel watcher against an isolated home and a local `/subagents` protocol fixture
// (no model, no paid inference), and proves the contract the runtime worker's node will implement:
//
//   * an artifact is exported and imported through the public `wa-sentinel job import` CLI;
//   * import installs the job DISABLED; enabling is separate;
//   * an eligible event reaches POST /subagents with the exact profile, prompt and
//     `job:revision:event_id` idempotency key;
//   * the delivery settles `completed` only when the service reports a settled child;
//   * a settled child is never spawned twice, and a repeated delivery is deduplicated by the job store;
//   * a child that never settles becomes `unknown` and is never retried;
//   * reserved child capacity runs a subagent while the node reports busy, and without it the delivery
//     waits in the queue until the node is idle;
//   * a guest import is refused even when the artifact claims `owner: operator`;
//   * the scoped WhatsApp tools deny reads/sends outside the profile's scope.
//
// Only processes started by this fixture are stopped, and never by image name.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const http = require("node:http");
const assert = require("node:assert/strict");
const { spawn, spawnSync } = require("node:child_process");

const root = fs.mkdtempSync(path.join(os.tmpdir(), "wa-subagents-"));
const repo = path.resolve(__dirname, "..");
const sentinel = path.resolve(process.argv[2] || path.join(repo, "rust/wa-sentinel/target/release", process.platform === "win32" ? "wa-sentinel.exe" : "wa-sentinel"));
const wa = path.resolve(process.argv[3] || path.join(repo, "rust/target/release", process.platform === "win32" ? "wa.exe" : "wa"));

let checked = 0;
let children = [];
const servers = [];
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
function check(value, label) { assert.ok(value, label); checked += 1; }
async function until(f, label, ms = 15000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const value = await f();
    if (value) return value;
    await sleep(100);
  }
  throw new Error("Timed out: " + label);
}
function cli(env, ...args) {
  const result = spawnSync(sentinel, ["job", ...args], { env, encoding: "utf8", timeout: 15000, windowsHide: true });
  if (result.status !== 0) throw new Error(`job ${args.join(" ")} failed: ${result.stderr || result.stdout || result.error?.message}`);
  return JSON.parse(result.stdout);
}
function cliFailure(env, ...args) {
  const result = spawnSync(sentinel, ["job", ...args], { env, encoding: "utf8", timeout: 15000, windowsHide: true });
  return { status: result.status, output: `${result.stderr || ""}${result.stdout || ""}` };
}
function child(exe, args, env, home) {
  const log = fs.openSync(path.join(home, `child-${children.length}.log`), "a");
  const processHandle = spawn(exe, args, { env, stdio: ["ignore", log, log], windowsHide: true });
  children.push(processHandle);
  return processHandle;
}

// The node fixture: `/health` and the `/subagents` protocol. `mode` decides whether an await settles.
async function nodeFixture() {
  const state = { busy: true, mode: "complete", starts: [], awaits: 0, health: [], cancels: [] };
  const seen = new Map();
  const server = http.createServer((req, res) => {
    if (req.url === "/health") {
      state.health.push(state.busy);
      res.setHeader("content-type", "application/json");
      // The sentinel's idle contract requires a workers[] array; its absence is ambiguous, not idle.
      res.end(JSON.stringify({ ok: true, current: state.busy ? { label: "POST /chat" } : null,
        queue: 0, operation_overdue: false, workers: [{ state: "alive" }] }));
      return;
    }
    if (req.url === "/subagents" && req.method === "POST") {
      let body = "";
      req.on("data", (chunk) => { body += chunk; });
      req.on("end", async () => {
        let request = {};
        try { request = JSON.parse(body); } catch { /* reported below */ }
        if (request.action === "start") {
          const existing = seen.get(request.idempotency_key);
          const id = existing || `sub-${state.starts.length + 1}`;
          request.assigned_id = id;
          state.starts.push(request);
          if (!existing) seen.set(request.idempotency_key, id);
          res.setHeader("content-type", "application/json");
          res.end(JSON.stringify({ subagent_id: id, state: "running", settled: false, session_id: "fixture", queue_position: 0, duplicate: !!existing }));
          return;
        }
        if (request.action === "await") {
          state.awaits += 1;
          await sleep(200);
          // The service decides the terminal view; the sentinel must treat only a settled `completed`
          // with no error as success, and everything else as failed or unknown.
          const modes = {
            complete: { state: "completed", settled: true, result: { ok: true }, error: null },
            unknown_settled: { state: "unknown", settled: true, result: null, error: null },
            completed_unsettled: { state: "completed", settled: false, result: null, error: null },
            completed_with_error: { state: "completed", settled: true, result: { ok: false }, error: "boom" },
            failed: { state: "failed", settled: true, result: null, error: "boom" },
            cancelled: { state: "cancelled", settled: true, result: null, error: null },
            hang: { state: "running", settled: false, result: null, error: null },
          };
          const view = modes[state.mode] || modes.complete;
          res.setHeader("content-type", "application/json");
          res.end(JSON.stringify({ subagent_id: request.subagent_id, ...view }));
          return;
        }
        if (request.action === "cancel") {
          state.cancels.push(request.subagent_id);
          res.setHeader("content-type", "application/json");
          res.end(JSON.stringify({ subagent_id: request.subagent_id, state: "cancelled", settled: true }));
          return;
        }
        res.statusCode = 400;
        res.end(JSON.stringify({ error: "unknown_action" }));
      });
      return;
    }
    res.statusCode = 404;
    res.end("{}");
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  servers.push(server);
  return { state, port: server.address().port };
}

function envFor(home, port, extra = {}) {
  const env = {
    ...process.env,
    WASM_AGENT_HOME: home,
    WASM_AGENT_PORT: String(port),
    WASM_AGENT_RELAY: "",
    WASM_AGENT_RENDEZVOUS: "",
    WASM_AGENT_MANAGED: "0",
    WA_SENTINEL_WAKE_BUDGET: "6",
    ...extra,
  };
  delete env.WA_SCRIPT;
  delete env.WASM_AGENT_LUA_ROOT;
  return env;
}

// Write a subagent job, export it as a portable artifact, and import it through the public CLI.
function artifactFixture(home, env, id) {
  const job = {
    id,
    name: "Answer a message",
    trigger: { kind: "event", topic: "fixture.message" },
    action: { kind: "subagent", profile: "whatsapp-responder", prompt: "Decide; never send without approval.", timeout_seconds: 6 },
  };
  const jobFile = path.join(home, `${id}.json`);
  fs.writeFileSync(jobFile, JSON.stringify(job));
  cli(env, "put", jobFile);
  const artifact = cli(env, "export", id);
  const artifactFile = path.join(home, `${id}.artifact.json`);
  fs.writeFileSync(artifactFile, JSON.stringify(artifact));
  const bindingsFile = path.join(home, `${id}.bindings.json`);
  fs.writeFileSync(bindingsFile, "{}");
  return { artifact, artifactFile, bindingsFile };
}

// Emit one event and wait for its delivery (the newest for the job) to reach a terminal state.
async function emitAndSettle(env, fixture, home, jobId, messageId, mode, timeoutMs = 30000) {
  fixture.state.mode = mode;
  const before = cli(env, "history").filter((d) => d.job_id === jobId).length;
  const file = path.join(home, `${messageId}.json`);
  fs.writeFileSync(file, JSON.stringify({ conversation_id: "c@c.us", message_id: messageId, eligibility: { eligible: true } }));
  cli(env, "emit", "fixture.message", messageId, file);
  return until(() => {
    const rows = cli(env, "history").filter((d) => d.job_id === jobId);
    if (rows.length <= before) return null;
    const newest = rows[0];
    return ["completed", "failed", "unknown", "cancelled"].includes(newest.state) ? newest : null;
  }, `${messageId} -> ${mode}`, timeoutMs);
}

async function main() {
  check(fs.existsSync(sentinel), `sentinel binary exists: ${sentinel}`);
  check(fs.existsSync(wa), `wa binary exists: ${wa}`);

  // ---- fixture A: reserved child capacity runs while the node is busy ----------------------------
  const homeA = path.join(root, "home-a");
  fs.mkdirSync(homeA, { recursive: true });
  const fixtureA = await nodeFixture();
  const envA = envFor(homeA, fixtureA.port, { WA_SENTINEL_JOB_RESERVED_CHILD_CAPACITY: "1" });
  const { artifact, artifactFile, bindingsFile } = artifactFixture(homeA, envA, "responder");

  // Export never carries a machine binding or credential, and the subagent action survives the round trip.
  check(artifact.schema === "wasm-agent/automation" && artifact.schema_version === 1, "artifact is versioned");
  check(artifact.action.kind === "subagent" && artifact.action.profile === "whatsapp-responder", "subagent profile survives export");
  check(!JSON.stringify(artifact).includes("C:/") && !JSON.stringify(artifact).includes("ws://127.0.0.1"), "artifact carries no machine binding");

  const imported = cli(envA, "import", artifactFile, "--bindings", bindingsFile, "--approve");
  check(imported.job.enabled === false, "import installs the job disabled");
  const enabled = cli(envA, "enable", "responder");
  check(enabled.enabled === true, "enabling is a separate deliberate act");
  const revision = enabled.revision;

  // Guest import of the same artifact, claiming operator scope, is refused.
  const guest = cliFailure(envA, "import", artifactFile, "--bindings", bindingsFile, "--approve", "--as-role", "guest");
  check(guest.status !== 0 && guest.output.includes("guest_artifact_profile_not_permitted"), "guest import cannot spoof owner=operator or select an operator profile");

  const watcherA = child(sentinel, ["watch"], envA, homeA);
  check(cli(envA, "emit", "fixture.message", "m1", (() => { const f = path.join(homeA, "m1.json"); fs.writeFileSync(f, JSON.stringify({ conversation_id: "c@c.us", message_id: "m1", eligibility: { eligible: true } })); return f; })()).queued === 1, "eligible event enqueued");
  const expectedKey = `responder:${revision}:m1`;
  await until(() => fixtureA.state.starts.some((s) => s.idempotency_key === expectedKey), "subagent start posted while the node reports busy");
  const start = fixtureA.state.starts.find((s) => s.idempotency_key === expectedKey);
  check(start.profile === "whatsapp-responder", "start carries the profile");
  check(typeof start.prompt === "string" && start.prompt.includes("never send"), "start carries the approved prompt");
  check(start.context && start.context.conversation_id === "c@c.us", "start carries the trusted event context");
  check(start.delivery_id !== undefined, "start carries the delivery id");
  check(fixtureA.state.health.some((busy) => busy === true), "the node reported busy while the subagent ran (reserved capacity)");
  check(cli(envA, "history").find((d) => d.job_id === "responder").state === "running", "a non-settled child leaves the delivery running, not completed");

  // Settlement is driven by the service's settled result.
  fixtureA.state.mode = "complete";
  await until(() => cli(envA, "history").some((d) => d.job_id === "responder" && d.state === "completed"), "delivery settles completed after the child settles");
  check(cli(envA, "history").filter((d) => d.job_id === "responder").length === 1, "one delivery produced one settlement");
  check(fixtureA.state.starts.length === 1, "one start for one delivery");

  // Idempotency: the store dedupes the stable event id, and the service would reconcile a repeated key.
  check(cli(envA, "emit", "fixture.message", "m1", path.join(homeA, "m1.json")).queued === 0, "same event id is not enqueued twice");
  await sleep(800);
  check(fixtureA.state.starts.length === 1, "the repeated event started no second child");

  // A child that never settles is `unknown`, and the same message is never retried.
  const m2 = path.join(homeA, "m2.json");
  fs.writeFileSync(m2, JSON.stringify({ conversation_id: "c@c.us", message_id: "m2", eligibility: { eligible: true } }));
  fixtureA.state.mode = "hang";
  check(cli(envA, "emit", "fixture.message", "m2", m2).queued === 1, "a second eligible event is enqueued");
  await until(() => cli(envA, "history").some((d) => d.job_id === "responder" && d.state === "unknown"), "a hanging child becomes unknown", 20000);
  const m2Starts = fixtureA.state.starts.filter((s) => s.idempotency_key === `responder:${revision}:m2`).length;
  check(m2Starts === 1, "an unknown outcome is not retried");
  check(cli(envA, "history").find((d) => d.job_id === "responder").state !== "completed", "unknown is not reported as completed");

  // Only a settled `completed` with no error is success. Every other terminal view is failed or unknown -
  // a `settled:true` with `state:"unknown"` used to be reported as success.
  check((await emitAndSettle(envA, fixtureA, homeA, "responder", "o_complete", "complete")).state === "completed", "a settled completed child completes the job");
  check((await emitAndSettle(envA, fixtureA, homeA, "responder", "o_unknown", "unknown_settled")).state === "unknown", "settled:true with state unknown is NOT success");
  check((await emitAndSettle(envA, fixtureA, homeA, "responder", "o_unsettled", "completed_unsettled")).state === "unknown", "completed without settled is unknown, never success");
  check((await emitAndSettle(envA, fixtureA, homeA, "responder", "o_error", "completed_with_error")).state === "unknown", "completed with an error/ok:false is not success");
  check((await emitAndSettle(envA, fixtureA, homeA, "responder", "o_failed", "failed")).state === "failed", "a failed child is a failed job");
  check((await emitAndSettle(envA, fixtureA, homeA, "responder", "o_cancelled", "cancelled")).state === "failed", "a cancelled child is not success");

  // A job disabled while its child runs must cancel the owned child and settle the delivery, not leave it
  // running or replay it.
  fixtureA.state.mode = "hang";
  const dFile = path.join(homeA, "d1.json");
  fs.writeFileSync(dFile, JSON.stringify({ conversation_id: "c@c.us", message_id: "d1", eligibility: { eligible: true } }));
  cli(envA, "emit", "fixture.message", "d1", dFile);
  await until(() => fixtureA.state.starts.some((s) => s.idempotency_key.endsWith(":d1")), "disabled-case child started");
  const d1Start = fixtureA.state.starts.find((s) => s.idempotency_key.endsWith(":d1"));
  cli(envA, "disable", "responder");
  await until(() => fixtureA.state.cancels.includes(d1Start.assigned_id), "disabled job cancels its owned child", 15000);
  await until(() => cli(envA, "history").some((d) => d.job_id === "responder" && d.state === "cancelled"), "disabled job settles the delivery cancelled", 15000);
  check(fixtureA.state.starts.filter((s) => s.idempotency_key.endsWith(":d1")).length === 1, "a cancelled child is not respawned");

  // ---- fixture B: without reserved capacity, an inference action waits for idle ------------------
  const homeB = path.join(root, "home-b");
  fs.mkdirSync(homeB, { recursive: true });
  const fixtureB = await nodeFixture();
  const envB = envFor(homeB, fixtureB.port, { WA_SENTINEL_JOB_RESERVED_CHILD_CAPACITY: "0" });
  const b = artifactFixture(homeB, envB, "waiter");
  cli(envB, "enable", "waiter");
  const watcherB = child(sentinel, ["watch"], envB, homeB);
  const mb = path.join(homeB, "mb.json");
  fs.writeFileSync(mb, JSON.stringify({ conversation_id: "c@c.us", message_id: "b1", eligibility: { eligible: true } }));
  cli(envB, "emit", "fixture.message", "b1", mb);
  await sleep(1800);
  check(fixtureB.state.starts.length === 0, "without reserved capacity and a busy node, the subagent waits (no POST /subagents)");
  check(cli(envB, "history").some((d) => d.job_id === "waiter" && d.state === "queued"), "the waiting delivery stays durably queued");
  fixtureB.state.busy = false;
  await until(() => fixtureB.state.starts.length === 1, "the subagent starts once the node is idle");
  await until(() => cli(envB, "history").some((d) => d.job_id === "waiter" && d.state === "completed"), "the waiting delivery completes");

  // ---- scoped tools deny reads/sends outside the profile -----------------------------------------
  const scoped = spawnSync(wa, ["--db", path.join(root, "scoped.db")], {
    env: { ...envFor(homeA, fixtureA.port), WASM_AGENT_LUA_ROOT: repo, WA_SCRIPT: path.join(repo, "tests", "whatsapp-scoped.lua") },
    encoding: "utf8",
    timeout: 30000,
    windowsHide: true,
  });
  check(scoped.stdout.includes("whatsapp scoped ok"), `scoped WhatsApp denial suite runs in the isolated home: ${scoped.stderr.slice(0, 200)}`);

  void watcherA; void watcherB;
  console.log(`subagent integration ok (${checked} checks; real sentinel, protocol fixture, no paid inference)`);
  console.log(`evidence: ${root}`);
  // The gate's fixture verdict requires a terminal `ALL PASS` line (scripts/lib/test-verdict.cjs).
  console.log("ALL PASS");
}

(async () => {
  try {
    await main();
  } catch (error) {
    console.error(error.stack || String(error));
    console.error("evidence: " + root);
    process.exitCode = 1;
  } finally {
    for (const server of servers) { try { await new Promise((resolve) => server.close(resolve)); } catch { /* already closed */ } }
    for (const processHandle of children.reverse()) {
      if (processHandle.exitCode === null) {
        processHandle.kill();
        await Promise.race([new Promise((resolve) => processHandle.once("exit", resolve)), sleep(3000)]);
      }
    }
  }
})();
