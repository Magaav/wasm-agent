#!/usr/bin/env node
// Hermetic proof for the `onSubagentReturn` hook, driven through the Engine's own job machinery.
//
//   node scripts/test-subagent-return-hook.cjs [sentinel-executable]
//
// No model, no provider, no paid inference, no real node: one real sentinel watcher against an isolated
// home, a fake `/subagents` + `/chat` endpoint, and real git checkouts so the deploy verdict is measured
// rather than asserted. What it proves:
//
//   * `jobs/on-subagent-return.json` is installed by the same path every other job uses and appears in
//     `wa-sentinel job list` with its trigger (event `subagent.return`) and its action (a wake whose
//     `prepare` step is the deterministic block);
//   * the deterministic source (`jobs/subagent-return-observe.json` -> scripts/subagent-return-observe.sh)
//     notices EVERY settled child, in every state - completed, refused, cancelled, error - and emits one
//     event per child, deduplicated by the child's own id, while a child that has not settled is not
//     reported at all;
//   * each event produces one wake, and the wake message carries the injected block: the child id and
//     state, its branch and tip and worktree, the DEPLOY VERDICT, and the operating instruction for that
//     verdict - computed from the child's own diff against origin/main;
//   * both verdicts are driven: a child that changed `ui/**` is "deploy required at the wave's end", a
//     child that changed only documentation or tests is "no install impact";
//   * a child whose artifacts cannot be read says so, and never reports "no install impact";
//   * the path predicate is load-bearing: adding or removing a path flips the verdict, and mutating the
//     predicate constant itself flips it back (a mutation test, not a re-statement of the rule);
//   * firing the hook costs no provider call: the only outbound traffic is one wake message per settled
//     child to the node, and the injection step completes with the node not listening at all.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const http = require("node:http");
const assert = require("node:assert/strict");
const { spawn, spawnSync } = require("node:child_process");

const root = fs.mkdtempSync(path.join(os.tmpdir(), "wa-subagent-return-"));
const repo = path.resolve(__dirname, "..");
const sentinel = path.resolve(process.argv[2] || path.join(repo, "rust/wa-sentinel/target/release", process.platform === "win32" ? "wa-sentinel.exe" : "wa-sentinel"));

let checked = 0;
const children = [];
const requests = [];
const wakes = [];
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
function check(value, label) {
  assert.ok(value, label);
  checked += 1;
}
async function until(f, label, ms = 40000) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const value = await f();
    if (value) return value;
    await sleep(100);
  }
  throw new Error("Timed out: " + label);
}
function cli(env, ...args) {
  const result = spawnSync(sentinel, ["job", ...args], { env, encoding: "utf8", timeout: 20000, windowsHide: true });
  if (result.status !== 0) throw new Error(`job ${args.join(" ")} failed: ${result.stderr || result.stdout || result.error?.message}`);
  return JSON.parse(result.stdout);
}
function child(exe, args, env) {
  const log = fs.openSync(path.join(root, `child-${children.length}.log`), "a");
  const handle = spawn(exe, args, { env, stdio: ["ignore", log, log], windowsHide: true });
  children.push(handle);
  return handle;
}
function git(...args) {
  const result = spawnSync("git", args, { encoding: "utf8", timeout: 60000, windowsHide: true });
  if (result.status !== 0) throw new Error(`git ${args.join(" ")} failed: ${result.stderr || result.error?.message}`);
  return result.stdout.trim();
}
// The same shell `shell_for` in rust/wa-sentinel/src/main.rs hands a job's script to.
function jobShell() {
  if (process.platform !== "win32") return { program: "sh", args: [] };
  for (const candidate of ["C:\\Program Files\\Git\\bin\\bash.exe", "C:\\Program Files\\Git\\usr\\bin\\bash.exe", "C:\\Program Files (x86)\\Git\\bin\\bash.exe"]) {
    if (fs.existsSync(candidate)) return { program: candidate, args: [] };
  }
  return { program: "bash", args: [] };
}

