# sentinel-on-avell — a real watcher on this laptop, a status that names the truth, a resume that follows the deploy

Branch `change/sentinel-on-avell`, base `f5373ef2`. Commits:

| item | commit |
| --- | --- |
| 1. the `--user` unit, installed by the installer path | `357cc002`, `6d08630b` |
| 2. "installed; no watcher is running: <the command>" | `2a5b5463` |
| 3. a paused worker is resumed when the deploy ends | `f237b873` |
| test marker for the discrimination gate | `b6c671eb` |
| docs | `e094bdb8` |

Citations are `git log -S`: `wa_sentinel_unit_ensure` → `357cc002`, `fail_installed` → `2a5b5463`,
`release_due` → `f237b873`.

## The premises, re-measured (22/11, this laptop)

| the brief says | what the machine said |
| --- | --- |
| every `wa-deploy-*` of the night ended `failed` (7 of 7) | `systemctl --user list-units 'wa-deploy-*'` showed 33 failed deploy units on 21-22/11, and `~/.wasm-agent/build-status.json` said `{"state":"failed","phase":"installing: node installed, but the sentinel would not start"}` — **true** |
| the node WAS installed each time | `~/.local/bin/installed.txt` = commit `2e20aa70`, `wa --version` = `2e20aa70`, `/health` 200 — **true** |
| `wa-sentinel status` shows "sentinel: down / not running" and "supervisor: inside user@1000.service, which cannot be shown to own this watcher" | in a mission shell it showed "inside mission-sentinel-on-avell.service"; from an operator shell it shows `user@1000.service`. Same verdict, different cgroup — **true** |
| no `wa-sentinel` unit exists in `~/.config/systemd/user` | **true** (only `wa-serve.service`, `wa-vault.service`, `omarchy-quattro-sync.service`) |
| deploys are performed by a transient `systemd-run --user --unit=orch-sentinel-once ... wa-sentinel once` | **true** (`~/Work/missions/install-local.sh`) |
| `scripts/deploy.sh` ~2051-2057 runs `wa-sentinel start`, which refuses from inside the deploy unit, and the deploy is reported failed | **partly wrong.** The refusal was not `Step::Refuse`. `~/.wasm-agent/sentinel/deploy.out` of the last deploy says: `deploy: no sentinel watching - starting one` / `sentinel: systemctl --user restart orch-sentinel-once.service failed (exit status: 5): Unit orch-sentinel-once.service not found.` The deploy had inherited `WA_SENTINEL_SUPERVISOR=user:orch-sentinel-once.service` from `install-local.sh`'s `systemd-run -p Environment=...` and asked **that** unit's manager, which no longer existed. Both readings end at the same place — nothing outside owns the watcher — but the fix had to cover the wrong-unit case too, which is why the deploy now asks the unit **it installed**, by the supervisor that unit itself states |
| each deploy paused every running worker and the resume never fired | **true, with the mechanism.** `deploy_pause.at_boundary` arms ONE wake with `resume_seconds` = `(since + bound − now) + 30`, and `upgrade.sh` writes `bound=1800` (`WA_DEPLOY_IDLE_BOUND`). A 4-minute deploy therefore armed each resume ~26-30 minutes out; the orchestrator resumed its workers by hand at 00:26Z long before that |

## What the other nodes run

The servers run the **system** unit `deploy/wa-sentinel.service` (`/usr/local/bin/wa-sentinel watch`, `WASM_AGENT_HOME=/home/ubuntu`, `WA_SENTINEL_SCRIPTS=/usr/local/bin/scripts;/home/ubuntu/.local/bin/scripts`,
`WA_SENTINEL_WAKE_BUDGET=6`), installed by `deploy/install.sh` (`install -m 644 "$HERE/wa-sentinel.service" /etc/systemd/system/`).
On Windows it is the logon task or the SCM (`scripts/install-sentinel-service.ps1`).
A **user-local** install (this laptop, `~/.local/bin`) is the case `scripts/linux/bootstrap.sh` already
handled by writing `~/.config/systemd/user/wa-sentinel.service`; this branch gives the *deploy* the same
unit, so both install paths produce one shape: `wa-sentinel watch`, `Restart=always`, and
`WA_SENTINEL_SUPERVISOR=user:wa-sentinel.service`.

## Item 1 — a real watcher, from the product's installer path

