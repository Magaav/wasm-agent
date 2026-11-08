// The window's half of the long-call row: `⟳ <tool> · <elapsed>` plus what the running operation's
// output says, on the session-status-content row above the status bar (docs/TOOL-PROGRESS.md).
//
//   node tests/tool-progress.js
//
// The functions are read out of the shipping `ui/app.js` (not re-implemented) and run against a stub
// DOM and a clock the test controls, so this fails when the source drifts rather than when a copy of it
// does. What is pinned: the row's exact wording (the same strings the Rust crate and the Lua module
// assert, so the terminal and the window cannot disagree), each progress dialect, the two-second gate,
// the three-minute stall hint, the row's precedence against the update notice, that a secret never
// reaches it, and that the CSS gives the call's row its own colour.
const fs = require("fs");
let failures = 0;
const check = (condition, label) => {
  console.log((condition ? "ok   " : "FAIL ") + label);
  if (!condition) failures++;
};

const source = fs.readFileSync("ui/app.js", "utf8");
const css = fs.readFileSync("ui/style.css", "utf8");
const lua = fs.readFileSync("lua/core/tool_progress.lua", "utf8");
const rust = fs.readFileSync("rust/wa-tool-progress/src/lib.rs", "utf8");
const doc = fs.readFileSync("docs/TOOL-PROGRESS.md", "utf8");

// ---- the source is the source of truth ------------------------------------
for (const name of ["toolClock", "toolCompact", "toolBar", "toolProgressDialect", "toolProgressDetail", "toolRowDetail", "toolRowText",
  "toolScrub", "paintToolProgress", "clearToolProgress", "paintSessionContent", "paintSessionNotice"]) {
  check(new RegExp("function " + name + "\\(").test(source), "app.js defines " + name);
}
check(/const TOOL_STALL_SECONDS = 180;/.test(source), "the stall threshold is named once");
check(/const TOOL_BAR_CELLS = 14;/.test(source), "the bar's width is the build loader's");
check(/const TOOL_MIN_SECONDS = 2;/.test(source), "a call under two seconds has no row");
check(/const TOOL_RECENT = 4;/.test(source), "a finished build's bar is not allowed to speak for four lines");
check(/if \(standing\) return paintSessionNotice\(standing\);/.test(source),
  "the notice and `updating…` still win the row");
