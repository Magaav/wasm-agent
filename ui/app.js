// wasm-agent web UI. Components live in components.js (see DESIGN.md).
const messages = document.getElementById("messages");
const jump = document.getElementById("jump");
const meta = document.getElementById("meta");
const form = document.getElementById("composer");
const input = document.getElementById("input");
// The draft's undo/redo are keyboard-only since the diff topic took the only toggle in the
// transcript: the two footer buttons acted on the *draft* while looking like they acted on
// the conversation, and the transcript is where the reader looks for "undo the last thing".
// Ctrl+Z / Ctrl+Shift+Z still work, and they are the controls a text box is expected to have.
const panel = document.getElementById("panel");
const sendButton = document.getElementById("send");
const statusBtn = document.getElementById("status-btn");
const chipModel = document.getElementById("chip-model");
const chipUsage = document.getElementById("chip-usage");
const balloon = document.getElementById("status-balloon");
// Built here rather than in the markup: it lives in the account balloon now, and that balloon is
// drawn from JS. The id is stable, so everything that reads the selection keeps working.
const nodeSelect = document.createElement("select");
nodeSelect.id = "node-select";
nodeSelect.className = "wa-select";
const providerSelect = document.getElementById("provider-select");
const modelSelect = document.getElementById("model-select");
const reasoningSelect = document.getElementById("reasoning-select");
const harnessStatus = document.getElementById("harness-status");
const settingsError = document.getElementById("settings-error");
const contextBox = document.getElementById("context-box");
const limitsBox = document.getElementById("limits-box");
const usageBox = document.getElementById("usage-box");
const popFoot = document.getElementById("pop-foot");
const micButton = document.getElementById("mic");
const attachButton = document.getElementById("attach");
const fileInput = document.getElementById("file");
const attachmentsEl = document.getElementById("attachments");
const userBtn = document.getElementById("user-btn");
const userAvatar = document.getElementById("user-avatar");
const userMenu = document.getElementById("user-menu");
const contextMenu = document.getElementById("context-menu");
const terminal = document.getElementById("terminal");
const termBtn = document.getElementById("term-btn");
const termOut = document.getElementById("term-out");
const termForm = document.getElementById("term-form");
const termCmd = document.getElementById("term-cmd");
const termClose = document.getElementById("term-close");
const termTitle = document.getElementById("term-title");
const nodesBox = document.getElementById("nodes-box");
const nodesBinding = document.getElementById("nodes-binding");
const engineBtn = document.getElementById("engine-btn");
const engineView = document.getElementById("engine");
const engineClose = document.getElementById("engine-close");
const engineSub = document.getElementById("engine-sub");
const driftBtn = document.getElementById("diff-btn");
const driftView = document.getElementById("drift");
const driftClose = document.getElementById("drift-close");
const driftSub = document.getElementById("drift-sub");
const driftBody = document.getElementById("drift-body");
const driftRefresh = document.getElementById("drift-refresh");
const spellsBox = document.getElementById("spells-box");
const spellsNote = document.getElementById("spells-note");
const skillsBox = document.getElementById("skills-box");
const skillsNote = document.getElementById("skills-note");
const toolsBox = document.getElementById("tools-box");
const sessionsBox = document.getElementById("sessions-box");
const sessionsNote = document.getElementById("sessions-note");
const control = document.getElementById("control");
const controlTitle = document.getElementById("control-title");
const controlCanvas = document.getElementById("control-canvas");
// The view is what goes full size; the section is what is hidden when the control closes.
const controlView = document.getElementById("control-view");
const controlCtx = controlCanvas.getContext("2d");
const controlMax = document.getElementById("control-max");
const controlHint = document.getElementById("control-hint");
const controlLive = document.getElementById("control-live");
const controlRefresh = document.getElementById("control-refresh");
const controlClose = document.getElementById("control-close");
const controlKeys = document.getElementById("control-keys");
const controlText = document.getElementById("control-text");

let renderer = null;
let version = null;
let busy = false;
// Stop belongs to the request this window submitted. A conversation may have an older run
// executing while this request waits behind it, so cancellation must carry this request's id.
let activeRunId = null;
let submittedRunIds = null;
let statusLine = null;
let streamBody = null;
let streamText = "";
let controller = null;
let attachments = [];
let settings = { provider: "", model: "", providers: [], usage: {}, stats: {}, configured: false, base_url: "" };
let session = localStorage.getItem("wa-session") || "";
let me = { user: null, role: "guest", tools: [] };
let activeNode = localStorage.getItem("wa-node") || "";

// Which conversation this window is in, and the draft it was writing.
//
// The node owns the session; the window only remembers its id, and it learns that from the
// sessions list, because the chat route creates the session and never says which one it made. The
// draft is the reader's own text - attachments are deliberately not kept, since a picture
// silently reappearing in a composer is worse than one that does not come back.
const SESSION_KEY = "wa-chat-session";
const DRAFT_KEY = "wa-draft";
let chatSession = "";
try { chatSession = localStorage.getItem(SESSION_KEY) || ""; } catch (error) { chatSession = ""; }

function rememberSession(id) {
  if (!id || id === chatSession) return;
  chatSession = id;
  try { localStorage.setItem(SESSION_KEY, id); } catch (error) { /* private mode */ }
}

function saveDraft() {
  try { localStorage.setItem(DRAFT_KEY, input.value || ""); } catch (error) { /* private mode */ }
}

function clearDraft() {
  try { localStorage.removeItem(DRAFT_KEY); } catch (error) { /* nothing to clear */ }
}
let nodeList = [];

// Every request needs a deadline, and the recovery loop is why: it polls /version every
// second, and when the node was wedged one fetch that never resolved hung the loop
// forever - so the page sat on "connecting…" long after the node had recovered. A hung
// request must never be able to stop the retry. Requests that bring their own signal (the
// chat stream) pass through untouched: a run is legitimately long.
let apiTimeout = 8000;
function apiFetch(path, options = {}, timeout = apiTimeout) {
  if (!timeout || options.signal) return fetch(path, options);
  const control = new AbortController();
  const timer = setTimeout(() => control.abort(), timeout);
  return fetch(path, Object.assign({}, options, { signal: control.signal }))
    .finally(() => clearTimeout(timer));
}

function apiHeaders(extra) {
  const headers = Object.assign({}, extra || {});
  if (session) headers["X-WA-Session"] = session;
  if (activeNode) headers["X-WA-Node"] = activeNode;
  return headers;
}

// A run is *this window's* run only when it belongs to this window's conversation.
//
// This used to return the first chat run on the node, whichever conversation it belonged to. Once two
// conversations can run at once, that made a window watching conversation B see conversation A's run:
// it disabled its own composer, announced "a run is in progress", and deferred its own reconcile until
// a stranger's run finished. `/health` carries the conversation (`session`) on every worker and on
// `current`, so the match is exact. With no session known yet the window claims no run, which is the
// safe default - it has no transcript to reconcile.
function activeRun(health, session = chatSession) {
  const isChat = (entry) => /^POST \/chat(?:\?|$)/.test(entry?.label || "");
  const mine = (entry) => isChat(entry) && !!session && entry.session === session;
  return (health?.workers || []).find(mine) || (mine(health?.current) ? health.current : null);
}

function nodeQuery() {
  return activeNode ? "?node=" + encodeURIComponent(activeNode) : "";
}
let recognizing = false;
let recognition = null;
let voicePrefix = "";

async function loadRenderer() {
  try {
    const response = await apiFetch("render.wasm");
    const { instance } = await WebAssembly.instantiateStreaming(response, {});
    renderer = instance.exports;
  } catch (error) {
    // A silent fallback hides a broken asset: replies quietly lose tables,
    // headings and lists and just look plain. Keep the reason where a reader -
    // or the UI test - can see it.
    renderer = null;
    window.__rendererError = String((error && error.message) || error);
    console.warn("markdown renderer unavailable:", error);
  }
}

