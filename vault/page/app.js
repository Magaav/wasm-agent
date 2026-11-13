// Operator-only, write-only credential surface. No credential or admin token persistence.
"use strict";
const $ = id => document.getElementById(id);
const expectedVaultId=(location.hash.match(/^#vault=([a-f0-9-]{36})$/)||[])[1] || '';
let bindingReady=!expectedVaultId;
let adminToken = "", snapshot = null, busy = false;
// Retire the old page's persisted-token/fragment enrollment, without reading it.
try{localStorage.removeItem('wa-vault-admin-token');}catch(_){/* no persisted enrollment */}
if(location.hash)history.replaceState(null,'',location.pathname);
let uncertain = sessionStorage.getItem("wa-vault-pending-operation") || "";
const showError = text => { $("err").textContent = text || ""; };
function showAuth(needed) {
  $("auth").hidden = !needed || !bindingReady;
  $("opencode-go").hidden = needed;
  $("release-signing").hidden = needed;
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
  const go = value.providers?.["opencode-go"] || {};
  $("ocg-state").textContent = go.configured ? (go.enabled ? "key configured" : "configured · disabled") : "not configured";
  $("ocg-enabled").checked = go.enabled !== false;
  $("ocg-note").textContent = "Monthly GoUsageLimitError is account/workspace quota, not proof of an invalid key. A new key from the same exhausted workspace may still fail. No automatic retry or provider switch.";
  if (uncertain) {
    if (go.operation === uncertain) {
      uncertain = ""; sessionStorage.removeItem("wa-vault-pending-operation");
      showError("Save reconciled: this exact operation committed. Entitlement remains unknown.");
    } else showError("Save outcome unresolved or superseded. No replay. Reconcile with the operator before authorizing another write.");
  }
  if (value.release_signing) renderSigning(value.release_signing);
  lock();
}
function lock() {
  document.querySelectorAll("button,input").forEach(el => { if (!el.closest("#auth")) el.disabled = busy; });
  $("ocg-form").querySelector("button").disabled = busy || !!uncertain;
  $("ocg-remove").disabled = busy || !!uncertain;
  // The key's own state decides these, never the shared busy flag alone: a backup is offered only while
  // the vault says it has not been taken, and creating a key is offered only while there is none.
  const signing = snapshot && snapshot.releaseSigning;
  $("rs-create").disabled = busy || !!(signing && signing.configured);
  $("rs-write").disabled = busy || !signing || !signing.configured || !!signing.backup_taken;
  $("rs-show").disabled = busy || !signing || !signing.configured || !!signing.backup_taken;
}
function renderSigning(value) {
  snapshot.releaseSigning = value;
  $("rs-state").textContent = value.configured
    ? (value.backup_taken ? "key created · backup taken" : "key created · BACK UP NOW")
    : "no key";
  $("rs-state").className = "state" + (value.configured ? (value.backup_taken ? " ok" : " bad") : "");
  $("rs-public-row").hidden = !value.configured;
  $("rs-public").value = value.public_key || "";
  $("rs-create-row").hidden = !!value.configured;
  $("rs-backup").hidden = !value.configured || !!value.backup_taken;
  $("rs-note").textContent = value.configured
    ? "key id " + value.key_id + " · " + (value.signatures | 0) + " signature(s) made" + (value.backup_taken ? " · the backup was taken; the key is not readable again" : "")
    : "No signing key: releases cannot be signed until you generate one. Do it where the vault lives, then copy the one backup off this machine.";
}
async function refreshSigning() {
  const value = await api("GET", "/api/release-signing");
  renderSigning(value);
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
  if (!busy && adminToken) await run(refreshSigning);
}
$("auth-form").addEventListener("submit", event => {
  event.preventDefault(); if(!bindingReady)return;adminToken = $("auth-token").value.trim(); $("auth-token").value = ""; refresh();
});
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
$("rs-create").addEventListener("click", () => {
  if (!confirm("Generate the release signing key inside this vault? Releases will be signed with it and its private half will never be readable again except through the one backup offered next.")) return;
  run(async () => { await api("POST", "/api/release-signing/key", {}); return null; }).then(refreshSigning);
});
$("rs-write").addEventListener("click", () => {
  const path = $("rs-path").value.trim();
  if (!path) { showError("Name the file the vault should write the one backup to."); return; }
  if (!confirm("Write the one and only backup of the release signing key to " + path + "?")) return;
  run(async () => {
    const value = await api("POST", "/api/release-signing/backup", {path});
    $("rs-backup-note").textContent = "Backup written to " + value.path + " (mode 0600). Move it to offline media, then delete it here. This is the only one.";
    $("rs-seed").hidden = true;
    await refreshSigning();
    return null;
  });
});
$("rs-show").addEventListener("click", () => {
  if (!confirm("Show the one and only backup of the release signing key? It will not be shown or exportable again.")) return;
  run(async () => {
    const value = await api("POST", "/api/release-signing/backup", {});
    $("rs-seed").textContent = value.seed_hex;
    $("rs-seed").hidden = false;
    $("rs-backup-note").textContent = "Write this down now and keep it offline. This is the only time it is shown.";
    await refreshSigning();
    return null;
  });
});
$("ocg-remove").addEventListener("click", () => {
  if (confirm("Remove this vault Go credential?")) run(() => api("DELETE", "/api/opencode-go/key", {expected_generation:snapshot.providers["opencode-go"].generation}));
});
$("ocg-enabled").addEventListener("change", event => run(() => api("POST", "/api/opencode-go/enabled", {enabled:event.target.checked})));
// No model probes on this recovery surface.
$("ocg-test").hidden = true;
window.addEventListener("pagehide", () => { adminToken = ""; $("ocg-key").value = ""; $("auth-token").value = ""; $("rs-seed").textContent = ""; $("rs-seed").hidden = true; });
showAuth(true);
if(expectedVaultId)bindVault(expectedVaultId);
