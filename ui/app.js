// wasm-agent web UI. Components live in components.js (see DESIGN.md).
// The conversation - transcript region, composer, attachments, model strip - is the shared
// <wa-chat-shell>, the same component a child pane hosts, so a change to the chat is one change.
const chatShell = document.getElementById("chat");
const messages = chatShell.content;
// The transcript a render is pointed at. The window's own conversation is the default; a child
// pane's transcript is this same renderer aimed at a second container (see paintChildTranscript),
// which is what makes "a ledger row becomes a bubble" one implementation rather than one per
// surface. Two renderers is how a child grew an `Earlier messages` control and a `Load original
// message 3` button that the conversation it is a view of never had.
let transcript = messages;
// Assistive technology hears new messages as they arrive, and the composer has a name, not only a
// placeholder.
messages.setAttribute("role", "log");
messages.setAttribute("aria-live", "polite");
const jump = document.getElementById("jump");
const meta = document.getElementById("meta");
const form = chatShell.form;
const input = chatShell.input;
if (input && !input.getAttribute("aria-label")) input.setAttribute("aria-label", "Message wasm-agent");
// The draft's undo/redo are keyboard-only since the diff topic took the only toggle in the
// transcript: the two footer buttons acted on the *draft* while looking like they acted on
// the conversation, and the transcript is where the reader looks for "undo the last thing".
// Ctrl+Z / Ctrl+Shift+Z still work, and they are the controls a text box is expected to have.
const panel = document.getElementById("panel");
const sendButton = chatShell.send;
const statusBtn = document.getElementById("status-btn");
const chipModel = document.getElementById("chip-model");
const chipUsage = document.getElementById("chip-usage");
const composerModel = chatShell.modelEl;
const balloon = document.getElementById("status-balloon");
// Built here rather than in the markup: it lives in the account balloon now, and that balloon is
// drawn from JS. The id is stable, so everything that reads the selection keeps working.
const nodeSelect = document.createElement("select");
nodeSelect.id = "node-select";
nodeSelect.className = "wa-select";
const providerSelect = document.getElementById("provider-select");
const modelSelect = document.getElementById("model-select");
const reasoningSelect = document.getElementById("reasoning-select");
const settingsNote = document.getElementById("settings-note");
const harnessStatus = document.getElementById("harness-status");
const settingsError = document.getElementById("settings-error");
const contextBox = document.getElementById("context-box");
const limitsBox = document.getElementById("limits-box");
const usageBox = document.getElementById("usage-box");
const popFoot = document.getElementById("pop-foot");
const micButton = document.getElementById("mic");
const attachButton = chatShell.attach;
const fileInput = chatShell.file;
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
const orchestratorBtn = document.getElementById("orchestrator-btn");
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
let observedRun = null;
const composerBusy = () => busy || observedRun?.session === chatSession;
// Stop belongs to the request this window submitted. A conversation may have an older run
// executing while this request waits behind it, so cancellation must carry this request's id.
let activeRunId = null;
let submittedRunIds = null;
// A new submission in the same conversation is still a new renderer owner.
// Node/session epochs alone cannot fence an older transcript/health response.
let submissionEpoch = 0;
const ownStreamActive = () => busy && controller !== null;
let statusLine = null;
// The status line's parts, held by reference. Reaching back into the DOM for them on every
// streamed chunk would make the line depend on a parser that a stub document does not have,
// and three references are cheaper than three queries anyway.
let statusLabel = null;
let statusPhase = null;
let statusElapsed = null;
let statusSpinner = null;
// The body of the newest assistant bubble, tracked as it is created: the run status is
// attached to it when a run finishes, and finding it by querying the transcript would be
// the same dependency in another place.
let lastAssistantBody = null;
let runStatusTicker = null;
let streamBody = null;
let streamText = "";
let phasePendingText = new Map();
let controller = null;
// The one check that may decide the run this window is watching is over. `send()` arms it for the run it
// starts and clears it when the run ends; anything outside that closure (the UI harness) can run exactly
// one check through it, which is how the false-alarm decision is exercised without waiting for the
// 30-second silence the timer waits for.
let checkWatchedRun = null;
// The attachment list and its strip are the shell's; these two names stay because the draft's undo
// stack and the harness's probe address them.
const attachments = chatShell.attachments;
function renderAttachments() { chatShell.renderAttachments(); }
let settings = { provider: "", model: "", providers: [], usage: {}, stats: {}, configured: false, base_url: "" };
let lastUsedModel = "";
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
const NEW_SESSION_KEY = "wa-new-session";
const DRAFT_KEY = "wa-draft";
let chatSession = "";
try { chatSession = localStorage.getItem(SESSION_KEY) || ""; } catch (error) { chatSession = ""; }
let blankSession = "";
try { blankSession = localStorage.getItem(NEW_SESSION_KEY) || ""; } catch (error) { blankSession = ""; }
// Async reads and streams belong to the conversation that started them. A session switch increments
// this value so a late response from the old thread cannot repaint the new one.
let conversationEpoch = 0;

function rememberSession(id) {
  if (!id || id === chatSession) return false;
  chatSession = id;
  orchestrationMode=null;
  delete messages.dataset.debug;
  conversationEpoch += 1;
  resetConversationFollowState();
  try { localStorage.setItem(SESSION_KEY, id); } catch (error) { /* private mode */ }
  return true;
}

function rememberNode(node) {
  if (node === activeNode) return false;
  detachConversationView();
  activeNode = node;
  orchestrationMode=null;
  delete messages.dataset.debug;
  conversationEpoch += 1;
  invalidateHookInventory();
  resetConversationFollowState();
  metaReady = false;
  return true;
}

function rememberBlankSession(id) {
  blankSession = id || "";
  try {
    if (blankSession) localStorage.setItem(NEW_SESSION_KEY, blankSession);
    else localStorage.removeItem(NEW_SESSION_KEY);
  } catch (error) { /* private mode */ }
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
// Preserve durable state and live sockets when hidden; pause only optional visual/status work.
function uiVisible() { return !document.hidden && !document.body.classList.contains('compact'); }
function setText(node, text) {
  const value=String(text ?? '');
  if(node && node.textContent!==value) node.textContent=value;
}
let apiTimeout = 8000;
function apiFetch(path, options = {}, timeout = apiTimeout) {
  if (!timeout || options.signal) return fetch(path, options);
  const control = new AbortController();
  const timer = setTimeout(() => control.abort(new DOMException((options.method || "GET") + " " + path + ": deadline " + timeout + "ms", "AbortError")), timeout);
  return fetch(path, Object.assign({}, options, { signal: control.signal }))
    .catch((error) => {
      const problem = new Error((options.method || "GET") + " " + path + ": " + String(control.signal.aborted ? control.signal.reason : error.message || error));
      problem.name = error.name || "Error";
      throw problem;
    })
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
// a stranger's run finished. `/health` carries the conversation (`session`) on every node-thread and on
// `current`, so the match is exact. With no session known yet the window claims no run, which is the
// safe default - it has no transcript to reconcile.
function sessionRunEntry(entry) {
  if (!entry?.session || entry.role === "reads") return false;
  return /^POST \/(?:node\/)?chat(?:\?|$)/.test(entry.label || "")
    || entry.label === "child completion"
    || (entry.role === "runs" && runKey(entry) !== null);
}

function activeRun(health, session = chatSession) {
  if (!session) return null;
  const mine = (entry) => sessionRunEntry(entry) && entry.session === session;
  const thread = (health?.node_threads || []).find(mine) || (mine(health?.current) ? health.current : null);
  if (thread) return thread;
  // Queued/background admissions also own the conversation before a thread reports its label.
  const run = (health?.runs || []).find((entry) => entry.conversation === session
    && (!entry.state || ["accepted", "queued", "running", "admitted", "behind"].includes(entry.state)));
  return run ? { ...run, session } : null;
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

function safeLinks(html) {
  const template=document.createElement('template');template.innerHTML=html;
  for(const link of template.content.querySelectorAll('a')) {
    const href=link.getAttribute('href') || '';
    if(!/^(https?:\/\/|mailto:|file:\/\/)/i.test(href) || /[\u0000-\u0020]/.test(href)) {
      link.replaceWith(...link.childNodes);continue;
    }
    link.target='_blank';link.rel='noopener noreferrer';
  }
  const walker=document.createTreeWalker(template.content,NodeFilter.SHOW_TEXT);
  const nodes=[];while(walker.nextNode())nodes.push(walker.currentNode);
  for(const node of nodes) {
    if(node.parentElement?.closest('a,pre,code,script,style'))continue;
    const re=/https?:\/\/[^\s<>"']+/g;let match,last=0;const parts=[];
    while((match=re.exec(node.textContent))) {
      const url=match[0].replace(/[.,;!?)}\]]+$/,'');
      parts.push(document.createTextNode(node.textContent.slice(last,match.index)));
      const a=document.createElement('a');a.href=url;a.textContent=url;a.target='_blank';a.rel='noopener noreferrer';parts.push(a);
      last=match.index+url.length;re.lastIndex=match.index+match[0].length;
    }
    if(parts.length) {parts.push(document.createTextNode(node.textContent.slice(last)));node.replaceWith(...parts);}
  }
  return template.innerHTML;
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
      const html = new TextDecoder().decode(new Uint8Array(renderer.memory.buffer, outPointer, outLength));
      // Both buffers go back to the module; without this every render leaked its input and output.
      if (renderer.dealloc) { renderer.dealloc(pointer, bytes.length); renderer.dealloc(outPointer, outLength); }
      return safeLinks(enhanceCodeBlocks(html));
    } catch (error) { /* fall through */ }
  }
  return safeLinks(escapeHtml(text).replace(/\n/g, "<br>"));
}

// Content is preserved verbatim. Only actual typed reasoning events belong in thinking;
// inferring a channel from text markers erased legitimate answers and their evidence.
function stripThinking(text) {
  return String(text).trim();
}

function atBottom(slack = 40) {
  return transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight < slack;
}

// Sticky scroll. "Follow the bottom" is the default, and it stops only when the
// reader moves away - so reading scrollback is not interrupted by new output,
// and returning to the bottom resumes following. `follow` is only changed by the
// reader's own scrolling: our programmatic pins set `pinning` first so the scroll
// event they cause cannot be mistaken for intent.
let follow = true;
let pinning = false;
// Anchors belong to containers, including independently painted child chats.
const answerAnchors = new WeakMap();
const childScrollStates = new WeakMap();
function scrollState(container) {
  let state=childScrollStates.get(container);
  if (!state) {state={follow:true,pinning:false};childScrollStates.set(container,state);}
  return state;
}
const answerSeen = new WeakMap();
const answerReleased = new WeakSet();
const answerScrollPositions = new WeakMap();
function releaseAnswerAnchor(container = transcript, manual = true) {
  answerAnchors.delete(container);
  if (manual) {
    answerScrollPositions.delete(container);
    answerReleased.add(container);
    if (container===messages) setFollow(false);
    else scrollState(container).follow=false;
  }
}
function anchorAnswer(node) {
  if (replayingMessages || answerReleased.has(transcript)) return;
  const container = transcript;
  // Start reading with the first visible chunk, even before its provider phase
  // is known. This is a scroll policy, never evidence of a final/settled answer.
  // Do not steal a reader already in scrollback; an existing anchor may transfer
  // from provisional text to the confirmed answer in the same event turn.
  const following = container === messages ? follow : scrollState(container).follow;
  if (!following && !answerAnchors.has(container)) return;
  answerAnchors.set(container, node);
  for (const gesture of ['wheel', 'touchstart']) {
    container.addEventListener(gesture, () => { releaseAnswerAnchor(container); if(container===messages)setFollow(false); }, {passive:true, once:true});
  }
  container.addEventListener('keydown', event => {
    if (['PageUp','PageDown','ArrowUp','ArrowDown','Home','End',' '].includes(event.key) &&
      !event.target.closest('input,textarea,[contenteditable]')) releaseAnswerAnchor(container);
  });
  container.addEventListener('scroll', () => {
    const expected=answerScrollPositions.get(container);
    if (expected != null && Math.abs(container.scrollTop-expected)<1) return;
    releaseAnswerAnchor(container);
    const bottom=container.scrollHeight-container.scrollTop-container.clientHeight<40;
    if (container===messages) setFollow(bottom);
    else scrollState(container).follow=bottom;
  }, {passive:true});
  pin();
}

function pin(force = false) {
  const container=transcript;
  const state=container===messages ? null : scrollState(container);
  const answer = answerAnchors.get(transcript);
  if (answer?.isConnected && !force) {
    if (state) state.pinning=true; else pinning = true;
    // Clamp to the available scroll range: short output grows upward from the
    // bottom; once its start reaches the viewport top, only the overflow grows.
    const start = container.scrollTop + answer.getBoundingClientRect().top - container.getBoundingClientRect().top;
    const target = Math.max(0, Math.min(start, container.scrollHeight - container.clientHeight));
    if (Math.abs(container.scrollTop - target) >= 1) container.scrollTop = target;
    answerScrollPositions.set(transcript, transcript.scrollTop);
    requestAnimationFrame(() => { if(state)state.pinning=false;else pinning = false; });
    return;
  }
  if (!(state ? state.follow : follow) && !force) return;
  if(state)state.pinning=true;else pinning = true;
  transcript.scrollTop = transcript.scrollHeight;
  answerScrollPositions.set(container,container.scrollTop);
  // Release on the next frame: the scroll event fires asynchronously.
  requestAnimationFrame(() => { if(state)state.pinning=false;else pinning = false; });
}

function setFollow(value) {
  follow = value;
  jump.classList.toggle("show", !follow);
}

messages.addEventListener("scroll", () => {
  const expected = answerScrollPositions.get(messages);
  // Scroll delivery can follow the frame that cleared pinning. A position we
  // just set is still programmatic, not a reader opting out of answer-start.
  if (pinning || (expected != null && Math.abs(messages.scrollTop - expected) < 1)) return;
  releaseAnswerAnchor();
  setFollow(atBottom());
}, { passive: true });

// The reader's intent, not just the scroll position: a wheel tick or a drag
// upwards should release the follow even before the bottom is out of view.
for (const event of ["wheel", "touchstart"]) {
  messages.addEventListener(event, () => setFollow(atBottom(4)), { passive: true });
}
messages.addEventListener("keydown", (event) => {
  if (["PageUp", "PageDown", "ArrowUp", "ArrowDown", "Home", "End", " "].includes(event.key)) releaseAnswerAnchor();
  if (["PageUp", "ArrowUp", "Home"].includes(event.key)) setFollow(false);
  if (["PageDown", "ArrowDown", "End"].includes(event.key)) setFollow(atBottom());
});

// Content can grow without an append (markdown re-render, a topic opening,
// images): re-pin whenever the scroll height changes, if we are following.
if (typeof ResizeObserver === "function") {
  new ResizeObserver(() => pin()).observe(messages);
}
jump.addEventListener("click", () => { releaseAnswerAnchor(messages); setFollow(true); pin(true); });

// One assistant bubble per run. Decisions and their tool topics live *inside*
// it as stacked segments: separate bubbles put a border between every step,
// which reads as a divider between unrelated messages instead of one reply that
// thought, used tools, thought again, and answered. When the answer is ready the
// whole path collapses into a single run topic at the top of the bubble.
let runBubble = null;
let runStartedAt = 0;
let runStepState = null;
let runCounts = null;
const measuredContexts = new WeakMap();
let rendererTask=null;
const childRenderStates=new WeakMap();

function applyRunCounts(counts) {
  if (counts?.version !== 1 || typeof counts.run_id !== 'string' || !counts.run_id ||
      !Number.isSafeInteger(counts.model_calls) || counts.model_calls < 0 ||
      !Number.isSafeInteger(counts.tool_calls) || counts.tool_calls < 0) return;
  if (runCounts?.run_id === counts.run_id &&
      (counts.model_calls < runCounts.model_calls || counts.tool_calls < runCounts.tool_calls ||
       (counts.usage_calls ?? 0)<(runCounts.usage_calls ?? 0))) return;
  runCounts = {...counts, scope:runStepScope()};
  if(counts.context?.estimated===false && Number.isSafeInteger(counts.context.tokens) && counts.context.tokens>=0)
    measuredContexts.set(transcript,{...counts.context,scope:runStepScope()});
  if(transcript===messages) updateContextReadouts();
  updateRunElapsed();
}

function runCountsFooter(duration) {
  const prefix = replayingMessages && runCounts && !runCounts.complete ? '≥' : '';
  if (replayingMessages && runCounts?.complete && Number.isFinite(runCounts.elapsed_ms) && runCounts.elapsed_ms >= 0)
    duration = runDuration(runCounts.elapsed_ms);
  return `✧ ${prefix}${runCounts?.model_calls ?? '?'} · ⚒ ${prefix}${runCounts?.tool_calls ?? '?'} · ◷ ${duration}`;
}

function turnTokenReadout() {
  if(!Number.isSafeInteger(runCounts?.tokens_reported))return '?';
  const pending=runCounts.model_calls>(runCounts.usage_calls ?? 0);
  // Providers report usage at request completion, not every visible text chunk.
  // Never label a characters/4 guess or unseen reasoning as exact tokens.
  const prefix=runCounts.usage_unknown || pending ? '≥' : '';
  return prefix+formatTokens(runCounts.tokens_reported);
}
function turnIsActive() { return rendererTask ? !rendererTask.settled&&/^(running|accepted|queued|placing)$/.test(rendererTask.state) : busy || observedRun?.session === chatSession; }
function runStepScope() { return activeNode + ":" + (rendererTask?.session_id||chatSession) + ":" + conversationEpoch + (rendererTask?':'+(rendererTask.attempt_id||rendererTask.subagent_id):''); }
function runStepId() { return rendererTask ? rendererTask.attempt_id||rendererTask.subagent_id : busy ? runKey(activeRunId) : runKey(observedRun); }
function setTranscriptDebug(container, mode) {
  container.dataset.debug = String(mode === 'debug');
  if (container === transcript) {
    if (mode === 'debug' && runStepState?.active) {
      const step = runStepState.active;
      step.node.setStep(step.label, 'running', Date.now() - step.started);
    }
    updateRunPhase();
  }
  for (const topic of container.querySelectorAll('wa-run')) {
    const children = Array.from(topic.body.children);
    const steps = children.filter(node => node.classList.contains('seg') ||
      (mode === 'debug' && node.tagName === 'WA-STEP')).length;
    topic.setSummary(steps, topic.summary?.calls || 0, topic.summary?.ms ?? null);
  }
}
// Ordered small → full star → small. The fixed slot keeps the phase/timers still.
const runActivityGrowth = ['·', '•', '✧', '✦', '✶', '✳', '✺'];
const runActivityFrames = runActivityGrowth.map((glyph, index) => ({glyph, size: 7 + index}));
runActivityFrames.push(...runActivityFrames.slice(1, -1).reverse());
function updateRunPhase() {
  if (!statusPhase) return;
  const step = runStepState?.active;
  const live = !!step && !replayingMessages && !statusLine?.classList.contains('finished');
  statusPhase.hidden = !live;
  // Routine work needs one description: its measured phase, not a second label.
  if (statusLabel) statusLabel.hidden = !statusLabel.textContent;
  if (statusSpinner && live) {
    const frame = runActivityFrames[Math.max(0, Math.floor((Date.now() - (runStartedAt || step.started)) / 1000)) % runActivityFrames.length];
    setText(statusSpinner, frame.glyph);
    const size = frame.size + 'px';
    if (statusSpinner.style.fontSize !== size) statusSpinner.style.fontSize = size;
  }
  if (live) {
    setText(statusPhase, Math.max(0, Math.floor((Date.now() - step.started) / 1000)) + 's');
    statusPhase.title = step.label;
  }
  else setText(statusPhase, '');
}
function finishRunStep(state = "completed") {
  const step = runStepState?.active;
  if (!step) return;
  step.state = state;
  step.ms = Date.now() - step.started;
  step.node.setStep(step.label, state, step.ms);
  runStepState.active = null;
  updateRunPhase();
}
function showRunStep(key, label) {
  if (replayingMessages) return;
  const scope = runStepScope(), id = runStepId();
  if (!runStepState || runStepState.scope !== scope ||
      (id && runStepState.id && id !== runStepState.id)) {
    runStepState = { scope, id, userSeq: null, steps: [], active: null };
  }
  if (id) runStepState.id = id;
  if (!runStepState.userSeq) {
    const users = transcript.querySelectorAll('wa-message[role="user"]');
    runStepState.userSeq = Number(users[users.length - 1]?.dataset.messageSeq) || null;
  }
  if (runStepState.active?.key === key) return;
  finishRunStep();
  const node = document.createElement("wa-step");
  const step = { node, key, label, started: Date.now(), state: "running", ms: 0, beforeCall: null, beforeContent: null };
  runStepState.steps.push(step);
  runStepState.active = step;
  currentBubble().body.append(node);
  node.setStep(label, "running", 0);
  if (!runStartedAt) runStartedAt = Date.now();
  if (turnIsActive()) setStatus('');
  updateRunPhase();
  keepStatusLast();
  pin();
}
function anchorRunSteps(callId) {
  if (replayingMessages || !callId) return;
  for (const step of runStepState?.steps || []) if (!step.beforeCall && !step.beforeContent) step.beforeCall = String(callId);
}
function anchorRunStepContent(node) {
  if (replayingMessages || !node) return;
  const position = Array.from(currentBubble().querySelectorAll(node.tagName)).indexOf(node);
  for (const step of runStepState?.steps || []) if (!step.beforeCall && !step.beforeContent) {
    step.beforeContent = {node,position};
  }
}
function restoreRunSteps(state, bubble) {
  if (!state || !bubble) return;
  for (const step of state.steps) {
    const line = Array.from(bubble.querySelectorAll('.tool-line[data-call-id]'))
      .find(node => node.dataset.callId === step.beforeCall);
    const trace = line?.closest("wa-trace");
    const anchor = step.beforeContent;
    const candidates = anchor ? Array.from(bubble.querySelectorAll(anchor.node.tagName)) : [];
    const messageId = anchor?.node.dataset.messageId;
    const content = !anchor ? null : messageId ? candidates.find(node => node.dataset.messageId === messageId)
      : candidates[anchor?.position]?.textContent === anchor?.node.textContent ? candidates[anchor.position] : null;
    if (content) content.parentNode.insertBefore(step.node, content);
    else if (trace) trace.parentNode.insertBefore(step.node, trace);
    else {
      const topic = bubble.body.querySelector(":scope > wa-run");
      if (topic) topic.body.append(step.node);
      else bubble.body.insertBefore(step.node, bubble.body.querySelector(":scope > .seg, :scope > .chat-content-run-status"));
    }
  }
  const topic = bubble.body.querySelector(":scope > wa-run");
  if (topic) {
    const children = Array.from(topic.body.children);
    const steps = children.filter(node => node.classList.contains("seg") ||
      (transcript.dataset.debug === 'true' && node.tagName === "WA-STEP")).length;
    const calls = children.filter(node => node.tagName === "WA-TRACE").reduce((sum,node) => sum + node.count, 0);
    topic.setSummary(steps, calls, topic.summary?.ms ?? null);
  }
}
function ensureObservedRunStep(current) {
  if (!current || !runBubble) return;
  if (runStepState?.settled && runStepState.scope === runStepScope() && runStepState.id === runKey(current)) return;
  if (!runStartedAt && Number.isFinite(Number(current.ms))) runStartedAt = Date.now() - Number(current.ms);
  if (!runStepState?.active || runStepState.scope !== runStepScope() ||
      (runStepId() && runStepState.id && runStepId() !== runStepState.id)) {
    showRunStep("working", "Working — waiting for the next step");
  }
  setStatus('');
}

// The status line belongs to the run in flight and must stay the *last* thing in the
// transcript while that run is happening. Created before the run's bubble exists, it was
// overtaken the moment the bubble was appended, so it drifted to the top of the bubble it
// describes - the wrong place to read it from, and not where the sticky rule expects it.
// Re-appending after anything new lands keeps it below; appending an existing child moves
// it, so this is the whole of it.
function keepStatusLast() {
  if (statusLine) {
    const owner=runBubble?.body || transcript;
    if (owner.lastElementChild!==statusLine) owner.append(statusLine);
  }
}

function currentBubble() {
  if (!runBubble) {
    transcript.querySelector('#empty')?.remove();
    answerReleased.delete(transcript);
    runBubble = document.createElement("wa-message");
    runBubble.setAttribute("role", "assistant");
    transcript.append(runBubble);   // connecting is what builds .body
    runBubble.body.classList.add("steps");
    keepStatusLast();
  }
  return runBubble;
}

function add(role, text, asHtml = false) {
  transcript.querySelector('#empty')?.remove();
  const element = document.createElement("wa-message");
  element.setAttribute("role", role);
  transcript.append(element);
  keepStatusLast();
  const body = element.body;
  if (asHtml) body.innerHTML = text; else body.textContent = text;
  if (role === "assistant") lastAssistantBody = body;
  pin();
  return body;
}

function appendMessageImages(body, images) {
  const visible = images.filter((image) => typeof image.data === "string" && image.data.startsWith("data:image/"));
  if (!visible.length) return;
  const gallery = document.createElement("div");
  gallery.className = "message-images";
  for (const attachment of visible) {
    const image = document.createElement("img");
    image.className = "message-image";
    image.src = attachment.data;
    image.alt = attachment.name || "attached image";
    if (attachment.name) image.title = attachment.name;
    gallery.append(image);
  }
  body.append(gallery);
}

function setStatus(text) {
  transcript.querySelector('#empty')?.remove();
  if (!statusLine) {
    statusLine = document.createElement("div");
    statusLine.className = "status chat-content-run-status";
    statusSpinner = document.createElement("span");
    statusSpinner.className = "run-activity-glyph";
    statusSpinner.setAttribute('aria-hidden', 'true');
    statusSpinner.textContent = runActivityFrames[0].glyph;
    statusSpinner.style.fontSize = runActivityFrames[0].size + 'px';
    statusLabel = document.createElement("span");
    statusLabel.className = "chat-content-run-label";
    statusPhase = document.createElement("span");
    statusPhase.className = "chat-content-run-phase";
    statusPhase.hidden = true;
    statusElapsed = document.createElement("span");
    statusElapsed.className = "chat-content-run-elapsed";
    statusLine.append(statusSpinner, statusLabel, statusPhase, statusElapsed);
    if (turnIsActive() && !replayingMessages) startRunStatusTicker();
  }
  setText(statusLabel, text);
  updateRunPhase();
  if (turnIsActive()) currentBubble();
  const container = runBubble?.body || transcript;
  if (statusLine.parentNode !== container) container.append(statusLine);
  if (turnIsActive()) {
    if (!replayingMessages) startRunStatusTicker();
    updateRunElapsed();
  }
  else statusElapsed.textContent = "";
  pin();
}

function runDuration(ms) {
  const total = Math.max(0, Math.floor(ms / 1000));
  const seconds = String(total % 60).padStart(2, "0");
  const minutes = Math.floor(total / 60);
  if (minutes >= 60) return `${Math.floor(minutes / 60)}:${String(minutes % 60).padStart(2, "0")}:${seconds}`;
  return `${minutes}:${seconds}`;
}

