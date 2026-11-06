// The window's half of the update banner: the dismissible toast, the standing badge, and the one
// sentence the CLI footer prints too.
//
//   node tests/update-banner.js
//
// The functions are read out of the shipping `ui/app.js` (not re-implemented) and run against a stub
// DOM that implements exactly what they touch, so this fails when the source drifts rather than when a
// copy of it does. Three things are pinned: the text comes from the node (`banner.line`) and falls back
// to the same wording when a node is too old to send it; the banner is a toast + badge and never a row
// in the transcript; dismissing hides the toast and leaves the badge, which acts. The cross-language
// check at the end reads `lua/core/update_banner.lua` so the two surfaces cannot disagree about the
// sentence.
const fs = require("fs");
let failures = 0;
const check = (condition, label) => {
  console.log((condition ? "ok   " : "FAIL ") + label);
  if (!condition) failures++;
};

const source = fs.readFileSync("ui/app.js", "utf8");
const css = fs.readFileSync("ui/style.css", "utf8");
const lua = fs.readFileSync("lua/core/update_banner.lua", "utf8");

// ---- the source is the source of truth ------------------------------------
check(/function updateBannerText\(payload\)/.test(source), "app.js defines updateBannerText");
check(/function applyUpdateBanner\(payload\)/.test(source), "app.js defines applyUpdateBanner");
check(/async function showUpdateBanner\(\)/.test(source), "app.js defines showUpdateBanner");
check(/setTimeout\(\(\) => \{ void showUpdateBanner\(\); \}, 1200\)/.test(source),
  "the banner check runs after the first paint, once per load");
check(/body: JSON\.stringify\(\{ check: true \}\)/.test(source),
  "the check uses the read-only /update {check:true} route");
check(!/showReleaseBanner/.test(source), "the old transcript banner is gone");
check(!/messages\.append\(banner\)/.test(source), "no update banner is appended to the transcript");
check(/data-update-badge|dataset\.updateBadge/.test(source), "the badge is marked for lookup");
check(/data-update-toast|dataset\.updateToast/.test(source), "the toast is marked for lookup");
check(/dismissUpdateToast/.test(source), "the toast has a dismiss path");
check(/\.update-toast \{/.test(css), "the toast has its own style");
check(/\.update-badge \{/.test(css), "the badge has its own style");

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
    this.listeners = {};
    this.removed = false;
  }
  append(...nodes) { for (const node of nodes) { node.parent = this; this.children.push(node); } }
  insertBefore(node, reference) {
    node.parent = this;
    const at = reference ? this.children.indexOf(reference) : -1;
    if (at >= 0) this.children.splice(at, 0, node); else this.children.push(node);
    return node;
  }
  remove() { this.removed = true; if (this.parent) this.parent.children = this.parent.children.filter((c) => c !== this); }
  setAttribute(key, value) { this.attributes[key] = String(value); }
  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }
  fire(type, event = {}) { for (const fn of this.listeners[type] || []) fn(event); }
  querySelector(selector) {
    if (selector === ".composer-footer") return this.children.find((c) => c.className === "composer-footer") || null;
    return null;
  }
}

const body = new El("body");
const topbar = new El("div");
// The composer form: `session-status-content` is inserted above its footer (this page's status bar).
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
    if (selector === "[data-update-toast]") {
      return body.children.find((c) => c.dataset && c.dataset.updateToast) || null;
    }
    return null;
  },
};

let updatesAsked = 0;
const sandbox = new Function("document", "updateNode", `
let updateToastDismissed = false;
${extract("updateBannerText")}
${extract("dismissUpdateToast")}
${extract("paintUpdateBadge")}
${extract("paintUpdateToast")}
${extract("paintSessionNotice")}
${extract("applyUpdateBanner")}
return {
  updateBannerText,
  applyUpdateBanner,
  dismissUpdateToast,
  paintSessionNotice,
  toastDismissed: () => updateToastDismissed,
};
`)(documentStub, () => { updatesAsked += 1; });

const badge = () => documentStub.querySelector("[data-update-badge]");
const toast = () => documentStub.querySelector("[data-update-toast]");
const behind = {
  banner: {
    state: "behind",
    line: "Update available (cccccccccccc): run wa update or /update",
    latest: { tag: "node-cccccccccccc", sha12: "cccccccccccc" },
  },
};

// ---- behind: both surfaces, one sentence ---------------------------------
const drawn = sandbox.applyUpdateBanner(behind);
check(drawn === "Update available (cccccccccccc): run wa update or /update", "the node's line is drawn verbatim");
check(!!badge(), "a badge is added to the topbar");
check(badge().title === drawn, "the badge carries the full sentence as its title");
check(badge().attributes["aria-label"] === drawn, "the badge is described for a screen reader");
check(badge().dataset.updateBadge === "available", "the badge is marked as an available update");
check(!!toast(), "a toast is added");
check(toast().textContent === drawn, "the toast carries the sentence");
check(toast().className === "update-toast", "the toast has its own class, not a transcript notice");
check(toast().attributes.role === "status" && toast().attributes["aria-live"] === "polite",
  "the toast is announced politely rather than stealing focus");
check(body.children.includes(toast()), "the toast lives on the page body, not in the transcript");

