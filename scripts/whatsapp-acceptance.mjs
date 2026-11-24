#!/usr/bin/env node
// The ONE WhatsApp acceptance table: every mcp_whatsapp_* tool, from every site a model calls it from,
// plus the six flows, as one table - PASS, FAIL with the cause (file:line), or NOT-RUN with the reason.
//
// Two modes, and only one of them may touch a real account:
//
//   --mode scratch (default)  Three scratch nodes on this machine (account, laptop, work), each with its
//                             own home, a local rendezvous and a signed fleet roster, all answered by the
//                             `wa` binary of THIS checkout. No live node, no fleet, no real WhatsApp
//                             account: the wa-whatsapp component is never paired here, so the cells that
//                             need a paired device say so instead of pretending.
//   --mode live               The same rows against the node's OWN chat, and nothing else. --own-chat is
//                             required, the driver refuses every other target by name (a test for that
//                             refusal is one of the rows), and no chat id, phone number or message text is
//                             ever printed: see "redaction" below.
//
// WHAT A CELL PROVES. The verdict is about the call path, never about content the machine does not have:
//   PASS     the tool answered with its own answer (a read that answered data, a send that answered its
//            job), the measured milliseconds and the bytes/shape the MODEL receives;
//   FAIL     the call failed - a transport refusal, a dispatch that threw, an answer that was not the
//            tool's - and the cause names the product file and line;
//   NOT-RUN  the cell could not be measured here, and the reason says why (no paired device on this
//            machine, a guard that only the operator's own fleet can lift). A NOT-RUN is never a pass.
//
// PRIVACY. Nothing this script prints comes from a message: the driver (scripts/lib/whatsapp-acceptance-
// call.lua) prints a shape and an allow-list of scalar fields, both redacted, and this file re-checks
// every value before it prints (see `scrub`) and refuses to print a table that fails the check.
import {spawn, spawnSync} from "node:child_process";
import {mkdtempSync, mkdirSync, writeFileSync, readFileSync, existsSync, openSync, closeSync, rmSync} from "node:fs";
import {tmpdir, hostname} from "node:os";
import path from "node:path";

const ROOT = path.resolve(new URL(".", import.meta.url).pathname, "..");
const DRIVER = path.join(ROOT, "scripts/lib/whatsapp-acceptance-call.lua");
const REAL_HOME = path.join(process.env.HOME || "", ".wasm-agent");

// ---- the surface -----------------------------------------------------------------------------------
// Every tool the Lua surface exposes (lua/core/whatsapp.lua, M.TOOLS): eight offered to the model and
// two hidden doors. The brief's own list named send, send_status, read, search, media, download,
// reactions, contacts, backfill, approve - this is that list, with the exact names the model calls.
const TOOLS = [
  {verb: "contacts", effect: "read"},
  {verb: "search", effect: "read"},
  {verb: "read", effect: "read"},
  {verb: "reactions", effect: "read"},
  {verb: "media", effect: "read"},
  {verb: "download", effect: "write"},
  {verb: "backfill", effect: "write"},
  {verb: "send", effect: "write"},
  {verb: "send_status", effect: "read", hidden: true},
  {verb: "approve", effect: "write", hidden: true},
];
// Names the component (rust/components/mcp-whatsapp/src/main.rs, tools()) exposes and the Lua surface
// does NOT offer: the brief asks for every tool "the component exposes", so they are rows of their own -
// each of them is answered by the one surface's replacement name, not run.
const FOREIGN = [
  {name: "read_snapshot", use: "mcp_whatsapp_search"},
  {name: "read_newest", use: "mcp_whatsapp_read"},
  {name: "list_chats", use: "mcp_whatsapp_contacts"},
  {name: "posting_status", use: "mcp_whatsapp_approve"},
  {name: "read_field", use: "mcp_whatsapp_media"},
  {name: "lookup_self", use: "mcp_whatsapp_contacts"},
  {name: "inspect_chat", use: "mcp_whatsapp_read"},
  {name: "download_audio", use: "mcp_whatsapp_download"},
  {name: "send_message", use: "mcp_whatsapp_send"},
];
const SITES = ["account", "laptop", "work"];

// Fixtures only: a chat id, a message id and a sender that belong to no account. Every string here is a
// test fixture (`tests/fixtures` convention) - the live mode never uses any of them as a target.
const FIXTURE = {
  chat: "120363000000000001@g.us",
  chat_alt: "72103978127547@lid",
  message: "3EB0ACCEPTANCE01",
  query: "boleto",
  text: "acceptance one",
  foreign_chat: "000000000000000@s.whatsapp.net",
};

