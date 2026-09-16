// wasm-agent web UI: chat + hot reload, with a WASM message renderer.
const messages = document.getElementById("messages");
const meta = document.getElementById("meta");
const form = document.getElementById("composer");
const input = document.getElementById("input");
const sendButton = document.getElementById("send");

let renderer = null; // WASM renderer module
let version = null;  // UI version for hot reload
let busy = false;

async function loadRenderer() {
  try {
    const response = await fetch("render.wasm");
    const { instance } = await WebAssembly.instantiateStreaming(response, {});
    renderer = instance.exports;
  } catch (error) {
    renderer = null; // fall back to plain text rendering
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

function add(role, text, asHtml = false) {
  document.getElementById("empty")?.remove();
  const element = document.createElement("div");
  element.className = "msg " + role;
  const who = document.createElement("div");
  who.className = "who";
  who.textContent = role === "user" ? "you" : "wasm-agent";
  const body = document.createElement("div");
  if (asHtml) body.innerHTML = text; else body.textContent = text;
  element.append(who, body);
  messages.append(element);
  messages.scrollTop = messages.scrollHeight;
  return body;
}

async function send(text) {
  if (busy) return;
  busy = true;
  sendButton.disabled = true;
  add("user", text);
  const body = add("assistant", "…");
  body.classList.add("typing");
  try {
    const response = await fetch("chat", {
      method: "POST",
      headers: { "Content-Type": "text/plain; charset=utf-8" },
      body: text,
    });
    const payload = await response.json();
    body.classList.remove("typing");
    if (payload.error) body.textContent = "error: " + payload.error;
    else body.innerHTML = renderMarkdown(payload.reply || "(no reply)");
  } catch (error) {
    body.classList.remove("typing");
    body.textContent = "error: " + error;
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

loadRenderer().then(refreshMeta);
watch();
input.focus();
