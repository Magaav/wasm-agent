#!/usr/bin/env node
// Hermetic proof for the `onSubagentReturn` hook, driven through the Engine's own job machinery.
//
//   node scripts/test-subagent-return-hook.cjs [sentinel-executable]
//
// No model, no provider, no paid inference, no real node: one real sentinel watcher against an isolated
// home, a fake `/subagents` + `/chat` endpoint, and real git checkouts so the deploy verdict is measured
// rather than asserted. What it proves:
//
//   * `jobs/on-subagent-return.json` is installed by the same path every other job uses, appears in
//     `wa-sentinel job list` with its trigger (event `subagent.return`) and its action (a wake whose
//     `prepare` step is the deterministic block, whose `dedupe_key` is the child id, and which declares
//     that it supersedes the completion outbox's notice), and installs DISABLED;
//   * the deterministic source (`jobs/subagent-return-observe.json` -> scripts/subagent-return-observe.sh)
//     notices EVERY settled child, in every state - completed, refused, cancelled, error - and emits one
//     event per child, while a child that has not settled is not reported at all;
//   * each event produces one wake, and the wake message carries the injected block: the child id and
//     state, the notification facts, its branch and tip and worktree, the DEPLOY VERDICT, and the
//     operating instruction for that verdict - computed from the child's own diff against origin/main;
//   * the shipped set is the one scripts/deploy-shipped.json declares, which
//     scripts/check-deploy-shipped.mjs re-derives from the installers: `jobs/**` and `scripts/upgrade.sh`
//     are deploy impact, and a manifest missing either makes that check go red;
//   * both verdicts are driven, and every way of *not* knowing reads `cannot be computed` rather than
//     "no install impact": unreadable artifacts, no merge base with origin/main, and a checkout that
//     reports uncommitted work the pass cannot measure;
//   * a child whose tip equals main but whose worktree holds an uncommitted shipped change IS deploy
//     impact - the verdict line does not ignore the uncommitted half;
//   * the dedupe is pinned: the event id is the child's id (a fresh cursor over the same children emits
//     nothing), and a definition re-put plus a lost cursor cannot produce a second wake, because the
//     sentinel's wake ledger is keyed on the child id rather than on the job revision;
//   * the cursor converges: after a lost cursor the pass reconciles through the store's own receipt
//     instead of re-emitting the same child for ever;
//   * `prepare` is refused at `job put` when it is not a top-level wake's own step (a pipeline step
//     carrying one used to be accepted and silently ignored);
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
function cliFailure(env, ...args) {
  const result = spawnSync(sentinel, ["job", ...args], { env, encoding: "utf8", timeout: 20000, windowsHide: true });
  return { status: result.status, output: `${result.stdout || ""}${result.stderr || ""}` };
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
/// fabricated. `dirty` writes the change without committing it (the uncommitted half), `orphan` gives the
/// branch a history with no common ancestor at all.
function childCheckout(name, changedPath, { dirty = false, orphan = false } = {}) {
  const dir = path.join(root, name);
  fs.mkdirSync(dir, { recursive: true });
  git("init", "-q", "-b", "main", dir);
  git("-C", dir, "config", "user.email", "fixture@example.invalid");
  git("-C", dir, "config", "user.name", "fixture");
  fs.writeFileSync(path.join(dir, "README.md"), "fixture\n");
  git("-C", dir, "add", "-A");
  git("-C", dir, "commit", "-qm", "base");
  git("-C", dir, "update-ref", "refs/remotes/origin/main", "HEAD");
  const write = (target) => {
    const file = path.join(dir, target);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, `changed by ${name}\n`);
  };
  if (orphan) {
    git("-C", dir, "checkout", "-q", "--orphan", `change/${name}`);
    git("-C", dir, "rm", "-rq", "--cached", ".");
    write(changedPath);
    git("-C", dir, "add", "-A");
    git("-C", dir, "commit", "-qm", `orphan work from ${name}`);
  } else {
    git("-C", dir, "checkout", "-qb", `change/${name}`);
    write(changedPath);
    if (!dirty) {
      git("-C", dir, "add", "-A");
      git("-C", dir, "commit", "-qm", `work from ${name}`);
    }
  }
  return { worktree: dir, branch: `change/${name}`, head: git("-C", dir, "rev-parse", "HEAD") };
}

