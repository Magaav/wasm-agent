// The pipeline seam: what a `run` step hands on, and what a delivery says when it hands on nothing.
//
// Every bug of the copilot's first session lived here, and each was found by hand, in production: the
// reader's guard required WA_WHATSAPP_EMIT so the pipeline mode collected nothing; the runner never read
// the step's result; `returns` handed on the whole envelope, so `foreach` held an object where it wanted
// a list; and a delivery that handed on nothing looked exactly like one whose result was dropped.
//
// Hermetic: a real sentinel watcher against an isolated home, the "store" being the step's own script, and
// a protocol fixture for `/health` and `/subagents`. No model, no browser, no paid inference.
//
//   * a `returns` list reaches the `foreach`, which starts one child per item, keyed by the item's id;
//   * a `returns` step that produces nothing FAILS the delivery instead of reporting success;
//   * a no-op run is distinguishable from a dropped result: "pipeline completed 1 step(s), handed on 0 item(s)";
//   * an item with no key is refused, because it has no identity to dedupe a child on.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const http = require("node:http");
const assert = require("node:assert/strict");
const { spawn, spawnSync } = require("node:child_process");

const root = fs.mkdtempSync(path.join(os.tmpdir(), "wa-pipeline-"));
const repo = path.resolve(__dirname, "..");
const sentinel = path.resolve(process.argv[2] || path.join(repo, "rust/wa-sentinel/target/release", process.platform === "win32" ? "wa-sentinel.exe" : "wa-sentinel"));

