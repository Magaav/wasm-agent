// wasm-agent web UI: streaming chat, tool activity, hot reload, WASM renderer.
const messages = document.getElementById("messages");
const meta = document.getElementById("meta");
const form = document.getElementById("composer");
const input = document.getElementById("input");
const sendButton = document.getElementById("send");
const statusBtn = document.getElementById("status-btn");
const chipModel = document.getElementById("chip-model");
const chipUsage = document.getElementById("chip-usage");
const modelPop = document.getElementById("model-pop");
const modelList = document.getElementById("model-list");
const usageBox = document.getElementById("usage-box");
const popBase = document.getElementById("pop-base");
const micButton = document.getElementById("mic");
const attachButton = document.getElementById("attach");
const fileInput = document.getElementById("file");
const attachmentsEl = document.getElementById("attachments");

let renderer = null;
let version = null;
let busy = false;
let statusLine = null;
let streamBody = null;
let streamText = "";
let controller = null; // AbortController for the active turn
let attachments = []; // { name, text }
let settings = { model: "", models: [], usage: {}, configured: false, base_url: "" };
let recognizing = false;
let recognition = null;
let voicePrefix = "";

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

// Some models leak their reasoning into the message; drop it.
function stripThinking(text) {
  let out = String(text)
    .replace(/[\s\S]*?<\/think>/gi, "")
    .replace(/<\/?think\b[^>]*>/gi, "");
  const open = out.search(/<think\b[^>]*>/i);
  if (open >= 0) out = out.slice(0, open);
  return out.replace(/^\s+/, "");
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
  body.style.whiteSpace = "pre-wrap";
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
      body.style.whiteSpace = "normal";
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
    clearStatus();
    if (!streamBody) streamBody = add("assistant", "");
    streamText += event.text || "";
    streamBody.textContent = stripThinking(streamText);
    messages.scrollTop = messages.scrollHeight;
  } else if (event.type === "reply") {
    clearStatus();
    const finalText = stripThinking(event.text || streamText);
    if (streamBody) {
      streamBody.innerHTML = renderMarkdown(finalText);
      streamBody.style.whiteSpace = "normal";
      streamBody = null;
      streamText = "";
    } else {
      typeOut(add("assistant", ""), finalText);
    }
  } else if (event.type === "usage") {
    settings.usage = event.total || settings.usage;
    if (event.model) settings.model = event.model;
    updateChip();
    if (!modelPop.hidden) renderUsage();
  } else if (event.type === "error") {
    clearStatus();
    add("assistant", "error: " + (event.error || "unknown"));
  } else if (event.type === "done") {
    clearStatus();
  }
}

function setBusy(value) {
  busy = value;
  sendButton.classList.toggle("busy", value);
  sendButton.title = value ? "Stop" : "Send";
  sendButton.setAttribute("aria-label", sendButton.title);
}

function composedText(text) {
  if (attachments.length === 0) return text;
  const files = attachments.map((file) => `[file: ${file.name}]\n${file.text}`);
  return files.join("\n\n") + (text ? "\n\n" + text : "");
}

