// wasm-agent web UI. Components live in components.js (see DESIGN.md).
const messages = document.getElementById("messages");
const jump = document.getElementById("jump");
const meta = document.getElementById("meta");
const form = document.getElementById("composer");
const input = document.getElementById("input");
const undoBtn = document.getElementById("undo");
// The node's name is not in the footer: it is a setting about this node, so it lives in the
// account balloon, which is where "who am I, and what am I" is answered.
const redoBtn = document.getElementById("redo");
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
// chat stream) pass through untouched: a turn is legitimately long.
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

function renderMarkdown(text) {
  if (renderer && renderer.memory) {
    try {
      const bytes = new TextEncoder().encode(text);
      const pointer = renderer.alloc(bytes.length);
      new Uint8Array(renderer.memory.buffer, pointer, bytes.length).set(bytes);
      const packed = renderer.render(pointer, bytes.length);
      const outPointer = Number((packed >> 32n) & 0xffffffffn);
      const outLength = Number(packed & 0xffffffffn);
      return new TextDecoder().decode(new Uint8Array(renderer.memory.buffer, outPointer, outLength));
    } catch (error) { /* fall through */ }
  }
  return escapeHtml(text).replace(/\n/g, "<br>");
}

// Some models leak their reasoning into the message; drop it.
function stripThinking(text) {
  let out = String(text)
    .replace(/[\s\S]*?<\/think>/gi, "")
    .replace(/<\/?think\b[^>]*>/gi, "");
  const open = out.search(/<think\b[^>]*>/i);
  if (open >= 0) out = out.slice(0, open);
  return out.replace(/^\s+/, "");
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

// One assistant bubble per turn. Decisions and their tool topics live *inside*
// it as stacked segments: separate bubbles put a border between every decision,
// which reads as a divider between unrelated messages instead of one reply that
// thought, used tools, thought again, and answered. When the answer is ready the
// whole path collapses into a single run topic at the top of the bubble.
let turnBubble = null;
let turnStartedAt = 0;

function currentBubble() {
  if (!turnBubble) {
    document.getElementById("empty")?.remove();
    turnBubble = document.createElement("wa-message");
    turnBubble.setAttribute("role", "assistant");
    messages.append(turnBubble);   // connecting is what builds .body
    turnBubble.body.classList.add("steps");
  }
  return turnBubble;
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
    case "search_turns":
    case "search_messages":
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

// The trace topic for the turn currently running. Created on the first tool call
// and finished when the reply arrives, so one decision is one topic.
let trace = null;
let lastTool = "";

function renderDiff(bubble, changes) {
  const files = (changes && changes.files) || [];
  if (files.length === 0) return null;
  const topic = document.createElement("wa-diff");
  topic.setSummary(changes);
  bubble.body.append(topic);
  // The toggle starts disabled: the server has not yet said whether this can be undone
  // (the files may have moved on since the turn), and enabling it first would be a button
  // that promises something the handler can then refuse.
  topic.setUndoable(false, "checking…");
  topic.addEventListener("diff-act", (event) => actOnDiff(topic, event.detail));
  return topic;
}

// Ask whether this turn's change can still be undone, and let the topic show the answer.
// A refusal here is not an error: a file that moved on is a normal thing to find, and the
// topic says which file rather than leaving the reader with a dead button.
async function askUndoable(topic) {
  if (!topic.dataset.turnId) return;
  try {
    const response = await fetch("diff", {
      method: "POST", headers: apiHeaders({ "content-type": "application/json" }),
      body: JSON.stringify({ turn_id: topic.dataset.turnId, action: "check" }),
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
      body: JSON.stringify({ turn_id: topic.dataset.turnId, action: act }),
    });
    const payload = await response.json();
    if (payload.error) return detail.done({ ok: false, reason: payload.error });
    detail.done({ ok: payload.ok === true, reason: payload.reason || "" });
  } catch (error) {
    detail.done({ ok: false, reason: "the node did not answer" });
  }
}

function currentTrace() {
  if (!trace) {
    trace = document.createElement("wa-trace");
    currentBubble().body.append(trace);
  }
  return trace;
}

function addTool(name, args) {
  currentTrace().addTool(name, toolTitle(name, args));
  lastTool = name;
  pin();
}

function settleTool(result) {
  if (!trace) return;
  const outcome = toolOutcome(lastTool, result);
  trace.settle(outcome.text, toolDetail(result), outcome.failed);
  pin();
}

function finishTrace() {
  trace?.finish();
  trace = null;
}

// The answer is the point; the route is reference. On reply, everything the turn
// did before the answer moves into one collapsed run topic at the top of the
// bubble, and the answer sits below it.
function collapseRun() {
  const bubble = turnBubble;
  if (!bubble) return;
  const body = bubble.body;
  const answer = streamBody;
  const moves = Array.prototype.filter.call(body.children, (c) => c !== answer);
  const traces = moves.filter((c) => c.tagName === "WA-TRACE");
  if (traces.length === 0) return;   // nothing ran: leave the plain answer alone
  let calls = 0;
  let decisions = 0;
  for (const child of moves) {
    if (child.tagName === "WA-TRACE") calls += child.count || 0;
    else if (child.classList && child.classList.contains("seg")) decisions += 1;
  }
  const run = document.createElement("wa-run");
  body.prepend(run);
  for (const child of moves) {
    run.body.append(child);
    if (typeof child.reveal === "function") child.reveal();
  }
  run.setSummary(decisions, calls, Date.now() - (turnStartedAt || Date.now()));
}

// A round is one decision: what the model said, then the tools it chose. Closing
// both here interleaves them inside the same bubble - text, tools, text, tools -
// and the bubble only closes when the turn really ends.
function flushDecision(final = false) {
  if (streamBody) {
    const text = stripThinking(streamText);
    if (text.trim()) {
      streamBody.innerHTML = renderMarkdown(text);
      streamBody.style.whiteSpace = "normal";
    } else {
      streamBody.remove();   // a decision with no prose leaves no empty block
    }
    streamBody = null;
    streamText = "";
  }
  finishTrace();
  if (final) turnBubble = null;
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
    // A new decision begins: close the previous one (its text and its tool topic).
    if (!turnStartedAt) turnStartedAt = Date.now();
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
    // silent panel is indistinguishable from a hung one. The count also tells the
    // reader where the output budget went when a turn ends with no answer.
    const chars = Number(event.chars) || 0;
    setStatus("thinking… " + chars + " chars of reasoning");
  } else if (event.type === "tool") {
    addTool(event.name, event.arguments);
  } else if (event.type === "tool_result") {
    settleTool(event.result);
  } else if (event.type === "delta") {
    clearStatus();
    // A new segment per decision, inside the same bubble.
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
    // The run topic goes *above* the answer and the diff goes *below* it: the answer is
    // what was asked for, the changed files are what the reader may act on. Both are
    // appended before the bubble is released, or there is nothing left to append to.
    const diff = renderDiff(currentBubble(), event.changes);
    collapseRun();
    if (diff) askUndoable(diff);
    streamBody = null;
    streamText = "";
    turnBubble = null;
  } else if (event.type === "usage") {    settings.usage = event.total || settings.usage;
    if (event.model) settings.model = event.model;
    updateChip();
    if (balloon.open) { renderUsage(); renderModels(); }
  } else if (event.type === "error") {
    clearStatus();
    add("assistant", "error: " + (event.error || "unknown"));
    finishTrace();
    turnBubble = null;
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

// Repaint a transcript by replaying the stored turns as the events the live view already
// understands. Reusing handleEvent is the point: a repainted bubble is built by exactly the code
// that built it the first time, so the two cannot drift apart.
function repaintTurns(turns) {
  messages.replaceChildren();
  turnBubble = null;
  streamBody = null;
  streamText = "";
  let rendered = 0;
  let failed = 0;
  let firstFailure = "";
  for (const turn of turns) {
    // Per turn, so one malformed row cannot swallow the rest of the transcript. A repaint that
    // stops halfway is how "my own input is missing" becomes invisible: the rows before the throw
    // are drawn, the rows after it are not, and nothing says so.
    try {
      if (turn.role === "user") {
        add("user", turn.content || "");
      } else if (turn.role === "assistant") {
        if (turn.content) handleEvent({ type: "reply", text: turn.content });
        const calls = turn.tool_calls || [];
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
      } else if (turn.role === "tool") {
        handleEvent({ type: "tool_result", name: turn.tool_name, result: { content: turn.content } });
      }
      rendered += 1;
    } catch (error) {
      failed += 1;
      if (!firstFailure) {
        firstFailure = `${turn.role} seq ${turn.seq}: ${error}`;
        console.error("repaint failed", turn, error);
      }
    }
  }
  pin(true);
  if (failed) {
    add("assistant", `repaint: ${rendered} of ${turns.length} turns drawn, ${failed} failed — first: ${firstFailure}`);
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
  } catch (error) { /* unreachable: the next turn tries again */ }
}

async function restoreSession() {
  try {
    const payload = await (await apiFetch("sessions", { headers: apiHeaders() })).json();
    const sessions = payload.sessions || [];
    if (!sessions.length) return;
    const mine = sessions.filter((s) => !me.user || !s.user_id || s.user_id === me.user.id);
    const wanted = sessions.find((s) => s.id === chatSession) || mine[0] || sessions[0];
    rememberSession(wanted.id);
    const full = await (await apiFetch("session?id=" + encodeURIComponent(wanted.id), { headers: apiHeaders() })).json();
    if (full && Array.isArray(full.turns) && full.turns.length) repaintTurns(full.turns);
    // A thread whose last turn was cut off must say so *in the chat*: the answer never arrived, and a
    // transcript that just stops looks like the agent had nothing to say. The engine's badge says it
    // too, but the reader is here, so the offer belongs here.
    if (full && full.state === "unfinished") {
      const notice = document.createElement("div");
      notice.className = "unfinished-notice";
      notice.textContent = "this turn was stopped before it answered - " +
        (full.state_detail || "the node did not record a result") + ".";
      const again = nodeButton("continue", () => { notice.remove(); resumeSession(wanted.id); });
      notice.append(again);
      messages.append(notice);
    }
    // If that thread was still running when the window went away, watch it: the answer lands in the
    // ledger, and the repaint is what puts it on screen. Tokens that arrived before the reload are
    // still lost - the node streams to whoever opened the stream - so this resumes the *result* of
    // a run, not its partial text.
    if (full && full.state && full.state !== "answered" && full.state !== "empty") watchTurn();
  } catch (error) { /* an empty node, or an unreachable one: the welcome screen is right */ }
}

// What the turn changed on disk, as one topic at the end of the bubble.
//
// It is a component (`<wa-diff>`) because the same summary is shown wherever a change is
// summarised, and because the undo affordance must behave the same everywhere. This function was
// *called* and never defined - which threw on every answer, not only the ones with changes, so the
// live view silently lost the diff topic and a reload truncated the transcript at the first reply.
// "My own input is missing" was this.
function renderDiff(bubble, changes) {
  const files = (changes && changes.files) || [];
  if (!files.length) return null;
  const diff = document.createElement("wa-diff");
  diff.setSummary(changes);
  bubble.body.append(diff);
  return diff;
}

// Undo is the server's, not the page's: the page asks and reports the answer, and the component
// renders a refusal on the topic rather than swallowing it. There is no undo endpoint on this node
// yet, and saying so is the honest answer - the alternative is a control that looks live and does
// nothing, which is what `<wa-diff>` was written to avoid. When the endpoint lands, this is the
// only place that changes.
function askUndoable(diff) {
  diff.addEventListener("diff-act", async (event) => {
    const detail = event.detail || {};
    const done = typeof detail.done === "function" ? detail.done : () => {};
    try {
      const response = await apiFetch("undo", {
        method: "POST",
        headers: apiHeaders({ "Content-Type": "application/json" }),
        body: JSON.stringify({ act: detail.act, files: diff.files || [] }),
      });
      if (!response.ok) {
        done({ ok: false, reason: "this node has no undo endpoint yet (HTTP " + response.status + ")" });
        return;
      }
      done(await response.json());
    } catch (error) {
      done({ ok: false, reason: String(error) });
    }
  });
}

function setBusy(value) {
  busy = value;
  // A reload that was deferred for a running turn lands the moment it ends, so an update
  // never sits invisible behind a finished turn.
  if (!value && pendingReload) {
    pendingReload = false;
    reload();
  }
  sendButton.classList.toggle("busy", value);
  sendButton.title = value ? "Stop" : "Send";
  sendButton.setAttribute("aria-label", sendButton.title);
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
function composedBody(text) {
  const images = attachments.filter((file) => file.kind === "image");
  if (images.length === 0) return { contentType: "text/plain; charset=utf-8", body: composedText(text) };
  return {
    contentType: "application/json",
    body: JSON.stringify({
      text: composedText(text),
      images: images.map((file) => ({ name: file.name, mime: file.mime, data: file.data })),
    }),
  };
}

// A lost connection is not a failed turn. When the node dies mid-stream the
// browser throws a TypeError, and printing it raw - "error: TypeError: network
// error" - tells the reader nothing: not what broke, not what to do, and not
// that the work is recoverable. It is: the turn is recorded as unfinished.
function isConnectionLoss(error) {
  return error instanceof TypeError;
}

function connectionMessage() {
  return "lost the local node mid-turn (nothing is serving " + location.origin + ")." +
    " Start it with `wa ui` - this turn is recorded as unfinished, and" +
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
async function send(text, options = {}) {
  // The draft is going out, so what was stored is stale: a respawn must not put the sent prompt
  // back into the composer.
  clearDraft();
  setBusy(true);
  // Sending is an explicit request to see the answer: follow again, even if the
  // reader had scrolled up to read something.
  setFollow(true);
  pin(true);
  turnBubble = null;   // the reply gets its own bubble
  turnStartedAt = Date.now();
  controller = new AbortController();
  streamBody = null;
  streamText = "";
  const names = attachments.map((file) => file.name).join(", ");
  add("user", text + (names ? `\n\nattached: ${names}` : ""));
  const outgoing = composedBody(text);
  // Clear in place, like the submit handler does. Reassigning the binding here was
  // enough to make a reader's captured reference stale - which is how a test can end
  // up asserting against a dead array and passing.
  attachments.length = 0;
  renderAttachments();
  setStatus("wasm-agent is thinking…");
  try {
    const headers = { "Content-Type": outgoing.contentType, "Accept": "text/event-stream" };
    // Which thread this turn belongs to. The node creates a session when it is not told one, and
    // never says which - so a window that is *in* a thread says so, and a continuation lands in the
    // thread it is continuing rather than in whatever is newest. Only a master says it: the session
    // header doubles as the account header in this API, and a guest naming a master's thread is not
    // something the node checks for yet.
    const target = options.session || (me.role === "master" ? chatSession : "");
    if (target) headers["X-WA-Session"] = target;
    // Silence is not evidence of death.
    //
    // A tool that takes minutes - a build, a test suite, an install - produces no events at all, and
    // the node keeps beating throughout. A client that counts seconds therefore kills turns that are
    // working: this one aborted a healthy turn mid-build, told the reader it was "recorded as
    // unfinished" when it was not, and the turn then finished normally in the ledger. A false alarm
    // that also lies about the record is worse than no alarm.
    //
    // The node is the authority, and its accept thread answers /health without the interpreter, so it
    // can say whether the worker is alive while a turn runs. Ask it, and act only on its answer.
    let lastEvent = Date.now();
    let asking = false;
    const watchdog = setInterval(async () => {
      if (asking || Date.now() - lastEvent < 30000) return;
      asking = true;
      try {
        const health = await (await apiFetch("health", { headers: apiHeaders() })).json();
        const running = health && health.current;
        if (running && health.worker !== "stalled") {
          // Working, and quiet because the work is quiet. Keep waiting, and start counting again.
          lastEvent = Date.now();
          asking = false;
          return;
        }
        // Not running any more: the turn is genuinely over, and the page should say so and stop
        // pretending it is still listening.
        clearInterval(watchdog);
        add("assistant", "the node is no longer running this turn (" + (health.worker || "no worker") +
          "). It is recorded as unfinished - the sessions topic offers to continue it.");
        watchNode();
        controller?.abort();
      } catch (error) {
        // Unreachable: the node is gone, which is a different message and the one that fits.
        clearInterval(watchdog);
        add("assistant", connectionMessage());
        watchNode();
        controller?.abort();
      }
      asking = false;
    }, 5000);
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
    // Learn which thread this turn went into, but only until we know one: after that the window
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
  const total = (settings.usage && settings.usage.total) || 0;
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

// Token accounting: last turn and session totals.
function renderUsage() {
  usageBox.replaceChildren();
  const usage = settings.usage || {};
  const last = usage.last || {};
  const rows = [
    ["last turn (in/out)", `${formatTokens(last.prompt)} / ${formatTokens(last.completion)}`],
    ["last total", formatTokens(last.total)],
    ["session in", formatTokens(usage.prompt)],
    ["session out", formatTokens(usage.completion)],
    ["session total", formatTokens(usage.total)],
    ["turns", usage.turns || 0],
  ];
  // Only shown when the provider actually reports cache reuse.
  if (Number(usage.cached) > 0) {
    const percent = usage.prompt ? Math.round((usage.cached / usage.prompt) * 100) : 0;
    rows.push(["cached (session)", `${formatTokens(usage.cached)} · ${percent}% of input`]);
  }
  // Only shown when model rates are configured (WASM_AGENT_MODEL_RATES).
  if (Number(usage.cost) > 0) {
    rows.push(["cost (session)", "$" + Number(usage.cost).toFixed(4)]);
  }
  usageBox.append(grid(rows));
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

function syncUndoButtons() {
  if (undoBtn) undoBtn.disabled = draftUndo.length === 0;
  if (redoBtn) redoBtn.disabled = draftRedo.length === 0;
}

if (undoBtn) undoBtn.addEventListener("click", () => undoDraft());
if (redoBtn) redoBtn.addEventListener("click", () => redoDraft());

form.addEventListener("submit", (event) => {
  event.preventDefault();
  if (busy) {
    controller?.abort();
    return;
  }
  const text = input.value.trim();
  if (!text && attachments.length === 0) return;
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
// server (stored content-addressed, referenced from the turn).
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
// turn shows the model.
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
    const response = await apiFetch("models" + nodeQuery(), { headers: apiHeaders() });
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
// A stylesheet can be replaced under a running turn with no state lost, so styling changes
// - the common case - never need a reload at all. Markup and JS cannot: a reload mid-turn
// throws away the page's copy of a reply that is still arriving. Those wait for the turn to
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
// It is a lock rather than a toast because it covers the panel: a turn is still running behind it,
// and the reader should not be typing into a page that is about to be replaced. It is escapable -
// reload now, or dismiss and let the reload land when the turn finishes.
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

// Split out from the polling so the decision can be driven directly: the decision is the
// part worth testing, not the fetch around it.
function applyUiVersion(next) {
  if (version === null) { version = next; return "init"; }
  if (next === version) return "same";
  version = next;
  hotSwapStyles();
  if (busy) {
    pendingReload = true;
    setStatus("update ready - reloading when this turn finishes");
    updateLock("A turn is running, so the reload waits for it to finish. Your place and your draft are kept.");
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

function setConnecting() {
  // Say what is true and that it is being worked on. "connecting…" forever reads as broken, and
  // "offline" with no retry reads as final.
  const label = syncAttempts > 2 ? "node offline — retrying" : "connecting…";
  chipModel.textContent = label;
  meta.textContent = label;
}

async function sync(reason) {
  if (synced || syncRunning) return;
  syncRunning = true;
  syncAttempts += 1;
  const meOk = await refreshMe();
  const metaOk = await refreshMeta();
  syncRunning = false;
  if (!meOk || !metaOk) {
    setConnecting();
    return;
  }
  synced = true;
  syncAttempts = 0;
  clearStatus();
  // The transcript is restored once, and only after the node has answered - then the reader's place
  // is put back on top of it, because "fresh" should not mean "moved". Whether a turn is still
  // running is reconciled by `watch`, which keeps asking; one check here would only cover the first
  // reconnection.
  restoreSession().then(restorePlace);
}

// A window must never be more certain than the node.
//
// If the node says nothing is running, then nothing is - however sure the page was a moment ago. A
// turn that died with the node left the composer disabled and a stop button showing, and the only way
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
    if (health && !health.current) {
      if (busy) { setBusy(false); clearStatus(); }
      // Nothing to wait for any more, so the lock must not wait either: it is a message, not a trap.
      document.getElementById("update-lock")?.remove();
    }
  } catch (error) { /* the node is away; watchNode says so in the chat */ }
  reconciling = false;
}

async function watch() {
  try {
    const response = await apiFetch("version");
    const payload = await response.json();
    applyUiVersion(payload.version);
    // The node answered, so finish the first sync if it never finished. This loop always runs.
    if (!synced) sync("watch");
    // While this window believes a turn is running, or is holding an update lock, ask the node what
    // is true - every few seconds, not every second.
    else if (busy || document.getElementById("update-lock")) {
      if (Date.now() - reconciledAt > 5000) { reconciledAt = Date.now(); reconcile(); }
    }
  } catch (error) { /* keep polling: the deadline is what keeps this loop alive */ }
  setTimeout(watch, 1000);
}

// The node owns the turn; the browser only watches it. If one was running when this page
// loaded - a reload mid-turn, or a reconnection after the node was busy - the reply is
// already in the ledger, so refresh the transcript once it is no longer in flight instead
// of making the reader reload to see it.
let sawTurnInFlight = false;
let turnPolling = false;
async function watchTurn() {
  // One at a time: a poll that has not answered yet is not a reason to start another, and on a
  // single-worker node that is the difference between asking and queueing.
  if (turnPolling) { setTimeout(watchTurn, 3000); return; }
  turnPolling = true;
  try {
    const response = await apiFetch("health");
    const health = await response.json();
    const current = health && health.current;
    if (current) { sawTurnInFlight = true; }
    else if (sawTurnInFlight) {
      sawTurnInFlight = false;
      if (chatSession) openSession(chatSession);
    }
  } catch (error) { /* the node is down; watchNode handles that */ }
  turnPolling = false;
  setTimeout(watchTurn, 3000);
}

// ---- native companion window (wa-window / WebView2) ----------------------
const native = window.wasmAgent || null;
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
// the node so the turn runs where the session lives and the window can watch it.
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
    meta.textContent = `${session.turn_count} turns · ${when}`;
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

  for (const turn of payload.turns || []) {
    const row = document.createElement("div");
    row.className = "turn turn-" + turn.role + (turn.ok ? "" : " bad");
    const head = document.createElement("div");
    head.className = "turn-head";
    head.textContent = [
      turn.seq, turn.role, turn.tool_name, turn.ms ? turn.ms + "ms" : "",
      turn.tokens ? turn.tokens + " tok" : "",
    ].filter(Boolean).join(" · ");
    const body = document.createElement("div");
    body.className = "turn-body";
    body.textContent = (turn.content || "").slice(0, 1500);
    row.append(head, body);
    const trace = turn.trace || [];
    if (trace.length) {
      const line = document.createElement("div");
      line.className = "turn-trace";
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

function loadTopic(id) {
  if (id === "nodes-box") refreshNodes();
  else if (id === "sessions-box") refreshSessions();
  else if (id === "skills-box") refreshSkills();
  else if (id === "spells-box") refreshSpells();
  else if (id === "tools-box") refreshTools();
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
// thing that should be its own decision with its own confirmation.

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
