// The copilot reader's *acted* cursor, against a mock store: a message may be consumed only when a
// durable decision exists for it.
//
// Hermetic: the real `wa` binary runs the real `scripts/whatsapp-ingest.lua` (copied beside a fake reader
// that plays the part of `scripts/whatsapp-read.mjs`), against a real SQLite ledger in a temp home. No
// browser, no sentinel, no model. The store is a file this test rewrites between passes, so one pass is
// exactly what the sentinel's pipeline step runs:
//
//     WA_WHATSAPP_JSON_EVENTS=1 WA_SCRIPT=<ingest.lua> wa --db <ledger>
//
// What it proves, each a rule that failed in production at least once:
//   * the first pass adopts the cursor and answers nothing (a fresh install used to hand on nothing and
//     never move the cursor off zero);
//   * handing a message on does NOT advance the cursor - only a durable `effect_decisions` row does, so a
//     child that fails to decide cannot consume a message;
//   * an undecided message is handed on again (the child's idempotency key makes that a reconcile), and
//     the number of attempts is bounded, so one permanently failing message cannot pin the cursor;
//   * an eligible image or voice note is reported as unanswerable and never handed to a child;
//   * the operator answering first, and a deterministic eligibility refusal, are decisions too;
//   * a message the copilot declined because the operator took over is reported to the operator's own
//     inbox, once, so "the copilot chose not to answer" is never indistinguishable from "it never saw it".
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { DatabaseSync } = require("node:sqlite");

const FAKE_READER = `// The mock store, in the exact shape scripts/whatsapp-read.mjs produces for the ingest.
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
const args = process.argv.slice(2);
const value = (flag) => { const at = args.indexOf(flag); return at === -1 ? "" : args[at + 1] || ""; };
// What the reader asks for, kept because the *window* is the contract a real store honours: the mock
// returns everything, so only the requested --since can show whether an owed message is reachable.
if (process.env.WA_FIXTURE_ARGS) appendFileSync(process.env.WA_FIXTURE_ARGS, String(Number(value("--since")) || 0) + "\\n");
const store = JSON.parse(readFileSync(process.env.WA_FIXTURE_STORE, "utf8"));
const messages = store.messages || [];
const payload = {
  ok: true, endpoint: "fixture", tab: { id: "fixture", title: "fixture", url: "fixture" },
  since: Number(value("--since")) || 0, conversations: store.conversations || [], messages,
  skipped_no_timestamp: 0, store: null, dropped_over_limit: 0, newest: store.newest || 0,
  eligible: messages.filter((m) => m.eligibility && m.eligibility.eligible).length,
  ineligible: messages.filter((m) => !(m.eligibility && m.eligibility.eligible)).length,
};
writeFileSync(value("--out"), JSON.stringify(payload));
console.log(JSON.stringify({ ok: true, out: value("--out"), conversations: payload.conversations.length,
  messages: messages.length, eligible: payload.eligible, ineligible: payload.ineligible, newest: payload.newest }));
`;

const repo = path.resolve(__dirname, "..");
// The gate passes `rust/target/release/wa`, which on Windows is `wa.exe`; accept either, and either the
// bare name or the platform suffix.
const named = process.argv[2] || path.join(repo, "rust/target/release", "wa" + (process.platform === "win32" ? ".exe" : ""));
const wa = [named, named + ".exe"].map((candidate) => path.resolve(candidate)).find((candidate) => fs.existsSync(candidate)) || path.resolve(named);
const root = fs.mkdtempSync(path.join(os.tmpdir(), "wa-cursor-"));
const scripts = path.join(root, "scripts");
const db = path.join(root, ".wasm-agent", "memory.db");
const storePath = path.join(root, "store.json");
const argsPath = path.join(root, "reader-args.txt");
fs.writeFileSync(argsPath, "");
fs.mkdirSync(scripts, { recursive: true });
fs.copyFileSync(path.join(repo, "scripts", "whatsapp-ingest.lua"), path.join(scripts, "whatsapp-ingest.lua"));
fs.writeFileSync(path.join(scripts, "whatsapp-read.mjs"), FAKE_READER);

const CONV = "5511888888888@c.us";
const OTHER = "5511777777777@c.us";
let checks = 0;
function check(value, label) { assert.ok(value, label); checks += 1; }

const message = (id, at, extra = {}) => ({
  conversation_id: CONV, message_id: id, sender_id: "5511999999999", direction: "incoming", sent_at: at,
  body: "fixture body " + id, media: [{ type: "chat" }], eligibility: { eligible: true }, ...extra,
});

