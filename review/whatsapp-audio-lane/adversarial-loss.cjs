// INDEPENDENT adversarial fixture (reviewer-authored, not the delivery's own test).
// Goal 1: construct the silent loss the delivery claims to have fixed, with fresher traffic in the same
//         window, and check the cursor holds and the refusal is named.
// Goal 2: try to still lose a queued note silently.
// Goal 3: attack the NEW clamp for a duplicate-send regression - clamping the cursor back re-exposes
//         already-settled audio, so a second pass over it must not send its transcript again.
// Fake media/STT/send adapters, real Lua, real WASM formatter, real ledger. No browser, no model, no chat.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { queryOne } = require("../../scripts/lib/sqlite-python.cjs");

const repo = path.resolve(__dirname, "../..");
const wa = process.argv[2];
const wasm = process.argv[3];
const root = fs.mkdtempSync(path.join(os.tmpdir(), "wa-adv-"));
const scripts = path.join(root, "scripts");
const plugins = path.join(root, "plugins");
const db = path.join(root, "memory.db");
const store = path.join(root, "store.json");
const sends = path.join(root, "sends.jsonl");
const failSwitch = path.join(root, "fail");
fs.mkdirSync(scripts);
fs.mkdirSync(plugins);
fs.copyFileSync(path.join(repo, "scripts/whatsapp-transcribe.lua"), path.join(scripts, "whatsapp-transcribe.lua"));
fs.copyFileSync(wasm, path.join(plugins, "whatsapp-transcript.wasm"));
fs.writeFileSync(path.join(scripts, "whatsapp-read.mjs"), `
import { readFileSync, writeFileSync } from 'node:fs';
const args=process.argv.slice(2), at=(name)=>args.indexOf(name);
const since=Number(args[at('--since')+1]);
const full=JSON.parse(readFileSync(process.env.WA_TEST_STORE,'utf8'));
writeFileSync(args[at('--out')+1],JSON.stringify({...full,messages:full.messages.filter(m=>m.sent_at>since),dropped_over_limit:0}));
console.log(JSON.stringify({ok:true}));
`);
// The switch is a file, not an env var: it lets me flip the download between passes of one run.
fs.writeFileSync(path.join(scripts, "audio.mjs"), `
import { writeFileSync, existsSync } from 'node:fs';
const args=process.argv.slice(2), at=args.indexOf('--out');
if (existsSync(process.env.WA_ADV_FAIL_SWITCH)) {
  console.log(JSON.stringify({ok:false,error:'audio_browser_exception:InvalidMediaFileType: Unexpected mimetype application/octet-stream for media type ptt'}));
  process.exitCode=1;
} else { writeFileSync(args[at+1],Buffer.from('fixture audio')); console.log(JSON.stringify({ok:true,bytes:13})); }
`);
fs.writeFileSync(path.join(scripts, "stt.mjs"), `console.log(JSON.stringify({ok:true,transcript:'texto',local_only:true}));`);
fs.writeFileSync(path.join(scripts, "store-send.mjs"), `
import { readFileSync, appendFileSync } from 'node:fs';
const args=process.argv.slice(2), body=readFileSync(args[args.indexOf('--body-file')+1],'utf8');
appendFileSync(process.env.WA_TEST_SEND_LOG,JSON.stringify({body,chat:args[args.indexOf('--chat')+1]})+'\\n');
console.log(JSON.stringify({ok:true,sent:true,verified:true,message:{id:'fixture-sent'}}));
`);

const chat = "5511777777777@c.us";
const conversations = [{ id: chat, title: "Sender", kind: "direct", left: false, archived: false }];
const NOW = Math.floor(Date.now() / 1000);
const text = (id, age) => ({ conversation_id: chat, message_id: id, sender_id: "sender", direction: "incoming",
  sent_at: NOW - age, body: "[chat]", media: [{ type: "chat" }] });
