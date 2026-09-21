# wasm-agent — Windows developer preview

This package runs independently of the maintainers' computers. It is a developer
preview, **not a customer-ready automation service**. Ordinary guest setup stays
disconnected. A separately gated managed bootstrap requires a published package,
a managed registry, pinned operator identities and explicit remote-access consent.
Do not expose its HTTP service publicly or use the legacy SSH installer.

## Install and set up

1. Obtain the ZIP and its SHA-256 through a trusted distribution channel. Verify
   the archive hash before extraction; checksums alone do not authenticate a publisher.
2. Extract into a new folder. From PowerShell in that folder:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
   ```

   The default destination is `%LOCALAPPDATA%\wasm-agent-preview`, separate from
   the existing developer install. The installer verifies every asset, never
   overwrites an existing directory, and starts no services. `-InstallDir` chooses
   a different fresh destination. `-RegisterCommand` optionally adds its `bin`
   directory to your user PATH; open a new terminal afterward.

3. Run the exact command printed by the installer, for example:

   ```powershell
   & "$env:LOCALAPPDATA\wasm-agent-preview\bin\wa.cmd" setup
   ```

   Choose `personal`, an agent display name, an existing workspace, your compatible
   provider URL and model, and your own API key. Credential input is masked and
   the configuration file's permissions are limited to your Windows account.
   Keys are not accepted as command-line arguments.

4. Verify the provider and open the existing UI:

   ```powershell
   & "$env:LOCALAPPDATA\wasm-agent-preview\bin\wa.cmd" doctor -ValidateProvider
   & "$env:LOCALAPPDATA\wasm-agent-preview\bin\wa.cmd" ui
   ```

   Provider validation makes one small billable model request. A bad credential
   leaves configuration saved and reports failure; fix it with setup and retry.
   `doctor` without the flag is read-only and makes no provider request.

When `bin` is on PATH, these are `wa setup`, `wa doctor` and `wa ui`. Use the full
`.cmd` path if an older `wa` command takes precedence. These three commands are
provided by the Windows launcher; native `wa.exe` still provides the agent CLI.

The display name is onboarding metadata and a diagnostic label; it does not
rename your node, change a branch or define a new model personality. The UI
launches in your chosen workspace. Native one-shot CLI commands use their caller's
working directory. Setup rerun preserves node identity, memory, sessions,
existing instructions and unrelated configuration. Conflicting provider selections
previously saved through the UI are reported, not silently overridden.

Setup does not enroll either mode remotely; it clears rendezvous/sync settings.
It refuses pre-existing configuration not created by this setup flow, and refuses
changes while a recorded server is still running. Do not use it to reconfigure an
operator deployment; select a separate `WASM_AGENT_HOME` instead. Process
environment can override configuration; setup refuses conflicts it detects,
and the UI launcher refuses runtime overrides other than `WASM_AGENT_HOME`.

## Guest / assisted mode

Selecting `guest` in ordinary `wa setup` saves an offline profile without a model
key. It authorizes **no operator**, connects to **no service**, and refuses network
startup. Do not bypass this by copying an operator's environment or credentials.

The managed bootstrap is a different, explicitly approved entry path. It installs
in the background while asking for a node name, then asks for consent to **full
Windows-user-account automation** by pinned operators. It uses an isolated data
home, configures no model, adds no inbound firewall rule and verifies outbound
relay attachment. It does not install an automatic Windows-login task.

For an installation created by that bootstrap:

- `wa access`: consent, expiry, local role, registration and relay attachment.
- `wa access log`: recent local operator/capability/completion records. These are
  not tamper-proof and do not undo or exhaustively describe arbitrary shell effects.
- `wa disconnect`: revoke future/queued remote calls; pause outbound polling.
  Already running native actions may finish; registry presence expires afterward.
- `wa connect`: explicitly renew consent and start/reuse this installation's node.
  Default consent is 24 hours; `-Hours` selects another duration. Use this after
  expiry or logout if you want assistance again.

The operator uses `wa network role <node-id> master` or `guest` to change your
network/local role, without needing a model on your machine. Promotion does not
make every other customer accessible. Disconnecting assistance preserves an
already promoted owner's local master role.

The public release descriptor is disabled until operator service deployment and
package publication are approved. These controls are a tested prototype, not a
claim that every public/customer release gate has passed.

## Windows prerequisites and recovery

Windows x64 and Windows PowerShell 5.1 are the intended platform. WebView2 Runtime
is needed for the native shell; its loader DLL is bundled, the runtime itself is
not. `doctor` reports detection. Install Microsoft WebView2 Runtime or use
`wa ui -Browser` with a trusted local browser. No SSH, Git or Rust is needed merely
to launch the installed runtime. Some requested tasks/tools still need their own
prerequisites, including Bash for POSIX shell commands.

The launcher verifies the actual server PID owns its port. If another process
owns it, it refuses rather than connecting to someone else's agent. Use
`wa ui -Port 18799` to choose another unused port; the client bridge uses the next
port. `wa ui -NoOpen` starts/verifies the server without opening a window, useful
for diagnostics. It does not stop or replace existing windows. Launcher logs and PID records
live under the configuration directory, not inside the immutable package.

If a launch fails, inspect the reported log and PID. Never stop all processes
named `wa`. Existing installations must be upgraded by the external upgrade
procedure; this fresh installer intentionally refuses them. The bundled sentinel
and upgrade script are not automatically installed as a service; the current
upgrade script still needs its shell prerequisites.

## Data and authority

`wa paths` identifies the configuration/data directory. Personal endpoint settings
use the existing `<config>/env` file. `WASM_AGENT_HOME` may select a new absolute
Windows scratch home for testing; never point test runs at your live home. Clear
`WASM_AGENT_LUA_ROOT` and `WA_SCRIPT` to exercise embedded code.

Native file, shell and desktop tools carry your Windows account's authority.
**The workspace is not a sandbox.** This preview still has HTTP/concurrency
hardening gates before public/customer use. Do not run untrusted tasks merely
because a package passed its checksum checks.

Memory is explicit and on demand. Default transcript retention is seven days;
debug transcripts persist. Tracked file undo does not undo arbitrary external
actions. A provider answering is not proof that an automation succeeded.

The manifest records source revision and asset hashes; `candidate-unverified`
means it does not certify release readiness. See the repository release status
for tests performed, limitations and the public-release go/no-go decision.
