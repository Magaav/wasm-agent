// The wa-vault page. It holds the admin token (in this app's own storage) and nothing else: every
// answer from the API is presence and timestamps, never a stored value.
"use strict";

const TOKEN_KEY = "wa-vault-admin-token";
const $ = (id) => document.getElementById(id);

// The launcher passes the token in the fragment, which never leaves the browser. It is moved into
// storage and wiped from the address bar at once, so it is not left in history.
(function adoptFragmentToken() {
  const match = location.hash.match(/(?:^#|&)token=([^&]+)/);
  if (!match) return;
  try { localStorage.setItem(TOKEN_KEY, decodeURIComponent(match[1])); } catch (error) { /* storage blocked */ }
  history.replaceState(null, "", location.pathname);
})();

function token() {
  try { return localStorage.getItem(TOKEN_KEY) || ""; } catch (error) { return ""; }
}

function showError(text) { $("err").textContent = text || ""; }

async function api(method, path, body) {
  const response = await fetch(path, {
    method,
    headers: { "X-Vault-Token": token(), "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
    cache: "no-store",
  });
  const payload = await response.json().catch(() => ({}));
  if (response.status === 401 && payload.error && payload.error.code === "vault_admin_token") {
    showAuth(true);
    throw new Error("admin token missing or wrong");
  }
  if (!response.ok) throw new Error((payload.error && payload.error.message) || ("HTTP " + response.status));
  return payload;
}

function showAuth(needed) {
  $("auth").hidden = !needed;
  $("openai-sub").hidden = needed;
  $("opencode-go").hidden = needed;
}

function when(ms) {
  return ms ? new Date(ms).toLocaleString() : "";
}

let polling = null;

function render(payload) {
  showAuth(false);
  const providers = payload.providers || {};
  const sub = providers["openai-sub"] || {};
  const ocg = providers["opencode-go"] || {};
  const login = payload.login || {};

  const subState = $("sub-state");
  subState.textContent = sub.configured ? (sub.enabled ? "logged in" : "logged in · disabled") : "not logged in";
  subState.className = "state " + (sub.configured && sub.enabled ? "ok" : sub.configured ? "" : "bad");
  $("sub-enabled").checked = sub.enabled !== false;
  $("sub-logout").disabled = !sub.configured;
  $("sub-test").disabled = !sub.configured;
  const notes = [];
  if (sub.account) notes.push("account " + sub.account);
  if (sub.set_at) notes.push("since " + when(sub.set_at));
  if (sub.last_error) notes.push("last error: " + sub.last_error);
  if (login.state === "error") notes.push("login failed: " + login.error);
  if (!$("sub-note").dataset.sticky) $("sub-note").textContent = notes.join(" · ");

  const pending = login.state === "pending";
  $("sub-flow").hidden = !pending;
  $("sub-login").disabled = pending;
  if (pending) {
    $("sub-code").textContent = login.user_code || "";
    $("sub-url").textContent = login.verification_url || "";
    $("sub-url").href = login.verification_url || "#";
  }
  if (pending && !polling) polling = setInterval(refresh, 3000);
  if (!pending && polling) { clearInterval(polling); polling = null; }

  const ocgState = $("ocg-state");
  ocgState.textContent = ocg.configured ? (ocg.enabled ? "key set" : "key set · disabled") : "no key";
  ocgState.className = "state " + (ocg.configured && ocg.enabled ? "ok" : ocg.configured ? "" : "bad");
  $("ocg-enabled").checked = ocg.enabled !== false;
  $("ocg-remove").disabled = !ocg.configured;
  $("ocg-test").disabled = !ocg.configured;
  if (!$("ocg-note").dataset.sticky) $("ocg-note").textContent = ocg.set_at ? "saved " + when(ocg.set_at) : "";
}

async function run(action) {
  showError("");
  try { render(await action()); } catch (error) { showError(error.message); }
}

const refresh = () => run(() => api("GET", "/api/status"));

$("auth-form").addEventListener("submit", (event) => {
  event.preventDefault();
  try { localStorage.setItem(TOKEN_KEY, $("auth-token").value.trim()); } catch (error) { /* storage blocked */ }
  $("auth-token").value = "";
  refresh();
});

$("sub-login").addEventListener("click", () => run(() => api("POST", "/api/openai-sub/login")));
$("sub-cancel").addEventListener("click", () => run(() => api("DELETE", "/api/openai-sub/login")));
$("sub-logout").addEventListener("click", () => {
  if (confirm("Remove the ChatGPT login from the vault?")) run(() => api("DELETE", "/api/openai-sub"));
});
$("sub-enabled").addEventListener("change", (event) =>
  run(() => api("POST", "/api/openai-sub/enabled", { enabled: event.target.checked })));

$("ocg-form").addEventListener("submit", (event) => {
  event.preventDefault();
  const field = $("ocg-key");
  const key = field.value.trim();
  if (!key) return;
  field.value = "";  // out of the page as soon as it is sent
  run(() => api("POST", "/api/opencode-go/key", { key }));
});
$("ocg-remove").addEventListener("click", () => {
  if (confirm("Remove the OpenCode Go key from the vault?")) run(() => api("DELETE", "/api/opencode-go/key"));
});
$("ocg-enabled").addEventListener("change", (event) =>
  run(() => api("POST", "/api/opencode-go/enabled", { enabled: event.target.checked })));

async function test(provider, noteId) {
  const note = $(noteId);
  note.dataset.sticky = "1";
  note.textContent = "testing…";
  try {
    const { test: result } = await api("POST", "/api/" + provider + "/test");
    note.textContent = (result.ok ? "✓ " : "✗ ") + result.detail + (result.ms ? " · " + result.ms + " ms" : "");
  } catch (error) {
    note.textContent = "✗ " + error.message;
  }
}
$("sub-test").addEventListener("click", () => test("openai-sub", "sub-note"));
$("ocg-test").addEventListener("click", () => test("opencode-go", "ocg-note"));

if (token()) refresh(); else showAuth(true);