function store(messages, newest) {
  fs.writeFileSync(storePath, JSON.stringify({
    conversations: [
      { id: CONV, kind: "direct", title: "Fixture contact", updated_at: newest, archived: false, left: false },
      { id: OTHER, kind: "direct", title: "Other contact", updated_at: newest, archived: false, left: false },
    ],
    messages, newest,
  }));
}

// One pass = one reader step.
function pass() {
  const result = spawnSync(wa, ["--db", db], {
    env: {
      ...process.env, WASM_AGENT_HOME: root, WASM_AGENT_LUA_ROOT: repo,
      WA_SCRIPT: path.join(scripts, "whatsapp-ingest.lua"), WA_WHATSAPP_JSON_EVENTS: "1",
      WA_FIXTURE_STORE: storePath, WA_FIXTURE_ARGS: argsPath, WASM_AGENT_RENDEZVOUS: "", WASM_AGENT_RELAY: "", WASM_AGENT_MANAGED: "0",
    },
    encoding: "utf8", timeout: 60000, windowsHide: true,
  });
  const line = (result.stdout || "").trim().split(/\r?\n/).filter(Boolean).pop() || "";
  let parsed = null;
  try { parsed = JSON.parse(line); } catch { /* the caller asserts on `parsed` */ }
  return { parsed, stdout: result.stdout || "", stderr: result.stderr || "" };
}

// A durable decision, exactly as a child records one.
function decided(messageId) {
  const database = new DatabaseSync(db);
  database.prepare("INSERT INTO effect_decisions(message_id,session_id,conversation_id,decision,reason,created_at,updated_at) " +
    "VALUES(?,?,?,?,?,?,?) ON CONFLICT(message_id) DO NOTHING")
    .run(messageId, "fixture-session", CONV, "no_reply", "fixture decision", 1, 1);
  database.close();
}

function cursor() {
  const database = new DatabaseSync(db, { readOnly: true });
  const row = database.prepare("SELECT value FROM meta WHERE key='whatsapp_cursor'").get();
  database.close();
  return row ? Number(row.value) : 0;
}

// The window the last pass asked the store for.
function lastSince() {
  const lines = fs.readFileSync(argsPath, "utf8").split("\n").filter(Boolean);
  return Number(lines[lines.length - 1]);
}

// What is still owed a decision, as the reader records it durably.
function owedMap() {
  const database = new DatabaseSync(db, { readOnly: true });
  const row = database.prepare("SELECT value FROM meta WHERE key='whatsapp_handoffs'").get();
  database.close();
  return row ? JSON.parse(row.value) : {};
}

function ids(list) { return (list || []).map((item) => item.message_id).join(","); }

// A durable send, exactly as a child records one through effects.reserve/confirm.
function sent(messageId, conversationId, body, state, at) {
  const database = new DatabaseSync(db);
  database.prepare("INSERT INTO effect_sends(message_id,session_id,conversation_id,body,state,message,detail,created_at,updated_at) " +
    "VALUES(?,?,?,?,?,'{}','',?,?) ON CONFLICT(message_id) DO UPDATE SET state=excluded.state, updated_at=excluded.updated_at")
    .run(messageId, "fixture-session", conversationId, body, state, at, at);
  database.close();
}