// ---- the flows -------------------------------------------------------------------------------------
// Each flow is a row of the table with the code that would have to be proved and the brief that owns it
// when it fails. Nothing here is invented: the file:line is the one the flow actually runs through.
const FLOWS = [
  {id: "flow/voice-reply", title: "voice note in -> transcript stored -> (posting on, own chat) reply posted",
    code: "rust/components/wa-whatsapp/src/guest.rs (transcript -> tx/ record), src/posting.rs",
    brief: "whatsapp-transcription-works, whatsapp-posting-toggle"},
  {id: "flow/deleted-after-index", title: "a message deleted after it is indexed -> content kept + flagged",
    code: "rust/components/wa-whatsapp/src/index.rs (the delete event), rust/wa-whatsapp-index/src/lib.rs",
    brief: "whatsapp-hold-not-silent"},
  {id: "flow/voice-deleted-before-reply", title: "a voice note deleted before its reply -> the reply is skipped",
    code: "rust/components/wa-whatsapp/src/posting.rs (the gate reads the source record)",
    brief: "whatsapp-hold-not-silent"},
  {id: "flow/picture-ocr", title: "a picture -> OCR text on the record",
    code: "rust/components/wa-whatsapp/src/ocr.rs, src/guest.rs ocr_tick",
    brief: "whatsapp-transcription-works"},
  {id: "flow/large-image-one-call", title: "a 120 KB image fetched from a peer in ONE call",
    code: "rust/wa-capabilities/src/whatsapp_query.rs ask_download (MAX_DOWNLOAD_BYTES 512 KiB)",
    brief: "run-images-two-node"},
  {id: "flow/send-from-work", title: "a send from work arrives",
    code: "lua/core/whatsapp.lua M.send -> M.routed -> rust/wa-capabilities/src/whatsapp_send.rs",
    brief: "whatsapp-acceptance (this one) - it is the row that proves the peer hop"},
  // The rows Fable added on 23/11.
  {id: "row/send-then-search", title: "send, then search the chat: the sent message is first, or pending (order stated)",
    code: "rust/components/wa-whatsapp/src/index.rs search order (newest first)", brief: "whatsapp-read-is-consistent"},
  {id: "row/empty-chat-freshness", title: "an empty chat read answers nothing new as of <time>; node received a message Ns ago",
    code: "rust/components/wa-whatsapp/src/alerts.rs, src/index.rs freshness fields", brief: "whatsapp-read-is-consistent"},
  {id: "row/text-and-voice", title: "a text then a voice note: read returns both in order, the note WITH its transcript inline",
    code: "rust/components/wa-whatsapp/src/view.rs message shape (transcript field)", brief: "whatsapp-transcription-works"},
  {id: "row/cross-chat-labels", title: "a read across chats labels every row with its chat",
    code: "rust/components/wa-whatsapp/src/view.rs hit_json (chat_name per row)", brief: "whatsapp-read-is-consistent"},
  {id: "row/send-then-read", title: "send-then-read: the sent message is in the next read",
    code: "lua/core/whatsapp.lua M.settle -> the read that follows", brief: "whatsapp-read-is-consistent"},
  {id: "row/three-reads", title: "three reads in a row are never older than the one before",
    code: "lua/core/whatsapp.lua M.call (read), rust/wa-whatsapp-index/src/lib.rs", brief: "whatsapp-read-is-consistent"},
  {id: "row/voice-text-in-read-and-search", title: "a voice record's text appears in read and in search (not empty)",
    code: "rust/components/wa-whatsapp/src/index.rs (transcript is indexed as text)", brief: "whatsapp-transcription-works"},
  {id: "row/both-id-forms", title: "both id forms of one chat (@s.whatsapp.net and @lid) give the same messages",
    code: "rust/components/wa-whatsapp/src/index.rs alias table", brief: "whatsapp-read-is-consistent"},
];

// ---- arguments -------------------------------------------------------------------------------------
function parseArgs(argv) {
  const opts = {mode: "scratch", bin: process.env.WA_BIN || "", ownChat: "", json: "", keep: false, allowForeign: false};
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--mode") opts.mode = argv[++i];
    else if (arg === "--bin") opts.bin = argv[++i];
    else if (arg === "--own-chat") opts.ownChat = argv[++i];
    else if (arg === "--json") opts.json = argv[++i];
    else if (arg === "--keep") opts.keep = true;
    else if (arg === "--help" || arg === "-h") { console.log("usage: whatsapp-acceptance.mjs [--mode scratch|live] [--own-chat <jid>] [--bin <wa>] [--json <path>] [--keep]"); process.exit(0); }
    else { console.error("whatsapp-acceptance: unknown argument " + arg); process.exit(2); }
  }
  return opts;
}
const NL = String.fromCharCode(10);
const OPTS = parseArgs(process.argv.slice(2));

