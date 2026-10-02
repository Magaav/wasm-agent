// The silent skip, hermetically: real Lua, SQLite, WASM and operation host; fake WhatsApp media, local STT
// and send adapters. No browser, no sentinel, no model.
//
// The failure this pins down was measured on the live node: a voice note whose browser download failed
// (`audio_browser_exception`) stayed pending, aged past the 600 s window, and was then dropped by the stale
// sweep - which reported nothing. Every tick since said {"ok":true,"pending":0,"processed":0,"refused":[]},
// so the lane looked healthy while every note was lost. Three rules have to hold, and each one fails on the
// old shape:
//   * a failed download is `retryable` AND the cursor does not move past the note it could not download
//     (otherwise the next pass can no longer reach it and the loss is permanent);
//   * the underlying error - not just "stale_audio" - travels into the step result, so the reason a note was
//     lost is readable;
//   * a pass that drops a queued note is not "ok, nothing pending, nothing refused": the refusal is a
//     result, with the id, the step and the error.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { queryOne } = require("./lib/sqlite-python.cjs");

const repo = path.resolve(__dirname, "..");
const requestedWa = path.resolve(process.argv[2] || path.join(repo, "rust/target/release/wa"));
const wa = process.platform === "win32" && !fs.existsSync(requestedWa) && fs.existsSync(requestedWa + ".exe")
  ? requestedWa + ".exe" : requestedWa;
const wasm = path.resolve(process.argv[3] || path.join(repo, "rust/plugins/whatsapp-transcript/target/wasm32-unknown-unknown/release/wa_plugin_whatsapp_transcript.wasm"));
const root = fs.mkdtempSync(path.join(os.tmpdir(), "wa-loss-"));
const scripts = path.join(root, "scripts");
const plugins = path.join(root, "plugins");
const db = path.join(root, "memory.db");
const store = path.join(root, "store.json");
const sends = path.join(root, "sends.jsonl");
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
// The download failure, in the exact shape the live browser produced after the fix: the app's own typed
// rejection, carried out of the page. The old shape was the wrapper text ("Uncaught (in promise)").
const DOWNLOAD_ERROR = "audio_browser_exception:InvalidMediaFileType: Unexpected mimetype application/octet-stream for media type ptt";
fs.writeFileSync(path.join(scripts, "audio.mjs"), `
import { writeFileSync } from 'node:fs';
const args=process.argv.slice(2), at=args.indexOf('--out');
if (process.env.WA_TEST_DOWNLOAD_FAIL==='1') {console.log(JSON.stringify({ok:false,error:${JSON.stringify(DOWNLOAD_ERROR)}}));process.exitCode=1}
else {writeFileSync(args[at+1],Buffer.from('fixture audio'));console.log(JSON.stringify({ok:true,bytes:13}))}
`);
fs.writeFileSync(path.join(scripts, "stt.mjs"), `console.log(JSON.stringify({ok:true,transcript:'Olá mundo',local_only:true}));`);
fs.writeFileSync(path.join(scripts, "store-send.mjs"), `
import { readFileSync, appendFileSync } from 'node:fs';
const args=process.argv.slice(2), body=readFileSync(args[args.indexOf('--body-file')+1],'utf8');
appendFileSync(process.env.WA_TEST_SEND_LOG,JSON.stringify({body,chat:args[args.indexOf('--chat')+1]})+'\\n');
console.log(JSON.stringify({ok:true,sent:true,verified:true,message:{id:'sent-fixture'}}));
`);

const chat = "5511888888888@c.us";
const conversations = [{ id: chat, title: "Sender", kind: "direct", left: false, archived: false }];
const NOW = Math.floor(Date.now() / 1000);
const text = { conversation_id: chat, message_id: "old", sender_id: "sender", direction: "incoming",
  sent_at: NOW - 300, body: "[chat]", media: [{ type: "chat" }] };
const note = (id, age) => ({ conversation_id: chat, message_id: id, sender_id: "sender", direction: "incoming",
  sent_at: NOW - age, body: "[ptt]", media: [{ type: "ptt" }] });
function setStore(messages) {
  fs.writeFileSync(store, JSON.stringify({ ok: true, conversations, messages,
    newest: Math.max(...messages.map((m) => m.sent_at)) }));
}
function pass(extra = {}) {
  const run = spawnSync(wa, ["--db", db], { encoding: "utf8", timeout: 220000, windowsHide: true,
    env: { ...process.env, WASM_AGENT_HOME: root, WASM_AGENT_LUA_ROOT: repo,
      WASM_AGENT_PLUGINS: plugins, WA_SCRIPT: path.join(scripts, "whatsapp-transcribe.lua"),
      WA_TEST_STORE: store, WA_TEST_SEND_LOG: sends, WA_WHATSAPP_NODE: process.execPath,
      WA_WHATSAPP_AUDIO_SCRIPT: path.join(scripts, "audio.mjs"),
      WA_WHATSAPP_STT_PYTHON: process.execPath, WA_WHATSAPP_STT_SCRIPT: path.join(scripts, "stt.mjs"),
      WA_WHATSAPP_STORE_SEND_SCRIPT: path.join(scripts, "store-send.mjs"),
      WA_WHATSAPP_ACCOUNT: "5511999999999@c.us",
      WA_WHATSAPP_BROWSER_ENDPOINT: "ws://127.0.0.1:9222/devtools/page/fixture",
      ...extra } });
  const line = String(run.stdout || "").trim().split(/\r?\n/).pop();
  let value;
  try { value = JSON.parse(line); } catch { throw new Error(`not JSON: ${run.stdout}\n${run.stderr}`); }
  return { code: run.status, value, stderr: run.stderr };
}
const cursor = () => Number((queryOne(db, "SELECT value FROM meta WHERE key=?", ["whatsapp_transcribe_cursor"]) || {}).value);
const pendingRows = () => JSON.parse((queryOne(db, "SELECT value FROM meta WHERE key=?", ["whatsapp_transcribe_pending"]) || {}).value || "{}");
const decision = (id) => queryOne(db, "SELECT decision, reason FROM effect_decisions WHERE message_id=?", [id]);
const sentRows = () => (fs.existsSync(sends) ? fs.readFileSync(sends, "utf8").trim().split("\n").filter(Boolean).map(JSON.parse) : []);
let checks = 0;
const check = (value, label) => { assert.ok(value, label); checks += 1; };