function escapeHtml(text) {
  return String(text).replace(/[&<>"']/g, (c) => (
    { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

// Every fenced block gets a copy control. The renderer emits "<pre><code>…</code></pre>"
// for a fence and a bare "<code>" for inline code, so the <pre>-wrapped one is exactly a
// fence; wrapping here, once, covers every place a reply is inserted.
const CODE_FENCE = /<pre><code>([\s\S]*?)<\/code><\/pre>/g;

function enhanceCodeBlocks(html) {
  return String(html).replace(CODE_FENCE, function (_match, code) {
    return '<div class="code-wrap">'
      + '<button class="copy-code" type="button" aria-label="Copy code" title="Copy code">Copy</button>'
      + '<pre><code>' + code + '</code></pre></div>';
  });
}

// Copy the code TEXT, not its markup: `innerText` reflects what the reader sees, with the
// entities decoded. The clipboard API needs a secure context, so fall back to the legacy
// selection copy where it is unavailable.
function copyText(text) {
  if (navigator.clipboard && navigator.clipboard.writeText) {
    return navigator.clipboard.writeText(text).catch(function () { return legacyCopy(text); });
  }
  return legacyCopy(text);
}

function legacyCopy(text) {
  return new Promise(function (resolve, reject) {
    const area = document.createElement("textarea");
    area.value = text;
    area.setAttribute("readonly", "");
    area.style.position = "fixed";
    area.style.top = "-1000px";
    document.body.appendChild(area);
    area.select();
    let ok = false;
    try { ok = document.execCommand("copy"); } catch (error) { ok = false; }
    document.body.removeChild(area);
    if (ok) resolve(); else reject(new Error("copy failed"));
  });
}

function acknowledgeCopy(button, failed) {
  button.textContent = failed ? "Copy failed" : "Copied";
  button.classList.toggle("copied", !failed);
  button.classList.toggle("copy-failed", !!failed);
  clearTimeout(button.__copyTimer);
  button.__copyTimer = setTimeout(function () {
    button.textContent = "Copy";
    button.classList.remove("copied", "copy-failed");
  }, 1200);
}

// Delegated: the button is built as HTML, so there is no per-block listener to wire.
document.addEventListener("click", function (event) {
  const button = event.target && event.target.closest ? event.target.closest(".copy-code") : null;
  if (!button) return;
  const wrap = button.closest(".code-wrap");
  const pre = wrap ? wrap.querySelector("pre") : null;
  if (!pre) return;
  event.preventDefault();
  copyText(pre.innerText).then(function () { acknowledgeCopy(button, false); },
                               function () { acknowledgeCopy(button, true); });
});

function renderMarkdown(text) {
  if (renderer && renderer.memory) {
    try {
      const bytes = new TextEncoder().encode(text);
      const pointer = renderer.alloc(bytes.length);
      new Uint8Array(renderer.memory.buffer, pointer, bytes.length).set(bytes);
      const packed = renderer.render(pointer, bytes.length);
      const outPointer = Number((packed >> 32n) & 0xffffffffn);
      const outLength = Number(packed & 0xffffffffn);
      return enhanceCodeBlocks(new TextDecoder().decode(new Uint8Array(renderer.memory.buffer, outPointer, outLength)));
    } catch (error) { /* fall through */ }
  }
  return escapeHtml(text).replace(/\n/g, "<br>");
}

// Some models leak their reasoning into the message; drop it.
//
// Both ends are trimmed, and the tail matters as much as the head: these texts are rendered in
// `white-space: pre-wrap` containers, so a trailing newline is a *blank line* on screen. A provider
// ends a chunk with them, and three of them read as three paragraphs of nothing between the thinking
// and the tool call that follows it. Interior breaks are content and are left alone.
function stripThinking(text) {
  let out = String(text)
    .replace(/[\s\S]*?<\/think>/gi, "")
    .replace(/<\/?think\b[^>]*>/gi, "");
  const open = out.search(/<think\b[^>]*>/i);
  if (open >= 0) out = out.slice(0, open);
  return out.replace(/^\s+/, "").replace(/\s+$/, "");
}

function atBottom(slack = 40) {
  return messages.scrollHeight - messages.scrollTop - messages.clientHeight < slack;
}

// Sticky scroll. "Follow the bottom" is the default, and it stops only when the
// reader moves away - so reading scrollback is not interrupted by new output,
// and returning to the bottom resumes following. `follow` is only changed by the
// reader's own scrolling: our programmatic pins set `pinning` first so the scroll
// event they cause cannot be mistaken for intent.
let follow = true;
let pinning = false;

function pin(force = false) {
  if (!follow && !force) return;
  pinning = true;
  messages.scrollTop = messages.scrollHeight;
  // Release on the next frame: the scroll event fires asynchronously.
  requestAnimationFrame(() => { pinning = false; });
}

function setFollow(value) {
  follow = value;
  jump.classList.toggle("show", !follow);
}

messages.addEventListener("scroll", () => {
  if (pinning) return;
  setFollow(atBottom());
}, { passive: true });

// The reader's intent, not just the scroll position: a wheel tick or a drag
// upwards should release the follow even before the bottom is out of view.
for (const event of ["wheel", "touchstart"]) {
  messages.addEventListener(event, () => setFollow(atBottom(4)), { passive: true });
}
messages.addEventListener("keydown", (event) => {
  if (["PageUp", "ArrowUp", "Home"].includes(event.key)) setFollow(false);
  if (["PageDown", "ArrowDown", "End"].includes(event.key)) setFollow(atBottom());
});

// Content can grow without an append (markdown re-render, a topic opening,
// images): re-pin whenever the scroll height changes, if we are following.
if (typeof ResizeObserver === "function") {
  new ResizeObserver(() => pin()).observe(messages);
}
jump.addEventListener("click", () => { setFollow(true); pin(true); });

// One assistant bubble per run. Decisions and their tool topics live *inside*
// it as stacked segments: separate bubbles put a border between every step,
// which reads as a divider between unrelated messages instead of one reply that
// thought, used tools, thought again, and answered. When the answer is ready the
// whole path collapses into a single run topic at the top of the bubble.
let runBubble = null;
let runStartedAt = 0;

function currentBubble() {
  if (!runBubble) {
    document.getElementById("empty")?.remove();
    runBubble = document.createElement("wa-message");
    runBubble.setAttribute("role", "assistant");
    messages.append(runBubble);   // connecting is what builds .body
    runBubble.body.classList.add("steps");
  }
  return runBubble;
}

function add(role, text, asHtml = false) {
  document.getElementById("empty")?.remove();
  const element = document.createElement("wa-message");
  element.setAttribute("role", role);
  messages.append(element);
  const body = element.body;
  if (asHtml) body.innerHTML = text; else body.textContent = text;
  pin();
  return body;
}

function setStatus(text) {
  document.getElementById("empty")?.remove();
  if (!statusLine) {
    statusLine = document.createElement("div");
    statusLine.className = "status";
    messages.append(statusLine);
  }
  statusLine.innerHTML = `<span class="spinner"></span>${escapeHtml(text)}`;
  pin();
}

function clearStatus() {
  statusLine?.remove();
  statusLine = null;
}

// The model's own thinking, when the provider streams it in a field of its own instead of
// leaking it into the answer. It is the route to the reply, not the reply, so it lives in a
// collapsible block: open while the run is still thinking, folded away once the run moves on.
// It is folded into the run topic along with the tool calls it belongs to - it *is* the route, and
// leaving it outside left a wall of "thinking · N chars" rows between the reader and the answer
// (measured live: 196 of them sitting outside the topics in one thread). The case that must not be
// swallowed is a run that called no tool at all: no topic is created for one, so its thinking stays
// visible instead of reading as a run that only called tools.
let reasoningBlock = null;
let reasoningText = "";
function appendReasoning(text) {
  if (!text) return;
  const bubble = currentBubble();
  if (!reasoningBlock || reasoningBlock.parentNode !== bubble.body) {
    // A topic like every other one: <wa-reasoning> builds the same header as the tool calls beside it,
    // so the thinking reads as a step of the same kind rather than as a different thing.
    reasoningBlock = document.createElement("wa-reasoning");
    reasoningBlock.open = !replayingMessages;
    bubble.body.append(reasoningBlock);
    reasoningText = "";
  }
  reasoningText += text;
  reasoningBlock.setText(reasoningText);
  pin();
}

// A round is over: the thinking it produced is history, and the block folds away.
function sealReasoning() {
  if (reasoningBlock) reasoningBlock.open = false;
  reasoningBlock = null;
  reasoningText = "";
}

// Tool lines are rendered the way pi renders them in its CLI: bold lowercase
// tool name plus the argument that matters, never a JSON blob.
//   read src/app.js (lines 10-40)   bash $ ls -la   grep /pattern/   edit path
// Long paths crowd the trace line and push the interesting part off the end, so
// elide the middle and keep the last two segments (pi shows them relative to its
// working directory; we do not have the node's cwd in the browser, and the
// tail is what identifies the file either way).
function shortPath(value) {
  const text = String(value || "").replace(/\\/g, "/");
  if (text.length <= 52) return text;
  const parts = text.split("/").filter(Boolean);
  return "…/" + parts.slice(-2).join("/");
}

function toolTitle(name, args) {
  const a = args || {};
  const esc = escapeHtml;
  const path = esc(shortPath(a.path || a.file_path || ""));
  switch (name) {
    case "bash":
    case "shell": {
      const command = String(a.command || "").replace(/\s+/g, " ").slice(0, 160);
      return `$ ${esc(command)}`;
    }
    case "read": {
      const range = (a.offset || a.limit)
        ? ` (lines ${a.offset || 1}-${a.limit ? (Number(a.offset || 1) + Number(a.limit) - 1) : ""})`
        : "";
      return `${path}${esc(range)}`;
    }
    case "write":
    case "edit":
      return path;
    case "grep":
      return `/${esc(String(a.pattern || ""))}/${a.path ? " in " + esc(shortPath(a.path)) : ""}`;
    case "ls":
      return path || ".";
    case "recall":
      return esc(String(a.query || ""));
    case "remember":
      return esc(String(a.content || "").slice(0, 90));
    case "forget":
      return esc(String(a.id || ""));
    case "memories":
      return a.scope ? esc(String(a.scope)) : "all";
    case "session":
    case "session_debug":
    case "session_fixture":
      return esc(String(a.session_id || a.id || ""));
    case "search_messages":
    case "search_ledger":
      return esc(String(a.query || ""));
    case "nodes":
    case "spells":
    case "capabilities":
      return "";
    default: {
      const values = Object.entries(a)
        .filter(([, v]) => v !== undefined && v !== null && v !== "")
        .map(([k, v]) => `${k}=${typeof v === "string" ? v : JSON.stringify(v)}`);
      return esc(values.join(" ").slice(0, 140));
    }
  }
}

// What the call produced, in one short phrase (pi shows the payload only when a
// tool line is expanded).
function toolOutcome(name, result) {
  const r = result || {};
  if (r.error) return { text: String(r.error).slice(0, 80), failed: true };
  switch (name) {
    case "read": {
      const lines = String(r.content || "").split("\n").length - 1;
      return { text: `${lines} lines` };
    }
    case "bash":
    case "shell":
      return { text: `exit ${r.code === undefined ? "?" : r.code}`, failed: r.code !== 0 && r.code !== undefined };
    case "grep":
      return { text: `${r.count || 0} match${r.count === 1 ? "" : "es"}` };
    case "ls":
      return { text: `${(r.entries || []).length} entries` };
    case "write":
    case "edit":
      return { text: "written" };
    case "remember":
      return { text: "stored" };
    case "forget":
      return { text: r.forgotten ? "removed" : "not found" };
    case "memories":
    case "recall":
      return { text: `${Array.isArray(r) ? r.length : 0} memories` };
    case "sessions":
      return { text: `${(r.sessions || []).length} sessions` };
    case "nodes":
      return { text: `${(r.nodes || []).length} nodes` };
    default:
      return { text: "ok" };
  }
}

function toolDetail(result) {
  const text = typeof result === "string" ? result : JSON.stringify(result || {}, null, 1);
  return text.length > 4000 ? text.slice(0, 4000) + "\n…(truncated)" : text;
}

// The trace topic for the run currently running. Created on the first tool call
// and finished when the reply arrives, so one step is one topic.
let trace = null;
let lastTool = "";
// The deadline a `bash`/`shell` call is given, from /health. The tool event usually carries its own
// `timeout_ms`; this is the fallback for a window that joined mid-run or an older node, so the bound
// is still shown rather than guessed at.
let execTimeoutSeconds = 300;
// One ticker for the page, not one per tool. Only the newest pending line is in flight (runs are
// ordered within a session), and a timer per call would outlive the line it was counting for.
let toolTicker = null;

function renderDiff(bubble, changes) {
  const files = (changes && changes.files) || [];
  if (files.length === 0) return null;
  const topic = document.createElement("wa-diff");
  topic.setSummary(changes);
  bubble.body.append(topic);
  // The toggle starts pending: the server has not yet said whether this can be undone (the files may have
  // moved on since the run), and enabling it first would be a button that promises something the handler
  // can then refuse. It used to say "checking…" in the refusal style, which showed a question as an error.
  topic.setPending();
  topic.addEventListener("diff-act", (event) => actOnDiff(topic, event.detail));
  return topic;
}

// Ask whether this run's change can still be undone, and let the topic show the answer.
// A refusal here is not an error: a file that moved on is a normal thing to find, and the
// topic says which file rather than leaving the reader with a dead button.
async function askUndoable(topic) {
  if (!topic.dataset.messageId) return;
  try {
    const response = await fetch("diff", {
      method: "POST", headers: apiHeaders({ "content-type": "application/json" }),
      body: JSON.stringify({ message_id: topic.dataset.messageId, action: "check" }),
    });
    const payload = await response.json();
    topic.setUndoable(payload.can_undo === true, payload.reason || "");
  } catch (error) {
    topic.setUndoable(false, "the node did not answer");
  }
}

// One click, one request, and the outcome is whatever the server says - including a
// refusal, which is shown on the topic. Nothing here assumes the write happened.
async function actOnDiff(topic, detail) {
  const act = detail.act;
  try {
    const response = await fetch("diff", {
      method: "POST", headers: apiHeaders({ "content-type": "application/json" }),
      body: JSON.stringify({ message_id: topic.dataset.messageId, action: act }),
    });
    const payload = await response.json();
    if (payload.error) return detail.done({ ok: false, reason: payload.error });
    detail.done({ ok: payload.ok === true, reason: payload.reason || "" });
  } catch (error) {
    detail.done({ ok: false, reason: "the node did not answer" });
  }
}

// ---- what changed in one file (the balloon behind a click) -----------------
//
// The run carries addresses, not bodies, so the patch is built by the node on demand - which is why
// this is a click and not a hover. A hover that fetched would spend a request on every pointer movement,
// and the hover that showed nothing (which is what it did) is a control that lies about being one.
// A second click on the same row closes it again.
let diffBalloon = null;
let diffBalloonAnchor = null;
let diffBalloonRoom = null;

document.addEventListener("diff-file", (event) => {
  const topic = event.target && event.target.closest ? event.target.closest("wa-diff") : null;
  const detail = event.detail || {};
  if (diffBalloon && diffBalloonAnchor === detail.anchor) { closeFileDiff(); return; }
  openFileDiff(detail.path, detail.anchor, topic);
});

// A patch in its own window: the same content the balloon shows, given the room a window has.
//
// This is the second of the two ways a balloon can exist, and the reason both are kept. In the panel it
// is anchored, instant, and closes on a press outside. In a window it is resizable, movable, snappable
// and Alt-Tab-able, because the operating system already knows how to do all of that and re-implementing
// it in a div would be worse. The panel is the default - it costs nothing and keeps the close rule - and
// a window is for content that wants space, which is exactly what a long patch is.
const PATCH_PROMOTE_LINES = 200;

function patchViewName(path) {
  const base = String(path || "").split(/[\\/]/).pop() || "patch";
  return "patch:" + base;
}

function openPatchWindow(messageId, path) {
  if (!messageId || !path) return false;
  if (!native || typeof native.openView !== "function") return false;
  // Never from inside a view: opening a window from a window is how you get two of them.
  if (viewMode()) return false;
  const url = location.origin + location.pathname +
    "?view=" + encodeURIComponent(patchViewName(path)) +
    "&message=" + encodeURIComponent(messageId) + "&path=" + encodeURIComponent(path);
  native.openView(patchViewName(path), url);
  return true;
}

function renderPatchView(messageId, path) {
  const section = document.createElement("section");
  section.className = "patch-view";
  const head = document.createElement("div");
  head.className = "patch-head";
  const title = document.createElement("span");
  title.className = "patch-title";
  title.textContent = path || "patch";
  const close = document.createElement("button");
  close.type = "button";
  close.className = "patch-close";
  close.textContent = "close";
  close.addEventListener("click", () => {
    if (native && typeof native.closeView === "function") native.closeView();
  });
  head.append(title, close);
  const pre = document.createElement("pre");
  pre.className = "diff-patch";
  pre.textContent = "asking the node for this file…";
  section.append(head, pre);
  document.body.append(section);
  fetch("diff", {
    method: "POST", headers: apiHeaders({ "content-type": "application/json" }),
    body: JSON.stringify({ message_id: messageId, action: "patch", path: path }),
  })
    .then((response) => response.json())
    .then((payload) => {
      if (payload.error) pre.textContent = "this file cannot be shown: " + payload.error;
      else renderPatch(pre, payload);
    })
    .catch(() => { pre.textContent = "the node did not answer"; });
}

async function openFileDiff(path, anchor, topic) {
  const messageId = topic && topic.dataset.messageId;
  if (!messageId || !path) return;
  closeFileDiff();
  const balloon = document.createElement("wa-balloon");
  balloon.className = "file-diff";
  const head = document.createElement("div");
  head.className = "pop-head";
  const headLabel = document.createElement("span");
  headLabel.className = "pop-head-label";
  headLabel.textContent = path;
  // Always offered, not only when the patch is long: which container suits a patch is the reader's
  // judgement, and the two have different virtues - the balloon is instant and closes on a press
  // outside, the window is resizable, movable and survives the chat being collapsed.
  const toWindow = document.createElement("button");
  toWindow.type = "button";
  toWindow.className = "pop-head-action";
  toWindow.textContent = "open in a window";
  toWindow.title = "show this patch in its own window";
  toWindow.addEventListener("click", () => {
    if (openPatchWindow(messageId, path)) closeFileDiff();
  });
  head.append(headLabel, toWindow);
  const body = document.createElement("pre");
  body.className = "diff-patch";
  body.textContent = "asking the node for this file…";
  balloon.append(head, body);
  document.body.append(balloon);
  diffBalloon = balloon;
  diffBalloonAnchor = anchor;
  balloon.addEventListener("close", () => { closeFileDiff(); });
  balloon.show();
  placeFileDiff(balloon, anchor);
  try {
    const response = await fetch("diff", {
      method: "POST", headers: apiHeaders({ "content-type": "application/json" }),
      body: JSON.stringify({ message_id: messageId, action: "patch", path: path }),
    });
    const payload = await response.json();
    if (payload.error) {
      body.textContent = "this file cannot be shown: " + payload.error;
    } else {
      renderPatch(body, payload);
      // Content that wants more room than the panel can give goes to a window rather than being
      // scrolled inside a box the size of a chat bubble. The reader is told which happened: the
      // balloon does not silently become a window, and a window does not silently become a balloon.
      const lines = String(payload.patch || "").split("\n").length;
      if (lines >= PATCH_PROMOTE_LINES && openPatchWindow(messageId, path)) {
        closeFileDiff();
        return;
      }
    }
    // The patch decided the balloon's size, so where it goes is decided after it is filled.
    placeFileDiff(balloon, anchor);
  } catch (error) {
    body.textContent = "the node did not answer";
  }
}

// Make room rather than clip.
//
// The window is a clipped rectangle: a panel that needs more space than the window has cannot be drawn
// outside it, whatever the CSS says. So when a balloon does not fit, the shell is asked for a bigger
// window, and gives it back when the balloon closes. That is not the same as overflowing the window - a
// DOM element cannot paint outside its own window - but it is the difference between a patch the reader
// can read and one cut off at 88 pixels, which is what the compact window is.
function roomForBalloon(balloon) {
  const rect = balloon.getBoundingClientRect();
  const needWidth = Math.ceil(rect.width) + 10;
  const needHeight = Math.ceil(rect.height) + 10;
  const cramped = window.innerWidth < needWidth || window.innerHeight < needHeight;
  if (cramped && native && native.setMode && !diffBalloonRoom) {
    diffBalloonRoom = { mode: document.body.classList.contains("compact") ? "compact" : "expanded" };
    native.setMode("expanded", Math.min(900, Math.max(needWidth, 360)),
                              Math.min(1200, Math.max(needHeight, 420)));
  }
}

function placeFileDiff(balloon, anchor) {
  balloon.style.left = "0px";
  balloon.style.top = "0px";
  roomForBalloon(balloon);
  const rect = balloon.getBoundingClientRect();
  const box = anchor && anchor.getBoundingClientRect ? anchor.getBoundingClientRect()
    : { right: 120, top: 40 };
  const margin = 5;
  let left = (box.right || 120) + margin;
  if (left + rect.width > window.innerWidth - margin) {
    left = Math.max(margin, window.innerWidth - rect.width - margin);
  }
  let top = box.top || 40;
  if (top + rect.height > window.innerHeight - margin) {
    top = Math.max(margin, window.innerHeight - rect.height - margin);
  }
  balloon.style.left = Math.max(margin, left) + "px";
  balloon.style.top = Math.max(margin, top) + "px";
}

function renderPatch(pre, payload) {
  pre.replaceChildren();
  for (const line of String(payload.patch || "").split("\n")) {
    const row = document.createElement("span");
    row.className = "patch-line";
    if (line.startsWith("+++") || line.startsWith("---")) row.classList.add("patch-file");
    else if (line.startsWith("@@")) row.classList.add("patch-hunk");
    else if (line.startsWith("+")) row.classList.add("patch-add");
    else if (line.startsWith("-")) row.classList.add("patch-del");
    row.textContent = line === "" ? " " : line;
    pre.append(row);
  }
  if (payload.truncated) {
    const note = document.createElement("span");
    note.className = "patch-note";
    note.textContent = "this file is large, so only its first part is shown";
    pre.append(note);
  }
}

function closeFileDiff() {
  if (!diffBalloon) return;
  const balloon = diffBalloon;
  diffBalloon = null;
  diffBalloonAnchor = null;
  if (balloon.isConnected) balloon.remove();
  // The window was grown to make room; give it back the way the reader had it.
  if (diffBalloonRoom && native && native.setMode) {
    native.setMode(diffBalloonRoom.mode, window.innerWidth, window.innerHeight);
    diffBalloonRoom = null;
  }
}

function currentTrace() {
  if (!trace) {
    trace = document.createElement("wa-trace");
    currentBubble().body.append(trace);
  }
  return trace;
}

function addTool(name, args, options) {
  const boundMs = options && options.timeoutMs;
  currentTrace().addTool(name, toolTitle(name, args), null, boundMs ? Math.round(boundMs / 1000) : null);
  lastTool = name;
  if (!replayingMessages) startToolTicker();
  pin();
}

function startToolTicker() {
  if (toolTicker) return;
  toolTicker = setInterval(() => {
    if (!trace || !trace.pending) { stopToolTicker(); return; }
    trace.setAge();
  }, 1000);
}

function stopToolTicker() {
  if (toolTicker) { clearInterval(toolTicker); toolTicker = null; }
}

function settleTool(result, name) {
  if (!trace) return;
  const outcome = toolOutcome(name || lastTool, result);
  trace.settle(outcome.text, toolDetail(result), outcome.failed);
  if ((name || lastTool) === "subagent") renderSubagentCard(result);
  if (!trace.pending) stopToolTicker();
  pin();
}

// A subagent's work happens in its own session, so the parent transcript would otherwise show only
// a JSON receipt. Surface the profile, the state and the child's session, and link to its
// transcript - the receipt is a launch notice, not the work.
function renderSubagentCard(result) {
  let payload = result;
  if (typeof payload === "string") { try { payload = JSON.parse(payload); } catch (error) { return; } }
  if (!payload || typeof payload !== "object") return;
  if (!payload.profile && !payload.session_id) return;
  const card = document.createElement("div");
  card.className = "subagent-card";
  const title = document.createElement("span");
  title.className = "subagent-title";
  title.textContent = "subagent · " + (payload.profile || "unknown");
  const meta = document.createElement("span");
  meta.className = "subagent-meta";
  const parts = [];
  if (payload.state) parts.push(payload.state);
  if (payload.settled === true) parts.push("settled");
  if (payload.session_id) parts.push(String(payload.session_id).slice(0, 8));
  meta.textContent = parts.join(" · ");
  card.append(title, meta);
  if (payload.session_id) card.append(nodeButton("open", () => openSession(payload.session_id)));
  currentBubble().body.append(card);
}

function finishTrace() {
  stopToolTicker();
  // Every stored decision is historical, even when its tool result is absent.
  // A later reply or user message can close that decision before the replay ends.
  if (replayingMessages && trace?.pending) trace.unrecorded();
  trace?.finish();
  trace = null;
}

// A byte count a reader can act on. Small values keep one decimal so "1.5 KiB" does not read as
// "1 KiB"; large ones drop it.
function formatBytes(count) {
  const n = Number(count) || 0;
  if (n < 1024) return n + " B";
  if (n < 1024 * 1024) return (n / 1024).toFixed(n < 10240 ? 1 : 0) + " KiB";
  return (n / (1024 * 1024)).toFixed(1) + " MiB";
}

// While a tool call is in flight, show what the operation behind it is doing. A foreground
// `bash` blocks its worker and returns nothing until it settles, so the window otherwise shows
// only a clock - and a five-minute build is indistinguishable from a hang. The node already
// publishes the running operation on /health (`operations[]`) and its output through
// /operation; this reads both. `running` is the busy run for *this* window.
//
// The line always says the state and how much has been written, even when that is nothing: a
// silent command is a fact, and `running · 0 B` is more honest than an empty line that looks
// like the preview failed. Output bytes are not proof of useful progress (a quiet compiler is
// healthy), so the newest line is appended when there is one, not invented when there is not.
async function refreshOperationProgress(health, running) {
  if (!trace || !trace.pending || !running) return;
  // The owner is `run:<run_id>` - serve.rs sets it for the run before the interpreter starts,
  // so an in-turn operation carries the run, not the worker. Older builds used the worker id;
  // both are matched so the window works against whichever node it is attached to.
  const owners = [];
  if (running.run_id != null) owners.push("run:" + running.run_id);
  const workerId = running.worker_id != null ? running.worker_id : running.id;
  if (workerId != null) owners.push("worker:" + workerId);
  const operation = (health.operations || []).find((entry) => owners.indexOf(entry.owner) >= 0);
  if (!operation) return;
  const bytes = Number(operation.output_bytes) || 0;
  let tail = "";
  if (bytes > 0) {
    try {
      const response = await fetch("operation", {
        method: "POST",
        headers: apiHeaders({ "content-type": "application/json" }),
        body: JSON.stringify({ action: "read", id: operation.operation_id, stream: "stdout",
          offset: Math.max(0, bytes - 2048), limit: 2048 }),
      });
      if (response.ok) {
        const page = await response.json();
        if (page && typeof page.content === "string") {
          const lines = page.content.split(/\r?\n/).filter((line) => line.trim());
          tail = lines.length ? lines[lines.length - 1].slice(0, 200) : "";
        }
      }
    } catch (error) { /* a preview is never worth breaking the run over */ }
  }
  trace.setProgress((operation.state || "running") + " · " + formatBytes(bytes) + (tail ? " · " + tail : ""));
}

// The answer is the point; the route is reference. On reply, everything the run
// did before the answer moves into one collapsed run topic at the top of the
// bubble, and the answer sits below it.
function collapseRun() {
  const bubble = runBubble;
  if (!bubble) return;
  const body = bubble.body;
  const answer = streamBody;
  // One run topic per bubble. A run that answers more than once - a preamble, then the answer -
  // reuses the topic it already has: creating a second one nests the first inside it, and the
  // reader then opens topics to reach topics.
  const existing = Array.prototype.find.call(body.children, (c) => c.tagName === "WA-RUN");
  const moves = Array.prototype.filter.call(body.children,
    (c) => c !== answer && c !== existing && c.tagName !== "WA-DIFF");
  const traces = moves.filter((c) => c.tagName === "WA-TRACE");
  // A run topic is only created once something actually ran - a run that never called a tool keeps
  // its plain answer. But once a topic exists, a later reply must still fold the previous answer into
  // it even when that batch added no tool call: the guard is about *creating* the topic, not about
  // folding into one that is already there. Getting this wrong left the preamble sitting outside as
  // its own text segment, so the bubble read run,text,text instead of one run and one answer.
  if (!existing && traces.length === 0) return;
  if (moves.length === 0) return;
  const run = existing || document.createElement("wa-run");
  if (!existing) {
    body.prepend(run);
    // While the run is still going the route stays OPEN: the reader is watching it happen, and a
    // collapsed topic hides the very steps they are waiting on (measured: after the first answer the
    // topic closed and took the thinking and the tool lines with it, so a long run read as a folded
    // topic and a list of answers). It is set only when the topic is created, so a reader who closes it
    // by hand is not overruled by the next round. A repaint is history, so there it starts closed.
    run.open = !replayingMessages;
  }
  for (const child of moves) {
    run.body.append(child);
    if (typeof child.reveal === "function") child.reveal();
  }
  // Counted from the topic's own contents rather than accumulated from the moves, so a second
  // collapse cannot double-count what the first one already folded in.
  let calls = 0;
  let steps = 0;
  for (const child of run.body.children) {
    if (child.tagName === "WA-TRACE") calls += child.count || 0;
    else if (child.classList && child.classList.contains("seg")) steps += 1;
  }
  const endedAt = replayingMessages ? replayMessageEndedAt : Date.now();
  run.setSummary(steps, calls, Math.max(0, endedAt - (runStartedAt || endedAt)));
}

// A round is one step: what the model said, then the tools it chose. Closing
// both here interleaves them inside the same bubble - text, tools, text, tools -
// and the bubble only closes when the run really ends.
function flushDecision(final = false) {
  if (streamBody) {
    const text = stripThinking(streamText);
    if (text.trim()) {
      streamBody.innerHTML = renderMarkdown(text);
      streamBody.style.whiteSpace = "normal";
    } else {
      streamBody.remove();   // a step with no prose leaves no empty block
    }
    streamBody = null;
    streamText = "";
  }
  sealReasoning();
  finishTrace();
  if (final) {
    // The run is over: its route folds away, and the answer is what is left to read.
    if (runBubble) {
      for (const topic of runBubble.body.querySelectorAll(":scope > wa-run")) topic.open = false;
    }
    runBubble = null;
  }
  pin();
}

function typeOut(body, text) {
  let index = 0;
  const step = Math.max(2, Math.ceil(text.length / 180));
  const timer = setInterval(() => {
    index = Math.min(text.length, index + step);
    body.textContent = text.slice(0, index);
    pin();
    if (index >= text.length) {
      clearInterval(timer);
      body.innerHTML = renderMarkdown(text);
      body.style.whiteSpace = "normal";
    }
  }, 14);
}

function handleEvent(event) {
  if (event.type === "round") {
    // A new step begins: close the previous one (its text and its tool topic).
    if (!runStartedAt) runStartedAt = Date.now();
    flushDecision();
  } else if (event.type === "node") {
    // Another window renamed this node, or this one did: either way the name is the node's,
    // so take it from the event and let the list catch up.
    if (event.name) updateNodeLabel(event.name, event.worktree);
    refreshNodes();
  } else if (event.type === "status") {
    const note = event.text || "working";
    setStatus(note === "model" ? "thinking…" : "wasm-agent is " + note + "…");
  } else if (event.type === "reasoning") {
    // A reasoning model can think for a long time before it says anything, and a
    // silent panel is indistinguishable from a hung one. The text becomes a thinking
    // block; the count still drives the status line, the live "not hung" signal.
    const chars = Number(event.chars) || 0;
    appendReasoning(event.text || "");
    if (!replayingMessages) setStatus("thinking… " + chars + " chars of reasoning");
  } else if (event.type === "tool") {
    // The bound travels with the tool event when the host enforces one (bash/shell); /health is the
    // fallback so an in-flight line still says "of 300s" instead of only "42s".
    const boundMs = event.timeout_ms != null ? event.timeout_ms
      : (event.name === "bash" || event.name === "shell" ? execTimeoutSeconds * 1000 : null);
    addTool(event.name, event.arguments, { timeoutMs: boundMs });
  } else if (event.type === "tool_result") {
    settleTool(event.result, event.name);
  } else if (event.type === "delta") {
    clearStatus();
    // A new segment per step, inside the same bubble.
    if (!streamBody) {
      streamBody = document.createElement("div");
      streamBody.className = "seg";
      currentBubble().body.append(streamBody);
    }
    streamText += event.text || "";
    streamBody.textContent = stripThinking(streamText);
    pin();
  } else if (event.type === "reply") {
    clearStatus();
    const finalText = stripThinking(event.text || streamText);
    if (streamBody) {
      streamBody.innerHTML = renderMarkdown(finalText);
      streamBody.style.whiteSpace = "normal";
    } else {
      const segment = document.createElement("div");
      segment.className = "seg";
      segment.innerHTML = renderMarkdown(finalText);
      currentBubble().body.append(segment);
      streamBody = segment;
    }
    finishTrace();
    // The run topic goes *above* the answer; the diff goes *below* it. Order matters and was
    // wrong here: the diff used to be appended *before* collapseRun(), which moves every child
    // that is not the answer into the run topic - so the diff landed inside the run topic,
    // where the reader had to open the run's path to find out what it changed. The diff is
    // created after the run is collapsed, and collapseRun() also refuses to swallow a WA-DIFF,
    // so the two cannot get back into that order.
    collapseRun();
    sealReasoning();
    const diff = renderDiff(currentBubble(), event.changes);
    if (diff) {
      diff.dataset.messageId = event.message_id || "";
      if (diff.dataset.messageId) askUndoable(diff);
    }
    streamBody = null;
    streamText = "";
    // The bubble stays open for the rest of the run. A model that speaks between tool batches is
    // still one run, and the run topic has to be able to span everything it did; closing the bubble
    // here was the bug - one run drew one bubble per reply. flushDecision(true) closes it, on `done`
    // or on the next user turn, which is the contract its own comment already stated.
  } else if (event.type === "usage") {    settings.usage = event.total || settings.usage;
    if (event.model) settings.model = event.model;
    updateChip();
    if (balloon.open) { renderUsage(); renderModels(); }
  } else if (event.type === "error") {
    clearStatus();
    add("assistant", "error: " + (event.error || "unknown"));
    finishTrace();
    runBubble = null;
  } else if (event.type === "done") {
    clearStatus();
    flushDecision(true);
  }
}

function restoreDraft() {
  let text = "";
  try { text = localStorage.getItem(DRAFT_KEY) || ""; } catch (error) { text = ""; }
  if (!text) return;
  input.value = text;
  autosize();
  draftNow = snapshotDraft();
}

// ---- coming back after a respawn ---------------------------------------------------------
//
// A window is a view of a durable ledger, which is what makes patching it safe. This is the other
// half of that promise: after a respawn it must come back to the conversation it was in and
// repaint it, instead of starting blank and looking like the work is gone. It did start blank -
// a patch reloaded the window and both the transcript and a half-written prompt disappeared.

// Repaint a transcript by replaying the stored runs as the events the live view already
// understands. Reusing handleEvent is the point: a repainted bubble is built by exactly the code
// that built it the first time, so the two cannot drift apart.
let replayingMessages = false;
let replayMessageEndedAt = 0;
function repaintMessages(rows) {
  // A repaint is a view of durable rows, not a resumed event stream. In particular, an
  // assistant tool call without a result must never inherit a live timer from this page.
  stopToolTicker();
  trace = null;
  lastTool = null;
  messages.replaceChildren();
  runBubble = null;
  streamBody = null;
  streamText = "";
  reasoningBlock = null;
  runStartedAt = 0;
  replayMessageEndedAt = 0;
  let rendered = 0;
  let failed = 0;
  let firstFailure = "";
  replayingMessages = true;
  for (const message of rows) {
    // Per message, so one malformed row cannot swallow the rest of the transcript. A repaint that
    // stops halfway is how "my own input is missing" becomes invisible: the rows before the throw
    // are drawn, the rows after it are not, and nothing says so.
    try {
      if (message.role === "user") {
        flushDecision(true);
        runStartedAt = Number(message.created_at) > 0 ? Number(message.created_at) * 1000 : Date.now();
        add("user", message.content || "");
      } else if (message.role === "assistant") {
        // The stored message carries its changes summary and its id, and both are needed: the summary is
        // the topic, and the id is what the undo route is asked about. Dropping them here is why a
        // reloaded transcript showed no diff topics at all - the live path had them, the repaint did
        // not, and a window that has been reloaded is a repaint.
        // The stored row keeps the thinking apart from the answer; replay it through the same
        // path the live stream used, so a reloaded transcript shows it too.
        if (message.reasoning) {
          handleEvent({ type: "reasoning", text: message.reasoning, chars: message.reasoning.length });
        }
        if (message.content) {
          replayMessageEndedAt = Number(message.created_at) > 0 ? Number(message.created_at) * 1000 : Date.now();
          handleEvent({ type: "reply", text: message.content, changes: message.changes, message_id: message.id });
        }
        const calls = message.tool_calls || [];
        if (calls.length) {
          handleEvent({ type: "round", n: 1 });
          for (const raw of calls) {
            // A stored call keeps the provider's shape: name and arguments nested, and the arguments
            // still the JSON string the model produced.
            const fn = raw.function || raw;
            let args = fn.arguments;
            if (typeof args === "string") { try { args = JSON.parse(args); } catch (error) { args = {}; } }
            handleEvent({ type: "tool", name: fn.name, arguments: args || {} });
          }
        }
      } else if (message.role === "tool") {
        handleEvent({ type: "tool_result", name: message.tool_name, result: { content: message.content } });
      }
      rendered += 1;
    } catch (error) {
      failed += 1;
      if (!firstFailure) {
        firstFailure = `${message.role} seq ${message.seq}: ${error}`;
        console.error("repaint failed", run, error);
      }
    }
  }
  if (trace) finishTrace();
  replayingMessages = false;
  // The transcript just drawn is history, so the bubble it ended on is closed. The `reply` handler
  // used to close it, and when that stopped (one bubble per run) this became the place that must:
  // without it the next thing that arrives is appended to the last repainted run's bubble, so a
  // message sent after a reload lands inside the previous run's reply. Caught by the UI harness.
  runBubble = null;
  pin(true);
  if (failed) {
    add("assistant", `repaint: ${rendered} of ${rows.length} messages drawn, ${failed} failed — first: ${firstFailure}`);
  }
  return { rendered, failed, firstFailure };
}

// The newest session for this user is the one that just ran, which is how the window finds out
// which conversation it is in: the chat route does not return the id it used. Once known the id is
// remembered, so the next respawn comes back to exactly this thread.
// The newest session for this user is the one that just ran, which is how the window finds out
// which conversation it is in the *first* time: the chat route does not return the id it used. Once
// known the id is remembered, and everything below prefers it - guessing "newest" on every load is
// how a window ends up showing somebody else's thread, which is exactly what happened: the newest
// session was another agent's, so the reader's own conversation looked like it had lost their input.
async function learnSession() {
  try {
    const payload = await (await apiFetch("sessions", { headers: apiHeaders() })).json();
    const mine = (payload.sessions || []).filter((s) => !me.user || !s.user_id || s.user_id === me.user.id);
    if (mine.length) rememberSession(mine[0].id);
  } catch (error) { /* unreachable: the next run tries again */ }
}

// /sessions flattens state onto each row; /session returns the full state object.
// Treat those as two documented shapes, not as interchangeable strings.
function sessionOutcome(full) {
  const value = full && full.state;
  if (value && typeof value === "object") {
    return { name: value.state || "", detail: value.detail || "" };
  }
  return { name: typeof value === "string" ? value : "", detail: full?.state_detail || "" };
}

let restoringSession = null;
let transcriptReady = false;
async function restoreSession() {
  if (restoringSession) return restoringSession;
  restoringSession = restoreSessionOnce();
  try { return await restoringSession; }
  finally { restoringSession = null; }
}

async function restoreSessionOnce() {
  try {
    const payload = await (await apiFetch("sessions", { headers: apiHeaders() })).json();
    const sessions = payload.sessions || [];
    if (payload.error) throw new Error(payload.error);
    if (!sessions.length) { transcriptReady = true; return true; }
    const mine = sessions.filter((s) => !me.user || !s.user_id || s.user_id === me.user.id);
    const wanted = sessions.find((s) => s.id === chatSession) || mine[0] || sessions[0];
    rememberSession(wanted.id);
    const route = "session?id=" + encodeURIComponent(wanted.id);
    let [full, health] = await Promise.all([
      apiFetch(route, { headers: apiHeaders() }).then((response) => response.json()),
      nodeHealth(),
    ]);
    if (!full || full.error || !Array.isArray(full.messages)) {
      throw new Error(full?.error || "invalid session response");
    }
    let outcome = sessionOutcome(full);
    // A reply can land between the transcript read and /health. When the node is idle,
    // reread once before declaring a run unfinished; otherwise a completed answer could
    // briefly be displayed as a lost tool call.
    if (outcome.name === "unfinished" && health && !activeRun(health, wanted.id)) {
      const latest = await (await apiFetch(route, { headers: apiHeaders() })).json();
      if (latest && !latest.error && Array.isArray(latest.messages)) {
        full = latest;
        outcome = sessionOutcome(full);
      }
    }
    if (full && Array.isArray(full.messages) && full.messages.length) repaintMessages(full.messages);
    const unresolved = outcome.name === "failed" || outcome.name === "unfinished";
    if (unresolved) {
      const notice = document.createElement("div");
      notice.className = "unfinished-notice";
      if (outcome.name === "failed") {
        notice.textContent = "the last run failed before it answered - " +
          (outcome.detail || "the node recorded a failure") + ".";
      } else if (!health) {
        notice.textContent = "no result is recorded for the last message; the node is unavailable, so its outcome is unknown.";
      } else if (activeRun(health, wanted.id)) {
        notice.textContent = "no result is recorded yet. A run is in progress on the node; this page will check again when it becomes idle.";
        sawTurnInFlight = true;
      } else {
        notice.textContent = "this message has no recorded answer - " +
          (outcome.detail || "the last step has no recorded result") +
          ". Its effects may have happened; check them before continuing.";
      }
      // Reloading a page must never execute an unfinished tool a second time. Recovery
      // requires a person to inspect possible side effects and explicitly continue.
      if (health && !activeRun(health, wanted.id)) {
        notice.append(nodeButton("continue", () => { notice.remove(); resumeSession(wanted.id); }));
      }
      messages.append(notice);
    }
    transcriptReady = true;
    return true;
  } catch (error) {
    transcriptReady = false;
    setStatus("transcript not loaded - retrying (" + String(error) + ")");
    return false;
  }
}

function setBusy(value) {
  busy = value;
  // A reload that was deferred for a running run lands the moment it ends, so an update
  // never sits invisible behind a finished run.
  if (!value && pendingReload) {
    pendingReload = false;
    reload();
  }
  // A run ending is what frees the node for everything the engine asked for while it ran.
  if (!value && document.body.classList.contains("engine")) reloadTopics();
  sendButton.classList.toggle("busy", value);
  sendButton.title = value ? "Stop" : "Send";
  sendButton.setAttribute("aria-label", sendButton.title);
  if (value) startLiveness(); else stopLiveness();
}

// Whether this run is *working* or *stuck*, which looked identical from outside.
//
// A run can legitimately spend minutes inside one command, and until this existed the only signals
// were a spinner and a tool line that had not come back - so a long call and a wedged one were
// indistinguishable, and the difference arrived 300 seconds later when the call was killed. The user
// had no way to tell "still working" from "never coming back", which is exactly when they should be
// told to stop it.
//
// The node already knows, and has done all along: `stalled_ms` (also `workers[].age_ms`) is the age
// of the last heartbeat. `host.exec` beats while a command runs, so a *fresh* number proves progress
// and a number that keeps climbing proves a stall. That is the node's own evidence, reported rather
// than guessed - no client-side timeout, no heuristic about how long things should take.
let liveness = null;

function startLiveness() {
  if (liveness) return;
  let lastStalled = null;
  let climbingSince = 0;
  liveness = setInterval(async () => {
    // Only while a run is busy. The accept thread answers /health without the interpreter, so this
    // costs nothing the run needs and cannot itself be the thing that wedges.
    if (!busy) return;
    let health = null;
    try { health = await (await apiFetch("health", { headers: apiHeaders() })).json(); }
    catch (error) { return; }   // the offline path owns that case and says its piece
    const running = activeRun(health);
    if (!running) { setLiveness(null); return; }
    identifySubmittedRun(health);
    refreshOperationProgress(health, running);

    if (typeof health.exec_timeout_seconds === "number") execTimeoutSeconds = health.exec_timeout_seconds;
    const stalled = health.stalled_ms;
    if (typeof stalled !== "number") { setLiveness(null); return; }
    // "Climbing" is the honest signal for a stall: a single large number could be a long step between
    // beats, but a number that grows across two polls means nothing has beaten since the last one.
    if (lastStalled !== null && stalled > lastStalled + 500) {
      if (!climbingSince) climbingSince = Date.now();
    } else {
      climbingSince = 0;
    }
    lastStalled = stalled;
    const working = stalled < 5000 || !climbingSince;
    const busyFor = running.busy_ms || running.ms || Date.now() - (runStartedAt || Date.now());
    const ownState = (health.run_ids || []).find((run) => Number(run.run_id) === activeRunId)?.state;
    setLiveness({
      working,
      stalled,
      busy_ms: busyFor,
      climbing_ms: climbingSince ? Date.now() - climbingSince : 0,
      worker: health.worker || "alive",
      queue: health.queue || 0,
      run_state: ownState,
      current_run_id: running.run_id,
    });
  }, 1000);
}

function stopLiveness() {
  if (liveness) { clearInterval(liveness); liveness = null; }
  setLiveness(null);
}

function setLiveness(info) {
  let node = document.getElementById("liveness");
  if (!info) { if (node) node.remove(); return; }
  if (!node) {
    node = document.createElement("div");
    node.id = "liveness";
    node.className = "liveness";
    // Inside the message list, so it lives with the run it describes and disappears with it - a
    // status bar elsewhere would keep reporting a run that has already been answered.
    messages.append(node);
  }
  const seconds = (ms) => (ms / 1000).toFixed(0);
  if (info.working) {
    node.classList.remove("stuck");
    if (info.run_state === "queued") {
      node.textContent = "queued · this run has not started; waiting for run #"
        + info.current_run_id + " · node beat " + info.stalled + " ms ago"
        + (info.queue ? " · " + info.queue + " queued" : "");
    } else {
      node.textContent = "working — node beat " + info.stalled + " ms ago · this run "
        + seconds(info.busy_ms) + "s" + (info.queue ? " · " + info.queue + " queued" : "");
    }
  } else {
    node.classList.add("stuck");
    node.textContent = "possibly stuck — no node beat for " + seconds(info.climbing_ms) + "s"
      + " (worker: " + info.worker + ") · send to stop";
  }
  pin();
}

function identifySubmittedRun(health) {
  if (activeRunId !== null || !submittedRunIds || !chatSession) return;
  const candidates = (health?.run_ids || [])
    .filter((run) => run.conversation === chatSession && !submittedRunIds.has(Number(run.run_id)))
    .sort((a, b) => Number(a.run_id) - Number(b.run_id));
  if (candidates.length) activeRunId = Number(candidates[candidates.length - 1].run_id);
}

function composedText(text) {
  const files = attachments.filter((file) => file.kind !== "image");
  if (files.length === 0) return text;
  const bodies = files.map((file) => `[file: ${file.name}]\n${file.text}`);
  return bodies.join("\n\n") + (text ? "\n\n" + text : "");
}

// Images go out as a JSON body: {text, images:[{name, mime, data}]}.
// The server accepts plain text too, so this only changes when pictures are
// actually attached. `data` is a full data URL; the server strips the envelope.
function composedBody(text, options = {}) {
  const images = attachments.filter((file) => file.kind === "image");
  // The thread this run belongs to, named in the body.
  //
  // It used to be sent as `X-WA-Session`, which is the *account* header: a thread id in that field
  // resolved to no user at all and fell back to master, so the window's choice was never read and
  // every window shared one ever-growing thread. The node parses this body itself, which is why
  // naming a thread needed no HTTP route and no Rust change.
  //
  // Deliberately not gated on the role the page believes it has: that value arrives from `/me` and
  // is `guest` until it does, so a guard here would silently send the first run after `/new` to the
  // thread the reader just left. Who may address a thread is decided once, by the node, which knows
  // the caller - and refuses a thread that is not theirs with `forbidden_thread`.
  const thread = options.session || chatSession;
  if (images.length === 0 && !thread) {
    return { contentType: "text/plain; charset=utf-8", body: composedText(text) };
  }
  const payload = { text: composedText(text) };
  if (images.length) payload.images = images.map((file) => ({ name: file.name, mime: file.mime, data: file.data }));
  if (thread) payload.thread = thread;
  return { contentType: "application/json", body: JSON.stringify(payload) };
}

// A lost connection is not a failed run. When the node dies mid-stream the
// browser throws a TypeError, and printing it raw - "error: TypeError: network
// error" - tells the reader nothing: not what broke, not what to do, and not
// that the work is recoverable. It is: the run is recorded as unfinished.
function isConnectionLoss(error) {
  return error instanceof TypeError;
}

function connectionMessage() {
  return "lost the local node mid-run (nothing is serving " + location.origin + ")." +
    " Start it with `wa ui` - this run is recorded as unfinished, and" +
    " `wa resume --list` will offer to continue it.";
}

// The window should not sit there looking fine while its node is gone: after a
// lost connection it polls health and says so, then clears itself when the node
// answers again - no reload, no guessing.
let nodeWatch = null;
function nodeOffline(offline) {
  document.body.classList.toggle("node-offline", offline);
  if (offline) setStatus("the local node is not answering - start it with `wa ui`");
  else clearStatus();
}
function watchNode() {
  if (nodeWatch) return;
  nodeOffline(true);
  nodeWatch = setInterval(async () => {
    try {
      const response = await apiFetch("health", { headers: apiHeaders() });
      if (response.ok) { clearInterval(nodeWatch); nodeWatch = null; nodeOffline(false); refreshMeta(); }
    } catch (error) { /* still down */ }
  }, 3000);
}
// A notice the page put up about this run, so it can take it down again. A span that stays after the
// thing it described has gone is not a record, it is litter - and it grows the transcript with every
// false alarm.
let streamNotice = null;

function clearStreamNotice() {
  if (streamNotice && streamNotice.isConnected) streamNotice.remove();
  streamNotice = null;
  // The restore's notice is the same claim in a different place: "this run did not finish". Once the
  // node says the thread is settled, the claim is stale and the span should go - the durable record is
  // the engine's sessions topic, which is where a reader looks for it.
  for (const notice of document.querySelectorAll(".unfinished-notice")) notice.remove();
}

async function send(text, options = {}) {
  activeRunId = null;
  submittedRunIds = null;
  // The draft is going out, so what was stored is stale: a respawn must not put the sent prompt
  // back into the composer.
  clearDraft();
  setBusy(true);
  // Sending is an explicit request to see the answer: follow again, even if the
  // reader had scrolled up to read something.
  setFollow(true);
  pin(true);
  runBubble = null;   // the reply gets its own bubble
  runStartedAt = Date.now();
  controller = new AbortController();
  streamBody = null;
  streamText = "";
  const names = attachments.map((file) => file.name).join(", ");
  add("user", text + (names ? `\n\nattached: ${names}` : ""));
  const outgoing = composedBody(text, options);
  // Clear in place, like the submit handler does. Reassigning the binding here was
  // enough to make a reader's captured reference stale - which is how a test can end
  // up asserting against a dead array and passing.
  attachments.length = 0;
  renderAttachments();
  setStatus("wasm-agent is thinking…");
  // /health is answered without waiting for a worker. Take the baseline before admitting this run
  // so later polls can tell its queued id from an older run in the same conversation.
  try {
    const before = await (await apiFetch("health", { headers: apiHeaders() })).json();
    submittedRunIds = new Set((before.run_ids || [])
      .filter((run) => run.conversation === chatSession)
      .map((run) => Number(run.run_id)));
  } catch (error) {
    submittedRunIds = new Set();
  }
  // Declared out here, not inside the `try` below: the `finally` clears it, and a `const` inside the try
  // is not in scope there. It was inside, so every run ended by throwing `watchdog is not defined` from
  // the first line of the `finally` - which meant `clearInterval`, `setBusy(false)`, `controller = null`
  // and the meta refresh never ran, and the window sat there looking like it was still working on a run
  // that had finished. The gate's bug hunt found it; the product would only have shown it as "stuck".
  let watchdog = null;
  try {
    const headers = { "Content-Type": outgoing.contentType, "Accept": "text/event-stream" };
    // Which thread this run belongs to travels in the body (`composedBody`), not here: the header
    // this used to set is the *account* one, and a thread id in it resolved to no user and fell back
    // to master - so the window's choice was never read. `apiHeaders` supplies the account below.
    // Silence is not evidence of death.
    //
    // A tool that takes minutes - a build, a test suite, an install - produces no events at all, and
    // the node keeps beating throughout. A client that counts seconds therefore kills runs that are
    // working: this one aborted a healthy run mid-build, told the reader it was "recorded as
    // unfinished" when it was not, and the run then finished normally in the ledger. A false alarm
    // that also lies about the record is worse than no alarm.
    //
    // The node is the authority, and its accept thread answers /health without the interpreter, so it
    // can say whether the worker is alive while a run runs. Ask it, and act only on its answer.
    let lastEvent = Date.now();
    let asking = false;
    // Whether this run finished under its own steam. Without it the watchdog cannot tell a run that
    // ended from a run that died: both leave `current: null`, so a run that completed while the
    // watchdog was asking /health got reported as "no longer running this run ... recorded as
    // unfinished" - about a run whose answer was already on screen. The message said `(alive)`, which
    // was the tell.
    let turnFinished = false;
    const watchdogTick = async () => {
      if (turnFinished) { clearInterval(watchdog); return; }
      if (asking || Date.now() - lastEvent < 30000) return;
      asking = true;
      try {
        const health = await (await apiFetch("health", { headers: apiHeaders() })).json();
        identifySubmittedRun(health);
        // Asked and answered while the run was ending: say nothing. The run finished; there is
        // nothing to report and nothing to continue.
        if (turnFinished) { clearInterval(watchdog); asking = false; return; }
        const running = activeRun(health);
        if (running && health.worker !== "stalled") {
          // Working, and quiet because the work is quiet. Keep waiting, and start counting again.
          lastEvent = Date.now();
          asking = false;
          return;
        }
        // Not running any more, and the run did not finish: the run is genuinely over, and the page
        // should say so and stop pretending it is still listening.
        clearInterval(watchdog);
        streamNotice = add("assistant", "the node is no longer running this run (" + (health.worker || "no worker") +
          "). It is recorded as unfinished - the sessions topic offers to continue it.");
        watchNode();
        controller?.abort();
      } catch (error) {
        // Unreachable: the node is gone, which is a different message and the one that fits.
        clearInterval(watchdog);
        streamNotice = add("assistant", connectionMessage());
        watchNode();
        controller?.abort();
      }
      asking = false;
    };
    // Armed here, assigned to the outer `watchdog` so the `finally` can always clear it - including when
    // the fetch below throws before a single event arrives.
    watchdog = setInterval(watchdogTick, 5000);
    const response = await fetch("chat", {
      method: "POST",
      headers: apiHeaders(headers),
      body: outgoing.body,
      signal: controller.signal,
    });
    if (!response.body) {
      const payload = await response.json();
      clearStatus();
      add("assistant", payload.reply || payload.error || "(no reply)");
    } else {
      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        const parts = buffer.split("\n\n");
        buffer = parts.pop();
        for (const part of parts) {
          const line = part.split("\n").find((l) => l.startsWith("data: "));
          if (!line) continue;
          try { handleEvent(JSON.parse(line.slice(6))); lastEvent = Date.now(); } catch (error) { /* ignore */ }
          // A run that says it is done, or has answered, or has failed, is finished: whatever the
          // watchdog asks next, this run is not unfinished, and any notice it put up is stale.
          const kind = (() => { try { return JSON.parse(line.slice(6)).type; } catch (error) { return ""; } })();
          if (kind === "done" || kind === "reply" || kind === "error") {
            turnFinished = true;
            clearStreamNotice();
          }
        }
      }
    }
  } catch (error) {
    clearStatus();
    if (error.name === "AbortError") add("assistant", "stopped.");
    else if (isConnectionLoss(error)) { add("assistant", connectionMessage()); watchNode(); }
    else add("assistant", "error: " + error);
  } finally {
    clearInterval(watchdog);
    setBusy(false);
    controller = null;
    refreshMeta();
    // Learn which thread this run went into, but only until we know one: after that the window
    // keeps the thread it is in, rather than following whatever happens to be newest.
    if (!chatSession) learnSession();
    if (!native) input.focus();
  }
}

function formatTokens(value) {
  const n = Number(value) || 0;
  if (n >= 1_000_000) return (n / 1_000_000).toFixed(1) + "M";
  if (n >= 1000) return (n / 1000).toFixed(1) + "k";
  return String(n);
}

function activeProvider() {
  return (settings.providers || []).find((provider) => provider.id === settings.provider) || null;
}

function updateChip() {
  chipModel.textContent = settings.configured ? (settings.model || "model") : "local mode";
  statusBtn.classList.toggle("local", !settings.configured);
  const total = settings.observability?.available ? settings.observability.total?.total : 0;
  chipUsage.textContent = total ? formatTokens(total) + " tok" : "";
}

function renderNodeSelect() {
  const previous = nodeSelect.value;
  // Only nodes that can host a chat: the local host and peers. The local
  // `client` node is a control target, not a conversation target.
  const options = nodeList.filter((item) => item.kind !== "client");
  // Drop a stale selection (a node that is no longer a chat target) instead of
  // silently sending it as X-WA-Node and keying sessions under a phantom name.
  if (activeNode && !options.some((node) => node.name === activeNode)) {
    activeNode = "";
    try { localStorage.removeItem("wa-node"); } catch (error) { /* ignore */ }
  }
  nodeSelect.replaceChildren();
  for (const node of options) {
    const option = document.createElement("option");
    option.value = node.name;
    option.textContent = `${node.name} · ${node.kind}${node.online ? "" : " (offline)"}`;
    if (node.name === (activeNode || previous)) option.selected = true;
    nodeSelect.append(option);
  }
  if (!activeNode && nodeList.length && !nodeSelect.value) {
    const local = nodeList.find((node) => node.local_node && node.kind === "host") || nodeList[0];
    if (local) nodeSelect.value = local.name;
  }
}

function renderProviders() {
  providerSelect.replaceChildren();
  for (const provider of settings.providers || []) {
    const option = document.createElement("option");
    option.value = provider.id;
    option.textContent = provider.configured ? provider.label : provider.label + " (no key)";
    if (provider.id === settings.provider) option.selected = true;
    providerSelect.append(option);
  }
}

function renderModels() {
  reasoningSelect.replaceChildren();
  const reasoning=settings.reasoning || {};
  for (const level of reasoning.supported ? reasoning.levels : ['provider']) {
    const option=document.createElement('option'); option.value=level;
    option.textContent=level==='provider' ? 'provider default / unknown' : level;
    option.selected=level===reasoning.selected; reasoningSelect.append(option);
  }
  reasoningSelect.disabled=!reasoning.supported || me.role!=='master';
  modelSelect.replaceChildren();
  const provider = activeProvider();
  const models = (provider && provider.models) || [];
  for (const name of models) {
    const option = document.createElement("option");
    option.value = name;
    option.textContent = name;
    if (name === settings.model) option.selected = true;
    modelSelect.append(option);
  }
}

function grid(rows) {
  const fragment = document.createDocumentFragment();
  for (const [label, value] of rows) {
    const key = document.createElement("span");
    key.textContent = label;
    const val = document.createElement("b");
    val.textContent = String(value);
    fragment.append(key, val);
  }
  return fragment;
}

function meter(percent) {
  const wrap = document.createElement("div");
  wrap.className = "meter";
  const fill = document.createElement("span");
  fill.style.width = Math.min(100, Math.max(0, percent)) + "%";
  if (percent >= 90) fill.classList.add("hot");
  wrap.append(fill);
  return wrap;
}

function formatReset(iso) {
  const then = new Date(iso).getTime();
  if (!then) return "";
  const minutes = Math.round((then - Date.now()) / 60000);
  if (minutes <= 0) return "resetting";
  if (minutes < 60) return `resets in ${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 48) return `resets in ${hours}h ${minutes % 60}m`;
  return `resets in ${Math.round(hours / 24)}d`;
}

// Context: one information line (used / budget · percent), then the seeker. A
// budget of zero is a fact worth stating - "taken 12K, budget -" reads like a
// missing value rather than a configured absence.
function renderContext() {
  contextBox.replaceChildren();
  if ('observability' in settings) {
    const request=settings.observability?.last_request || {}, last=settings.observability?.last;
    const taken=last?.normalized?.prompt;
    const capacity=Number(settings.context_limit);
    const mismatch=request.model && request.model!==settings.model;
    contextBox.append(grid([['last measured input',taken==null ? 'unknown' : formatTokens(taken)],
      ['selected capacity',capacity ? formatTokens(capacity) : 'unknown']]));
    if (taken!=null && capacity>0 && !mismatch) contextBox.append(meter(taken/capacity*100));
    return;
  }
  const usage = settings.usage || {};
  const taken = Number((usage.last && usage.last.prompt) || 0);
  const budget = Number(settings.context_limit) || 0;
  if (!budget) {
    contextBox.append(grid([["used", `${formatTokens(taken)} taken · no budget`]]));
    return;
  }
  const percent = Math.min(100, Math.round((taken / budget) * 100));
  contextBox.append(grid([["used", `${formatTokens(taken)} / ${formatTokens(budget)} · ${percent}%`]]));
  contextBox.append(meter(percent));
}

// Rolling provider limits: 5h, 7d and 30d.
function renderLimits() {
  limitsBox.replaceChildren();
  const limits = settings.limits || {};
  const windows = [["5h", "rolling"], ["7d", "weekly"], ["30d", "monthly"]];
  let shown = 0;
  for (const [label, key] of windows) {
    const entry = limits[key];
    if (!entry) continue;
    shown += 1;
    const percent = Number(entry.percent) || 0;
    limitsBox.append(grid([[label + " limit", percent + "%"]]));
    limitsBox.append(meter(percent));
    const note = document.createElement("span");
    note.className = "usage-note";
    note.textContent = formatReset(entry.resetsAt);
    limitsBox.append(note);
  }
  if (!shown) {
    const none = document.createElement("span");
    none.className = "usage-note";
    none.textContent = "limits unavailable";
    limitsBox.append(none);
  }
}

// Token accounting: last run and session totals.
function renderUsage() {
  usageBox.replaceChildren();
  harnessStatus.data=settings;
  const observed=settings.observability;
  if (!observed?.available) {
    usageBox.append(grid([['durable usage','not yet observed']]));
    return;
  }
  const t=observed.total || {};
  const known=x=>x==null ? 'unknown' : formatTokens(x);
  usageBox.append(grid([
    ['session input (all)',known(t.prompt)+(t.missing_usage ? ' · partial' : '')],
    ['uncached / cache read',t.cache_known ? `${known(t.input)} / ${known(t.cacheRead)}` : 'unknown / partial'],
    ['cache write',t.cache_known ? known(t.cacheWrite) : 'unknown / partial'],
    ['output (includes reasoning)',known(t.output)+(t.missing_usage ? ' · partial' : '')],
    ['reasoning subset',known(t.reasoning)+(t.reasoning_unknown ? ' · partial/unknown' : '')],
    ['cache reuse',t.cache_known && t.prompt ? (100*t.cacheRead/t.prompt).toFixed(1)+'%' : 'unknown'],
    ['cost (incl. summaries)',t.cost_known ? '$'+Number(t.cost).toFixed(6) : 'unknown / unpriced calls'],
  ]));
}


function renderPopFoot() {
  const provider = activeProvider();
  const base = (provider && provider.base_url) || settings.base_url || "";
  popFoot.textContent = base + (settings.database ? "  ·  " + settings.database : "");
}

async function post(path, body) {
  const response = await apiFetch(path, {
    method: "POST",
    headers: apiHeaders({ "Content-Type": "text/plain; charset=utf-8" }),
    body: body,
  });
  const payload = await response.json();
  settingsError.textContent=payload.error || '';
  if (!payload.error) {
    settings = { ...settings, ...payload };
    updateNodeLabel(settings.node_name, settings.node_worktree);
    updateChip();
    renderProviders();
    renderModels();
    renderContext();
    renderLimits();
    renderUsage();
    renderPopFoot();
  }
}

function setProvider(id) { return post("provider", id); }
function setModel(name) { return post("model", name); }

function renderAttachments() {
  attachmentsEl.replaceChildren();
  attachments.forEach((file, index) => {
    const chip = document.createElement("span");
    chip.className = "attachment" + (file.kind === "image" ? " attachment-image" : "");
    if (file.kind === "image") {
      const thumb = document.createElement("img");
      thumb.className = "attachment-thumb";
      thumb.src = file.data;
      thumb.alt = file.name;
      chip.append(thumb);
    }
    const name = document.createElement("b");
    name.textContent = file.name;
    const remove = document.createElement("button");
    remove.type = "button";
    remove.textContent = "×";
    remove.title = "Remove";
    remove.addEventListener("click", () => {
      // A removal by hand is worth undoing: it is the easiest way to lose a
      // pasted screenshot, and the chip is small enough to hit by accident.
      pushDraft();
      attachments.splice(index, 1);
      renderAttachments();
    });
    chip.append(name, remove);
    attachmentsEl.append(chip);
  });
}

// ---- composer undo/redo --------------------------------------------------
// What this undoes is the *draft*: the text you have typed and the files you
// have attached but not yet sent. It deliberately does not touch the
// transcript or the ledger - see DESIGN.md §12 for why that boundary is where
// it is. Nothing here can alter what the model has already seen.
const DRAFT_LIMIT = 50;
let draftUndo = [];
let draftRedo = [];
let draftNow = { text: "", attachments: [] };
// Every time the draft is *committed* - sent, or replaced wholesale by an undo - the
// generation moves on. A file read that began in an earlier generation belongs to a
// draft that no longer exists, and appending it to the composer is how a screenshot
// attached just before Enter reappears in the empty box afterwards.
let draftGeneration = 0;

function snapshotDraft() {
  return {
    text: input.value,
    // The attachment objects are treated as immutable once created (a chip is
    // removed, never edited in place), so a shallow copy is a real snapshot and
    // a deep clone would only copy base64 for nothing.
    attachments: attachments.slice(),
  };
}

function sameDraft(a, b) {
  if (a.text !== b.text) return false;
  if (a.attachments.length !== b.attachments.length) return false;
  for (let i = 0; i < a.attachments.length; i += 1) {
    if (a.attachments[i] !== b.attachments[i]) return false;
  }
  return true;
}

// Call *before* a change, so the stack holds the state to come back to.
//
// It pushes the state as it is *now*. Comparing against draftNow instead looked
// equivalent and was not: draftNow still equalled the current state at the moment of
// a change (the snapshot is taken before the mutation), so the check returned early
// and the change was never recorded. Removing a chip then pushed nothing, and undo
// jumped back past it to the state before the files were attached at all - losing the
// draft rather than restoring the chip. Deduping against the stack top keeps repeated
// calls from piling up identical entries.
function pushDraft() {
  const previous = draftNow;
  // Dedupe against the *stack top*, not against the current state. Comparing with the
  // current state looked equivalent and was not: at the moment of a change they are
  // usually still equal (the snapshot is taken before the mutation), so the check
  // returned early and the state to come back to was never recorded - removing a chip
  // pushed nothing, and undo jumped back past the attachments to an empty composer.
  const top = draftUndo[draftUndo.length - 1];
  if (!(top && sameDraft(top, previous))) {
    draftUndo.push(previous);
    if (draftUndo.length > DRAFT_LIMIT) draftUndo.shift();
  }
  // A fresh edit invalidates the redo branch, as in any editor.
  draftRedo = [];
  draftNow = snapshotDraft();
  syncUndoButtons();
}

function applyDraft(draft) {
  input.value = draft.text;
  draftGeneration += 1;
  attachments.length = 0;
  attachments.push(...draft.attachments);
  draftNow = { text: draft.text, attachments: draft.attachments.slice() };
  renderAttachments();
  autosize();
  syncUndoButtons();
}

function undoDraft() {
  if (draftUndo.length === 0) return false;
  const current = snapshotDraft();
  const previous = draftUndo.pop();
  draftRedo.push(current);
  applyDraft(previous);
  setStatus("undone - press Enter to send, Ctrl+Y to redo");
  return true;
}

function redoDraft() {
  if (draftRedo.length === 0) return false;
  const current = snapshotDraft();
  const next = draftRedo.pop();
  draftUndo.push(current);
  applyDraft(next);
  setStatus("redone");
  return true;
}

// There is no button to sync any more: the draft's undo/redo are the keyboard's, and a
// status line already reports what each one did ("undone - press Enter to send"). Kept as a
// named function because the callers describe an intent - "the stacks moved" - not a widget.
function syncUndoButtons() {}

// Stop means "stop on the node", not only "stop reading the stream". A client-side abort leaves the
// model call running and the ledger records an unfinished run. `POST /runs {action:cancel}` sets the
// run's own cancel flag, which the provider reader observes on the node; the abort then only stops
// this page reading. The request is fire-and-forget: the reader has already asked to stop, and the
// node reports the settled state in the ledger and `/health`.
function cancelActiveRun() {
  const thread = chatSession;
  if (thread && activeRunId === null && submittedRunIds) {
    // Admission and the next health poll can cross. Resolve the new id once more instead of
    // falling back to the route's default, which would cancel the older running turn.
    apiFetch("health", { headers: apiHeaders() }).then((response) => response.json()).then((health) => {
      identifySubmittedRun(health);
      if (activeRunId !== null) cancelRun(activeRunId);
      else setStatus("this run is still being admitted — try stop again in a moment");
    }).catch(() => setStatus("could not identify this run to stop it"));
    return;
  }
  cancelRun(activeRunId);
}

function cancelRun(runId) {
  const thread = chatSession;
  if (thread) {
    apiFetch("runs", {
      method: "POST",
      headers: apiHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ action: "cancel", thread, ...(runId === null ? {} : { run_id: runId }) }),
    }).catch(() => { /* the abort below is what the reader sees; the node still gets the request */ });
  }
  controller?.abort();
}

form.addEventListener("submit", (event) => {
  event.preventDefault();
  if (busy) {
    cancelActiveRun();
    return;
  }
  const text = input.value.trim();
  if (!text && attachments.length === 0) return;
  commandMenu.close();
  input.value = "";
  attachments.length = 0;
  draftGeneration += 1;
  // The draft has been sent, so there is nothing to undo *to*: keeping the
  // stack would let Ctrl+Z resurrect a draft that is already in the transcript,
  // and pressing Enter again would send it twice.
  draftUndo = [];
  draftRedo = [];
  draftNow = snapshotDraft();
  renderAttachments();
  syncUndoButtons();
  autosize();
  send(text);
});

input.addEventListener("keydown", (event) => {
  const accel = event.ctrlKey || event.metaKey;
  // While the command list is up it owns the arrows, Enter and Tab: a menu that offered choices
  // and then sent the half-typed command on Enter would be worse than no menu. Escape is left to
  // the overlay itself (§3), which is where the close rule lives.
  if (commandMenu.open && !accel) {
    if (event.key === "ArrowDown") { event.preventDefault(); commandMenu.move(1); return; }
    if (event.key === "ArrowUp") { event.preventDefault(); commandMenu.move(-1); return; }
    if (event.key === "Enter" || event.key === "Tab") {
      if (commandMenu.activate()) { event.preventDefault(); return; }
    }
  }
  // Ctrl+Z / Ctrl+Shift+Z / Ctrl+Y, the three spellings people actually use.
  // Only while the composer has focus, so we never shadow an undo a browser
  // context (a dialog, a native field) is entitled to handle itself.
  if (accel && event.key.toLowerCase() === "z") {
    event.preventDefault();
    if (event.shiftKey) redoDraft();
    else undoDraft();
    return;
  }
  if (accel && event.key.toLowerCase() === "y") {
    event.preventDefault();
    redoDraft();
    return;
  }
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    form.requestSubmit();
  }
});
function autosize() {
  input.style.height = "auto";
  input.style.height = Math.min(input.scrollHeight, 180) + "px";
}
// Group typing into one undo step: without this, every keystroke is its own
// entry and Ctrl+Z walks back one character at a time, which is not what the
// gesture means. A pause, or any non-typing change, starts a new step.
let typingTimer = null;
input.addEventListener("input", () => {
  autosize();
  if (typingTimer === null) pushDraft();     // first keystroke of a burst
  clearTimeout(typingTimer);
  typingTimer = setTimeout(() => { typingTimer = null; }, 600);
});

// ---- `/` commands ---------------------------------------------------------
//
// The composer is where the reader is already typing, so a command is a word typed into it
// rather than one more control in the footer - §9 keeps the footer for per-message actions
// (send, mic, attach). The panel is `<wa-menu>`, which already owns the §3 close rule and now
// owns keyboard selection too, so what a click would choose and what Enter chooses are the same
// item by construction.
const commandMenu = document.getElementById("command-menu");

// Only commands that can keep their promise. `/new` starts a thread; `/update` asks the node to
// install what is already built in its own tree - which the node cannot do to itself, so the honest
// answer is a *queued* request for the sentinel, and the notice says so. Nothing here deletes a
// transcript, because the ledger is append-only (§12) and a command that silently removed
// history would make the record a claim it cannot support.
// `/merge` is a brief for the agent, not a node operation: the worktrees, the branches and the gate
// live outside this process. The sentence mirrors `lua/core/merge.lua` (the CLI's copy); both point
// at the one skill, so the procedure cannot drift even though the trigger is written twice.
const ORCHESTRATOR_BRIEF = "Act as the git orchestrator for this repository. Audit every open branch, " +
  "merge the ones that merge clean into main one at a time, run the gate on the merged result, push, " +
  "sync the worktrees, and delete the merged change branches. Re-fetch and re-audit after the last " +
  "merge so a late lane is caught in the same run. Load skills/git-orchestrator for the procedure. " +
  "The AGENTS.md hand-off rule is suspended by this command: you may merge to main and enter the " +
  "other worktrees to converge them. Escalate a conflict; never force it.";

const COMMANDS = [
  {
    name: "/new",
    hint: "start a new session — this window's transcript is cleared, the old thread is not touched",
    run: newThread,
  },
  {
    name: "/update",
    hint: "install the newest build in this node's tree — the sentinel does it once the node is idle",
    run: updateNode,
  },
  {
    name: "/merge",
    hint: "act as git orchestrator — merge every open branch into main, gate, push, sync",
    run: () => { send(ORCHESTRATOR_BRIEF); },
  },
];

// A thread is named by whoever starts it. The id is made here rather than asked for, so the name
// the window holds is the name the node stores, with no round trip in which the node could answer
// "started" and hand back something else.
function newId() {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") return crypto.randomUUID();
  const bytes = new Uint8Array(16);
  if (typeof crypto !== "undefined" && crypto.getRandomValues) crypto.getRandomValues(bytes);
  else for (let i = 0; i < bytes.length; i += 1) bytes[i] = Math.floor(Math.random() * 256);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

// `/update` asks the node to install the newest build of its own tree.
//
// It cannot install anything from here: the node is the process being replaced, and the sentinel is
// the only thing that stops or starts it. So the node answers with a report, the report says
// `queued` (not "done"), and this shows that sentence rather than inventing a second wording for it.
// A refusal - nothing built, no tree, no sentinel - is displayed with what was seen and where to go.
async function updateNode() {
  const notice = document.createElement("div");
  notice.className = "thread-notice";
  notice.textContent = "/update — asking the node what it runs and what its tree holds…";
  messages.append(notice);
  pin();
  try {
    const response = await apiFetch("update", {
      method: "POST",
      headers: apiHeaders({ "Content-Type": "application/json" }),
      body: "{}",
    });
    const payload = await response.json();
    notice.textContent = updateNotice(payload);
    notice.dataset.state = payload && payload.queued ? "queued" : payload && payload.ok === false ? "refused" : "current";
  } catch (error) {
    notice.textContent = "/update could not be asked: " + String(error);
    notice.dataset.state = "refused";
  }
  pin();
}

// The wording lives in the node (`lua/core/update.lua`), so the window and `wa chat` cannot drift
// into saying two different things about the same answer. This only has to cope with a node that
// answered in a shape it does not recognise.
function updateNotice(payload) {
  if (!payload || typeof payload !== "object") return "/update: the node did not answer with a report.";
  const message = payload.message || "";
  const tail = payload.next ? " " + payload.next : "";
  if (message) return "/update — " + message + tail;
  if (payload.queued) return "/update — queued: the sentinel will install it once this node is idle." + tail;
  return "/update — refused: " + (payload.observed || payload.error || "no reason given") + tail;
}

// Start a thread with nothing in it.
//
// Nothing is deleted. The thread being left behind is still in the ledger and still listed in the
// engine view, which is why the notice says so: an empty transcript with no explanation reads as
// "the work is gone", and it is not.
function newThread() {
  rememberSession(newId());
  repaintMessages([]);
  clearStatus();
  const notice = document.createElement("div");
  notice.className = "thread-notice";
  notice.textContent = "new session — nothing from the previous thread carries over here. " +
    "That thread is unchanged and still listed in the engine view.";
  messages.append(notice);
  pin();
}

// `/` opens the list; anything else typed after it filters. A newline ends the command line and
// closes it, so a message that merely starts with a slash is not trapped.
function commandMatches(value) {
  if (value[0] !== "/" || value.includes("\n")) return [];
  const typed = value.slice(1).trim().toLowerCase();
  return COMMANDS.filter((command) => command.name.slice(1).startsWith(typed));
}

function syncCommands() {
  const matches = commandMatches(input.value);
  if (!matches.length) { commandMenu.close(); return; }
  const rect = input.getBoundingClientRect();
  commandMenu.items = matches.map((command) => ({
    label: `${command.name}  —  ${command.hint}`,
    action: () => {
      // The draft as it stands (with the command typed in it) is what Ctrl+Z comes back to, so
      // the command is pushed *before* the text is taken away.
      pushDraft();
      input.value = "";
      draftNow = snapshotDraft();
      autosize();
      command.run();
    },
  }));
  commandMenu.openAt(rect.left, rect.top, { above: true, inset: 5 });
  // The first match is chosen before any arrow key is pressed, so the list shows what Enter is
  // about to do instead of waiting to be told.
  commandMenu.move(1);
}
input.addEventListener("input", syncCommands);
window.addEventListener("resize", () => requestAnimationFrame(autosize));

messages.addEventListener("click", (event) => {
  const prompt = event.target?.dataset?.prompt;
  if (prompt) send(prompt);
});

// ---- status balloon (provider + model + usage) ---------------------------
statusBtn.addEventListener("click", () => {
  balloon.toggle();
  statusBtn.setAttribute("aria-expanded", String(balloon.open));
  if (balloon.open) {
    refreshNodes();
    refreshMeta();
    renderProviders();
    renderModels();
    renderContext();
    renderLimits();
    renderUsage();
    renderPopFoot();
  }
});
balloon.addEventListener("close", () => statusBtn.setAttribute("aria-expanded", "false"));
providerSelect.addEventListener("change", () => setProvider(providerSelect.value));
modelSelect.addEventListener("change", () => setModel(modelSelect.value));
reasoningSelect.addEventListener('change',()=>post('reasoning',reasoningSelect.value).catch(error=>{settingsError.textContent=String(error);}));
harnessStatus.addEventListener('export',async event=>{
  settingsError.textContent='Exporting recorded events…';
  try {
    const id=event.detail.scope==='node' ? '*' : settings.observability.session_id;
    const since=Math.floor(Date.now()/1000)-172800, events=[];
    let cursor=0, page;
    do {
      const query=new URLSearchParams({id,cursor:String(cursor),since:String(since)});
      page=await (await apiFetch('observability/events?'+query,{headers:apiHeaders()})).json();
      if (page.error) throw new Error(page.error);
      events.push(...page.events);
      if (page.has_more && page.next_cursor<=cursor) throw new Error('export cursor did not advance');
      cursor=page.next_cursor;
    } while (page.has_more);
    const data={schema_version:1,exported_at:new Date().toISOString(),scope:event.detail.scope,
      since:event.detail.scope==='node' ? since : null,node:page.node_name,runtime:page.runtime,events};
    const url=URL.createObjectURL(new Blob([JSON.stringify(data,null,2)],{type:'application/json'}));
    const a=document.createElement('a'); a.href=url; a.download='wasm-harness-'+event.detail.scope+'-'+Date.now()+'.json';
    a.click(); setTimeout(()=>URL.revokeObjectURL(url),1000);
    settingsError.textContent=`Exported ${events.length} events. No task-quality judgment included.`;
  } catch(error) { settingsError.textContent='Export failed: '+String(error); }
});
nodeSelect.addEventListener("change", async () => {
  const value = nodeSelect.value;
  const local = nodeList.find((node) => node.name === value && node.local_node && node.kind === "host");
  activeNode = local ? "" : value;
  localStorage.setItem("wa-node", activeNode);
  await refreshMeta();
  renderProviders();
  renderModels();
});

// ---- voice input ---------------------------------------------------------
function setupVoice() {
  const Recognition = window.SpeechRecognition || window.webkitSpeechRecognition;
  if (!Recognition) {
    micButton.disabled = true;
    micButton.title = "Voice input is not available in this browser";
    return;
  }
  recognition = new Recognition();
  recognition.continuous = false;
  recognition.interimResults = true;
  recognition.lang = navigator.language || "en-US";
  recognition.onstart = () => {
    recognizing = true;
    micButton.classList.add("listening", "active");
  };
  const stop = () => {
    recognizing = false;
    micButton.classList.remove("listening", "active");
  };
  recognition.onend = stop;
  recognition.onerror = stop;
  recognition.onresult = (event) => {
    let transcript = "";
    for (const result of event.results) transcript += result[0].transcript;
    input.value = voicePrefix + transcript;
    autosize();
  };
  micButton.addEventListener("click", () => {
    if (recognizing) {
      recognition.stop();
    } else {
      voicePrefix = input.value ? input.value + " " : "";
      try { recognition.start(); } catch (error) { /* already started */ }
    }
  });
}

// ---- file append ---------------------------------------------------------
// Two kinds of attachment ride through here. Text files keep the original
// behaviour: read as UTF-8, inlined into the prompt. Images are sent as
// structured parts so the model can actually see them, and are handled by the
// server (stored content-addressed, referenced from the run).
const IMAGE_TYPES = ["image/png", "image/jpeg", "image/webp", "image/gif"];

function isImage(file) {
  return IMAGE_TYPES.includes((file.type || "").toLowerCase());
}

function readAsDataURL(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result || ""));
    reader.onerror = () => reject(reader.error || new Error("read_failed"));
    reader.readAsDataURL(file);
  });
}

// One path for every way a file can arrive - the attach button, a paste, a drop
// - so the three cannot drift apart in what they accept or how they name it.
// Returns what it took and what it refused, so a caller can report accurately
// instead of announcing success over a rejection.
// The draft moved on while this file was being read. Say so: a file the user attached
// that quietly does not appear is worse than one that explains why it did not.
function discard(file, before) {
  setStatus(`the draft was sent while ${file.name} was reading - it was not attached`);
  // Files earlier in the same batch may already have been attached, so the state to
  // undo back to is the one from before the batch - but only if anything changed,
  // or the stack collects an entry that does nothing.
  if (!sameDraft(before, snapshotDraft())) {
    draftUndo.push(before);
    draftNow = snapshotDraft();
    syncUndoButtons();
  }
  renderAttachments();
  return { added: 0, refused: 0 };
}

async function addFiles(files) {
  let added = 0;
  let refused = 0;
  // One snapshot for the whole batch: undoing a three-file drop one file at a
  // time would make Ctrl+Z feel broken. Captured before the first await, so a
  // slow read still leaves the pre-drop state on the stack.
  const before = snapshotDraft();
  const generation = draftGeneration;
  for (const file of files) {
    if (isImage(file)) {
      try {
        const dataUrl = await readAsDataURL(file);
        if (generation !== draftGeneration) return discard(file, before);
        attachments.push({ kind: "image", name: file.name, mime: file.type, data: dataUrl });
        added += 1;
      } catch (error) {
        // A picture we could not read must not vanish silently.
        setStatus(`could not read ${file.name}`);
      }
      continue;
    }
    if ((file.type || "").startsWith("image/")) {
      // An image type we do not accept (bmp, tiff, svg). Sending it would fail
      // at the provider; refusing it here says why.
      refused += 1;
      continue;
    }
    try {
      const text = await file.text();
      if (generation !== draftGeneration) return discard(file, before);
      attachments.push({ kind: "text", name: file.name, text: text.slice(0, 20000) });
    } catch (error) {
      attachments.push({ kind: "text", name: file.name, text: "" });
    }
    added += 1;
  }
  if (refused > 0) {
    setStatus(`${refused} image(s) skipped - only png, jpeg, webp and gif are accepted`);
  } else if (added > 0) {
    setStatus(`${added} file(s) attached - press Enter to send`);
  }
  // Only record a step if the batch actually changed something: a refused-only
  // drop must not add an undo entry that appears to do nothing.
  if (added > 0 && !sameDraft(before, snapshotDraft())) {
    draftUndo.push(before);
    if (draftUndo.length > DRAFT_LIMIT) draftUndo.shift();
    draftRedo = [];
    draftNow = snapshotDraft();
  }
  renderAttachments();
  syncUndoButtons();
  return { added, refused };
}

attachButton.addEventListener("click", () => fileInput.click());
fileInput.addEventListener("change", async () => {
  await addFiles(fileInput.files);
  fileInput.value = "";
});

// ---- paste (Ctrl+V) ------------------------------------------------------
// A screenshot pasted from the clipboard arrives as a blob with no filename, so
// give it one: an unnamed chip would be unreadable, and the name is what the
// run shows the model.
input.addEventListener("paste", async (event) => {
  const data = event.clipboardData;
  if (!data) return;
  const files = [];
  for (const item of data.items || []) {
    if (item.kind !== "file") continue;
    const file = item.getAsFile();
    if (!file) continue;
    files.push(file);
  }
  if (files.length === 0) return;   // ordinary text paste: let it through
  event.preventDefault();
  const stamped = files.map((file, index) => {
    if (file.name && file.name !== "image.png") return file;
    const extension = (file.type || "").split("/")[1] || "png";
    const suffix = files.length > 1 ? `-${index + 1}` : "";
    return new File([file], `pasted${suffix}.${extension}`, { type: file.type });
  });
  await addFiles(stamped);
});

// ---- drag and drop -------------------------------------------------------
// The whole panel is a target, not just the 45px textarea: dropping onto a
// window that looks like it accepts files and having nothing happen is worse
// than having no drop target at all.
let dragDepth = 0;

function hasFiles(event) {
  const types = event.dataTransfer?.types;
  return types ? Array.from(types).includes("Files") : false;
}

panel.addEventListener("dragenter", (event) => {
  if (!hasFiles(event)) return;
  event.preventDefault();
  dragDepth += 1;
  panel.classList.add("dropping");
});

panel.addEventListener("dragover", (event) => {
  if (!hasFiles(event)) return;
  // Without preventDefault on dragover the browser refuses the drop entirely.
  event.preventDefault();
  event.dataTransfer.dropEffect = "copy";
});

panel.addEventListener("dragleave", (event) => {
  if (!hasFiles(event)) return;
  dragDepth = Math.max(0, dragDepth - 1);
  if (dragDepth === 0) panel.classList.remove("dropping");
});

panel.addEventListener("drop", async (event) => {
  if (!hasFiles(event)) return;
  event.preventDefault();
  dragDepth = 0;
  panel.classList.remove("dropping");
  const files = Array.from(event.dataTransfer.files || []);
  if (files.length === 0) return;
  await addFiles(files);
});

// ---- account -------------------------------------------------------------
function initials(name) {
  return (name || "?").trim().slice(0, 2);
}

// The account picture, if one was chosen. It replaces the initials inside the same rounded icon,
// so the pill keeps its shape either way. Kept in localStorage: it belongs to this window's
// reader rather than to the node, and nothing here is worth a server round trip.
const AVATAR_KEY = "wa-avatar";

function accountPicture() {
  try { return localStorage.getItem(AVATAR_KEY) || ""; } catch (error) { return ""; }
}

function renderAvatar(name) {
  const picture = accountPicture();
  userAvatar.replaceChildren();
  if (picture) {
    const image = document.createElement("img");
    image.className = "user-avatar-img";
    image.src = picture;
    image.alt = "";
    userAvatar.append(image);
    userAvatar.classList.add("has-picture");
    return;
  }
  userAvatar.classList.remove("has-picture");
  userAvatar.textContent = initials(name);
}

function renderUser() {
  const user = me.user || { name: "guest" };
  renderAvatar(user.name || user.id);
  // The tooltip names the *node*, because that is what this window is at, and how much it may do
  // there. The account name is the same for everyone on a local-first node, so it said nothing.
  const tools = (me.tools || []).length;
  userBtn.title = "Signed in as " + (settings.node_name || "this node") + " · " + tools + " tools";
  userBtn.setAttribute("aria-label", userBtn.title);
  userBtn.classList.toggle("local", me.role !== "master");
}

async function refreshMe() {
  try {
    const response = await apiFetch("me", { headers: apiHeaders() });
    const payload = await response.json();
    if (payload.error) return false;
    me = payload;
    renderUser();
    return true;
  } catch (error) {
    // Report rather than swallow: the caller decides whether to retry.
    return false;
  }
}

async function pickPicture() {
  const input = document.createElement("input");
  input.type = "file";
  input.accept = "image/*";
  input.addEventListener("change", async () => {
    const file = (input.files || [])[0];
    if (!file) return;
    try {
      localStorage.setItem(AVATAR_KEY, await squareThumbnail(file));
      renderUser();
    } catch (error) {
      setStatus("could not read that picture: " + error);
    }
  });
  input.click();
}

function clearPicture() {
  try { localStorage.removeItem(AVATAR_KEY); } catch (error) { /* nothing to remove */ }
  renderUser();
}

// Downscaled before it is stored: this lives in localStorage, the icon is 20px, and an unshrunk
// photo would both fill the quota and be thrown away by the display. Square and centre-cropped,
// so the round icon does not squash it.
async function squareThumbnail(file, size = 200) {
  const bitmap = await createImageBitmap(file);
  const side = Math.min(bitmap.width, bitmap.height);
  const canvas = document.createElement("canvas");
  canvas.width = size;
  canvas.height = size;
  const context = canvas.getContext("2d");
  context.drawImage(bitmap, (bitmap.width - side) / 2, (bitmap.height - side) / 2, side, side, 0, 0, size, size);
  bitmap.close();
  return canvas.toDataURL("image/jpeg", 0.85);
}

// Switch Node: which node this window talks to, and therefore where work happens. It belongs with
// the other identity controls rather than in the provider balloon, which is about the model.
function switchNodeControl() {
  const row = document.createElement("div");
  row.className = "menu-item muted menu-node";
  const label = document.createElement("span");
  label.className = "menu-node-label";
  label.textContent = "switch node";
  // Draw what is known, then ask. The node list used to be fetched only when the engine's nodes
  // topic was opened, so this row would have been an empty box for anyone who had not been there
  // - a control that does nothing until you have already done something else.
  renderNodeSelect();
  refreshNodes();
  row.append(label, nodeSelect);
  return row;
}

function openUserMenu() {
  // Three things about this window's identity, and nothing else: who the node is, what it looks
  // like, and which node it is. The binding line that used to open this balloon said
  // "master · master" and told nobody anything.
  const items = [
    // Who this window is talking to, and what that node calls itself.
    { element: nodeControl() },
    { label: "Change Picture", action: () => pickPicture() },
  ];
  // Offered only when there is one to remove, so the balloon does not grow a row that does
  // nothing - but offered, because a picture with no way back is a trap.
  if (accountPicture()) items.push({ label: "Remove Picture", action: () => clearPicture() });
  items.push({ element: switchNodeControl() });
  // Open with what is already known: the node control has nothing to wait for, and a balloon
  // that appears only after a round trip feels broken when the round trip is slow.
  userMenu.items = items;
  const rect = userBtn.getBoundingClientRect();
  userMenu.openAt(rect.left, rect.top, { above: true, inset: 5 });
  userBtn.setAttribute("aria-expanded", "true");
}

async function refreshMeta() {
  try {
    const query=new URLSearchParams({session_id:chatSession});
    if (activeNode) query.set('node',activeNode);
    const response = await apiFetch("models?"+query, { headers: apiHeaders() });
    const payload = await response.json();
    settings = { ...settings, ...payload };
    updateNodeLabel(settings.node_name, settings.node_worktree);
    // The account tooltip names the node, so it follows the same payload.
    renderUser();
    updateChip();
    if (balloon.open) {
      renderProviders();
      renderModels();
      renderContext();
      renderLimits();
      renderUsage();
      renderPopFoot();
    }
    const provider = activeProvider();
    const label = provider ? provider.label : "local";
    const where = activeNode || "local";
    meta.textContent = `${where} · ${label} · ${payload.model}`;
    return true;
  } catch (error) {
    meta.textContent = "offline";
    return false;
  }
}

// Hot reload, in two halves.
//
// A stylesheet can be replaced under a running run with no state lost, so styling changes
// - the common case - never need a reload at all. Markup and JS cannot: a reload mid-run
// throws away the page's copy of a reply that is still arriving. Those wait for the run to
// finish, and say so while they wait.
let pendingReload = false;
// Every reload goes through here, so every reload can save where the reader was first.
let reload = () => { rememberPlace(); location.reload(); };

// ---- the update lock ------------------------------------------------------
//
// A UI update is invisible: the page keeps working while new files sit on disk, and then it reloads
// at a moment the reader did not choose. Saying so - and saying *why now* - is the difference
// between "the window flickered and lost my place" and "the window told me it was updating".
//
// It is a lock rather than a toast because it covers the panel: a run is still running behind it,
// and the reader should not be typing into a page that is about to be replaced. It is escapable -
// reload now, or dismiss and let the reload land when the run finishes.
function updateLock(reason) {
  let lock = document.getElementById("update-lock");
  if (!lock) {
    lock = document.createElement("div");
    lock.id = "update-lock";
    lock.innerHTML = '<div class="lock-card"><div class="lock-title">UI updating</div>' +
      '<div class="lock-reason"></div><div class="lock-actions">' +
      '<button type="button" class="lock-now">reload now</button>' +
      '<button type="button" class="lock-later">keep working</button></div></div>';
    lock.querySelector(".lock-now").addEventListener("click", () => { rememberPlace(); location.reload(); });
    lock.querySelector(".lock-later").addEventListener("click", () => lock.remove());
    document.body.append(lock);
  }
  lock.querySelector(".lock-reason").textContent = reason;
  return lock;
}

// Where the reader was: the scroll offset, whether they were following the bottom, and which engine
// topics were open. A reload that lands at the bottom of a long thread is a different page from the
// one that was there a moment ago, and "fresh" should not mean "moved".
const PLACE_KEY = "wa-place";

function rememberPlace() {
  try {
    const topics = [];
    for (const box of document.querySelectorAll(".engine-content")) {
      if (!box.hidden && box.id) topics.push(box.id);
    }
    sessionStorage.setItem(PLACE_KEY, JSON.stringify({
      session: chatSession,
      top: messages.scrollTop,
      following: follow,
      topics: topics,
    }));
  } catch (error) { /* private mode: the reload still happens */ }
}

function restorePlace() {
  let place = null;
  try { place = JSON.parse(sessionStorage.getItem(PLACE_KEY) || "null"); } catch (error) { place = null; }
  if (!place) return;
  try { sessionStorage.removeItem(PLACE_KEY); } catch (error) { /* nothing to remove */ }
  for (const id of place.topics || []) {
    const box = document.getElementById(id);
    if (box && box.hidden) document.querySelector('[data-target="' + id + '"]')?.click();
  }
  // Following the bottom is a position too, and the default: only a reader who had scrolled away
  // needs the offset put back.
  if (place.following) { setFollow(true); pin(true); }
  else if (typeof place.top === "number") { setFollow(false); messages.scrollTop = place.top; }
}

function hotSwapStyles() {
  for (const link of document.querySelectorAll('link[rel="stylesheet"]')) {
    const url = new URL(link.href, location.href);
    url.searchParams.set("v", String(Date.now()));
    // Load the replacement first and only then drop the old one: rewriting the href of the
    // live link leaves the page unstyled for as long as the new sheet takes to arrive.
    const next = link.cloneNode();
    next.href = url.toString();
    next.addEventListener("load", () => link.remove(), { once: true });
    link.after(next);
  }
}

// Split out from the polling so the step can be driven directly: the step is the
// part worth testing, not the fetch around it.
function applyUiVersion(next) {
  if (version === null) { version = next; return "init"; }
  if (next === version) return "same";
  version = next;
  hotSwapStyles();
  if (busy) {
    pendingReload = true;
    setStatus("update ready - reloading when this run finishes");
    updateLock("A run is running, so the reload waits for it to finish. Your place and your draft are kept.");
    return "deferred";
  }
  updateLock("Reloading now - your place and your draft are kept.");
  reload();
  return "reloading";
}

// ---- staying in sync ------------------------------------------------------
//
// A window must never sit in a state that will not change by itself, and it did: when the node was
// briefly away at load - a restart, a slow start - the first /me and /models failed, nothing
// retried them, and the footer said "connecting…" for the life of the page while the node was fine.
// The chat was empty for the same reason: the transcript is restored *after* the node answers, and
// it never did.
//
// The version poll already runs every second and is the one loop that always runs, so recovery
// belongs there: it was always the liveness signal, it just never said so. Nothing here keeps a
// retry timer of its own - one recovery path, not two.
let synced = false;
let syncRunning = false;
let syncAttempts = 0;

function setConnecting(label) {
  // Say what is true and that it is being worked on. "connecting…" forever reads as broken, and
  // "offline" with no retry reads as final. A node that is alive and inside a run is neither: it is
  // busy, and it will answer when the run ends.
  const text = label || (syncAttempts > 2 ? "node offline — retrying" : "connecting…");
  chipModel.textContent = text;
  meta.textContent = text;
}

/// The node's own answer, which is served without the interpreter - so it works exactly when the Lua
/// routes do not, which is while a run is running. Null means the node really is not answering.
async function nodeHealth() {
  try {
    return await (await apiFetch("health", { headers: apiHeaders() })).json();
  } catch (error) {
    return null;
  }
}

async function sync(reason) {
  if (synced || syncRunning) return;
  syncRunning = true;
  syncAttempts += 1;
  const meOk = await refreshMe();
  const metaOk = await refreshMeta();
  syncRunning = false;
  if (!meOk || !metaOk) {
    // Why it failed decides what to say. A reload during a run used to show "connecting…" and then
    // "node offline — retrying" on a node that was working perfectly, and the transcript stayed empty
    // because the restore never ran. It cannot run while the run holds the interpreter - that is
    // physical on a single-worker node - but the message can be true, and the retry does the rest.
    const health = await nodeHealth();
    if (activeRun(health)) {
      syncAttempts = 0;
      setConnecting("the node is running a run — this window returns when it finishes");
    } else if (health) {
      // The node answered, so it is not offline - it is busy, and the reads this window needs
      // (`/me`, `/models`, the transcript) queue behind the run because one interpreter serves
      // them. Calling that "offline" was a lie the reader could not check: the node was local,
      // alive, and running their command. Only a node that does not answer at all is offline.
      syncAttempts = 0;
      setConnecting("the node is busy — this window returns when it can answer");
    } else {
      setConnecting();
    }
    return;
  }
  synced = true;
  syncAttempts = 0;
  clearStatus();
  // The transcript is restored once, and only after the node has answered - then the reader's place
  // is put back on top of it, because "fresh" should not mean "moved". Whether a run is still
  // running is reconciled by `watch`, which keeps asking; one check here would only cover the first
  // reconnection.
  restoreSession().then(restorePlace);
}

// A window must never be more certain than the node.
//
// If the node says nothing is running, then nothing is - however sure the page was a moment ago. A
// run that died with the node left the composer disabled and a stop button showing, and the only way
// out was a manual reload: that is the "locked" window, and it is not a state a reader should have to
// escape. This is also what makes a reinstall feel seamless - the node goes away, comes back, and the
// chat is usable again without anyone clicking anything.
let reconciling = false;
let reconciledAt = 0;

async function reconcile() {
  if (reconciling || !synced) return;
  reconciling = true;
  try {
    const health = await (await apiFetch("health", { headers: apiHeaders() })).json();
    if (health && !activeRun(health)) {
      // What the live DOM still believes is worth checking *before* clearing it: if the page thought a message was
      // running, then whatever it is still showing - a tool topic waiting for a result that already arrived,
      // a segment that never got its reply - is stale.
      const wasLive = busy || document.getElementById("update-lock") || trace?.pending;
      if (busy) { setBusy(false); clearStatus(); }
      // Nothing to wait for any more, so the lock must not wait either: it is a message, not a trap.
      document.getElementById("update-lock")?.remove();
      // And a notice about a run that is over is litter: take it down.
      clearStreamNotice();
      // The node says the run is over, so the ledger is the authority - repaint from it. This is exactly what
      // a reload does, and it is why a reload fixed it: a tool whose result arrived while the stream was gone
      // stays open in the live DOM forever, because the only thing that settles a tool is its own event.
      // Measured: the run had finished, the answer was in the ledger, and the window still said "deciding…"
      // until Ctrl+R. A window must never be more certain than the node.
      if (wasLive) restoreSession();
    }
  } catch (error) { /* the node is away; watchNode says so in the chat */ }
  reconciling = false;
}

async function watch() {
  try {
    const response = await apiFetch("version");
    const payload = await response.json();
    // Tell the shell this page's loop is alive. It is the only per-window proof: the node's page-age
    // counter is global, and WebView2 reports a failed navigation as "finished", so a shell cannot tell
    // an error page from a good one by the load alone. A page stuck on an error page cannot send this,
    // which is exactly what the shell watches for.
    if (native && typeof native.heartbeat === "function") native.heartbeat();
    applyUiVersion(payload.version);
    // The node answered, so finish the first sync if it never finished. This loop always runs.
    if (!synced) sync("watch");
    else if (!transcriptReady) restoreSession();
    // A live stream or update lock needs reconciliation. A durable unfinished notice does not:
    // polling and repainting an interrupted transcript forever would waste reads and restart its view.
    else if (busy || document.getElementById("update-lock") || trace?.pending) {
      if (Date.now() - reconciledAt > 5000) { reconciledAt = Date.now(); reconcile(); }
    }
  } catch (error) { /* keep polling: the deadline is what keeps this loop alive */ }
  setTimeout(watch, 1000);
}

// The node owns the run; the browser only watches it. If one was running when this page
// loaded - a reload mid-run, or a reconnection after the node was busy - the reply is
// already in the ledger, so refresh the transcript once it is no longer in flight instead
// of making the reader reload to see it.
let sawTurnInFlight = false;
let runPolling = false;
// The thread's `last_seq` as of the last redraw, so a poll redraws only when the run moved.
let followedSeq = null;

// A run in flight that this window did NOT open - a reload during a run, or one a wake or a job
// started - has no live channel: the node streams a run only to the request that opened it. The
// ledger is a channel, and /session answers while the run is in flight (measured: 200 in ~500ms
// against a running turn), so the window follows the run by re-reading it. Without this the
// transcript sat frozen for the whole run and the reader reloaded to see anything - and the reload
// showed the same frozen snapshot, because a reload does not reattach to a run either (measured:
// 40s of node work, 0 bytes of page change).
async function followRun() {
  if (!chatSession) return;
  // /sessions is small and carries the thread's `last_seq`; the 1.5 MB /session read happens only
  // when there is something new. Redrawing an unchanged transcript would cost a megabyte every
  // three seconds and fight the reader's scroll for nothing.
  const list = await (await apiFetch("sessions", { headers: apiHeaders() })).json();
  const mine = (list.sessions || []).find((entry) => entry.id === chatSession);
  if (!mine) return;
  const seq = Number(mine.last_seq) || 0;
  if (seq === followedSeq) return;
  followedSeq = seq;
  rememberPlace();
  await restoreSession();
  restorePlace();
}

async function watchTurn() {
  // One at a time: a poll that has not answered yet is not a reason to start another, and on a
  // single-worker node that is the difference between asking and queueing.
  if (runPolling) { setTimeout(watchTurn, 3000); return; }
  runPolling = true;
  try {
    const response = await apiFetch("health");
    const health = await response.json();
    const current = activeRun(health);
    if (current) {
      sawTurnInFlight = true;
      // Only when this window is not streaming the run itself: `busy` means its own stream is
      // drawing it live, and a repaint under a live stream would fight it for the same bubble.
      if (!busy) await followRun();
    } else if (sawTurnInFlight) {
      sawTurnInFlight = false;
      if (chatSession) {
        rememberPlace();
        await restoreSession();
        restorePlace();
      }
    }
  } catch (error) { /* the node is down; watchNode handles that */ }
  runPolling = false;
  setTimeout(watchTurn, 3000);
}

// ---- native companion window (wa-window / WebView2) ----------------------
// `let`, not `const`: the harness runs the page with no shell on purpose (to prove the page degrades), and
// a test that wants to prove the *window* path has to be able to hand it one. Same seam as `reload`.
let native = window.wasmAgent || null;
const orb = document.getElementById("orb");
const collapse = document.getElementById("collapse");
const dragbar = document.getElementById("dragbar");

function applyMode(mode) {
  document.body.classList.toggle("compact", mode === "compact");
  document.body.classList.toggle("expanded", mode === "expanded");
  try { localStorage.setItem("wa-mode", mode); } catch (error) { /* private mode */ }
}
// Keep the page and the window in step across hot reloads: restore the last mode
// and ask the shell to size itself to match.
const initialMode = native ? (localStorage.getItem("wa-mode") || "compact") : "expanded";
applyMode(initialMode);
if (native && initialMode === "expanded") requestAnimationFrame(() => native.expand());

orb?.addEventListener("click", () => {
  applyMode("expanded");
  requestAnimationFrame(autosize);
  native?.expand();
});
collapse?.addEventListener("click", () => { applyMode("compact"); native?.compact(); });

let dragDown = null;
function wireDrag(element) {
  if (!element || !native) return;
  element.addEventListener("pointerdown", (event) => {
    if (event.target.closest("button, a, textarea, input, select, wa-balloon")) return;
    dragDown = { x: event.clientX, y: event.clientY };
  });
  element.addEventListener("pointermove", (event) => {
    if (!dragDown) return;
    if (Math.hypot(event.clientX - dragDown.x, event.clientY - dragDown.y) > 4) {
      dragDown = null;
      native.drag();
    }
  });
  element.addEventListener("pointerup", () => { dragDown = null; });
}
wireDrag(orb);
wireDrag(dragbar);

// ---- nodes + remote control ---------------------------------------------
let controlTimer = null;
let controlPending = false;
let controlCanvasSize = { w: 0, h: 0 };
let controlScreen = { w: 0, h: 0 };

function b64ToBytes(base64) {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

async function clientAction(payload) {
  const response = await apiFetch("client", {
    method: "POST",
    headers: apiHeaders({ "Content-Type": "application/json" }),
    body: JSON.stringify(payload),
  });
  return response.json();
}

function nodeButton(label, handler) {
  const button = document.createElement("button");
  button.type = "button";
  button.textContent = label;
  button.addEventListener("click", handler);
  return button;
}

// The one place the label is drawn, so the balloon, the engine and the settings cannot
// disagree about what this node is called.
function updateNodeLabel(name, worktree) {
  if (name) settings.node_name = name;
  if (worktree !== undefined) settings.node_worktree = worktree;
  const button = document.getElementById("node-name-btn");
  if (!button) return;
  button.textContent = settings.node_name || "…";
  button.title = nodeTitle();
}

// A guest node owns no worktree, so its title says what it is instead of leaving a blank where
// a checkout would be. The role comes from the same payload as the name (GET /models), so the
// two can never disagree.
function nodeTitle() {
  if (settings.node_role === "guest") {
    return "guest node — no worktree of its own — click to rename";
  }
  return settings.node_worktree
    ? "running in " + settings.node_worktree + " — click to rename"
    : "click to rename";
}

// The node's own row in the account balloon: its name, editable in place.
function nodeControl() {
  const row = document.createElement("div");
  row.className = "menu-item muted menu-node";
  const label = document.createElement("span");
  label.className = "menu-node-label";
  label.textContent = "node";
  const button = document.createElement("button");
  button.type = "button";
  button.id = "node-name-btn";
  button.className = "menu-node-name";
  button.textContent = settings.node_name || "…";
  button.title = nodeTitle();
  button.addEventListener("click", () => editNodeName(button));
  row.append(label, button);
  return row;
}

function editNodeName(button) {
  if (!button || button.dataset.editing === "1") return;
  button.dataset.editing = "1";
  const current = button.textContent;
  const field = document.createElement("input");
  field.className = "node-rename";
  field.value = current === "…" ? "" : current;
  field.setAttribute("aria-label", "Node name");
  button.replaceWith(field);
  field.focus();
  field.select();
  let settled = false;
  const finish = (save) => {
    if (settled) return;
    settled = true;
    const next = field.value.trim();
    field.replaceWith(button);
    button.dataset.editing = "";
    if (!save) return;
    // A node with no name is worse than a node with a boring one: keep what it had and say why.
    if (!next) {
      setStatus("a node needs a name");
      return;
    }
    if (next !== current) saveNodeName(next);
  };
  field.addEventListener("keydown", (event) => {
    if (event.key === "Enter") { event.preventDefault(); finish(true); }
    else if (event.key === "Escape") { event.preventDefault(); finish(false); }
  });
  field.addEventListener("blur", () => finish(true));
}

// Rename this node. The name is the node's, not this window's: it goes to the node, every
// other window is told over the event stream, and the label is redrawn from what the node
// reports.
async function saveNodeName(name) {
  const next = String(name || "").trim();
  if (!next) { setStatus("a node needs a name"); return; }
  updateNodeLabel(next);   // the edit should feel immediate; the node is the truth
  try {
    const response = await apiFetch("node/name", {
      method: "POST",
      headers: apiHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ name: next }),
    });
    const payload = await response.json();
    if (payload && payload.error) setStatus("could not rename the node: " + payload.error);
  } catch (error) {
    setStatus("could not rename the node: the node is not answering");
  }
  await refreshNodes();
}

async function refreshNodes() {
  try {
    const payload = await (await apiFetch("nodes", { headers: apiHeaders() })).json();
    nodeList = payload.nodes || [];
    renderNodeSelect();
    nodesBinding.textContent = payload.binding || "";
    nodesBox.replaceChildren();
    let desktopNode = null;
    let hostRow = null;
    for (const node of payload.nodes || []) {
      const row = document.createElement("div");
      row.className = "node" + (node.online ? " online" : "");
      const dot = document.createElement("span");
      dot.className = "node-dot";
      const name = document.createElement("span");
      name.className = "node-name";
      name.textContent = node.name;
      // Which of these is the window talking to? Without it a list of four nodes is four
      // names and no way to tell which one this is.
      // The client executor is not a second node: it is the desktop this node's window runs
      // on, so its state belongs on this node's row rather than in a row of its own. The
      // payload still carries it, because the picker and the capability tiers read it.
      if (node.kind === "client") {
        desktopNode = node;
        row.remove();
        continue;
      }
      if (node.local_node) {
        row.classList.add("node-local");
        const badge = document.createElement("span");
        badge.className = "node-this";
        badge.textContent = "this node";
        row.append(badge);
      }
      if (node.kind === "host") updateNodeLabel(node.name, node.worktree);
      const kind = document.createElement("span");
      kind.className = "node-kind";
      kind.textContent = node.kind;
      const caps = document.createElement("span");
      caps.className = "node-caps";
      caps.textContent = (node.capabilities || []).join(" ");
      row.append(dot, name, kind, caps);
      row.append(nodeButton("talk", () => { balloon.close(); input.focus(); }));
      if (node.kind === "host") hostRow = row;
      nodesBox.append(row);
    }
    // One row for this machine: the node, with the desktop it runs a window on. The control
    // button lives here because it opens *this* window's desktop, and it would have been lost
    // with the row it used to sit on.
    if (hostRow) {
      if (desktopNode) {
        const state = document.createElement("span");
        state.className = "node-desktop" + (desktopNode.online ? " ready" : "");
        state.textContent = desktopNode.online ? "desktop ready" : "desktop offline";
        state.title = "the machine this window runs on, reachable through the client bridge";
        hostRow.append(state);
        if (desktopNode.online) {
          hostRow.append(nodeButton("control", () => openControl(desktopNode.name)));
        }
      }
    }
  } catch (error) { /* leave the panel as-is */ }
}

async function drawTile(tile) {
  try {
    const blob = new Blob([b64ToBytes(tile.image)], { type: "image/bmp" });
    const bitmap = await createImageBitmap(blob);
    controlCtx.drawImage(bitmap, tile.x, tile.y, tile.w, tile.h);
    bitmap.close();
  } catch (error) { /* skip a bad tile */ }
}

async function fetchFrame(full) {
  if (controlPending) return;
  controlPending = true;
  try {
    const payload = await (await apiFetch("frame", {
      method: "POST",
      headers: apiHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ max_width: 800, full: !!full }),
    })).json();
    if (payload.error) {
      controlHint.textContent = payload.error;
      return;
    }
    controlScreen = { w: payload.screen_width, h: payload.screen_height };
    if (payload.full || controlCanvasSize.w !== payload.width || controlCanvasSize.h !== payload.height) {
      controlCanvas.width = payload.width;
      controlCanvas.height = payload.height;
      controlCanvasSize = { w: payload.width, h: payload.height };
    }
    controlHint.textContent = `${payload.width}×${payload.height} · ${payload.tiles.length} tile${payload.tiles.length === 1 ? "" : "s"}`;
    for (const tile of payload.tiles) await drawTile(tile);
  } catch (error) {
    controlHint.textContent = String(error);
  } finally {
    controlPending = false;
  }
}

// The live view polls as fast as the node answers, and no faster.
//
// It used to poll every 150ms behind an 8-second client deadline: each request was abandoned while
// the node still had it, the next one started immediately, and the abandoned ones piled up - 256 of
// them, the queue's bound, at which point the chat's own /me and /models could not get through and
// the window sat on "connecting…" with an empty transcript. A live view is a view *of* the machine;
// it is not the reason the machine exists, and it has to yield to the conversation.
let controlDelay = 150;

function scheduleFrame() {
  if (controlTimer) clearTimeout(controlTimer);
  controlTimer = setTimeout(async () => {
    controlTimer = null;
    const started = Date.now();
    await fetchFrame(false);
    const took = Date.now() - started;
    // Twice the round trip, floored at the old cadence and capped so a slow node still gets a frame
    // eventually rather than never.
    controlDelay = Math.min(Math.max(150, took * 2), 5000);
    if (controlLive.checked) scheduleFrame();
  }, controlDelay);
}

function startLive() {
  if (controlTimer) clearTimeout(controlTimer);
  controlDelay = 150;
  scheduleFrame();
}

// ---- views: a component in its own window -------------------------------------------------
//
// A view is something the chat asked for and then gets out of the way of: the control view is a
// desktop you work in, not a panel inside a conversation. When there is a shell to ask, it gets a
// real OS window - decorated, resizable, movable, and *not* always on top, so the chat floats
// above the thing it opened. In a browser there is no shell, so the same component renders in an
// in-page <wa-window> instead.
function viewMode() {
  try { return new URLSearchParams(location.search).get("view") || ""; } catch (error) { return ""; }
}

function viewUrl(view) {
  return location.origin + location.pathname + "?view=" + encodeURIComponent(view);
}

function controlViewName(name) {
  return "control:" + (name || "this-node");
}

// In a view window, render that one component and nothing else. The section is moved out of the
// panel, because this window is not the chat: there is no conversation here to keep.
function applyViewMode() {
  const wanted = viewMode();
  if (!wanted) return false;
  document.body.classList.add("view-only");
  const parts = wanted.split(":");
  const kind = parts[0];
  const target = parts[1] && parts[1] !== "this-node" ? parts.slice(1).join(":") : "";
  if (kind === "control") {
    if (target) activeNode = target;
    document.body.append(control);
    openControl(target);
  }
  if (kind === "patch") {
    // A view window is a client of the node like any other, so it fetches its own patch. Nothing is
    // passed through the main window: that is what makes it a view and not a screenshot of one.
    const params = new URLSearchParams(location.search);
    renderPatchView(params.get("message") || "", params.get("path") || "");
  }
  return true;
}

// A deep link can ask for a view directly: `?open=control:node` opens it in its own window, which
// is what a shortcut, a script or a test wants - and it is the same call the control button makes,
// so the two cannot drift.
function openFromQuery() {
  let wanted = "";
  try { wanted = new URLSearchParams(location.search).get("open") || ""; } catch (error) { wanted = ""; }
  if (!wanted) return false;
  const parts = wanted.split(":");
  const target = parts[1] && parts[1] !== "this-node" ? parts.slice(1).join(":") : "";
  if (parts[0] === "control") openControl(target);
  return true;
}

function openControl(name) {
  balloon.close();
  const view = controlViewName(name);
  // Its own window when the shell can give it one - and never from inside a view, or opening the
  // control would open another window, which would open another.
  if (!viewMode() && native && typeof native.openView === "function") {
    native.openView(view, viewUrl(view));
    return;
  }
  document.body.classList.add("control");
  control.hidden = false;
  controlTitle.textContent = "control · " + (name || "this node");
  controlCanvasSize = { w: 0, h: 0 };
  fetchFrame(true).then(() => { if (controlLive.checked) startLive(); });
}

// The control view at full size. "Fill the screen" has to be asked for in two places: the
// page can cover the window, and only the shell can give the page the screen. A control view
// is a desktop, not a message, so it does not belong inside the chat panel.
function setControlMaximized(on) {
  controlView.classList.toggle("maximized", on);
  // Also on the section, so descendant rules (the header staying reachable) can match.
  control.classList.toggle("maximized", on);
  controlMax.setAttribute("aria-pressed", on ? "true" : "false");
  controlMax.title = on ? "Leave full screen (Esc)" : "Fill the screen";
  if (native && native.maximize) {
    if (on) native.maximize();
    else native.expand();
  }
}

function closeControl() {
  // In its own window, closing means closing the window - the shell owns it. In the page it means
  // hiding the panel, because the panel is still the chat's.
  if (viewMode() && native && typeof native.closeView === "function") { native.closeView(); return; }
  // Leaving the control leaves the full screen too, or the chat would open inside a window
  // sized for a desktop.
  if (controlView.classList.contains("maximized")) setControlMaximized(false);
  document.body.classList.remove("control");
  control.hidden = true;
  control.classList.remove("maximized");
  if (controlTimer) { clearTimeout(controlTimer); controlTimer = null; }
}

controlCanvas.addEventListener("click", (event) => {
  const rect = controlCanvas.getBoundingClientRect();
  if (!rect.width || !controlScreen.w) return;
  const x = Math.round(((event.clientX - rect.left) / rect.width) * controlScreen.w);
  const y = Math.round(((event.clientY - rect.top) / rect.height) * controlScreen.h);
  clientAction({ action: "click", x, y });
});
controlKeys.addEventListener("submit", (event) => {
  event.preventDefault();
  const text = controlText.value;
  if (!text) return;
  controlText.value = "";
  clientAction({ action: "type", text });
});
controlMax.addEventListener("click", () => setControlMaximized(!controlView.classList.contains("maximized")));
// Escapable the way every other mode here is: the control that opened it, Escape, and closing
// the view. A mode you can only leave one way is a mode you can get stuck in.
document.addEventListener("keydown", (event) => {
  if (event.key !== "Escape" || control.hidden) return;
  event.preventDefault();
  if (controlView.classList.contains("maximized")) setControlMaximized(false);
  else closeControl();
});
controlRefresh.addEventListener("click", () => fetchFrame(true));
controlClose.addEventListener("click", closeControl);
controlLive.addEventListener("change", () => {
  if (controlLive.checked) startLive();
  else if (controlTimer) { clearTimeout(controlTimer); controlTimer = null; }
});

// ---- engine: nodes / spells / tools --------------------------------------
// ---- skills: what this node can be told to do -----------------------------
//
// Two different facts about one row, which is why the topic exists. The *description* is always
// in the model's context - that is how the agent knows a skill exists - while the *body* is only
// read when a task matches it. So "the agent has this skill" and "the agent can load it on
// demand" are separate claims, and a skill whose file cannot be read is listed here and useless
// to the model. Nothing on this screen is in context; looking loads nothing.
async function refreshSkills() {
  try {
    const response = await apiFetch("skills", { headers: apiHeaders() });
    // A node that does not serve this route answers with a plain "not found", and calling
    // `.json()` on that raises a SyntaxError - which reads like the UI is broken rather than the
    // node being older than the UI. Say which it is: a missing route is a normal thing to meet
    // when a window is newer than the node it is talking to.
    const text = await response.text();
    let payload = null;
    try { payload = JSON.parse(text); } catch (error) { payload = null; }
    if (!payload) {
      skillsNote.textContent = "not served";
      // Say what is actually missing. The route and the Lua function are both compiled into the
      // node binary - the UI is read from disk per request, which is why this file can be newer
      // than the node - so a *restart* of the same binary would change nothing. It needs a node
      // built from a tree that has them.
      skillsBox.textContent = "this node was built before the /skills route existed (HTTP " +
        response.status + ") - it needs a node built from the current tree, not a restart";
      return;
    }
    const skills = payload.skills || [];
    skillsNote.textContent = payload.count + " · " + payload.loadable + " loadable on demand";
    skillsBox.replaceChildren();
    if (!skills.length) {
      skillsBox.textContent = "no skills found";
      return;
    }
    for (const skill of skills) {
      const row = document.createElement("div");
      row.className = "skill-row";
      const name = document.createElement("span");
      name.className = "skill-name";
      name.textContent = skill.name;
      const meta = document.createElement("span");
      meta.className = "skill-meta";
      const tags = [skill.source];
      tags.push(skill.loadable ? skill.body_chars + " chars on demand" : "body unreadable");
      tags.push(skill.hidden ? "hidden from the model" : "described in context");
      meta.textContent = tags.join(" · ");
      const description = document.createElement("div");
      description.className = "skill-description";
      description.textContent = skill.description || "(no description)";
      row.append(name, meta, description);
      skillsBox.append(row);
    }
  } catch (error) {
    skillsNote.textContent = "unavailable";
    skillsBox.textContent = String(error);
  }
}

async function refreshSpells() {
  try {
    const payload = await (await apiFetch("spells", { headers: apiHeaders() })).json();
    const spells = payload.spells || [];
    spellsNote.textContent = spells.length + " saved";
    spellsBox.replaceChildren();
    if (!spells.length) {
      spellsBox.textContent = "no spells saved yet";
      return;
    }
    for (const spell of spells) {
      const row = document.createElement("div");
      row.className = "spell-row";
      const name = document.createElement("span");
      name.className = "spell-name";
      name.textContent = spell.name;
      const meta = document.createElement("span");
      meta.className = "spell-meta";
      const params = Object.keys(spell.params || {});
      const detail = `v${spell.version} · ${spell.steps} steps · ${spell.post} settle`;
      meta.textContent = detail + (params.length ? " · " + params.join(",") : "");
      const run = nodeButton("run", async () => {
        meta.textContent = "running…";
        const result = await (await apiFetch("spell", {
          method: "POST",
          headers: apiHeaders({ "Content-Type": "application/json" }),
          body: JSON.stringify({ name: spell.name }),
        })).json();
        meta.textContent = result.error ? "error: " + result.error : `ok · ${result.ms}ms · settled`;
      });
      row.append(name, meta, run);
      spellsBox.append(row);
    }
  } catch (error) {
    spellsBox.textContent = String(error);
  }
}

async function refreshTools() {
  try {
    const payload = await (await apiFetch("tools", { headers: apiHeaders() })).json();
    toolsBox.replaceChildren();
    for (const group of payload.tiers || []) {
      const block = document.createElement("div");
      block.className = "tier";
      const title = document.createElement("div");
      title.className = "tier-name";
      title.textContent = group.tier;
      block.append(title);
      for (const tool of group.tools) {
        const row = document.createElement("div");
        row.className = "tool-row";
        const name = document.createElement("span");
        name.className = "tool-name";
        name.textContent = tool.name;
        const desc = document.createElement("span");
        desc.className = "tool-desc";
        desc.textContent = tool.description || "";
        row.append(name, desc);
        block.append(row);
      }
      if (group.tier === "client") {
        for (const action of payload.client_actions || []) {
          const row = document.createElement("div");
          row.className = "tool-row";
          const name = document.createElement("span");
          name.className = "tool-name";
          name.textContent = "client." + action.name;
          const args = Object.keys(action.args || {}).join(", ");
          const desc = document.createElement("span");
          desc.className = "tool-desc";
          desc.textContent = (args ? "(" + args + ")" : "()") + (action.note ? "  " + action.note : "");
          row.append(name, desc);
          block.append(row);
        }
      }
      toolsBox.append(block);
    }
    // The literal object sent to the provider, at full depth.
    const envelope = await (await apiFetch("envelope", { headers: apiHeaders() })).json();
    if (envelope.request) {
      const details = document.createElement("details");
      details.className = "envelope-raw";
      const summary = document.createElement("summary");
      summary.textContent = `raw envelope · ${envelope.tool_count} tools`;
      const pre = document.createElement("pre");
      pre.textContent = JSON.stringify(envelope.request, null, 2);
      details.append(summary, pre);
      toolsBox.append(details);
    }
  } catch (error) {
    toolsBox.textContent = String(error);
  }
}

// Sessions: the agent's own transcripts, with traces. This is the debugging
// surface: open a session, flip it to debug, export it as a fixture.
// ---- sessions: the threads this node has had --------------------------------
//
// Ordered by last interaction - the route does that, and this view must not re-sort it, because
// "most recently used" is the only order that makes a long list usable. Named after their opening
// message, and searchable: keeping threads is only worth anything if you can find the one you mean,
// and a list you have to read top to bottom is not a way to find anything.
let sessionQuery = "";
let sessionList = [];

// "3m ago" rather than a locale timestamp: in a list of threads, how long ago is the question, and
// the exact second is never the answer.
function ago(seconds) {
  const s = Math.max(0, Number(seconds) || 0);
  if (s < 60) return "just now";
  if (s < 3600) return Math.floor(s / 60) + "m ago";
  if (s < 86400) return Math.floor(s / 3600) + "h ago";
  if (s < 86400 * 7) return Math.floor(s / 86400) + "d ago";
  return new Date(Date.now() - s * 1000).toLocaleDateString();
}

function sessionMatches(session, query) {
  if (!query) return true;
  const haystack = [session.title, session.id, session.objective, session.state]
    .filter(Boolean).join(" ").toLowerCase();
  return query.toLowerCase().split(/\s+/).every((word) => haystack.includes(word));
}

// Continue a thread the node left unfinished.
//
// The node records what was lost and prints the command; it does not act on its own, because a
// repair nobody asked for destroys the evidence of the crash. That leaves a person to notice a
// badge and type a command, which is not recovery - this is the same thing as one click, sent to
// the node so the run runs where the session lives and the window can watch it.
function resumeSession(id) {
  if (!id) return;
  rememberSession(id);
  send("continue where you stopped", { session: id });
}

function renderSessions() {
  const shown = sessionList.filter((session) => sessionMatches(session, sessionQuery));
  sessionsNote.textContent = sessionQuery
    ? `${shown.length} of ${sessionList.length} sessions`
    : `${sessionList.length} sessions · most recent first`;
  // The search row is re-appended on every render, not replaced by it: a filter box that vanishes
  // when you type in it is not a filter box.
  sessionsBox.replaceChildren(sessionSearch());
  if (!sessionList.length) {
    const empty = document.createElement("div");
    empty.textContent = "no sessions yet";
    sessionsBox.append(empty);
    return;
  }
  if (!shown.length) {
    const empty = document.createElement("div");
    empty.textContent = "nothing matches " + JSON.stringify(sessionQuery);
    sessionsBox.append(empty);
    return;
  }
  for (const session of shown) {
    const row = document.createElement("div");
    row.className = "session-row";
    const title = document.createElement("span");
    title.className = "session-title";
    // The id is the fallback, not the name: a thread whose first message could not name it is still
    // findable by the id it will be referred to by.
    title.textContent = session.title || session.id.slice(0, 8);
    title.title = session.id;
    const meta = document.createElement("span");
    meta.className = "session-meta";
    const when = ago((Date.now() / 1000) - (session.updated_at || session.started_at || 0));
    meta.textContent = `${session.message_count} runs · ${when}`;
    row.append(title, meta);
    // Only when there is something to recover: a badge on every row would be noise, and "answered"
    // is the case that needs no attention. The reason is the API's own words, so the UI cannot
    // invent a different story.
    if (session.state && session.state !== "answered" && session.state !== "empty") {
      const badge = document.createElement("span");
      badge.className = "session-state " + session.state;
      badge.textContent = session.state;
      badge.title = session.state_detail || session.state;
      row.append(badge);
    }
    row.append(nodeButton("open", () => openSession(session.id)));
    // A child session names the thread that spawned it; without this it is an orphan in the list.
    if (session.parent_session_id) {
      row.append(nodeButton("parent", () => openSession(session.parent_session_id)));
    }
    // Only where there is something to recover, and named as what it does: the node's own words for
    // this are "continue where you stopped".
    if (session.state === "unfinished") {
      row.append(nodeButton("continue", () => resumeSession(session.id)));
    }
    sessionsBox.append(row);
  }
}

async function refreshSessions() {
  try {
    const payload = await (await apiFetch("sessions", { headers: apiHeaders() })).json();
    sessionList = payload.sessions || [];
    renderSessions();
  } catch (error) {
    sessionsNote.textContent = "unavailable";
    sessionsBox.textContent = String(error);
  }
}

// The search box is part of the topic rather than the markup because the topic is drawn from JS -
// and because a filter that survives re-rendering has to own its own element.
function sessionSearch() {
  const row = document.createElement("div");
  row.className = "session-search";
  const input = document.createElement("input");
  input.type = "search";
  input.id = "session-search";
  input.placeholder = "search threads";
  input.autocomplete = "off";
  input.value = sessionQuery;
  input.addEventListener("input", () => { sessionQuery = input.value.trim(); renderSessions(); });
  row.append(input);
  return row;
}

async function openSession(id) {
  // Opening a thread is also choosing it: from here on this window is *in* that conversation, so a
  // later respawn comes back to it instead of guessing.
  rememberSession(id);
  return openSessionById(id);
}

async function openSessionById(id) {
  const payload = await (await apiFetch("session?id=" + encodeURIComponent(id), { headers: apiHeaders() })).json();
  if (payload.error) {
    sessionsBox.textContent = payload.error;
    return;
  }
  const session = payload.session;
  sessionsBox.replaceChildren();

  const bar = document.createElement("div");
  bar.className = "session-bar";
  bar.append(nodeButton("← sessions", () => refreshSessions()));
  bar.append(nodeButton(session.mode === "debug" ? "debug: on" : "debug: off", async () => {
    const next = session.mode === "debug" ? "default" : "debug";
    await apiFetch("session/mode", {
      method: "POST",
      headers: apiHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ session_id: id, mode: next }),
    });
    openSession(id);
  }));
  bar.append(nodeButton("export fixture", async () => {
    const fixture = await (await apiFetch("session/fixture?id=" + encodeURIComponent(id), { headers: apiHeaders() })).json();
    const blob = new Blob([JSON.stringify(fixture, null, 2)], { type: "application/json" });
    const link = document.createElement("a");
    link.href = URL.createObjectURL(blob);
    link.download = `wasm-agent-session-${id.slice(0, 8)}.json`;
    link.click();
    URL.revokeObjectURL(link.href);
  }));
  sessionsBox.append(bar);

  if (session.summary) {
    const summary = document.createElement("div");
    summary.className = "session-summary";
    summary.textContent = "summary: " + session.summary;
    sessionsBox.append(summary);
  }

  for (const message of payload.messages || []) {
    const row = document.createElement("div");
    row.className = "message message-" + message.role + (message.ok ? "" : " bad");
    const head = document.createElement("div");
    head.className = "message-head";
    head.textContent = [
      message.seq, message.role, message.tool_name, message.ms ? message.ms + "ms" : "",
      message.tokens ? message.tokens + " tok" : "",
    ].filter(Boolean).join(" · ");
    const body = document.createElement("div");
    body.className = "message-body";
    body.textContent = (message.content || "").slice(0, 1500);
    row.append(head, body);
    const trace = message.trace || [];
    if (trace.length) {
      const line = document.createElement("div");
      line.className = "message-trace";
      line.textContent = trace.map((span) => {
        const parts = [span.kind + (span.name ? "(" + span.name + ")" : "")];
        if (span.ms != null) parts.push(span.ms + "ms");
        if (span.ok === false) parts.push("FAILED");
        if (span.error) parts.push(span.error);
        return parts.join(" ");
      }).join("  →  ");
      row.append(line);
    }
    sessionsBox.append(row);
  }
}

// Topics waiting for the node to be free. The engine's reads are Lua, so on a single-worker node they
// queue behind a run - and the client's deadline is shorter than a run, so opening one while the node
// was working showed "AbortError: signal is aborted without reason". That reads as the UI being broken
// when the node is simply busy, which is the opposite of what a status line is for.
const pendingTopics = new Set();

async function refreshJobs() {
  const box = document.getElementById('jobs-box');
  try {
    const response = await apiFetch('jobs', {headers: apiHeaders()});
    const payload = await response.json();
    if (!response.ok || payload.error) throw new Error(payload.error || `HTTP ${response.status}`);
    let panel = box.querySelector('wa-jobs');
    if (!panel) { panel = document.createElement('wa-jobs'); box.replaceChildren(panel); }
    panel.items = payload.jobs || [];
  } catch (error) { box.textContent = `Jobs unavailable: ${error}`; }
}
document.getElementById('jobs-box').addEventListener('job-toggle', async (event) => {
  const {id, enabled, control} = event.detail;
  try {
    const response = await apiFetch('jobs', {method: 'POST', headers: {...apiHeaders(), 'Content-Type': 'application/json'}, body: JSON.stringify({id, action: enabled ? 'enable' : 'disable'})});
    const payload = await response.json();
    if (!response.ok || payload.error) throw new Error(payload.error || `HTTP ${response.status}`);
    await refreshJobs();
  } catch (error) {
    control.disabled = false;
    let failure = document.getElementById('jobs-box').querySelector('.job-error');
    if (!failure) { failure = document.createElement('p'); failure.className = 'job-error'; document.getElementById('jobs-box').append(failure); }
    failure.textContent = `Job was not changed: ${error}`;
  }
});

function loadTopic(id) {
  const box = document.getElementById(id);
  if (busy && id !== 'jobs-box') {
    // Do not even ask: the worker is inside a run, so the request would queue and then be abandoned by
    // the deadline. Say what is true and come back to it when the run ends.
    pendingTopics.add(id);
    if (box) box.textContent = "the node is busy with a run — this loads when it finishes";
    return;
  }
  pendingTopics.delete(id);
  if (id === "nodes-box") refreshNodes();
  else if (id === "sessions-box") refreshSessions();
  else if (id === "skills-box") refreshSkills();
  else if (id === "spells-box") refreshSpells();
  else if (id === "tools-box") refreshTools();
  else if (id === "jobs-box") refreshJobs();
}

/// Everything the engine was asked for while the node was busy, plus whatever is open, once it is free.
function reloadTopics() {
  for (const id of Array.from(pendingTopics)) loadTopic(id);
  for (const box of document.querySelectorAll(".engine-content")) {
    if (!box.hidden && box.id && !pendingTopics.has(box.id)) loadTopic(box.id);
  }
}

document.querySelectorAll(".engine-head").forEach((head) => {
  head.addEventListener("click", () => {
    const content = document.getElementById(head.dataset.target);
    const opening = content.hidden;
    content.hidden = !opening;
    const caret = head.querySelector(".engine-caret");
    if (caret) caret.textContent = opening ? "▾" : "▸";
    if (opening) loadTopic(head.dataset.target);
  });
});

function setEngine(open) {
  document.body.classList.toggle("engine", open);
  engineView.hidden = !open;
  engineBtn.classList.toggle("active", open);
  if (open) {
    engineSub.textContent = `${me.role} · ${me.tools.length} tools`;
  }
}

engineBtn.addEventListener("click", () => setEngine(!document.body.classList.contains("engine")));
engineClose.addEventListener("click", () => setEngine(false));

// ---- drift: what this node has that a peer does not ----------------------
// A diff of the replication journal, read from GET /sync. This is the one place
// in the UI that shows a *diff* rather than a transcript, so it is worth being
// explicit about what the rows mean: a node keeps an append-only journal of
// entries, and a cursor per peer recording how far that peer has been sent. The
// gap between a cursor and the head is therefore exactly the set of entries that
// peer has not seen - the drift. The local node has a head and no cursor; a peer
// has both.
//
// It is READ-ONLY, and that is a deliberate limit rather than an oversight:
// showing drift must not cause it. Pushing from a button would make merely
// looking at the panel a mutation of another node's ledger, which is the kind of
// thing that should be its own step with its own confirmation.

function driftRow(label, value, kind = "") {
  const row = document.createElement("div");
  row.className = "drift-row" + (kind ? " " + kind : "");
  const name = document.createElement("span");
  name.className = "drift-key";
  name.textContent = label;
  const val = document.createElement("span");
  val.className = "drift-val";
  val.textContent = value;
  row.append(name, val);
  return row;
}

function driftTopic(title, note) {
  const topic = document.createElement("div");
  topic.className = "engine-topic";
  const head = document.createElement("div");
  head.className = "engine-head";
  const name = document.createElement("span");
  name.className = "engine-name";
  name.textContent = title;
  const detail = document.createElement("span");
  detail.className = "engine-note";
  detail.textContent = note;
  head.append(name, detail);
  topic.append(head);
  return topic;
}

// The journal head and a peer's cursor are both counts of entries, so the gap is
// a count too - and a negative gap would mean the peer is *ahead* of us, which is
// real (we may have been offline while it advanced) and must not be clamped to
// zero. Showing "0 behind" for a peer that is ahead would be a lie in the same
// family as a silent failure.
function renderDrift(status) {
  driftBody.replaceChildren();
  const head = Number(status.head || 0);
  const peers = Array.isArray(status.peers) ? status.peers : [];

  driftSub.textContent = status.node_id
    ? `${String(status.node_id).slice(0, 12)}… · head ${head}`
    : `head ${head}`;

  const own = driftTopic("this node", `${head} journal entr${head === 1 ? "y" : "ies"}`);
  const ownBody = document.createElement("div");
  ownBody.className = "engine-content";
  ownBody.append(driftRow("head", String(head)));
  ownBody.append(driftRow("pushing to", status.pushing_to ? String(status.pushing_to) : "nobody (WASM_AGENT_SYNC_TO is unset)"));
  own.append(ownBody);
  driftBody.append(own);

  const peersTopic = driftTopic(
    "peers",
    peers.length === 0 ? "no peer has been sent anything yet" : `${peers.length} peer${peers.length === 1 ? "" : "s"}`,
  );
  const peersBody = document.createElement("div");
  peersBody.className = "engine-content";

  if (peers.length === 0) {
    // Say why rather than showing an empty box: "no peers" and "peers that are
    // all level" are different states and must not look the same.
    const note = document.createElement("div");
    note.className = "drift-empty";
    note.textContent = "No cursors recorded. Either nothing has been pushed yet, or this node is not configured to push.";
    peersBody.append(note);
  } else {
    for (const peer of peers) {
      const cursor = Number(peer.cursor || 0);
      const behind = head - cursor;
      const topic = driftTopic(
        String(peer.peer_id || "unknown").slice(0, 20),
        behind > 0 ? `${behind} behind` : behind < 0 ? `${-behind} ahead` : "level",
      );
      const body = document.createElement("div");
      body.className = "engine-content";
      // Every pushed entry gets its own + line, so the count is auditable rather
      // than asserted: a row per entry, capped so a large gap cannot hang the
      // render, and the cap is stated instead of silently truncating.
      const shown = Math.min(behind, 50);
      for (let i = 0; i < shown; i += 1) {
        body.append(driftRow("+", `journal entry ${cursor + i + 1}`, "add"));
      }
      if (behind > shown) {
        body.append(driftRow("…", `${behind - shown} more not listed`, "muted"));
      }
      if (behind < 0) {
        body.append(driftRow("−", `we are ${-behind} behind this peer`, "del"));
      }
      if (behind === 0) {
        body.append(driftRow("=", "nothing to send", "muted"));
      }
      body.append(driftRow("cursor", String(cursor), "muted"));
      topic.append(body);
      peersBody.append(topic);
    }
  }
  peersTopic.append(peersBody);
  driftBody.append(peersTopic);
}

async function loadDrift() {
  driftSub.textContent = "reading…";
  try {
    const response = await fetch("sync", { headers: apiHeaders() });
    if (!response.ok) throw new Error(`sync ${response.status}`);
    const payload = await response.json();
    if (payload && payload.error) throw new Error(payload.error);
    renderDrift(payload || {});
  } catch (error) {
    // Never render a failed read as "no drift": an unreadable journal is not a
    // clean one, and conflating them is how a sync problem hides for a week.
    driftBody.replaceChildren();
    driftSub.textContent = "unreadable";
    const topic = driftTopic("this node", "could not read the journal");
    const body = document.createElement("div");
    body.className = "engine-content";
    body.append(driftRow("error", String(error && error.message ? error.message : error), "del"));
    topic.append(body);
    driftBody.append(topic);
  }
}

function setDrift(open) {
  document.body.classList.toggle("drift", open);
  driftView.hidden = !open;
  driftBtn.classList.toggle("active", open);
  if (open) loadDrift();
}

driftBtn.addEventListener("click", () => setDrift(!document.body.classList.contains("drift")));
driftClose.addEventListener("click", () => setDrift(false));
driftRefresh.addEventListener("click", () => loadDrift());

// ---- terminal: shell on this machine + spell replay ----------------------
const termHistory = [];
let termIndex = 0;

function termWrite(text, kind = "") {
  const line = document.createElement("div");
  line.className = "term-line" + (kind ? " " + kind : "");
  line.textContent = text;
  termOut.append(line);
  termOut.scrollTop = termOut.scrollHeight;
}

async function runShell(command) {
  termWrite("> " + command, "cmd");
  const trimmed = command.trim();
  if (!trimmed) return;
  if (trimmed === ":clear") { termOut.replaceChildren(); return; }
  try {
    if (trimmed === ":spells" || trimmed === ":spell") {
      const payload = await (await apiFetch("spells", { headers: apiHeaders() })).json();
      if (payload.error) { termWrite(payload.error, "err"); return; }
      const spells = payload.spells || [];
      if (!spells.length) { termWrite("(no spells saved yet)", "meta"); return; }
      for (const spell of spells) {
        const params = Object.keys(spell.params || {});
        const settle = `${spell.post} settle`;
        termWrite(`  ${spell.name} v${spell.version} · ${spell.steps} steps · ${settle}${params.length ? " · params: " + params.join(",") : ""}  ${spell.description || ""}`, "meta");
      }
      return;
    }
    if (trimmed.startsWith(":run ")) {
      const name = trimmed.slice(5).trim();
      const payload = await (await apiFetch("spell", {
        method: "POST", headers: apiHeaders({ "Content-Type": "text/plain" }), body: name,
      })).json();
      termWrite(JSON.stringify(payload), payload.error ? "err" : "meta");
      return;
    }
    const payload = await (await apiFetch("shell", {
      method: "POST", headers: apiHeaders({ "Content-Type": "text/plain" }), body: command,
    })).json();
    if (payload.error) { termWrite(payload.error, "err"); return; }
    if (payload.stdout) termWrite(payload.stdout.replace(/\n$/, ""));
    if (payload.stderr) termWrite(payload.stderr.replace(/\n$/, ""), "err");
    if (payload.code) termWrite(`(exit ${payload.code})`, "meta");
  } catch (error) {
    termWrite(String(error), "err");
  }
}

let clientHost = "";
async function ensureHost() {
  if (clientHost) return;
  try {
    const payload = await (await apiFetch("shell", {
      method: "POST", headers: apiHeaders({ "Content-Type": "text/plain" }), body: "hostname",
    })).json();
    clientHost = (payload.stdout || "").trim() || "client";
    termTitle.textContent = "shell · " + clientHost;
  } catch (error) { /* leave the default title */ }
}

function setTerm(open) {
  document.body.classList.toggle("term", open);
  terminal.hidden = !open;
  termBtn.classList.toggle("active", open);
  if (open) {
    ensureHost();
    termCmd.focus();
  }
}

termBtn.addEventListener("click", () => setTerm(!document.body.classList.contains("term")));
termClose.addEventListener("click", () => setTerm(false));
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") {
    if (document.body.classList.contains("engine")) { event.preventDefault(); setEngine(false); input.focus(); return; }
    if (document.body.classList.contains("drift")) { event.preventDefault(); setDrift(false); input.focus(); return; }
    if (document.body.classList.contains("term")) { event.preventDefault(); setTerm(false); input.focus(); return; }
    if (document.body.classList.contains("control")) { event.preventDefault(); closeControl(); return; }
  }
  if (event.ctrlKey && (event.key === "`" || event.code === "Backquote")) {
    event.preventDefault();
    setTerm(!document.body.classList.contains("term"));
  } else if (event.ctrlKey && (event.key === "e" || event.key === "E")) {
    event.preventDefault();
    setEngine(!document.body.classList.contains("engine"));
  } else if (event.ctrlKey && (event.key === "d" || event.key === "D")) {
    // Ctrl+D would otherwise be the browser's bookmark gesture.
    event.preventDefault();
    setDrift(!document.body.classList.contains("drift"));
  }
});
termForm.addEventListener("submit", (event) => {
  event.preventDefault();
  const command = termCmd.value;
  termCmd.value = "";
  if (command.trim()) {
    termHistory.push(command);
    termIndex = termHistory.length;
  }
  runShell(command);
});
termCmd.addEventListener("keydown", (event) => {
  if (event.key === "ArrowUp" && termHistory.length) {
    event.preventDefault();
    termIndex = Math.max(0, termIndex - 1);
    termCmd.value = termHistory[termIndex] || "";
  } else if (event.key === "ArrowDown") {
    event.preventDefault();
    termIndex = Math.min(termHistory.length, termIndex + 1);
    termCmd.value = termHistory[termIndex] || "";
  }
});

// ---- menus ---------------------------------------------------------------
statusBtn.setAttribute("aria-expanded", "false");
userBtn.addEventListener("click", openUserMenu);
userMenu.addEventListener("close", () => userBtn.setAttribute("aria-expanded", "false"));

document.addEventListener("contextmenu", (event) => {
  if (!native) return; // keep the normal browser menu outside the shell
  event.preventDefault();
  contextMenu.items = [
    { label: "Collapse to avatar", action: () => { applyMode("compact"); native.compact(); } },
    { label: "Reload window", action: () => reload() },
    { separator: true },
    { label: "Close wasm-agent", danger: true, action: () => native.quit() },
  ];
  contextMenu.openAt(event.clientX, event.clientY);
});

// Rendering is a round trip to fetch render.wasm. Anything that needs to know the
// real renderer - rather than the escape-and-<br> fallback - can await this, which
// is what the UI test does instead of guessing at ticks.
window.rendererLoaded = loadRenderer().then(() => {
  setupVoice();
  refreshMe();
  refreshMeta();
  // The draft first, because it is instant and it is the reader's own text; the conversation after
  // /me has answered, because the session list is filtered by user. The second input listener is the
  // draft's - the first belongs to the undo stack, and they answer different questions.
  restoreDraft();
  input.addEventListener("input", saveDraft);
  // A view window renders one component and stops: it is not a conversation, and restoring a
  // transcript into it would be showing the chat inside the thing the chat opened.
  if (!applyViewMode()) {
    // One entry point for "become live", and it retries itself until the node answers - so a node
    // that is briefly away at load no longer leaves the page half-born.
    sync("boot");
    setTimeout(openFromQuery, 400);
  }
  window.addEventListener("online", () => sync("online"));
});
watch();
watchTurn();
if (!native) input.focus();