function say(line) { process.stdout.write(line + "\n"); }
function fail(code, message) { console.error("whatsapp-acceptance: " + message); process.exit(code); }

// ---- scratch-home guard ----------------------------------------------------------------------------
// A run that writes must never write where the operator's node lives (rule: every test creates its own
// home and REFUSES to run when it is the real one). One check for both modes: the work root must not be
// the node home, and the node home must not be inherited by the children this script starts.
function assertScratch(root) {
  const inside = (parent, child) => child === parent || child.startsWith(parent + path.sep);
  const realHome = path.resolve(REAL_HOME);
  if (inside(realHome, path.resolve(root))) fail(3, "refusing to run: " + root + " is inside the node home " + realHome);
  const envHome = process.env.WASM_AGENT_HOME || "";
  if (envHome && inside(realHome, path.resolve(envHome)) && path.resolve(envHome) === realHome) fail(3, "refusing to run: WASM_AGENT_HOME is the operator's real node home");
  if (path.resolve(root) === path.resolve(process.env.HOME || "")) fail(3, "refusing to run: the work root is HOME");
}

// ---- privacy --------------------------------------------------------------------------------------
// Every string that reaches the table is checked here first. A run that would print a JID, a phone
// number, a message id or a piece of message text refuses instead of printing (exit 4), because a table
// that leaks is worse than a table that is missing a row.
const DIGITS = /d{5,}/;
const JID = /[A-Za-z0-9.+_-]+@[A-Za-z0-9.-]+/;
function scrub(value, where) {
  if (value === null || value === undefined) return value;
  if (typeof value === "number" || typeof value === "boolean") return value;
  const text = String(value);
  if (JID.test(text) || DIGITS.test(text)) fail(4, "refusing to print " + where + ": a value looks like a chat id or a phone number (" + text.slice(0, 24) + ")");
  return text;
}

// ---- process plumbing ------------------------------------------------------------------------------
// A node runs with only what this script hands it: the ambient WASM_AGENT_*/WA_*/provider variables of
// the session it was started in are dropped here (they are the operator's), which is the same rule
// scripts/lib/fast-row-exec.sh applies to a test row.
function baseEnv(home, extra = {}) {
  const env = {PATH: process.env.PATH || "/usr/bin:/bin", HOME: home, LANG: process.env.LANG || "C.UTF-8", NO_PROXY: "127.0.0.1,localhost,::1"};
  for (const [key, value] of Object.entries(extra)) env[key] = value;
  return env;
}

let CHILDREN = [];
function stopChildren() {
  for (const child of CHILDREN) {
    try { process.kill(child.pid, "SIGTERM"); } catch { /* already gone */ }
  }
  for (const child of CHILDREN) {
    try { child.kill("SIGKILL"); } catch { /* already gone */ }
  }
  CHILDREN = [];
}
process.on("exit", stopChildren);

function spawnNode(name, args, env, cwd, logFile) {
  const out = openSync(logFile, "a");
  const child = spawn(OPTS.bin, args, {cwd, env, stdio: ["ignore", out, out]});
  closeSync(out);
  child.__name = name;
  CHILDREN.push(child);
  return child;
}

function runOnce(args, env, cwd) {
  const started = Date.now();
  const done = spawnSync(OPTS.bin, args, {cwd, env, encoding: "utf8", timeout: 180000, maxBuffer: 32 * 1024 * 1024});
  return {code: done.status, stdout: done.stdout || "", stderr: done.stderr || "", ms: Date.now() - started};
}

async function waitFor(fn, seconds, what) {
  const deadline = Date.now() + seconds * 1000;
  while (Date.now() < deadline) {
    if (await fn()) return true;
    await new Promise((r) => setTimeout(r, 200));
  }
  throw new Error("timed out after " + seconds + "s waiting for " + what);
}

async function health(port) {
  try {
    const response = await fetch("http://127.0.0.1:" + port + "/health", {signal: AbortSignal.timeout(1500)});
    if (!response.ok) return false;
    const body = await response.json();
    return body && body.ok === true;
  } catch { return false; }
}

function freePort() {
  // Two ports per node (serve + client) and one for each mesh mount; node's own listener picks it.
  const done = spawnSync(process.execPath, ["-e", "const n=require('net');const s=n.createServer();s.listen(0,'127.0.0.1',()=>{const p=s.address().port;s.close(()=>process.stdout.write(String(p)))})"], {encoding: "utf8"});
  const port = Number((done.stdout || "").trim());
  if (!port) throw new Error("no free port");
  return port;
}