check(/\.session-status-content\.session-status-tool \{/.test(css), "the call's row has its own colour");
check(/\.session-status-content\.session-status-stall \{/.test(css), "and the stall hint a dimmer one");
check(/session-status-tool/.test(source), "the painter applies the tool class");
check(/void refreshOperationProgress\(health,threadOfRun\(health,ownId\)\)/.test(source),
  "the row is fed by the /health + /operation poll that already runs during a call");

// ---- the same sentence in all three renderers ------------------------------
// One rule, three renderers: the glyphs and the two clocks are asserted here against the Rust and Lua
// sources, so a change to one of them fails here rather than showing two sentences for one call.
check(/pub const STALL_SECONDS: f64 = 180\.0;/.test(rust), "Rust: the stall threshold is 180 s");
check(/pub const BAR: usize = 14;/.test(rust), "Rust: the bar is 14 cells");
check(/pub const MIN_SECONDS: f64 = 2\.0;/.test(rust), "Rust: the two-second gate");
check(/M\.STALL_SECONDS = 180/.test(lua) && /M\.BAR = 14/.test(lua) && /M\.MIN_SECONDS = 2/.test(lua),
  "Lua: the same three constants");
check(/no output for/.test(rust) && /no output for/.test(lua) && /no output for/.test(source),
  "the stall hint is one sentence in all three");
check(/\\u\{27F3\}/.test(lua) && /\\u27F3/.test(source), "the loader's glyph, not a second one");
check(doc.includes("no output for"), "docs/TOOL-PROGRESS.md documents the row's parts");

// ---- run the real functions against a stub DOM ----------------------------
// A brace matcher, not a regex: these functions contain nested callbacks, and a `\n}` match would cut
// one of them in half and test a truncated copy.
function extract(name) {
  const start = source.indexOf("function " + name + "(");
  check(start >= 0, "found " + name + " in app.js");
  let depth = 0, started = false, inString = null, inComment = false;
  for (let i = start; i < source.length; i++) {
    const ch = source[i];
    if (inComment) { if (ch === "\n") inComment = false; continue; }
    if (inString) {
      if (ch === "\\") { i++; continue; }
      if (ch === inString) inString = null;
      continue;
    }
    if (ch === "/" && source[i + 1] === "/") { inComment = true; i++; continue; }
    if (ch === '"' || ch === "'" || ch === "`") { inString = ch; continue; }
    if (ch === "{") { depth++; started = true; continue; }
    if (ch === "}") {
      depth--;
      if (started && depth === 0) return source.slice(start, i + 1);
    }
  }
  throw new Error("unbalanced function " + name);
}

class El {
  constructor(tag = "div") {
    this.tagName = String(tag).toUpperCase();
    this.children = [];
    this.dataset = {};
    this.attributes = {};
    this.className = "";
    this.textContent = "";
    this.parent = null;
  }
  append(...nodes) { for (const node of nodes) { node.parent = this; this.children.push(node); } }
  insertBefore(node, reference) {
    node.parent = this;
    const at = reference ? this.children.indexOf(reference) : -1;
    if (at >= 0) this.children.splice(at, 0, node); else this.children.push(node);
    return node;
  }
  remove() { if (this.parent) this.parent.children = this.parent.children.filter((c) => c !== this); this.parent = null; }
  setAttribute(key, value) { this.attributes[key] = String(value); }
  querySelector(selector) {
    if (selector === ".composer-footer") return this.children.find((c) => c.className === "composer-footer") || null;
    return null;
  }
}

const composerFooter = new El("div");
composerFooter.className = "composer-footer";
const composer = new El("form");
composer.className = "composer";
composer.append(composerFooter);
const body = new El("body");
const documentStub = {
  body,
  createElement: (tag) => new El(tag),
  querySelector: (selector) => {
    if (selector === ".composer") return composer;
    if (selector === "[data-session-status-content]") {
      return composer.children.find((c) => c.dataset && c.dataset.sessionStatusContent) || null;
    }
    return null;
  },
};

// A clock the test drives: the extracted functions call `Date.now()`, and this shadows the global.
const clock = { now: 1_000_000 };
const FakeDate = { now: () => clock.now };

const constants = (source.match(/const TOOL_(BAR_CELLS|STALL_SECONDS|MIN_SECONDS|RECENT) = [^;]+;/g) || []).join("\n");
const sandbox = new Function("document", "Date", `
${constants}
let toolRow = null;
let sessionStandingNotice = "";
let sessionUpdating = "";
${extract("toolClock")}
${extract("toolCompact")}
${extract("toolBar")}
${extract("toolScrub")}
${extract("toolProgressDialect")}
${extract("toolProgressDetail")}
${extract("toolRowDetail")}
${extract("toolRowText")}
${extract("paintSessionNotice")}
${extract("paintSessionContent")}
${extract("paintToolProgress")}
${extract("clearToolProgress")}
function setCall(tool, startedAt, lastLine, lastChangeAt, bytes, history) {
  toolRow = { operationId: "op-1", tool, startedAt, lastLine, outputBytes: bytes || 0,
    history: history || (lastLine ? [lastLine] : []),
    lastChangeAt: lastChangeAt == null ? startedAt : lastChangeAt };
}
function setNotice(text) { sessionStandingNotice = text; }
function setUpdating(on) { sessionUpdating = on ? "updating…" : ""; }
return { toolClock, toolCompact, toolBar, toolScrub, toolProgressDialect, toolProgressDetail, toolRowDetail, toolRowText, paintToolProgress,
  clearToolProgress, paintSessionContent, paintSessionNotice, setCall, setNotice, setUpdating,
  hasRow: () => !!toolRow };
`)(documentStub, FakeDate);

const row = () => documentStub.querySelector("[data-session-status-content]");
const BAR = (fraction) => {
  const filled = Math.round(Math.min(1, Math.max(0, fraction)) * 14);
  return "\u2595" + "\u2588".repeat(filled) + "\u2591".repeat(14 - filled) + "\u258F";
};

// ---- the clock, the bar, and the dialects ---------------------------------
check(sandbox.toolClock(45) === "45s", "a short clock is seconds");
check(sandbox.toolClock(125) === "2m05s", "a long one is minutes and seconds");
check(sandbox.toolClock(3720) === "1h02m", "a very long one is hours and minutes");
check(sandbox.toolCompact(180) === "3m", "the stall hint drops a zero seconds part");
check(sandbox.toolCompact(200) === "3m20s", "and keeps the seconds when they matter");
check(sandbox.toolBar(0) === BAR(0) && sandbox.toolBar(1) === BAR(1), "the bar is the build loader's shape");
check(sandbox.toolBar(2) === BAR(1), "a fraction past one is clamped");

const cargo = sandbox.toolProgressDetail("    Building [=============>         ] 143/412: serde_json, syn, proc-macro2");
check(cargo && cargo.kind === "bar" && cargo.done === 143 && cargo.total === 412, "cargo's Building line is a bar");
check(cargo && cargo.label === "building serde_json", "labelled with the first crate it names");
check(sandbox.toolProgressDetail("   Compiling wasmtime v50.0.0").text === "compiling wasmtime", "a bare Compiling line is text");
check(sandbox.toolProgressDetail("Progress: resolved 143, reused 120, downloaded 23, added 0").text === "resolved 143 packages",
  "pnpm's Progress line is its own dialect");
const pip = sandbox.toolProgressDetail("  45%|\u2588\u2588\u2588\u2588\u258c      | 45.0/100.0 [00:03<00:04, 12.3MB/s]");
check(pip && pip.kind === "bar" && pip.done === 45 && pip.total === 100, "pip's bar is 45 of 100, not 0 of 100");
const git = sandbox.toolProgressDetail("Receiving objects:  45% (450/1000), 1.20 MiB | 2.00 MiB/s");
check(git && git.kind === "bar" && git.done === 450 && git.total === 1000 && git.label === "receiving objects",
  "git's Receiving objects is a bar with its count");
check(sandbox.toolProgressDetail("Cloning into 'wasm-agent'...").text === "cloning into 'wasm-agent'...", "a clone says so");
check(sandbox.toolProgressDetail("test result: ok. 41 passed").text === "test result: ok. 41 passed",
  "no dialect: the last line is the answer");
check(sandbox.toolProgressDetail("") === null, "no output at all: no detail");
check(sandbox.toolProgressDetail("\u001b[32mCompiling\u001b[0m serde").text === "compiling serde",
  "an ANSI sequence never reaches the row");

// ---- the row's wording -----------------------------------------------------
check(sandbox.toolRowText("bash", 190, cargo, 1) === "\u27F3 bash \u00B7 3m10s " + BAR(143 / 412) +
  " 143/412 building serde_json", "a bar row: the tool, the clock, the bar, the count, the label");
check(sandbox.toolRowText("bash", 41, { kind: "text", text: "test result: ok. 41 passed" }, 0) ===
  "\u27F3 bash \u00B7 41s \u00B7 test result: ok. 41 passed", "a text row: the last line");
check(sandbox.toolRowText("bash", 260, { kind: "text", text: "compiling x" }, 180) ===
  "\u27F3 bash \u00B7 4m20s \u00B7 no output for 3m", "a stalled row is the hint, not the detail");
check(sandbox.toolRowText("bash", 12, null, 0) === "\u27F3 bash \u00B7 12s", "no detail: the tool and the clock only");

// A finished build's bar does not speak for the test run that follows it (`wa-tool-progress`'s RECENT).
const history = [
  "    Building [=============>         ] 143/412: serde_json, syn",
  "     Running unittests src/lib.rs",
  "running 41 tests",
  "test a::one ... ok",
  "test result: ok. 41 passed; 0 failed; 0 ignored",
];
check(sandbox.toolRowDetail({ history, lastLine: history[4] }).text === "test result: ok. 41 passed; 0 failed; 0 ignored",
  "four ordinary lines after a bar: the last line is the row");
check(sandbox.toolRowDetail({ history: history.slice(0, 3), lastLine: history[2] }).kind === "bar",
  "and one line after it, the bar is still the row");

// ---- no secret reaches the row --------------------------------------------
const scrubbed = sandbox.toolScrub("curl -H 'authorization: Bearer sk-live-9f2a4c1d8b7e6f50' https://api");
check(!scrubbed.includes("sk-live-9f2a4c1d8b7e6f50"), "a key-shaped value is masked: " + scrubbed);
check(/Bearer\s+(<redacted>|sk-\.\.\.)/.test(scrubbed), "and the Bearer token is gone too: " + scrubbed);
check(!sandbox.toolScrub("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc123signature").includes("eyJhbGciOiJIUzI1NiJ9"),
  "a JWT is masked");
check(sandbox.toolScrub("exit 0") === "exit 0", "ordinary output is untouched");

// ---- the row, on the page --------------------------------------------------
sandbox.setCall("bash", clock.now - 190_000, "    Building [=============>         ] 143/412: serde_json, syn", clock.now - 1_000, 4096);
sandbox.paintToolProgress();
check(!!row(), "a call past two seconds takes the row");
check(row().textContent === "\u27F3 bash \u00B7 3m10s " + BAR(143 / 412) + " 143/412 building serde_json",
  "with the sentence above: " + (row() && row().textContent));
check(row().className === "session-status-content session-status-tool", "in the loader's colour, not the notice's yellow");
check(row().dataset.sessionStatusContent === "tool", "marked as the call's row");
check(row().parent === composer && composer.children.filter((c) => /session-status-content/.test(c.className)).length === 1,
  "one row, directly above the status bar, never a second copy");

// A young call is the status line's business.
sandbox.setCall("bash", clock.now - 1_000, "Compiling x", clock.now - 1_000, 10);
sandbox.paintToolProgress();
check(row() === null, "a call under two seconds leaves the row to the status line");

// The stall hint, dim, after three minutes of silence.
sandbox.setCall("bash", clock.now - 260_000, "Compiling x", clock.now - 180_000, 10);
sandbox.paintToolProgress();
check(row().textContent === "\u27F3 bash \u00B7 4m20s \u00B7 no output for 3m", "three minutes of silence says so: " + row().textContent);
check(row().className === "session-status-content session-status-stall", "and it is the dim one");

// The notice wins, and gives the row back.
sandbox.setUpdating(true);
sandbox.paintToolProgress();
check(row().textContent === "updating…", "`updating…` wins the row while the node is away");
sandbox.setUpdating(false);
sandbox.setNotice("Update available (cccccccccccc): run wa update or /update");
sandbox.paintToolProgress();
check(row().textContent === "Update available (cccccccccccc): run wa update or /update",
  "the standing notice outranks the call");
check(row().className === "session-status-content", "and paints it as the notice");
sandbox.setNotice("");
sandbox.paintToolProgress();
check(/no output for 3m/.test(row().textContent), "with the notice gone the call has the row back");

// The call ends: the row goes, and there is no blank gap.
sandbox.clearToolProgress();
check(row() === null, "the call ends: no row, no blank gap above the status bar");
check(!sandbox.hasRow(), "and nothing is left to paint");

console.log(failures === 0 ? "tool-progress: all checks passed" : `tool-progress: ${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
