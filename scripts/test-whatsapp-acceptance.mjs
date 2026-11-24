#!/usr/bin/env node
// The acceptance script's own contracts, checked without starting a node (fast path row "whatsapp-acceptance").
//
// What it measures, and why each one is a contract rather than a style note:
//
//   * THE ROWS COVER THE SURFACE. The script's TOOLS list is compared with the verbs in
//     lua/core/whatsapp.lua (M.TOOLS): a tool added there and forgotten here would leave the table silently
//     incomplete, which is the one failure this mission exists to prevent (13/11: contacts was added to the
//     component and the pin did not move).
//   * LIVE RUNS REFUSE A MISSING OR MALFORMED TARGET. --mode live without --own-chat, or with something
//     that is not an exact chat JID, must refuse before anything is called (privacy: the live run touches
//     the operator's own chat and nothing else).
//   * THE OWN-CHAT GUARD IS IN THE DRIVER, BEFORE THE CALL. The Lua driver must carry the refusal
//     ("refused_not_own_chat") and the plan must exercise it, or "never another person's chat" is a
//     promise with no code behind it.
//   * THE DRIVER REDACTES. Its redaction table must carry a rule for a JID and a rule for digits, because
//     the table prints values that come from a real account at G.
import {spawnSync} from "node:child_process";
import {readFileSync, existsSync} from "node:fs";
import path from "node:path";

const ROOT = path.resolve(new URL(".", import.meta.url).pathname, "..");
const SCRIPT = path.join(ROOT, "scripts/whatsapp-acceptance.mjs");
const DRIVER = path.join(ROOT, "scripts/lib/whatsapp-acceptance-call.lua");
const SURFACE = path.join(ROOT, "lua/core/whatsapp.lua");

let checks = 0;
const problems = [];
function check(condition, label, detail) {
  checks += 1;
  if (!condition) problems.push(label + (detail ? " - " + detail : ""));
}
function read(file) { return existsSync(file) ? readFileSync(file, "utf8") : ""; }

const script = read(SCRIPT);
const driver = read(DRIVER);
const surface = read(SURFACE);
check(script.length > 0, "scripts/whatsapp-acceptance.mjs exists");
check(driver.length > 0, "scripts/lib/whatsapp-acceptance-call.lua exists");