// ---- the plans -------------------------------------------------------------------------------------
// One plan per site: the steps the driver runs, in the order a model would need them. `chat` is a fixture
// in scratch mode and the configured own chat in live mode - the only difference between the two runs.
function planFor(site, ownChat) {
  const chat = ownChat || FIXTURE.chat;
  const steps = [
    {id: "contacts", tool: "mcp_whatsapp_contacts", args: {q: "ana", limit: 3}},
    {id: "search", tool: "mcp_whatsapp_search", args: {q: FIXTURE.query, chat, limit: 5}},
    {id: "read", tool: "mcp_whatsapp_read", args: {chat, limit: 5}},
    {id: "reactions", tool: "mcp_whatsapp_reactions", args: {chat, id: FIXTURE.message}},
    {id: "media", tool: "mcp_whatsapp_media", args: {chat, id: FIXTURE.message}},
    {id: "download", tool: "mcp_whatsapp_download", args: {chat, id: FIXTURE.message, max_bytes: 524288}},
    {id: "backfill", tool: "mcp_whatsapp_backfill", args: {count: 10}},
    {id: "send", tool: "mcp_whatsapp_send", args: {chat, text: FIXTURE.text, wait_s: 0}},
    {id: "send/resume", tool: "mcp_whatsapp_send", args: {wait_s: 0}, reuse: {id: "send", key: "id"}},
    // The same chat + text + reply_to is ONE job (never a second message), and a job still queued can be
    // taken out of the queue: both are answerable without a paired device, so both are proved here.
    {id: "send/dedupe", tool: "mcp_whatsapp_send", args: {chat, text: FIXTURE.text, wait_s: 0}},
    {id: "send/cancel", tool: "mcp_whatsapp_send", args: {}, reuse: {id: "send", key: "id", as: "cancel"}},
    {id: "send_status", tool: "mcp_whatsapp_send_status", args: {}, reuse: {id: "send", key: "id"}},
    {id: "approve", tool: "mcp_whatsapp_approve", args: {action: "list"}},
    {id: "approve/policy", tool: "mcp_whatsapp_approve", args: {action: "policy"}},
    // THE GUARD ROW: a target that is not the configured own chat. In live mode this MUST be refused
    // before any call; in scratch mode the own chat is empty and the row says so (not a pass).
    {id: "guard/other-chat", tool: "mcp_whatsapp_read", args: {chat: FIXTURE.foreign_chat, limit: 1}},
    // Names an older build answered, and a name the component exposes that this surface does not: the
    // answer must be the one sentence that names the replacement, never a silent success.
    {id: "foreign/read_newest", tool: "mcp_whatsapp_native_read_newest_deadbeef", args: {}},
    {id: "foreign/whatsapp_read", tool: "whatsapp_read", args: {chat}},
    {id: "foreign/operator", tool: "whatsapp_operator", args: {}},
  ];
  return {site, own_chat: ownChat, steps};
}

// ---- verdicts --------------------------------------------------------------------------------------
function verdictFor(tool, site, rows) {
  const mine = rows.filter((row) => row.tool === tool);
  if (!mine.length) return {verdict: "NOT-RUN", why: "the step was not executed"};
  // A step that could not build its own arguments (a resume with no job id) says so, and the reason is
  // the cell it depends on - never a failure of this tool.
  const cascade = mine.find((row) => typeof row.error === "string" && row.error.startsWith("reuse_unavailable"));
  if (cascade) return {verdict: "NOT-RUN", why: "the step it resumes answered no job id here: " + cascade.error};
  const transport = mine.find((row) => row.fields && ["whatsapp_owner_unreachable", "remote_unreachable", "mesh_refused", "unknown_node"].includes(row.fields.error));
  if (transport) return {verdict: "FAIL", why: "the peer hop did not reach the account node: " + transport.fields.error + " (lua/core/whatsapp.lua M.forward; lua/core/nodes.lua M.remote_call)"};
  // The account node ANSWERED the hop and refused the caller's ROLE. That is the fleet's admission, not
  // this tool: a scratch rendezvous registers every node as a guest (it grants master only to the ids the
  // operator listed for the network, and the edit_admin_set hook refuses a session that sets that list),
  // so the hop is measured and the tool is not. Named as such, never as a pass.
  const role = mine.find((row) => row.fields && row.fields.error === "remote_refused");
  if (role) return {verdict: "NOT-RUN", why: "the hop was admitted by the signed roster (mesh decision=allow) and the account node refused the caller's role (lua/core/server.lua:1034 verify_peer -> forbidden_role): a scratch rendezvous has no master to grant; the tool itself was not reached"};
  if (mine.some((row) => row.error === "dispatch_threw" || row.error === "answer_not_a_table")) return {verdict: "FAIL", why: "the call did not return the tool's own answer"};
  const slow = mine.find((row) => typeof (row.fields && row.fields.error) === "string" && /_slow$/.test(row.fields.error));
  if (slow) {
    const job = mine.find((row) => row.fields && row.fields.job !== undefined);
    return {verdict: "NOT-RUN", why: "no paired device on this machine: the capability queued the question" + (job ? " as job " + job.fields.job : "") + " and answered " + slow.fields.error + " (rust/wa-capabilities/src/whatsapp_query.rs: nothing settles whatsapp.query without the component paired to a phone)"};
  }
  const good = mine.find((row) => row.ok === true);
  if (good) return {verdict: "PASS", why: ""};
  const refusal = mine.find((row) => row.fields && row.fields.error);
  if (refusal) return {verdict: "FAIL", why: refusal.fields.error};
  return {verdict: "FAIL", why: mine[0].error || "no answer"};
}

