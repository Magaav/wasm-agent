# Windows developer candidate — not customer onboarding

This archive is a developer candidate, not a public release. Guest invitations,
first-run setup and customer permission controls are not included. Do not use it
to enroll customers or expose its HTTP service publicly.

## Contents and verification

`manifest.json` names the source revision, build target and every runtime asset's
SHA-256. The archive has a separate `.sha256` file. Obtain both through a trusted
distribution channel: a matching checksum alone does not authenticate a publisher.
The manifest's `candidate-unverified` status means behavior and release gates
still require verification.

Extract to a new folder, not over an existing installation. Existing installations
must use the external upgrade procedure. Do not copy this binary over a running
node or replace an existing window. User data is not included in this archive.

## Isolated manual verification

Use a disposable Windows user or VM with no operator configuration. These commands
are for a verifier, not the proposed end-user experience. From the extracted folder,
set a new absolute scratch home (not your real home) and clear development overrides:

```powershell
$env:WASM_AGENT_HOME = Join-Path $env:TEMP ("wa-candidate-" + [guid]::NewGuid())
Remove-Item Env:WASM_AGENT_LUA_ROOT -ErrorAction SilentlyContinue
Remove-Item Env:WA_SCRIPT -ErrorAction SilentlyContinue
.\wa.exe --version
.\wa.exe paths
.\wa.exe help
```

The home override isolates configuration, identity and data. Use a clean process
environment: do not inherit provider credentials, rendezvous, sync or other
`WASM_AGENT_*` settings from an operator session. No remote enrollment is needed.

Without a model you can inspect paths, remember/recall facts and start the local
UI server. Run it in one terminal, with two unused ports:

```powershell
.\wa.exe serve --port 18799 --client-port 18800 --ui "$PWD\ui"
```

Open `http://127.0.0.1:18799/` in a trusted local browser. To inspect the bundled
Windows shell from a second terminal in the same extracted folder:

```powershell
$env:WASM_AGENT_UI_URL = 'http://127.0.0.1:18799/'
$env:WASM_AGENT_CLIENT_PORT = '18800'
.\wa-window.exe
```

WebView2 Runtime must be available for the shell; its loader DLL is bundled, the
runtime itself is not. Clean-machine runtime dependencies remain a release gate.
Do not confuse a successful page load with a verified tool-backed task.

To test model use, put only your own compatible provider configuration into the
scratch `<config>/env` path reported by `paths`. Protect that file; do not put
credentials in command arguments or evidence exports. `wa chat` is a native CLI
command; `wa setup`, `wa doctor` and a packaged `wa ui` launcher are not supplied
by this slice.

Stop only the scratch server you started, using its terminal or exact PID. Never
stop all processes named `wa`. The sentinel and upgrade script are included for
later integration verification; this archive does not start a watcher or install
a service, and the current upgrade script requires its shell prerequisites.

## Authority and evidence

Native shell/desktop tools run with the user's authority, not inside a guaranteed
workspace sandbox. Do not use untrusted tasks or grant customer access before the
release authority gates pass.

Remembered facts are explicit and retrieved on demand. Default conversation
retention is seven days; debug transcripts persist. Tracked file undo is not an
undo for arbitrary network, shell or application effects. Inspect actual results,
not just an agent's success message.