const note = (id, age) => ({ conversation_id: chat, message_id: id, sender_id: "sender", direction: "incoming",
  sent_at: NOW - age, body: "[ptt]", media: [{ type: "ptt" }] });
function setStore(messages) {
  fs.writeFileSync(store, JSON.stringify({ ok: true, conversations, messages,
    newest: Math.max(...messages.map((m) => m.sent_at)) }));
}
function pass(extra = {}) {
  const run = spawnSync(wa, ["--db", db], { encoding: "utf8", timeout: 220000, windowsHide: true,
    env: { ...process.env, WASM_AGENT_HOME: root, WASM_AGENT_LUA_ROOT: repo, WASM_AGENT_PLUGINS: plugins,
      WA_SCRIPT: path.join(scripts, "whatsapp-transcribe.lua"), WA_TEST_STORE: store, WA_TEST_SEND_LOG: sends,
      WA_WHATSAPP_NODE: process.execPath, WA_WHATSAPP_AUDIO_SCRIPT: path.join(scripts, "audio.mjs"),
      WA_WHATSAPP_STT_PYTHON: process.execPath, WA_WHATSAPP_STT_SCRIPT: path.join(scripts, "stt.mjs"),
      WA_WHATSAPP_STORE_SEND_SCRIPT: path.join(scripts, "store-send.mjs"),
      WA_WHATSAPP_ACCOUNT: "5511999999999@c.us",
      WA_WHATSAPP_BROWSER_ENDPOINT: "ws://127.0.0.1:9222/devtools/page/fixture",
      WA_ADV_FAIL_SWITCH: failSwitch, ...extra } });
  const line = String(run.stdout || "").trim().split(/\r?\n/).pop();
  let value; try { value = JSON.parse(line); } catch { throw new Error("not JSON: " + run.stdout + run.stderr); }
  return { code: run.status, value };
}
const cursor = () => Number((queryOne(db, "SELECT value FROM meta WHERE key=?", ["whatsapp_transcribe_cursor"]) || {}).value);
const pending = () => JSON.parse((queryOne(db, "SELECT value FROM meta WHERE key=?", ["whatsapp_transcribe_pending"]) || {}).value || "{}");
const sent = () => (fs.existsSync(sends) ? fs.readFileSync(sends, "utf8").trim().split("\n").filter(Boolean).map(JSON.parse) : []);
const decide = (id) => queryOne(db, "SELECT decision, reason FROM effect_decisions WHERE message_id=?", [id]);
let checks = 0;
const check = (v, label) => { assert.ok(v, label); checks += 1; };

// ---------------------------------------------------------------- scenario 1: fresher traffic, cursor holds
setStore([text("t0", 300)]);
assert.equal(pass().value.primed, true);
setStore([text("t0", 300), note("loud1", 200)]);
fs.writeFileSync(failSwitch, "1");
const f1 = pass();
check(f1.value.ok === false && f1.value.step === "download" && f1.value.state === "retryable",
  `S1 failing download is a retryable, named refusal: ${JSON.stringify(f1.value)}`);
check(f1.value.message_id === "loud1", `S1 names the id: ${f1.value.message_id}`);
check(/InvalidMediaFileType/.test(String(f1.value.error)), `S1 carries the underlying error: ${f1.value.error}`);
const cursorAfterFail = cursor();
check(cursorAfterFail < NOW - 200, `S1 cursor did NOT advance past the failing note: cursor=${cursorAfterFail} note=${NOW - 200}`);
// fresher traffic arrives in the same window, and the note still fails
setStore([text("t0", 300), note("loud1", 200), text("fresh", 100)]);
const f2 = pass();
check(cursor() < NOW - 200, `S1 cursor still holds after fresher traffic (${cursor()} < ${NOW - 200})`);
check(Object.keys(pending()).includes("loud1"), `S1 the note survives as a durable pending row: ${JSON.stringify(pending())}`);
// the retry reaches it: same note, now downloadable
fs.rmSync(failSwitch);
const f3 = pass();
check(f3.value.state === "sent" && f3.value.message_id === "loud1",
  `S1 the held note is processed on the next pass: ${JSON.stringify(f3.value)}`);
