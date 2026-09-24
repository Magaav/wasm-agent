// Hermetic voice lane proof: real Lua, SQLite, WASM, and operation host;
// fake WhatsApp media, local STT, and send adapters. No browser or model.
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const assert = require("node:assert/strict");
const { spawnSync } = require("node:child_process");
const { DatabaseSync } = require("node:sqlite");

const repo = path.resolve(__dirname, "..");
const requestedWa = path.resolve(process.argv[2] || path.join(repo, "rust/target/release/wa"));
const wa = process.platform === "win32" && !fs.existsSync(requestedWa) && fs.existsSync(requestedWa + ".exe")
  ? requestedWa + ".exe" : requestedWa;
const wasm = path.resolve(process.argv[3] || path.join(repo, "rust/plugins/whatsapp-transcript/target/wasm32-unknown-unknown/release/wa_plugin_whatsapp_transcript.wasm"));
const root = fs.mkdtempSync(path.join(os.tmpdir(), "wa-voice-"));
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
fs.writeFileSync(path.join(scripts, "audio.mjs"), `
import { writeFileSync } from 'node:fs';
const args=process.argv.slice(2), at=args.indexOf('--out');
writeFileSync(args[at+1],Buffer.from('fixture audio'));
console.log(JSON.stringify({ok:true,bytes:13}));
`);
fs.writeFileSync(path.join(scripts, "stt.mjs"), `
if (process.env.WA_TEST_STT_FAIL==='1') {console.log(JSON.stringify({ok:false,error:'local_stt_failed'}));process.exitCode=1}
else console.log(JSON.stringify({ok:true,transcript:process.env.WA_TEST_LONG==='1'?'x'.repeat(7000):'Olá mundo',local_only:true}));
`);
fs.writeFileSync(path.join(scripts, "reply.mjs"), `
import { readFileSync, appendFileSync } from 'node:fs';
const args=process.argv.slice(2), body=readFileSync(args[args.indexOf('--body-file')+1],'utf8');
if (process.env.WA_TEST_SEND_PRECHECK==='1' && body.includes('(2/3)')) {console.log(JSON.stringify({ok:false,error:'composer_preoccupied'}));process.exitCode=1}
else {
appendFileSync(process.env.WA_TEST_SEND_LOG,JSON.stringify({body,chat:args[args.indexOf('--chat')+1]})+'\\n');
if (process.env.WA_TEST_SEND_UNKNOWN==='1') {console.log(JSON.stringify({ok:false,error:'ambiguous_send'}));process.exitCode=1}
else console.log(JSON.stringify({ok:true,sent:true,verified:true,message:{id:'sent-fixture'}}));
}
`);

const chat = "5511888888888@c.us";
const conversations = [{ id: chat, title: "Sender", kind: "direct", left: false, archived: false }];
const message = (id, sent_at, kind = "chat") => ({
  conversation_id: chat, message_id: id, sender_id: "sender", direction: "incoming",
  sent_at, body: `[${kind}]`, media: [{ type: kind }],
});
function setStore(messages) {
  fs.writeFileSync(store, JSON.stringify({ ok: true, conversations, messages, newest: Math.max(...messages.map((m) => m.sent_at)) }));
}
function pass(extra = {}) {
  const run = spawnSync(wa, ["--db", db], { encoding: "utf8", timeout: 220000, windowsHide: true,
    env: { ...process.env, WASM_AGENT_HOME: root, WASM_AGENT_LUA_ROOT: repo,
      WASM_AGENT_PLUGINS: plugins, WA_SCRIPT: path.join(scripts, "whatsapp-transcribe.lua"),
      WA_TEST_STORE: store, WA_TEST_SEND_LOG: sends, WA_WHATSAPP_NODE: process.execPath,
      WA_WHATSAPP_AUDIO_SCRIPT: path.join(scripts, "audio.mjs"),
      WA_WHATSAPP_STT_PYTHON: process.execPath, WA_WHATSAPP_STT_SCRIPT: path.join(scripts, "stt.mjs"),
      WA_WHATSAPP_REPLY_SCRIPT: path.join(scripts, "reply.mjs"), ...extra } });
  const line = String(run.stdout || "").trim().split(/\r?\n/).pop();
  let value;
  try { value = JSON.parse(line); } catch { throw new Error(`not JSON: ${run.stdout}\n${run.stderr}`); }
  return { code: run.status, value, stderr: run.stderr };
}
function sent() { return fs.existsSync(sends) ? fs.readFileSync(sends, "utf8").trim().split("\n").filter(Boolean).map(JSON.parse) : []; }
function effect(id) {
  const database = new DatabaseSync(db, { readOnly: true });
  const row = database.prepare("SELECT state, body FROM effect_sends WHERE message_id=?").get(id);
  database.close();
  return row;
}

assert.ok(fs.existsSync(wa) && fs.existsSync(wasm));
setStore([message("old", 1000)]);
assert.equal(pass().value.primed, true);
setStore([message("old", 1000), message("voice1", 2000, "ptt")]);
const first = pass();
assert.equal(first.code, 0, JSON.stringify(first));
assert.equal(first.value.state, "sent");
assert.equal(effect("voice1:transcript:1").state, "sent");
assert.deepEqual(sent(), [{ body: "Transcrição do áudio:\nOlá mundo", chat }]);
assert.equal(pass().value.processed, 0);
assert.equal(sent().length, 1, "confirmed send is never replayed");