// ---- nodes -----------------------------------------------------------------------------------------
async function startFleet(root, bin) {
  const nodes = {};
  for (const site of SITES) {
    const home = path.join(root, site, "home");
    const cwd = path.join(root, "nodes", site);
    const policy = path.join(root, site, ".wasm-agent");
    for (const dir of [home, cwd, policy, path.join(root, site, "tmp")]) mkdirSync(dir, {recursive: true});
    nodes[site] = {site, home, cwd, data: path.join(root, site), tmp: path.join(root, site, "tmp"),
      serve: freePort(), client: freePort(), mesh: freePort(), name: site};
  }
  // The rendezvous: a scratch HOME, so even a default database path lands inside this run.
  const rendezvousHome = path.join(root, "rendezvous");
  mkdirSync(rendezvousHome, {recursive: true});
  const rendezvousPort = freePort();
  const log = (name) => path.join(root, "logs", name + ".log");
  mkdirSync(path.join(root, "logs"), {recursive: true});
  spawnNode("rendezvous", ["rendezvous", "--port", String(rendezvousPort), "--db=" + path.join(rendezvousHome, "rdb")],
    baseEnv(rendezvousHome), rendezvousHome, log("rendezvous"));

  // The fleet key and the roster: a real signed roster is what the mesh mount admits a peer against
  // (docs/MESH.md), so a peer call either takes the real path or refuses for a reason that is the
  // product's own.
  const fleet = path.join(root, "fleet");
  mkdirSync(fleet, {recursive: true});
  const keygen = runOnce(["fleet", "keygen", "--out", path.join(fleet, "acceptance.key")], baseEnv(rendezvousHome), rendezvousHome);
  const fleetKey = (keygen.stdout.match(/"public_key":"([0-9a-f]+)"/) || [])[1];
  if (!fleetKey) throw new Error("wa fleet keygen printed no public key: " + (keygen.stdout + keygen.stderr).slice(0, 300));
  const roster = {version: 1, fleet: "acceptance", issued_at: 0, expires_at: 0, nodes: []};
  for (const site of SITES) {
    const id = runOnce(["node"], baseEnv(nodes[site].home, {WASM_AGENT_HOME: nodes[site].data, WASM_AGENT_MANAGED: "0"}), nodes[site].cwd);
    const nodeId = (id.stdout.match(/"node_id":"([0-9a-f]+)"/) || [])[1];
    const publicKey = (id.stdout.match(/"public_key":"([0-9a-f]+)"/) || [])[1];
    if (!nodeId || !publicKey) throw new Error("wa node printed no identity for " + site + ": " + id.stdout.slice(0, 200));
    nodes[site].id = nodeId;
    nodes[site].public_key = publicKey;
    // Level 1 for the account node, level 0 for the two callers: a node may call at its own level or
    // below (docs/MESH.md), which is the hierarchy the real fleet uses.
    roster.nodes.push({node_id: nodeId, public_key: publicKey, name: site, level: site === "account" ? 1 : 0,
      addresses: ["127.0.0.1:" + nodes[site].mesh], revoked_at: 0});
  }
  const rosterPath = path.join(fleet, "roster.json");
  writeFileSync(rosterPath, JSON.stringify(roster, null, 1));
  const signed = runOnce(["fleet", "sign", rosterPath, "--key", path.join(fleet, "acceptance.key"), "--expires-days", "30"], baseEnv(rendezvousHome), rendezvousHome);
  if (!existsSync(path.join(fleet, "roster.signed.json"))) throw new Error("wa fleet sign wrote no signed roster: " + (signed.stdout + signed.stderr).slice(0, 300));

  const rendezvousUrl = "http://127.0.0.1:" + rendezvousPort;
  for (const site of SITES) {
    const node = nodes[site];
    const data = path.join(node.data, ".wasm-agent");
    writeFileSync(path.join(data, "mesh-roster.json"), readFileSync(path.join(fleet, "roster.signed.json")));
    // THE SHIPPED POLICY, not one written by this script: the whatsapp.send rule, its caps and the
    // component's kv prefixes are what a node really runs under (policies/default.json), and a scratch
    // node with an empty policy would answer a send with a refusal no node in the field returns.
    const shipped = JSON.parse(readFileSync(path.join(ROOT, "policies/default.json"), "utf8"));
    shipped.mesh = {version: 1, roster_key: fleetKey, roster: "mesh-roster.json", enabled: true, port: node.mesh, bind: "127.0.0.1"};
    writeFileSync(path.join(data, "policy.json"), JSON.stringify(shipped, null, 1));
    const env = baseEnv(node.home, {
      TMPDIR: node.tmp, WASM_AGENT_HOME: node.data, WASM_AGENT_LUA_ROOT: ROOT, WASM_AGENT_MANAGED: "0",
      WASM_AGENT_RELAY: "", WASM_AGENT_RENDEZVOUS: rendezvousUrl, WASM_AGENT_ENDPOINT: "http://127.0.0.1:" + node.serve,
      WASM_AGENT_LLM_BASE_URL: "http://127.0.0.1:1/v1", WASM_AGENT_LLM_API_KEY: "fixture-only",
    });
    spawnNode(site, ["--db", path.join(node.data, "memory.db"), "serve", "--port", String(node.serve),
      "--client-port", String(node.client), "--ui", path.join(ROOT, "ui")], env, node.cwd, log(site));
  }
  await waitFor(async () => {
    for (const site of SITES) if (!(await health(nodes[site].serve))) return false;
    return true;
  }, 120, "three scratch nodes to answer /health");
  return {nodes, rendezvousUrl};
}

