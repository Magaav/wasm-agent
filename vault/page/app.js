// Operator-only, write-only credential surface. No credential or admin token persistence.
"use strict";
const $ = id => document.getElementById(id);
const expectedVaultId=(location.hash.match(/^#vault=([a-f0-9-]{36})$/)||[])[1] || '';
let bindingReady=!expectedVaultId;
let adminToken = "", snapshot = null, busy = false, polling = null;
// Retire the old page's persisted-token/fragment enrollment, without reading it.
try{localStorage.removeItem('wa-vault-admin-token');}catch(_){/* no persisted enrollment */}
if(location.hash)history.replaceState(null,'',location.pathname);
let uncertain = sessionStorage.getItem("wa-vault-pending-operation") || "";
const showError = text => { $("err").textContent = text || ""; };
function showAuth(needed) {
  $("auth").hidden = !needed || !bindingReady;
  $("openai-sub").hidden = needed;
  $("opencode-go").hidden = needed;
}
async function api(method, path, body) {
  const response = await fetch(path, {method, headers:{"X-Vault-Token":adminToken,"X-Vault-Instance":snapshot?.vault_id || expectedVaultId,"Content-Type":"application/json"},
    body:body === undefined ? undefined : JSON.stringify(body), cache:"no-store", credentials:"omit", redirect:"error"});
  const value = await response.json().catch(() => ({}));
  if (response.status === 401) { showAuth(true); const error=new Error("Operator authorization refused. Enroll on this vault origin."); error.refused=true; throw error; }
  if (!response.ok) { const error = new Error(value.error?.code || "vault_request_refused"); error.refused = response.status >= 400 && response.status < 500; throw error; }
  return value;
}
async function bindVault(expected) {
  bindingReady=false;showAuth(true);
  try {
    const response=await fetch('/identity',{cache:'no-store',credentials:'omit',redirect:'error'});
    const identity=await response.json();
    if(!response.ok || identity.vault_id!==expected)throw new Error('identity mismatch');
    bindingReady=true;showAuth(true);return true;
  } catch(_) { adminToken='';showError('Vault identity mismatch/unavailable. No operator authorization or key will be sent. Return to the original node and reconcile its configured vault.');return false; }
}
function render(value) {
  snapshot = value;
  showAuth(false);
  const sub = value.providers?.["openai-sub"] || {}, go = value.providers?.["opencode-go"] || {}, login = value.login || {};
  $("sub-state").textContent = sub.configured ? (sub.enabled ? "login configured" : "configured · disabled") : "not configured";
  $("ocg-state").textContent = go.configured ? (go.enabled ? "key configured" : "configured · disabled") : "not configured";
  $("sub-enabled").checked = sub.enabled !== false;
  $("ocg-enabled").checked = go.enabled !== false;
  $("sub-note").textContent = "Vault source only. Presence is not entitlement verification." + (login.state === "error" ? " Login failed: " + login.error : "");
  $("ocg-note").textContent = "Monthly GoUsageLimitError is account/workspace quota, not proof of an invalid key. A new key from the same exhausted workspace may still fail. No automatic retry or provider switch.";
  const pending = login.state === "pending" || login.state === "starting";
  $("sub-flow").hidden = !pending;
  $("sub-code").textContent = pending ? login.user_code || "" : "";
  $("sub-url").textContent = pending ? login.verification_url || "" : "";
  $("sub-url").href = pending ? login.verification_url || "#" : "#";
  if (pending && !polling) polling = setInterval(refresh, 3000);
  if (!pending && polling) { clearInterval(polling); polling = null; }
  if (uncertain) {
    if (go.operation === uncertain) {
      uncertain = ""; sessionStorage.removeItem("wa-vault-pending-operation");
      showError("Save reconciled: this exact operation committed. Entitlement remains unknown.");
    } else showError("Save outcome unresolved or superseded. No replay. Reconcile with the operator before authorizing another write.");
  }
  lock();
}
function lock() {
  document.querySelectorAll("button,input").forEach(el => { if (!el.closest("#auth")) el.disabled = busy; });
  $("ocg-form").querySelector("button").disabled = busy || !!uncertain;
  $("ocg-remove").disabled = busy || !!uncertain;
  $("sub-login").disabled = busy || ['pending','starting'].includes(snapshot?.login?.state);
}
async function run(action) {
  if (busy) return;
  busy = true; lock(); showError("");
  try { render(await action()); } catch (_) { showError("Request failed or outcome unknown. Read status; do not automatically repeat a write."); }
  finally { busy = false; lock(); }
}
async function refresh() {
  if (busy || !adminToken) return;
  await run(() => api("GET", "/api/status"));
}
$("auth-form").addEventListener("submit", event => {
  event.preventDefault(); if(!bindingReady)return;adminToken = $("auth-token").value.trim(); $("auth-token").value = ""; refresh();
});
$("sub-login").addEventListener("click", () => {
  if (confirm("Start an explicit ChatGPT device re-login on this vault? The current credential is retained until fresh login completes. This does not change the node's authentication source."))
    run(() => api("POST", "/api/openai-sub/login", {expected_generation:snapshot.providers['openai-sub'].generation}));
});
$("sub-cancel").addEventListener("click", () => run(() => api("DELETE", "/api/openai-sub/login", {operation:snapshot.login.operation})));
$("sub-logout").addEventListener("click", () => { if (confirm("Remove the vault ChatGPT login?")) run(() => api("DELETE", "/api/openai-sub")); });
$("sub-enabled").addEventListener("change", event => run(() => api("POST", "/api/openai-sub/enabled", {enabled:event.target.checked})));
$("ocg-form").addEventListener("submit", event => {
  event.preventDefault(); if (busy || uncertain || !snapshot) return;
  let key = $("ocg-key").value.trim(); $("ocg-key").value = "";
  if (!key) return;
  if (!confirm("Save this operator-provided Go key in this vault? It does not reset workspace quota or select a provider.")) { key = ""; return; }
  const operation = crypto.randomUUID();
  uncertain = operation; sessionStorage.setItem("wa-vault-pending-operation", operation);
  const body = {key, expected_generation:snapshot.providers["opencode-go"].generation, operation}; key = "";
  run(async () => { try { return await api("POST", "/api/opencode-go/key", body); }
    catch (error) { if (error.refused) { uncertain = ""; sessionStorage.removeItem("wa-vault-pending-operation"); } throw error; }
    finally { body.key = ""; } });
});
$("ocg-cancel").addEventListener("click", () => { $("ocg-key").value = ""; showError("Entry cancelled; no credential write sent."); });
$("reconcile").addEventListener("click", refresh);
$("ocg-remove").addEventListener("click", () => {
  if (confirm("Remove this vault Go credential?")) run(() => api("DELETE", "/api/opencode-go/key", {expected_generation:snapshot.providers["opencode-go"].generation}));
});
$("ocg-enabled").addEventListener("change", event => run(() => api("POST", "/api/opencode-go/enabled", {enabled:event.target.checked})));
// No model probes on this recovery surface.
$("sub-test").hidden = true; $("ocg-test").hidden = true;
window.addEventListener("pagehide", () => { adminToken = ""; $("ocg-key").value = ""; $("auth-token").value = ""; });
showAuth(true);
if(expectedVaultId)bindVault(expectedVaultId);