function main() {
  check(fs.existsSync(wa), `node binary exists: ${wa}`);

  // ---- the first pass adopts the cursor and answers nothing ---------------------------------------
  store([message("a1", 1000)], 1000);
  const first = pass();
  check(first.parsed !== null, `the reader prints one JSON object: ${first.stdout.slice(0, 200)}${first.stderr.slice(0, 200)}`);
  check(first.parsed.events.length === 0, "the first pass hands on nothing: a fresh cursor answers no backlog");
  check(first.parsed.cursor === 1000 && cursor() === 1000, "the first pass adopts the newest message as the cursor");
  check(first.parsed.still_owed === 0, "the first pass owes nothing");

  // ---- a new message is handed on, and the cursor does NOT pass it ---------------------------------
  store([message("a1", 1000), message("a2", 2000)], 2000);
  const second = pass();
  check(ids(second.parsed.events) === "a2", `a new eligible message is handed on (got ${ids(second.parsed.events)})`);
  check(second.parsed.cursor === 1000, "handing a message on does not advance the cursor past it");
  check(cursor() === 1000, "the ledger's cursor is unchanged by a hand-on");
  check(second.parsed.still_owed === 1, "the handed-on message is recorded as owed a decision");

  // ---- an undecided message is handed on again, and a decision is what settles it ------------------
  const third = pass();
  check(ids(third.parsed.events) === "a2", "an undecided message is handed on again (a reconcile, not a second child)");
  check(third.parsed.still_owed === 1, "still exactly one message owed");
  decided("a2");
  const fourth = pass();
  check(fourth.parsed.events.length === 0, "a message with a durable decision is not handed on again");
  check(fourth.parsed.already_decided >= 1, "the reader reports the decided message");
  check(fourth.parsed.still_owed === 0, "nothing is owed once the decision exists");
  check(fourth.parsed.cursor === 2000 && cursor() === 2000, "the cursor advances past a decided message");

  // ---- a message nobody decides is bounded, and cannot pin the cursor ------------------------------
  store([message("a1", 1000), message("a2", 2000), message("a3", 3000)], 3000);
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    const handed = pass();
    check(ids(handed.parsed.events) === "a3", `attempt ${attempt} hands the undecided message on`);
    check(handed.parsed.cursor === 2000, `attempt ${attempt} leaves the cursor before the undecided message`);
  }
  const gaveUp = pass();
  check(gaveUp.parsed.events.length === 0, "the reader stops handing a message on once the attempts run out");
  check(ids(gaveUp.parsed.exhausted) === "a3" && gaveUp.parsed.exhausted[0].attempts === 3,
    "the exhausted message is reported with its attempt count");
  check(gaveUp.parsed.cursor === 3000 && cursor() === 3000, "the attempt bound lets the cursor move past a message nobody decided");
  check(gaveUp.parsed.still_owed === 0, "an exhausted message is no longer owed");

  // ---- media is reported to the operator, never handed to a child ---------------------------------
  store([message("a1", 1000), message("a2", 2000), message("a3", 3000),
    message("a4", 4000, { media: [{ type: "voice" }], body: "[voice]" })], 4000);
  const media = pass();
  check(media.parsed.events.length === 0, "an eligible voice note is not handed to a child");
  check(ids(media.parsed.unanswerable) === "a4" && media.parsed.unanswerable[0].media === "voice",
    "the voice note is reported as unanswerable instead");
  check(media.parsed.cursor === 4000, "a reported media message is settled, so the cursor may pass it");

  // ---- the operator answering first is a decision too ---------------------------------------------
  store([message("a1", 1000), message("a2", 2000), message("a3", 3000),
    message("a4", 4000, { media: [{ type: "voice" }] }), message("a5", 5000),
    { conversation_id: CONV, message_id: "o1", sender_id: "self", direction: "outgoing", sent_at: 6000,
      body: "operator reply", media: [{ type: "chat" }] }], 6000);
  const precedence = pass();
  check(precedence.parsed.events.length === 0, "a message the operator already answered is not handed on");
  check(precedence.parsed.operator_answered >= 1, "the reader reports the operator's precedence");
  check(precedence.parsed.cursor === 5000, "the cursor passes a conversation the operator took over");
  // Standing down is invisible to the operator: they see no reply and cannot tell "the copilot decided not
  // to" from "the copilot never saw it". Every stand-down is therefore reported, with the moment the
  // operator took over, so silence is never ambiguous. Only `a5` is reported: `a1`-`a4` were settled in
  // earlier passes and sit below the cursor, so a stand-down is said once and never repeated.
  check(ids(precedence.parsed.stood_down) === "a5",
    `every message the operator took over is reported once (got ${ids(precedence.parsed.stood_down)})`);
  check((precedence.parsed.stood_down[0] || {}).took_over_at === 6000,
    `the report carries the moment the operator took over (got ${JSON.stringify(precedence.parsed.stood_down[0])})`);
  check(precedence.parsed.stood_down.every((entry) => entry.conversation_id === CONV),
    "the report names the conversation, so the operator knows where to look");

  // ---- a deterministic refusal is a decision too ---------------------------------------------------
  store([message("a1", 1000), message("a2", 2000), message("a3", 3000),
    message("a4", 4000, { media: [{ type: "voice" }] }), message("a5", 5000),
    { conversation_id: CONV, message_id: "o1", sender_id: "self", direction: "outgoing", sent_at: 6000,
      body: "operator reply", media: [{ type: "chat" }] },
    message("a6", 7000, { conversation_id: OTHER, eligibility: { eligible: false, reason: "group_without_operator_mention" } })], 7000);
  const refused = pass();
  check(refused.parsed.events.length === 0, "an ineligible message is never handed on");
  check(refused.parsed.cursor === 7000, "the cursor passes a message a rule refused");
  check(!refused.parsed.decisions_error, `the decision lookup succeeded: ${refused.parsed.decisions_error}`);
  // Once is enough: the stand-down cleared the owed entry, so a later pass cannot report it again. Without
  // this the operator would be told about the same message every 30 seconds, forever.
  check((refused.parsed.stood_down || []).length === 0,
    `a stand-down is reported once, not on every pass (got ${ids(refused.parsed.stood_down)})`);

  // ---- what the copilot sent as the operator is reported to their own inbox ------------------------
  // A reply that went out to somebody else is an effect on *their* conversation, and the operator reads
  // their own inbox, not the ledger. The reader emits one line per send since its last report, and advances
  // its report cursor so the same send is not announced twice.
  sent("s1", CONV, "Ok, obrigado!", "sent", Math.floor(Date.now() / 1000) + 10);
  const noticed = pass();
  const notices = noticed.parsed.notices || [];
  check(notices.length === 1, `a send is reported to the operator: ${JSON.stringify(notices)}`);
  check(/replied for you to Fixture contact/.test(notices[0].detail || ""), `the notice names the conversation: ${notices[0] && notices[0].detail}`);
  check(/Ok, obrigado!/.test(notices[0].detail || ""), "the notice carries what was said in the operator's name");
  check(!/[\r\n|]/.test(notices[0].detail || ""), "the notice is one line with one field separator, so the shell cannot split it");
  const noticedAgain = pass();
  check((noticedAgain.parsed.notices || []).length === 0, "the same send is not reported twice: the report cursor moved");
  sent("s2", CONV, "nao confirmado", "pending", Math.floor(Date.now() / 1000) + 20);
  const unconfirmed = pass();
  check((unconfirmed.parsed.notices || []).length === 1 && /NOT confirmed/.test(unconfirmed.parsed.notices[0].detail || ""),
    `a send that did not confirm is reported as not sent: ${JSON.stringify(unconfirmed.parsed.notices)}`);

  // ---- the window must reach a message that is still owed ------------------------------------------
  // The cursor moves past *settled* messages, so a newer settled one can leave an owed message far below
  // it - outside the ordinary `cursor - 3600` window. A real store then never returns that message again:
  // it is neither re-handed nor pruned, and the owed map holds it forever (measured live: the map still
  // held a message whose decision had arrived twenty minutes earlier). The floor must be the oldest owed
  // message, whatever the cursor says - and the mock returns everything, so the assertion is on the
  // window the reader *asks for*, which is the contract a real store honours.
  const tail = () => [message("a1", 1000), message("a2", 2000), message("a3", 3000),
    message("a4", 4000, { media: [{ type: "voice" }] }), message("a5", 5000),
    { conversation_id: CONV, message_id: "o1", sender_id: "self", direction: "outgoing", sent_at: 6000,
      body: "operator reply", media: [{ type: "chat" }] },
    message("a6", 7000, { conversation_id: OTHER, eligibility: { eligible: false, reason: "group_without_operator_mention" } })];
  store([...tail(), message("b1", 8000)], 8000);
  const handedOn = pass();
  check(ids(handedOn.parsed.events) === "b1", `a new message is handed on (got ${ids(handedOn.parsed.events)})`);
  check(handedOn.parsed.still_owed === 1, `it is recorded as owed a decision (still_owed=${handedOn.parsed.still_owed})`);
  // A newer message the deterministic rule settles pushes the cursor past it: 13000 - 3600 > 8000.
  store([...tail(), message("b1", 8000),
    message("settled", 13000, { conversation_id: OTHER, eligibility: { eligible: false, reason: "group_without_operator_mention" } })], 13000);
  const pushed = pass();
  check(pushed.parsed.cursor === 13000, `the cursor moves past the settled message (cursor=${pushed.parsed.cursor})`);
  check(ids(pushed.parsed.events) === "b1", "the owed message is handed on again");
  // The same window is what lets it prune: once a decision exists, the owed entry must disappear. This is
  // also the first pass whose *starting* cursor is past the owed message, so it is the one whose window
  // decides whether a real store would ever return the message again.
  decided("b1");
  const pruned = pass();
  check(lastSince() <= 8000 - 1, `the reader asks for a window that reaches the owed message: --since=${lastSince()}`);
  check(pruned.parsed.still_owed === 0 && pruned.parsed.already_decided >= 1,
    `an owed message below the cursor is pruned once decided (still_owed=${pruned.parsed.still_owed})`);
  check(Object.keys(owedMap()).length === 0, `the owed map no longer holds it: ${JSON.stringify(owedMap())}`);


  console.log(`whatsapp cursor ok (${checks} checks, 0 failed, 0 skipped; mock store, real ingest, no browser)`);
  console.log(`evidence: ${root}`);
  console.log("ALL PASS");
}

try {
  main();
} catch (error) {
  console.error(error.stack || String(error));
  console.error("evidence: " + root);
  process.exitCode = 1;
}