// ---- one site's plan -------------------------------------------------------------------------------
function runPlan(ctx, node, plan, extraEnv) {
  const root = ctx.root;
  const planPath = path.join(root, "plans", plan.site + ".json");
  mkdirSync(path.dirname(planPath), {recursive: true});
  writeFileSync(planPath, JSON.stringify(plan, null, 1));
  const env = baseEnv(node.home, {
    TMPDIR: node.tmp, WASM_AGENT_HOME: node.data, WASM_AGENT_LUA_ROOT: ROOT, WASM_AGENT_MANAGED: "0",
    WASM_AGENT_RELAY: "", WASM_AGENT_RENDEZVOUS: ctx.rendezvousUrl || "", WA_ACCEPTANCE_PLAN: planPath,
    WA_SCRIPT: DRIVER, ...extraEnv,
  });
  const done = runOnce(["--db", path.join(node.data, "memory.db")], env, node.cwd);
  const rows = [];
  for (const line of done.stdout.split("\n")) {
    if (!line.startsWith("ACCEPTANCE ")) continue;
    try { rows.push(JSON.parse(line.slice("ACCEPTANCE ".length))); } catch { /* a torn line is not a row */ }
  }
  return {rows, code: done.code, raw: done.stdout + done.stderr};
}

// ---- the table -------------------------------------------------------------------------------------
function fmt(value, width) {
  const text = String(value === undefined || value === null ? "" : value);
  return text.length > width ? text.slice(0, width - 1) + "…" : text.padEnd(width);
}
function render(cells, flows) {
  const lines = [];
  lines.push("site      tool                          verdict  ms     bytes  what the model receives / why");
  lines.push("--------  ----------------------------  -------  -----  -----  ---------------------------------------------");
  for (const cell of cells) {
    lines.push([fmt(cell.site, 8), fmt(cell.tool, 28), fmt(cell.verdict, 7), fmt(cell.ms, 5), fmt(cell.bytes, 5),
      (cell.verdict === "PASS" ? (cell.shape || "") : cell.why)].join("  "));
  }
  lines.push("");
  lines.push("row                                     verdict  ms     why / code");
  lines.push("--------------------------------------  -------  -----  ---------------------------------------------");
  for (const flow of flows) {
    lines.push([fmt(flow.id, 38), fmt(flow.verdict, 7), fmt(flow.ms, 5), flow.verdict === "PASS" ? flow.shape || "" : flow.why].join("  "));
  }
  return lines.join("\n");
}