function packet(checkout, session, parent, extra = {}) {
  return {
    child: { id: extra.child_id, state: extra.state, profile: "task-worker", model: "fixture-model",
      served_model: "fixture-model", provider: "mock", reasoning: "high" },
    session: { id: session, parent, duration_s: 12.5, started_at: 1, settled_at: 13 },
    usage: { available: true, prompt_tokens: 100, completion_tokens: 20, total_tokens: 120 },
    artifacts: checkout === null
      ? { available: false, reason: "artifact_facts_failed: no session record" }
      : { available: true, managed: true, state: "clean", worktree: checkout.worktree, recorded_branch: checkout.branch,
          branch: checkout.branch, head: checkout.head, ahead: 1, behind: 0, pushed: false,
          dirty: extra.dirty === undefined ? 0 : extra.dirty, untracked: 0 },
    review: { needs_wake: true, kind: "evaluation", reason: "delivery_ready_to_evaluate" },
  };
}

function task(id, state, settled, extra = {}) {
  return { subagent_id: id, state, settled, session_id: `session-${id}`, profile: "task-worker",
    parent_session_id: "session-orchestrator", execution_node: "local", created_at: 1, ...extra };
}

const CHILDREN = [
  { id: "child-completed-ui", state: "completed", changed: "ui/app.js", verdict: "deploy required at the wave's end", instruction: "exactly ONE deploy" },
  { id: "child-refused-docs", state: "refused", changed: "docs/JOBS.md", verdict: "no install impact", instruction: "no deploy is owed for it" },
  { id: "child-cancelled-script", state: "cancelled", changed: "scripts/whatsapp-read.mjs", verdict: "deploy required at the wave's end", instruction: "exactly ONE deploy" },
  { id: "child-error-tests", state: "failed", changed: "tests/fixture.cjs", verdict: "no install impact", instruction: "no deploy is owed for it" },
  { id: "child-unknown-unreadable", state: "unknown", changed: null, verdict: "cannot be computed", instruction: "NOT established" },
  // The uncommitted half: the tip IS origin/main, and the shipped change is in the worktree.
  { id: "child-dirty-shipped", state: "completed", changed: "ui/app.js", dirty: true, packetDirty: 1,
    verdict: "deploy required at the wave's end", instruction: "exactly ONE deploy" },
  // No common ancestor with origin/main: no base for the diff, so no verdict.
  { id: "child-no-merge-base", state: "completed", changed: "rust/wa-sentinel/src/main.rs", orphan: true,
    verdict: "cannot be computed", instruction: "NOT established" },
  // The two classes the hand-written predicate missed (the reviewer's findings 1 and 2).
  { id: "child-job-definition", state: "completed", changed: "jobs/whatsapp-copilot.json",
    verdict: "deploy required at the wave's end", instruction: "exactly ONE deploy" },
  { id: "child-upgrade-script", state: "completed", changed: "scripts/upgrade.sh",
    verdict: "deploy required at the wave's end", instruction: "exactly ONE deploy" },
  // The recorded checkout says there is uncommitted work; this pass can see none. The two disagree, and
  // the disagreement is a refusal to answer.
  { id: "child-dirty-unmeasurable", state: "completed", changed: "docs/notes.md", packetDirty: 1,
    verdict: "cannot be computed", instruction: "NOT established" },
];
const LIVE = task("child-still-running", "running", false);