assert.ok(fs.existsSync(wa) && fs.existsSync(wasm), `missing ${wa} or ${wasm}`);
setStore([text]);
assert.equal(pass().value.primed, true);

// ---- a failed download is retryable, named, and does not move the cursor past the note ----------------
setStore([text, note("voice1", 50)]);
const failed = pass({ WA_TEST_DOWNLOAD_FAIL: "1" });
check(failed.value.ok === false, `a failed download does not report ok: ${JSON.stringify(failed.value)}`);
check(failed.value.step === "download", `the failing step is named: ${failed.value.step}`);
check(failed.value.state === "retryable", `a download failure is retryable, not terminal: ${failed.value.state}`);
check(failed.value.message_id === "voice1", `the failing message id is named: ${failed.value.message_id}`);
check(/InvalidMediaFileType/.test(String(failed.value.error)),
  `the underlying error travels, not a bare "download failed": ${failed.value.error}`);
check(failed.value.pending === 1, `the note is still queued: ${failed.value.pending}`);
check(cursor() < NOW - 50,
  `the cursor did not advance past the note it could not download (cursor ${cursor()} vs note ${NOW - 50})`);
check(Object.keys(pendingRows()).includes("voice1"), "the durable pending row survives the failure");
check(sentRows().length === 0, "a failed download never sends anything");

// The retry is the same note, and it succeeds: a retryable failure is not a skip.
const recovered = pass();
check(recovered.value.state === "sent", `the note is processed on the next pass: ${JSON.stringify(recovered.value)}`);
check(sentRows().length === 1, "exactly one transcript was sent after the retry");
check(cursor() >= NOW - 50, `a settled pass may move the cursor: ${cursor()}`);

// ---- and the aged-out case: the exact old shape must be impossible -------------------------------------
setStore([text, note("voice2", 40)]);
const queued = pass({ WA_TEST_DOWNLOAD_FAIL: "1" });
check(queued.value.state === "retryable" && queued.value.message_id === "voice2",
  `the second note is queued and failing: ${JSON.stringify(queued.value)}`);
// The window is moved under the queued note (one second), which is the situation the live node reached after
// ten minutes of failed downloads: the sweep refuses it. The old code dropped it here and said nothing.
const stale = pass({ WA_TEST_DOWNLOAD_FAIL: "1", WA_WHATSAPP_TRANSCRIBE_MAX_AGE_SECONDS: "1" });
check(stale.value.ok === false, `a pass that lost a queued note does not report ok: ${JSON.stringify(stale.value)}`);
assert.notDeepEqual({ ok: stale.value.ok, pending: stale.value.pending, refused: stale.value.refused },
  { ok: true, pending: 0, refused: [] },
  "the exact old shape: ok with nothing pending and nothing refused while an incoming ptt was in the window");
checks += 1;
check(stale.value.message_id === "voice2", `the lost note is named in the step result: ${stale.value.message_id}`);
check(stale.value.step === "download", `the step that lost it is named: ${stale.value.step}`);
check(/InvalidMediaFileType/.test(String(stale.value.error)),
  `the underlying error is named, not only stale_audio: ${stale.value.error}`);
const refusal = (stale.value.refused || []).find((entry) => entry.message_id === "voice2");
check(!!refusal, `the refusal is in the step result: ${JSON.stringify(stale.value.refused)}`);
check(refusal && refusal.reason === "stale_audio", `the refusal reason is explicit: ${refusal && refusal.reason}`);
check(refusal && refusal.step === "download" && /InvalidMediaFileType/.test(String(refusal.error)),
  `the refusal carries the step and the error that lost it: ${JSON.stringify(refusal)}`);
check(refusal && refusal.attempts >= 1, `the refusal counts the attempts: ${refusal && refusal.attempts}`);
const durable = decision("voice2");
check(durable && durable.decision === "transcription_refused" && durable.reason === "stale_audio",
  `the refusal is durable: ${JSON.stringify(durable)}`);
check(sentRows().length === 1, "the lost note sent nothing into the chat");
check(!Object.keys(pendingRows()).includes("voice2"), "the refused note is out of the pending list");

console.log(`whatsapp audio loss ok (${checks} checks, 0 failed, 0 skipped; fake media/STT/send, no browser, no model)`);
console.log("evidence: " + root);