// ---- main ------------------------------------------------------------------------------------------
async function main() {
  const bin = OPTS.bin || ["/home/victor/wasm-agent/target/m-whatsapp-acceptance/debug/wa", path.join(ROOT, "rust/target/debug/wa")].find((c) => existsSync(c)) || "";
  if (!bin || !existsSync(bin)) fail(2, "no wa binary: pass --bin, or set WA_BIN (this run builds nothing)");
  OPTS.bin = bin;
  // TMPDIR is not trusted: on this node it is INSIDE the operator store (~/.wasm-agent/tmp), which is
  // exactly what the scratch guard refuses. The first candidate that is outside the node home wins.
  const base = [tmpdir(), "/tmp", "/var/tmp"].find((dir) => existsSync(dir) && !path.resolve(dir).startsWith(path.resolve(REAL_HOME) + path.sep) && path.resolve(dir) !== path.resolve(REAL_HOME));
  if (!base) fail(3, "refusing to run: no temporary directory outside the node home " + REAL_HOME);
  const root = mkdtempSync(path.join(base, "wa-acceptance-"));
  assertScratch(root);
  say("whatsapp-acceptance: mode " + OPTS.mode + ", binary " + bin);
  say("  work root " + root + (OPTS.keep ? " (kept)" : ""));

  const cells = [];
  const flows = [];
  try {
    if (OPTS.mode === "live") {
      if (!OPTS.ownChat) fail(2, "--mode live needs --own-chat <jid>: the run touches the operator's own chat and nothing else");
      if (!/^[0-9]{5,}@(s.whatsapp.net|lid|g.us)$/.test(OPTS.ownChat)) fail(2, "--own-chat is not an exact chat JID (<digits>@s.whatsapp.net, @lid or @g.us)");
      const node = {site: "account", home: process.env.HOME || "", cwd: process.cwd(), data: process.env.WASM_AGENT_HOME || path.join(process.env.HOME || "", ".wasm-agent"), tmp: process.env.TMPDIR || "/tmp"};
      const plan = planFor("account", OPTS.ownChat);
      const ran = runPlan({root, rendezvousUrl: ""}, node, plan, {});
      collect(cells, flows, "account", ran.rows, OPTS.ownChat);
    } else {
      const fleet = await startFleet(root, bin);
      // The guard is exercised with the FIXTURE chat standing in for the account's own chat: the row
      // that names another chat must be refused, and every other step must use the fixture.
      const ownChat = FIXTURE.chat;
      for (const site of SITES) {
        const plan = planFor(site, ownChat);
        const extra = site === "account" ? {} : {WASM_AGENT_WHATSAPP_OWNER: fleet.nodes.account.name, WASM_AGENT_RENDEZVOUS: fleet.rendezvousUrl};
        const ran = runPlan({root, rendezvousUrl: fleet.rendezvousUrl}, fleet.nodes[site], plan, extra);
        collect(cells, flows, site, ran.rows, ownChat);
      }
    }
  } finally {
    stopChildren();
    if (!OPTS.keep) rmSync(root, {recursive: true, force: true});
  }

  const table = render(cells, flows);
  say("");
  say(table);
  const bad = cells.filter((cell) => cell.verdict === "FAIL").length + flows.filter((flow) => flow.verdict === "FAIL").length;
  say("");
  say("whatsapp-acceptance: " + cells.filter((c) => c.verdict === "PASS").length + " pass, "
    + cells.filter((c) => c.verdict === "NOT-RUN").length + " not-run, " + cells.filter((c) => c.verdict === "FAIL").length
    + " fail, across " + cells.length + " cells and " + flows.length + " rows");
  if (OPTS.json) writeFileSync(OPTS.json, JSON.stringify({mode: OPTS.mode, binary: bin, cells, flows}, null, 1));
  process.exit(bad === 0 ? 0 : 1);
}