function updateRunElapsed() {
  for(const retry of runBubble?.querySelectorAll('wa-retry') || []) retry.setAge();
  const step = runStepState?.active;
  if (step && transcript.dataset.debug === 'true') step.node.setStep(step.label, "running", Date.now() - step.started);
  updateRunPhase();
  if (!statusElapsed) return;
  if (replayingMessages && (!runStartedAt || !replayMessageEndedAt)) {
    statusElapsed.textContent = "duration unknown";
    return;
  }
  // A repaint has no clock of its own: the run ended when its stored row says it did. Using
  // Date.now() there would print days on a footer for a turn that took four seconds - the same
  // mistake the run topic's own summary avoids by reading replayMessageEndedAt.
  const endedAt = replayingMessages && replayMessageEndedAt ? replayMessageEndedAt : Date.now();
  const duration=runDuration(endedAt - (runStartedAt || endedAt));
  setText(statusElapsed,!replayingMessages && runStepState?.active
    ? ` · ◈ ${turnTokenReadout()} · ✧ ${runCounts?.model_calls ?? '?'} · ⚒ ${runCounts?.tool_calls ?? '?'} · ◷ ${duration}` : duration);
  if(!replayingMessages&&runCounts?.context) {
    if(rendererTask)updateChildContextReadouts();else if(transcript===messages)updateContextReadouts();
  }
  statusElapsed.title='Turn provider-reported input + output: '+(Number.isSafeInteger(runCounts?.tokens_reported)?runCounts.tokens_reported.toLocaleString('en-US'):'unknown')+' tokens (cached input/retries/summaries included). ≥ means pending or missing usage; exact per-token streaming is unavailable.';
}

function startRunStatusTicker() {
  if (rendererTask) return; // Child host supplies its existing clock to this same renderer.
  if (runStatusTicker) return;
  runStatusTicker = setInterval(() => { if (uiVisible()) updateRunElapsed(); }, 1000);
}

function finishRunStatus(label = "completed") {
  if(transcript===messages)chatShell.warning.setNotice('active','');
  for(const retry of runBubble?.querySelectorAll('wa-retry') || [])
    retry.interrupt(label==='cancelled'?'cancelled':'unfinished');
  if (!replayingMessages) {
    finishRunStep(label === "failed" ? "failed" : label === "unfinished" ? "unfinished" : "completed");
    if (runStepState) runStepState.settled = true;
  }
  if (!statusLine) return;
  // The footer goes *inside the bubble's body*, after the answer, not on the custom element:
  // the element's children are its body and nothing else, so appending to it left the line
  // outside the message it belongs to.
  const body = runBubble ? runBubble.body : lastAssistantBody;
  statusSpinner?.remove();
  statusLabel.textContent = label;
  updateRunElapsed();
  statusElapsed.textContent = runCountsFooter(statusElapsed.textContent);
  statusElapsed.title = 'Provider-call attempts (includes retries/summaries, excludes internal transport reconnects) · requested tool calls · total duration; ? means unavailable, ≥ means last recorded lower bound';
  statusLine.classList.add("finished");
  updateRunPhase();
  if (body) body.append(statusLine);
  else statusLine.remove();
  statusLine = null;
  statusLabel = null; statusPhase = null; statusElapsed = null; statusSpinner = null;
  if (runStatusTicker) { clearInterval(runStatusTicker); runStatusTicker = null; }
  pin();
}

function clearStatus() {
  statusLine?.remove();
  statusLine = null;
  statusLabel = null; statusPhase = null; statusElapsed = null; statusSpinner = null;
  if (runStatusTicker) { clearInterval(runStatusTicker); runStatusTicker = null; }
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
let streamedCommentaryBlock = null;
let streamedCommentaryText = "";
function appendReasoning(text, complete = false) {
  if (!text && !complete) return reasoningText;
  const bubble = currentBubble();
  if (!reasoningBlock || reasoningBlock.parentNode !== bubble.body) {
    // A topic like every other one: <wa-reasoning> builds the same header as the tool calls beside it,
    // so the thinking reads as a step of the same kind rather than as a different thing.
    reasoningBlock = document.createElement("wa-reasoning");
    reasoningBlock.open = !replayingMessages;
    bubble.body.append(reasoningBlock);
    anchorRunStepContent(reasoningBlock);
    reasoningText = "";
  }
  reasoningText = complete ? text : reasoningText + text;
  reasoningBlock.setText(reasoningText);
  pin();
  return reasoningText;
}

function appendCommentary(text, messageId, pendingId) {
  if (!text || (messageId && renderedMessageIds.has(String(messageId)))) return;
  const block = document.createElement("wa-commentary");
  block.open = true;
  block.setText(text);
  if(pendingId)block.dataset.pendingId=String(pendingId);
  if (messageId) {
    block.dataset.messageId = String(messageId);
    renderedMessageIds.add(String(messageId));
  }
  currentBubble().body.append(block);
  anchorRunStepContent(block);
  pin();
}

function appendStreamedCommentary(text, pendingId) {
  if (!text) return;
  const bubble = currentBubble();
  if(streamedCommentaryBlock && pendingId && streamedCommentaryBlock.dataset.pendingId!==String(pendingId))markStreamedCommentaryIncomplete();
  if (!streamedCommentaryBlock || streamedCommentaryBlock.parentNode !== bubble.body) {
    streamedCommentaryBlock = document.createElement("wa-commentary");
    streamedCommentaryBlock.classList.add("phase-pending");
    streamedCommentaryBlock.open = true;
    if(pendingId)streamedCommentaryBlock.dataset.pendingId=String(pendingId);
    bubble.body.append(streamedCommentaryBlock);
    anchorRunStepContent(streamedCommentaryBlock);
    streamedCommentaryText = "";
  }
  streamedCommentaryText += text;
  streamedCommentaryBlock.setText(streamedCommentaryText);
  pin();
}

function finishStreamedCommentary(messageId) {
  if (!streamedCommentaryBlock) return;
  const id = messageId == null ? "" : String(messageId);
  if (id && renderedMessageIds.has(id)) {
    streamedCommentaryBlock.remove();
  } else {
    if (id) {
      streamedCommentaryBlock.dataset.messageId = id;
      renderedMessageIds.add(id);
    }
    streamedCommentaryBlock.classList.remove("phase-pending", "phase-incomplete");
  }
  streamedCommentaryBlock = null;
  streamedCommentaryText = "";
}

function markStreamedCommentaryIncomplete() {
  if (!streamedCommentaryBlock) return;
  streamedCommentaryBlock.classList.remove("phase-pending");
  streamedCommentaryBlock.classList.add("phase-incomplete");
  streamedCommentaryBlock = null;
  streamedCommentaryText = "";
}

function removePendingText(id) {
  if (!id) return;
  const pending = phasePendingText.get(String(id));
  if (!pending) return;
  pending.node.remove();
  phasePendingText.delete(String(id));
}

function discardPendingText() {
  for (const pending of phasePendingText.values()) pending.node.remove();
  phasePendingText.clear();
}

function markPendingTextIncomplete() {
  for (const pending of phasePendingText.values()) {
    pending.node.classList.remove("phase-pending");
    pending.node.classList.add("phase-incomplete");
  }
  phasePendingText.clear();
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
function steeringCancellation(result) {
  let value=result;
  // Historical replay wraps the original JSON in content; never infer cancellation from prose.
  if (value && typeof value.content==='string' && Object.keys(value).length===1) {
    try { value=JSON.parse(value.content); } catch { return false; }
  }
  return !!value && value.error==='superseded_by_steering' && value.executed===false
    && value.effect==='none' && (value.ok===undefined || value.ok===false) && value.code===undefined;
}
function toolOutcome(name, result) {
  const r = result || {};
  if (steeringCancellation(r)) return {text:'not executed · superseded', cancelled:true, failed:false};
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
  const callId = options && options.callId != null ? String(options.callId) : "";
  showRunStep("tools", "Executing tools");
  if (!replayingMessages && trace && runStepState?.active) trace.parentNode.insertBefore(runStepState.active.node, trace);
  anchorRunSteps(callId);
  if (callId && trace?.hasPendingCall(callId)) {
    if (!replayingMessages) startToolTicker();
    return;
  }
  currentTrace().addTool(name, toolTitle(name, args), null, boundMs ? Math.round(boundMs / 1000) : null, callId);
  lastTool = name;
  if (!replayingMessages) startToolTicker();
  pin();
}

function addDecision(event) {
  showRunStep("decision", "Selecting tools");
  currentTrace().addDecision(event.call_id, event.name, event.arguments_text || "",
    event.complete === true, event.previous_call_id);
  pin();
}

function startToolTicker() {
  if (toolTicker) return;
  toolTicker = setInterval(() => {
    if (!trace || !trace.pending) { stopToolTicker(); return; }
    if (uiVisible()) trace.setAge();
  }, 1000);
}

function stopToolTicker() {
  if (toolTicker) { clearInterval(toolTicker); toolTicker = null; }
}

function settleTool(result, name, failed, cancelled) {
  if (!trace) return;
  const outcome = toolOutcome(name || lastTool, result);
  // The ledger's own verdict, where the caller has one, outranks what the payload looks like: a
  // replayed `ok: 0` row carries no exit code, and reading it as a success is how a failed call came
  // back after a reload as a green line.
  const notExecuted=cancelled!==false && outcome.cancelled===true;
  trace.settle(outcome.text, toolDetail(result), notExecuted ? false : failed === undefined ? outcome.failed : failed === true, notExecuted);
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
// `bash` blocks its node-thread and returns nothing until it settles, so the window otherwise shows
// only a clock - and a five-minute build is indistinguishable from a hang. The node already
// publishes the running operation on /health (`operations[]`) and its output through
// /operation; this reads both. `running` is the busy run for *this* window.
//
// The line always says the state and how much has been written, even when that is nothing: a
// silent command is a fact, and `running · 0 B` is more honest than an empty line that looks
// like the preview failed. Output bytes are not proof of useful progress (a quiet compiler is
// healthy), so the newest line is appended when there is one, not invented when there is not.
async function refreshOperationProgress(health, running) {
  const activeTrace = trace;
  if (!activeTrace || !activeTrace.pending || !running) return;
  // The owner is `run:<run_id>` - serve.rs sets it for the run before the interpreter starts,
  // so an in-turn operation carries the run, not the node-thread. An operation launched outside a run
  // carries the node-thread instead. A node built before this rename reports that id as `worker_id`
  // and an even older one as `id`, so all three spellings are read: the window works against
  // whichever node it is attached to. The `worker:` *prefix* is the operation record's own durable
  // value (rust/wa-operation), not a health field, so it keeps its name too.
  const owners = [];
  if (running.run_id != null) owners.push("run:" + runKey(running));
  const nodeThreadId = running.node_thread_id != null
    ? running.node_thread_id
    : (running.worker_id != null ? running.worker_id : running.id);
  if (nodeThreadId != null) owners.push("worker:" + nodeThreadId);
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
  // The operation read above is asynchronous. A reply, repaint, or session switch can finish
  // and detach this trace while it waits; only paint if this is still the live trace.
  if (trace !== activeTrace || !activeTrace.pending || typeof activeTrace.setProgress !== "function") return;
  activeTrace.setProgress((operation.state || "running") + " · " + formatBytes(bytes) + (tail ? " · " + tail : ""));
}

// The answer is the point; the route is reference. On reply, everything the run
// did before the answer moves into one collapsed run topic at the top of the
// bubble, and the answer sits below it.
function collapseRun(finalStart = false) {
  const bubble = runBubble;
  if (!bubble) return;
  const body = bubble.body;
  const answer = streamBody;
  // One run topic per bubble. A run that answers more than once - a preamble, then the answer -
  // reuses the topic it already has: creating a second one nests the first inside it, and the
  // reader then opens topics to reach topics.
  const existing = Array.prototype.find.call(body.children, (c) => c.tagName === "WA-RUN");
  const moves = Array.prototype.filter.call(body.children,
    (c) => c !== answer && c !== existing && c.tagName !== "WA-DIFF" && c.tagName !== "WA-COMMENTARY" && c !== statusLine);
  const traces = moves.filter((c) => c.tagName === "WA-TRACE");
  // A run topic is only created once something actually ran - a run that never called a tool keeps
  // its plain answer. But once a topic exists, a later reply must still fold the previous answer into
  // it even when that batch added no tool call: the guard is about *creating* the topic, not about
  // folding into one that is already there. Getting this wrong left the preamble sitting outside as
  // its own text segment, so the bubble read run,text,text instead of one run and one answer.
  if (!existing && traces.length === 0 && !moves.some(c=>c.tagName==='WA-RETRY') && !finalStart) return;
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
    else if (child.classList?.contains("seg") || (transcript.dataset.debug === 'true' && child.tagName === "WA-STEP")) steps += 1;
  }
  if (finalStart) run.open = false;
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

function paintDelta() {
  if (!streamBody) return;
  // Formatting is presentation, not proof of provider phase or completion.
  streamBody.innerHTML = renderMarkdown(stripThinking(streamText));
  streamBody.style.whiteSpace = 'normal';
  pin();
}

// A retry never rolls back effects. It seals ONLY provisional model output;
// the bridge supplies a retained interrupted snapshot before regenerating it.
function interruptSubscriptionAttempt(saved) {
  if (!saved || saved.tools_executed !== 0 || typeof saved.id !== 'string' ||
      typeof saved.reasoning !== 'string' || !Array.isArray(saved.texts) || !Array.isArray(saved.decisions)) return;
  const bubble=currentBubble();
  if (Array.from(bubble.querySelectorAll('[data-interrupted-attempt]')).some(node=>node.dataset.interruptedAttempt===saved.id)) return;
  finishRunStep('unfinished');
  for (const item of saved.texts) {
    if (typeof item.pending_id !== 'string' || typeof item.text !== 'string') continue;
    let node=Array.from(bubble.querySelectorAll('[data-pending-id]')).find(node=>node.dataset.pendingId===item.pending_id);
    if (!node && item.text) {
      node=document.createElement('div');node.className='seg';node.textContent=item.text;
      node.dataset.pendingId=item.pending_id;bubble.body.append(node);
    }
    if (node) {node.classList.remove('phase-pending','final-answer');node.classList.add('phase-incomplete');}
  }
  if (saved.reasoning) {
    appendReasoning(saved.reasoning,true);
    reasoningBlock?.classList.add('phase-incomplete');
  }
  if (!trace && saved.decisions.length) {
    for (const item of saved.decisions) currentTrace().addDecision(item.call_id,item.name,item.arguments_text,item.complete,item.previous_call_id);
  }
  const marker=document.createElement('div');marker.className='patch-note';
  marker.dataset.interruptedAttempt=saved.id;
  marker.textContent='Interrupted model attempt — preserved, not executed; regenerating response';
  bubble.body.append(marker);
  markPendingTextIncomplete();markStreamedCommentaryIncomplete();
  if (streamBody) streamBody.classList.add('phase-incomplete');
  flushDecision();
  delete bubble.dataset.finalMessage;
  releaseAnswerAnchor(transcript,false);
}

function handleEvent(event) {
  if (!replayingMessages && transcript===messages && !['done','error'].includes(event.type)) markRunStreamAlive();
  if (["round", "reasoning", "commentary", "commentary_delta", "commentary_end", "pending_delta", "decision", "tool", "tool_result", "delta", "reply", "error", "done"].includes(event.type)) {
    if(transcript===messages)clearActiveRunNotice();
  }
  if (event.type === 'delegated') {
    if(event.task?.subagent_id)renderSubagentCard(event.task);
  } else if (event.type === "final_answer_begin") {
    const bubble = currentBubble();
    const key = [event.run_id || '', event.response_id || '', event.message_id || event.pending_id || ''].join('|');
    if (!event.message_id && !event.pending_id) return;
    let seen=answerSeen.get(bubble);
    if (!seen) {seen=new Set();answerSeen.set(bubble,seen);}
    if (seen.has(key)) return;
    seen.add(key);
    if (streamBody) flushDecision();
    bubble.dataset.finalMessage = key;
    if (!streamBody) {
      streamBody = document.createElement('div');
      streamBody.className = 'seg final-answer';
      bubble.body.append(streamBody);
    }
    collapseRun(true);
    if (!answerReleased.has(transcript)) anchorAnswer(streamBody);
  } else if (event.type === "retry") {
    const index=Number(event.index),limit=Number(event.limit);
    if(!Number.isInteger(index)||index<1||!Number.isInteger(limit)||limit<1||limit>10||index>limit)return;
    if(event.state==='interrupted')interruptSubscriptionAttempt(event.discarded_attempt);
    const bubble=currentBubble(),id=String(event.retry_id || 'subscription-recovery');
    let retry=Array.from(bubble.querySelectorAll('wa-retry')).find(node=>node.dataset.retryId===id);
    if(!retry){retry=document.createElement('wa-retry');retry.dataset.retryId=id;bubble.body.append(retry);}
    retry.update(event);
    if(!replayingMessages) {
      showRunStep('retry:'+id+':'+(event.cycle||1)+':'+event.index+':'+event.state,
        event.state==='reconnecting'?'Reconnecting in 3 minutes':'Retry '+event.index+'/'+event.limit+' — '+event.state);
      setStatus('Retry '+event.index+'/'+event.limit+' — '+(event.reason || event.state));
    }
  } else if (event.type === "round") {
    releaseAnswerAnchor(transcript, false);
    // A new step begins: close the previous one (its text and its tool topic).
    if (!runStartedAt) runStartedAt = Date.now();
    markStreamedCommentaryIncomplete();
    flushDecision();
  } else if (event.type === "run_counts") {
    applyRunCounts(event.counts);
  } else if (event.type === "checkpoint") {
    if (runStepState && !runStepState.userSeq && !trace) runStepState.userSeq = Number(event.seq) || null;
  } else if (event.type === "node") {
    // Another window renamed this node, or this one did: either way the name is the node's,
    // so take it from the event and let the list catch up.
    if (event.name) updateNodeLabel(event.name, event.worktree);
    refreshNodes();
  } else if (event.type === "status") {
    const note = event.text || "working";
    showRunStep(note === "model" ? "model" : note === "thinking" ? "preparing" : "status:" + note,
      note === "model" ? "Reasoning" : note === "thinking" ? "Preparing turn" : note);
    setStatus(note === "model" || note === "thinking" ? "" : "wasm-agent is " + note + "…");
  } else if (event.type === "commentary") {
    showRunStep("commentary", "Progress update");
    const pending = phasePendingText.get(String(event.pending_id || ''));
    if (pending?.node === answerAnchors.get(transcript)) releaseAnswerAnchor(transcript, false);
    removePendingText(event.pending_id);
    if(streamedCommentaryBlock && (!event.pending_id || streamedCommentaryBlock.dataset.pendingId===String(event.pending_id))) {
      streamedCommentaryBlock.setText(event.text || streamedCommentaryText);
      finishStreamedCommentary(event.message_id);
    } else appendCommentary(event.text || "", event.message_id, event.pending_id);
  } else if (event.type === "commentary_delta") {
    showRunStep("commentary", "Progress update");
    appendStreamedCommentary(event.text || "",event.pending_id);
  } else if (event.type === "commentary_end") {
    finishStreamedCommentary(event.message_id);
  } else if (event.type === "reasoning") {
    showRunStep("reasoning", "Reasoning");
    // A reasoning model can think for a long time before it says anything, and a
    // silent panel is indistinguishable from a hung one. Keep the reasoning
    // topic; the compact measured phase provides the live "not hung" signal.
    appendReasoning(event.text || "", event.complete === true);
    if (!replayingMessages) setStatus("");
  } else if (event.type === "decision") {
    addDecision(event);
  } else if (event.type === "tool") {
    releaseAnswerAnchor(transcript, false);
    if (streamBody?.classList.contains('final-answer')) {
      streamBody.classList.remove('final-answer');
      flushDecision();
      collapseRun();
    }
    // The bound travels with the tool event when the host enforces one (bash/shell); /health is the
    // fallback so an in-flight line still says "of 300s" instead of only "42s".
    const boundMs = event.timeout_ms != null ? event.timeout_ms
      : (event.name === "bash" || event.name === "shell" ? execTimeoutSeconds * 1000 : null);
    addTool(event.name, event.arguments, { timeoutMs: boundMs, callId: event.call_id });
  } else if (event.type === "tool_result") {
    settleTool(event.result, event.name, event.failed, event.cancelled);
  } else if (event.type === "pending_delta") {
    showRunStep("output", "Model output");
    const key = String(event.pending_id || "");
    if (!key) return;
    if (statusLabel) { setText(statusLabel, ''); updateRunPhase(); }
    let pending = phasePendingText.get(key);
    if (!pending) {
      const node = document.createElement("div");
      node.className = "seg phase-pending";
      node.dataset.pendingId=key;
      currentBubble().body.append(node);
      anchorRunStepContent(node);
      pending = { node, text: "" };
      phasePendingText.set(key, pending);
      anchorAnswer(node);
    }
    pending.text += event.text || "";
    pending.node.rawText = pending.text;
    pending.node.innerHTML = renderMarkdown(pending.text);
    pending.node.style.whiteSpace = 'normal';
    pin();
  } else if (event.type === "delta") {
    showRunStep("answer", "Writing response");
    removePendingText(event.pending_id);
    if (statusLabel) { setText(statusLabel, ''); updateRunPhase(); }
    // A new segment per step, inside the same bubble.
    if (!streamBody) {
      streamBody = document.createElement("div");
      streamBody.className = "seg";
      currentBubble().body.append(streamBody);
      anchorRunStepContent(streamBody);
      anchorAnswer(streamBody);
    }
    if(event.pending_id)streamBody.dataset.pendingId=String(event.pending_id);
    streamText += event.text || "";
    streamBody.rawText=streamText;
    // Keep streaming observable synchronously, including background tabs where
    // animation frames may stop. Allocation reclamation bounds renderer growth.
    paintDelta();
  } else if (event.type === "reply") {
    if (!replayingMessages) finishRunStep();
    discardPendingText();
    markStreamedCommentaryIncomplete();
    if (statusLabel) { setText(statusLabel, 'finishing…'); updateRunPhase(); }
    if (!replayingMessages && event.message_id && renderedMessageIds.has(String(event.message_id))) {
      // The durable reply can be repainted before its trailing `reply` event is replayed.
      // Keep the saved bubble and let `done` settle it without appending the answer twice.
      sealReasoning();
      finishTrace();
      streamBody = null;
      streamText = "";
      return;
    }
    const finalText = stripThinking(event.text || streamText);
    const newlyConfirmed = !streamBody?.classList.contains('final-answer');
    if (streamBody) {
      if (event.message_id) streamBody.dataset.messageId = event.message_id;
      streamBody.innerHTML = renderMarkdown(finalText);
      streamBody.rawText=event.text || streamText;
      streamBody.style.whiteSpace = "normal";
    } else {
      const segment = document.createElement("div");
      segment.className = "seg";
      segment.innerHTML = renderMarkdown(finalText);
      segment.rawText=event.text || streamText;
      if (event.message_id) segment.dataset.messageId = event.message_id;
      currentBubble().body.append(segment);
      anchorRunStepContent(segment);
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
    if (newlyConfirmed && !answerReleased.has(transcript)) anchorAnswer(streamBody);
    sealReasoning();
    const diff = renderDiff(currentBubble(), event.changes);
    if (diff) {
      diff.dataset.messageId = event.message_id || "";
      if (diff.dataset.messageId) askUndoable(diff);
    }
    streamBody = null;
    streamText = "";
    if (event.message_id) renderedMessageIds.add(String(event.message_id));
    // The bubble stays open for the rest of the run. A model that speaks between tool batches is
    // still one run, and the run topic has to be able to span everything it did; closing the bubble
    // here was the bug - one run drew one bubble per reply. flushDecision(true) closes it, on `done`
    // or on the next user turn, which is the contract its own comment already stated.
  } else if (event.type === "usage") {
    if(rendererTask){updateChildContextReadouts();return;}
    settings.usage = event.total || settings.usage;
    if (event.model) {
      lastUsedModel = event.model;
      composerModel.hidden = true;
    }
    updateChip();
    if (balloon.open) { renderUsage(); renderControls(); }
  } else if (event.type === "error") {
    if(!replayingMessages&&transcript===messages)stopLiveness();
    releaseAnswerAnchor();
    markPendingTextIncomplete();
    markStreamedCommentaryIncomplete();
    add("assistant", "error: " + (event.error || "unknown"));
    finishRunStatus("failed");
    finishTrace();
    runBubble = null;
  } else if (event.type === "done") {
    if(!replayingMessages&&transcript===messages)stopLiveness();
    releaseAnswerAnchor();
    markPendingTextIncomplete();
    markStreamedCommentaryIncomplete();
    finishRunStatus();
    flushDecision(true);
  }
  keepStatusLast();
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
let replayRunLastMessage = null;
let renderedMessageIds = new Set();
function finishReplayedRun(isLast = false, options = {}) {
  // The last run's ledger state is authoritative. A saved interim answer may be followed by a
  // tool call and a stopped run; its bubble must not say "completed" above an unfinished notice.
  // An active run has no final duration yet. Earlier runs have no stored terminal state, so only
  // a final assistant answer (content and no tool calls) supports "completed" for them.
  if (!runBubble || (isLast && options.active)) { clearStatus(); return; }
  const finalAnswer = replayRunLastMessage?.role === "assistant" &&
    replayRunLastMessage.phase !== "commentary" &&
    !!replayRunLastMessage.content && !(replayRunLastMessage.tool_calls || []).length;
  let label = finalAnswer ? "completed" : "unfinished";
  if (isLast && options.state === "failed") label = "failed";
  else if (isLast && options.state === "unfinished") label = "unfinished";
  else if (isLast && options.state === "answered") label = "completed";
  const settledAt = Number(options.stateAt);
  if (isLast && Number.isFinite(settledAt) && settledAt > 0 &&
      label !== "completed" && settledAt * 1000 > replayMessageEndedAt) {
    replayMessageEndedAt = settledAt * 1000;
  }
  if (!statusLine) setStatus(label);
  finishRunStatus(label);
  for(const retry of runBubble?.querySelectorAll('wa-retry') || [])retry.freeze();
}
// ---- device notifications: the engine bell, and the native toast it turns on --------
//
// A settled child that owes a judgement reaches the operator as the wake the node already runs:
// `lua/core/completions.lua` decides `review.needs_wake`, and *only* where a judgement is owed does it
// start a coordinator run in this thread - whose first user row is the notice below. Nothing else
// writes that row, so this inherits that decision exactly: the classes the outbox skips (a
// self-reporting responder profile with nothing left to review, a cancelled child whose checkout is
// clean) never wake, so there is nothing here to notify about. No new polling loop either: this reads
// the transcript the page is already repainting (`restoreSession` on boot and `followRun` while a run
// is in flight), which is the same place the wake appears.
//
// The page does not raise the toast: a page has no process identity on the Windows notification
// platform. It asks the window shell, which raises it and answers (§window.wasmAgent.notify).
//
// The preference is device-local on purpose. Whether *this* machine should make a noise is a fact
// about this machine, not about the node, and a node setting would decide for the laptop and the
// phone at once.
const COMPLETION_NOTICE = "[Child completion notice]";
const NOTIFY_PREFERENCE_KEY = "wa.notify.settlement";
const NOTIFY_WATERMARK_KEY = "wa.notify.settlement.seen";

let notifyStorageAvailable = true;
let notifyShellState = "";
let lastNotifyResult = null;
// The engine card's own nodes, assigned where the engine is wired. `let` and guarded: a repaint that
// notifies must never be the thing that throws because a card is missing from the DOM.
let notifyBellEl = null;
let notifyStateNoteEl = null;
let notifyDetailEl = null;
let notifyResultEl = null;
let notifyTestEl = null;

/// "on" only when this device's own storage says so. Anything unreadable is **off**: a device that
/// cannot remember the choice has not been told to make a noise.
function notifyPreference() {
  try {
    return localStorage.getItem(NOTIFY_PREFERENCE_KEY) === "on" ? "on" : "off";
  } catch (error) {
    notifyStorageAvailable = false;
    return "off";
  }
}

function setNotifyPreference(on) {
  try {
    localStorage.setItem(NOTIFY_PREFERENCE_KEY, on ? "on" : "off");
    notifyStorageAvailable = true;
  } catch (error) {
    notifyStorageAvailable = false;
  }
}

/// A notice is marked seen whether or not the bell is on, so switching the bell on tells the operator
/// about the *next* settlement instead of replaying every one it slept through.
function rememberNotifyWatermark(session, seq) {
  try { localStorage.setItem(NOTIFY_WATERMARK_KEY, JSON.stringify({ session, seq })); }
  catch (error) { notifyStorageAvailable = false; }
}

function readNotifyWatermark(session) {
  try {
    const stored = JSON.parse(localStorage.getItem(NOTIFY_WATERMARK_KEY) || "null");
    if (stored && typeof stored === "object" && String(stored.session || "") === session) {
      const seq = Number(stored.seq);
      return Number.isFinite(seq) ? seq : -Infinity;
    }
  } catch (error) { /* unreadable or belonging to another thread: nothing has been seen in this one */ }
  return -Infinity;
}

/// The wake notices in a transcript, in ledger order.
function evaluationNotices(rows) {
  return (rows || []).filter((row) => row && row.role === "user" && typeof row.content === "string" &&
    row.content.startsWith(COMPLETION_NOTICE));
}

/// What the toast says, read out of the wake's own sentence. A notice whose shape is not the one
/// `completions.lua` writes still notifies - the wake is the evidence - but nothing about the child is
/// invented: the id and the reported state appear when they can be read, and are left out when they
/// cannot.
function settlementNotice(row) {
  const text = String(row.content || "");
  const id = (/^\[Child completion notice\] Task (\S+) settled\./.exec(text) || [])[1] || "";
  const state = (/Reported state: \{.*?"state":"([^"]*)"/.exec(text) || [])[1] || "";
  const what = id ? `Task ${id}${state ? ` settled (${state})` : " settled"}` : "a child task settled and owes an evaluation";
  return { title: "Evaluation owed", body: what };
}

/// Ask the window shell for a native notification. The shell answers with its own result
/// (`{supported, delivered, reason, identity, app_name}`); a surface with no shell answers with a
/// refusal that says so, because that is what happened - the page raised nothing itself.
async function raiseNotification({ title, body, diagnostic = false }) {
  const shell = native;
  if (!shell || typeof shell.notify !== "function") {
    lastNotifyResult = { supported: false, delivered: false,
      reason: "this surface has no window shell, so a page cannot raise a Windows notification" };
    return lastNotifyResult;
  }
  try {
    lastNotifyResult = await shell.notify({ title, body, diagnostic });
  } catch (error) {
    lastNotifyResult = { supported: false, delivered: false,
      reason: "the shell call failed: " + String((error && error.message) || error) };
  }
  return lastNotifyResult;
}

/// One toast for each settlement that owes an evaluation - and nothing at all when the bell is off.
/// Returns the notices it acted on, which is what a test asserts against.
function announceSettlements(rows) {
  const notices = evaluationNotices(rows);
  if (!notices.length) return [];
  const session = chatSession || "";
  const seq = (row) => (Number.isFinite(Number(row.seq)) ? Number(row.seq) : -Infinity);
  const seen = readNotifyWatermark(session);
  const fresh = notices.filter((row) => seq(row) > seen).sort((a, b) => seq(a) - seq(b));
  if (!fresh.length) return [];
  rememberNotifyWatermark(session, Math.max(...notices.map(seq)));
  // Off means nothing is raised, not "raised and then hidden": there is no call to make.
  if (notifyPreference() !== "on") return [];
  const toast = settlementNotice(fresh[fresh.length - 1]);
  raiseNotification(toast).then((result) => {
    paintNotifyResult(result);
    console.info("settlement notification", toast.title, toast.body, result.delivered ? "delivered" : "not delivered: " + result.reason);
  });
  return fresh;
}

function paintNotifyResult(result) {
  lastNotifyResult = result || lastNotifyResult;
  if (!notifyResultEl) return;
  const value = lastNotifyResult;
  if (!value) { notifyResultEl.textContent = ""; notifyResultEl.removeAttribute("data-delivered"); return; }
  notifyResultEl.dataset.delivered = String(value.delivered === true);
  notifyResultEl.textContent = value.delivered
    ? `delivered to Windows as "${value.app_name || "unknown app name"}" (${value.identity || "identity unknown"}) - delivery, not proof that it was seen`
    : `not delivered: ${value.reason || "the shell gave no reason"}`;
}

/// The one place the bell's state is drawn: the topic row's note, the switch, the test control and the
/// explanation are painted together, so they cannot show three different states.
function paintNotifyState() {
  const on = notifyPreference() === "on";
  if (notifyBellEl) { notifyBellEl.checked = on; notifyBellEl.disabled = !notifyStorageAvailable; }
  if (notifyTestEl) notifyTestEl.disabled = !on || !notifyStorageAvailable;
  if (notifyStateNoteEl) notifyStateNoteEl.textContent = on ? "on for this device" : "off on this device";
  if (notifyDetailEl) {
    const lines = [on
      ? "A child task that settles owing an evaluation raises a Windows notification on this device."
      : "Nothing is raised on this device while this is off, including the test below."];
    lines.push("The choice is stored in this window's own storage, so it is per device: the node is not told and no other device is affected.");
    if (!notifyStorageAvailable) {
      lines.push("This window refuses local storage, so the choice cannot be kept here and notifications stay off.");
    }
    if (notifyShellState) lines.push(notifyShellState);
    notifyDetailEl.textContent = lines.join(" ");
  }
}

/// Whether the shell can raise a toast at all, without raising one. Runs when the card is opened:
/// "the shell cannot" and "the bell is off" look identical from the outside otherwise.
async function refreshNotifySupport() {
  const shell = native;
  if (!shell || typeof shell.notifySupport !== "function") {
    notifyShellState = "No window shell in this surface (a browser page cannot raise a Windows notification), so the bell has nothing to switch on here.";
  } else {
    const support = await shell.notifySupport();
    notifyShellState = support.supported
      ? `Shell ready: Windows accepted the identity "${support.identity || "unknown"}", which it shows as "${support.app_name || "unknown"}".`
      : `This shell cannot raise notifications: ${support.reason}`;
  }
  paintNotifyState();
}

function repaintMessages(rows, options = {}) {
  const savedSteps = runStepState?.scope === runStepScope() ? runStepState : null;
  const savedCounts = runCounts?.scope === runStepScope() ? runCounts : null;
  const commentaryChoices=Array.from(transcript.querySelectorAll('wa-commentary')).map(node=>({id:node.dataset.messageId,pending:node.dataset.pendingId,text:node.body.textContent,open:node.open}));
  const savedCountUser = Number(Array.from(transcript.querySelectorAll('wa-message[role="user"]')).at(-1)?.dataset.messageSeq) || null;
  const changedRun = savedSteps?.id && runStepId() && savedSteps.id !== runStepId();
  if (changedRun && savedSteps.active) {
    const first = rows.findIndex(row => row.role === "user" && Number(row.seq) === savedSteps.userSeq);
    let last = null;
    if (first >= 0) for (const row of rows.slice(first + 1)) {
      if (row.role === "user") break;
      last = row;
    }
    const step = savedSteps.active;
    step.state = last?.ok === 0 ? "failed" : last?.role === "assistant" && last.phase !== "commentary" && last.content &&
      !(last.tool_calls || []).length ? "completed" : "unfinished";
    const at = Number(last?.created_at) * 1000;
    step.ms = at >= step.started ? at - step.started : null;
    step.node.setStep(step.label, step.state, step.ms);
    savedSteps.active = null;
    savedSteps.settled = true;
  }
  const replayedBubbles = new Map();
  let replayUserSeq = null;
  // A repaint is a view of durable rows, not a resumed event stream. In particular, an
  // assistant tool call without a result must never inherit a live timer from this page.
  stopToolTicker();
  clearStatus();
  trace = null;
  lastTool = null;
  transcript.replaceChildren();
  runBubble = null;
  streamBody = null;
  streamText = "";
  reasoningBlock = null;
  streamedCommentaryBlock = null;
  streamedCommentaryText = "";
  phasePendingText = new Map();
  runStartedAt = 0;
  runCounts = null;
  replayMessageEndedAt = 0;
  replayRunLastMessage = null;
  renderedMessageIds = new Set();
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
        finishReplayedRun();
        runCounts = null;
        flushDecision(true);
        runStartedAt = Number(message.created_at) > 0 ? Number(message.created_at) * 1000 : 0;
        replayMessageEndedAt = 0;
        replayRunLastMessage = null;
        const userBody=add("user", message.content || "");
        userBody.closest('wa-message').dataset.ledgerKey=String(message.id || message.seq);
        userBody.closest('wa-message').dataset.messageSeq=String(message.seq || "");
        replayUserSeq = Number(message.seq) || null;
        for (const item of message.trace || []) if (item.kind === 'run_counts') applyRunCounts(item);
      } else if (message.role === "summary") {
        for (const item of message.trace || []) if (item.kind === 'run_counts') applyRunCounts(item);
      } else if (message.role === "retry") {
        const event=JSON.parse(message.content || '{}');
        if(event.type!=='retry')throw Error('invalid retry ledger row');
        if(options.active && event.state==='reconnecting' && Number(message.created_at)>0)
          event.wait_ms=Math.max(0,Number(event.wait_ms)-Math.max(0,Date.now()-Number(message.created_at)*1000));
        handleEvent(event);
        if(!options.active)for(const retry of runBubble?.querySelectorAll('wa-retry') || [])retry.freeze();
        replayRunLastMessage=message;
        if(Number(message.created_at)>0)replayMessageEndedAt=Number(message.created_at)*1000;
        if(runBubble&&!runBubble.dataset.ledgerKey)runBubble.dataset.ledgerKey=String(message.id || message.seq);
      } else if (message.role === "assistant") {
        for (const item of message.trace || []) if (item.kind === 'run_counts') applyRunCounts(item);
        replayRunLastMessage = message;
        if (Number(message.created_at) > 0) replayMessageEndedAt = Number(message.created_at) * 1000;
        for(const span of message.trace || []) if(span.kind==='delegation' && span.ok===true && span.receipt?.subagent_id)
          handleEvent({type:'delegated',task:span.receipt});
        // The stored message carries its changes summary and its id, and both are needed: the summary is
        // the topic, and the id is what the undo route is asked about. Dropping them here is why a
        // reloaded transcript showed no diff topics at all - the live path had them, the repaint did
        // not, and a window that has been reloaded is a repaint.
        // The stored row keeps the thinking apart from the answer; replay it through the same
        // path the live stream used, so a reloaded transcript shows it too.
        if (message.reasoning) {
          handleEvent({ type: "reasoning", text: message.reasoning, chars: message.reasoning.length });
          if (reasoningBlock && message.id) reasoningBlock.dataset.messageId = message.id;
        }
        if (message.phase === "commentary") {
          handleEvent({ type: "commentary", text: message.content, message_id: message.id });
        } else if (message.content) {
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
            handleEvent({ type: "tool", call_id: raw.id, name: fn.name, arguments: args || {} });
          }
        }
        if(runBubble && !runBubble.dataset.ledgerKey)runBubble.dataset.ledgerKey=String(message.id || message.seq);
        for(const [index,segment] of Array.from(runBubble?.querySelectorAll('wa-run,wa-trace,wa-retry,wa-reasoning,wa-commentary,.seg')||[]).entries())
          if(!segment.dataset.ledgerKey)segment.dataset.ledgerKey=String(message.id || message.seq)+':segment:'+index;
        if (message.id) renderedMessageIds.add(String(message.id));
      } else if (message.role === "tool") {
        for (const item of message.trace || []) if (item.kind === 'run_counts') applyRunCounts(item);
        replayRunLastMessage = message;
        if (Number(message.created_at) > 0) replayMessageEndedAt = Number(message.created_at) * 1000;
        // The stored row carries the ledger's own verdict (`ok`), and a repaint that dropped it drew a
        // failed call as a successful one: the payload of a failure has no exit code to read, so
        // without this the line comes back green.
        handleEvent({ type: "tool_result", name: message.tool_name,
          failed: message.ok === 0 ? true : undefined, result: { content: message.content } });
      }
      rendered += 1;
      if (replayUserSeq && runBubble) replayedBubbles.set(replayUserSeq, runBubble);
    } catch (error) {
      failed += 1;
      if (!firstFailure) {
        firstFailure = `${message.role} seq ${message.seq}: ${error}`;
        console.error("repaint failed", message.role, message.seq, error);
      }
    }
  }
  // A host with no event stream of its own can hand over the call the node reports as in flight (a
  // child pane reads the ledger, so this is the only way it can show the step its child is on). The
  // window's own conversation gets the same line from its `tool` event, so the rule stays here, in the
  // one renderer, instead of becoming a second one that draws the same thing differently.
  const liveCall = options.liveTool;
  let livePending = false;
  if (options.active && liveCall && liveCall.call_id &&
      !rows.some((row) => row.role === "tool" && row.tool_call_id === liveCall.call_id)) {
    handleEvent({ type: "tool", call_id: liveCall.call_id, name: liveCall.name,
      arguments: liveCall.arguments || {}, timeout_ms: liveCall.timeout_ms });
    livePending = !!trace?.hasPendingCall(liveCall.call_id);
  }
  // A repaint is a view of durable rows, and this page holds no stream for the run it draws:
  // a tool call with no recorded result is history, not work this page can watch. Keeping its
  // line pending and starting a ticker invented a clock for a call nobody was timing, and the
  // reader could not tell it from a live one. Every replayed decision closes as unrecorded.
  // Replay has no `done` event. Close each historical run at its next user boundary, then use
  // the ledger's current state for the final run. An active run remains open until it settles.
  finishReplayedRun(true, options);
  // A repaint holds no stream for the run it draws, so a call with no recorded result is history: it
  // is closed as unrecorded rather than left with a clock nobody is timing. The exception is the call
  // the *node* reports as in flight and the host handed over - that is a measurement, and a child
  // pane watching its child work is the one reader for whom the run has not stopped.
  if (trace && !livePending) finishTrace();
  replayingMessages = false;
  // A repaint during a live run is not finished history. Keep its last bubble as the target for
  // the reconnecting event tail; otherwise the in-progress notice and eventual answer split into
  // separate assistant bubbles. An idle repaint still closes the historical bubble so the next
  // user turn starts cleanly.
  if (options.active) {
    if (!runBubble) currentBubble();
    if (replayUserSeq) replayedBubbles.set(replayUserSeq, runBubble);
  } else runBubble = null;
  const savedBubble = savedSteps?.userSeq && replayedBubbles.get(savedSteps.userSeq);
  if (savedBubble) {
    runStepState = changedRun && options.active ? null : savedSteps;
    if (!options.active && savedSteps.active) {
      const step = savedSteps.active;
      step.state = options.state === "answered" ? "completed" : options.state === "failed" ? "failed" : "unfinished";
      const at = Number(options.stateAt);
      step.ms = at > 0 ? Math.max(0, at * 1000 - step.started) : null;
      step.node.setStep(step.label, step.state, step.ms);
      savedSteps.active = null;
      savedSteps.settled = true;
    }
    restoreRunSteps(savedSteps, savedBubble);
  } else runStepState = null;
  if (options.active && observedRun?.session === chatSession) ensureObservedRunStep(observedRun);
  if (options.active && savedCounts && !changedRun && savedCountUser === replayUserSeq) {applyRunCounts(savedCounts);updateRunElapsed();}
  for(const node of transcript.querySelectorAll('wa-commentary')) {
    const choice=commentaryChoices.find(old=>old.id&&old.id===node.dataset.messageId || old.pending&&old.pending===node.dataset.pendingId || !old.id&&!node.dataset.messageId&&old.text===node.body.textContent);
    if(choice)node.open=choice.open;
  }
  pin(true);
  if (failed) {
    add("assistant", `repaint: ${rendered} of ${rows.length} messages drawn, ${failed} failed — first: ${firstFailure}`);
  }
  // The rows just drawn are the only place a settlement wake appears. Anything thrown here is the
  // notification's problem, never the transcript's: a toast that fails must not cost the reader a reply.
  // A child's transcript is not this window's conversation, so a paint of one asks not to notify: the
  // wake belongs to the thread that delegated the child, and a pane repainted on a poll would raise
  // the same settlement again on every poll.
  if (options.notify !== false) {
    try {
      announceSettlements(rows);
    } catch (error) {
      console.error("settlement notification failed", error);
    }
  }
  return { rendered, failed, firstFailure };
}

// Draw a child's conversation with the window's own renderer.
//
// The renderer is module-level because a window has one conversation; a child pane is a second
// container for the same ledger rows, so the target and the render state are saved, the rows are
// drawn, and both are put back. Nothing else about the path differs - the same handleEvent, the same
// `wa-message` bubble with a `steps` body, the same run topic, and the same
// `completed`/`unfinished`/`failed` footer - which is the point: a reader looking at a child and at
// this window's own chat is looking at one implementation, so a fix to either lands in both.
function captureRenderer() {
  return {transcript,runBubble,statusLine,statusLabel,statusElapsed,statusSpinner,runStepState,runCounts,
    statusPhase,lastAssistantBody,runStatusTicker,toolTicker,streamBody,streamText,phasePendingText,trace,lastTool,
    reasoningBlock,reasoningText,streamedCommentaryBlock,streamedCommentaryText,runStartedAt,replayingMessages,
    replayMessageEndedAt,replayRunLastMessage,renderedMessageIds,rendererTask};
}
function restoreRenderer(value) {
  ({transcript,runBubble,statusLine,statusLabel,statusElapsed,statusSpinner,runStepState,runCounts,
    statusPhase,lastAssistantBody,runStatusTicker,toolTicker,streamBody,streamText,phasePendingText,trace,lastTool,
    reasoningBlock,reasoningText,streamedCommentaryBlock,streamedCommentaryText,runStartedAt,replayingMessages,
    replayMessageEndedAt,replayRunLastMessage,renderedMessageIds,rendererTask}=value);
}
function childRenderKey(task) {return [activeNode,session,task?.session_id,task?.attempt_id||task?.subagent_id].join('|');}
function withChildRenderer(container,task,render) {
  const parent=captureRenderer(),retained=childRenderStates.get(container);
  if(retained?.key===childRenderKey(task))restoreRenderer(retained.renderer);
  else {
    transcript=container;runBubble=null;runStepState=null;runCounts=null;
    statusLine=null;statusLabel=null;statusPhase=null;statusElapsed=null;statusSpinner=null;runStatusTicker=null;toolTicker=null;
    trace=null;lastTool=null;lastAssistantBody=null;streamBody=null;streamText='';phasePendingText=new Map();
    reasoningBlock=null;reasoningText='';streamedCommentaryBlock=null;streamedCommentaryText='';runStartedAt=0;
    replayingMessages=false;replayMessageEndedAt=0;replayRunLastMessage=null;renderedMessageIds=new Set();
  }
  rendererTask=task;
  try {return render();}
  finally {
    stopToolTicker();if(runStatusTicker)clearInterval(runStatusTicker);runStatusTicker=null;
    childRenderStates.set(container,{key:childRenderKey(task),journal:container._renderJournal,renderer:captureRenderer()});restoreRenderer(parent);
  }
}
function renderChildProgress(task) {
  if(!turnIsActive()||!runBubble)return;
  if(!runStartedAt&&Number(task?.started_at)>0)runStartedAt=Number(task.started_at)*1000;
  const preview=task.preview || {},live=preview.tool;
  if(!runStepState?.active || runStepState.active.fallback&&runStepState.active.preview!==preview.status) {
    const note=live?'tools':preview.status || 'working';
    showRunStep(live?'tool:'+live.call_id:note,live?'Executing tools':note==='model'?'Reasoning':note==='queued'?'Queued':'Working');
    if(runStepState?.active){runStepState.active.fallback=true;runStepState.active.preview=preview.status;}
  }
  if(live?.started_at&&trace?.pending)trace.setAge(Date.now()/1000-live.started_at,live.timeout_ms?Math.round(live.timeout_ms/1000):undefined);
  if(!statusLine)setStatus('');updateRunElapsed();
}
function paintChildTranscript(container, rows, options = {}) {
  if(!container)return null;
  const task=options.task||container.closest('wa-agent-session')?.task||
    {session_id:container.dataset.session||'child',subagent_id:'child',state:options.active?'running':'completed',settled:!options.active};
  return withChildRenderer(container,task,()=>{
    const choices=Array.from(container.querySelectorAll('wa-commentary')).map(node=>({id:node.dataset.messageId,pending:node.dataset.pendingId,open:node.open}));
    const prior=runStepState?.active,oldJournal=childRenderStates.get(container)?.journal;
    const journal=JSON.stringify([options.identity,options.raw||options.events]);
    setTranscriptDebug(container,options.mode);
    const result=repaintMessages(rows||[],{...options,notify:false});
    // Phase clocks belong to observation/event time, never repeated repaint time.
    renderJournalEvents(options.events||[],options.raw,options.identity);
    if(task?.settled) {
      const state=childRunState(task);finishRunStatus(state==='failed'?'failed':state==='answered'?'completed':'unfinished');
      markPendingTextIncomplete();markStreamedCommentaryIncomplete();flushDecision(true);
    } else renderChildProgress(task||{});
    if(oldJournal===journal&&prior?.key===runStepState?.active?.key)runStepState.active.started=prior.started;
    for(const choice of choices) {
      const node=Array.from(container.querySelectorAll('wa-commentary')).find(node=>choice.id&&node.dataset.messageId===choice.id||choice.pending&&node.dataset.pendingId===choice.pending);
      if(node)node.open=choice.open;
    }
    updateRunElapsed();
    if(rendererTask)updateChildContextReadouts();
    container._renderJournal=journal;
    return result;
  });
}
document.addEventListener('chat-render-tick',event=>{
  const pane=event.detail.pane;
  if(!pane?.isConnected)return;
  withChildRenderer(pane.transcript,pane.task,()=>{
    if(pane.task?.settled&&statusLine) {
      const state=childRunState(pane.task);finishRunStatus(state==='failed'?'failed':state==='answered'?'completed':'unfinished');
      flushDecision(true);
    } else renderChildProgress(pane.task);
    updateRunElapsed();
  });
  if(pendingReload&&!activeChatView()){pendingReload=false;reload();}
});

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
  const outcome = value && typeof value === 'object'
    ? {name:value.state || '',detail:value.detail || ''}
    : {name:typeof value === 'string' ? value : '',detail:full?.state_detail || ''};
  if (outcome.name === 'failed' && (!outcome.detail || /inspect (its error|its transcript)/i.test(outcome.detail))) {
    const row = full?.messages?.at(-1);
    // Older nodes expose only generic state prose. The last failed assistant's
    // own trace is original evidence, not a guess from preceding tool failures.
    if (row?.role === 'assistant' && (row.ok === 0 || row.ok === false)) {
      const failure = (Array.isArray(row.trace) ? row.trace : []).slice().reverse().find(span =>
        span && (span.ok === false || span.ok === 0) && typeof span.error === 'string' && span.error);
      if (failure) outcome.detail = failure.error.length <= 1200 ? failure.error
        : failure.error.slice(0,1200) + ' (excerpt; full error in transcript)';
    }
  }
  return outcome;
}

