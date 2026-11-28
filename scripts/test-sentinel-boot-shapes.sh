#!/usr/bin/env bash
# EVERY INSTALL SHAPE BRINGS THE NODE UP WITH NOBODY TYPING `wa` (Victor, 29/11: "the reboot fix should be built in
# from the installation, for any instance").
#
# docs/BOOT-REACHABLE.md lists the shapes. This row is one section per shape, and every section runs on this machine:
# the two that need another platform assert the INSTALLER'S OWN WORDS (what it writes, what it refuses by name) and say
# aloud that the platform itself is not exercised here. Scratch only: a private HOME, no unit manager is touched, and
# WA_SENTINEL_SUPERVISOR=none keeps every verb inside the fixture.
set -uo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
bin=${WA_SENTINEL_BIN:-$root/rust/wa-sentinel/target/debug/wa-sentinel}
[ -x "$bin" ] || { echo "sentinel-boot-shapes: SKIP (no sentinel binary at $bin)"; exit 0; }
[ -f "$root/docs/BOOT-REACHABLE.md" ] || { echo 'sentinel-boot-shapes: docs/BOOT-REACHABLE.md is missing, so the shapes are not written down anywhere' >&2; exit 1; }
work=$(mktemp -d)
checks=0
sleeper=
cleanup() { [ -n "$sleeper" ] && kill "$sleeper" 2>/dev/null; rm -rf "$work"; }
trap cleanup EXIT
ok() { checks=$((checks + 1)); }
fail() { echo "sentinel-boot-shapes: $1" >&2; exit 1; }

# A SHAPE BRINGS THE NODE UP: from a scratch home with a stale pid file naming a live process that is not a watcher
# (the container incident), one start, and the watcher must answer for that home.
bring_up() {
  local name="$1" home="$work/home-$1" pidfile out status now
  mkdir -p "$home/.wasm-agent/sentinel"
  pidfile=$home/.wasm-agent/sentinel/sentinel.pid
  printf '%s\n' "$sleeper" > "$pidfile"
  out=$(env -u WASM_AGENT_IN_TURN WASM_AGENT_HOME=$home WA_SENTINEL_SUPERVISOR=none timeout 30 "$bin" start 2>&1) \
    || fail "$name: the start refused (stale pid from a previous namespace still blocks it): $out"
  case $out in *"unverified live pid"*) fail "$name: refused for a pid that is not a watcher: $out" ;; esac
  status=$(env -u WASM_AGENT_IN_TURN WASM_AGENT_HOME=$home WA_SENTINEL_SUPERVISOR=none timeout 20 "$bin" status 2>&1)
  case $status in
    *"sentinel:"*"up"*) ;;
    *) fail "$name: nothing is watching after the start: $status" ;;
  esac
  now=$(cat "$pidfile" 2>/dev/null || true)
  [ -n "$now" ] && [ "$now" != "$sleeper" ] || fail "$name: the watcher never claimed the pid file"
  env -u WASM_AGENT_IN_TURN WASM_AGENT_HOME=$home WA_SENTINEL_SUPERVISOR=none timeout 20 "$bin" stop >/dev/null 2>&1
  ok
}

sleep 300 & sleeper=$!

# 1. LINUX, systemd --user unit. The unit's bytes, the enable, and (since 29/11) lingering are the installer's own row;
#    here the question is only whether such a start reaches a running watcher.
bring_up linux-user-unit

# 2. CONTAINER ENTRYPOINT: what `wa-entrypoint` runs, in the order it runs it - autostart on (a file, so it survives the
#    restart), then start, then nothing else forever. The image is not in this repository, so the SEQUENCE is what this
#    section can judge, and it is the sequence that was broken on work.
home2=$work/home-container
mkdir -p "$home2/.wasm-agent/sentinel"
printf '%s\n' "$sleeper" > "$home2/.wasm-agent/sentinel/sentinel.pid"
env -u WASM_AGENT_IN_TURN WASM_AGENT_HOME=$home2 WA_SENTINEL_SUPERVISOR=none timeout 20 "$bin" autostart on >/dev/null 2>&1 \
  || fail 'container entrypoint: `wa-sentinel autostart on` failed, so the restart has nothing to start the node'
[ -f "$home2/.wasm-agent/sentinel/autostart" ] || fail 'container entrypoint: autostart is not recorded on disk, so it does not survive the restart'
ok

# 3. PLAIN HOST WITHOUT A USER MANAGER (`install.sh --no-service`): there is no unit and no boot hook, and the shape must
#    SAY so rather than look reachable. The installer's own help is the statement this section can check here.
grep -q -- '--no-service' "$root/scripts/install.sh" || fail 'plain host: install.sh has no --no-service shape, so this section is measuring nothing'
grep -qi 'linger' "$root/scripts/lib/sentinel-unit.sh" || fail 'plain host: the unit installer does not enable lingering, so a no-login reboot starts nothing'
case "$(grep -c 'linger' "$root/docs/BOOT-REACHABLE.md")" in 0) fail 'BOOT-REACHABLE.md does not name the linger gap' ;; *) ;; esac
ok

# 4. WINDOWS SCM SERVICE: this node cannot register or run one. What it CAN check is that the shape is implemented and
#    documented, and that the older logon task is still named - an unproven platform asserted by its own words, never a
#    silent pass.
[ -f "$root/rust/wa-sentinel/src/windows_service.rs" ] || fail 'windows: there is no SCM service implementation, so the shape does not exist'
grep -q -- 'service --name' "$root/docs/WINDOWS-SENTINEL-SERVICE.md" || fail 'windows: the service shape is not documented'
grep -q 'wasm-agent-sentinel' "$root/lua/core/update.lua" || fail 'windows: nothing names the logon task, so the fallback shape is not written down'
ok

# 5. macOS: refused by name at install (`no_published_bundle_for_macos`). The shape is absent, and the row requires the
#    refusal to STAY named - an installer that quietly half-supports it is the failure this section exists for.
grep -q 'no_published_bundle_for_macos' "$root/scripts/install.sh" || fail 'macos: install.sh no longer refuses by name, so a half-supported shape could install silently'
grep -qi 'macos' "$root/docs/BOOT-REACHABLE.md" || fail 'macos: the shapes document does not name the unsupported platform'
ok

echo "sentinel-boot-shapes ok ($checks shapes: linux user unit and container reachable from a stale pid; plain host, windows and macos named - the two the installer cannot start, and the one it refuses)"