- `scripts/lib/sentinel-unit.sh` (`357cc002`) is the one writer of the unit text, plus
  `wa_sentinel_unit_ensure` (write when the bytes differ → `daemon-reload` → `enable`, never a lifecycle
  verb), `wa_sentinel_unit_verdict` (should this machine have one, and why not), `wa_sentinel_node_unit_present`
  (`6d08630b`: system **or user** unit for the node) and `wa_sentinel_watcher_prepare` (the deploy's plan).
- `scripts/deploy.sh` (`357cc002`) calls it in the "no watcher, no stop file" branch and then starts the
  watcher by handing `wa-sentinel start` the supervisor the unit states, so `role::step` answers
  `Step::Manager` and the deploy asks `systemctl --user restart wa-sentinel.service` — from its own
  transient unit, outside the watcher's control group (`role::placement`). The supervisor check itself is
  untouched: a system unit for the watcher, a prefix outside `$HOME`, Windows, `WA_DEPLOY_SENTINEL_UNIT=0`
  or no user manager each get `unit=no: <why>` and the command the deploy always ran.
- `scripts/linux/bootstrap.sh` (`357cc002`) writes the same provenance comment line, so the front door's
  copy and the lib's are compared byte for byte by the test.

**Live, on this laptop** (the installer path, run from the worktree because the branch is not installed):

```
$ . scripts/lib/sentinel-unit.sh; . scripts/lib/service-target.sh; . scripts/lib/node-runtime.sh
$ wa_sentinel_watcher_prepare /home/victor/.local/bin/wa-sentinel /home/victor/.local/bin /home/victor/.wasm-agent 8799 8800
supervisor=user:wa-sentinel.service
watcher=systemctl --user restart wa-sentinel.service
unit=yes: unit_written unit_enabled
$ WA_SENTINEL_SUPERVISOR=user:wa-sentinel.service /home/victor/.local/bin/wa-sentinel start
  wa-sentinel.service started by its manager (the manager owns this watcher)
$ wa-sentinel status
  node:      up    port 8799  pid 2314281
  sentinel:  up    watching (pid 2491981)  no port of its own
  supervisor: wa-sentinel.service owns this watcher (systemd --user); stop and restart are asked of it
$ systemctl --user is-active wa-sentinel.service; systemctl --user is-enabled wa-sentinel.service
active
enabled
```

The written unit is at `~/.config/systemd/user/wa-sentinel.service`; its autostart line is
`Environment=WA_SENTINEL_AUTOSTART=0` because this machine's node has its own unit (`wa-serve.service`,
user, enabled+active), and a second starter is a second answer to "who starts this node" (`6d08630b`).
`loginctl show-user victor -p Linger` is `no`, so across a reboot without a login the unit needs
`sudo loginctl enable-linger victor` — the same one line `bootstrap.sh` prints; I did not run sudo.

## Item 2 — "installed; no watcher is running: <the one command>"

`scripts/deploy.sh`'s watcher step has two refusals, and both now go through `fail_installed`
(`2a5b5463`):

```
deploy: node installed, but the sentinel would not start
deploy: the node is installed and answering; start its watcher with: <the one command>
```

and `build-status.json` gets `state=installed`, `phase=no watcher is running: <the one command>` — the
same state a finished deploy writes, never `failed`. Both renderers draw it (`2a5b5463`):
`rust/wa-term/src/build_status.rs` (`build_status::NO_WATCHER`, `✓ wasm-agent installed — <phase>`) and
`lua/core/update_banner.lua`, pinned against each other by `scripts/test-update-banner.lua`. The deploy's
exit status stays non-zero (the deploy did not finish its job), and `deploy-result.json` carries
`ok:false` with the same sentence.

## Item 3 — the resume follows the deploy, decided with a test

Decision: **`wa chat --once` IS paused, and the resume does not depend on it existing.** The paused
process exits; the wake is a row in the ledger; the node's own tick performs it. What was wrong was the
time: the wake was armed from the installer's *bound*.

`lua/core/deploy_pause.lua` (`f237b873`): `RESUME_REASON` is a constant, and `release_due` makes the
pending deploy-resume wakes due the moment the marker is gone (`upgrade.sh` removes it in its `EXIT`
trap), or the moment its bound has passed. Rows that are already due and wakes with any other reason are
left alone. `lua/core/selfloop.lua` calls it at the top of the node's tick, before the due-row query, so
the release is dispatched in the same 2-second pass — by the node, not by the worker.

## Tests, and where they are wired