setStore([message("old", 1000), message("voice1", 2000, "ptt"), message("same_second", 2000, "ptt")]);
assert.equal(pass().value.state, "sent", "new audio in the cursor's second is processed");
assert.equal(effect("same_second:transcript:1").state, "sent");
assert.equal(pass().value.processed, 0, "same-second audio is not replayed");

setStore([message("old", 1000), message("voice1", 2000, "ptt"), message("same_second", 2000, "ptt"), message("voice2", 3000, "audio")]);
const failed = pass({ WA_TEST_STT_FAIL: "1" });
assert.equal(failed.value.step, "transcribe");
assert.equal(effect("voice2:transcript:1"), undefined, "failed recognition never reserves a send");
const recovered = pass();
assert.equal(recovered.value.state, "sent");
assert.equal(sent().length, 3, "transient local STT failure is retried");

setStore([message("old", 1000), message("voice1", 2000, "ptt"), message("same_second", 2000, "ptt"), message("voice2", 3000, "audio"), message("voice3", 4000, "voice")]);
const ambiguous = pass({ WA_TEST_SEND_UNKNOWN: "1" });
assert.equal(ambiguous.value.state, "unknown");
assert.equal(effect("voice3:transcript:1").state, "unknown");
assert.equal(pass().value.processed, 0);
assert.equal(sent().length, 4, "ambiguous send is never replayed");

setStore([message("old", 1000), message("voice1", 2000, "ptt"), message("same_second", 2000, "ptt"), message("voice2", 3000, "audio"),
  message("voice3", 4000, "voice"), message("voice4", 5000, "ptt")]);
const partBlocked = pass({ WA_TEST_LONG: "1", WA_TEST_SEND_PRECHECK: "1" });
assert.equal(partBlocked.value.step, "send_precheck");
assert.equal(partBlocked.value.part, 2);
assert.equal(effect("voice4:transcript:1").state, "sent");
assert.equal(effect("voice4:transcript:2"), undefined);
const partResumed = pass({ WA_TEST_STT_FAIL: "1" });
assert.equal(partResumed.value.state, "sent", "cached parts resume without running STT again");
assert.equal(sent().filter((row) => row.body.includes("(1/3)")).length, 1);
assert.equal(sent().filter((row) => row.body.includes("(2/3)")).length, 1);
assert.equal(sent().filter((row) => row.body.includes("(3/3)")).length, 1);
assert.equal(pass().value.processed, 0, "all parts were settled once");

const probe = path.join(scripts, "plugin-probe.lua");
fs.writeFileSync(probe, `assert(not host.plugins():find('whatsapp_transcript'), 'internal plugin in model tools')\nassert(host.invoke('whatsapp_transcript','{"transcript":"hello"}'):find('Transcrição'), 'plugin not callable')\nprint('plugin visibility ok')\n`);
const visibility = spawnSync(wa, ["--db", db], { encoding: "utf8", windowsHide: true,
  env: { ...process.env, WASM_AGENT_HOME: root, WASM_AGENT_LUA_ROOT: repo, WASM_AGENT_PLUGINS: plugins, WA_SCRIPT: probe } });
assert.equal(visibility.status, 0, visibility.stderr);
assert.match(visibility.stdout, /plugin visibility ok/);
// The real STT script must emit UTF-8 whatever the locale says. A transcript is read
// by a UTF-8 reader, and on Windows a piped stdout defaults to the ANSI code page,
// where each accented character becomes one byte the reader replaces with U+FFFD -
// the text is lost, not merely garbled. PYTHONIOENCODING=cp1252 reproduces that
// default on any platform, so this check means the same thing on Linux and Windows.
// The fake adapter above is UTF-8 and would never have caught it.
let encoding = "skipped: no usable python";
for (const python of [process.env.WA_WHATSAPP_STT_PYTHON, "python3", "python"]) {
  if (!python) continue;
  const snippet = [
    "import importlib.util, json, sys",
    `spec = importlib.util.spec_from_file_location('stt', ${JSON.stringify(path.join(repo, "scripts/whatsapp-stt-local.py"))})`,
    "mod = importlib.util.module_from_spec(spec)",
    "spec.loader.exec_module(mod)",
    "sys.stdout.write(json.dumps({'transcript': '\\u00c1rea de sa\\u00fade'}, ensure_ascii=False))",
  ].join("\n");
  const run = spawnSync(python, ["-c", snippet], { encoding: "buffer", windowsHide: true,
    env: { ...process.env, PYTHONIOENCODING: "cp1252" } });
  if (run.error || run.status !== 0) continue;
  const text = run.stdout.toString("utf8");
  assert.ok(!text.includes("\ufffd"), `STT output is not valid UTF-8: ${text}`);
  assert.match(text, /\u00c1rea de sa\u00fade/, "the transcript survived the round trip");
  encoding = "checked";
  break;
}
console.log(`whatsapp transcription ok (local adapter, WASM formatter, durable send, output encoding ${encoding}; ${encoding === "checked" ? 0 : 1} skipped)`);
console.log("evidence: " + root);
