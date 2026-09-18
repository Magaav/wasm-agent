// wasm-agent web UI. Components live in components.js (see DESIGN.md).
const messages = document.getElementById("messages");
const jump = document.getElementById("jump");
const meta = document.getElementById("meta");
const form = document.getElementById("composer");
const input = document.getElementById("input");
const undoBtn = document.getElementById("undo");
const redoBtn = document.getElementById("redo");
const panel = document.getElementById("panel");
const sendButton = document.getElementById("send");
const statusBtn = document.getElementById("status-btn");
const chipModel = document.getElementById("chip-model");
const chipUsage = document.getElementById("chip-usage");
const balloon = document.getElementById("status-balloon");
const nodeSelect = document.getElementById("node-select");
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
const userName = document.getElementById("user-name");
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
const spellsBox = document.getElementById("spells-box");
const spellsNote = document.getElementById("spells-note");
const toolsBox = document.getElementById("tools-box");
const sessionsBox = document.getElementById("sessions-box");
const sessionsNote = document.getElementById("sessions-note");
const control = document.getElementById("control");
const controlTitle = document.getElementById("control-title");
const controlCanvas = document.getElementById("control-canvas");
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
let nodeList = [];

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
    const response = await fetch("render.wasm");
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
    collapseRun();
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

function setBusy(value) {
  busy = value;
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
      const response = await fetch("health", { headers: apiHeaders() });
      if (response.ok) { clearInterval(nodeWatch); nodeWatch = null; nodeOffline(false); refreshMeta(); }
    } catch (error) { /* still down */ }
  }, 3000);
}
async function send(text) {
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
  attachments = [];
  renderAttachments();
  setStatus("wasm-agent is thinking…");
  try {
    const response = await fetch("chat", {
      method: "POST",
      headers: apiHeaders({ "Content-Type": outgoing.contentType, "Accept": "text/event-stream" }),
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
          try { handleEvent(JSON.parse(line.slice(6))); } catch (error) { /* ignore */ }
        }
      }
    }
  } catch (error) {
    clearStatus();
    if (error.name === "AbortError") add("assistant", "stopped.");
    else if (isConnectionLoss(error)) { add("assistant", connectionMessage()); watchNode(); }
    else add("assistant", "error: " + error);
  } finally {
    setBusy(false);
    controller = null;
    refreshMeta();
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
  const response = await fetch(path, {
    method: "POST",
    headers: apiHeaders({ "Content-Type": "text/plain; charset=utf-8" }),
    body: body,
  });
  const payload = await response.json();
  if (!payload.error) {
    settings = { ...settings, ...payload };
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
function pushDraft() {
  const previous = draftNow;
  if (sameDraft(previous, snapshotDraft())) return;
  draftUndo.push(previous);
  if (draftUndo.length > DRAFT_LIMIT) draftUndo.shift();
  // A fresh edit invalidates the redo branch, as in any editor.
  draftRedo = [];
  draftNow = snapshotDraft();
  syncUndoButtons();
}

function applyDraft(draft) {
  input.value = draft.text;
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
async function addFiles(files) {
  let added = 0;
  let refused = 0;
  // One snapshot for the whole batch: undoing a three-file drop one file at a
  // time would make Ctrl+Z feel broken. Captured before the first await, so a
  // slow read still leaves the pre-drop state on the stack.
  const before = snapshotDraft();
  for (const file of files) {
    if (isImage(file)) {
      try {
        const dataUrl = await readAsDataURL(file);
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

function renderUser() {
  const user = me.user || { name: "guest" };
  userName.textContent = user.name || user.id || "guest";
  userAvatar.textContent = initials(user.name || user.id);
  userBtn.title = `Signed in as ${user.name || "guest"} (${me.role}) · ${me.tools.length} tools`;
  userBtn.classList.toggle("local", me.role !== "admin");
}

async function refreshMe() {
  try {
    const response = await fetch("me", { headers: apiHeaders() });
    const payload = await response.json();
    if (!payload.error) {
      me = payload;
      renderUser();
    }
  } catch (error) { /* keep the current view */ }
}

async function login(id) {
  const response = await fetch("login", {
    method: "POST", headers: apiHeaders({ "Content-Type": "text/plain" }), body: id,
  });
  const payload = await response.json();
  if (payload.session) {
    session = payload.session;
    localStorage.setItem("wa-session", session);
  }
  await refreshMe();
  await refreshMeta();
}

async function logout() {
  await fetch("logout", { method: "POST", headers: apiHeaders() });
  session = "";
  localStorage.removeItem("wa-session");
  await refreshMe();
  await refreshMeta();
}

async function openUserMenu() {
  const user = me.user || {};
  const items = [{ label: `${user.name || "guest"} · ${me.role}`, action: null }, { separator: true }];
  try {
    const payload = await (await fetch("users")).json();
    for (const candidate of payload.users || []) {
      if (candidate.id === (user.id || "")) continue;
      items.push({ label: `Sign in as ${candidate.name}`, action: () => login(candidate.id) });
    }
  } catch (error) { /* no user list */ }
  if (session) {
    items.push({ separator: true }, { label: "Sign out", danger: true, action: () => logout() });
  }
  userMenu.items = items;
  const rect = userBtn.getBoundingClientRect();
  userMenu.openAt(rect.left, rect.top - 5);
  userBtn.setAttribute("aria-expanded", "true");
}

async function refreshMeta() {
  try {
    const response = await fetch("models" + nodeQuery(), { headers: apiHeaders() });
    const payload = await response.json();
    settings = { ...settings, ...payload };
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
  } catch (error) {
    meta.textContent = "offline";
  }
}

// Hot reload.
async function watch() {
  try {
    const response = await fetch("version");
    const payload = await response.json();
    if (version === null) version = payload.version;
    else if (payload.version !== version) location.reload();
  } catch (error) { /* keep polling */ }
  setTimeout(watch, 1000);
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
  const response = await fetch("client", {
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

async function refreshNodes() {
  try {
    const payload = await (await fetch("nodes", { headers: apiHeaders() })).json();
    nodeList = payload.nodes || [];
    renderNodeSelect();
    nodesBinding.textContent = payload.binding || "";
    nodesBox.replaceChildren();
    for (const node of payload.nodes || []) {
      const row = document.createElement("div");
      row.className = "node" + (node.online ? " online" : "");
      const dot = document.createElement("span");
      dot.className = "node-dot";
      const name = document.createElement("span");
      name.className = "node-name";
      name.textContent = node.name;
      const kind = document.createElement("span");
      kind.className = "node-kind";
      kind.textContent = node.kind;
      const caps = document.createElement("span");
      caps.className = "node-caps";
      caps.textContent = (node.capabilities || []).join(" ");
      row.append(dot, name, kind, caps);
      row.append(nodeButton("talk", () => { balloon.close(); input.focus(); }));
      if (node.kind === "client") {
        row.append(nodeButton("control", () => openControl(node.name)));
      }
      nodesBox.append(row);
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
    const payload = await (await fetch("frame", {
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

function startLive() {
  if (controlTimer) clearInterval(controlTimer);
  controlTimer = setInterval(() => fetchFrame(false), 150);
}

function openControl(name) {
  balloon.close();
  document.body.classList.add("control");
  control.hidden = false;
  controlTitle.textContent = "control · " + name;
  controlCanvasSize = { w: 0, h: 0 };
  fetchFrame(true).then(() => { if (controlLive.checked) startLive(); });
}

function closeControl() {
  document.body.classList.remove("control");
  control.hidden = true;
  control.classList.remove("maximized");
  if (controlTimer) { clearInterval(controlTimer); controlTimer = null; }
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
controlMax.addEventListener("click", () => control.classList.toggle("maximized"));
controlRefresh.addEventListener("click", () => fetchFrame(true));
controlClose.addEventListener("click", closeControl);
controlLive.addEventListener("change", () => {
  if (controlLive.checked) startLive();
  else if (controlTimer) { clearInterval(controlTimer); controlTimer = null; }
});

// ---- engine: nodes / spells / tools --------------------------------------
async function refreshSpells() {
  try {
    const payload = await (await fetch("spells", { headers: apiHeaders() })).json();
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
        const result = await (await fetch("spell", {
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
    const payload = await (await fetch("tools", { headers: apiHeaders() })).json();
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
    const envelope = await (await fetch("envelope", { headers: apiHeaders() })).json();
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
async function refreshSessions() {
  try {
    const payload = await (await fetch("sessions", { headers: apiHeaders() })).json();
    const list = payload.sessions || [];
    sessionsNote.textContent = `${list.length} sessions`;
    sessionsBox.replaceChildren();
    if (!list.length) {
      sessionsBox.textContent = "no sessions yet";
      return;
    }
    for (const session of list) {
      const row = document.createElement("div");
      row.className = "session-row";
      const title = document.createElement("span");
      title.className = "session-title";
      title.textContent = session.title || session.id.slice(0, 8);
      const meta = document.createElement("span");
      meta.className = "session-meta";
      const when = new Date((session.updated_at || session.started_at) * 1000).toLocaleString();
      meta.textContent = `${session.mode} · ${session.turn_count} turns · ${when}`;
      row.append(title, meta);
      // Only when there is something to recover: a badge on every row would be
      // noise, and "answered" is the case that needs no attention. The reason
      // is the API's own words, so the UI cannot invent a different story.
      if (session.state && session.state !== "answered" && session.state !== "empty") {
        const badge = document.createElement("span");
        badge.className = "session-state " + session.state;
        badge.textContent = session.state;
        badge.title = session.state_detail || session.state;
        row.append(badge);
      }
      row.append(nodeButton("open", () => openSession(session.id)));
      sessionsBox.append(row);
    }
  } catch (error) {
    sessionsBox.textContent = String(error);
  }
}

async function openSession(id) {
  const payload = await (await fetch("session?id=" + encodeURIComponent(id), { headers: apiHeaders() })).json();
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
    await fetch("session/mode", {
      method: "POST",
      headers: apiHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ session_id: id, mode: next }),
    });
    openSession(id);
  }));
  bar.append(nodeButton("export fixture", async () => {
    const fixture = await (await fetch("session/fixture?id=" + encodeURIComponent(id), { headers: apiHeaders() })).json();
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
      const payload = await (await fetch("spells", { headers: apiHeaders() })).json();
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
      const payload = await (await fetch("spell", {
        method: "POST", headers: apiHeaders({ "Content-Type": "text/plain" }), body: name,
      })).json();
      termWrite(JSON.stringify(payload), payload.error ? "err" : "meta");
      return;
    }
    const payload = await (await fetch("shell", {
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
    const payload = await (await fetch("shell", {
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
    if (document.body.classList.contains("term")) { event.preventDefault(); setTerm(false); input.focus(); return; }
    if (document.body.classList.contains("control")) { event.preventDefault(); closeControl(); return; }
  }
  if (event.ctrlKey && (event.key === "`" || event.code === "Backquote")) {
    event.preventDefault();
    setTerm(!document.body.classList.contains("term"));
  } else if (event.ctrlKey && (event.key === "e" || event.key === "E")) {
    event.preventDefault();
    setEngine(!document.body.classList.contains("engine"));
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
    { label: "Reload window", action: () => location.reload() },
    { separator: true },
    { label: "Close wasm-agent", danger: true, action: () => native.quit() },
  ];
  contextMenu.openAt(event.clientX, event.clientY);
});

// Rendering is a round trip to fetch render.wasm. Anything that needs to know the
// real renderer - rather than the escape-and-<br> fallback - can await this, which
// is what the UI test does instead of guessing at ticks.
window.rendererLoaded = loadRenderer().then(() => { setupVoice(); refreshMe(); refreshMeta(); });
watch();
if (!native) input.focus();