// A recorded tool result is safe to continue from only when every call in its
// batch has a matching result. A result with an unknown call id needs inspection.
function completeToolBatch(rows) {
  const last = rows[rows.length - 1];
  if (last?.role !== "tool") return false;
  for (let i = rows.length - 2; i >= 0; i -= 1) {
    const row = rows[i];
    if (row.role === "user") return false;
    if (row.role !== "assistant" || !Array.isArray(row.tool_calls) || !row.tool_calls.length) continue;
    const results = new Set(rows.slice(i + 1).filter((item) => item.role === "tool")
      .map((item) => item.tool_call_id));
    return row.tool_calls.every((call) => call?.id && results.has(call.id));
  }
  return false;
}

const autoResumedTails = new Set();

let restoringSession = null;
let transcriptReady = false;
let transcriptRetryAt = 0;
let transcriptFailures = 0;
let transcriptFailure = "";
async function restoreSession(target = chatSession, retry = false) {
  const epoch = conversationEpoch;
  const node = activeNode;
  const submission = submissionEpoch;
  if (ownStreamActive()) return false;
  if (restoringSession && restoringSession.target === target && restoringSession.epoch === epoch && restoringSession.node === node && restoringSession.submission === submission) {
    return restoringSession.promise;
  }
  if (retry && Date.now() < transcriptRetryAt) return false;
  const pending = { target, epoch, node, submission, promise: restoreSessionOnce(target, epoch, node) };
  restoringSession = pending;
  try { return await pending.promise; }
  finally { if (restoringSession === pending) restoringSession = null; }
}

async function restoreSessionOnce(target, epoch, node = activeNode) {
  const submission = submissionEpoch;
  if (ownStreamActive()) return false;
  let phase = "session discovery";
  const viewing = () => chatSession === target && conversationEpoch === epoch && activeNode === node
    && submissionEpoch === submission && !ownStreamActive();
  try {
    // A known thread is already enough to read its authorized ledger. Discovery
    // is only needed for a new window, never a prerequisite on every reconnect.
    const payload = target && blankSession !== target ? {sessions:[{id:target}]} : await (await apiFetch("sessions", { headers: apiHeaders() })).json();
    const sessions = payload.sessions || [];
    if (payload.error) throw new Error(payload.error);
    if (!viewing()) return false;
    if (!sessions.length) { transcriptReady = true; return true; }
    const mine = sessions.filter((s) => !me.user || !s.user_id || s.user_id === me.user.id);
    let wanted = target ? sessions.find((s) => s.id === target) : (mine[0] || sessions[0]);
    // A client-chosen id has no ledger row until its first message is sent. It is still a deliberate
    // empty session: replacing it with the newest old row makes `/new` fail across a reload.
    if (target && !wanted && blankSession === target) {
      repaintMessages([]);
      showNewThreadNotice();
      transcriptReady = true;
      followedSeq = 0;
      return true;
    }
    if (!wanted) wanted = mine[0] || sessions[0];
    if (!wanted) { transcriptReady = true; return true; }
    if (!target || wanted.id !== target) {
      const originalTarget=target, originalEpoch=epoch;
      rememberSession(wanted.id);
      target = wanted.id;
      epoch = conversationEpoch;
      if (restoringSession?.target===originalTarget && restoringSession.epoch===originalEpoch && restoringSession.node===node) {
        restoringSession.target=target;
        restoringSession.epoch=epoch;
      }
    }
    if (blankSession === wanted.id) rememberBlankSession("");
    const route = "session?id=" + encodeURIComponent(wanted.id);
    phase = route;
    // Health is listener-owned; native lookup shares the transcript's read
    // capacity. Read history first so recovery cannot overload its own slot.
    let [full, health] = await Promise.all([
      apiFetch(route, { headers: apiHeaders() }).then((response) => response.json()),
      nodeHealth(),
    ]);
    if (!viewing()) return false;
    if (!full || full.error || !Array.isArray(full.messages)) {
      throw new Error(full?.error || "invalid session response");
    }
    phase = "native session lookup";
    const child = await nativeSessionTask(wanted.id);
    if (!viewing()) return false;
    if (health) observedRun = activeRun(health, wanted.id);
    applyRunControls();
    phase = route;
    let outcome = sessionOutcome(full);
    // A reply can land between the transcript read and /health. When the node is idle,
    // reread once before declaring a run unfinished; otherwise a completed answer could
    // briefly be displayed as a lost tool call.
    if (outcome.name === "unfinished" && health && !activeRun(health, wanted.id)) {
      const latest = await (await apiFetch(route, { headers: apiHeaders() })).json();
      if (!viewing()) return false;
      if (latest && !latest.error && Array.isArray(latest.messages)) {
        full = latest;
        outcome = sessionOutcome(full);
      }
    }
    orchestrationMode=full.orchestration || null;
    setTranscriptDebug(messages, full.session?.mode);
    const loadedSeq = (full.messages || []).reduce((last, row) => Math.max(last, Number(row.seq) || 0), 0);
    if (full && Array.isArray(full.messages) && full.messages.length) {
      repaintMessages(full.messages, { state: outcome.name, stateAt: full.state?.at,
        active: !!activeRun(health, wanted.id) });
    } else {
      repaintMessages([]);
    }
    const state = full.state;
    const autoResumeSeq = state && typeof state === "object" && state.state === "unfinished"
      && state.role === "tool" && Array.isArray(state.pending) && state.pending.length === 0
      && Number.isInteger(Number(state.seq)) && completeToolBatch(full.messages)
      && !child && health && !runningSessions(health).has(wanted.id) && !busy
      ? Number(state.seq) : null;
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
        notice.classList.add("active-run-notice");
        notice.textContent = "no result is recorded yet. A run is in progress on the node; this page will check again when it becomes idle.";
        sawTurnInFlight = true;
      } else {
        notice.textContent = autoResumeSeq !== null
          ? "this run stopped after a recorded tool result; resuming automatically."
          : "this message has no recorded answer - " +
            (outcome.detail || "the last step has no recorded result") +
            ". Its effects may have happened; check them before continuing.";
      }
      // Missing tool results still require inspection. A complete batch can resume
      // from its recorded tail; the node checks that exact sequence at admission.
      if (health && !runningSessions(health).has(wanted.id) && autoResumeSeq === null) {
        notice.append(nodeButton("continue", () => { notice.remove(); resumeSession(wanted.id); }));
      }
      if (notice.classList.contains("active-run-notice")) {
        chatShell.warning.setNotice('active',notice.textContent);
      } else messages.append(notice);
    }
    // Advance only through rows actually read. A list or checkpoint observed
    // later cannot prove its newer messages were included in this snapshot.
    followedSeq = loadedSeq;
    transcriptReady = true;
    transcriptFailures = 0;
    transcriptRetryAt = 0;
    chatShell.warning.setNotice('transcript','');
    if(outcome.name!=='unfinished'||!activeRun(health,wanted.id))chatShell.warning.setNotice('active','');
    transcriptFailure = "";
    if (autoResumeSeq !== null) {
      const key = node + ":" + wanted.id + ":" + autoResumeSeq;
      if (!autoResumedTails.has(key)) {
        autoResumedTails.add(key);
        void resumeSession(wanted.id, autoResumeSeq);
      }
    }
    return true;
  } catch (error) {
    if (!viewing()) return false;
    transcriptReady = false;
    transcriptFailures += 1;
    const delay = Math.min(30000, 500 * (2 ** Math.min(transcriptFailures - 1, 6)));
    transcriptRetryAt = Date.now() + delay;
    transcriptFailure = phase + ": " + String(error.message || error);
    chatShell.warning.setNotice('transcript',"transcript " + (followedSeq ? "refresh failed; saved view kept" : "not loaded") + " - retrying in " + Math.ceil(delay / 1000) + "s (" + transcriptFailure + ")");
    return false;
  }
}