// ---- 1. every verb of the surface is a row -----------------------------------------------------------------
const surfaceVerbs = [...surface.matchAll(/\bverb = '([a-z_]+)'/g)].map((match) => match[1]);
const surfaceHidden = [...surface.matchAll(/\bverb = '([a-z_]+)',[^\n]*hidden = true/g)].map((match) => match[1]);
const scriptVerbs = [...script.matchAll(/\{verb: "([a-z_]+)"/g)].map((match) => match[1]);
check(surfaceVerbs.length >= 8, "the surface really lists its verbs", "found " + surfaceVerbs.length + " in lua/core/whatsapp.lua");
for (const verb of surfaceVerbs) check(scriptVerbs.includes(verb), "the table has a row for mcp_whatsapp_" + verb);
for (const verb of scriptVerbs) check(surfaceVerbs.includes(verb), "the table's row mcp_whatsapp_" + verb + " is a tool the surface exposes");
for (const verb of surfaceHidden) {
  const row = new RegExp('\\{verb: "' + verb + '",[^\\n]*hidden: true').test(script);
  check(row, "mcp_whatsapp_" + verb + " is marked hidden in the table, as it is on the surface");
}

// ---- 2. live mode refuses a missing or malformed target ----------------------------------------------------
const noChat = spawnSync(process.execPath, [SCRIPT, "--mode", "live"], {encoding: "utf8", timeout: 30000});
check(noChat.status === 2, "--mode live without --own-chat exits 2", "exit " + noChat.status);
check((noChat.stderr || "").includes("--own-chat"), "--mode live says which argument it needs", noChat.stderr);
const badChat = spawnSync(process.execPath, [SCRIPT, "--mode", "live", "--own-chat", "victor"], {encoding: "utf8", timeout: 30000});
check(badChat.status === 2, "--mode live refuses a target that is not an exact chat JID", "exit " + badChat.status);
check((badChat.stderr || "").includes("JID"), "the refusal names what a chat has to look like", badChat.stderr);
const help = spawnSync(process.execPath, [SCRIPT, "--help"], {encoding: "utf8", timeout: 30000});
check(help.status === 0 && (help.stdout || "").includes("--own-chat"), "--help documents the live target");

// ---- 3. the own-chat guard, in the driver and in the plan ---------------------------------------------------
check(driver.includes("refused_not_own_chat"), "the driver refuses a chat that is not the configured own chat");
check(/own_chat ~= "" and type\(args\.chat\) == "string" and args\.chat ~= own_chat/.test(driver),
  "the refusal is an allow-list on the exact chat, checked before the call");
check(driver.indexOf("refused_not_own_chat") < driver.indexOf("pcall(tools.dispatch"),
  "the guard runs BEFORE the dispatch, so nothing is called for another chat");
check(script.includes("guard/other-chat"), "the plan exercises the guard with a target that is not the own chat");
// The ONE bypass is a validation probe on a shape no account can own: a synthetic step is allowed past the
// guard only when its chat is NOT a well-formed JID, so no well-formed foreign chat can ever reach a call.
check(/step\.synthetic == true and type\(args\.chat\) == "string" and not args\.chat:match\(WELL_FORMED\)/.test(driver),
  "the synthetic bypass is limited to a chat that is not a well-formed JID");
check(driver.includes('^%d+@(s%.whatsapp%.net|lid|g%.us)$'), "the well-formed test is the exact chat shape the surface accepts");
check(script.includes("FIXTURE.foreign_chat"), "the guard row uses a fixture target, never a real one");
check(/000000000000000@s\.whatsapp\.net/.test(script), "the fixture target is a chat no account can own");

// ---- 4. redaction: a JID rule and a digits rule, before anything is printed ---------------------------------
check(driver.includes("@([%w%.%-]+)"), "the driver redacts an email/JID");
check(driver.includes('("%d"):rep(5)'), "the driver redacts a run of five or more digits (a phone number)");
check(driver.includes("redact(value)"), "every allow-listed field passes through the redaction");
check(!/record\.fields\.chat\b/.test(driver) && !/record\.fields\.text\b/.test(driver),
  "the driver never reports a chat or a message body as a field");
check(script.includes("function scrub("), "the script re-checks every value before printing it");

// ---- 5. live mode is DEFAULT-DENY, and the plan says so ------------------------------------------
// Fable 24/11: in live mode a step that names NO chat is refused by name before any dispatch, unless it
// is one of the few read-only questions about the ACCOUNT itself. The allow-list is stated here
// independently of the driver, so the two have to agree:
//   approve {action:list|policy}  - the operator's gate, read-only forms
//   send/send_status in their resume form (an id, never a chat; the resume never sends)
const FIXTURE_OWN = "000000000000000@s.whatsapp.net";
const livePlanRun = spawnSync(process.execPath, [SCRIPT, "--print-plan", "--mode", "live", "--own-chat", FIXTURE_OWN], {encoding: "utf8", timeout: 30000});
check(livePlanRun.status === 0, "--print-plan --mode live exits 0", livePlanRun.stderr);
let livePlan = null;
try { livePlan = JSON.parse(livePlanRun.stdout); } catch { livePlan = null; }
check(livePlan && Array.isArray(livePlan.steps) && livePlan.steps.length > 4, "the live plan is readable JSON with its steps");
const steps = (livePlan && livePlan.steps) || [];
const toolOf = (step) => step.tool;
const chatOf = (step) => (step.args && step.args.chat);
const allowListed = (step) => {
  const args = step.args || {};
  if (toolOf(step) === "mcp_whatsapp_approve") return args.action === "list" || args.action === "policy";
  if (toolOf(step) === "mcp_whatsapp_send" || toolOf(step) === "mcp_whatsapp_send_status") {
    // The resume form carries the job id it got from an earlier step (reuse) or an explicit id/cancel; the
    // driver fills it in at run time, so the PLAN states it as a reuse.
    const reuse = step.reuse && step.reuse.id !== undefined;
    return reuse || args.id !== undefined || args.ids !== undefined || args.draft !== undefined || args.cancel !== undefined;
  }
  return false;
};
const chatless = steps.filter((step) => chatOf(step) === undefined);
check(chatless.every(allowListed), "every live step with no chat argument is on the allow-list",
  chatless.filter((step) => !allowListed(step)).map((step) => step.id).join(", "));
check(steps.some((step) => chatOf(step) === FIXTURE_OWN), "the live plan does read the own chat");
check(chatless.length > 0 && chatless.length <= 6, "the allow-listed chat-less steps are a short list", String(chatless.length));
// NOTHING about other people's entries: no lookup by name, no account-wide history sync.
check(!steps.some((step) => toolOf(step) === "mcp_whatsapp_contacts"), "contacts (a lookup in other people's entries) is not in the live plan");
check(!steps.some((step) => toolOf(step) === "mcp_whatsapp_backfill"), "backfill (an account-wide history sync) is not in the live plan");
// Every step that names a chat names the OWN chat, or a shape no account can own (a validation probe).
for (const step of steps) {
  const chat = chatOf(step);
  if (chat === undefined) continue;
  const synthetic = step.synthetic === true && !/^[0-9]+@(s\.whatsapp\.net|lid|g\.us)$/.test(chat);
  const ownOrGuard = chat === FIXTURE_OWN || step.id === "guard/other-chat" || synthetic;
  check(ownOrGuard, "live step " + step.id + " names the own chat (or is the guard/probe row)", chat);
}
// The scratch plan keeps both cells: they are how the scratch table proves those tools at all.
const scratchPlanRun = spawnSync(process.execPath, [SCRIPT, "--print-plan"], {encoding: "utf8", timeout: 30000});
let scratchPlan = null;
try { scratchPlan = JSON.parse(scratchPlanRun.stdout); } catch { scratchPlan = null; }
const scratchTools = ((scratchPlan && scratchPlan.steps) || []).map(toolOf);
check(scratchTools.includes("mcp_whatsapp_contacts"), "the scratch plan still calls contacts");
check(scratchTools.includes("mcp_whatsapp_backfill"), "the scratch plan still calls backfill");
check(spawnSync(process.execPath, [SCRIPT, "--print-plan", "--mode", "live"], {encoding: "utf8", timeout: 30000}).status === 2,
  "--print-plan --mode live without --own-chat exits 2");
// And the driver really refuses: the word, and its position before the dispatch it protects.
check(driver.includes("refused_no_chat_in_live"), "the driver refuses a chat-less live step by name");
check(driver.indexOf("refused_no_chat_in_live") < driver.indexOf("pcall(tools.dispatch"), "the default-deny runs BEFORE the dispatch");
check(driver.includes("chat_less_allowed(record.tool, args)"), "the default-deny consults the allow-list");

// ---- 6. the scratch-home guard ---------------------------------------------------------------
check(script.includes("refusing to run"), "a run that would write in the node home refuses");
check(script.includes("REAL_HOME"), "the refusal is about the operator's own node home");

// ---- 7. the one real message text, and the dedupe row uses the same one -------------------------
// Fable 24/11: the live run sends exactly one message, and its text is this sentence. The dedupe row is
// the SAME text on purpose - a different text would be a second job (and a second message), not a dedupe.
const REAL_TEXT = "wa acceptance test - ignore";
check(script.includes(JSON.stringify(REAL_TEXT)), "the script carries the one real message text verbatim", REAL_TEXT);
const textUses = (script.match(/FIXTURE\.text/g) || []).length;
check(textUses >= 2, "both the send and the dedupe step take the text from the one constant", String(textUses));
const fixtureBlock = script.split("const FIXTURE = {")[1].split("};")[0];
const textLines = [...fixtureBlock.matchAll(/text: "([^"]*)"/g)].map((match) => match[1]);
check(textLines.length === 1 && textLines[0] === REAL_TEXT,
  "the only message text in the fixtures is the sentence Fable named", textLines.join(" | "));

if (problems.length) {
  console.error("test-whatsapp-acceptance: FAIL (" + problems.length + " of " + checks + ")");
  for (const problem of problems) console.error("  - " + problem);
  process.exit(1);
}
console.log("test-whatsapp-acceptance: ok (" + checks + " checks, including: every surface verb is a row, live mode refuses a missing or malformed target and is default-deny for a step with no chat, the own-chat guard runs before the call, the driver redacts, the one real message text is the sentence Fable named, and a run in the node home refuses)");
