# Boot reachable: every install shape starts the node with nobody typing `wa`

Victor, 29/11: "just turning the node instance on should make it reachable" and "the reboot fix should be built in from
the installation, for any instance".

## The shapes the installer writes today

| shape | written by | what starts it at boot | row |
|---|---|---|---|
| Linux, systemd `--user` unit (`~/.config/systemd/user/wa-sentinel.service`) | `scripts/linux/bootstrap.sh`, `scripts/deploy.sh` via `scripts/lib/sentinel-unit.sh` | the unit is `enabled` in `default.target` **and (since 29/11) the installer enables lingering**, so the user manager exists before a login; `Restart=always` restarts a dead watcher | `sentinel-unit`, `sentinel-boot-shapes` |
| Container entrypoint (`wa-entrypoint`: `wa-sentinel autostart on; wa-sentinel start; exec sleep infinity`) | the image, not this repository | the entrypoint itself, once per container start | `sentinel-boot-shapes` (section 2) |
| Plain host without a user manager (`install.sh --no-service`) | `scripts/install.sh` | **nothing**: there is no unit and no boot hook, so the node comes up only when a person or another supervisor runs `wa-sentinel start` | `sentinel-boot-shapes` (section 3) - named, not silently accepted |
| Windows SCM service (`wa-sentinel service --name NAME`) | the Windows installer (`scripts/test-sentinel-service-installer.ps1`, `releases/windows-service.json`); the older logon task (`schtasks /Run /TN wasm-agent-sentinel`) remains until the service is proved | the service manager, once the service is registered with an automatic start type; the logon task starts it at logon | `sentinel-boot-shapes` (section 4) - asserted here by the installer's own words, because this node cannot run SCM |
| macOS | `scripts/install.sh` refuses it: `no_published_bundle_for_macos` | not supported: there is no bundle, so no unit, no launchd job and no supported shape | `sentinel-boot-shapes` (section 5) |

## What was broken, and in which shape

1. **Any shape, any platform** - a stale `sentinel.pid` from a previous pid namespace made `start` refuse (`unverified live
   pid N; refusing a second watcher`). The container restart on 10:31Z brought nothing up until a person typed `wa` at
   11:54Z. Fixed in `watcher_pid_trusted`: the recorded pid counts only if it is not our own process and is really a
   `wa-sentinel ... watch` process (see `rust/wa-sentinel/src/main.rs`).
2. **Linux user unit** - the unit was written and enabled, and **nothing enabled lingering**, so on a machine nobody logs
   into the user manager did not exist and the enabled unit started nothing: the same symptom as the container, on a
   host. Fixed in `wa_sentinel_unit_linger`, called by `wa_sentinel_unit_ensure`.
3. **Plain host, `--no-service`** - no boot hook at all. Named here as a gap: the shape is for a box whose supervisor is
   something else (a container, an init system outside this node), and the installer should say which.
4. **Windows** - the service path is prepared and the logon task is the current shape; this node cannot prove SCM, so the
   row asserts the installer's own statements and names what is unproven.
5. **macOS** - refused by name at install; there is no shape to fix.

## The rule

A shape is boot-reachable only if, from a machine state with no session and a stale pid file, the node answers without a
human: the row for the shape starts it from a scratch home and asks `wa-sentinel status` for `sentinel: up`.