function setBusy(value) {
  busy = value;
  // A run ending is what frees the node for everything the engine asked for while it ran.
  if (!value && document.body.classList.contains("engine")) reloadTopics();
  applyRunControls();
  if (value) startLiveness(); else stopLiveness();
}

function applyRunControls() {
  // A durable follower owns controls too, but it must not pretend to own the
  // original stream: `busy` still prevents repaint only for our own socket.
  const value = composerBusy();
  // Steering remains a backend/keyboard capability, not a visible control.
  sendButton.classList.toggle("busy", value);
  sendButton.title = value ? "Stop" : "Send";
  sendButton.setAttribute("aria-label", sendButton.title);
  // The shell owns the button; telling it keeps Enter and the send path in step with the run.
  chatShell.busy = value;
  applySettingsSovereignty();
  // Both a followed run and our own stream defer an update until ownership ends.
  if (!value && pendingReload && !activeChatView()) { pendingReload = false; reload(); }
}

// Turn sovereignty for the model controls: a switch is seen by the next run, never by the one
// in flight. The node pins provider/model/reasoning at run start (`provider.pin()`), so a change
// mid-run cannot reach the streaming turn - and a control that moves under it misreports what
// that turn actually used. Locked while a run streams, with the delay stated rather than silent.
function applySettingsSovereignty() {
  const locked = composerBusy();
  providerSelect.disabled = locked;
  modelSelect.disabled = locked;
  reasoningSelect.disabled = locked || !(settings.reasoning || {}).supported || me.role !== "master";
  settingsNote.textContent = locked
    ? "a run is in flight \u2014 a change here applies at the next turn" : "";
}

// One exact-run observation, fed by watchTurn's existing health poll. No independent timer.
const CHAT_UNCERTAINTY_MS = 5000;
let lastRunStreamAt = 0;
let livenessSample = null;
let connectionFailures = 0;
let connectionFailedAt = null;
let livenessWarningKind = '';

function startLiveness() {
  stopLiveness();
  lastRunStreamAt = 0;
}
function stopLiveness() {
  livenessSample = null;
  connectionFailures = 0;
  connectionFailedAt = null;
  setLiveness(null);
}
function markRunStreamAlive() {
  lastRunStreamAt = Date.now();
  if (livenessWarningKind === 'connection') setLiveness(null);
}
function observeRunHealth(health) {
  const id = busy ? runKey(activeRunId) : runKey(observedRun);
  const scope = runStepScope() + ':' + (id || 'unidentified');
  if (livenessSample?.scope !== scope) {
    livenessSample = {scope, beat: null, staleAt: null};
    connectionFailures = 0; connectionFailedAt = null;
    setLiveness(null);
  }
  if (!composerBusy() || (runStepState?.settled && runStepState.id === id && runStepState.scope === runStepScope())) {
    stopLiveness(); return;
  }
  const now = Date.now();
  if (!health) {
    connectionFailures += 1;
    connectionFailedAt ??= now;
    const quietFor = now - Math.max(connectionFailedAt, lastRunStreamAt);
    if (connectionFailures >= 2 && quietFor >= CHAT_UNCERTAINTY_MS) {
      setLiveness({kind:'connection', working:false, seconds:Math.floor(quietFor/1000)});
    }
    return;
  }
  connectionFailures = 0; connectionFailedAt = null;
  if (livenessWarningKind === 'connection') setLiveness(null);
  if (!id) return; // An aggregate node beat never belongs to an unidentified run.
  const row = (health.run_ids || []).find(run => run.conversation === chatSession && runKey(run) === id);
  if (row && /^(completed|cancelled|failed)$/.test(row.state)) {stopLiveness();return;}
  if (row?.state === 'queued') {setLiveness({working:true,run_state:'queued'});return;}
  const thread = threadOfRun(health,id);
  if (!thread || thread.role === 'reads' || !Number.isFinite(thread.age_ms) || thread.age_ms < 0) {
    livenessSample.beat=null;livenessSample.staleAt=null;
    // Missing scoped evidence is not a foreign/aggregate stall and cannot sustain its alarm.
    if(livenessWarningKind==='worker')setLiveness(null);
    return;
  }
  const beat = now - thread.age_ms;
  const stalled = thread.age_ms >= CHAT_UNCERTAINTY_MS && livenessSample.beat !== null && beat <= livenessSample.beat + 500;
  if (stalled) livenessSample.staleAt ??= now;
  else {livenessSample.staleAt = null;setLiveness({working:true,run_state:'running'});}
  livenessSample.beat = beat;
  if (livenessSample.staleAt !== null && now - livenessSample.staleAt >= CHAT_UNCERTAINTY_MS) {
    setLiveness({kind:'worker',working:false,seconds:Math.floor(thread.age_ms/1000)});
  }
}
function setLiveness(info) {
  document.getElementById('liveness')?.remove(); // Retire the old transcript counter.
  if (info?.run_state === 'queued') {
    showRunStep('queued','Queued — waiting for the current turn');
    setStatus('Queued — waiting for the current turn');
  } else if (info?.run_state === 'running' && runStepState?.active?.key === 'queued') {
    showRunStep('working','Starting turn');setStatus('Starting turn');
  }
  const warning = chatShell.warning;
  if (!info || info.working) {warning.message='';livenessWarningKind='';return;}
  livenessWarningKind = info.kind || 'worker';
  const seconds = Math.max(0, Math.floor(info.seconds ?? (info.stalled || 0)/1000));
  warning.message = livenessWarningKind === 'connection'
    ? 'Connection uncertain for '+seconds+'s; this chat may be out of sync. Outcome not yet confirmed.'
    : 'Execution worker may be unresponsive; its heartbeat has not refreshed for '+seconds+'s. Outcome not yet confirmed.';
}

// Canonical decimal identity. Never stringify a rounded legacy JSON number.
function runKey(value) {
  const raw=value && typeof value==='object' ? (value.run_key ?? value.run_id) : value;
  if(typeof raw==='number')return Number.isSafeInteger(raw)&&raw>0 ? String(raw) : null;
  if(typeof raw!=='string'||! /^[1-9][0-9]*$/.test(raw))return null;
  return BigInt(raw)<=9223372036854775807n ? raw : null;
}
function identifySubmittedRun(health) {
  if (activeRunId !== null || !submittedRunIds || !chatSession) return;
  const candidates = (health?.run_ids || [])
    .filter((run) => run.conversation === chatSession && runKey(run)!==null && !submittedRunIds.has(runKey(run)))
    .sort((a, b) => BigInt(runKey(a))<BigInt(runKey(b)) ? -1 : 1);
  if (candidates.length) activeRunId = runKey(candidates[candidates.length - 1]);
}

// The inlining rule for text attachments is the shell's (§11), shared with the child panes.
function composedText(text) {
  return chatShell.composedText(text);
}

// Images go out as a JSON body: {text, images:[{name, mime, data}]}.
// The server accepts plain text too, so this only changes when pictures are
// actually attached. `data` is a full data URL; the server strips the envelope.
function composedBody(text, options = {}) {
  const images = options.resumeSeq === undefined ? attachments.filter((file) => file.kind === "image") : [];
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
  const payload = { text: options.resumeSeq === undefined ? composedText(text) : text };
  if (images.length) payload.images = images.map((file) => ({ name: file.name, mime: file.mime, data: file.data }));
  if (thread) payload.thread = thread;
  if (options.resumeSeq !== undefined) payload.resume_seq = options.resumeSeq;
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
      const health = await nodeHealth(1000);
      if (health) { clearInterval(nodeWatch); nodeWatch = null; nodeOffline(false); refreshMeta(); }
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
  chatShell.warning.setNotice('active','');
}

function clearActiveRunNotice() {
  for (const notice of document.querySelectorAll(".active-run-notice")) notice.remove();
  chatShell.warning.setNotice('active','');
}

// What the node's own answer says about the run this window is watching.
//
// `view` is everything the page knows: the conversation it submitted to (`session`), the run id the node
// accepted for it (`runId`, from `run_ids` minus the pre-submit baseline `submitted`), and whether this
// window has already seen the run finish (`finished`).
//
// The verdicts are `running`, `busy-unknown`, `finished` and `over`, and only `over` is a claim that the run
// has ended - so only `over` may end the stream. The order matters: what this window watched finish wins,
// then what the node says about *this run*, and only then the node's aggregate word about being busy.
//
// This is the decision the owner's incident got wrong. `/health` answered `worker: "busy"` while the busy
// node-thread carried an identity this window could not match to its conversation, and the page announced
// "the node is no longer running this run (busy)" and aborted a healthy stream - printing the node's own
// word for *working* in the sentence that said the run was over. An answer this page cannot interpret is
// not evidence of death: the node was busy, so it was working on something, and the only thing the page
// knew for certain was that it could not tell whose work it was.
function runStanding(health, view = {}) {
  if (view.finished) return "finished";
  // A node-thread on this conversation, or one carrying the run id the node accepted for it: this run.
  const thread = activeRun(health, view.session);
  if (thread) return "running";
  const accepted = view.runId === null || view.runId === undefined ? null : view.runId;
  if (accepted !== null && threadOfRun(health, accepted, view.session)) return "running";
  const ids = Array.isArray(health?.run_ids) ? health.run_ids : null;
  if (ids) {
    // The run the node accepted for this conversation is the node's own record of it, and it outranks the
    // thread list: a thread is an implementation detail that a respawn or a re-queue may change.
    if (accepted !== null) {
      const mine = ids.find((run) => run && runKey(run)!==null && runKey(run)===runKey(accepted)
        && run.conversation === view.session);
      if (mine && /^(queued|running|not_started)$/.test(mine.state)) return "running";
      if (mine && /^(completed|cancelled|failed)$/.test(mine.state)) return "over";
    }
    // Not identified yet: a live run of this conversation that this window did not submit before is the
    // node's own answer that its newest run belongs here (`identifySubmittedRun` makes that exact match).
    const fresh = ids.filter((run) => run && run.conversation === view.session);
    if (fresh.some((run) => /^(queued|running|not_started)$/.test(String(run.state || "")))) return "running";
  }
  // The node says something is running that this window cannot name as its own run. "Busy but I cannot
  // identify it" is keep waiting - never "over". The node is not idle, so the run has not been observed
  // to end, and a page may not end a stream it cannot contradict.
  const worker = String(health?.worker || "");
  const isChatThread = (entry) => /^POST \/(?:node\/)?chat(?:\?|$)/.test(entry?.label || "");
  const chatWorking = (health?.node_threads || []).some(isChatThread) || isChatThread(health?.current);
  if (chatWorking || worker === "busy" || worker === "stalled") return "busy-unknown";
  return "busy-unknown";
}

// The node-thread carrying one run id, when the node names it there (`/health` puts `run_id` on both
// `current` and each `node_threads` entry). Absent on an older node, and then this is simply no evidence.
// Authenticated durable journal status, scoped by conversation. Numeric IDs beyond the safe
// integer range cannot be recovered from this server's numeric JSON contract; never guess them.
async function durableRunStanding(thread,runId) {
  if(runKey(runId)===null)return 'busy-unknown';
  try {
    const response=await apiFetch('runs',{method:'POST',headers:apiHeaders({'Content-Type':'application/json'}),body:JSON.stringify({action:'status',thread})});
    const payload=await response.json();
    if(!response.ok || payload.ok!==true || payload.conversation!==thread)return 'busy-unknown';
    const row=(payload.runs||[]).find(row=>runKey(row)!==null&&runKey(row)===runKey(runId));
    if(/^(completed|cancelled|failed)$/.test(row?.state))return 'over';
    if(/^(queued|running|not_started)$/.test(row?.state))return 'running';
  } catch(error) { /* observation unavailable; stream remains authoritative */ }
  return 'busy-unknown';
}

function threadOfRun(health, runId, session = chatSession) {
  const carries = (entry) => entry && entry.session === session
    && runKey(entry)!==null && runKey(entry)===runKey(runId);
  return (health?.node_threads || []).find(carries) || (carries(health?.current) ? health.current : null);
}

async function send(text, options = {}) {
  const runThread = options.session || chatSession;
  const runEpoch = conversationEpoch, runNode = activeNode;
  const submission = ++submissionEpoch;
  const stillViewingRun = () => chatSession === runThread && conversationEpoch === runEpoch
    && activeNode === runNode && submissionEpoch === submission;
  // Seal previous view buffers before the new user boundary, never reuse its trace/text.
  markPendingTextIncomplete();markStreamedCommentaryIncomplete();flushDecision(true);clearStatus();
  activeRunId = null;
  submittedRunIds = null;
  // The draft is going out, so what was stored is stale: a respawn must not put the sent prompt
  // back into the composer.
  if (options.resumeSeq === undefined) clearDraft();
  setBusy(true);
  // Sending is an explicit request to see the answer: follow again, even if the
  // reader had scrolled up to read something.
  setFollow(true);
  pin(true);
  runBubble = null;   // the reply gets its own bubble
  runStepState = null;runCounts = null;
  runStartedAt = Date.now();
  const runController = new AbortController();
  controller = runController;
  streamBody = null;
  streamText = "";
  const names = options.resumeSeq === undefined ? attachments.map((file) => file.name).join(", ") : "";
  const attachedImages = options.resumeSeq === undefined ? attachments.filter((file) => file.kind === "image") : [];
  const userBody = add("user", text + (names ? `\n\nattached: ${names}` : ""));
  appendMessageImages(userBody, attachedImages);
  const outgoing = composedBody(text, options);
  // Clear in place, like the submit handler does. Reassigning the binding here was
  // enough to make a reader's captured reference stale - which is how a test can end
  // up asserting against a dead array and passing.
  // Cleanup belongs here, after the user bubble and request have captured the attachments.
  // Clearing them in the form handler runs before send() starts, leaving nothing to display or send.
  if (options.resumeSeq === undefined) {
    chatShell.clearAttachments();
    draftNow = snapshotDraft();
  }
  showRunStep("submitting", "Sending message");
  setStatus("Sending message…");
  // /health is answered without waiting for a node-thread. Take the baseline before admitting this run
  // so later polls can tell its queued id from an older run in the same conversation.
  try {
    const before = await nodeHealth();
    if (stillViewingRun()) submittedRunIds = new Set((before.run_ids || [])
      .filter((run) => run.conversation === runThread)
      .map(runKey).filter(key=>key!==null));
  } catch (error) {
    if (stillViewingRun()) submittedRunIds = new Set();
  }
  // Declared out here, not inside the `try` below: the `finally` clears it, and a `const` inside the try
  // is not in scope there. It was inside, so every run ended by throwing `watchdog is not defined` from
  // the first line of the `finally` - which meant `clearInterval`, `setBusy(false)`, `controller = null`
  // and the meta refresh never ran, and the window sat there looking like it was still working on a run
  // that had finished. The gate's bug hunt found it; the product would only have shown it as "stuck".
  let watchdog = null;
  let sawDone = false;
  let lostRun = false;  try {
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
    // can say whether the node-thread is alive while a run runs. Ask it, and act only on its answer.
    let lastEvent = Date.now();
    let asking = false;
    // Whether this run finished under its own steam. Without it the watchdog cannot tell a run that
    // ended from a run that died: both leave `current: null`, so a run that completed while the
    // watchdog was asking /health got reported as "no longer running this run ... recorded as
    // unfinished" - about a run whose answer was already on screen. The message said `(alive)`, which
    // was the tell.
    let turnFinished = false;
    // One check, callable without the timer: `watchdogTick` only decides *when* to ask, so the UI harness
    // can run an ask itself with a fixture answer instead of waiting half a minute of silence for the
    // interval to fire. The decision below is the part that was wrong in the live incident, so the decision
    // is the part that gets a seam.
    const watchdogCheck = async () => {
      if (turnFinished) { clearInterval(watchdog); return; }
      // The reader chose another conversation. The node still owns this run and the stream is still
      // drained below, but its watchdog and notices no longer belong to the visible thread.
      if (!stillViewingRun()) { clearInterval(watchdog); return; }
      asking = true;
      try {
        const health = await nodeHealth();
        if (!stillViewingRun()) return;
        if(!health)throw new Error('health unavailable');
        identifySubmittedRun(health);
        // Asked and answered while the run was ending: say nothing. The run finished; there is
        // nothing to report and nothing to continue.
        if (turnFinished) { clearInterval(watchdog); asking = false; return; }
        let standing = runStanding(health, { session: runThread, runId: activeRunId,
          submitted: submittedRunIds, finished: turnFinished });
        if (standing === 'busy-unknown' && runKey(activeRunId)!==null) {
          const durable=await durableRunStanding(runThread,activeRunId);
          if(turnFinished || !stillViewingRun()) return;
          if(durable==='over') standing='over';
          else if(durable==='running') standing='running';
        }
        if (standing === "running" || standing === "busy-unknown") {
          // Working, and quiet because the work is quiet. Keep waiting, and start counting again. For
          // `busy-unknown` the page says the one thing it actually knows, and keeps the stream: it cannot
          // tell whose work the node is busy with, and an answer it cannot interpret must not cost the
          // reader a run that is still running.
          lastEvent = Date.now();
          if (standing === "busy-unknown") {
            setStatus("the node is busy with a run I cannot identify; still listening");
          }
          asking = false;
          return;
        }
        // Not running any more, and the run did not finish: the run is genuinely over, and the page
        // should say so and stop pretending it is still listening.
        clearInterval(watchdog);
        streamNotice = add("assistant", "the node is no longer running this run (" + (health.worker || "no beat") +
          "). Checking the recorded result for recovery.");
        watchNode();
        lostRun = true;
        runController.abort();
      } catch (error) {
        // Unreachable: the node is gone, which is a different message and the one that fits.
        // A failed observation is not a failed stream. Its own read/error/done settles it.
        if (!turnFinished && stillViewingRun()) setStatus("run status unavailable; still listening");
        lastEvent = Date.now();
      }
      asking = false;
    };
    // Armed here, assigned to the outer `watchdog` so the `finally` can always clear it - including when
    // the fetch below throws before a single event arrives. `checkWatchedRun` is the same function for
    // anyone outside this closure that has to run one check (the UI harness does).
    checkWatchedRun = watchdogCheck;
    watchdog = setInterval(() => {
      if (asking || Date.now() - lastEvent < 30000) return;
      void watchdogCheck();
    }, 5000);
    const response = await fetch("chat", {
      method: "POST",
      headers: apiHeaders(headers),
      body: outgoing.body,
      signal: runController.signal,
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
          // Parsed once. A malformed event is skipped, but a *rendering* failure is reported: swallowing it
          // made a render bug look like a stream that silently skipped (the inline reporter forwards
          // console.error to the node).
          let event = null;
          try { event = JSON.parse(line.slice(6)); } catch (error) { event = null; }
          if (event) {
            try {
              if (stillViewingRun()) handleEvent(event);
            } catch (error) {
              console.error("rendering a run event failed:", event.type, error);
            }
            lastEvent = Date.now();
          }
          // A run that says it is done, or has answered, or has failed, is finished: whatever the
          // watchdog asks next, this run is not unfinished, and any notice it put up is stale.
          const kind = event && typeof event.type === "string" ? event.type : "";
          if (kind === "done") sawDone = true;
          if (kind === "done" || kind === "reply" || kind === "error") {
            turnFinished = true;
            if (stillViewingRun()) clearStreamNotice();
          }
        }
      }
    }
  } catch (error) {
    if (stillViewingRun()) {
      clearStatus();
      if (error.name === "AbortError") add("assistant", "stopped.");
      else if (isConnectionLoss(error)) { add("assistant", connectionMessage()); watchNode(); }
      else add("assistant", "error: " + error);
    }
  } finally {
    clearInterval(watchdog);
    // This closure's run is over: the check goes with it, so nothing can run a check for a run that has
    // already settled. A later run arms its own.
    if (controller === runController) checkWatchedRun = null;
    if (stillViewingRun()) {
      setBusy(false);
      refreshMeta();
      notifyMetadataChange();
      // A dead stream can finish after the ledger follower already read its tail
      // while this page was busy. Re-read once after releasing the stream so the
      // recorded tool result can trigger recovery without a page reload.
      if (!sawDone && (!runController.signal.aborted || lostRun)) void restoreSession(runThread);
    }
    if (controller === runController) controller = null;
    // Learn which thread this run went into, but only until we know one: after that the window
    // keeps the thread it is in, rather than following whatever happens to be newest.
    if (!chatSession) learnSession();
    if (stillViewingRun() && !native) input.focus();
  }
}

function formatTokens(value) {
  const n=Number(value);
  if(!Number.isFinite(n)||n<0)return '?';
  if(n<1000)return String(Math.round(n));
  // Decimal SI units, one fractional digit; promote a rounded 1000k to 1M.
  const units=['k','M','G','T'];let index=0,scaled=n/1000;
  while(scaled>=999.95&&index<units.length-1){scaled/=1000;index++;}
  return scaled.toFixed(1).replace(/\.0$/,'')+units[index];
}
function formatContextCapacity(value) {
  const n=Number(value);
  return n>0&&Number.isFinite(n)?(n/1e6).toFixed(6).replace(/0+$/,'').replace(/\.$/,'')+'M':'?M';
}

function activeProvider() {
  return (settings.providers || []).find((provider) => provider.id === settings.provider) || null;
}

function contextReadout(context) {
  const capacity=Number(context?.capacity),tokens=Number(context?.tokens);
  const known=context?.estimated!==true&&context?.tokens!=null&&Number.isSafeInteger(tokens)&&tokens>=0&&capacity>0;
  const percent=known?String(Math.round(tokens/capacity*100)).padStart(2,'0'):'??';
  return `▤ ${percent}%/${formatContextCapacity(capacity)}`;
}
function contextFacts() {
  if(rendererTask) {
    const measured=measuredContexts.get(transcript),latest=runCounts?.context;
    return measured?.scope===runStepScope()&&(!latest?.model||latest.model===measured.model)
      ? {...measured,capacity:latest?.capacity||measured.capacity}
      : {tokens:null,capacity:latest?.capacity,model:latest?.model};
  }
  const scope=runStepScope(),request=settings.observability?.last_request;
  const current=runCounts?.scope===scope?runCounts.context:null;
  const model=composerBusy()?(current?.model||settings.model):settings.model;
  const measured=measuredContexts.get(transcript);
  if(measured?.scope===scope&&(!measured.model||measured.model===model))
    return {...measured,capacity:composerBusy()?(current?.capacity||measured.capacity):settings.context_limit};
  const sameModel=!request?.model||request.model===model;
  const observation=settings.observability;
  const inScope=!observation?.session_id||observation.session_id===chatSession;
  const prompt=observation?.last?.normalized?.prompt;
  return {tokens:inScope&&sameModel&&Number.isSafeInteger(prompt)?prompt:null,
    capacity:composerBusy()?current?.capacity||settings.context_limit:settings.context_limit,model,estimated:false};
}
function contextDetail(context) {
  const tokens=context.tokens,capacity=context.capacity;
  return 'Last provider-reported request input: '+(tokens==null?'unknown':tokens.toLocaleString('en-US'))+
    ' tokens / capacity '+(capacity>0?capacity.toLocaleString('en-US'):'unknown')+
    ' tokens'+(tokens!=null&&capacity>0?' ('+(tokens/capacity*100).toFixed(4)+'%)':'')+'. Rounded display; no live text estimate.';
}
function updateChip() {
  const context=contextFacts();
  setText(chipModel,contextReadout(context));
  const detail=contextDetail(context);
  if(chipModel.title!==detail)chipModel.title=detail;
  composerModel.hidden=true;
  setText(chipUsage,'');
}
function updateChildContextReadouts() {
  const pane=transcript.closest('wa-agent-session');if(!pane?.shell.modelChip)return;
  const context=contextFacts(),facts=[{label:'last measured input',value:context.tokens==null?'unknown':formatTokens(context.tokens)},
    {label:'selected capacity',value:formatContextCapacity(context.capacity)},
    {label:'occupancy',value:contextReadout(context).replace(/^▤ /,'')},
    {label:'exact counts',value:contextDetail(context)},
    {label:'model',value:rendererTask.model||context.model||'unknown'},
    {label:'reasoning',value:rendererTask.reasoning||'unknown'}];
  pane.shell.setModelPicker(facts,contextReadout(context));
}
let contextPaintKey='';
function updateContextReadouts() {
  updateChip();
  if(balloon.open)renderContext();
}

