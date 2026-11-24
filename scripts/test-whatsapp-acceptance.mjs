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
check(script.includes("FIXTURE.foreign_chat"), "the guard row uses a fixture target, never a real one");
check(/000000000000000@s\.whatsapp\.net/.test(script), "the fixture target is a chat no account can own");

// ---- 4. redaction: a JID rule and a digits rule, before anything is printed ---------------------------------
check(driver.includes("@([%w%.%-]+)"), "the driver redacts an email/JID");
check(driver.includes('("%d"):rep(5)'), "the driver redacts a run of five or more digits (a phone number)");
check(driver.includes("redact(value)"), "every allow-listed field passes through the redaction");
check(!/record\.fields\.chat\b/.test(driver) && !/record\.fields\.text\b/.test(driver),
  "the driver never reports a chat or a message body as a field");
check(script.includes("function scrub("), "the script re-checks every value before printing it");

// ---- 5. the scratch-home guard ---------------------------------------------------------------
check(script.includes("refusing to run"), "a run that would write in the node home refuses");
check(script.includes("REAL_HOME"), "the refusal is about the operator's own node home");

if (problems.length) {
  console.error("test-whatsapp-acceptance: FAIL (" + problems.length + " of " + checks + ")");
  for (const problem of problems) console.error("  - " + problem);
  process.exit(1);
}
console.log("test-whatsapp-acceptance: ok (" + checks + " checks: every surface verb is a row, live mode refuses a missing or malformed target, the own-chat guard runs before the call, the driver redacts, and a run in the node home refuses)");