async function send(text) {
  setBusy(true);
  controller = new AbortController();
  streamBody = null;
  streamText = "";
  const names = attachments.map((file) => file.name).join(", ");
  add("user", text + (names ? `\n\nattached: ${names}` : ""));
  const outgoing = composedText(text);
  attachments = [];
  renderAttachments();
  setStatus("wasm-agent is thinking…");
  try {
    const response = await fetch("chat", {
      method: "POST",
      headers: { "Content-Type": "text/plain; charset=utf-8", "Accept": "text/event-stream" },
      body: outgoing,
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

function updateChip() {
  chipModel.textContent = settings.configured ? (settings.model || "model") : "local mode";
  statusBtn.classList.toggle("local", !settings.configured);
  const total = (settings.usage && settings.usage.total) || 0;
  chipUsage.textContent = total ? formatTokens(total) + " tok" : "";
}

function renderModels() {
  modelList.replaceChildren();
  const models = settings.models && settings.models.length ? settings.models : [settings.model].filter(Boolean);
  for (const name of models) {
    const item = document.createElement("button");
    item.type = "button";
    item.className = "model-item" + (name === settings.model ? " active" : "");
    const label = document.createElement("span");
    label.textContent = name;
    item.append(label);
    if (name === settings.model) {
      const check = document.createElement("span");
      check.className = "check";
      check.textContent = "✓";
      item.append(check);
    }
    item.addEventListener("click", () => setModel(name));
    modelList.append(item);
  }
}

function renderUsage() {
  usageBox.replaceChildren();
  const usage = settings.usage || {};
  const rows = [
    ["prompt tokens", usage.prompt || 0],
    ["completion tokens", usage.completion || 0],
    ["total tokens", usage.total || 0],
    ["turns", usage.turns || 0],
  ];
  for (const [label, value] of rows) {
    const key = document.createElement("span");
    key.textContent = label;
    const val = document.createElement("b");
    val.textContent = String(value);
    usageBox.append(key, val);
  }
  if (settings.context_limit) {
    const used = usage.total || 0;
    const percent = Math.min(100, Math.round((used / settings.context_limit) * 100));
    const meter = document.createElement("div");
    meter.className = "meter";
    const fill = document.createElement("span");
    fill.style.width = percent + "%";
    meter.append(fill);
    usageBox.append(meter);
    const key = document.createElement("span");
    key.textContent = "context window";
    const val = document.createElement("b");
    val.textContent = `${formatTokens(used)} / ${formatTokens(settings.context_limit)}`;
    usageBox.append(key, val);
  }
  popBase.textContent = settings.base_url || "";
}

async function setModel(name) {
  try {
    const response = await fetch("model", {
      method: "POST",
      headers: { "Content-Type": "text/plain; charset=utf-8" },
      body: name,
    });
    const payload = await response.json();
    if (!payload.error) {
      settings = { ...settings, ...payload };
      updateChip();
      renderModels();
      renderUsage();
    }
  } catch (error) { /* keep the old model */ }
}

function renderAttachments() {
  attachmentsEl.replaceChildren();
  attachments.forEach((file, index) => {
    const chip = document.createElement("span");
    chip.className = "attachment";
    const name = document.createElement("b");
    name.textContent = file.name;
    const remove = document.createElement("button");
    remove.type = "button";
    remove.textContent = "×";
    remove.title = "Remove";
    remove.addEventListener("click", () => {
      attachments.splice(index, 1);
      renderAttachments();
    });
    chip.append(name, remove);
    attachmentsEl.append(chip);
  });
}

form.addEventListener("submit", (event) => {
  event.preventDefault();
  if (busy) {
    controller?.abort();
    return;
  }
  const text = input.value.trim();
  if (!text && attachments.length === 0) return;
  input.value = "";
  autosize();
  send(text);
});

input.addEventListener("keydown", (event) => {
  if (event.key === "Enter" && !event.shiftKey) {
    event.preventDefault();
    form.requestSubmit();
  }
});
function autosize() {
  input.style.height = "auto";
  input.style.height = Math.min(input.scrollHeight, 180) + "px";
}
input.addEventListener("input", autosize);
window.addEventListener("resize", () => requestAnimationFrame(autosize));

messages.addEventListener("click", (event) => {
  const prompt = event.target?.dataset?.prompt;
  if (prompt) send(prompt);
});

// ---- model / usage popover ----------------------------------------------
statusBtn.addEventListener("click", (event) => {
  event.stopPropagation();
  modelPop.hidden = !modelPop.hidden;
  if (!modelPop.hidden) {
    renderModels();
    renderUsage();
  }
});
document.addEventListener("click", (event) => {
  if (!modelPop.hidden && !modelPop.contains(event.target) && !statusBtn.contains(event.target)) {
    modelPop.hidden = true;
  }
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
attachButton.addEventListener("click", () => fileInput.click());
fileInput.addEventListener("change", async () => {
  for (const file of fileInput.files) {
    try {
      const text = await file.text();
      attachments.push({ name: file.name, text: text.slice(0, 20000) });
    } catch (error) {
      attachments.push({ name: file.name, text: "" });
    }
  }
  fileInput.value = "";
  renderAttachments();
});

async function refreshMeta() {
  try {
    const response = await fetch("models");
    const payload = await response.json();
    settings = { ...settings, ...payload };
    updateChip();
    if (!modelPop.hidden) {
      renderModels();
      renderUsage();
    }
    const stats = payload.stats || {};
    meta.textContent = `${payload.configured ? payload.model : "local mode"} · ${stats.memories ?? 0} memories · ${stats.messages ?? 0} messages`;
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
const native = window.wasmAgent || null;
const orb = document.getElementById("orb");
const collapse = document.getElementById("collapse");
const dragbar = document.getElementById("dragbar");

function applyMode(mode) {
  document.body.classList.toggle("compact", mode === "compact");
  document.body.classList.toggle("expanded", mode === "expanded");
}
applyMode(native ? "compact" : "expanded");

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

loadRenderer().then(() => { setupVoice(); refreshMeta(); });
watch();
if (!native) input.focus();