function renderNodeSelect() {
  const previous = nodeSelect.value;
  // Only nodes that can host a chat: the local host and peers. The local
  // `client` node is a control target, not a conversation target.
  const options = nodeList.filter((item) => item.kind !== "client");
  // Drop a stale selection (a node that is no longer a chat target) instead of
  // silently sending it as X-WA-Node and keying sessions under a phantom name.
  if (activeNode && !options.some((node) => node.name === activeNode)) {
    rememberNode("");
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

// One renderer, one payload. Provider, reasoning and model are three views of the same `settings`
// answer, so they are drawn together or not at all: drawing them from separate copies of it is how
// the balloon came to show "OpenAI subscription" beside opencode-go's model ids and opencode-go's
// rolling/weekly/monthly resets - a pair no payload from the node ever contained.
function renderControls() {
  const providers = settings.providers || [];
  providerSelect.replaceChildren();
  for (const provider of providers) {
    const option = document.createElement("option");
    option.value = provider.id;
    option.textContent = provider.configured ? provider.label : provider.label +
      (provider.auth === "subscription" ? " (login in Pi)" : " (no key)");
    if (provider.id === settings.provider) option.selected = true;
    providerSelect.append(option);
  }
  // The node's provider is what the select must show even when the node's catalogue does not list
  // it: falling back to the first option is the same disagreement one control over.
  if (settings.provider && !providers.some((provider) => provider.id === settings.provider)) {
    const option = document.createElement("option");
    option.value = settings.provider;
    option.textContent = settings.provider + " (not in this node's catalogue)";
    option.selected = true;
    providerSelect.append(option);
  }
  reasoningSelect.replaceChildren();
  const reasoning=settings.reasoning || {};
  for (const level of reasoning.supported ? reasoning.levels : ['provider']) {
    const option=document.createElement('option'); option.value=level;
    option.textContent=level==='provider' ? 'provider default / unknown' : level;
    option.selected=level===reasoning.selected; reasoningSelect.append(option);
  }
  reasoningSelect.disabled=!reasoning.supported || me.role!=='master';
  applySettingsSovereignty();
  modelSelect.replaceChildren();
  const provider = activeProvider();
  const models = (provider && provider.models) || [];
  // Do not display the first available model as if it were the persisted one.
  // Keep stale selections visible so the operator can explicitly repair them.
  if (settings.model && !models.includes(settings.model)) {
    const option = document.createElement('option');
    option.value = settings.model;
    option.textContent = settings.model + ' (unavailable on this route; choose a model)';
    option.selected = true;
    option.disabled = true;
    modelSelect.append(option);
  }
  if (settings.model_error) settingsError.textContent = settings.model_error;
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
  const context=contextFacts(),key=JSON.stringify([runStepScope(),context.tokens,context.capacity,context.model]);
  if(contextPaintKey===key&&contextBox.childElementCount)return;
  contextPaintKey=key;contextBox.replaceChildren();
  contextBox.append(grid([['last measured input',context.tokens==null?'unknown':formatTokens(context.tokens)],
    ['selected capacity',formatContextCapacity(context.capacity)],['occupancy',contextReadout(context).replace(/^▤ /,'')]]));
  const raw=document.createElement('span');raw.className='usage-note';
  raw.textContent=contextDetail(context);contextBox.append(raw);
  if(context.tokens!=null&&context.capacity>0)contextBox.append(meter(context.tokens/context.capacity*100));
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
    none.textContent = settings.limits_error
      ? "limits unavailable · " + settings.limits_error
      : "limits unavailable";
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

// What each settings route names in the payload, so a reconcile can compare what was asked for with
// what the node reports afterwards.
const SETTING_VALUE = {
  provider: (payload) => payload.provider,
  model: (payload) => payload.model,
  reasoning: (payload) => (payload.reasoning || {}).selected,
};

// A settings change is confirmed or visibly refused - never silently dropped.
//
// It used to send the write and assume it landed. A rejected or aborted fetch became an unhandled
// rejection (recorded only as `ui_error` by the page's reporter), nothing re-rendered, and the
// select kept the value the operator had chosen - so the window showed a provider the node never
// accepted beside the previous route's model ids and limits, and said nothing, for as long as it
// stayed open. Every outcome that is not a success payload now reconciles: it re-reads the node and
// draws the controls from the node's answer, because a request this client aborted may still be
// applied by the node afterwards, and only the node's answer is the truth about where it is.
let settingsChanging = false;
let settingsNode = activeNode;
let settingsReconciliation = null;
function acceptSettings(payload) {
  if (!payload || payload.error || typeof payload.provider !== "string" || typeof payload.model !== "string") throw new Error(payload?.error || "invalid model settings response");
  if (settingsNode === activeNode && Number.isFinite(payload.settings_revision) && Number.isFinite(settings.settings_revision)
      && payload.settings_revision < settings.settings_revision) return false;
  settings = { ...settings, ...payload };
  // Once this page no longer follows/owns a stream, a fresh authoritative read
  // supersedes the cached checkpoint measure (which may predate another window).
  if(!composerBusy()&&payload.observability?.session_id===chatSession)measuredContexts.delete(messages);
  settingsNode = activeNode;
  return true;
}
async function post(path, body) {
  // The turn in flight owns the settings it started with - the node pins provider, model and
  // reasoning when a run starts - so a change now would be seen by the next turn at the
  // earliest, and sending it mid-run only makes the controls disagree with the run they are
  // describing. Refuse it, say when it will apply, and draw the controls from the node's answer.
  if (composerBusy()) {
    await reconcileControls("not applied \u2014 a run is in flight, so this change applies at the next turn");
    return;
  }
  if (settingsChanging) { await reconcileControls("another settings change is awaiting confirmation"); return; }
  const node = activeNode, target = chatSession, epoch = conversationEpoch;
  settingsChanging = true;
  let failure = "";
  let payload = null;
  try {
    const response = await apiFetch(path, {
      method: "POST",
      headers: apiHeaders({ "Content-Type": Number.isFinite(settings.settings_revision) ? "application/json" : "text/plain; charset=utf-8" }),
      body: Number.isFinite(settings.settings_revision) ? JSON.stringify({value:body, revision:settings.settings_revision}) : body,
    });
    payload = await response.json();
    // The node's own words when it gives them; its status when it does not.
    if (payload.error) failure = String(payload.error);
    else if (!response.ok) failure = "the node answered HTTP " + response.status;
  } catch (error) {
    // A thrown fetch. The abort apiFetch raises at its own deadline (apiTimeout, 8s) arrives here
    // too, and is said as what it is: the node was never told no, so it may apply the change later.
    failure = error && error.name === "AbortError"
      ? "no answer within " + Math.round(apiTimeout / 1000) + "s (the request was aborted)"
      : String(error);
  }
  settingsChanging = false;
  if (activeNode !== node || chatSession !== target || conversationEpoch !== epoch) return;
  if (failure) {
    await reconcileControls(failure, { asked: body, reads: SETTING_VALUE[path] });
    return;
  }
  try { if (!acceptSettings(payload)) return; }
  catch (error) { await reconcileControls(error.message, {asked:body, reads:SETTING_VALUE[path]}); return; }
  try {
    metadataPaintKeys.clear();
    updateNodeLabel(settings.node_name, settings.node_worktree);
    updateChip();
    renderControls();
    renderContext();
    renderLimits();
    renderUsage();
    renderPopFoot();
  } catch (error) {
    // The node accepted the change, so the merged settings are the truth even when drawing them
    // throws. Say that rather than let the failure become an unhandled rejection that leaves the
    // controls stale and the note silent - the same defect class this function exists to close.
    settingsError.textContent = "the change was applied, but the controls could not be redrawn: " + String(error);
    return;
  }
  settingsError.textContent = payload.model_error || "";
  settingsReconciliation = null;
  notifyMetadataChange();
}

// Draw the controls from the node's own answer after a settings change, and say what that answer is.
// The note is derived from the node's report, never from the write outcome alone: a request this
// client aborted is still the node's to apply, and a note that read "not applied" while the screen
// showed a provider the node had applied afterwards is the note the operator acts on. When the
// answer is what was asked for it is said as in effect; when the node cannot be re-read either, the
// controls are still drawn from the last answer this window has and the note says so.
async function reconcileControls(reason, sent) {
  const node=activeNode, target=chatSession, epoch=conversationEpoch;
  settingsReconciliation={node,target,epoch,reason,sent};
  renderControls();
  settingsError.textContent = (sent ? 'not confirmed' : 'not sent') + ' - ' + reason;
  const read = await refreshMeta();
  if (node!==activeNode || target!==chatSession || epoch!==conversationEpoch) return;
  renderControls();
  renderSettingsReconciliation(read);
}

function renderSettingsReconciliation(read) {
  const pending=settingsReconciliation;
  if (!pending) { if (read) settingsError.textContent=settings.model_error || ""; return; }
  if (pending.node!==activeNode || pending.target!==chatSession || pending.epoch!==conversationEpoch) {
    settingsReconciliation=null;
    return;
  }
  const {reason,sent}=pending;
  const route = (settings.provider || "unknown provider") + " / " + (settings.model || "unknown model");
  const landed = !!(sent && sent.asked && sent.reads && sent.reads(settings) === sent.asked);
  if (!read) {
    settingsError.textContent = (sent ? "not confirmed \u2014 " : "not sent \u2014 ") + reason +
      "; the node could not be re-read, so this still shows " + route;
    return;
  }
  settingsError.textContent = landed
    ? "in effect \u2014 " + reason + "; the node reports " + route + ", which is what was asked for"
    : (sent ? "not confirmed \u2014 " : "not sent \u2014 ") + reason + "; the node now reports " + route;
}

function setProvider(id) { return post("provider", id); }
function setModel(name) { return post("model", name); }

// The chips are the shell's now (it owns the list, the strip and the §11 read policy), so the main chat
// and a child pane cannot disagree about what an attachment looks like.

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

// Stop means "stop on the node", not only "stop reading the stream". Keep the stream open until the
// node acknowledges its cancel request; an early browser abort hid both refusals and the node's
// eventual cancelled result, making Stop look inert even when the request failed.
function cancelActiveRun() {
  const thread = chatSession;
  if (!busy && observedRun?.session === thread) { cancelRun(runKey(observedRun)); return; }
  if (thread && activeRunId === null && submittedRunIds) {
    // Admission and the next health poll can cross. Resolve the new id once more instead of
    // falling back to the route's default, which would cancel the older running turn.
    const node=activeNode,epoch=conversationEpoch;
    nodeHealth().then((health) => {
      if(node!==activeNode || thread!==chatSession || epoch!==conversationEpoch)return;
      identifySubmittedRun(health);
      if (activeRunId !== null) cancelRun(activeRunId);
      else setStatus("this run is still being admitted — try stop again in a moment");
    }).catch(() => {if(node===activeNode&&thread===chatSession&&epoch===conversationEpoch)setStatus("could not identify this run to stop it");});
    return;
  }
  cancelRun(activeRunId);
}

async function cancelRun(runId) {
  const thread = chatSession;
  if (!thread) { setStatus("there is no active conversation to stop"); return; }
  try {
    const response = await apiFetch("runs", {
      method: "POST",
      headers: apiHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ action: "cancel", thread, ...(runId === null ? {} : { run_id: runId }) }),
    });
    const payload = await response.json().catch(() => ({}));
    if (!response.ok || payload.ok !== true || payload.cancel_requested !== true) {
      setStatus("could not stop this run: " + String(payload.error || ("HTTP " + response.status)));
      return;
    }
    setStatus("stop requested — waiting for the node to finish cancelling");
  } catch (error) {
    setStatus("could not stop this run: " + String(error));
  }
}

let steeringSubmission=null;
let steeringPending=false;
async function steerActiveRun() {
  const text=input.value.trim(), thread=chatSession, node=activeNode, epoch=conversationEpoch;
  const viewing=()=>chatSession===thread && activeNode===node && conversationEpoch===epoch;
  if(!composerBusy() || !thread || !text || steeringPending)return;
  if(attachments.length) {setStatus('Steering accepts text only; attachments and draft kept.');return;}
  if(!steeringSubmission || steeringSubmission.text!==text || steeringSubmission.thread!==thread
    || steeringSubmission.node!==node || steeringSubmission.epoch!==epoch)
    steeringSubmission={text,thread,node,epoch,key:crypto.randomUUID()};
  const submission=steeringSubmission;
  steeringPending=true;
  const steerButton=document.getElementById('steer');
  if(steerButton)steerButton.disabled=true;
  try {
    let receipt;
    for(let attempt=0;attempt<2;attempt++) {
      if(!viewing())return;
      const response=await apiFetch('subagents',{method:'POST',headers:apiHeaders({'Content-Type':'application/json'}),
        body:JSON.stringify({action:'steer_session',session_id:thread,text,idempotency_key:submission.key})});
      if(!viewing())return;
      receipt=await response.json();
      if(!viewing())return;
      // This explicit refusal occurs before dispatch. Unknown outcomes are never auto-retried.
      if(response.status===503 && receipt.error==='read_capacity_busy' && attempt===0) {
        setStatus('Control lane busy; retrying steering once. Draft kept; Stop remains available.');
        await nodeHealth();
        if(!viewing())return;
        continue;
      }
      if(!response.ok || receipt.error || !receipt.id)throw new Error(receipt.error || 'missing steering receipt');
      break;
    }
    if(viewing() && input.value.trim()===text) {
      input.value='';draftGeneration++;draftUndo=[];draftRedo=[];autosize();saveDraft();
    }
    steeringSubmission=null;
    setStatus('Steering '+receipt.state+' — applies at the next safe boundary; in-flight effects are not undone.');
  } catch(error) {if(viewing())setStatus('Steering not confirmed; draft kept: '+error.message);}
  finally {steeringPending=false;if(steerButton)steerButton.disabled=false;}
}

// The shell owns the form: a click on Send, an Enter in the field and `requestSubmit()` all arrive
// here as one event, so the composer has one send path whatever the reader did.
chatShell.addEventListener("chat-send", (event) => {
  const text = String(event.detail.text || "");
  if (event.detail.busy) {
    cancelActiveRun();
    return;
  }
  if (!text && attachments.length === 0) return;
  commandMenu.close();
  input.value = "";
  draftGeneration += 1;
  // The draft has been sent, so there is nothing to undo *to*: keeping the
  // stack would let Ctrl+Z resurrect a draft that is already in the transcript,
  // and pressing Enter again would send it twice.
  draftUndo = [];
  draftRedo = [];
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
  if(accel && event.key==='Enter' && composerBusy()) {event.preventDefault();steerActiveRun();return;}
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
    // The shell sent it already: a plain Enter in a healthy composer is the shell's gesture, and it
    // says so by consuming the event. This branch is what a run in flight does with that key.
    if (event.defaultPrevented) return;
    event.preventDefault();
    if (composerBusy()) {
      // Typing ahead is not a stop gesture. The red button remains the explicit stop control; Enter
      // keeps the next prompt in the composer so one keystroke cannot cancel a healthy provider call.
      saveDraft();
      setStatus("run still working — draft kept; Ctrl+Enter or Steer sends it now; Stop cancels");
      return;
    }
    form.requestSubmit();
  }
});
// The textarea's own mechanics (autosize on input, Enter sends) belong to the shell; what stays here is
// the draft's undo history, which groups a burst of typing into one step.
function autosize() {
  chatShell.autosize();
}
// Group typing into one undo step: without this, every keystroke is its own
// entry and Ctrl+Z walks back one character at a time, which is not what the
// gesture means. A pause, or any non-typing change, starts a new step.
let typingTimer = null;
input.addEventListener("input", () => {
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
// While the list is up it owns Enter: the highlight and the item a click would choose are the same
// thing by construction, so the shell must not send the half-typed command from under it.
commandMenu.addEventListener("open", () => { chatShell.enterLocked = true; });
commandMenu.addEventListener("close", () => { chatShell.enterLocked = false; });

// Only commands that can keep their promise. `/new` starts a thread; `/update` asks the node to
// install what is already built in its own tree - which the node cannot do to itself, so the honest
// answer is a *queued* request for the sentinel, and the notice says so. Nothing here deletes a
// transcript, because the ledger is append-only (§12) and a command that silently removed
// history would make the record a claim it cannot support.
// `/merge` is a brief for the agent, not a node operation: the worktrees, the branches and the gate
// live outside this process. The sentence mirrors `lua/core/merge.lua` (the CLI's copy); both point
// at the one skill, so the procedure cannot drift even though the trigger is written twice.
const ORCHESTRATOR_BRIEF = "Act as the git orchestrator for this repository. " +
  "Load skills/git-orchestrator and run its deterministic audit before merging. " +
  "Integrate every in-scope committed local and remote branch tip, including actor branches and local-only work, into main. " +
  "Review the changes, gate the combined result, push, then re-fetch and repeat until the audit proves convergence. " +
  "After the final gate and audit, delete every integrated non-main branch ref from origin; completion requires origin to contain only main. Preserve active or dirty local worktrees and report them separately. " +
  "The AGENTS.md hand-off rule is suspended: you are the integrator and may merge to main. " +
  "Preserve uncommitted work and active checkouts. Resolve understood conflicts without losing either intent; escalate an unresolved decision, never force it. " +
  "Scope: internal branches only. Open PR work is excluded; use /merge all to explicitly include PRs.";
const ORCHESTRATOR_ALL_BRIEF = "Act as the git orchestrator for this repository. " +
  "Load skills/git-orchestrator and run its deterministic audit before merging. " +
  "Integrate every in-scope committed local and remote branch tip, including actor branches and local-only work, into main. " +
  "Review the changes, gate the combined result, push, then re-fetch and repeat until the audit proves convergence. " +
  "After the final gate and audit, delete every integrated non-main branch ref from origin; completion requires origin to contain only main. Preserve active or dirty local worktrees and report them separately. " +
  "The AGENTS.md hand-off rule is suspended: you are the integrator and may merge to main. " +
  "Preserve uncommitted work and active checkouts. Resolve understood conflicts without losing either intent; escalate an unresolved decision, never force it. " +
  "Scope: /merge all explicitly includes every open PR head, including forks. Review each PR and honor required checks and approvals before integration.";

let orchestrationMode=null,orchestrationRead=null;
async function readOrchestrationMode() {
  const thread=chatSession,node=activeNode,epoch=conversationEpoch;
  if(!thread)return;
  const key=node+'|'+thread+'|'+epoch;
  if(orchestrationRead?.key===key)return orchestrationRead.promise;
  const pending={key,promise:null};
  pending.promise=(async()=>{try {
    const r=await orchestratorRequest({action:'orchestration_mode',thread,mode_action:'get'});
    if(thread!==chatSession||node!==activeNode||epoch!==conversationEpoch)return;
    if(!r.ok||typeof r.orchestration?.enabled!=='boolean'||r.orchestration.thread!==thread)throw Error(r.error||'invalid mode reply');
    orchestrationMode=r.orchestration;
    if(input.value.startsWith('/'))syncCommands();
  }catch(error){if(thread===chatSession&&node===activeNode&&epoch===conversationEpoch)orchestrationMode=null;}
  finally{if(orchestrationRead===pending)orchestrationRead=null;}})();
  orchestrationRead=pending;return pending.promise;
}
async function toggleOrchestration() {
  const thread=chatSession,node=activeNode,epoch=conversationEpoch;
  await readOrchestrationMode();
  if(thread!==chatSession||node!==activeNode||epoch!==conversationEpoch)return;
  if(!orchestrationMode){add('assistant','Orchestration state unavailable; no change made.');return;}
  const r=await orchestratorRequest({action:'orchestration_mode',thread,mode_action:'toggle',revision:orchestrationMode.revision});
  if(thread!==chatSession||node!==activeNode||epoch!==conversationEpoch)return;
  if(!r.ok||r.orchestration?.thread!==thread||typeof r.orchestration?.enabled!=='boolean'){add('assistant','Orchestration change refused: '+(r.error||'unconfirmed'));await readOrchestrationMode();return;}
  orchestrationMode=r.orchestration;
  add('assistant','Orchestration '+(orchestrationMode.enabled?'on — tasks route to native workers; I remain available.':'off — I handle new tasks directly. Existing workers keep running.'));
}
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
    hint: "merge internal branches; leave open PR work for review",
    run: () => { send(ORCHESTRATOR_BRIEF); },
  },
  {
    name: "/merge all",
    hint: "include all open PRs after review and required checks",
    run: () => { send(ORCHESTRATOR_ALL_BRIEF); },
  },
  {
    name: "/efficiency_report",
    hint: "what the last call sent and cost — tokens, KV cache, USD, and the prefix to inspect",
    run: efficiencyReport,
  },
  {
    name: "/orchestration",
    get hint(){return (orchestrationMode ? (orchestrationMode.enabled?'ON':'OFF') : 'unknown')+' — toggle native task routing';},
    run:()=>{toggleOrchestration().catch(error=>add('assistant','Orchestration change failed: '+error.message));},
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
  notice.dataset.state = "checking";
  notice.textContent = "/update — asking the node what it runs and what its tree holds…";
  messages.append(notice);
  pin();
  try {
    const response = await apiFetch("update", {
      method: "POST",
      headers: apiHeaders({ "Content-Type": "application/json" }),
      // Replacement drops every in-memory connection. Name the durable thread so the sentinel can
      // wake it only after the new node answers, instead of making the window's reconnect luck the
      // continuation protocol.
      body: JSON.stringify(chatSession ? { thread: chatSession } : {}),
    });
    const payload = await response.json();
    notice.textContent = updateNotice(payload);
    notice.dataset.state = payload && payload.queued ? "queued" : payload && payload.ok === false ? "refused" : "current";
    if (payload && payload.queued) {
      updateLock("Deploy queued in the background. The page will reload when the new UI is ready.", true);
    }
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

// `/efficiency_report`: what the last model call sent and cost, read from the harness ledger.
//
// The window has no Lua, so it cannot build the report itself: it asks the node's read route,
// which runs the same deterministic report the CLI's `/efficiency_report` prints. No model call
// is spent. The answer is preformatted, so it goes in a <pre> rather than a one-line notice.
async function efficiencyReport() {
  const panel = document.createElement("pre");
  panel.className = "efficiency-report";
  panel.textContent = "/efficiency_report — reading the harness ledger…";
  messages.append(panel);
  pin();
  try {
    const response = await apiFetch("efficiency?session_id=" + encodeURIComponent(chatSession), { headers: apiHeaders() });
    const payload = await response.json();
    if (payload && payload.error) {
      panel.textContent = "/efficiency_report: " + payload.error;
      panel.dataset.state = "refused";
    } else {
      panel.textContent = (payload && payload.text) || "(empty report)";
      panel.dataset.state = "current";
    }
  } catch (error) {
    panel.textContent = "/efficiency_report could not be read: " + String(error);
    panel.dataset.state = "refused";
  }
  pin();
}

// Start a thread with nothing in it.
//
// Nothing is deleted. The thread being left behind is still in the ledger and still listed in the
// engine view, which is why the notice says so: an empty transcript with no explanation reads as
// "the work is gone", and it is not.
function showNewThreadNotice() {
  const notice = document.createElement("div");
  notice.className = "thread-notice";
  notice.textContent = "new session — nothing from the previous thread carries over here. " +
    "That thread is unchanged and still listed in the engine view.";
  messages.append(notice);
}

function newThread() {
  detachConversationView();
  rememberSession(newId());
  rememberBlankSession(chatSession);
  repaintMessages([]);
  clearStatus();
  showNewThreadNotice();
  setEngine(false);
  refreshMeta();
  pin();
}

// `/` opens the list; anything else typed after it filters. A newline ends the command line and
// closes it, so a message that merely starts with a slash is not trapped.
function commandMatches(value) {
  if (value[0] !== "/" || value.includes("\n")) return [];
  let typed = value.slice(1).trim().toLowerCase();
  if(typed.startsWith('ochestration'))typed='orchestration'+typed.slice('ochestration'.length);
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
input.addEventListener("input", () => {syncCommands();if(commandMatches(input.value).some(command=>command.name==='/orchestration'))void readOrchestrationMode();});
input.addEventListener("focus", syncCommands);
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
    metadataPaintKeys.clear();
    refreshNodes();
    refreshMeta();
    renderControls();
    renderContext();
    renderLimits();
    renderUsage();
    renderPopFoot();
  }
});
balloon.addEventListener("close", () => statusBtn.setAttribute("aria-expanded", "false"));
providerSelect.addEventListener("change", () => setProvider(providerSelect.value)
  .catch((error) => { settingsError.textContent = "the change could not be sent: " + String(error); }));
modelSelect.addEventListener("change", () => setModel(modelSelect.value)
  .catch((error) => { settingsError.textContent = "the change could not be sent: " + String(error); }));
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
  rememberNode(local ? "" : value);
  localStorage.setItem("wa-node", activeNode);
  await refreshMeta();
  renderControls();
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
// The intake itself - §11's two kinds, the accepted image types, reading a file and building its chip
// - is the shared shell's, because a child pane appends files the same way. What stays here is what
// only the main chat knows: the draft's undo step and the words the status line uses.

async function addFiles(files) {
  // One snapshot for the whole batch: undoing a three-file drop one file at a time would make Ctrl+Z
  // feel broken. Captured before the first await, so a slow read still leaves the pre-drop state.
  const before = snapshotDraft();
  const generation = draftGeneration;
  // The app's own rule for "this read belongs to a draft that no longer exists", handed to the shell
  // so a file cannot land in the composer after the prompt it belonged to has gone out.
  const receipt = await chatShell.addFiles(files, () => generation === draftGeneration);
  if (receipt.refused > 0) {
    setStatus(`${receipt.refused} image(s) skipped - only png, jpeg, webp and gif are accepted`);
  }
  // Successful attachment intake is shown by the cards, never by a run status/timer.
  // The draft moved on while a file was in flight. A file the reader attached that quietly does not
  // appear is worse than one that explains why it did not.
  if (receipt.stale.length > 0) {
    setStatus(`the draft was sent while ${receipt.stale[0]} was reading - it was not attached`);
  }
  // Only record a step if the batch actually changed something: a refused-only drop must not add an
  // undo entry that appears to do nothing.
  if (receipt.added > 0 && !sameDraft(before, snapshotDraft())) {
    draftUndo.push(before);
    if (draftUndo.length > DRAFT_LIMIT) draftUndo.shift();
    draftRedo = [];
    draftNow = snapshotDraft();
  }
  syncUndoButtons();
  return receipt;
}

// The shell owns the intake - the attach button, a paste, a drop - and announces what it took.
chatShell.addEventListener("chat-files", (event) => { addFiles(event.detail.files); });
// A chip removed by hand is worth undoing: the shell says so *before* it changes the list.
chatShell.addEventListener("chat-attachments", (event) => { if (event.detail.action === "remove") pushDraft(); });

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

// Compare only each view's dependencies. An unchanged response never replaces option
// nodes, expanded diagnostic sections, or text the reader is selecting.
const metadataPaintKeys=new Map();
function renderMetadataParts() {
  const parts=[
    ['user',[me,settings.node_name],renderUser],
    ['chip',[runStepScope(),settings.model,settings.context_limit,settings.observability?.last_request?.model,settings.observability?.last?.normalized?.prompt,contextFacts()],updateChip],
  ];
  if(balloon.open) parts.push(
    ['controls',[settings.providers,settings.provider,settings.model,settings.reasoning,settings.model_error,me.role],renderControls],
    ['context',[runStepScope(),contextFacts()],renderContext],
    ['limits',[settings.limits,settings.limits_error,Math.floor(Date.now()/60000)],renderLimits],
    ['usage',[settings.observability,settings.provider,settings.model,settings.output_limit,settings.compact_trigger,settings.compact_reserve,settings.compact_keep,settings.reasoning],renderUsage],
    ['foot',[settings.provider,settings.base_url,settings.database],renderPopFoot]);
  for(const [key,facts,draw] of parts){
    const signature=JSON.stringify(facts);
    if(metadataPaintKeys.get(key)===signature)continue;
    draw();metadataPaintKeys.set(key,signature);
  }
}
// Same-origin windows announce invalidation only, never settings, auth or payloads.
// Live run SSE already carries completion/change events; idle reads remain a fallback.
let metadataChannel=null;
try {
  if(typeof BroadcastChannel==='function') {
    metadataChannel=new BroadcastChannel('wa-ui-invalidation-v1');
    metadataChannel.onmessage=(event)=>{
      if(event.data?.node!==activeNode)return;
      metadataRefreshedAt=0;
      if(uiVisible())void ensureMeta();
    };
  }
}catch(error){ /* periodic reads remain authoritative when unavailable */ }
function notifyMetadataChange() { metadataChannel?.postMessage({node:activeNode}); }
let metadataRefresh = null;
let metadataRefreshedAt = 0;
let metadataRetryAt = 0;
let metadataFailures = 0;
async function refreshMeta() {
  const key = activeNode + ":" + chatSession + ":" + conversationEpoch;
  if (metadataRefresh?.key === key) return metadataRefresh.promise;
  // Direct settings/open-panel/settlement reads still bypass idle scheduling.
  const pending = {key, promise: refreshMetaOnce()};
  metadataRefresh = pending;
  try { return await pending.promise; }
  finally { if (metadataRefresh === pending) metadataRefresh = null; }
}
async function refreshMetaOnce() {
  const target = chatSession;
  const epoch = conversationEpoch;
  const node = activeNode;
  try {
    const query=new URLSearchParams({session_id:target});
    if (activeNode) query.set('node',activeNode);
    const response = await apiFetch("models?"+query, { headers: apiHeaders() });
    const payload = await response.json();
    // A slower response for the thread we just left must not replace the selected thread's usage
    // and observability metadata. The new selection starts its own refresh.
    if (chatSession !== target || conversationEpoch !== epoch || activeNode !== node) return false;
    if (!response.ok) throw new Error(payload.error || "HTTP " + response.status);
    acceptSettings(payload);
    metadataFailures = 0;
    metadataRetryAt = 0;
    metadataRefreshedAt = Date.now();
    updateNodeLabel(settings.node_name, settings.node_worktree);
    // The account tooltip names the node, so it follows the same payload.
    renderMetadataParts();
    // A timed-out write can apply after the immediate reconciliation read.
    // Keep its note tied to the newly observed state on later refreshes too.
    renderSettingsReconciliation(true);
    const provider = activeProvider();
    const label = provider ? provider.label : "local";
    const where = activeNode || "local";
    setText(meta, `${where} · ${label} · ${settings.model}`);
    return true;
  } catch (error) {
    if (chatSession !== target || conversationEpoch !== epoch || activeNode !== node) return false;
    metadataFailures += 1;
    metadataRetryAt = Date.now() + Math.min(30000, 500 * (2 ** Math.min(metadataFailures - 1, 6)));
    // The chat may still be healthy. A catalogue failure must describe only
    // this read, and the watch loop retries it without blocking the transcript.
    meta.textContent = "model info unavailable · retrying (" + String(error.message || error) + ")";
    // A metadata outage must not turn the context-only trigger into an error banner.
    updateContextReadouts();
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
function updateLock(reason, working = true) {
  let lock = document.getElementById("update-lock");
  if (!lock) {
    lock = document.createElement("div");
    lock.id = "update-lock";
    lock.innerHTML = '<div class="lock-card"><span class="update-spinner" aria-hidden="true"></span>' +
      '<div class="lock-title">UI updating</div>' +
      '<div class="lock-reason"></div><div class="lock-actions">' +
      '<button type="button" class="lock-now">reload now</button>' +
      '<button type="button" class="lock-later">keep working</button></div></div>';
    lock.querySelector(".lock-now").addEventListener("click", () => { rememberPlace(); location.reload(); });
    lock.querySelector(".lock-later").addEventListener("click", () => lock.remove());
    document.body.append(lock);
  }
  lock.classList.toggle("working", working);
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
    const position=transcriptPlace(messages);
    sessionStorage.setItem(PLACE_KEY, JSON.stringify({
      session: chatSession,
      top: messages.scrollTop,
      following: follow,
      topics: topics,
      position,
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
  if(place.session===chatSession && place.position)restoreTranscriptPlace(messages,place.position);
}
// Stable row/segment anchors survive growing assistant bodies, prepends and header resizing.
function transcriptPlace(container) {
  const box=container.getBoundingClientRect();
  const visible=Array.from(container.querySelectorAll('[data-ledger-key]')).filter(el=>{const r=el.getBoundingClientRect();return r.bottom>box.top&&r.top<box.bottom;});
  const leaves=visible.filter(el=>!visible.some(other=>other!==el&&el.contains(other)));
  const anchor=leaves.find(el=>el.getBoundingClientRect().top<=box.top)||leaves[0]||visible[0];
  return {top:container.scrollTop,following:container.scrollHeight-container.scrollTop-container.clientHeight<40,
    key:anchor?.dataset.ledgerKey,offset:anchor?anchor.getBoundingClientRect().top-box.top:0,
    attempt:anchor?.dataset.liveAttempt,channel:anchor?.dataset.liveChannel,
    folded:Array.from(container.querySelectorAll('[data-ledger-key]')).map(el=>[el.dataset.ledgerKey,el.hasAttribute('open'),el.classList.contains('open'),
      Array.from(el.querySelectorAll('.reasoning-body,.commentary-body,.tool-output,pre')).map(body=>body.scrollTop),el.dataset.liveAttempt,el.dataset.liveChannel])};
}
function restoreTranscriptPlace(container,place) {
  const elements=Array.from(container.querySelectorAll('[data-ledger-key]'));
  for(const [key,attr,cls,scroll,attempt,channel] of place.folded||[]) {
    const el=elements.find(el=>el.dataset.ledgerKey===key)||
      (attempt&&elements.find(el=>el.dataset.liveAttempt===attempt&&el.dataset.liveChannel===channel));
    if(el){el.toggleAttribute('open',attr);el.classList.toggle('open',cls);
      Array.from(el.querySelectorAll('.reasoning-body,.commentary-body,.tool-output,pre')).forEach((body,i)=>{if(scroll?.[i])body.scrollTop=scroll[i];});}
  }
  container.scrollTop=place.following?container.scrollHeight:place.top;
  const anchor=elements.find(el=>el.dataset.ledgerKey===place.key)||
    (place.attempt&&elements.find(el=>el.dataset.liveAttempt===place.attempt&&el.dataset.liveChannel===place.channel));
  if(!place.following&&anchor)container.scrollTop+=anchor.getBoundingClientRect().top-container.getBoundingClientRect().top-place.offset;
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
function activeChatView() {
  return composerBusy() || Array.from(document.querySelectorAll('wa-agent-session')).some(pane=>pane.shell?.busy);
}
function applyUiVersion(next) {
  if (version === null) { version = next; return "init"; }
  if (next === version) return "same";
  version = next;
  hotSwapStyles();
  if (activeChatView()) {
    pendingReload = true;
    if(!viewMode())setStatus("update ready - reloading when this run finishes");
    updateLock("New UI is ready. Reloading waits for this run to finish; your place and draft are kept.", false);
    return "deferred";
  }
  updateLock("New UI is ready. Reload when convenient; your place and draft are kept.", false);
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
let metaReady = false;
let metaRunning = false;

async function ensureMeta() {
  const interval=!uiVisible() ? 60000 : composerBusy() || balloon.open ? 5000 : 30000;
  if (metaRunning || Date.now() < metadataRetryAt || (metaReady && Date.now() - metadataRefreshedAt < interval)) return;
  metaRunning = true;
  try { metaReady = await refreshMeta(); }
  finally { metaRunning = false; }
}

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
let healthFlight = null;
let healthSample = null;
function nodeHealth(maxAge = 0) {
  const scope=activeNode+':'+session+':'+chatSession+':'+conversationEpoch;
  if (healthFlight?.scope===scope) return healthFlight.promise;
  if (maxAge>0 && healthSample?.scope===scope && Date.now()-healthSample.at<maxAge) return Promise.resolve(healthSample.value);
  const request={scope,promise:null};
  healthFlight=request;
  request.promise=(async()=>{
    try {
      const response=await apiFetch('health',{headers:apiHeaders()});
      const value=response.ok?await response.json():null;
      if(scope===activeNode+':'+session+':'+chatSession+':'+conversationEpoch) healthSample={scope,at:Date.now(),value};
      return value;
    } catch {
      if(scope===activeNode+':'+session+':'+chatSession+':'+conversationEpoch)healthSample=null;
      return null;
    }
    finally {if(healthFlight===request)healthFlight=null;}
  })();
  return request.promise;
}

async function sync(reason) {
  if (synced || syncRunning) return;
  syncRunning = true;
  syncAttempts += 1;
  // Optional model diagnostics share read capacity with account/history
  // recovery. The watch loop starts them only after the transcript is ready.
  const meOk = await refreshMe();
  syncRunning = false;
  if (!meOk) {
    // Why it failed decides what to say. A reload during a run used to show "connecting…" and then
    // "node offline — retrying" on a node that was working perfectly, and the transcript stayed empty
    // because the restore never ran. It cannot run while the run holds the interpreter - that is
    // physical when the node runs one node-thread - but the message can be true, and the retry does the rest.
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
  restoreSession().then((loaded) => {
    restorePlace();
    if (loaded) void ensureMeta();
  });
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
  // Own SSE (including admission wait) owns its view until its finally block.
  // Its watchdog checks exact run standing; idle health alone cannot release it.
  if (reconciling || !synced || ownStreamActive()) return;
  reconciling = true;
  const node=activeNode, target=chatSession, epoch=conversationEpoch, submission=submissionEpoch;
  try {
    const health = await nodeHealth(1000);
    if (node!==activeNode || target!==chatSession || epoch!==conversationEpoch || submission!==submissionEpoch || ownStreamActive()) return;
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
  finally { reconciling = false; }
}

async function watch() {
  // Tell the shell this page's loop is alive, *before* asking the node anything. This is the only
  // per-window proof: the node's page-age counter is global, and WebView2 reports a failed navigation
  // as "finished", so a shell cannot tell an error page from a good one by the load alone. A page
  // stuck on an error page cannot send this, which is exactly what the shell watches for.
  //
  // It must not depend on the node answering. It used to be sent only after `/version` returned, so
  // when a run filled the browser's connection pool with pending reads, `/version` never completed,
  // no heartbeat was sent, and the shell reloaded a page that was alive and would have recovered -
  // the reload re-issued the same requests and re-saturated, so a busy node looked like a dead
  // window and the window looped.
  if (native && typeof native.heartbeat === "function") native.heartbeat();
  try {
    const response = await apiFetch("version");
    const payload = await response.json();
    applyUiVersion(payload.version);
    // The node answered, so finish the first sync if it never finished. This loop always runs.
    if (!synced) sync("watch");
    else {
      // Give durable recovery priority over optional model diagnostics. Periodic
      // versioned reads also reconcile changes made by another window.
      if (!transcriptReady) restoreSession(chatSession, true);
      if (transcriptReady) void ensureMeta();
      // A live stream or update lock needs reconciliation. A durable unfinished notice does not:
      // polling and repainting an interrupted transcript forever would waste reads and restart its view.
      if (transcriptReady && (busy || document.getElementById("update-lock") || trace?.pending)) {
        if (Date.now() - reconciledAt > 5000) { reconciledAt = Date.now(); reconcile(); }
      }
    }
  } catch (error) { /* keep polling: the deadline is what keeps this loop alive */ }
  setTimeout(watch, uiVisible() ? 3000 : 5000);
}

// The node owns the run; the browser only watches it. If one was running when this page
// loaded - a reload mid-run, or a reconnection after the node was busy - the reply is
// already in the ledger, so refresh the transcript once it is no longer in flight instead
// of making the reader reload to see it.
let sawTurnInFlight = false;
let runPolling = false;
let turnPollTimer=null;
let lastFollowAt = 0;
// The thread's `last_seq` as of the last redraw, so a poll redraws only when the run moved.
let followedSeq = null;
let liveRunId = null;
let liveEventSeq = 0;
let liveCheckpointSeq = null;
let liveRunPolling = null;
let liveSyncFailed = false;
let nativeSessionPainted = null;

function resetConversationFollowState() {
  stopLiveness();lastRunStreamAt=0;
  observedRun = null;
  applyRunControls();
  transcriptReady = false;
  transcriptRetryAt = 0;
  transcriptFailures = 0;
  transcriptFailure = "";
  chatShell.warning.clearNotices();
  measuredContexts.delete(messages);
  contextPaintKey='';
  sawTurnInFlight = false;
  followedSeq = null;
  lastFollowAt = 0;
  liveRunId = null;
  liveEventSeq = 0;
  liveCheckpointSeq = null;
  liveRunPolling = null;
  liveSyncFailed = false;
  nativeSessionPainted = null;
}

// Leave the old request running on the node, but stop treating its stream as the view we are in.
// The local reader continues to drain it; its epoch prevents late events and cleanup from touching
// the newly selected conversation.
function detachConversationView() {
  observedRun = null;
  applyRunControls();
  if (busy) setBusy(false);
  controller = null;
  clearStreamNotice();
}

// A run in flight that this window did NOT open - a reload during a run, or one a wake or a job
// started - lost its live socket. The window follows durable rows through /session and reconnects to
// the node's bounded event tail for reasoning, tool steps and other output not saved yet.
async function followRun() {
  const target = chatSession;
  const epoch = conversationEpoch;
  const node = activeNode, submission = submissionEpoch;
  if (!target || ownStreamActive()) return;
  // /sessions is small and carries the thread's `last_seq`; the 1.5 MB /session read happens only
  // when there is something new. Redrawing an unchanged transcript would cost a megabyte every
  // three seconds and fight the reader's scroll for nothing.
  const list = await (await apiFetch("sessions", { headers: apiHeaders() })).json();
  if (chatSession !== target || conversationEpoch !== epoch || activeNode !== node || submission !== submissionEpoch || ownStreamActive()) return;
  const mine = (list.sessions || []).find((entry) => entry.id === target);
  if (!mine) return;
  const seq = Number(mine.last_seq) || 0;
  if (seq === followedSeq) return;
  // Preserve the established epoch/dedupe/backoff and loaded-row cursor contract.
  rememberPlace();
  if (await restoreSession(target, true)) {
    if (chatSession !== target || conversationEpoch !== epoch || activeNode !== node || submission !== submissionEpoch || ownStreamActive()) return;
    restorePlace();
  }
}

// A page reload drops the original chat socket, but the node's run keeps going. The node retains only
// events after the newest durable transcript checkpoint; repaint through that checkpoint before
// applying the live tail, so saved tool calls/results are never duplicated.
async function syncLiveRun(current) {
  if (busy || !chatSession || !current || current.run_id == null || liveRunPolling) return;
  const target = chatSession;
  const epoch = conversationEpoch;
  const node = activeNode;
  if (current.session && current.session !== target) return;
  const submission = submissionEpoch;
  const poll = { target, epoch, node, submission };
  liveRunPolling = poll;
  const id=runKey(current);
  if(id===null) {liveRunPolling=null;setStatus('exact run identity unavailable; saved transcript only');return;}
  const viewing = () => chatSession === target && conversationEpoch === epoch && activeNode === node
    && liveRunId === id && liveRunPolling === poll && !busy && submission === submissionEpoch;
  if (liveRunId !== id) {
    liveRunId = id;
    liveEventSeq = 0;
    liveCheckpointSeq = null;
  }
  try {
    const response = await sessionEventPage(target,id,liveEventSeq);
    const payload = await response.json();
    if (!viewing()) return;
    if (!response.ok) {
      if (response.status === 404) {
        const latest = await nodeHealth();
        if (!viewing()) return;
        if (!activeRun(latest)) {
          await followRun();
          if (!viewing()) return;
          liveRunId = null;
          return;
        }
      }
      throw new Error(payload.error || ("HTTP " + response.status));
    }
    if (liveSyncFailed) {
      liveSyncFailed = false;
      clearStatus();
    }

    if (liveCheckpointSeq !== payload.checkpoint_seq) {
      // The checkpoint may have advanced after the preceding ledger poll. Read again before using
      // its tail, and wait another cycle if the read node-thread has not exposed that row yet.
      if (Number(payload.checkpoint_message_seq) > (Number(followedSeq) || 0)) await followRun();
      if (!viewing()) return;
      if (Number(payload.checkpoint_message_seq) > (Number(followedSeq) || 0)) return;
      liveCheckpointSeq = payload.checkpoint_seq;
      liveEventSeq = Number(payload.checkpoint_seq) || 0;
      if (payload.overflow) setStatus("live output exceeded the replay buffer; saved transcript is still syncing");
      else ensureObservedRunStep(current);
    }
    if (payload.overflow) {
      liveEventSeq = Number(payload.next_seq) || liveEventSeq;
      setStatus("live output exceeded the replay buffer; saved transcript is still syncing");
      return;
    }
    for (const item of payload.events || []) {
      const seq = Number(item.seq) || 0;
      if (seq <= liveEventSeq) continue;
      handleEvent(item.event);
      liveEventSeq = seq;
    }
  } catch (error) {
    if (!viewing()) return;
    liveSyncFailed = true;
    setStatus("live sync retrying: " + String(error.message || error));
  } finally {
    if (liveRunPolling === poll) liveRunPolling = null;
  }
}

function turnHealthDelay() {
  const streamFresh=busy && lastRunStreamAt>0 && Date.now()-lastRunStreamAt<5000 && !trace?.pending;
  return !uiVisible() ? 15000 : streamFresh ? 5000 : composerBusy() || sawTurnInFlight ? 1000 : 5000;
}
async function watchTurn() {
  // One at a time: a poll that has not answered yet is not a reason to start another, and when the
  // node runs one node-thread that is the difference between asking and queueing.
  if (runPolling) return;
  clearTimeout(turnPollTimer);
  runPolling = true;
  const node=activeNode, target=chatSession, epoch=conversationEpoch, submission=submissionEpoch;
  const viewing=()=>node===activeNode && target===chatSession && epoch===conversationEpoch && submission===submissionEpoch;
  try {
    const health = await nodeHealth();
    if (!viewing()) return;
    if (!health) {observeRunHealth(null);throw new Error('health unavailable');}
    if (busy) {identifySubmittedRun(health);observeRunHealth(health);}
    if (typeof health.exec_timeout_seconds==='number') execTimeoutSeconds=health.exec_timeout_seconds;
    const ownId=busy?runKey(activeRunId):runKey(activeRun(health));
    if(ownId) void refreshOperationProgress(health,threadOfRun(health,ownId));
    // Keep the session list's live badges in step with the run this loop is already watching, with
    // no extra request: a thread turns "running" the moment a run is admitted and back when it ends.
    if (document.body.classList.contains("engine")) applySessionHealth(health);
    const current = activeRun(health);
    observedRun = current;
    if (!busy) observeRunHealth(health);
    applyRunControls();
    if (current) {
      sawTurnInFlight = true;
      // Only when this window is not streaming the run itself: `busy` means its own stream is
      // drawing it live, and a repaint under a live stream would fight it for the same bubble.
      if (!busy) {
        if (!followedSeq || Date.now() - lastFollowAt >= 3000) {
          lastFollowAt = Date.now();
          await followRun();
          if (!viewing()) return;
        }
        await syncLiveRun(current);
        if (viewing()) ensureObservedRunStep(current);
      }
    } else if (!busy && await syncNativeSession(target, epoch, node)) {
      // Native children have opaque attempts and never enter HTTP run admission.
    } else if (!busy && sawTurnInFlight) {
      sawTurnInFlight = false;
      liveRunId = null;
      liveEventSeq = 0;
      liveCheckpointSeq = null;
      if (chatSession) {
        clearStatus();
        rememberPlace();
        await restoreSession();
        if (!viewing()) return;
        restorePlace();
      }
    }
  } catch (error) { /* the node is down; watchNode handles that */ }
  finally {
    runPolling = false;
    // Fresh own-stream events prove transport life; quiet tools/followers retain the fast check.
    turnPollTimer=setTimeout(watchTurn, turnHealthDelay());
  }
}

// ---- native companion window (wa-window / WebView2) ----------------------
// `let`, not `const`: the harness runs the page with no shell on purpose (to prove the page degrades), and
// a test that wants to prove the *window* path has to be able to hand it one. Same seam as `reload`.
let native = window.wasmAgent || null;
const orb = document.getElementById("orb");
const collapse = document.getElementById("collapse");
const dragbar = document.getElementById("dragbar");

function applyMode(mode) {
  const wasResting=document.body.classList.contains('ui-resting');
  document.body.classList.toggle("compact", mode === "compact");
  document.body.classList.toggle("expanded", mode === "expanded");
  try { localStorage.setItem("wa-mode", mode); } catch (error) { /* private mode */ }
  document.body.classList.toggle('ui-resting', !uiVisible());
  if(wasResting && mode==='expanded')resumeUi();
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
let controlNode = "client";
let controlCanvasSize = { w: 0, h: 0 };
let controlScreen = { w: 0, h: 0, x: 0, y: 0 };

function controlHeaders(extra) {
  return Object.assign(apiHeaders(extra), { "X-WA-Node": controlNode });
}

function b64ToBytes(base64) {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

async function clientAction(payload) {
  const response = await apiFetch("client", {
    method: "POST",
    headers: controlHeaders({ "Content-Type": "application/json" }),
    body: JSON.stringify(payload),
  });
  const result = await response.json();
  if (result.error) controlHint.textContent = result.error;
  return result;
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

function formatResourceBytes(bytes) {
  const value = Number(bytes);
  if (!Number.isFinite(value) || value <= 0) return "?";
  const units = ["B", "KB", "MB", "GB", "TB", "PB"];
  const power = Math.min(Math.floor(Math.log(value) / Math.log(1024)), units.length - 1);
  const amount = value / Math.pow(1024, power);
  return `${amount >= 10 || power === 0 ? amount.toFixed(0) : amount.toFixed(1)}${units[power]}`;
}

function resourcePercent(value) {
  const number = Number(value);
  return Number.isFinite(number) ? `${Math.round(number)}%` : "?";
}

function formatNodeResources(resources, online) {
  if (!online) return "resources offline";
  if (!resources || typeof resources !== "object") return "resources pending";
  const ram = resources.memory || {};
  const disk = resources.disk || {};
  return `CPU ${resourcePercent(resources.cpu?.used_percent)} · RAM ${resourcePercent(ram.used_percent)}/${formatResourceBytes(ram.total_bytes)} · DISK ${resourcePercent(disk.used_percent)}/${formatResourceBytes(disk.total_bytes)}`;
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
      const resources = document.createElement("span");
      resources.className = "node-resources";
      resources.textContent = formatNodeResources(node.resources, node.online);
      resources.title = "Latest node sample: CPU use · RAM use/total · workspace disk use/total";
      row.append(resources);
      row.append(nodeButton("talk", () => { balloon.close(); input.focus(); }));
      if (node.kind === "peer" && node.online && me.role === "master") {
        row.append(nodeButton("control", () => openControl(node.name)));
      }
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
    const replication=document.createElement('details');
    const summary=document.createElement('summary'); summary.textContent='Replication diagnostics';
    const evidence=document.createElement('pre'); replication.append(summary,evidence);nodesBox.append(replication);
    replication.addEventListener('toggle',async()=>{
      if(!replication.open)return;
      try { evidence.textContent=JSON.stringify(await taskRequest('sync'),null,2); }
      catch(error) { evidence.textContent='Replication status unavailable: '+error.message; }
    });
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
      headers: controlHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ max_width: 800, full: !!full }),
    })).json();
    if (payload.error) {
      controlHint.textContent = payload.error;
      return;
    }
    controlScreen = { w: payload.screen_width, h: payload.screen_height,
      x: payload.origin_x || 0, y: payload.origin_y || 0 };
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

// ---- the inspector window ----------------------------------------------------------------
//
// The node's own page as a *view*. The reuse is the **shell's**, not this page's: `rust/wa-window/src/main.rs`
// `open_view` (:404-421) returns early when `state.views` already holds a window whose title is this view's
// name (:406 `if state.views.iter().any(|open| open.window.title() == view)`), logging "view … is already
// open" and opening nothing. So this page's half is only the constant name below - asking twice asks for the
// same window - and nothing here reloads, navigates or otherwise disturbs the window that is already open.
// The running window is never touched: this only asks the shell for a window of its own.
const INSPECT_VIEW = "inspect";

// A second wa-window on the node's page. Each view's webview is created with Chromium's *default* context
// menu enabled (`main.rs:506`, `.with_default_context_menus(true)` - the main window's is disabled at :611),
// so in the inspector the browser's own menu - `Inspect element` included - is what the reader gets, and the
// parts of the UI can be navigated and polished in the real DevTools rather than in a DOM panel that only
// looks like one. This page must therefore *not* suppress that event; see the `contextmenu` listener.
//
// Never from inside a view, for the reason the patch and control views refuse it too: a window opening a
// window is how you get two of them, and the second is the one that stacks.
function openInspectWindow() {
  if (!native || typeof native.openView !== "function") {
    setStatus("This window has no shell to open a second window in; the inspector needs the desktop window.");
    return false;
  }
  if (viewMode()) {
    setStatus("This window is a view of its own; open the inspector from the main chat window.");
    return false;
  }
  native.openView(INSPECT_VIEW, viewUrl(INSPECT_VIEW));
  return true;
}

function openOrchestrator() {
  const url=viewUrl('orchestrator');
  if(native && typeof native.openView==='function') native.openView('orchestrator',url);
  else if(!window.open(url,'wa-orchestrator')) meta.textContent='Allow a window to open the orchestrator.';
}
orchestratorBtn.addEventListener('click',openOrchestrator);

let orchestratorPanel=null;
let orchestratorPolling=false;
let orchestratorTimer=null;
async function orchestratorRequest(body) {
  const response=await apiFetch('subagents',{method:'POST',headers:apiHeaders({'Content-Type':'application/json'}),body:JSON.stringify(body)},65000);
  const result=await response.json();
  if(!response.ok || result.error) throw new Error(result.error || `HTTP ${response.status}`);
  return result;
}
function saveOrchestratorLayout() {
  if(!orchestratorPanel)return;
  const panes=[...orchestratorPanel.panes.values()].map(pane=>({id:pane.task.subagent_id,draft:pane.input.value}));
  try { localStorage.setItem('wa-orchestrator-layout:'+session,JSON.stringify({panes,drafts:[...orchestratorPanel.drafts]})); } catch(error) { orchestratorPanel.message='Layout could not be saved: '+error.message; }
}
// A read this view can live without. It hands back the error instead of throwing, because one
// unavailable source must not take the whole panel down - and the view then says which part it could
// not read, rather than showing a short list that reads as "nothing is running".
async function orchestratorRead(path) {
  try {
    const response=await apiFetch(path,{headers:apiHeaders()});
    const value=await response.json();
    if(!response.ok || value.error) throw new Error(value.detail || value.error || `HTTP ${response.status}`);
    return {value};
  } catch(error) { return {error:path+': '+error.message}; }
}
// The orchestrator lists children, not dispatches.
//
// A dispatch row is a placement: it exists because the dispatcher sent a child somewhere, and it
// carries the destination and the state. It is not the whole truth about what is running. A child
// started outside placement has no row there at all - it exists only as a session with a worktree -
// and a child the dispatcher has settled drops off the list while its session is still unfinished.
// Either way the child is invisible, and a child you cannot see is one you cannot cancel or reach.
//
// Active dispatch states provide cards. A recordless child also needs current run health:
// an unfinished ledger or retained checkout alone cannot prove anything is running.
// Historical/unknown records stay accessible in Engine, not in this active surface.
const LOCAL_NODE='local';
function namedNode(nodes, id) {
  if(!id || id===LOCAL_NODE) return nodes.find(node=>node.local_node) || null;
  return nodes.find(node=>node.id===id || node.node_id===id) || null;
}
function subagentCounts(localName, health) {
  const counts=health && health.subagents;
  if(!counts) return localName+': the node did not report its subagent counts';
  return localName+': '+counts.running+' running · '+counts.queued+' queued · '+counts.active+' active';
}
function liveChildRows({sessions=[], dispatches=[], fleet={}, health={}, errors=[]} = {}) {
  const nodes=(fleet.nodes || []).filter(node=>node.kind!=='client');
  const localName=(nodes.find(node=>node.local_node) || {}).name || 'this node';
  const byId=new Map(sessions.map(session=>[session.id,session]));
  // Claim every known dispatch before filtering so historical/unknown tasks cannot
  // reappear as supposedly live merely through an unfinished ledger tail.
  const claimed=new Set(dispatches.map(task=>task.session_id).filter(Boolean));
  const running=runningSessions(health);
  const rows=[];
  for(const task of agentLatestTasks(dispatches)) {
    if(!agentTaskActive(task)) continue;
    const session=byId.get(task.session_id);
    const id=task.execution_node || LOCAL_NODE;
    const node=namedNode(nodes,id);
    claimed.add(task.session_id);
    rows.push({key:'dispatch:'+task.subagent_id,source:'dispatch',task,
      subagent_id:task.subagent_id || '',session_id:task.session_id || '',
      title:task.title || (session && session.title) || task.prompt || 'Untitled child',
      state:task.state || 'unknown',detail:(session && session.state_detail) || '',
      node:id,node_name:node ? node.name : id,node_peer:node ? !node.local_node : id!==LOCAL_NODE,
      node_source:node ? 'the machine the dispatcher sent this child to'
        : 'the dispatch record names a machine this node does not know'});
  }
  for(const session of sessions) {
    if(claimed.has(session.id) || !running.has(session.id)) continue;
    const child=!!session.parent_session_id || String(session.id).indexOf('child:')===0;
    if(!child) continue;
    rows.push({key:'session:'+session.id,source:'session',task:null,subagent_id:'',session_id:session.id,
      title:session.title || session.id,state:'running',detail:session.state_detail || '',
      node:LOCAL_NODE,node_name:localName,node_peer:false,node_online:true,
      node_source:'no dispatch record: read from the ledger of the node that holds this session'});
  }
  const peers=rows.filter(row=>row.node_peer).length;
  const note=[peers ? peers+' row(s) are on another node: this window shows the dispatcher\'s record of them, because a peer\'s own live children are not reachable from here.'
    : 'A peer\'s own live children are not reachable from here.'];
  note.push('History and unresolved outcomes remain in Engine → Sessions; unfinished alone is not active.');
  if(errors.length) note.push('Not everything could be read: '+errors.join('; ')+'.');
  return {rows,counts:subagentCounts(localName,health),note:note.join(' ')};
}

// ---- lanes: the checkout a child was given ------------------------------------------------
//
// A lane is a *recorded* checkout, not a guess: `/sessions` selects each session's own row, so
// `worktree`, `workspace_branch`, `workspace_state` and `workspace_error` are the child's workspace
// as the node stored it. A dispatch row carries no checkout of its own (the runtime's task view has
// no workspace field), so grouping by anything the dispatcher knows would group by machine rather
// than by lane - and a lane is what the reader has to reason about: one checkout, the children
// working in it, and whether anything is still owed on it.
//
// A lane's facts are folded across every child that holds its key, because a lane is one checkout:
// "is this lane retired" is a question about all of its children, not about the first session row a
// loop happened to see. A child with no branch of its own works in the node's own checkout: that is
// the `main` lane, stated as such rather than as a missing key.
const MAIN_LANE='main';
const UNRECORDED_LANE='no recorded checkout';
// The four outcomes a lane is read for. Each is a *measurement* or an explicit unknown with the
// reason: `merged` and `clean` are git facts about a ref (containment in origin/main, a clean tree)
// which this view is not given, and a check nobody made is worse than no checklist at all.
function laneChecklist(lane, rows) {
  // `retired` is a recorded end state, not the absence of a path: a lane whose children recorded a
  // released checkout has been retired, a lane with a bound checkout has not, and a child that never
  // had a checkout of its own leaves it unknown rather than answered either way.
  const bound=rows.some(row=>String(row.worktree || '') && String(row.workspace_state || '')!=='released');
  const released=rows.length>0 && rows.every(row=>String(row.workspace_state || '')==='released');
  const retired=released ? 'yes' : bound ? 'no' : 'unknown';
  // `main-only` is a statement about the *lane*, so it has to come from the same recorded facts the
  // lane is keyed by - branch-or-worktree - and not from the branch name alone. A lane whose children
  // recorded a worktree and no branch name is a checkout of its own (its header draws that path), and
  // reporting it as main-only would contradict the row directly above it.
  const checkout=lane.branch || lane.worktree;
  const ownCheckout=!!checkout;
  return [
    {outcome:'merged',state:'unknown',
      detail:'this view reads no branch tip and no origin/main ref, so containment is not measured here'},
    {outcome:'retired',state:rows.length ? retired : 'unknown',
      detail:released ? 'every child of this lane recorded a released checkout; the branch is retained'
        : bound ? 'a child of this lane still holds a bound checkout'
        : rows.length ? 'no child of this lane recorded a released checkout; nothing was retired here'
        : 'no session record for this lane'},
    {outcome:'clean',state:'unknown',
      detail:"a checkout's own git status is measured by the node's settlement review, which this view is not given"},
    {outcome:'main-only',state:ownCheckout ? 'no':'yes',
      detail:ownCheckout ? 'this lane holds a checkout of its own ('+checkout+')'
        : 'this lane holds no branch and no worktree of its own: its children work in the node checkout'}];
}
function laneRecord(key,rows) {
  const first=rows[0] || {};
  const branch=String(first.workspace_branch || '');
  const worktree=rows.map(row=>String(row.worktree || '')).find(Boolean) || '';
  const lane={key,recorded:rows.length>0,branch,worktree,children:rows.length,
    label:branch || worktree || "main (the node's own checkout)"};
  lane.checklist=laneChecklist(lane,rows);
  return lane;
}
// One read of the session ledger grouped into lanes, indexed by session id: every card's lane comes
// from here, and the index is what a dispatch row is joined against.
function lanesBySession(sessions) {
  const groups=new Map();
  for(const session of sessions || []) {
    if(!session || !session.id) continue;
    const key=String(session.workspace_branch || '') || String(session.worktree || '') || MAIN_LANE;
    if(!groups.has(key)) groups.set(key,[]);
    groups.get(key).push(session);
  }
  const index=new Map();
  for(const [key,rows] of groups) {
    const lane=laneRecord(key,rows);
    for(const row of rows) index.set(String(row.id),lane);
  }
  return index;
}
// A child with no session row of its own has no recorded checkout to be grouped by, and saying so is
// the only honest grouping: inventing a lane for it would file it under somebody else's worktree.
function taskLane(task,index) {
  const lane=task.session_id ? index.get(String(task.session_id)) : null;
  if(lane) return lane;
  const unknown={key:UNRECORDED_LANE,recorded:false,worktree:'',branch:'',children:1,label:UNRECORDED_LANE};
  unknown.checklist=['merged','retired','clean','main-only'].map(outcome=>({outcome,state:'unknown',
    detail:'no session record for this child'}));
  return unknown;
}

async function refreshOrchestrator() {
  if(!orchestratorPanel || orchestratorPolling)return;
  orchestratorPolling=true;
  try {
    const fleet=await orchestratorRequest({action:'fleet'});
    if(!orchestratorPanel.configured)orchestratorPanel.configure(fleet);
    const list=await orchestratorRequest({action:'list'});
    // The dispatches are not the whole truth about what is running: read the session ledger and the
    // node's own subagent view too, and hand the panel every child with the source of each fact.
    const [sessions,health]=await Promise.all([orchestratorRead('sessions'),orchestratorRead('health')]);
    const sessionRows=(sessions.value && sessions.value.sessions) || [];
    // The cards are grouped by lane, so each one is handed the lane its own session recorded. This
    // is also the only place the panel needs the ledger for: a card is a child, and its lane is a fact
    // about where that child works.
    const lanes=lanesBySession(sessionRows);
    orchestratorPanel.data=(list.subagents || []).map(task=>({...task,lane:taskLane(task,lanes)}));
    const live=liveChildRows({sessions:sessionRows,
      dispatches:list.subagents || [],fleet,health:health.value || {},
      errors:[sessions.error,health.error].filter(Boolean)});
    orchestratorPanel.live=live;
    if(!orchestratorPanel.restored) {
      orchestratorPanel.restored=true;
      let saved={};try { saved=JSON.parse(localStorage.getItem('wa-orchestrator-layout:'+session) || '{}'); } catch(error) { /* layout only */ }
      orchestratorPanel.drafts=new Map(saved.drafts || []);
      orchestratorPanel.restoring=true;
      for(const item of saved.panes || []) {
        const task=orchestratorPanel.activeTasks.find(task=>task.subagent_id===item.id);
        if(task)orchestratorPanel.pin(task).input.value=item.draft || '';
        else if(item.draft)orchestratorPanel.drafts.set(item.id,item.draft); // Hidden history must not lose an unsent draft.
      }
      orchestratorPanel.restoring=false;
    }
    for(const pane of orchestratorPanel.allPanes()) await refreshAgentPane(pane);
    orchestratorPanel.message=`${orchestratorPanel.activeTasks.length} active card(s) · closing this window keeps work running`;
  } catch(error) { orchestratorPanel.message='Orchestration unavailable: '+error.message; }
  finally {
    orchestratorPolling=false;
    if(orchestratorPanel?.isConnected)orchestratorTimer=setTimeout(refreshOrchestrator,2000);
  }
}
// A settled child's own words decide its footer where they are definite: a failure says `failed` and
// a cancellation says `unfinished`. A completion is left to the ledger's last row - the rule this
// window's own repaint already uses - because a child that stopped after a tool call ran to
// completion without answering, and `completed` over a stopped run is the contradiction this must
// not print.
function childRunState(task) {
  if(!task || !task.settled) return 'unfinished';
  if(task.state==='failed') return 'failed';
  if(task.state==='cancelled') return 'unfinished';
  return undefined;
}
// The page this view asks a child's transcript for, and what happens when the node refuses the size.
//
// `lua/core/session_view.lua` refuses a `byte_limit` above `MAX_BYTES - 2048`, and `MAX_BYTES` is
// lowered from 51200 to as little as 4096 by `WASM_AGENT_TOOL_OUTPUT_BYTES` - a supported setting under
// which a hard-coded 40960 made *every* child pane read "Conversation unavailable:
// invalid_session_byte_limit", with no transcript at all. No route reports that budget to a window, so
// this asks for the page it wants and, on that refusal, asks again with no byte budget at all (the
// node's own valid default) and says so in the pane: a conversation that silently shrank is a reader
// wondering where the rows went. The answer is remembered for every pane, because it is a fact about the
// node in front of us rather than about one child.
let panePageBytes=40960;
let panePageNote='';
let panePageNoteDetail='';
async function panePage(pane, options) {
  const target=pane.task.session_id;
  const validate=page=>{
    if(!options.message_id && page.session_id!==target)throw Error('native_session_identity_mismatch');
    return page;
  };
  const request={action:'session',id:pane.task.subagent_id,limit:200,...options};
  if(panePageBytes)request.byte_limit=panePageBytes;
  try { return validate(await orchestratorRequest(request)); }
  catch(error) {
    if(!panePageBytes || !/invalid_session_byte_limit/.test(String(error.message))) throw error;
    // The note is one line on purpose: it sits in the pane's status row, and a paragraph there would
    // take the room the transcript needs (measured: a 250-character note cost 75px of transcript, which
    // is the readability this pane exists for). The full reason travels in the row's title.
    panePageNote='page '+Math.round(panePageBytes/1024)+' KiB refused ('+error.message+'): reading the page size the node chooses';
    panePageNoteDetail='This node bounds a transcript page by its own tool-output budget '+
      '(WASM_AGENT_TOOL_OUTPUT_BYTES), which is smaller than the '+Math.round(panePageBytes/1024)+
      ' KiB page this view asked for. The pane renders the page the node returns instead, so a child\'s transcript '+
      'shows fewer rows here than it would on the default budget.';
    panePageBytes=0;
    delete request.byte_limit;
    return validate(await orchestratorRequest(request));
  }
}
// The rows to draw for one child: the node's newest page, extended backwards while that page opens
// on a `tool` row whose call sits just above it. In this renderer a result belongs to the call above
// it, so a page cut between them would draw nothing for evidence the reader came to see. The loop is
// bounded and normally never runs: one page is the whole conversation.
// Shared ordered ledger collector: callers supply their authenticated session page transport.
// It preserves original rows and identities and refuses cyclic paging rather than inventing history.
async function collectSessionHistory(readPage) {
  let page=await readPage({}),rows=page.messages||[],seen=new Set();
  while(page.has_more_before) {
    const cursor=page.next_before_seq ?? rows[0]?.seq;
    if(cursor==null || seen.has(cursor))throw Error('session_cursor_did_not_advance');
    seen.add(cursor);
    page=await readPage({before_seq:cursor});
    const earlier=(page.messages||[]).filter(row=>row.seq<cursor);
    if(!earlier.length)throw Error('session_history_incomplete');
    rows=earlier.concat(rows);
  }
  return rows;
}
// Owner-authenticated journal attachment shared by any session host. Ledger checkpoint precedes tail.
function sessionEventPage(thread,key,after) {
  return apiFetch('run-events',{method:'POST',headers:apiHeaders({'Content-Type':'application/json'}),body:JSON.stringify({thread,run_id:runKey(key),after})});
}
const sessionAttachPending=new Map();
async function attachSessionJournal(thread,readHistory) {
  const key=activeNode+'|'+thread;
  if(sessionAttachPending.has(key))return sessionAttachPending.get(key);
  const pending=attachSessionJournalOnce(thread,readHistory);
  sessionAttachPending.set(key,pending);
  try{return await pending;}finally{if(sessionAttachPending.get(key)===pending)sessionAttachPending.delete(key);}
}
async function attachSessionJournalOnce(thread, readHistory) {
  let rows=await readHistory();
  const response=await apiFetch('runs',{method:'POST',headers:apiHeaders({'Content-Type':'application/json'}),body:JSON.stringify({action:'status',thread})});
  const status=await response.json();
  if(!response.ok || status.ok!==true || status.conversation!==thread)throw Error('session_run_status_unavailable');
  const runs=(status.runs||[]).filter(row=>runKey(row)!==null);
  const live=runs.filter(run=>/^(running|queued|not_started)$/.test(run.state));
  const current=(live.length?live:runs).sort((a,b)=>BigInt(runKey(a))<BigInt(runKey(b))?-1:1).at(-1);
  if(!current)return {rows,events:[],state:'unknown'};
  const events=[];let after=0,checkpoint=null,seen=new Set();
  for(;;){
    const replayResponse=await sessionEventPage(thread,runKey(current),after);
    const replay=await replayResponse.json();
    if(!replayResponse.ok || runKey(replay)!==runKey(current))throw Error('session_replay_identity_mismatch');
    if(checkpoint===null || checkpoint!==replay.checkpoint_seq){
      checkpoint=replay.checkpoint_seq;rows=await readHistory();
      const loaded=rows.reduce((max,row)=>Math.max(max,Number(row.seq)||0),0);
      if(Number(replay.checkpoint_message_seq)>loaded)throw Error('session_checkpoint_not_loaded');
      events.length=0;seen.clear();
    }
    for(const item of replay.events||[])if(!seen.has(item.seq)){seen.add(item.seq);events.push(item.event);}
    if(!replay.has_more)break;
    if(replay.next_seq<=after)throw Error('session_event_cursor_did_not_advance');
    after=replay.next_seq;
  }
  return {rows,events,state:current.state,runKey:runKey(current)};
}
async function nativeSessionTask(thread) {
  if(!thread)return null;
  const response=await apiFetch('subagents',{method:'POST',headers:apiHeaders({'Content-Type':'application/json'}),
    body:JSON.stringify({action:'lookup_session',conversation_id:thread})});
  const result=await response.json();
  if(!response.ok || result.error)throw Error(result.error||'native_session_discovery_unavailable');
  if (result.found === false && result.task == null) return null;
  if (result.found !== true || !result.task || typeof result.task !== 'object') throw Error('native_session_lookup_contract_invalid');
  const task=result.task;
  if(task.session_id!==thread || task.transport!=='native') throw Error('native_session_lookup_identity_mismatch');
  if (![task.subagent_id, task.task_id, task.attempt_id, task.node_id, task.event_node_id, task.event_epoch]
    .every(value => typeof value === 'string' && value.length > 0)) throw Error('native_event_identity_unavailable');
  return task;
}
// Native identity is intentionally opaque; never feed it to runKey or /run-events.
async function attachNativeJournal(task, readHistory, viewing=()=>true) {
  const identity={id:task.subagent_id,attempt_id:task.attempt_id,session_id:task.session_id,
    node_id:task.node_id,event_node_id:task.event_node_id,event_epoch:task.event_epoch};
  if(!identity.id || !identity.attempt_id || !identity.event_node_id || !identity.event_epoch)throw Error('native_event_identity_unavailable');
  let rows=await readHistory(),after=0,checkpoint=null,events=[],raw=[],seen=new Set(),last;
  if(!viewing())throw Error('native_session_view_changed');
  for(;;) {
    const page=await orchestratorRequest({action:'events',...identity,after});
    if(!viewing())throw Error('native_session_view_changed');
    if(page.transport!=='native' || page.task_id!==task.task_id || page.attempt_id!==identity.attempt_id ||
      page.session_id!==identity.session_id || page.node_id!==identity.node_id || page.event_node_id!==identity.event_node_id || page.event_epoch!==identity.event_epoch)
      throw Error('native_event_identity_mismatch');
    if(page.durable!==true)throw Error('native_event_evidence_unavailable');
    if(checkpoint!==page.checkpoint_seq) {
      rows=await readHistory();
      if(!viewing())throw Error('native_session_view_changed');
      const loaded=rows.reduce((max,row)=>Math.max(max,Number(row.seq)||0),0);
      if(Number(page.checkpoint_message_seq)>loaded)throw Error('native_session_checkpoint_not_loaded');
      checkpoint=page.checkpoint_seq;events=[];raw=[];seen.clear();after=Number(checkpoint)||0;
    }
    for(const item of page.events||[]) {
      if(!Number.isSafeInteger(item.seq) || item.seq<=Number(checkpoint))throw Error('native_event_sequence_invalid');
      if(seen.has(item.seq)) {
        if(JSON.stringify(raw.find(row=>row.seq===item.seq))!==JSON.stringify(item))throw Error('native_event_identity_changed');
      }else {
        if(item.seq!==(raw.at(-1)?.seq||Number(checkpoint))+1)throw Error('native_event_sequence_gap');
        seen.add(item.seq);events.push(item.event);raw.push(item);
      }
    }
    if(page.next_seq!==(raw.at(-1)?.seq||Number(checkpoint)))throw Error('native_event_cursor_incomplete');
    last=page;
    if(!page.has_more)break;
    if(!Number.isSafeInteger(page.next_seq) || page.next_seq<=after)throw Error('native_event_cursor_did_not_advance');
    after=page.next_seq;
  }
  return {rows,events,raw,state:last.state,settled:last.settled,identity,checkpointSeq:checkpoint,nextSeq:last.next_seq};
}
async function syncNativeSession(target,epoch,node) {
  const credential=session,submission=submissionEpoch;
  const viewing=()=>target===chatSession && epoch===conversationEpoch && node===activeNode && credential===session && !busy && submission===submissionEpoch;
  const task=await nativeSessionTask(target);
  if(!viewing() || !task)return false;
  try {
    const pane={task};
    const attached=await attachNativeJournal(task,async()=>(await paneMessages(pane)).rows,viewing);
    if(!viewing())return true;
    if(retainNativeTerminal(transcript,task,attached.rows)) {
      setStatus('Native journal restored; stored messages and previously seen output retained.');
      transcriptReady=true;
      return true;
    }
    const painted=JSON.stringify([attached.identity,attached.rows,attached.raw,attached.state]);
    if(painted!==nativeSessionPainted) {
      rememberPlace();
      repaintMessages(attached.rows,{state:childRunState({...task,state:attached.state}),active:!attached.settled});
      renderJournalEvents(attached.events,attached.raw,attached.identity);
      followedSeq=attached.rows.reduce((max,row)=>Math.max(max,Number(row.seq)||0),0);
      restorePlace();nativeSessionPainted=painted;
      rememberNativeRows(transcript,task,attached.rows,attached.raw);
    }
    liveEventSeq=attached.nextSeq;liveCheckpointSeq=attached.checkpointSeq;
    transcriptReady=true;
  }catch(error){
    if(viewing()) {
      let note='Native live journal unavailable: '+error.message;
      // Only storage unavailability permits a ledger fallback; identity/cursor refusals do not.
      if(nativeJournalUnavailable(error))try {
        const result=await paneMessages({task});
        if(!viewing())return true;
        const terminal={...task,...result.task};
        if(terminal.settled) {
          retainNativeTerminal(transcript,task,result.rows,true,terminal);
          followedSeq=result.rows.reduce((max,row)=>Math.max(max,Number(row.seq)||0),0);
          transcriptReady=true;
          note+='; showing stored terminal messages. Previously seen output retained; raw history gap remains.';
        }
      }catch(fallback){note+='; stored messages unavailable: '+fallback.message;}
      if(viewing())setStatus(note);
    }
  }
  return true;
}
const nativeRetainedViews=new WeakMap();
function nativeViewKey(task) {
  return JSON.stringify([session,activeNode,conversationEpoch,task.task_id,task.subagent_id,task.session_id,
    task.attempt_id,task.node_id,task.event_node_id,task.event_epoch]);
}
function nativeJournalUnavailable(error) {
  return /^(native_event_evidence_unavailable|native_event_journal_(read|write)_failed)(:|$)/.test(error.message);
}
function rememberNativeRows(container,task,rows,raw=[]) {
  const ids=new Set(rows.map(row=>String(row.id||row.seq)));
  for(const item of raw)if(item.event?.message_id)ids.add(String(item.event.message_id));
  nativeRetainedViews.set(container,{key:nativeViewKey(task),ids,terminal:false});
}
// During a terminal journal gap, append authenticated ledger messages through the shared
// renderer. Keep the existing DOM (raw identities, folds and scroll anchors) intact. Once
// the journal returns, retain this explicitly mixed-source view rather than replaying it.
function retainNativeTerminal(container,task,rows,gap=false,terminal=task) {
  const key=nativeViewKey(task);
  let retained=nativeRetainedViews.get(container);
  if(retained?.key!==key)retained=null;
  if(!gap && !retained?.terminal)return false;
  if(!retained) {
    retained={key,ids:new Set(),terminal:false};
    const keys=Array.from(container.querySelectorAll('[data-ledger-key]'),element=>element.dataset.ledgerKey);
    for(const row of rows) {
      const id=String(row.id||row.seq);
      if(keys.some(key=>key===id||key.startsWith(id+':segment:')))retained.ids.add(id);
    }
    nativeRetainedViews.set(container,retained);
  }
  const missing=rows.filter(row=>!retained.ids.has(String(row.id||row.seq)));
  if(missing.length) {
    const place=transcriptPlace(container),staged=document.createElement('div');
    // Tool topics initialise when connected, including on a fresh ledger-only pane.
    staged.hidden=true;document.body.append(staged);
    try {
      const painted=paintChildTranscript(staged,missing,{state:childRunState(terminal),active:false});
      if(painted.failed)throw Error('native_terminal_messages_render_failed: '+painted.firstFailure);
      for(const element of staged.children)element.dataset.source='stored-session';
      container.append(...staged.childNodes);
    }finally{staged.remove();}
    restoreTranscriptPlace(container,place);
    for(const row of missing)retained.ids.add(String(row.id||row.seq));
  }
  retained.terminal=true;
  return true;
}
// Projection addresses cite genuine native event IDs until a reply supplies its durable message ID.
const journalPhaseClocks=new WeakMap();
function renderJournalEvents(events,raw,identity) {
  let clocks=journalPhaseClocks.get(transcript);
  if(!clocks){clocks=new Map();journalPhaseClocks.set(transcript,clocks);}
  for(const [i,event] of events.entries()) {
    const prior=runStepState?.active;
    handleEvent(event);
    if(rendererTask&&identity&&raw?.[i]&&runStepState?.active!==prior&&runStepState?.active) {
      const key=identity.attempt_id+':'+raw[i].seq;
      if(clocks.has(key))runStepState.active.started=clocks.get(key);
      else clocks.set(key,runStepState.active.started);
    }
    if(!identity||!raw?.[i])continue;
    const prefix='native:'+identity.attempt_id+':event:'+raw[i].seq;
    if(runBubble) {
      if(!runBubble.dataset.ledgerKey)runBubble.dataset.ledgerKey=prefix;
      for(const [n,el] of Array.from(runBubble.querySelectorAll('wa-run,wa-trace,wa-retry,wa-reasoning,wa-commentary,.seg')).entries())if(!el.dataset.ledgerKey){
        el.dataset.ledgerKey=prefix+':segment:'+n;el.dataset.liveAttempt=identity.attempt_id;el.dataset.liveChannel=event.type;
      }
    }
    if(event.type==='reply'&&event.message_id)for(const el of transcript.querySelectorAll('.seg[data-ledger-key],wa-reasoning[data-ledger-key]'))
      if(el.dataset.ledgerKey.startsWith(String(event.message_id)+':segment:')){
        el.dataset.liveAttempt=identity.attempt_id;el.dataset.liveChannel=el.tagName==='WA-REASONING'?'reasoning':'delta';
      }
  }
}
async function paneMessages(pane) {
  // More than the node's default page of eight rows, so a child's transcript is the conversation and
  // not just its tail. The node still bounds the page - by bytes, by its own budget - and answers with
  // an address for a row too large to send; the rows are then drawn by the window's own renderer.
  const page=await panePage(pane,{});
  let rows=page.has_more_before ? await collectSessionHistory(args=>panePage(pane,args)) : (page.messages || []);
  for(let older=0; older<3 && rows[0]?.role==='tool'; older++) {
    const first=Number(rows[0].seq);
    if(!Number.isFinite(first) || first<=1) break;
    const before=await panePage(pane,{before_seq:first});
    const earlier=(before.messages || []).filter(row=>Number(row.seq)<first);
    if(!earlier.length) break;
    rows=earlier.concat(rows);
  }
  rows=await Promise.all(rows.map(row=>row.omitted&&row.id&&row.evidence ? exactSessionRow(row,options=>panePage(pane,options)) : row));
  if(rows.some(row=>row.session_id && row.session_id!==pane.task.session_id))throw Error('native_session_identity_mismatch');
  return {rows,task:page.task,mode:page.session?.mode};
}
async function exactSessionRow(reference,readPage) {
  let offset=1,version=null,text='',bytes=null;
  for(;;) {
    const page=await readPage({message_id:reference.id,byte_offset:offset,...(version?{message_version:version}:{})});
    if(page.encoding!=='exact_message_json' || page.message_id!==reference.id || !page.message_version ||
      (version&&page.message_version!==version))throw Error('exact_message_identity_mismatch');
    version=page.message_version;
    if(bytes!==null&&bytes!==page.bytes)throw Error('exact_message_size_changed');
    bytes=page.bytes;text+=page.content;
    if(!Number.isSafeInteger(page.next_offset)||page.next_offset<=offset)throw Error('exact_message_cursor_did_not_advance');
    offset=page.next_offset;
    if(page.eof)break;
  }
  if(new TextEncoder().encode(text).length!==bytes || offset!==bytes+1)throw Error('exact_message_bytes_incomplete');
  const row=JSON.parse(text);
  if(row.id!==reference.id || row.seq!==reference.seq)throw Error('exact_message_identity_mismatch');
  return row;
}
async function refreshAgentPane(pane) {
  if(!pane.task.session_id) { pane.notice.setNotice('journal',pane.task.error || 'Waiting for placement…'); return; }
  const target=pane.task.session_id,node=activeNode,attempt=pane.task.subagent_id,nativeAttempt=pane.task.attempt_id,credential=session;
  const viewing=()=>pane.isConnected && pane.task.session_id===target && pane.task.subagent_id===attempt && pane.task.attempt_id===nativeAttempt && activeNode===node && credential===session;
  try {
    const result=await paneMessages(pane);
    if(!viewing())return;
    let attached=null;
    let journalError='';
    try {
      const native=pane.task.transport==='native' ? pane.task : await orchestratorRequest({action:'status',id:attempt}).catch(error=>{
        if(/unknown_subagent/.test(error.message))return {};
        throw error;
      });
      if(!viewing())return;
      if(native.transport==='native'&&native.session_id===target)attached=await attachNativeJournal(native,async()=>(await paneMessages(pane)).rows,viewing);
      else attached=await attachSessionJournal(pane.task.session_id,async()=> (await paneMessages(pane)).rows);
    }catch(error){journalError='Live journal unavailable: '+error.message;}
    if(!viewing())return;
    if(!attached && pane.task.transport==='native' && journalError) {
      const terminal={...pane.task,...result.task};
      if(nativeJournalUnavailable({message:journalError.replace('Live journal unavailable: ','')}) && terminal.settled) {
        retainNativeTerminal(pane.transcript,pane.task,result.rows,true,terminal);
        pane.task=terminal;
        pane.notice.setNotice('journal',journalError+'; showing stored terminal messages. Previously seen output retained; raw history gap remains.');
        return;
      }else if(pane.liveJournalAttached || !nativeJournalUnavailable({message:journalError.replace('Live journal unavailable: ','')})) {
        pane.notice.setNotice('journal',journalError);
        return;
      }
    }
    if(!attached && pane.liveJournalAttached && pane.painted && journalError) {
      pane.notice.setNotice('journal',journalError);
      return;
    }
    if(attached){
      if(attached.identity && retainNativeTerminal(pane.transcript,pane.task,attached.rows)) {
        pane.notice.setNotice('journal','Native journal restored; stored messages and previously seen output retained.');
        return;
      }
      pane.liveJournalAttached=!!(attached.identity||attached.runKey);
      pane.toggleAttribute('journal-attached',pane.liveJournalAttached);
      result.rows=attached.rows;result.events=attached.events;result.raw=attached.raw;result.identity=attached.identity;
      if(/^(completed|cancelled|failed)$/.test(attached.state))pane.task={...pane.task,state:attached.state,settled:true};
    }
    if(!pane.isConnected || pane.task.session_id!==target || pane.task.subagent_id!==attempt || activeNode!==node)return;
    // A placed task's control address is logical; a session echo may name its native attempt.
    if(result.task)pane.task={...pane.task,...result.task,subagent_id:attempt};
    const rows=result.rows;
    const contextSnapshots=rows.flatMap(row=>row.trace||[]).filter(span=>span.kind==='run_counts'&&span.context);
    const measured=contextSnapshots.filter(span=>span.context.estimated===false).at(-1)?.context;
    const latest=contextSnapshots.at(-1)?.context;
    if(latest) pane.task={...pane.task,context_readout:contextReadout(measured&&(!latest.model||measured.model===latest.model)?{...measured,capacity:latest.capacity}:latest)};
    // A repaint throws away the transcript's scroll position and its folded topics, so a poll that
    // found the same rows, the same state and the same in-flight call leaves the pane it found alone.
    const painted=JSON.stringify([rows,result.events,result.mode,pane.task.state,pane.task.settled,
      pane.task.preview?.tool?.call_id]);
    if(painted!==pane.painted) {
      pane.painted=painted;
      // Preserve the reader's place while the shared ledger renderer appends/repaints.
      const position=transcriptPlace(pane.transcript);
      paintChildTranscript(pane.transcript,rows,{state:childRunState(pane.task),
        task:pane.task,mode:result.mode,stateAt:pane.task.settled_at,active:!pane.task.settled,liveTool:pane.task.preview?.tool,events:result.events,raw:result.raw,identity:result.identity});
      restoreTranscriptPlace(pane.transcript,position);
      if(result.identity)rememberNativeRows(pane.transcript,pane.task,rows,result.raw);
    }
    // What is left for the pane's own notice is what the shared transcript cannot say: a failure the
    // child reported, a page size this node refused, or nothing. `Ready for your next message.` used to
    // sit here, restating the `completed`/duration footer the run already draws in its own bubble.
    pane.notice.setNotice('journal',[panePageNote,journalError,pane.task.error].filter(Boolean).join(' '));
    if(panePageNote)pane.notice.title=panePageNoteDetail;
  } catch(error) { if(viewing())pane.notice.setNotice('journal','Conversation unavailable: '+error.message); }
}
function mountOrchestrator() {
  rememberNode(''); // This node owns the dispatcher; each task carries its destination.
  orchestratorPanel=document.createElement('wa-orchestrator');
  document.body.append(orchestratorPanel);
  if(native?.maximize)native.maximize();
  orchestratorPanel.addEventListener('input',saveOrchestratorLayout);
  orchestratorPanel.addEventListener('orchestrator-action',async event=>{
    const {action}=event.detail;
    if(action==='close') { saveOrchestratorLayout(); if(native?.closeView)native.closeView();else window.close();return; }
    if(action==='layout') { if(!orchestratorPanel.restoring)saveOrchestratorLayout(); for(const pane of orchestratorPanel.allPanes())refreshAgentPane(pane);return; }
    try {
      if(action==='save-placement') {
        await orchestratorRequest({action:'placement',policy:orchestratorPanel.policy});
        orchestratorPanel.message='Node order and limits saved.';
      } else if(action==='refresh') { clearTimeout(orchestratorTimer);await refreshOrchestrator(); }
    } catch(error) { orchestratorPanel.message=error.message; }
  });
  orchestratorPanel.addEventListener('agent-action',async event=>{
    const {action,pane,text,key}=event.detail;
    if(!['message','steer','cancel'].includes(action))return;
    const button=pane.querySelector(action==='message' ? 'button[type="submit"]' : '[data-action="'+action+'"]');
    if(button)button.disabled=true;
    try {
      const receipt=await orchestratorRequest({action,id:pane.task.subagent_id,text,idempotency_key:key});
      if(action==='message' || action==='steer') {
        if(pane.input.value===text)pane.clearDraft();pane.submission=null;
        if(action==='message')pane.task={...receipt,execution_node:pane.task.execution_node};
        saveOrchestratorLayout();
      }
      pane.notice.setNotice('submission',action==='steer' ? 'Steering '+receipt.state+'; in-flight effects are not undone.' : action==='message' ? 'Message accepted in this session.' : 'Cancellation requested.');
    } catch(error) { pane.notice.setNotice('submission',error.message); }
    finally { if(button)button.disabled=false; }
  });
  document.addEventListener('keydown',event=>{
    // Escape leaves the orchestrator window. A promoted conversation is its own window: it closes the
    // way a window closes (its own control), not with this key (DESIGN.md §3).
    if(event.key==='Escape') orchestratorPanel.querySelector('[data-action="close"]').click();
  });
  refreshOrchestrator();
}

function controlViewName(name) {
  return "control:" + (name || "this-node");
}

// In a view window, render that one component and nothing else. The section is moved out of the
// panel, because this window is not the chat: there is no conversation here to keep.
function applyViewMode() {
  const wanted = viewMode();
  if (!wanted) return false;
  const parts = wanted.split(":");
  const kind = parts[0];
  // The inspector window is the chat *itself* - the surface being inspected is the whole one - so nothing
  // is unmounted or stripped here, and the menu it keeps is the browser's. What it does need said is the
  // mode: a fresh window profile boots compact, and compact hides the panel, which would leave the
  // inspector pointed at an empty page.
  if (kind === INSPECT_VIEW) { applyMode("expanded"); return true; }
  document.body.classList.add("view-only");
  const target = parts[1] && parts[1] !== "this-node" ? parts.slice(1).join(":") : "";
  if (kind === "orchestrator") { mountOrchestrator(); return true; }
  if (kind === "control") {
    if (target) rememberNode(target);
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
  if (parts[0] === "orchestrator") openOrchestrator();
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
  controlNode = name || "client";
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
  const x = controlScreen.x + Math.round(((event.clientX - rect.left) / rect.width) * controlScreen.w);
  const y = controlScreen.y + Math.round(((event.clientY - rect.top) / rect.height) * controlScreen.h);
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
    // Selected configuration and tool schemas; no transcript or per-call settings.
    const preview = await (await apiFetch("model-configuration-preview", { headers: apiHeaders() })).json();
    if (preview.request) {
      const details = document.createElement("details");
      details.className = "request-preview";
      const summary = document.createElement("summary");
      summary.textContent = `selected configuration + tools · ${preview.tool_count} tools (not a model request)`;
      const pre = document.createElement("pre");
      pre.textContent = JSON.stringify(preview.request, null, 2);
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
// The last /health read, so a row can say it is running without one request per row, and the running
// set from that read so a poll repaints only when *which* sessions are live changes. Repainting on
// every poll would pull the cursor out of the search box while someone is typing in it.
let sessionHealth = null;
let sessionRunningKey = null;
let sessionLoaded = false;

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

// Which conversations the node is working on right now. /health carries an active owner per
// conversation (`runs`), the conversation each node-thread holds, and the run in `current` - any of the
// three means the thread is live, and reading it needs no node-thread of its own.
function runningSessions(health) {
  const ids = new Set();
  for (const run of health?.runs || []) if (run.conversation && activeRun(health, run.conversation)) ids.add(run.conversation);
  for (const nodeThread of health?.node_threads || []) if (sessionRunEntry(nodeThread)) ids.add(nodeThread.session);
  if (sessionRunEntry(health?.current)) ids.add(health.current.session);
  return ids;
}

// Fold one /health read into the already-rendered list without rebuilding it, so a session turns
// live the moment a run starts and turns back when it ends.
function applySessionHealth(health) {
  sessionHealth = health;
  if (!sessionLoaded) return;
  const key = Array.from(runningSessions(health)).sort().join(",");
  if (key === sessionRunningKey) return;
  sessionRunningKey = key;
  renderSessions();
}

// Continue a thread the node left unfinished.
//
// The node records what was lost and prints the command; it does not act on its own, because a
// repair nobody asked for destroys the evidence of the crash. That leaves a person to notice a
// badge and type a command, which is not recovery - this is the same thing as one click, sent to
// the node so the run runs where the session lives and the window can watch it.
function resumeSession(id, expectedSeq) {
  if (!id) return;
  rememberSession(id);
  return send("continue where you stopped", {
    session: id, ...(expectedSeq === undefined ? {} : { resumeSeq: expectedSeq }),
  });
}

function renderSessions() {
  const shown = sessionList.filter((session) => sessionMatches(session, sessionQuery));
  const running = runningSessions(sessionHealth);
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
  // The route already orders by last use; sorting here too keeps that true if a cached list is ever
  // merged with live state, and makes "the last used is at the top" a property of the view rather
  // than a promise about the node.
  const ordered = shown.slice().sort((a, b) =>
    (Number(b.updated_at) || Number(b.started_at) || 0) - (Number(a.updated_at) || Number(a.started_at) || 0));
  for (const session of ordered) {
    const live = running.has(session.id);
    const row = document.createElement("div");
    row.className = "session-row" + (live ? " running" : "");
    row.dataset.session = session.id;
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
    if (live) {
      // A run in flight is not an unfinished turn: its last recorded message is the prompt it is
      // answering, so "unfinished" would be true of the ledger and false of the node. The badge is
      // derived from /health, not from the ledger, for exactly that reason.
      const badge = document.createElement("span");
      badge.className = "session-state running";
      badge.innerHTML = '<span class="spinner" aria-hidden="true"></span>running';
      badge.title = "a run is in progress on this node";
      row.append(badge);
    } else if (session.state && session.state !== "answered" && session.state !== "empty") {
      // Only when there is something to recover: a badge on every row would be noise, and "answered"
      // is the case that needs no attention. The reason is the API's own words, so the UI cannot
      // invent a different story.
      const badge = document.createElement("span");
      badge.className = "session-state " + session.state;
      badge.textContent = session.state;
      badge.title = session.state_detail || session.state;
      row.append(badge);
    }
    row.append(nodeButton("open", () => openSession(session.id)));
    row.append(nodeButton("inspect", () => openSessionById(session.id)));
    // A child session names the thread that spawned it; without this it is an orphan in the list.
    if (session.parent_session_id) {
      row.append(nodeButton("parent", () => openSession(session.parent_session_id)));
    }
    if (session.fork_parent_id) row.append(nodeButton('fork source',()=>openSession(session.fork_parent_id)));
    if (session.workspace_required) {
      const workspace=document.createElement('span'); workspace.className='session-meta';
      workspace.textContent='workspace: '+(session.workspace_state || 'unknown');
      workspace.title=session.worktree || session.workspace_error || ''; row.append(workspace);
      if(['allocated','releasing','release_unknown'].includes(session.workspace_state)) {
        const release=nodeButton('Release clean workspace',async()=>{
          release.disabled=true;
          try {
            await taskRequest('session/worktree',{session_id:session.id,action:'release'});
            await refreshSessions();
          } catch(error) { workspace.textContent='Workspace release refused: '+error.message; }
          finally { release.disabled=false; }
        });
        release.title='Remove only a verified clean, inactive, merged worktree. The branch and transcript remain.';
        row.append(release);
      }
    }
    // Only where there is something to recover, and named as what it does: the node's own words for
    // this are "continue where you stopped". A running turn has nothing to recover yet.
    if (!live && session.state === "unfinished") {
      row.append(nodeButton("continue", () => resumeSession(session.id)));
    }
    sessionsBox.append(row);
  }
}

async function refreshSessions() {
  try {
    // Sessions and health together: the list says what this node has been doing, and health says
    // which of those threads is being worked on right now. /health needs no node-thread, so this stays
    // answerable while a run holds the run node-thread.
    const [listResponse, health] = await Promise.all([
      apiFetch("sessions", { headers: apiHeaders() }),
      nodeHealth(1000),
    ]);
    const payload = await listResponse.json();
    sessionList = payload.sessions || [];
    sessionLoaded = true;
    sessionHealth = health;
    sessionRunningKey = Array.from(runningSessions(health)).sort().join(",");
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
  const create = nodeButton("new session", newThread);
  create.className = "session-new";
  row.append(input, create);
  return row;
}

async function openSession(id) {
  // Opening a thread is also choosing it: from here on this window is *in* that conversation, so a
  // later respawn comes back to it instead of guessing.
  if (!id) return false;
  if (id === chatSession) {
    setEngine(false);
    return true;
  }
  detachConversationView();
  rememberBlankSession("");
  rememberSession(id);
  repaintMessages([]);
  setStatus("opening session…");
  setEngine(false);
  const opened = await restoreSession(id);
  if (opened && chatSession === id) {
    clearStatus();
    refreshMeta();
  }
  return opened;
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
    const node = activeNode, epoch = conversationEpoch;
    const response = await apiFetch("session/mode", {
      method: "POST",
      headers: apiHeaders({ "Content-Type": "application/json" }),
      body: JSON.stringify({ session_id: id, mode: next }),
    });
    const result = await response.json();
    if (activeNode !== node || conversationEpoch !== epoch) return;
    if (!response.ok || result.error) { setStatus('Debug mode not changed: ' + (result.error || response.status)); return; }
    if (chatSession === id) setTranscriptDebug(messages, result.mode);
    if (activeNode === node) openSessionById(id);
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
    if (message.role !== 'summary' && Number.isInteger(Number(message.seq))) {
      const fork=nodeButton('Fork here',()=>forkSessionAt(id,Number(message.seq),fork));
      fork.title='Continue from this message in a separate conversation and clean worktree. File and external effects are not rolled back.';
      row.append(fork);
    }
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

// Topics that still need the run node-thread wait for the run to finish. Read-only topics such as nodes,
// sessions, and skills use the host's read node-threads and can be inspected during a run.
const pendingTopics = new Set();

const runWorkerTopics = new Set(['spells-box', 'tools-box']);

let tasksPolling = false;
async function taskRequest(route, body) {
  const response = await apiFetch(route, {method:body ? 'POST' : 'GET',headers:apiHeaders({'Content-Type':'application/json'}),...(body ? {body:JSON.stringify(body)} : {})});
  const value = await response.json();
  if (!response.ok || value.error) throw new Error(value.detail || value.error || `HTTP ${response.status}`);
  return value;
}
async function refreshTasks() {
  const panel = document.querySelector('#tasks-box wa-tasks');
  if (!panel || tasksPolling) return;
  if (activeNode) { panel.message='Select this node to manage its tasks. Remote task placement is not available here.'; return; }
  const account=session;
  tasksPolling=true;
  try {
    const [list,children,profiles] = await Promise.all([
      taskRequest('sessions'),taskRequest('subagents',{action:'list'}),taskRequest('subagents',{action:'profiles'})]);
    const runs={};
    const sessions=list.sessions || [];
    for (let offset=0;offset<sessions.length;offset+=4) {
      await Promise.all(sessions.slice(offset,offset+4).map(async item=>{
        const result=await taskRequest('runs',{action:'status',thread:item.id}); runs[item.id]=result.runs || [];
      }));
    }
    if (account!==session || activeNode) return;
    panel.data={sessions,tasks:children.subagents || [],profiles:profiles.profiles || [],runs,current:chatSession};
    panel.message=(profiles.errors || []).length ? 'Some profiles could not load: '+JSON.stringify(profiles.errors) :
      'Tasks use the selected model and approved profile. Accepted tasks may still be waiting or running; inspect the result before treating work as complete.';
  } catch(error) { if(account===session) panel.message='Tasks unavailable: '+error.message; }
  finally { tasksPolling=false; }
}
document.getElementById('tasks-box').addEventListener('task-action',async event=>{
  const {action,control,...detail}=event.detail;
  const panel=event.target.closest('wa-tasks');
  if (activeNode) { panel.message='Select this node before controlling its tasks.'; return; }
  if(!['refresh','open'].includes(action)) panel.actionSerial=(panel.actionSerial || 0)+1;
  const serial=panel.actionSerial;
  const showEvidence=(value,cursor)=>{if(serial===panel.actionSerial)panel.showEvidence(value,cursor);};
  if(control) control.disabled=true;
  try {
    if(action==='refresh') await refreshTasks();
    else if(action==='open') await openSession(detail.session);
    else if(action==='start') {
      const receipt=await taskRequest('subagents',{action:'start',thread:detail.parent,profile:detail.profile,
        prompt:detail.prompt,idempotency_key:detail.key});
      showEvidence(receipt); panel.prompt.value=''; panel.submission=null;
      await refreshTasks();
    } else if(action==='result') showEvidence(await taskRequest('subagents',{action:'result',subagent_id:detail.id}));
    else if(action==='cancel') {
      showEvidence(await taskRequest('subagents',{action:'cancel',subagent_id:detail.id}));
      await refreshTasks();
    } else if(action==='inspect-run') {
      const [receipt,replay]=await Promise.all([
        taskRequest('runs',{action:'inspect',thread:detail.session,run_id:detail.runId}),
        taskRequest('run-events',{thread:detail.session,run_id:detail.runId,archive:true})]);
      if(serial!==panel.actionSerial)return;
      panel.runEvidence={receipt,pages:[replay]};
      showEvidence(panel.runEvidence,replay.has_more ? {...detail,after:replay.next_seq} : null);
    } else if(action==='more-output') {
      const replay=await taskRequest('run-events',{thread:detail.session,run_id:detail.runId,after:detail.after,archive:true});
      if(serial!==panel.actionSerial)return;
      panel.runEvidence.pages.push(replay);
      showEvidence(panel.runEvidence,replay.has_more ? {...detail,after:replay.next_seq} : null);
    } else if(action==='cancel-run') {
      showEvidence(await taskRequest('runs',{action:'cancel',thread:detail.session,run_id:detail.runId}));
      await refreshTasks();
    }
  } catch(error) { if(serial===panel.actionSerial)panel.message='Task action did not complete: '+error.message+'. Inspect the task list before retrying.'; }
  finally { if(action==='start') panel.finishSubmission(); else if(control)control.disabled=false; }
});
setInterval(()=>{if(uiVisible() && !document.getElementById('tasks-box').hidden) void refreshTasks();},3000);

async function forkSessionAt(id, seq, control) {
  control.disabled=true;
  try {
    const result=await taskRequest('session/fork',{session_id:id,before_seq:seq});
    if (!result.ok || !result.session_id) throw new Error('fork receipt is incomplete');
    await refreshSessions();
    await openSession(result.session_id);
  } catch(error) { setStatus('Fork failed at message '+seq+': '+error.message); }
  finally { control.disabled=false; }
}

let hookInventoryEpoch = 0;
function invalidateHookInventory() {
  hookInventoryEpoch++;
  const panel = document.querySelector('#hooks-box wa-hook-events');
  if (panel) panel.message = 'Hook inventory not loaded for this node. Expand hooks / events to read its catalogue.';
}
async function refreshHooks() {
  const box = document.getElementById('hooks-box');
  let panel = box.querySelector('wa-hook-events');
  if (!panel) { panel = document.createElement('wa-hook-events'); box.replaceChildren(panel); }
  const epoch = ++hookInventoryEpoch, node = activeNode, thread = chatSession, account = session, conversation = conversationEpoch;
  const current = () => epoch === hookInventoryEpoch && node === activeNode && thread === chatSession && account === session && conversation === conversationEpoch;
  panel.message = 'Loading hook/event inventory…';
  try {
    const response = await apiFetch('jobs', {method:'POST', headers:apiHeaders({'Content-Type':'application/json'}), body:JSON.stringify({action:'hooks'})});
    if (!current()) return;
    const payload = await response.json();
    if (!current()) return;
    if (!response.ok || payload.error) throw new Error(payload.detail || payload.error || `HTTP ${response.status}`);
    panel.catalogue = payload;
  } catch (error) { if (current()) panel.message = 'Hook inventory unavailable: ' + String(error.message || error); }
}

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
// A control is the same route with the numbers, and the same rule as the toggle: the store's answer is
// what gets displayed. A refusal is the store's own words rather than a smoothed-over old value, because
// a number the operator believes they set and did not is worse than a sentence they have to read.
document.getElementById('jobs-box').addEventListener('job-controls', async (event) => {
  const {id, control, controls} = event.detail;
  try {
    const response = await apiFetch('jobs', {method: 'POST', headers: {...apiHeaders(), 'Content-Type': 'application/json'}, body: JSON.stringify({id, action: 'controls', controls})});
    const payload = await response.json();
    if (!response.ok || payload.error) throw new Error(payload.error || `HTTP ${response.status}`);
    await refreshJobs();
  } catch (error) {
    control.disabled = false;
    let failure = document.getElementById('jobs-box').querySelector('.job-error');
    if (!failure) { failure = document.createElement('p'); failure.className = 'job-error'; document.getElementById('jobs-box').append(failure); }
    failure.textContent = `Controls were not changed: ${error}`;
  }
});
function loadTopic(id) {
  const box = document.getElementById(id);
  if (busy && runWorkerTopics.has(id)) {
    // These topics still use a route on the run node-thread. Do not issue a request that would time out;
    // keep them queued and load them as soon as that node-thread is free.
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
  else if (id === "hooks-box") refreshHooks();
  else if (id === "tasks-box") refreshTasks();
  else if (id === "notify-box") refreshNotifySupport();
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

// ---- engine: the notification bell (device-local, not a node setting) ----------------
// The card is the only switch for the OS notification, and its state comes from this window's own
// storage. It also carries the on-demand path: "send a test notification" is how the shell's identity
// and the raise path are checked without waiting for a real settlement (`wa-window.exe --notify-test`,
// printed in the card, does the same with no page involved at all).
notifyBellEl = document.getElementById("notify-bell");
notifyStateNoteEl = document.getElementById("notify-state");
notifyDetailEl = document.getElementById("notify-detail");
notifyResultEl = document.getElementById("notify-result");
notifyTestEl = document.getElementById("notify-test");
notifyBellEl.addEventListener("change", () => {
  setNotifyPreference(notifyBellEl.checked);
  paintNotifyResult(null);
  paintNotifyState();
});
notifyTestEl.addEventListener("click", async () => {
  notifyTestEl.disabled = true;
  notifyResultEl.dataset.delivered = "pending";
  notifyResultEl.textContent = "asking the shell…";
  paintNotifyResult(await raiseNotification({ title: "wasm-agent", body: "test notification from the wasm-agent window", diagnostic: true }));
  paintNotifyState();
});
paintNotifyState();

function setEngine(open) {
  document.body.classList.toggle("engine", open);
  engineView.hidden = !open;
  engineBtn.classList.toggle("active", open);
  if (open) {
    // The session list is the node's front door: opening the engine lists what this node has been
    // doing whether or not the topic is expanded, and whether or not a run is in flight. It runs
    // first because the label below is decoration - a missing `tools` must not blank the list.
    refreshSessions();
    engineSub.textContent = `${me.role} · ${(me.tools || []).length} tools`;
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
    if (document.body.classList.contains("term")) { event.preventDefault(); setTerm(false); input.focus(); return; }
    if (document.body.classList.contains("control")) { event.preventDefault(); closeControl(); return; }
  }
  // Ctrl+E and Ctrl+D are line editing keys inside a text field (end of line, delete forward on macOS and
  // in readline-style fields); the panel shortcuts apply only outside one.
  const editing = event.target && (event.target.isContentEditable || /^(INPUT|TEXTAREA)$/.test(event.target.tagName || ""));
  if (event.ctrlKey && (event.key === "`" || event.code === "Backquote")) {
    event.preventDefault();
    setTerm(!document.body.classList.contains("term"));
  } else if (editing && event.ctrlKey && /^[eEdD]$/.test(event.key)) {
    // leave the key to the field
  } else if (event.ctrlKey && (event.key === "e" || event.key === "E")) {
    event.preventDefault();
    setEngine(!document.body.classList.contains("engine"));
  } else if (event.ctrlKey && (event.key === "d" || event.key === "D")) {
    // Ctrl+D would otherwise be the browser's bookmark gesture.
    event.preventDefault();
    openOrchestrator();
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
  // A window with no shell keeps the browser's own menu, and so does the *inspector* window: the shell
  // enables Chromium's default menu for every view, and in the inspector that menu IS the feature -
  // `Inspect element` opens the real DevTools. Every other window is this app's own surface and draws
  // this app's menu, exactly as it always has, the other views included (DESIGN.md §3).
  if (!native || viewMode() === INSPECT_VIEW) return;
  event.preventDefault();
  const items = [
    { label: "Collapse to avatar", action: () => { applyMode("compact"); native.compact(); } },
    { label: "Reload window", action: () => reload() },
  ];
  // The inspector is asked for from the window that owns the conversation: `openInspectWindow` refuses
  // from inside a view (a window opening a window is how you get two), so the item is offered where it
  // does something rather than offered everywhere and refused.
  if (!viewMode()) {
    // Immediately after the reload: both are "open this page again", and the inspector is the one that
    // opens it in a window the browser itself owns - with Chrome's own element inspection on it.
    items.push({ label: "inspect", action: () => openInspectWindow() });
  }
  items.push({ separator: true }, { label: "Close wasm-agent", danger: true, action: () => native.quit() });
  contextMenu.items = items;
  contextMenu.openAt(event.clientX, event.clientY);
});

// The draft and transcript do not depend on the Markdown renderer. Waiting for
// render.wasm before booting chat made a stalled asset leave an otherwise healthy
// page on "connecting" indefinitely, even when /version was also unavailable.
setupVoice();
restoreDraft();
input.addEventListener("input", saveDraft);
// A view page normally drops the chat and renders the one component it is for. The inspector is the
// exception: it is a view whose content *is* the chat, so it boots like the main window (transcript,
// settings, watchers) and only differs in the menu its window keeps.
const inspectWindow = viewMode() === INSPECT_VIEW;
const openingView = !!viewMode() && !inspectWindow;
if (!openingView) {
  sync("boot");
  setTimeout(openFromQuery, 400);
}
// Views can wait for the renderer. Chat first draws readable fallback text;
// later transcript updates use Markdown once the renderer is ready.
window.rendererLoaded = loadRenderer().then(() => {
  if (openingView || inspectWindow) applyViewMode();
});
window.addEventListener("online", () => sync("online"));
watch();
watchTurn();
// Restore clocks and reconcile immediately on return, not after a hidden-tab timer.
let uiResumeQueued=false;
function resumeUi() {
  document.body.classList.toggle('ui-resting',!uiVisible());
  if(!uiVisible() || uiResumeQueued)return;
  uiResumeQueued=true;
  queueMicrotask(()=>{
    uiResumeQueued=false;
    if(!uiVisible())return;
    updateRunElapsed();trace?.setAge();
    metadataRefreshedAt=0;
    void ensureMeta();void watchTurn();
  });
}
document.addEventListener('visibilitychange',resumeUi);
window.addEventListener('focus',resumeUi);
if (!native) input.focus();
