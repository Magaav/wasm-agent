// wasm-agent web UI. Components live in components.js (see DESIGN.md).
const messages = document.getElementById("messages");
const meta = document.getElementById("meta");
const form = document.getElementById("composer");
const input = document.getElementById("input");
const sendButton = document.getElementById("send");
const statusBtn = document.getElementById("status-btn");
const chipModel = document.getElementById("chip-model");
const chipUsage = document.getElementById("chip-usage");
const balloon = document.getElementById("status-balloon");
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
const control = document.getElementById("control");
const controlTitle = document.getElementById("control-title");
const controlImg = document.getElementById("control-img");
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

function apiHeaders(extra) {
  const headers = Object.assign({}, extra || {});
  if (session) headers["X-WA-Session"] = session;
  return headers;
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
    renderer = null;
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

function atBottom() {
  return messages.scrollHeight - messages.scrollTop - messages.clientHeight < 80;
}

function add(role, text, asHtml = false) {
  document.getElementById("empty")?.remove();
  const stick = atBottom();
  const element = document.createElement("wa-message");
  element.setAttribute("role", role);
  messages.append(element);
  const body = element.body;
  if (asHtml) body.innerHTML = text; else body.textContent = text;
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
  const chip = document.createElement("wa-tool");
  chip.setAttribute("name", name);
  messages.append(chip);
  chip.detail.textContent = JSON.stringify(args || {});
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
    if (chip && chip.detail) {
      const ok = !(event.result && event.result.error);
      chip.classList.add(ok ? "ok" : "err");
      chip.detail.textContent = JSON.stringify(event.result || {}).slice(0, 400);
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
    if (balloon.open) { renderUsage(); renderModels(); }
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
      headers: apiHeaders({ "Content-Type": "text/plain; charset=utf-8", "Accept": "text/event-stream" }),
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

function activeProvider() {
  return (settings.providers || []).find((provider) => provider.id === settings.provider) || null;
}

function updateChip() {
  chipModel.textContent = settings.configured ? (settings.model || "model") : "local mode";
  statusBtn.classList.toggle("local", !settings.configured);
  const total = (settings.usage && settings.usage.total) || 0;
  chipUsage.textContent = total ? formatTokens(total) + " tok" : "";
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

// Context: tokens sent last turn vs the configured context budget.
function renderContext() {
  contextBox.replaceChildren();
  const usage = settings.usage || {};
  const taken = Number((usage.last && usage.last.prompt) || 0);
  const budget = Number(settings.context_limit) || 0;
  contextBox.append(grid([
    ["taken", formatTokens(taken)],
    ["budget", budget ? formatTokens(budget) : "—"],
  ]));
  if (budget) {
    const percent = Math.min(100, Math.round((taken / budget) * 100));
    contextBox.append(meter(percent), grid([["used", percent + "%"]]));
  }
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
  usageBox.append(grid([
    ["last turn (in/out)", `${formatTokens(last.prompt)} / ${formatTokens(last.completion)}`],
    ["last total", formatTokens(last.total)],
    ["session in", formatTokens(usage.prompt)],
    ["session out", formatTokens(usage.completion)],
    ["session total", formatTokens(usage.total)],
    ["turns", usage.turns || 0],
  ]));
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

// ---- status balloon (provider + model + usage) ---------------------------
statusBtn.addEventListener("click", () => {
  balloon.toggle();
  statusBtn.setAttribute("aria-expanded", String(balloon.open));
  if (balloon.open) {
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
    const response = await fetch("models", { headers: apiHeaders() });
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
    meta.textContent = `${label} · ${payload.model}`;
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
let controlScale = 1;

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

async function fetchFrame() {
  try {
    const payload = await (await fetch("frame", {
      method: "POST", headers: apiHeaders({ "Content-Type": "text/plain" }), body: "720",
    })).json();
    if (payload.error || !payload.image) return;
    controlScale = payload.scale || 1;
    controlImg.src = "data:image/bmp;base64," + payload.image;
  } catch (error) { /* ignore */ }
}

function openControl(name) {
  balloon.close();
  document.body.classList.add("control");
  control.hidden = false;
  controlTitle.textContent = "control · " + name;
  fetchFrame();
}

function closeControl() {
  document.body.classList.remove("control");
  control.hidden = true;
  controlLive.checked = false;
  if (controlTimer) { clearInterval(controlTimer); controlTimer = null; }
}

controlImg.addEventListener("click", (event) => {
  const rect = controlImg.getBoundingClientRect();
  const x = Math.round((event.clientX - rect.left) / controlScale);
  const y = Math.round((event.clientY - rect.top) / controlScale);
  clientAction({ action: "click", x, y });
});
controlKeys.addEventListener("submit", (event) => {
  event.preventDefault();
  const text = controlText.value;
  if (!text) return;
  controlText.value = "";
  clientAction({ action: "type", text });
});
controlRefresh.addEventListener("click", fetchFrame);
controlClose.addEventListener("click", closeControl);
controlLive.addEventListener("change", () => {
  if (controlTimer) { clearInterval(controlTimer); controlTimer = null; }
  if (controlLive.checked) controlTimer = setInterval(fetchFrame, 1500);
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
  } catch (error) {
    toolsBox.textContent = String(error);
  }
}

function loadTopic(id) {
  if (id === "nodes-box") refreshNodes();
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

loadRenderer().then(() => { setupVoice(); refreshMe(); refreshMeta(); });
watch();
if (!native) input.focus();