// ---- session-status-content: the notice's own line above the status bar ----------------
// The composer footer is this page's status bar; the notice gets ONE line directly above it, in the
// same yellow as the CLI's, and the footer keeps its own controls where they were.
const noticeRow = () => documentStub.querySelector("[data-session-status-content]");
check(!!noticeRow(), "a session-status-content line is drawn above the status bar");
check(noticeRow().className === "session-status-content", "with its own class, not the status bar's");
check(noticeRow().textContent === drawn, "carrying the node's sentence, unchanged");
check(noticeRow().attributes.role === "status" && noticeRow().attributes["aria-live"] === "polite",
  "announced politely rather than stealing focus");
check(noticeRow().parent === composer, "it lives in the composer, beside the status bar");
check(composer.children.indexOf(noticeRow()) === composer.children.indexOf(composer.children.find((c) => c.className === "composer-footer")) - 1,
  "directly above the composer footer: the status bar's own row is untouched");
check(composer.children.filter((c) => c.className === "composer-footer").length === 1,
  "the status bar is still one row, not a second copy of it");
check(/\.session-status-content \{/.test(css), "the line has its own style");
check(/\.session-status-content \{[^}]*color: var\(--warn\)/.test(css), "it is yellow, the stylesheet's warning colour");
check(/\.session-status-content \{[^}]*white-space: nowrap/.test(css), "and never wraps");
check(/\.session-status-content \{[^}]*text-overflow: ellipsis/.test(css),
  "a narrow window truncates it with an ellipsis (width 40 included)");
// A node with no `.composer` in the document is not an error: the badge and the toast still draw.
const bareDocument = { ...documentStub, querySelector: (selector) => (selector === ".composer" || selector === "[data-session-status-content]" ? null : documentStub.querySelector(selector)) };
const bare = new Function("document", `${extract("paintSessionNotice")} return paintSessionNotice;`)(bareDocument);
check(bare("Update available") === null, "a page with no composer draws no line rather than failing");

check(noticeRow().textContent === drawn, "the line carries the same sentence as the toast and the badge");

// Dismissing removes the toast and keeps the standing badge; a later draw does not resurrect it.
const close = toast().children.find((c) => c.className === "update-toast-close");
check(!!close, "the toast has a dismiss button");
check(close.attributes["aria-label"] === "Dismiss the update notice", "the dismiss button is described");
close.fire("click");
check(toast() === null, "dismissing removes the toast");
check(!!badge(), "the badge stays after the toast is dismissed");
check(sandbox.toastDismissed() === true, "the dismissal is remembered");
sandbox.applyUpdateBanner(behind);
check(toast() === null, "a second draw does not bring a dismissed toast back");

// The badge acts: the same request `/update` makes.
sandbox.applyUpdateBanner(behind);
badge().fire("click");
check(updatesAsked === 1, "clicking the badge asks the node to update");

// ---- a node too old to send a line: same sentence, built here ------------
const rebuilt = sandbox.updateBannerText({ banner: { state: "behind", latest: { sha12: "abc123456789" } } });
check(rebuilt === "Update available (abc123456789): run wa update or /update",
  "without banner.line the window builds exactly the same sentence");
check(sandbox.updateBannerText({ banner: { state: "behind" } }) === "Update available: run wa update or /update",
  "and a node that names no commit still gets an actionable sentence");

// ---- current / ahead / unknown / no answer: nothing is drawn -------------
for (const state of ["current", "ahead", "unknown"]) {
  check(sandbox.updateBannerText({ banner: { state, line: "must not be used" } }) === "",
    state + " draws nothing");
}
check(sandbox.updateBannerText(null) === "", "no answer draws nothing");
check(sandbox.updateBannerText({}) === "", "an empty answer draws nothing");
check(sandbox.updateBannerText({ banner: { state: "behind" }, release: { state: "behind", message: "tag" } }).includes("abc") === false,
  "a banner answer is never mixed with the tag-based wording");
check(sandbox.updateBannerText({ release: { state: "behind", message: "installed v0.1.0 is behind v0.2.0" } }) ===
  "Update available — installed v0.1.0 is behind v0.2.0. Run /update to install it.",
  "a node with no commit banner keeps the old tag wording");
check(sandbox.updateBannerText({ release: { state: "current", message: "current" } }) === "",
  "and a current tag draws nothing");

// ---- the indicator disappears once the node runs that version -----------
sandbox.applyUpdateBanner({ banner: { state: "current" } });
check(badge() === null, "a current node clears the badge on the next load");
check(toast() === null, "and any toast is gone");
check(noticeRow() === null, "and the session-status-content line goes: no empty row above the status bar");

// ---- one sentence, two languages ---------------------------------------
const format = (lua.match(/M\.LINE = "([^"]+)"/) || [])[1];
check(format === "Update available (%s): run wa update or /update",
  "lua/core/update_banner.lua declares the sentence once (" + String(format) + ")");
const fromLua = String(format).replace("%s", "cccccccccccc");
check(fromLua === drawn, "the Lua and the window produce the same sentence for the same commit");
const cli = fs.readFileSync("lua/core/chat.lua", "utf8") + fs.readFileSync("lua/core/cli_view.lua", "utf8");
check(/session_notice/.test(cli), "the CLI keeps the sentence for session-status-content");
check(/function METHODS:session_draw\(\)/.test(cli), "and has one place that draws that line");
check(/banner\.check\(\{ refresh = true \}\)/.test(cli), "the CLI asks at session start");
check(!/print\(.*session_notice/.test(cli) || /seen\.line/.test(cli), "the CLI prints the node's line once, at start");

console.log("---");
console.log(failures === 0 ? "ALL PASS" : failures + " FAILURE(S)");
process.exit(failures === 0 ? 0 : 1);
