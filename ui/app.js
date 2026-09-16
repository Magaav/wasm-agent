// wasm-agent web UI: streaming chat, tool activity, hot reload, WASM renderer.
const messages = document.getElementById("messages");
const meta = document.getElementById("meta");
const form = document.getElementById("composer");
const input = document.getElementById("input");
const sendButton = document.getElementById("send");

let renderer = null; // WASM renderer module
let version = null; // UI version for hot reload
let busy = false;
let statusLine = null;
let streamBody = null;
let streamText = "";

async function loadRenderer() {
  try {
    const response = await fetch("render.wasm");
    const { instance } = await WebAssembly.instantiateStreaming(response, {});
    renderer = instance.exports;
  } catch (error) {
    renderer = null; // fall back to escaped text
  }
}

function escapeHtml(text) {
  return String(text).replace(/[&<>"']/g, (c) => (
    { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

// Render markdown-lite in WASM when available (safe HTML), else escaped text.
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

function atBottom() {
  return messages.scrollHeight - messages.scrollTop - messages.clientHeight < 80;
}

function add(role, text, asHtml = false) {
  document.getElementById("empty")?.remove();
  const stick = atBottom();
  const element = document.createElement("div");
  element.className = "msg " + role;
  const who = document.createElement("div");
  who.className = "who";
  who.textContent = role === "user" ? "you" : "wasm-agent";
  const body = document.createElement("div");
  if (asHtml) body.innerHTML = text; else body.textContent = text;
  element.append(who, body);
  messages.append(element);
  if (stick) messages.scrollTop = messages.scrollHeight;
  return body;
}

function setStatus(text) {
  document.getElementById("empty")?.remove();
  const stick = atBottom();
  if (!statusLine) {
    statusLine = document.createElement("div");
    statusLine.className = "status";
    messages.append(statusLine);
  }
  statusLine.innerHTML = `<span class="spinner"></span>${escapeHtml(text)}`;
  if (stick) messages.scrollTop = messages.scrollHeight;
}

function clearStatus() {
  statusLine?.remove();
  statusLine = null;
}

function addTool(name, args) {
  document.getElementById("empty")?.remove();
  const stick = atBottom();
  const chip = document.createElement("div");
  chip.className = "tool";
  const title = document.createElement("div");
  title.className = "tool-name";
  title.textContent = "tool · " + name;
  const detail = document.createElement("div");
  detail.className = "tool-detail";
  detail.textContent = JSON.stringify(args || {});
  chip.append(title, detail);
  messages.append(chip);
  if (stick) messages.scrollTop = messages.scrollHeight;
  return chip;
}

function typeOut(body, text) {
  let index = 0;
  const step = Math.max(2, Math.ceil(text.length / 180));
  const timer = setInterval(() => {
    index = Math.min(text.length, index + step);
    body.textContent = text.slice(0, index);
    messages.scrollTop = messages.scrollHeight;
    if (index >= text.length) {
      clearInterval(timer);
      body.innerHTML = renderMarkdown(text);
    }
  }, 14);
}

function handleEvent(event) {
  if (event.type === "status") {
    setStatus("wasm-agent is " + (event.text || "working") + "…");
  } else if (event.type === "tool") {
    addTool(event.name, event.arguments);
  } else if (event.type === "tool_result") {
    const chip = messages.lastElementChild;
    if (chip && chip.classList.contains("tool")) {
      const ok = !(event.result && event.result.error);
      chip.classList.add(ok ? "ok" : "err");
      const detail = chip.querySelector(".tool-detail");
      if (detail) detail.textContent = JSON.stringify(event.result || {}).slice(0, 400);
    }
  } else if (event.type === "delta") {
    // Token-by-token from the model: append to the live assistant bubble.
    clearStatus();
    if (!streamBody) streamBody = add("assistant", "");
    streamText += event.text || "";
    streamBody.textContent = streamText;
    messages.scrollTop = messages.scrollHeight;
  } else if (event.type === "reply") {
    clearStatus();
    const finalText = event.text || streamText;
    if (streamBody) {
      streamBody.innerHTML = renderMarkdown(finalText);
      streamBody = null;
      streamText = "";
    } else {
      typeOut(add("assistant", ""), finalText);
    }
  } else if (event.type === "error") {
    clearStatus();
    add("assistant", "error: " + (event.error || "unknown"));
  } else if (event.type === "done") {
    clearStatus();
  }
}

async function send(text) {
  if (busy) return;
  busy = true;
  sendButton.disabled = true;
  streamBody = null;
  streamText = "";
  add("user", text);
  setStatus("wasm-agent is thinking…");
  try {
    const response = await fetch("chat", {
      method: "POST",
      headers: { "Content-Type": "text/plain; charset=utf-8", "Accept": "text/event-stream" },
      body: text,
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
    add("assistant", "error: " + error);
  } finally {
    busy = false;
    sendButton.disabled = false;
    refreshMeta();
    input.focus();
  }
}

form.addEventListener("submit", (event) => {
  event.preventDefault();
  const text = input.value.trim();
  if (!text) return;
  input.value = "";
  input.style.height = "auto";
  send(text);
});

input.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    form.requestSubmit();
  }
});
input.addEventListener("input", () => {
  input.style.height = "auto";
  input.style.height = Math.min(input.scrollHeight, 180) + "px";
});
messages.addEventListener("click", (event) => {
  const prompt = event.target?.dataset?.prompt;
  if (prompt) send(prompt);
});

async function refreshMeta() {
  try {
    const response = await fetch("models");
    const payload = await response.json();
    const model = payload.configured ? payload.model : "local mode";
    const stats = payload.stats || {};
    meta.textContent = `${model} · ${stats.memories ?? 0} memories · ${stats.messages ?? 0} messages`;
  } catch (error) {
    meta.textContent = "offline";
  }
}

// Hot reload: reload the window whenever the UI files change on disk.
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
// When hosted in the frameless always-on-top shell, the page starts as a round
// avatar and expands into the translucent chat panel on click.
const native = window.wasmAgent || null;
const orb = document.getElementById("orb");
const collapse = document.getElementById("collapse");
const dragbar = document.getElementById("dragbar");

function applyMode(mode) {
  document.body.classList.toggle("compact", mode === "compact");
  document.body.classList.toggle("expanded", mode === "expanded");
}
applyMode(native ? "compact" : "expanded");

orb?.addEventListener("click", () => { applyMode("expanded"); native?.expand(); });
collapse?.addEventListener("click", () => { applyMode("compact"); native?.compact(); });

// Drag to move the frameless window (click still expands the orb).
let dragDown = null;
function wireDrag(element) {
  if (!element || !native) return;
  element.addEventListener("pointerdown", (event) => {
    if (event.target.closest("button, a, textarea, input")) return;
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

loadRenderer().then(refreshMeta);
watch();
if (!native) input.focus();