/// One real checkout: an integration branch `origin/main`, and a child branch whose commits differ from it
/// in exactly one path. This is the input the hook's verdict is measured from; nothing about the diff is
/// fabricated.
function childCheckout(name, changedPath) {
  const dir = path.join(root, name);
  fs.mkdirSync(dir, { recursive: true });
  git("init", "-q", "-b", "main", dir);
  git("-C", dir, "config", "user.email", "fixture@example.invalid");
  git("-C", dir, "config", "user.name", "fixture");
  fs.writeFileSync(path.join(dir, "README.md"), "fixture\n");
  git("-C", dir, "add", "-A");
  git("-C", dir, "commit", "-qm", "base");
  git("-C", dir, "update-ref", "refs/remotes/origin/main", "HEAD");
  git("-C", dir, "checkout", "-qb", `change/${name}`);
  const target = path.join(dir, changedPath);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, `changed by ${name}\n`);
  git("-C", dir, "add", "-A");
  git("-C", dir, "commit", "-qm", `work from ${name}`);
  return { worktree: dir, branch: `change/${name}`, head: git("-C", dir, "rev-parse", "HEAD") };
}

function packet(checkout, session, parent, extra = {}) {
  return {
    child: { id: extra.child_id, state: extra.state, profile: "task-worker" },
    session: { id: session, parent },
    artifacts: checkout === null
      ? { available: false, reason: "artifact_facts_failed: no session record" }
      : { available: true, managed: true, state: "clean", worktree: checkout.worktree, recorded_branch: checkout.branch,
          branch: checkout.branch, head: checkout.head, ahead: 1, behind: 0, pushed: false, dirty: 0, untracked: 0 },
    review: { needs_wake: true, kind: "evaluation", reason: "delivery_ready_to_evaluate" },
  };
}

function task(id, state, settled, extra = {}) {
  return { subagent_id: id, state, settled, session_id: `session-${id}`, profile: "task-worker",
    parent_session_id: "session-orchestrator", execution_node: "local", created_at: 1, ...extra };
}