check(sent().length === 1, `S1 one transcript sent: ${sent().length}`);

// ---------------------------------------------------------------- scenario 2: aged out => reported, not silent
setStore([text("t0", 300), note("loud1", 200), note("loud2", 90)]);
fs.writeFileSync(failSwitch, "1");
const q = pass();
check(q.value.state === "retryable" && q.value.pending === 1, `S2 note queued and failing: ${JSON.stringify(q.value)}`);
const swept = pass({ WA_WHATSAPP_TRANSCRIBE_MAX_AGE_SECONDS: "1" });
check(!(swept.value.ok === true && swept.value.pending === 0 && (swept.value.refused || []).length === 0),
  `S2 the exact old shape is unreachable: ${JSON.stringify(swept.value)}`);
check(swept.value.ok === false && swept.value.message_id === "loud2" && swept.value.step === "download",
  `S2 the lost note, step and error are in the step result: ${JSON.stringify(swept.value)}`);
check(/InvalidMediaFileType/.test(String(swept.value.error)), `S2 the error is the real one, not just stale_audio: ${swept.value.error}`);
const entry = (swept.value.refused || []).find((r) => r.message_id === "loud2");
check(!!entry && entry.reason === "stale_audio" && entry.step === "download" && /InvalidMediaFileType/.test(String(entry.error)),
  `S2 the refusal carries id + step + underlying error: ${JSON.stringify(entry)}`);
check(JSON.stringify(decide("loud2")) === JSON.stringify({ decision: "transcription_refused", reason: "stale_audio" }),
  `S2 the loss is durable: ${JSON.stringify(decide("loud2"))}`);
check(sent().length === 1, `S2 the lost note sent nothing: ${sent().length}`);

// ------------------------------------------- scenario 3: two failing notes settle once each
// The clamp pulls the cursor back to just before the OLDEST pending note, so anything newer than that is
// re-scanned. I could not construct a re-exposure of an already-settled note: the scan needs at > cursor and
// the clamp keeps cursor below every pending note, while a pass touches only the oldest pending note. What is
// reachable - and what would be a send-safety regression - is a note being settled twice. This checks it.
const db2 = path.join(root, "memory2.db");
const pass2 = (extra = {}) => {
  const run = spawnSync(wa, ["--db", db2], { encoding: "utf8", timeout: 220000, windowsHide: true,
    env: { ...process.env, WASM_AGENT_HOME: root, WASM_AGENT_LUA_ROOT: repo, WASM_AGENT_PLUGINS: plugins,
      WA_SCRIPT: path.join(scripts, "whatsapp-transcribe.lua"), WA_TEST_STORE: store, WA_TEST_SEND_LOG: sends,
      WA_WHATSAPP_NODE: process.execPath, WA_WHATSAPP_AUDIO_SCRIPT: path.join(scripts, "audio.mjs"),
      WA_WHATSAPP_STT_PYTHON: process.execPath, WA_WHATSAPP_STT_SCRIPT: path.join(scripts, "stt.mjs"),
      WA_WHATSAPP_STORE_SEND_SCRIPT: path.join(scripts, "store-send.mjs"),
      WA_WHATSAPP_ACCOUNT: "5511999999999@c.us",
      WA_WHATSAPP_BROWSER_ENDPOINT: "ws://127.0.0.1:9222/devtools/page/fixture",
      WA_ADV_FAIL_SWITCH: failSwitch, ...extra } });
  const line = String(run.stdout || "").trim().split(/\r?\n/).pop();
  return { code: run.status, value: JSON.parse(line) };
};
const cursor2 = () => Number((queryOne(db2, "SELECT value FROM meta WHERE key=?", ["whatsapp_transcribe_cursor"]) || {}).value);
const cursorIds2 = () => (queryOne(db2, "SELECT value FROM meta WHERE key=?", ["whatsapp_transcribe_cursor_ids"]) || {}).value;
fs.writeFileSync(sends, "");
setStore([text("t0", 300)]);
assert.equal(pass2().value.primed, true);
// two notes arrive together, both downloads fail, the older is attempted first
setStore([text("t0", 300), note("older", 90), note("newer", 40)]);
fs.writeFileSync(failSwitch, "1");
const a1 = pass2();
check(a1.value.message_id === "older" && a1.value.state === "retryable", `S3 the older note fails first: ${JSON.stringify(a1.value)}`);
check(cursor2() < NOW - 90, `S3 cursor holds below the oldest pending note: ${cursor2()} vs ${NOW - 90}`);
check(Object.keys(JSON.parse((queryOne(db2, "SELECT value FROM meta WHERE key=?", ["whatsapp_transcribe_pending"]) || {}).value || "{}")).sort().join()
  === "newer,older", "S3 both notes are queued, none dropped");