async function main() {
  check(fs.existsSync(sentinel), `sentinel binary exists: ${sentinel}`);
  for (const entry of CHILDREN) {
    entry.checkout = entry.changed === null ? null
      : childCheckout(entry.id, entry.changed, { dirty: entry.dirty === true, orphan: entry.orphan === true });
  }

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
        const tasks = CHILDREN.map((entry) => task(entry.id, entry.state, true));
        tasks.push(LIVE);
        response.end(JSON.stringify({ subagents: tasks }));
        return;
      }
      const entry = CHILDREN.find((candidate) => candidate.id === call.id);
      if (!entry) {
        response.end(JSON.stringify({ error: "unknown_subagent" }));
        return;
      }
      response.end(JSON.stringify({
        ...task(entry.id, entry.state, true),
        completion: { child_id: entry.id, state: entry.state, run_id: 1, detail: `{"state":"${entry.state}"}`,
          packet: JSON.stringify(packet(entry.checkout, `session-${entry.id}`, "session-orchestrator",
            { child_id: entry.id, state: entry.state, dirty: entry.packetDirty })) },
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
    // ambient value from the live node (6) would otherwise decide this fixture's lane capacity. The figure is
    // generous on purpose: a *suppressed* wake delivery (one the ledger answers `already_woken`) is still
    // claimed and executed, so it still spends this allowance - the fixture drives more deliveries than it
    // sends messages.
    WA_SENTINEL_WAKE_BUDGET: "200", WA_SENTINEL_JOB_WAKE_BUDGET: "200", WA_SENTINEL_JOB_RESERVED_CHILD_CAPACITY: "1",
    WA_SENTINEL_SCRIPTS: `${path.join(repo, "scripts")};${root}`, WA_SENTINEL_BIN: sentinel,
    WA_SENTINEL_AUTH_SESSION: "fixture-auth-session",
    WA_SENTINEL_RETURN_STATE: path.join(root, "subagent-return-reported.json"),
    WASM_AGENT_RELAY: "", WASM_AGENT_RENDEZVOUS: "", WASM_AGENT_MANAGED: "0" };
  delete env.WA_SCRIPT;
  delete env.WASM_AGENT_LUA_ROOT;

  const stateFile = env.WA_SENTINEL_RETURN_STATE;
  const sentinelDir = path.join(root, ".wasm-agent", "sentinel");
  const markerFile = path.join(sentinelDir, "completion-wake-superseded");
  const ledgerFile = path.join(sentinelDir, "wake-dedupe-onSubagentReturn.json");

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
  check(hook.action.dedupe_key === "child_id", "the hook's wake names the child id as its dedupe key");
  check(hook.supersedes === "completion_wake", "the hook declares that it supersedes the outbox notice");
  check(hook.action.prompt.includes("never one install per child"),
    "the hook's action carries the fixed operating instruction");
  check(hook.enabled === false && source.enabled === false, "a freshly installed definition is disabled");
  check(source.trigger.kind === "schedule" && source.action.kind === "run",
    "the deterministic source is listed as a schedule -> run job");
  process.stdout.write(`--- wa-sentinel job list (the two hook rows) ---\n${JSON.stringify(
    listed.filter((job) => job.id === "onSubagentReturn" || job.id === "subagent-return-observe"), null, 2)}\n`);

  // `prepare` is a wake's own step. A pipeline step carrying one used to be accepted by `job put` and
  // then silently ignored, so the definition boundary refuses it by name.
  const misuse = { id: "fixture-pipeline-prepare", name: "a prepare inside a pipeline step is refused",
    trigger: { kind: "event", topic: "fixture.pipeline" },
    action: { kind: "pipeline", steps: [{ kind: "run", script: path.join(repo, "scripts", "subagent-return-observe.sh"),
      timeout_seconds: 30, prepare: { script: path.join(repo, "scripts", "subagent-return-prepare.sh") } }] } };
  const misuseFile = path.join(root, "pipeline-prepare.json");
  fs.writeFileSync(misuseFile, JSON.stringify(misuse));
  const refusedPut = cliFailure(env, "put", misuseFile);
  check(refusedPut.status !== 0, "job put refuses a prepare inside a pipeline step");
  check(refusedPut.output.includes("prepare_is_only_for_a_wake_action"),
    `the refusal names the rule: ${refusedPut.output.trim().slice(0, 160)}`);
  check(!cli(env, "list").some((job) => job.id === "fixture-pipeline-prepare"),
    "and the refused definition was not stored");
  const misuseWake = { ...misuse, id: "fixture-run-prepare",
    action: { kind: "run", script: path.join(repo, "scripts", "subagent-return-observe.sh"), timeout_seconds: 30,
      prepare: { script: path.join(repo, "scripts", "subagent-return-prepare.sh") } } };
  const misuseWakeFile = path.join(root, "run-prepare.json");
  fs.writeFileSync(misuseWakeFile, JSON.stringify(misuseWake));
  check(cliFailure(env, "put", misuseWakeFile).output.includes("prepare_is_only_for_a_wake_action"),
    "job put refuses a prepare on a run action too");

  // A fixture copy of the source with a short interval, so the schedule lane itself is what runs it.
  const fixtureSource = JSON.parse(fs.readFileSync(definitions[1], "utf8"));
  fixtureSource.id = "subagent-return-observe-fixture";
  fixtureSource.trigger.every_seconds = 2;
  const fixtureFile = path.join(root, "observe-fixture.json");
  fs.writeFileSync(fixtureFile, JSON.stringify(fixtureSource));
  cli(env, "put", fixtureFile);
  cli(env, "enable", "onSubagentReturn");
  // The supersede marker follows the CLI's own enable/disable immediately - before the watcher exists, so no
  // tick can be what wrote it. A marker that only appeared on a tick left a window in which a child settling
  // between `job enable` and that tick was announced twice (the supersede-ordering finding).
  check(fs.existsSync(markerFile), "job enable writes the supersede marker with the enable, before any tick");
  cli(env, "disable", "onSubagentReturn");
  check(!fs.existsSync(markerFile), "job disable removes it with the disable, before any tick");
  cli(env, "enable", "onSubagentReturn");
  check(fs.existsSync(markerFile), "and re-enabling writes it again");
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
    check(text.includes("notification: model: fixture-model") && text.includes("duration_s: 12.5"),
      `${entry.id}: the notification facts are in the block, so this message IS the notice`);
    check(text.includes("DEPLOY VERDICT: "), `${entry.id}: the block carries a deploy verdict`);
    if (entry.checkout) {
      check(text.includes(`branch: ${entry.checkout.branch}`) && text.includes(`tip: ${entry.checkout.head}`),
        `${entry.id}: the branch and tip of its own checkout are in the block`);
      check(text.includes(entry.checkout.worktree), `${entry.id}: its worktree is named`);
    }
    check(text.includes(`DEPLOY VERDICT: ${entry.verdict}`), `${entry.id}: verdict "${entry.verdict}"`);
    check(text.includes(entry.instruction), `${entry.id}: the operating instruction for that verdict is injected`);
    // Authority, not data: the block is injected *before* the untrusted event section, so the instruction
    // cannot be mistaken for event content and event content cannot become the instruction.
    check(text.indexOf("[onSubagentReturn]") < text.indexOf("BEGIN UNTRUSTED EVENT DATA"),
      `${entry.id}: the instruction block sits before the untrusted event block`);
  }
  const blockFor = (id) => wakes.find((wake) => wake.text.includes(id)).text.split("BEGIN UNTRUSTED EVENT DATA")[0];
  check(blockFor("child-dirty-shipped").includes("uncommitted: ui/app.js"),
    "the uncommitted half is measured and named for a tip that equals main");
  check(blockFor("child-dirty-shipped").includes("changed paths vs origin/main: 1"),
    "an uncommitted shipped change counts as a changed path");
  check(blockFor("child-no-merge-base").includes("no_merge_base_with_origin_main"),
    "a branch with no merge base names that as the reason");
  check(blockFor("child-dirty-unmeasurable").includes("uncommitted_work_reported_but_not_measurable"),
    "recorded uncommitted work the pass could not see is named, not ignored");
  check(blockFor("child-job-definition").includes("jobs/whatsapp-copilot.json"),
    "a job definition is deploy impact end to end");
  check(blockFor("child-upgrade-script").includes("scripts/upgrade.sh"),
    "upgrade.sh is deploy impact end to end");
  const unreadable = blockFor("child-unknown-unreadable");
  check(unreadable.includes("artifacts: UNREADABLE"), "an unreadable checkout is named as unreadable");
  check(unreadable.includes("NOT MEASURED"), "an unreadable checkout does not report a measured diff");
  check(!unreadable.includes("DEPLOY VERDICT: no install impact"),
    "an unreadable checkout never reports 'no install impact'");
  const verdicts = (name) => wakes.filter((wake) => wake.text.includes(`DEPLOY VERDICT: ${name}`)).length;
  check(verdicts("deploy required at the wave's end") === 5, "every deploy-shipping child was reported as deploy-required");
  check(verdicts("no install impact") === 2, "both non-shipping children were reported as having no install impact");
  check(verdicts("cannot be computed") === 3, "all three unmeasurable children read cannot be computed");
  process.stdout.write(`--- the injected block for ${CHILDREN[0].id} ---\n${blockFor(CHILDREN[0].id)}\n`
    + `--- and for the child whose tip equals main with an uncommitted shipped change ---\n${blockFor("child-dirty-shipped")}\n`);

  // The shipped set: the manifest the predicate reads, checked against the installers themselves - and
  // then the guard falsified, because a guard that derives less than it claims is how the class this hook
  // exists for went missing the first time. Every mutation below stayed GREEN before this pass: a manifest
  // entry dropped for `jobs/**` / `scripts/whatsapp-*` / `scripts/subagent-return-*` (the derivation missed
  // the quote-then-slash spelling deploy.sh uses for every glob), a plain `cp`/`install`, and a copied path
  // that is not in the tree (skipped with a note).
  const checker = path.join(repo, "scripts", "check-deploy-shipped.mjs");
  const runChecker = (args) => spawnSync(process.execPath, [checker, ...args], { encoding: "utf8", windowsHide: true, timeout: 120000 });
  const shippedCheck = runChecker([]);
  check(shippedCheck.status === 0, `check-deploy-shipped passes: ${(shippedCheck.stdout || shippedCheck.stderr).trim()}`);
  check(/deploy shipped ok \(\d+ checks/.test(shippedCheck.stdout || ""),
    "and prints one terminal verdict with its check count, so the gate can pin a floor");
  const baseManifest = JSON.parse(fs.readFileSync(path.join(repo, "scripts", "deploy-shipped.json"), "utf8"));
  const mutateManifest = (name, mutate) => {
    const manifest = JSON.parse(JSON.stringify(baseManifest));
    mutate(manifest);
    const file = path.join(root, name);
    fs.writeFileSync(file, JSON.stringify(manifest));
    return file;
  };
  const mutations = [
    ["jobs/** dropped", mutateManifest("m-jobs.json", (m) => { m.directories = m.directories.filter((entry) => entry !== "jobs/"); }), /FAIL the predicate covers jobs\//],
    ["scripts/whatsapp-* dropped", mutateManifest("m-whatsapp.json", (m) => { m.globs = m.globs.filter((entry) => entry !== "scripts/whatsapp-*"); }), /FAIL the predicate covers scripts\/whatsapp-/],
    ["scripts/subagent-return-* dropped", mutateManifest("m-sr.json", (m) => { m.globs = m.globs.filter((entry) => entry !== "scripts/subagent-return-*"); }), /FAIL the predicate covers scripts\/subagent-return-/],
    ["scripts/upgrade.sh dropped", mutateManifest("m-upgrade.json", (m) => { m.files = m.files.filter((entry) => entry !== "scripts/upgrade.sh"); }), /FAIL the predicate covers scripts\/upgrade\.sh/],
  ];
  for (const [label, file, expected] of mutations) {
    const result = runChecker([file]);
    check(result.status !== 0, `a manifest with ${label} makes the guard go red`);
    check(expected.test(result.stderr || ""),
      `and the failure names the path: ${label}: ${(result.stderr || "").trim().split("\n").filter((line) => line.includes("FAIL"))[0]}`);
  }
  // Mutations of the installers themselves: the guard must read every copy-like line, in every spelling,
  // and refuse to pass a rule it cannot instantiate.
  const installerMutations = [
    ["a plain cp of an uncovered path", '  cp "$ROOT/scripts/gate-lane.mjs" "$INSTALL_DIR/scripts/" || fail "m"', /FAIL the predicate covers scripts\/gate-lane\.mjs/],
    ["an install -m copy", '  install -m 644 "$ROOT/scripts/check-naming.sh" "$INSTALL_DIR/scripts/" || fail "m"', /FAIL the predicate covers scripts\/check-naming\.sh/],
    ["a copy of a path absent from the tree", '  cp -f "$ROOT/scripts/ghost-absent.mjs" "$INSTALL_DIR/scripts/" || fail "m"', /FAIL copies scripts\/ghost-absent\.mjs .*not in the tree/],
    ["a loop over an absent glob", '  for source in "$ROOT/scripts/ghost-glob-*"; do cp -f "$source" "$INSTALL_DIR/scripts/"; done', /FAIL the predicate covers scripts\/ghost-glob-probe/],
    ["a copy from a target/ nobody builds", '  cp -f "$ROOT/rust/plugins/nobody-builds-this/target/release/ghost.wasm" "$INSTALL_DIR/plugins/" || fail "m"', /FAIL copies rust\/plugins\/nobody-builds-this\/target\/release\/ghost\.wasm/],
  ];
  for (const [index, [label, line, expected]] of installerMutations.entries()) {
    const dir = path.join(root, `installers-${index}`);
    fs.mkdirSync(dir, { recursive: true });
    for (const name of ["deploy.sh", "upgrade.sh"]) fs.copyFileSync(path.join(repo, "scripts", name), path.join(dir, name));
    fs.appendFileSync(path.join(dir, "deploy.sh"), `\n${line}\n`);
    const result = runChecker(["--installers", dir]);
    check(result.status !== 0, `a deploy.sh with ${label} makes the guard go red`);
    check(expected.test(result.stderr || ""),
      `and the failure names it: ${label}: ${(result.stderr || "").trim().split("\n").filter((entry) => entry.includes("FAIL"))[0]}`);
  }
  // The build-output rule is derived, not "anything under target/": removing the build that produces a
  // copied output must turn that copy into an absent path.
  const noBuildDir = path.join(root, "installers-no-build");
  fs.mkdirSync(noBuildDir, { recursive: true });
  for (const name of ["deploy.sh", "upgrade.sh"]) fs.copyFileSync(path.join(repo, "scripts", name), path.join(noBuildDir, name));
  const pluginBuild = 'cargo build --manifest-path "$ROOT/rust/plugins/whatsapp-transcript/Cargo.toml"';
  const deployText = fs.readFileSync(path.join(noBuildDir, "deploy.sh"), "utf8");
  check(deployText.includes(pluginBuild), "the plugin build line is where this mutation expects it");
  fs.writeFileSync(path.join(noBuildDir, "deploy.sh"), deployText.replace(pluginBuild, `true # was: ${pluginBuild}`));
  const noBuild = runChecker(["--installers", noBuildDir]);
  check(noBuild.status !== 0, "removing the build that produces a copied output makes the guard go red");
  check(/FAIL copies rust\/plugins\/whatsapp-transcript\/target\/.*not in the tree and this installer does not build it/.test(noBuild.stderr || ""),
    `and it names the output nobody builds: ${(noBuild.stderr || "").trim().split("\n").filter((entry) => entry.includes("FAIL"))[0]}`);

  // Firing the hook is a script and a diff, never an inference call.
  const paths = new Set(requests.map((entry) => entry.path));
  check([...paths].every((entry) => ["/health", "/chat", "/subagents"].includes(entry)),
    `the hook's firing touches no model endpoint (paths seen: ${requestSummary()})`);
  check(requests.filter((entry) => entry.path === "/chat").length === CHILDREN.length,
    "exactly one message per settled child was submitted to the node - the hook's own wake");
  const history = cli(env, "history").filter((entry) => entry.job_id === "onSubagentReturn");
  check(history.some((entry) => entry.state === "completed"), "the hook's deliveries settle completed in the job history");

  // While the hook is enabled the sentinel marks the outbox notice superseded; the marker is derived from
  // the job store's own enabled state, and the outbox reads it (scripts/test-completion-wake.cjs proves
  // that half against a real node).
  await until(() => fs.existsSync(markerFile), "the supersede marker is written while the hook is enabled");
  const marker = JSON.parse(fs.readFileSync(markerFile, "utf8"));
  check(Array.isArray(marker.by) && marker.by.includes("onSubagentReturn"),
    `the marker names the job that supersedes the notice: ${JSON.stringify(marker.by)}`);
  check(fs.existsSync(ledgerFile), "the wake ledger is written beside the sentinel's own state");
  check(Object.keys(JSON.parse(fs.readFileSync(ledgerFile, "utf8")).keys).length === CHILDREN.length,
    "the ledger holds one key per settled child");

  // A second, explicit observation pass: the child ids are the event ids, so the store's own dedupe is
  // what stops a wake per poll. Spawned asynchronously on purpose: this fixture *is* the fake node, and a
  // blocking spawn would freeze the event loop the observation pass has to reach. The fixture's scheduled
  // copy of the source is disabled first: two passes writing one cursor file at once would race, and the
  // guarantee under test is the one a single pass gives.
  cli(env, "disable", "subagent-return-observe-fixture");
  const runObserver = (extraEnv = {}) => new Promise((resolve) => {
    const shell = jobShell();
    const handle = spawn(shell.program, [...shell.args, path.join(repo, "scripts", "subagent-return-observe.sh")],
      { env: { ...env, ...extraEnv }, stdio: ["ignore", "pipe", "pipe"], windowsHide: true });
    let stdout = "";
    let stderr = "";
    handle.stdout.on("data", (chunk) => { stdout += chunk; });
    handle.stderr.on("data", (chunk) => { stderr += chunk; });
    handle.on("close", (code) => resolve({ status: code, stdout, stderr }));
  });
  const direct = await runObserver();
  check(direct.status === 0, `the source's own pass runs clean (exit ${direct.status}: ${direct.stderr.trim().slice(0, 300)})`);
  check(JSON.parse(direct.stdout).emitted === 0, "a second pass over the same children emits nothing new");
  await sleep(2500);
  check(wakes.length === CHILDREN.length, "a repeated observation pass wakes nobody twice");

  // The dedupe key is pinned: with the cursor deleted, the event id is still the child's id, so the store
  // answers "this exact event exists" and the pass reconciles through its receipt instead of emitting.
  fs.rmSync(stateFile, { force: true });
  const lost = JSON.parse((await runObserver()).stdout);
  check(lost.emitted === 0 && lost.duplicates === CHILDREN.length,
    `a lost cursor emits nothing and reports the duplicates (${JSON.stringify({ emitted: lost.emitted, duplicates: lost.duplicates, reconciled: lost.reconciled })})`);
  check(lost.reconciled === CHILDREN.length, "and the pass reconciles each child through the store's receipt");
  const converged = JSON.parse((await runObserver()).stdout);
  check(converged.emitted === 0 && converged.duplicates === 0 && converged.known === CHILDREN.length,
    `the cursor converges: the next pass knows every child instead of re-emitting (${JSON.stringify(converged)})`);
  await sleep(1500);
  check(wakes.length === CHILDREN.length, "none of that produced a second wake");

  // The revision-independent guarantee: a definition re-put (or a disable/enable, which also moves the
  // revision) plus a lost cursor used to mean two deliveries and two wakes for one child. The sentinel's
  // ledger is keyed on the child id, so the second delivery completes without a second message.
  cli(env, "disable", "onSubagentReturn");
  cli(env, "enable", "onSubagentReturn");
  fs.rmSync(stateFile, { force: true });
  const afterRevision = JSON.parse((await runObserver()).stdout);
  check(afterRevision.emitted > 0, `a new revision lets the observer emit again (${JSON.stringify({ emitted: afterRevision.emitted })})`);
  await until(() => cli(env, "history").filter((entry) => entry.job_id === "onSubagentReturn")
    .some((entry) => (entry.detail || "").includes("already_woken")), "the second delivery is suppressed");
  await sleep(1500);
  check(wakes.length === CHILDREN.length, "a re-put plus a lost cursor does NOT produce a second wake per child");
  check(cli(env, "history").filter((entry) => entry.job_id === "onSubagentReturn")
    .every((entry) => !(entry.detail || "").includes("already_woken") || entry.state === "completed"),
    "the suppressed deliveries completed rather than failing");

  // A pending intent must reconcile against the payload it actually emitted (the cursor finding). The
  // measurement moving between the intent and the reconciliation used to make `payload_match` false, so the
  // pass re-emitted that child on every tick for ever: deduped, so no extra wake, but never settled.
  const reworkChild = CHILDREN[0].id;
  const wakesBeforeIntents = wakes.length;
  cli(env, "disable", "onSubagentReturn");
  fs.rmSync(stateFile, { force: true });
  const intentPass = JSON.parse((await runObserver()).stdout);
  check(intentPass.emitted === 0 && intentPass.duplicates === CHILDREN.length,
    `with the hook off every child stays a durable intent (${JSON.stringify({ emitted: intentPass.emitted, duplicates: intentPass.duplicates })})`);
  const savedPayload = (JSON.parse(fs.readFileSync(stateFile, "utf8")).pending[reworkChild] || {}).payload;
  check(!!savedPayload && savedPayload.child_id === reworkChild, "the intent carries the payload it emitted");
  cli(env, "enable", "onSubagentReturn");
  const deliveryPass = JSON.parse((await runObserver()).stdout);
  check(deliveryPass.emitted === CHILDREN.length, `re-enabling lets the intents through (${deliveryPass.emitted} deliveries)`);
  await sleep(1500);
  check(wakes.length === wakesBeforeIntents, "and the wake ledger still holds each child to one message");
  // Now the window the finding is about: a durable intent whose delivery exists, with the measurement moved
  // since. The store's receipt compares payloads, so only the emitted payload can match it.
  const hookRevision = cli(env, "list").find((job) => job.id === "onSubagentReturn").revision;
  const crafted = JSON.parse(fs.readFileSync(stateFile, "utf8"));
  delete crafted.reported[reworkChild];
  crafted.pending[reworkChild] = { event_id: reworkChild, at: new Date().toISOString(), revision: hookRevision, payload: savedPayload };
  fs.writeFileSync(stateFile, JSON.stringify(crafted));
  fs.mkdirSync(path.join(root, reworkChild, "ui"), { recursive: true });
  fs.writeFileSync(path.join(root, reworkChild, "ui", "second.js"), "another change\n");
  git("-C", path.join(root, reworkChild), "add", "-A");
  git("-C", path.join(root, reworkChild), "commit", "-qm", "more work");
  const reconcilePass = JSON.parse((await runObserver()).stdout);
  check(reconcilePass.emitted === 0 && reconcilePass.duplicates === 0 && reconcilePass.reconciled === 1 && reconcilePass.errors.length === 0,
    `a moved measurement still reconciles the intent through the payload it emitted (${JSON.stringify({ emitted: reconcilePass.emitted, duplicates: reconcilePass.duplicates, reconciled: reconcilePass.reconciled, errors: reconcilePass.errors })})`);
  const settled = JSON.parse((await runObserver()).stdout);
  check(settled.known === CHILDREN.length && settled.duplicates === 0 && settled.reconciled === 0,
    `and the cursor settles instead of re-emitting for ever (${JSON.stringify({ known: settled.known, duplicates: settled.duplicates, reconciled: settled.reconciled })})`);
  check(wakes.length === wakesBeforeIntents, "neither pass produced a second message for any child");

  // The wake ledger is bounded (the wake-ledger finding): it grew one entry per child ever woken. Seed it
  // past the bound, re-wake one child, and the file must come back bounded - newest keys kept, oldest
  // dropped. What the bound preserves is stated where it is implemented: a child that settles again is still
  // deduped while its key is inside the window.
  const ledgerSeeded = JSON.parse(fs.readFileSync(ledgerFile, "utf8"));
  const seedAt = Math.floor(Date.now() / 1000);
  for (let index = 0; index < 520; index += 1) {
    ledgerSeeded.keys[`synthetic-old-${index}`] = { at: seedAt - 100000 + index, delivery: 0 };
  }
  delete ledgerSeeded.keys[reworkChild];
  fs.writeFileSync(ledgerFile, JSON.stringify(ledgerSeeded));
  const stateForRewake = JSON.parse(fs.readFileSync(stateFile, "utf8"));
  delete stateForRewake.reported[reworkChild];
  delete stateForRewake.pending[reworkChild];
  fs.writeFileSync(stateFile, JSON.stringify(stateForRewake));
  cli(env, "disable", "onSubagentReturn");
  cli(env, "enable", "onSubagentReturn"); // a new revision: the store's dedupe is scoped to it
  const wakesBeforeRewake = wakes.length;
  const rewakePass = JSON.parse((await runObserver()).stdout);
  check(rewakePass.emitted === 1, `a child whose key left the ledger is woken again (${rewakePass.emitted})`);
  await until(() => wakes.length === wakesBeforeRewake + 1, "the re-woken child produced one message");
  const pruned = Object.keys(JSON.parse(fs.readFileSync(ledgerFile, "utf8")).keys);
  check(pruned.length <= 512, `the ledger is bounded after a wake (${pruned.length} keys)`);
  check(pruned.includes(reworkChild), "the key just written survives the bound");
  check(!pruned.includes("synthetic-old-0"), "the oldest key is dropped");
  check(pruned.includes("synthetic-old-519"), "the newest seeded key survives");
  check(pruned.filter((key) => key.startsWith("synthetic-old-")).length === 512 - CHILDREN.length,
    "and the bound keeps the newest by the time they were woken");

  // Disabling the hook removes the marker: the outbox notice is not suppressed by a job that is off.
  cli(env, "disable", "onSubagentReturn");
  check(!fs.existsSync(markerFile), "job disable removes the marker immediately, not on the next tick");
  await sleep(500);
  check(!fs.existsSync(markerFile), "and it stays gone while the job is off");

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
  check(verdict("jobs/delivery-admission.json").verdict === "deploy required at the wave's end",
    "every job definition is shipped, not only the hook's");
  const mutantHook = path.join(root, "mutant-hook.mjs");
  fs.writeFileSync(mutantHook, fs.readFileSync(path.join(repo, "scripts", "subagent-return-hook.mjs"), "utf8")
    .replace("MANIFEST_NAME = 'deploy-shipped.json'", "MANIFEST_NAME = 'deploy-shipped-missing.json'"));
  const mutant = JSON.parse(spawnSync(process.execPath, [mutantHook, "--verdict", "--path", "ui/app.js"],
    { encoding: "utf8", windowsHide: true }).stdout);
  check(mutant.verdict === "cannot be computed",
    "a predicate that cannot read the shipped set answers cannot be computed, never no install impact");
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
  check(requests.filter((entry) => entry.path === "/chat").length === wakes.length,
    `the unreachable-node pass added no wake and no model call (${wakes.length} messages, one per submitted wake)`);
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