// Assemble one site's rows into cells and flow rows.
function collect(cells, flows, site, rows, ownChat) {
  const byTool = new Map();
  for (const row of rows) {
    if (row.id === "done") continue;
    const tool = row.tool;
    cell(byTool, tool).push(row);
    if (row.id === "guard/other-chat") {
      const refused = row.error === "refused_not_own_chat" || (row.fields && row.fields.error === "refused_not_own_chat");
      if (ownChat === "") {
        flows.push({id: "guard/own-chat-" + site, verdict: "NOT-RUN", ms: row.ms || 0, why: "no own chat configured (scratch mode): the refusal cannot be exercised - the live run is where it must refuse"});
      } else {
        flows.push({id: "guard/own-chat-" + site, verdict: refused ? "PASS" : "FAIL", ms: row.ms || 0,
          why: refused ? "a target that is not the configured own chat was refused before any call (scripts/lib/whatsapp-acceptance-call.lua, the own-chat guard)" : "the guard did NOT refuse another chat: " + (row.error || (row.fields && row.fields.error) || "no answer")});
      }
    }
  }
  for (const tool of TOOLS) {
    const name = "mcp_whatsapp_" + tool.verb;
    const mine = byTool.get(name) || [];
    const verdict = verdictFor(name, site, mine);
    const first = mine.find((row) => row.ok === true) || mine[0] || {};
    cells.push({site, tool: name, hidden: !!tool.hidden, verdict: verdict.verdict,
      ms: mine.length > 0 ? mine[0].ms || 0 : 0, bytes: first.bytes || 0,
      shape: (first.shape || "").replace(/\s+/g, " ").slice(0, 96), why: verdict.why});
  }
  const byId = new Map(rows.map((row) => [row.id, row]));
  const send = byId.get("send") || {};
  const dedupe = byId.get("send/dedupe") || {};
  const cancel = byId.get("send/cancel") || {};
  const sendProved = send.ok === true && dedupe.ok === true && send.fields && dedupe.fields && send.fields.id === dedupe.fields.id;
  cells.push({site, tool: "mcp_whatsapp_send (same message twice = one job)", hidden: true,
    verdict: sendProved ? "PASS" : send.ok === true ? "FAIL" : "NOT-RUN",
    ms: (send.ms || 0) + (dedupe.ms || 0), bytes: dedupe.bytes || 0,
    shape: (dedupe.shape || "").slice(0, 96),
    why: sendProved ? "one job for the repeated message (lua/core/whatsapp.lua M.send; the dedupe key is the request)" : send.ok === true ? "the second send did not answer the same job id" : "the send it repeats never queued here, so there is no job to dedupe (see the send cell)"});
  cells.push({site, tool: "mcp_whatsapp_send (cancel a queued job)", hidden: true,
    verdict: cancel.ok === true ? "PASS" : send.ok === true ? "FAIL" : "NOT-RUN", ms: cancel.ms || 0, bytes: cancel.bytes || 0,
    shape: (cancel.shape || "").slice(0, 96),
    why: cancel.ok === true ? "the queued job was taken out of the queue before any worker held it (rust/wa-capabilities/src/whatsapp_send.rs, the cancel branch)" : send.ok === true ? ((cancel.fields && cancel.fields.error) || "cancel refused") : "the send it cancels never queued here, so there is no job to take out (see the send cell)"});
  // The three names that must never run: an older spelling, a name the component exposes, and a retired
  // operator tool. Each answers one sentence that names the replacement - proved, not assumed.
  const names = [
    ["whatsapp_read (an older spelling)", "foreign/whatsapp_read", "whatsapp_tool_renamed"],
    ["mcp_whatsapp_native_read_newest_<hash> (component name)", "foreign/read_newest", "whatsapp_tool_renamed"],
    ["whatsapp_operator (retired)", "foreign/operator", "whatsapp_tool_retired"],
  ];
  for (const [label, id, expected] of names) {
    const row = byId.get(id) || {};
    const got = row.fields && row.fields.error;
    cells.push({site, tool: label, verdict: got === expected ? "PASS" : "FAIL", ms: row.ms || 0, bytes: row.bytes || 0,
      shape: (row.shape || "").slice(0, 96),
      why: got === expected ? "refused by name with " + expected + " and the replacement it names (lua/core/whatsapp.lua M.renamed/M.RETIRED)" : "answered " + (got || "nothing") + ", expected " + expected});
  }
  // The component's own tool names: a fact about the surface, not about a site, so they are one row each
  // (emitted on the first site only).
  for (const foreign of (site === SITES[0] ? FOREIGN : [])) {
    const row = rows.find((entry) => entry.tool === "mcp_whatsapp_native_" + foreign.name + "_deadbeef");
    const asked = rows.find((entry) => entry.id === "foreign/read_newest");
    cells.push({site, tool: foreign.name + " (component name)", verdict: "NOT-RUN",
      ms: asked ? asked.ms : 0, bytes: 0, shape: "",
      why: "not offered by the one surface: rust/components/mcp-whatsapp/src/main.rs tools() exposes it, and lua/core/whatsapp.lua M.renamed answers it with " + foreign.use});
  }
  // The flow rows: what this machine can prove, and what it cannot.
  for (const flow of FLOWS) {
    const already = flows.find((entry) => entry.id === flow.id);
    if (already) continue;
    flows.push({id: flow.id, verdict: "NOT-RUN", ms: 0, why: flowWhy(flow, site)});
  }
}

function cell(map, tool) {
  if (!map.has(tool)) map.set(tool, []);
  return map.get(tool);
}

// Why a content flow cannot be measured on a machine with no paired device, per site. The sentence is
// the run's own measurement: `read` answered `whatsapp_read_slow` (nothing settles whatsapp.query
// without the component connected), which is exactly why no message can be read, sent or transcribed here.
function flowWhy(flow, site) {
  return "no paired device here (rust/components/wa-whatsapp/src/guest.rs pairs with a phone), so this "
    + "runs on the account's own node at G; code " + flow.code + "; owner " + flow.brief;
}

main().catch((error) => { stopChildren(); fail(5, String(error && error.stack || error)); });