async function main() {
  check(fs.existsSync(sentinel), `sentinel binary exists: ${sentinel}`);
  const CHILDREN = [
    { id: "child-completed-ui", state: "completed", settled: true, changed: "ui/app.js", verdict: "deploy required at the wave's end", instruction: "exactly ONE deploy" },
    { id: "child-refused-docs", state: "refused", settled: true, changed: "docs/JOBS.md", verdict: "no install impact", instruction: "no deploy is owed for it" },
    { id: "child-cancelled-script", state: "cancelled", settled: true, changed: "scripts/whatsapp-read.mjs", verdict: "deploy required at the wave's end", instruction: "exactly ONE deploy" },
    { id: "child-error-tests", state: "failed", settled: true, changed: "tests/fixture.cjs", verdict: "no install impact", instruction: "no deploy is owed for it" },
    { id: "child-unknown-unreadable", state: "unknown", settled: true, changed: null, verdict: "cannot be computed", instruction: "NOT established" },
  ];
  for (const entry of CHILDREN) {
    entry.checkout = entry.changed === null ? null : childCheckout(entry.id, entry.changed);
  }
  const live = task("child-still-running", "running", false);

  let server;
  const requestSummary = () => [...new Set(requests.map((entry) => entry.path))].sort().join(",");
  server = http.createServer(async (request, response) => {
    let body = "";
    for await (const chunk of request) body += chunk;
    requests.push({ path: request.url, at: Date.now(), body });
    if (request.url === "/health") {
      response.setHeader("content-type", "application/json");
      response.end(JSON.stringify({ ok: true, current: null }));
      return;
    }
    if (request.url === "/subagents") {
      const call = body ? JSON.parse(body) : {};
      response.setHeader("content-type", "application/json");
      if ((call.action || "list") === "list") {
        const tasks = CHILDREN.map((entry) => task(entry.id, entry.state, entry.settled)) ;
        tasks.push(live);
        response.end(JSON.stringify({ subagents: tasks }));
        return;
      }
      const entry = CHILDREN.find((candidate) => candidate.id === call.id);
      if (!entry) {
        response.end(JSON.stringify({ error: "unknown_subagent" }));
        return;
      }
      response.end(JSON.stringify({
        ...task(entry.id, entry.state, entry.settled),
        completion: { child_id: entry.id, state: entry.state, run_id: 1, detail: `{"state":"${entry.state}"}`,
          packet: JSON.stringify(packet(entry.checkout, `session-${entry.id}`, "session-orchestrator",
            { child_id: entry.id, state: entry.state })) },
      }));
      return;
    }
    if (request.url === "/chat") {
      const payload = JSON.parse(body);
      wakes.push({ thread: payload.thread, text: payload.text });
      response.writeHead(200, { "Content-Type": "text/event-stream" });
      response.end('data: {"type":"reply","text":"fixture"}\n\ndata: {"type":"done"}\n\n');
      return;
    }
    response.writeHead(404);
    response.end();
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const port = server.address().port;

  const env = { ...process.env, WASM_AGENT_HOME: root, WASM_AGENT_PORT: String(port),
    // Both budget names explicitly: the claim lane reads WA_SENTINEL_JOB_WAKE_BUDGET first, and an
    // ambient value from the live node (6) would otherwise decide this fixture's lane capacity.
    WA_SENTINEL_WAKE_BUDGET: "24", WA_SENTINEL_JOB_WAKE_BUDGET: "24", WA_SENTINEL_JOB_RESERVED_CHILD_CAPACITY: "1",
    WA_SENTINEL_SCRIPTS: `${path.join(repo, "scripts")};${root}`, WA_SENTINEL_BIN: sentinel,
    WA_SENTINEL_AUTH_SESSION: "fixture-auth-session",
    WA_SENTINEL_RETURN_STATE: path.join(root, "subagent-return-reported.json"),
    WASM_AGENT_RELAY: "", WASM_AGENT_RENDEZVOUS: "", WASM_AGENT_MANAGED: "0" };
  delete env.WA_SCRIPT;
  delete env.WASM_AGENT_LUA_ROOT;

  // The shipped definitions, installed exactly as an install would: the placeholder names the directory
  // the hook's scripts live in, and the coordinator conversation is bound locally.
  const definitions = ["on-subagent-return", "subagent-return-observe"].map((name) => {
    const source = fs.readFileSync(path.join(repo, "jobs", `${name}.json`), "utf8");
    const prepared = source.replaceAll("PREPARED_BY_INSTALL", path.join(repo).replaceAll("\\", "/"))
      .replaceAll("COORDINATOR_SESSION_ID", "fixture-orchestrator");
    const file = path.join(root, `${name}.json`);
    fs.writeFileSync(file, prepared);
    return file;
  });
  for (const file of definitions) cli(env, "put", file);
  const listed = cli(env, "list");
  const hook = listed.find((job) => job.id === "onSubagentReturn");
  const source = listed.find((job) => job.id === "subagent-return-observe");
  check(!!hook && !!source, "both job definitions are in the Engine's store");
  check(hook.trigger.kind === "event" && hook.trigger.topic === "subagent.return",
    "the hook is listed with its trigger: event subagent.return");
  check(hook.action.kind === "wake" && hook.action.session === "fixture-orchestrator",
    "the hook's action is a wake to the bound coordinator conversation");
  check(hook.action.prepare.script.endsWith("scripts/subagent-return-prepare.sh"),
    "the hook's wake carries the deterministic prepare step");
  check(hook.action.prompt.includes("never one install per child"),
    "the hook's action carries the fixed operating instruction");
  check(hook.enabled === false && source.enabled === false, "a freshly installed definition is disabled");
  check(source.trigger.kind === "schedule" && source.action.kind === "run",
    "the deterministic source is listed as a schedule -> run job");
  process.stdout.write(`--- wa-sentinel job list (the two hook rows) ---\n${JSON.stringify(
    listed.filter((job) => job.id === "onSubagentReturn" || job.id === "subagent-return-observe"), null, 2)}\n`);

  // A fixture copy of the source with a short interval, so the schedule lane itself is what runs it.
  const fixtureSource = JSON.parse(fs.readFileSync(definitions[1], "utf8"));
  fixtureSource.id = "subagent-return-observe-fixture";
  fixtureSource.trigger.every_seconds = 2;
  const fixtureFile = path.join(root, "observe-fixture.json");
  fs.writeFileSync(fixtureFile, JSON.stringify(fixtureSource));
  cli(env, "put", fixtureFile);
  cli(env, "enable", "onSubagentReturn");
  cli(env, "enable", "subagent-return-observe-fixture");

  child(sentinel, ["watch"], env);
  await until(() => wakes.length === CHILDREN.length, "one wake per settled child");
  await sleep(3000); // a second observation pass: dedupe must not produce a second wake for any child

  check(wakes.length === CHILDREN.length, `every settled child woke the orchestrator exactly once (${wakes.length} wakes for ${CHILDREN.length} settles)`);
  check(wakes.every((wake) => wake.thread === "fixture-orchestrator"), "each wake goes to the coordinator conversation, not the auth header");
  check(!wakes.some((wake) => wake.text.includes("child-still-running")), "a child that has not settled is not reported");
  for (const entry of CHILDREN) {
    const wake = wakes.find((candidate) => candidate.text.includes(entry.id));
    check(!!wake, `${entry.id} (${entry.state}) produced a wake`);
    const text = wake.text;
    check(text.includes("[Sentinel notice]"), `${entry.id}: the sentinel provenance reaches the transcript first`);
    check(text.includes("[onSubagentReturn] deterministic child-return hook"),
      `${entry.id}: the injected instruction block is in the message`);
    check(text.includes(`state: ${entry.state}   settled: yes`), `${entry.id}: the child's state is in the block`);
    check(text.includes("DEPLOY VERDICT: ") , `${entry.id}: the block carries a deploy verdict`);
    if (entry.checkout) {
      check(text.includes(`branch: ${entry.checkout.branch}`) && text.includes(`tip: ${entry.checkout.head}`),
        `${entry.id}: the branch and tip of its own checkout are in the block`);
      check(text.includes(`worktree: ${entry.checkout.worktree.replaceAll("\\", "/")}`)
        || text.includes(entry.checkout.worktree), `${entry.id}: its worktree is named`);
      check(text.includes(`changed paths vs origin/main: 1`), `${entry.id}: the diff against origin/main was measured`);
    }
    check(text.includes(`DEPLOY VERDICT: ${entry.verdict}`), `${entry.id}: verdict "${entry.verdict}"`);
    check(text.includes(entry.instruction), `${entry.id}: the operating instruction for that verdict is injected`);
    // Authority, not data: the block is injected *before* the untrusted event section, so the instruction
    // cannot be mistaken for event content and event content cannot become the instruction.
    check(text.indexOf("[onSubagentReturn]") < text.indexOf("BEGIN UNTRUSTED EVENT DATA"),
      `${entry.id}: the instruction block sits before the untrusted event block`);
  }
  process.stdout.write(`--- the injected block, as it reached the orchestrator for ${CHILDREN[0].id} ---\n`
    + `${wakes.find((wake) => wake.text.includes(CHILDREN[0].id)).text.split("BEGIN UNTRUSTED EVENT DATA")[0]}\n`
    + `--- and for the child whose artifacts could not be read ---\n`
    + `${wakes.find((wake) => wake.text.includes("child-unknown-unreadable")).text.split("BEGIN UNTRUSTED EVENT DATA")[0]}\n`);
  const unreadable = wakes.find((wake) => wake.text.includes("child-unknown-unreadable")).text;
  check(unreadable.includes("artifacts: UNREADABLE"), "an unreadable checkout is named as unreadable");
  check(unreadable.includes("not measured") || unreadable.includes("NOT MEASURED"),
    "an unreadable checkout does not report a measured diff");
  check(!unreadable.includes("DEPLOY VERDICT: no install impact"),
    "an unreadable checkout never reports 'no install impact'");
  check(wakes.filter((wake) => wake.text.includes("DEPLOY VERDICT: deploy required at the wave's end")).length === 2,
    "both deploy-shipping children were reported as deploy-required");
  check(wakes.filter((wake) => wake.text.includes("DEPLOY VERDICT: no install impact")).length === 2,
    "both non-shipping children were reported as having no install impact");

  // Firing the hook is a script and a diff, never an inference call.
  const paths = new Set(requests.map((entry) => entry.path));
  check([...paths].every((entry) => ["/health", "/chat", "/subagents"].includes(entry)),
    `the hook's firing touches no model endpoint (paths seen: ${requestSummary()})`);
  check(requests.filter((entry) => entry.path === "/chat").length === CHILDREN.length,
    "exactly one message per settled child was submitted to the node - the hook's own wake");
  const history = cli(env, "history").filter((entry) => entry.job_id === "onSubagentReturn");
  check(history.some((entry) => entry.state === "completed"), "the hook's deliveries settle completed in the job history");

  // A second, explicit observation pass: the child ids are the event ids, so the job store's own dedupe
  // is what stops a wake per poll. Spawned asynchronously on purpose: this fixture *is* the fake node, and
  // a blocking spawn would freeze the event loop the observation pass has to reach.
  const direct = await new Promise((resolve) => {
    const shell = jobShell();
    const handle = spawn(shell.program, [...shell.args, path.join(repo, "scripts", "subagent-return-observe.sh")],
      { env, stdio: ["ignore", "pipe", "pipe"], windowsHide: true });
    let stdout = "";
    let stderr = "";
    handle.stdout.on("data", (chunk) => { stdout += chunk; });
    handle.stderr.on("data", (chunk) => { stderr += chunk; });
    handle.on("close", (code) => resolve({ status: code, stdout, stderr }));
  });
  check(direct.status === 0, `the source's own pass runs clean (exit ${direct.status}: ${direct.stderr.trim().slice(0, 300)})`);
  check(JSON.parse(direct.stdout).emitted === 0, "a second pass over the same children emits nothing new");
  await sleep(2500);
  check(wakes.length === CHILDREN.length, "a repeated observation pass wakes nobody twice");

  // The rules that keep `prepare` a step and not a second action language: a wake without one is unchanged,
  // a `prepare` outside a wake is refused by name, and a step that hands on nothing refuses the wake rather
  // than sending a message with an empty instruction in it.
  const putJob = (definition) => {
    const file = path.join(root, `${definition.id}.json`);
    fs.writeFileSync(file, JSON.stringify(definition));
    return cli(env, "put", file);
  };
  const emit = (topic, id, payload) => {
    const file = path.join(root, `event-${id}.json`);
    fs.writeFileSync(file, JSON.stringify(payload));
    return cli(env, "emit", topic, id, file);
  };
  putJob({ id: "fixture-plain-wake", name: "fixture plain wake", trigger: { kind: "event", topic: "fixture.plain" },
    action: { kind: "wake", session: "fixture-orchestrator", prompt: "PLAIN WAKE FIXTURE" } });
  cli(env, "enable", "fixture-plain-wake");
  emit("fixture.plain", "plain-1", { text: "data" });
  await until(() => wakes.some((wake) => wake.text.includes("PLAIN WAKE FIXTURE")), "plain wake delivered");
  const plainWake = wakes.find((wake) => wake.text.includes("PLAIN WAKE FIXTURE"));
  check(!plainWake.text.includes("[onSubagentReturn]"), "a wake with no prepare carries no injected block");
  check(plainWake.text.includes('Automation job "fixture-plain-wake"') && plainWake.text.includes("BEGIN UNTRUSTED EVENT DATA"),
    "a wake with no prepare is unchanged in shape");
  putJob({ id: "fixture-prepare-misuse", name: "a prepare outside a wake is refused",
    trigger: { kind: "event", topic: "fixture.misuse" },
    action: { kind: "run", script: path.join(repo, "scripts", "subagent-return-prepare.sh"), timeout_seconds: 30,
      prepare: { script: path.join(repo, "scripts", "subagent-return-prepare.sh") } } });
  cli(env, "enable", "fixture-prepare-misuse");
  emit("fixture.misuse", "misuse-1", {});
  await until(() => cli(env, "history").some((entry) => entry.job_id === "fixture-prepare-misuse" && entry.state === "failed"),
    "a prepare on a run action is refused");
  check(cli(env, "history").find((entry) => entry.job_id === "fixture-prepare-misuse").detail.includes("prepare_is_only_for_a_wake_action"),
    "the refusal names the rule instead of ignoring the knob");
  const brokenPrepare = path.join(root, "broken-prepare.sh");
  // A step that succeeds and hands on nothing: the delivery must fail rather than wake someone with an
  // empty instruction block in the message.
  fs.writeFileSync(brokenPrepare, "#!/usr/bin/env bash\nset -uo pipefail\nprintf ''\nexit 0\n");
  putJob({ id: "fixture-broken-prepare", name: "a prepare that hands on nothing refuses the wake",
    trigger: { kind: "event", topic: "fixture.broken" },
    action: { kind: "wake", session: "fixture-orchestrator", prompt: "SHOULD NOT BE SENT",
      prepare: { script: brokenPrepare, timeout_seconds: 30 } } });
  cli(env, "enable", "fixture-broken-prepare");
  emit("fixture.broken", "broken-1", {});
  await until(() => cli(env, "history").some((entry) => entry.job_id === "fixture-broken-prepare" && entry.state === "failed"),
    "a prepare that hands on nothing fails the delivery");
  check(cli(env, "history").find((entry) => entry.job_id === "fixture-broken-prepare").detail.includes("wake prepare step"),
    "the failing delivery says which step failed");
  check(!wakes.some((wake) => wake.text.includes("SHOULD NOT BE SENT")),
    "no message was submitted for the wake whose instruction block could not be built");

  // The path predicate, falsified two ways: a path added or removed from the same diff, and the
  // predicate constant itself mutated.
  const verdict = (...paths) => JSON.parse(spawnSync(process.execPath,
    [path.join(repo, "scripts", "subagent-return-hook.mjs"), "--verdict", ...paths.flatMap((entry) => ["--path", entry])],
    { encoding: "utf8", windowsHide: true }).stdout);
  check(verdict("docs/notes.md").verdict === "no install impact", "documentation only: no install impact");
  check(verdict("docs/notes.md", "ui/app.js").verdict === "deploy required at the wave's end",
    "adding one shipped path flips the verdict to deploy required");
  check(verdict("docs/notes.md").verdict === "no install impact", "removing it flips the verdict back");
  check(verdict("scripts/delivery-record.mjs").verdict === "no install impact",
    "a script a deploy does not copy is not deploy impact");
  check(verdict("scripts/deploy.sh").verdict === "deploy required at the wave's end", "deploy.sh itself is shipped");
  const mutantFile = path.join(root, "mutant-hook.mjs");
  fs.writeFileSync(mutantFile, fs.readFileSync(path.join(repo, "scripts", "subagent-return-hook.mjs"), "utf8")
    .replace("const DEPLOY_SHIPPED_DIRECTORIES = ['ui/', 'rust/', 'lua/', 'skills/'];",
      "const DEPLOY_SHIPPED_DIRECTORIES = ['ui-x/', 'rust/', 'lua/', 'skills/'];"));
  const mutant = JSON.parse(spawnSync(process.execPath, [mutantFile, "--verdict", "--path", "ui/app.js"],
    { encoding: "utf8", windowsHide: true }).stdout);
  check(mutant.verdict === "no install impact",
    "mutating the predicate's directory constant flips the verdict for the same path - the rule is load-bearing");
  const original = JSON.parse(spawnSync(process.execPath,
    [path.join(repo, "scripts", "subagent-return-hook.mjs"), "--verdict", "--path", "ui/app.js"],
    { encoding: "utf8", windowsHide: true }).stdout);
  check(original.verdict === "deploy required at the wave's end", "the unmutated rule still says deploy required");

  // The injection step with the node not listening at all: no network, no model, still a block.
  await new Promise((resolve) => server.close(resolve));
  const eventFile = path.join(root, "event.json");
  fs.writeFileSync(eventFile, JSON.stringify({
    child_id: "child-offline", state: "completed", settled: true, session: "session-offline", parent_session: "session-orchestrator",
    artifacts: { available: true, managed: true, worktree: path.join(root, "child-completed-ui"), branch: "change/child-completed-ui", head: "0".repeat(40) },
    changed_paths: ["lua/core/agent.lua"], changed_paths_source: "fixture",
  }));
  const offline = spawnSync(process.execPath,
    [path.join(repo, "scripts", "subagent-return-hook.mjs"), "--compose", "--event", eventFile],
    { encoding: "utf8", windowsHide: true, env: { ...env, WASM_AGENT_PORT: "1", WA_SENTINEL_AUTH_SESSION: "" } });
  check(offline.status === 0, `the injection step runs with the node unreachable (exit ${offline.status})`);
  const composed = JSON.parse(offline.stdout);
  check(composed.verdict === "deploy required at the wave's end" && composed.instruction.includes("DEPLOY VERDICT"),
    "with nothing listening it still composes the verdict and instruction - no provider call to fire the hook");
  check(requests.filter((entry) => entry.path === "/chat").length === CHILDREN.length + 1,
    "the unreachable-node pass added no wake and no model call");
  check(spawnSync(process.execPath, [path.join(repo, "scripts", "subagent-return-hook.mjs"), "--compose"],
    { encoding: "utf8", windowsHide: true }).status === 4, "a compose with no event is refused, not guessed");

  console.log(`subagent return ok (${checked} checks; real sentinel, real git checkouts, no model)\nevidence: ${root}`);
}

(async () => {
  try {
    await main();
  } catch (error) {
    console.error(error.stack);
    console.error("evidence: " + root);
    process.exitCode = 1;
  } finally {
    for (const handle of children) {
      try { handle.kill(); } catch {}
    }
    await sleep(500);
    if (process.exitCode !== 1) fs.rmSync(root, { recursive: true, force: true });
    // The fake node and the watcher are this fixture's own processes; nothing here waits on the event
    // loop to decide that the run is over.
    process.exit(process.exitCode || 0);
  }
})();
