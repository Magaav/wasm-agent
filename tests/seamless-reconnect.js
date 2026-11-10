// The window's half of the seamless update: the session-status-content row says `updating…` while the
// node is away being replaced, and clears on the recovery edge; the transcript comes back by itself.
//
//   node tests/seamless-reconnect.js
//
// The functions are read out of the shipping `ui/app.js` (not re-implemented) and run against a stub DOM
// that implements exactly what they touch, so this fails when the source drifts rather than when a copy of
// it does. The cross-language check at the end reads `lua/core/cli_restart.lua` so the CLI and the window
// cannot disagree about the sentence.
const fs = require("fs");
let failures = 0;
const check = (condition, label) => {
  console.log((condition ? "ok   " : "FAIL ") + label);
  if (!condition) failures++;
};

const source = fs.readFileSync("ui/app.js", "utf8");
const css = fs.readFileSync("ui/style.css", "utf8");
const lua = fs.readFileSync("lua/core/cli_restart.lua", "utf8");
const doc = fs.readFileSync("docs/RELEASE-UPDATE.md", "utf8");

// ---- the source is the source of truth ------------------------------------
check(/const UPDATING_TEXT = "updating…";/.test(source), "app.js pins the sentence `updating…` once");
check(/function paintSessionContent\(\) \{/.test(source), "app.js defines paintSessionContent");
check(/function paintUpdating\(on\) \{/.test(source), "app.js defines paintUpdating");
check(/const standing = sessionUpdating \|\| sessionStandingNotice;/.test(source)
  && /if \(standing\) return paintSessionNotice\(standing\);/.test(source),
  "one resolver: `updating…` replaces the standing notice on the same row (and both outrank a tool call)");
check(/if \(upgradeState\) paintUpdating\(true\);/.test(source),
  "the line appears when the node stops answering during a known install");
const recovery = source.slice(source.indexOf("function clearNodeRestartStatus()"));
check(/function clearNodeRestartStatus\(\)[\s\S]{0,900}?paintUpdating\(false\)/.test(source),
  "and is cleared on the one recovery path, not on a timer of its own");
check(!/setInterval\([^)]*paintUpdating/.test(source), "there is no second retry loop for it");
check(/sessionStandingNotice = text;/.test(source), "the banner feeds the standing half of the row");
check(/\.session-status-content \{/.test(css), "the row keeps its own style (the CLI's rule)");

// ---- run the real functions against a stub DOM ----------------------------
// A brace matcher, not a regex: these functions contain nested callbacks, and a `\n}` match would cut one
// of them in half and test a truncated copy.
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
    this.listeners = {};
    this.classList = {
      _set: new Set(),
      add: (name) => this.classList._set.add(name),
      remove: (name) => this.classList._set.delete(name),
      toggle: (name, on) => { if (on) this.classList._set.add(name); else this.classList._set.delete(name); },
      contains: (name) => this.classList._set.has(name),
    };
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
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  querySelector(selector) {
    if (selector === ".composer-footer") return this.children.find((c) => c.className === "composer-footer") || null;
    return null;
  }
}

const body = new El("body");
const topbar = new El("div");
const composerFooter = new El("div");
composerFooter.className = "composer-footer";
const composer = new El("form");
composer.className = "composer";
composer.append(composerFooter);
const documentStub = {
  body,
  documentElement: new El("html"),
  createElement: (tag) => new El(tag),
  getElementById: (id) => (id === "dragbar" ? topbar : null),
  querySelector: (selector) => {
    if (selector === "#dragbar .topbar-actions") return topbar;
    if (selector === ".composer") return composer;
    if (selector === "[data-session-status-content]") {
      return composer.children.find((c) => c.dataset && c.dataset.sessionStatusContent) || null;
    }
    if (selector === "[data-update-badge]") {
      return topbar.children.find((c) => c.dataset && c.dataset.updateBadge) || null;
    }
    return null;
  },
};

// The constant is taken from the shipping source, not retyped: if app.js renames or re-words it, the
// `check` above fails and this preamble would silently pass a different sentence.
const updatingConst = (source.match(/const UPDATING_TEXT = [^;]+;/) || [""])[0];
const sandbox = new Function("document", `
let sessionStandingNotice = "";
let sessionUpdating = "";
// The row's third claimant (docs/TOOL-PROGRESS.md): a long tool call, the lowest of the three. Null
// here because this test is about the node's half; tests/tool-progress.js covers the call's.
let toolRow = null;
${updatingConst}
let nodeWatch = null;
// The status bar's own line, as the node-offline path leaves it: the recovery edge must clear it too.
let statusLine = { textContent: "the node is restarting to install a new build - it will answer again shortly" };
let statusCleared = 0;
function clearStatus() { statusCleared += 1; }
${extract("updateBannerText")}
${extract("paintUpdateBadge")}
${extract("paintSessionNotice")}
${extract("paintSessionContent")}
${extract("paintUpdating")}
${extract("applyUpdateBanner")}
${extract("clearNodeRestartStatus")}
return {
  applyUpdateBanner, paintUpdating, paintSessionContent, paintSessionNotice, clearNodeRestartStatus,
  updating: () => sessionUpdating,
  standing: () => sessionStandingNotice,
  statusCleared: () => statusCleared,
};
`)(documentStub);

const row = () => documentStub.querySelector("[data-session-status-content]");
const BEHIND = {
  banner: {
    state: "behind",
    line: "Update available (cccccccccccc): run wa update or /update",
    latest: { tag: "node-cccccccccccc", sha12: "cccccccccccc" },
  },
};

// ---- a node that is behind: the standing notice, as before ------------------
const notice = sandbox.applyUpdateBanner(BEHIND);
check(sandbox.standing() === notice, "the banner's sentence is the standing text of the row");
check(!!row() && row().textContent === notice, "and it is what the row shows");

// ---- the install: the node goes away, the row says `updating…` --------------
sandbox.paintUpdating(true);
check(sandbox.updating() === "updating…", "the row says `updating…` while the node is away for an install");
check(row().textContent === "updating…", "one line, the same row: `updating…` and nothing else");
check(sandbox.standing() === notice, "the standing notice is remembered, not thrown away");
check(row().className === "session-status-content", "it is still the session-status-content row, not a toast");
check(row().parent === composer, "still directly above the status bar, inside the composer");
check(composer.children.filter((c) => c.className === "session-status-content").length === 1,
  "one row, never a second copy of it");
check(body.classList.contains("node-updating"), "the page is marked as updating");
// Idempotent: two failed polls are one line, not two.
sandbox.paintUpdating(true);
check(composer.children.filter((c) => c.className === "session-status-content").length === 1,
  "a second failed poll does not add a second row");

// ---- the node answers again: the line clears, the notice comes back ---------
sandbox.clearNodeRestartStatus();
check(sandbox.updating() === "", "the answer clears `updating…`");
check(!body.classList.contains("node-updating"), "and the page is no longer marked as updating");
check(row().textContent === notice, "the standing notice is back on the same row");
check(sandbox.statusCleared() > 0, "the stale restart/offline claim is cleared on the same edge");

// ---- nothing standing: the row goes away entirely --------------------------
sandbox.applyUpdateBanner({ banner: { state: "current" } });
sandbox.paintUpdating(true);
check(row().textContent === "updating…", "an update with nothing standing still says `updating…`");
sandbox.clearNodeRestartStatus();
check(row() === null, "and when it clears there is no blank row left above the status bar");

// ---- the sentence is one sentence, in three places -------------------------
check(/M\.UPDATING = "updating…"/.test(lua), "the CLI's module pins the same sentence");
check(/M\.UPDATING = "updating…"/.test(lua) && /const UPDATING_TEXT = "updating…";/.test(source),
  "the CLI and the window cannot disagree about what the row says");
check(doc.includes("`updating…`"), "docs/RELEASE-UPDATE.md documents the line");
check(/kind = "notice"/.test(lua), "the CLI draws it as the notice kind, the kind both renderers paint");

console.log(failures === 0 ? "seamless-reconnect: all checks passed" : `seamless-reconnect: ${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