// the download recovers: the two notes settle one per pass, once each
fs.rmSync(failSwitch);
const a2 = pass2();
check(a2.value.message_id === "older" && a2.value.state === "sent", `S3 the older note settles: ${JSON.stringify(a2.value)}`);
const a3 = pass2();
check(a3.value.message_id === "newer" && a3.value.state === "sent", `S3 the newer note settles: ${JSON.stringify(a3.value)}`);
check(sent().length === 2, `S3 exactly two sends, no duplicate: ${JSON.stringify(sent())}`);
// The two notes produce the same transcript text, so send count is not the duplicate test on its own: the
// ledger is. One settled decision per note, and one send per part key.
const settledRows = queryOne(db2, "SELECT COUNT(*) AS n FROM effect_decisions WHERE decision='transcribed_sent'", []);
check(Number(settledRows.n) === 2, `S3 exactly one settled decision per note: ${JSON.stringify(settledRows)}`);
const partStates = queryOne(db2, "SELECT COUNT(*) AS n, COUNT(DISTINCT message_id) AS distinct_notes FROM effect_decisions WHERE decision='transcribed_sent'", []);
check(Number(partStates.n) === 2 && Number(partStates.distinct_notes) === 2,
  `S3 two notes, two settled decisions, once each: ${JSON.stringify(partStates)}`);
check(cursor2() >= NOW - 40, `S3 the cursor reaches the newest settled note: ${cursor2()}`);

// ------------------- scenario 4: the pass that cannot read the source - is the swept loss still recorded?
// A queued note ages out in the same pass in which the source read fails. The step result then fails at
// `read` and does not carry the stale detail: how much of the loss is still visible?
setStore([text("t0", 300), note("gone", 20)]);
fs.writeFileSync(failSwitch, "1");
const q1 = pass();
check(q1.value.state === "retryable" && q1.value.message_id === "gone", `S4 the note is queued and failing: ${JSON.stringify(q1.value)}`);
const brokenStore = path.join(root, "absent-store.json");
const q2 = pass({ WA_WHATSAPP_TRANSCRIBE_MAX_AGE_SECONDS: "1", WA_TEST_STORE: brokenStore });
check(q2.value.ok === false, `S4 the read failure is not ok: ${JSON.stringify(q2.value)}`);
check(q2.value.step === "read", `S4 and it names the step that broke: ${JSON.stringify(q2.value)}`);
const durableGone = decide("gone");
check(JSON.stringify(durableGone) === JSON.stringify({ decision: "transcription_refused", reason: "stale_audio" }),
  `S4 the swept note is still durably refused even when the pass dies at read: ${JSON.stringify(durableGone)}`);
console.log("S4 NOTE: the read-failure result carries step=read and does NOT carry the stale step/error; the loss "
  + "is visible only as the durable refusal above. Reported as an observation, not a blocker.");

console.log(`adversarial loss review ok (${checks} checks, 0 failed; independent fixture, fake adapters, real Lua)`);
console.log("evidence: " + root);