let checked = 0;
const children = [];
const servers = [];
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
function check(value, label) { assert.ok(value, label); checked += 1; }
async function until(f, label, ms = 20000) {
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
function child(exe, args, env, home) {
  const log = fs.openSync(path.join(home, `child-${children.length}.log`), "a");
  const handle = spawn(exe, args, { env, stdio: ["ignore", log, log], windowsHide: true });
  children.push(handle);
  return handle;
}

// `/health` (idle, so an inference delivery is claimed without a reservation) and `/subagents` (the
// protocol fixture: a start is recorded and settles immediately).
async function nodeFixture() {
  const state = { starts: [], seen: new Map() };
  const server = http.createServer((req, res) => {
    if (req.url === "/health") {
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify({ ok: true, current: null, queue: 0, operation_overdue: false, workers: [{ state: "alive" }] }));
      return;
    }
    if (req.url === "/subagents" && req.method === "POST") {
      let body = "";
      req.on("data", (chunk) => { body += chunk; });
      req.on("end", () => {
        let request = {};
        try { request = JSON.parse(body); } catch { /* reported by the assertions */ }
        if (request.action === "start") {
          const existing = state.seen.get(request.idempotency_key);
          const id = existing || `sub-${state.starts.length + 1}`;
          state.starts.push(request);
          if (!existing) state.seen.set(request.idempotency_key, id);
          res.setHeader("content-type", "application/json");
          res.end(JSON.stringify({ subagent_id: id, state: "running", settled: false, session_id: "fixture", duplicate: !!existing }));
          return;
        }
        if (request.action === "await") {
          res.setHeader("content-type", "application/json");
          res.end(JSON.stringify({ subagent_id: request.subagent_id, state: "completed", settled: true, result: { ok: true }, error: null }));
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

function envFor(home, port) {
  const env = {
    ...process.env,
    WASM_AGENT_HOME: home,
    WASM_AGENT_PORT: String(port),
    WASM_AGENT_RELAY: "",
    WASM_AGENT_RENDEZVOUS: "",
    WASM_AGENT_MANAGED: "0",
    WA_SENTINEL_WAKE_BUDGET: "6",
    WA_SENTINEL_SCRIPTS: path.join(home, "scripts"),
  };
  delete env.WA_SCRIPT;
  delete env.WASM_AGENT_LUA_ROOT;
  return env;
}

// One `run` step's script. `print` is what the step's contract is about: exit 0 and one JSON object.
function stepScript(home, name, body) {
  const file = path.join(home, "scripts", name);
  fs.writeFileSync(file, `#!/usr/bin/env bash\n${body}\n`);
  return file;
}

function job(home, env, id, steps) {
  const file = path.join(home, `${id}.json`);
  fs.writeFileSync(file, JSON.stringify({
    id, name: id, trigger: { kind: "event", topic: `fixture.${id}` },
    action: { kind: "pipeline", steps },
  }));
  cli(env, "put", file);
  return cli(env, "enable", id);
}

async function deliver(env, home, id, eventId) {
  const before = cli(env, "history").filter((row) => row.job_id === id).length;
  const file = path.join(home, `${eventId}.json`);
  fs.writeFileSync(file, JSON.stringify({ conversation_id: "c@c.us", message_id: eventId, eligibility: { eligible: true } }));
  // One topic per job: a shared topic delivers one event to every enabled subscriber, which would make
  // each assertion here depend on the others' deliveries.
  cli(env, "emit", `fixture.${id}`, eventId, file);
  return until(() => {
    const rows = cli(env, "history").filter((row) => row.job_id === id);
    if (rows.length <= before) return null;
    const newest = rows[0];
    return ["completed", "failed", "unknown", "cancelled"].includes(newest.state) ? newest : null;
  }, `${id}: ${eventId} settles`);
}

async function main() {
  check(fs.existsSync(sentinel), `sentinel binary exists: ${sentinel}`);
  const home = path.join(root, "home");
  fs.mkdirSync(path.join(home, "scripts"), { recursive: true });
  const fixture = await nodeFixture();
  const env = envFor(home, fixture.port);
  const list = stepScript(home, "list.sh", `printf '%s' '{"events":[{"message_id":"m1"},{"message_id":"m2"}]}'`);
  const empty = stepScript(home, "empty.sh", "exit 0");
  const noop = stepScript(home, "noop.sh", `printf '%s' '{"events":[]}'`);
  const nokey = stepScript(home, "nokey.sh", `printf '%s' '{"events":[{"conversation_id":"c@c.us"}]}'`);
  const foreach = (max = 8) => ({ kind: "foreach", from: "events", key: "message_id", max,
    step: { kind: "subagent", profile: "whatsapp-responder", prompt: "Decide; never send without approval.", timeout_seconds: 6 } });

  const withList = job(home, env, "pipeline-list", [{ kind: "run", script: list, returns: "events", timeout_seconds: 30 }, foreach()]);
  const withEmpty = job(home, env, "pipeline-empty", [{ kind: "run", script: empty, returns: "events", timeout_seconds: 30 }]);
  const withNoop = job(home, env, "pipeline-noop", [{ kind: "run", script: noop, returns: "events", timeout_seconds: 30 }]);
  const withNoKey = job(home, env, "pipeline-nokey", [{ kind: "run", script: nokey, returns: "events", timeout_seconds: 30 }, foreach()]);

  const watcher = child(sentinel, ["watch"], env, home);

  // ---- a `returns` list reaches the foreach, one child per item, keyed by the item's id -------------
  const listed = await deliver(env, home, "pipeline-list", "e-list");
  check(listed.state === "completed", `a pipeline whose step hands on a list completes: ${listed.detail}`);
  check(/pipeline completed 2 step\(s\), handed on 2 item\(s\)/.test(listed.detail || ""),
    `the delivery says how much it handed on: ${listed.detail}`);
  check(fixture.state.starts.length === 2, `the foreach started one child per item (got ${fixture.state.starts.length})`);
  const keys = fixture.state.starts.map((start) => start.idempotency_key).sort();
  check(keys.join(",") === `pipeline-list:${withList.revision}:m1,pipeline-list:${withList.revision}:m2`,
    `each child's idempotency key is the item's own id: ${keys.join(",")}`);
  check(fixture.state.starts.every((start) => start.profile === "whatsapp-responder"), "each child carries the profile");
  check(fixture.state.starts.map((start) => start.event && start.event.message_id).sort().join(",") === "m1,m2",
    "each child's trusted event names its own item, not the pipeline's event");

  // ---- a `returns` step that produces nothing fails the delivery ------------------------------------
  const dropped = await deliver(env, home, "pipeline-empty", "e-empty");
  check(dropped.state === "failed", `a returns step that produced nothing fails the delivery (got ${dropped.state}: ${dropped.detail})`);
  check(/promised a result with `returns` and produced none/.test(dropped.detail || ""),
    `the failure names the rule: ${dropped.detail}`);

  // ---- a no-op run is not the same thing as a dropped result ----------------------------------------
  const emptyRun = await deliver(env, home, "pipeline-noop", "e-noop");
  check(emptyRun.state === "completed", `a step that found nothing completes: ${emptyRun.state}: ${emptyRun.detail}`);
  check(/pipeline completed 1 step\(s\), handed on 0 item\(s\)/.test(emptyRun.detail || ""),
    `a no-op delivery says it handed on nothing: ${emptyRun.detail}`);
  check(emptyRun.detail !== dropped.detail, "a no-op run and a dropped result are distinguishable in the history");

  // ---- an item with no key is refused: it has no identity to dedupe on ------------------------------
  const noKey = await deliver(env, home, "pipeline-nokey", "e-nokey");
  check(noKey.state === "failed", `an item without the key fails the delivery (got ${noKey.state}: ${noKey.detail})`);
  check(/an item has no "message_id"/.test(noKey.detail || ""), `the failure names the missing key: ${noKey.detail}`);
  check(fixture.state.starts.length === 2, "the refused foreach started no child");
  void withEmpty; void withNoKey; void watcher;

  console.log(`pipeline seam ok (${checked} checks, 0 failed, 0 skipped; real sentinel, mock store, no paid inference)`);
  console.log(`evidence: ${root}`);
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
    for (const handle of children.reverse()) {
      if (handle.exitCode === null) {
        handle.kill();
        await Promise.race([new Promise((resolve) => handle.once("exit", resolve)), sleep(3000)]);
      }
    }
  }
})();