| test | what it holds | wired | on the base |
| --- | --- | --- | --- |
| `scripts/test-sentinel-unit.sh` (45 checks) | the unit text; byte parity with `bootstrap.sh`'s heredoc; `ensure` writes/`daemon-reload`/`enable` and never restarts (stub `systemctl` records argv); every refusal by name (`no_user_manager`, `no_sentinel_at_prefix`, `prefix_not_absolute`, `daemon_reload_failed`); the verdicts (opt-out, invalid knob, outside `$HOME`, system unit, no `systemctl`); the plan's command/supervisor and the autostart decision both ways | `scripts/test.sh`, `gate_run bash scripts/test-sentinel-unit.sh` | `new-symbol` (the lib does not exist on the base) |
| `scripts/test-deploy-resume.lua` (25 checks) | schedule → tick → release → dispatch, on the real ledger in a scratch home: a live marker releases nothing; after the marker is removed the same tick makes exactly the resume wake due and dispatches it; an unrelated wake keeps its time; an expired marker releases; `at_boundary` arms the reason the release matches on | the fast path (any `scripts/test-*.lua` not in `scripts/fast-path.exclude`) | measured by hand on `f5373ef2`: `wake_reason_required`, so it fails there |
| `scripts/test-update-banner.lua` (+2 checks) | the installed-with-no-watcher line, never the failure sentence, and `banner.NO_WATCHER` equals `build_status::NO_WATCHER` read out of the Rust source | the fast path | measured by hand on `f5373ef2`: 2 of 234 fail (`got ✓ wasm-agent rebuilt …`) |
| `rust/wa-term/src/build_status.rs` `an_installed_node_whose_watcher_is_missing_is_not_a_build_failure` | the row both renderers draw, and that a finished deploy keeps its own sentence | the crate's own test module | it is inside the file the fix changes; reverted with it |

`scripts/test-discriminates.sh f5373ef2` on this branch: **0 blocking** — `new-symbol` for
`test-sentinel-unit.sh`, and `unrevertable` for the two Lua rows (the branch changes `rust/`, so this
tool will not judge a Lua row against a base binary it did not build). That is why the two Lua rows were
measured on the base by hand, above.

## Not run here, and what is not verified

- The full gate (`scripts/test.sh`) and the fast path were **not** run: the land gate runs them. The rows
  this branch touches were run individually and are green
  (`test-sentinel-unit.sh`, `test-update-banner.lua`, `test-deploy-pause.lua`, `test-cli-notice.lua`,
  `test-deploy-build-status.sh`, `test-deploy-signal.sh`, `test-fast-rows.sh`, `check-deploy-docs.mjs`,
  and `cargo test -p wa-term --lib build_status` → 9 passed).
- A **live deploy through the new branch's `deploy.sh`** was not performed: it needs the branch installed,
  and this mission does not push. The path was verified in pieces: the unit written by the product's own
  installer function, `wa-sentinel start` asking its manager, `wa-sentinel status` reading "up", and the
  unit active+enabled.
- `wa chat --once` was not paused for real on this node (that needs an installed branch and a running
  deploy); item 3 is held by the Lua row above, which drives the real ledger, the real tick and the real
  marker file.
- Linger is off for this user; without `sudo loginctl enable-linger victor` the unit does not survive a
  reboot without a login. Not changed by me.

## Pre-existing failures named (not this branch's)

`bash scripts/check-naming.sh` fails with "20 old name(s) left" in files this branch does not touch
(`wit/kernel/kernel.wit`, `wit/kernel-v2/kernel.wit`, `rust/components/*/wit/deps/kernel.wit`,
`rust/components/wa-whatsapp/src/{ocr,recognize}.rs`, `docs/WHATSAPP-OCR.md`,
`docs/missions/reports/fence-card.md`).

## Texts to approve (operator-facing, verbatim)

1. `deploy: sentinel unit: unit_written unit_enabled`
2. `deploy: starting the sentinel through its unit: systemctl --user restart wa-sentinel.service`
3. `deploy: the node is installed and answering; start its watcher with: <the one command>`
4. `deploy: no sentinel unit installed: <why>` — reasons: `WA_DEPLOY_SENTINEL_UNIT=0: the operator asked for no unit`;
   `the install is not under $HOME (<prefix>): a system-wide prefix belongs to a system unit`;
   `a system unit for this watcher is already installed (<file>): not adding a second owner`;
   `systemctl --user has no session to talk to: no user manager to install a unit into`;
   `windows: the watcher is a logon task or the SCM there`; and the unit-writer's own
   `sentinel_unit: no_user_manager|no_sentinel_at_prefix|prefix_not_absolute|unit_write_failed|daemon_reload_failed|enable_failed`
5. build-status phase: `no watcher is running: <the one command>`
6. the row both renderers draw: `✓ wasm-agent installed — no watcher is running: <the one command>`
7. the unit's first two lines: `# Written by wasm-agent (scripts/lib/sentinel-unit.sh and scripts/linux/bootstrap.sh write the same text).` /
   `# The sentinel (autostart) starts and supervises wa serve.` (the second is bootstrap's existing wording)
8. `docs/SENTINEL.md`, new section title: `### A user-local install gets a `--user` unit from the deploy`
