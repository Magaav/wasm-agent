#!/usr/bin/env bash
# The lint this leak earns: a test that runs the INSTALLER must name its own data dir.
#
# The failure it prevents (24/11, twice in one afternoon): scripts/test-upgrade-idle.sh ran upgrade.sh with
# the inherited environment. upgrade.sh writes the deploy-pending signal before it waits -
# `DEPLOY_SIGNAL_DIR="${WASM_AGENT_DATA:-${WASM_AGENT_HOME:-$HOME}/.wasm-agent}"` (upgrade.sh:648), written
# with `to ${COMMIT:-unknown}` (:659) - so one run of a test wrote ~/.wasm-agent/deploy-pending.json and
# every running session on the machine paused after its step; the node never resumed them, because no
# install was coming. A test that touches the operator's data dir is not a test, it is an outage.
#
# What counts as RUNNING the installer, and what does not:
#   runs     `bash .../upgrade.sh`, `bash .../deploy.sh`, `sh`, `source`/`.` of one, `$(...)` of one, and a
#            copy of one that is then executed (a fixture that stands in for the real script)
#   does not `bash -n` (a syntax check runs nothing), grep/cat/sed/awk reads, and a stub whose NAME is
#            upgrade.sh or deploy.sh under the test's own $WORK
# A file that runs one must set WASM_AGENT_DATA, WASM_AGENT_HOME or HOME somewhere (the usual shape is a
# run() wrapper), and the row it runs must have been fixed to do so.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

fails=0
checked=0
runs=0
for file in scripts/test-*.sh; do
  case "$file" in scripts/test-installer-data-isolation.sh) continue ;; esac
  [ -f "$file" ] || continue
  checked=$((checked + 1))
  # Does the file name its own state dir at all?
  sets=no
  if grep -qE '(WASM_AGENT_DATA|WASM_AGENT_HOME|HOME)=' "$file"; then sets=yes; fi
  # Which lines EXECUTE the installer? The line has to put bash/sh/source/. in front of something that IS
  # the installer - a path ending upgrade.sh or deploy.sh, or a variable the file fills with one. A line
  # that merely mentions $DEPLOY (an extract, a grep, an assignment to another name) runs nothing.
  while IFS= read -r hit; do
    line="${hit%%:*}"
    text="${hit#*:}"
    case "$text" in '#'*) continue ;; esac
    printf '%s' "$text" | grep -qE 'bash -n' && continue
    printf '%s' "$text" | grep -qE '\$WORK/(stub-)?[A-Za-z0-9_.-]*(upgrade|deploy)\.sh' && continue
    if printf '%s' "$text" | grep -qE '(^|[;|&(=]|\$\()[[:space:]]*(bash|sh|source|\.)[[:space:]]+[^|;&]*((upgrade|deploy)\.sh|[$][A-Z_]*(UPGRADE|DEPLOY))'; then
      runs=$((runs + 1))
      if [ "$sets" = no ]; then
        echo "installer-data-isolation FAILED: $file:$line runs the installer with the inherited state dir:" >&2
        echo "    $text" >&2
        echo "    set WASM_AGENT_DATA (or WASM_AGENT_HOME and HOME) to a scratch directory for that run" >&2
        fails=$((fails + 1))
      fi
    fi
  done < <(grep -nE '(upgrade|deploy)\.sh|["$]\$?[A-Z_]*(UPGRADE|DEPLOY)["$]' "$file" 2>/dev/null || true)
done

# The rule must be able to fail: the two rows this round fixed are named, so a regression in either is red.
for must in scripts/test-upgrade-idle.sh scripts/test-glibc-floor.sh; do
  grep -qE '(WASM_AGENT_DATA|WASM_AGENT_HOME)=' "$must" \
    || { echo "installer-data-isolation FAILED: $must no longer names its own state dir" >&2; fails=$((fails + 1)); }
done

[ "$fails" = 0 ] || { echo "installer-data-isolation: $fails file(s) run the installer with the real state dir" >&2; exit 1; }

# ---- THE SIX THINGS AROUND THE STATE DIR (25/11, mission release-node-updates, Fable's G condition) --------
# The lint above asks one question: does the row name its own STATE DIR? The night of 24-25/11 showed five more
# things a scratch installer run must not inherit, and each of them was a live one: WA_INSTALL_DIR unset (which
# means the operator's ~/.local/bin), the systemd unit dir (an inherited XDG_CONFIG_HOME is where the LIVE
# wa-sentinel.service lives - two scratch runs rewrote it that night), WA_SENTINEL_UNIT_SYSTEMCTL left as the
# real systemctl, WASM_AGENT_DB naming the operator's ledger, and the node's port 8799/8800.
#
# scripts/lib/install-isolation.sh answers all six for the environment the run WILL use, and its answer is what
# the harnesses below call before they start an installer. The rows here prove the guard refuses a live
# environment (the RED row the condition asks for), passes a scratch one, and that the harnesses call it.
. "$ROOT/scripts/lib/install-isolation.sh" || { echo "installer isolation FAILED: no scripts/lib/install-isolation.sh" >&2; exit 1; }

REAL_HOME="${HOME:-}"
SCRATCH_ROOT="${TMPDIR:-/tmp}"
case "$SCRATCH_ROOT" in "$REAL_HOME"|"$REAL_HOME"/*) SCRATCH_ROOT=/tmp ;; esac
PROBE="$(CDPATH= cd -- "$SCRATCH_ROOT" && pwd -P)/wa-isolation-probe-$$"
mkdir -p "$PROBE/home" "$PROBE/install" "$PROBE/units" "$PROBE/bin" "$PROBE/config" || exit 1
trap 'rm -rf "$PROBE"' EXIT
printf '#!/bin/sh\nexit 1\n' > "$PROBE/bin/systemctl-stub"; chmod +x "$PROBE/bin/systemctl-stub"

checks=0; guard_failed=0
say_ok() { checks=$((checks + 1)); }
say_bad() { checks=$((checks + 1)); guard_failed=$((guard_failed + 1)); echo "installer isolation FAILED: $1" >&2; }

# RED: an inherited, live-looking environment is refused, and every reason is named. The home the run would use
# is an argument, because `env -i` drops everything this shell had.
live=$(env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$REAL_HOME" \
  WA_INSTALL_DIR="$REAL_HOME/.local/bin" XDG_CONFIG_HOME="$REAL_HOME/.config" \
  WASM_AGENT_DB="$REAL_HOME/.wasm-agent/memory.db" WASM_AGENT_PORT=8799 WASM_AGENT_CLIENT_PORT=8800 \
  bash -c '. "$1/scripts/lib/install-isolation.sh"; wa_install_isolation_guard "$2" "$3"' _ "$ROOT" "$PROBE" "$REAL_HOME" 2>&1)
rc=$?
[ "${rc:-0}" != 0 ] && say_ok || say_bad 'a live-looking environment was NOT refused by the isolation guard'
for needle in "WA_INSTALL_DIR = $REAL_HOME/.local/bin" \
              "WA_SENTINEL_UNIT_DIR = $REAL_HOME/.config/systemd/user" \
              "WA_SENTINEL_UNIT_SYSTEMCTL is systemctl, the real systemctl" \
              "WASM_AGENT_DB = $REAL_HOME/.wasm-agent/memory.db" \
              "WASM_AGENT_PORT = 8799 is a live port" \
              "the data dir = $REAL_HOME/.wasm-agent"; do
  printf '%s\n' "$live" | grep -Fq "$needle" && say_ok || say_bad "the refusal does not name: $needle"
done

# GREEN: a scratch environment passes, so the guard is a check and not a wall.
green=$(env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$PROBE/home" WASM_AGENT_HOME="$PROBE/home" \
  WA_INSTALL_DIR="$PROBE/install" XDG_CONFIG_HOME="$PROBE/config" WA_SENTINEL_UNIT_DIR="$PROBE/units" \
  WA_SENTINEL_UNIT_SYSTEMCTL="$PROBE/bin/systemctl-stub" WASM_AGENT_PORT=17999 WASM_AGENT_CLIENT_PORT=18000 \
  bash -c '. "$1/scripts/lib/install-isolation.sh"; wa_install_isolation_guard "$2" "$3"; echo "answer=$?"' _ "$ROOT" "$PROBE" "$PROBE/home" 2>&1)
printf '%s\n' "$green" | grep -q 'answer=0' && say_ok || say_bad "a fully scratch environment was refused: $green"

# THE HARNESSES CALL IT: a harness that runs an installer cannot quietly lose the isolation it was given.
for harness in scripts/test-bootstrap-gate.sh scripts/test-release-install-exec.sh scripts/test-linux-release-fetch.sh; do
  grep -Fq 'install-isolation.sh' "$harness" && say_ok || say_bad "$harness does not source scripts/lib/install-isolation.sh"
  grep -Fq 'wa_install_isolation_guard' "$harness" && say_ok || say_bad "$harness does not run the isolation guard before its installer"
  grep -Fq 'WA_SENTINEL_UNIT_DIR' "$harness" && say_ok || say_bad "$harness does not name a scratch unit dir"
done

[ "$guard_failed" = 0 ] || exit 1
echo "installer isolation ok ($checks checks: a live environment is refused, a scratch one passes, and the installer harnesses call the guard)"

. "$ROOT/scripts/lib/scratch-home.sh"
. "$ROOT/scripts/lib/scratch-installer.sh"

root="$(wa_scratch_root wa-installer-isolation)" || exit 2
W="$(wa_test_workdir "$root" run)" || exit 2
REAL_HOME="$(CDPATH= cd -- "${HOME:-/nonexistent}" 2>/dev/null && pwd -P)" || REAL_HOME=/nonexistent
MARKERS=()
cleanup() {
  local m
  for m in "${MARKERS[@]:-}"; do
    [ -n "$m" ] || continue
    # ONLY the processes this test started, named by the marker it put in their argv.
    local pid
    for pid in $(proc_with_marker "$m"); do kill -TERM "$pid" 2>/dev/null; done
  done
  chmod -R u+w "$W" 2>/dev/null
  rm -rf "$W"
}
trap cleanup EXIT
R="$W/root"
mkdir -p "$R" || exit 2

failed=0
ok()   { checks=$((checks + 1)); if [ "$1" = "1" ]; then printf '  ok   %s\n' "$2"; else failed=$((failed + 1)); printf '  FAIL %s%s\n' "$2" "${3:+ - $3}"; fi; }
under() { # <path> <root> -> 1 when the path is the root or under it
  case "$1" in "$2"|"$2"/*) echo 1 ;; *) echo 0 ;; esac
}

# ---- reading a live process's environment: the checker both halves are judged by ----------------------------------
proc_with_marker() { # <marker> -> pids whose argv names it
  local m="$1" pid a
  for pid in /proc/[0-9]*; do
    pid="${pid#/proc/}"
    [ "$pid" = "$$" ] && continue
    # cat, not a redirect: a process that exits between the glob and the read makes the shell itself print
    # "No such file or directory" for the redirect, which reads as a defect of this test.
    a="$(cat "/proc/$pid/cmdline" 2>/dev/null | tr '\0' ' ')"
    case "$a" in *"$m"*) echo "$pid" ;; esac
  done
}
env_of() { # <pid> <name> -> value or empty
  tr '\0' '\n' < "/proc/$1/environ" 2>/dev/null | sed -n "s/^$2=//p" | head -1
}
# THE CHECKER. Prints one line per violation; exit 0 when the process is isolated from the operator.
isolation_violations() { # <pid> <scratch root> [<real home>]
  local pid="$1" r="$2" real="${3:-$REAL_HOME}" bad=0 home xdg db inst port
  home="$(env_of "$pid" HOME)"
  xdg="$(env_of "$pid" XDG_CONFIG_HOME)"
  db="$(env_of "$pid" WASM_AGENT_DB)"
  inst="$(env_of "$pid" WA_INSTALL_DIR)"
  port="$(env_of "$pid" WASM_AGENT_PORT)"
  case "$home" in
    "$r"|"$r"/*) ;;
    *) printf 'HOME=%s is not under the scratch root %s\n' "${home:-<unset>}" "$r"; bad=1 ;;
  esac
  case "$xdg" in
    '') printf 'XDG_CONFIG_HOME is unset, so the unit dir falls back to $HOME/.config - a value that does not travel with the row\n'; bad=1 ;;
    "$r"|"$r"/*) ;;
    *) printf 'XDG_CONFIG_HOME=%s is not under the scratch root %s (the unit dir follows it)\n' "$xdg" "$r"; bad=1 ;;
  esac
  # THE STORE: WASM_AGENT_DB, else <HOME>/.wasm-agent - both are the node's ledger.
  if [ -n "$db" ]; then
    case "$db" in "$r"|"$r"/*) ;; *) printf 'WASM_AGENT_DB=%s is not under the scratch root %s (this is the live ledger)\n' "$db" "$r"; bad=1 ;; esac
  else
    case "$home" in "$r"|"$r"/*) ;; *) printf 'WASM_AGENT_DB is unset and HOME is not scratch, so the store is the operator store\n'; bad=1 ;; esac
  fi
  case "$inst" in
    '') printf 'WA_INSTALL_DIR is unset, so the install is <HOME>/.local/bin - the live install wherever HOME is live\n'; bad=1 ;;
    "$r"|"$r"/*) ;;
    *) printf 'WA_INSTALL_DIR=%s is not under the scratch root %s\n' "$inst" "$r"; bad=1 ;;
  esac
  case "$port" in
    '') printf 'WASM_AGENT_PORT is unset, which is the live 8799\n'; bad=1 ;;
    8799|8800|8801|8810) printf 'WASM_AGENT_PORT=%s is a live port\n' "$port"; bad=1 ;;
  esac
  return $bad
}

# A process that outlives its parent, named by a marker in its argv: `bash -c 'while :; do sleep 1; done' MARKER`
# keeps the marker as $0, so /proc/<pid>/cmdline names it. It is a sleeping shell, never an installer.
leftover_child() { # <marker> -> pid of the surviving shell
  local m="$1" pid
  bash -c "$(printf "bash -c 'while :; do sleep 1; done' %q & sleep 0" "$m")" >/dev/null 2>&1
  sleep 0.4
  pid="$(proc_with_marker "$m" | head -1)"
  MARKERS+=("$m")
  printf '%s' "$pid"
}

# ================= A. the six dimensions, on a real child of the library ======================================
printf 'A. the wrapper (scripts/lib/scratch-installer.sh): the six dimensions on a real child\n'
# A PORT THE LIVE NODE DOES NOT OWN, asked of the kernel.
PORT="$(bash -c 'exec 3<>/dev/tcp/127.0.0.1/1' 2>/dev/null; python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null)"
case "$PORT" in ''|*[!0-9]*) PORT=23456 ;; esac
ENV_FILE="$R/child.env"
MARK="${WASM_AGENT_IN_TURN-1}" WASM_AGENT_IN_TURN="${WASM_AGENT_IN_TURN:-1}" WASM_AGENT_VAULT_URL="https://vault.invalid/never" WASM_AGENT_OPENCODE_GO_VAULT_URL="https://vault.invalid/never" \
  wa_installer_run --root "$R" --port "$PORT" -- bash -c 'env' > "$ENV_FILE" 2>"$R/child.err"
rc=$?
ok "$([ "$rc" = 0 ] && echo 1)" "the wrapper runs a child at all" "rc=$rc $(head -2 "$R/child.err")"
field() { sed -n "s/^$1=//p" "$ENV_FILE" | head -1; }
for pair in HOME WASM_AGENT_HOME WA_INSTALL_DIR WASM_AGENT_DB XDG_CONFIG_HOME XDG_RUNTIME_DIR WA_SENTINEL_UNIT_DIR WA_SENTINEL_UNIT_SYSTEMCTL; do
  v="$(field "$pair")"
  ok "$(under "$v" "$R")" "$pair is under the scratch root" "$pair=${v:-<unset>}"
done
ok "$([ "$(field WASM_AGENT_DB)" = "$R/ledger.db" ] && echo 1)" "the ledger is the scratch one, not an inherited WASM_AGENT_DB" "$(field WASM_AGENT_DB)"
ok "$(under "$(field XDG_CONFIG_HOME)" "$R")" "the unit dir's XDG_CONFIG_HOME is scratch (sentinel-unit.sh:41 reads it first)" "$(field XDG_CONFIG_HOME)"
stub="$(field WA_SENTINEL_UNIT_SYSTEMCTL)"
ok "$([ -x "$stub" ] && [ "$stub" != /usr/bin/systemctl ] && echo 1)" "the child is given a systemctl STUB, not the real one" "$stub"
printf 'systemctl-probe' > "$R/.probe"
stub_out="$("$stub" --user restart wa-sentinel.service 2>&1)"; stub_rc=$?
ok "$([ "$stub_rc" = 0 ] && grep -q 'restart wa-sentinel.service' "$R/systemctl-calls.log" 2>/dev/null && echo 1)" \
  "and the stub RECORDS the call instead of reaching a user manager" "rc=$stub_rc out=$stub_out log=$(tail -1 "$R/systemctl-calls.log" 2>/dev/null)"
p="$(field WASM_AGENT_PORT)"; wp="$(field WA_PORT)"
ok "$([ -n "$p" ] && [ "$p" = "$wp" ] && ! wa_installer_live_port "$p" && echo 1)" "the port is set, is not a live port, and WA_PORT agrees" "WASM_AGENT_PORT=${p:-unset} WA_PORT=${wp:-unset}"
ok "$([ "$(field WASM_AGENT_IN_TURN)" = "1" ] && echo 1)" \
  "the turn-guard marker is PRESERVED, not stripped (the caller had 1, the child has it too)" "WASM_AGENT_IN_TURN=$(field WASM_AGENT_IN_TURN)"
ok "$([ -z "$(field WASM_AGENT_VAULT_URL)" ] && [ -z "$(field WASM_AGENT_OPENCODE_GO_VAULT_URL)" ] && echo 1)" \
  "no vault URL survives into the child" "$(field WASM_AGENT_VAULT_URL)"
ok "$([ "$(field DBUS_SESSION_BUS_ADDRESS)" = "unix:path=$R/no-bus" ] && echo 1)" \
  "the session bus points at nothing, so nothing can reach a live user manager" "$(field DBUS_SESSION_BUS_ADDRESS)"

# --- and the refusals, each by name, before anything is created ---
out="$(wa_installer_env_prepare --root "$REAL_HOME" --port "$PORT" 2>&1)"; rc=$?
ok "$([ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'refused(' && echo 1)" "the operator home is refused as a scratch root" "rc=$rc $out"
# AND IT STILL WORKS WHEN THE ROW HAS ALREADY REPLACED HOME. Measured in the orchestrator's runner, 25/11 03:24Z: a
# row does `export HOME=$W/home` as its first act, so a guard asked with that HOME in front of it answered "this is
# the operator home" about the row's own scratch home, refused(real_node_home), and the row's 14 checks failed behind
# it. The library captures the operator home when it is sourced, and this check is that capture.
out="$(HOME="$R/home" WASM_AGENT_HOME="$R/home" wa_installer_env_prepare --root "$R" --port "$PORT" 2>&1)"; rc=$?
ok "$([ "$rc" = 0 ] && printf '%s' "$out" | grep -q '^HOME=' && echo 1)" \
  "a row that already replaced HOME still gets an environment (the operator home is captured at source time)" \
  "rc=$rc $(printf '%s' "$out" | head -2 | tr '\n' '|')"
out="$(wa_installer_env_prepare --root "$R" --port 8799 2>&1)"; rc=$?
ok "$([ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'live port' && echo 1)" "the live port 8799 is refused by name" "rc=$rc $out"
out="$(wa_installer_env_prepare --root "$R" --port "$PORT" --install-dir /usr/local/bin 2>&1)"; rc=$?
ok "$([ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'not under the scratch root' && echo 1)" "an install dir outside the scratch root is refused" "rc=$rc $out"
out="$(wa_installer_env_prepare --root "$R" --port "$PORT" --set "HOME=$REAL_HOME" 2>&1)"; rc=$?
ok "$([ "$rc" != 0 ] && printf '%s' "$out" | grep -q 'refused(' && echo 1)" "a row cannot --set a dimension back to the operator home" "rc=$rc $out"

# ================= B. tonight's case: "ok" and a process left behind ==========================================
printf '\nB. the concrete case: a harness that says ok and leaves a live-HOME process behind\n'
# Replica 1 - the harness's own child: scratch HOME, and the unit dir, the ledger and the port inherited (which is
# exactly what the row of 24/11 had). Nothing is opened: the process only sleeps.
M1="wa-isolation-probe-harness-$$"
pid1="$(HOME="$R/home" XDG_CONFIG_HOME="$REAL_HOME/.config" WASM_AGENT_DB="$REAL_HOME/.wasm-agent/memory.db" \
  bash -c "$(printf "bash -c 'while :; do sleep 1; done' %q & sleep 0" "$M1")" >/dev/null 2>&1; sleep 0.4; proc_with_marker "$M1" | head -1)"
MARKERS+=("$M1")
v1="$(isolation_violations "${pid1:-0}" "$R" 2>&1)"; rc1=$?
ok "$([ -n "$pid1" ] && echo 1)" "the replica of the leaked process was found by its marker" "pid=${pid1:-none}"
ok "$([ "$rc1" != 0 ] && echo 1)" "the checker CATCHES it (a green row with a live-unit/ledger/port process is a failure)" "$(printf '%s' "$v1" | tr '\n' '|')"
ok "$(printf '%s' "$v1" | grep -q 'XDG_CONFIG_HOME' && echo 1)" "and names the unit dir as the escape" "$(printf '%s' "$v1" | tr '\n' '|')"
ok "$(printf '%s' "$v1" | grep -q 'live ledger' && echo 1)" "and the ledger" "$(printf '%s' "$v1" | tr '\n' '|')"
ok "$(printf '%s' "$v1" | grep -q 'WASM_AGENT_PORT is unset' && echo 1)" "and the missing port (the symptom: a sentinel with no WASM_AGENT_PORT)" "$(printf '%s' "$v1" | tr '\n' '|')"
# Replica 2 - what a systemd unit hands the sentinel: the LIVE home itself (pid 635976's shape).
M2="wa-isolation-probe-unit-$$"
pid2="$(HOME="$REAL_HOME" WASM_AGENT_DB="$REAL_HOME/.wasm-agent/memory.db" \
  bash -c "$(printf "bash -c 'while :; do sleep 1; done' %q & sleep 0" "$M2")" >/dev/null 2>&1; sleep 0.4; proc_with_marker "$M2" | head -1)"
MARKERS+=("$M2")
v2="$(isolation_violations "${pid2:-0}" "$R" 2>&1)"; rc2=$?
ok "$([ "$rc2" != 0 ] && printf '%s' "$v2" | grep -q 'HOME=' && echo 1)" "and it catches the sentinel a unit started, by its HOME" "$(printf '%s' "$v2" | tr '\n' '|')"
# Replica 3 - the SAME leftover, started through the wrapper: the checker must be clean, or the wrapper is useless.
M3="wa-isolation-probe-wrapper-$$"
wa_installer_run --root "$R" --port "$PORT" -- bash -c "bash -c 'while :; do sleep 1; done' $M3 & sleep 0.4" >/dev/null 2>&1
pid3="$(proc_with_marker "$M3" | head -1)"
MARKERS+=("$M3")
v3="$(isolation_violations "${pid3:-0}" "$R" 2>&1)"; rc3=$?
ok "$([ -n "$pid3" ] && echo 1)" "the wrapper's own leftover was found too" "pid=${pid3:-none}"
ok "$([ "$rc3" = 0 ] && echo 1)" "and it is CLEAN on every dimension (the wrapper is what turns a red into a green)" "$(printf '%s' "$v3" | tr '\n' '|')"
for m in "${MARKERS[@]:-}"; do for q in $(proc_with_marker "$m"); do kill -TERM "$q" 2>/dev/null; done; done

# ================= C. the rows =================================================================================
printf '\nC. every row that runs deploy.sh or upgrade.sh: no stripped guard, no detach unless it is the guard s own fixture\n'
# Statements, not lines: a row writes its installer call over six continued lines.
rows_reached=0; offenders=0
vent() { # shellcheck disable=SC2016
  printf '%s' "$1"
}
while IFS=$'\t' read -r file ln text; do
  case "$text" in ''|'#'*) continue ;; esac
  # ONLY a statement that RUNS the installer, not one that greps it.
  # a RUN of the installer, not a mention of it: an interpreter word and one of the two scripts, literal or through
  # the $DEPLOY/$UPGRADE variables every row sets.
  case "$text" in
    *'bash '*|*'timeout '*|*'exec '*) ;;
    *) continue ;;
  esac
  case "$text" in
    *scripts/deploy.sh*|*scripts/upgrade.sh*|*'$DEPLOY'*|*'$UPGRADE'*) ;;
    *) continue ;;
  esac
  rows_reached=$((rows_reached + 1))
  strip=""
  case "$text" in
    *'-u WASM_AGENT_IN_TURN'*|*'-u WASM_AGENT_PROVENANCE'*) strip='env -u of the guard marker' ;;
    *unset*WASM_AGENT_IN_TURN*) strip='an unset of the guard marker' ;;
  esac
  case "$text" in *WASM_AGENT_IN_TURN=*) case "$text" in *WASM_AGENT_IN_TURN=1*) ;; *) strip='a cleared guard marker' ;; esac ;; esac
  detach=""
  case "$text" in *setsid*|*nohup*|*disown*) detach='a detached installer' ;; esac
  # A CREDENTIAL IS NEVER HANDED TO AN INSTALLER UNDER TEST (25/11, Fable's D, after 40ffd00d): not as an env
  # assignment on its statement, and not through the builder, which no longer has a pass-through at all. A row that
  # reads a release channel uses a LOCAL STUB CHANNEL - a file:// index signed with the committed TEST key - and
  # needs no credential. (A row that deliberately SETS a vault URL to prove the product clears it is not this: it is
  # not on an installer's statement, and it is not forwarding the operator's.)
  credential=""
  case "$text" in
    *GH_TOKEN=*|*GITHUB_TOKEN=*|*GH_CONFIG_DIR=*|*GITHUB_CONFIG_DIR=*|*OPENAI_API_KEY=*|*ANTHROPIC_API_KEY=*|*OPENCODE_GO_API_KEY=*|*WA_VAULT_ADMIN_TOKEN=*)
      credential='a credential' ;;
  esac
  if [ -n "$credential" ]; then
    offenders=$((offenders + 1))
    ok 0 "$file:$ln does not hand the installer a credential" "the statement passes $credential: $(printf '%s' "$text" | cut -c1-150)"
  fi
  # WHICH STATEMENT MAY BE EXEMPT: one that says where everything lands, in any order - its own scratch HOME or
  # WASM_AGENT_HOME, WA_INSTALL_DIR and WA_PORT. Anything less and a strip is a bypass, not a fixture.
  names_all=0
  case "$text" in
    *WA_INSTALL_DIR=*) case "$text" in *WA_PORT=*) case "$text" in *HOME=*|*WASM_AGENT_HOME=*) names_all=1 ;; esac ;; esac ;;
  esac
  if [ -n "$strip" ] && [ "$names_all" != 1 -o -z "$detach" ]; then
    offenders=$((offenders + 1))
    ok 0 "$file:$ln does not strip the guard" "$strip in a statement that $( [ -z "$detach" ] && echo 'does NOT re-root the process tree, so the strip is a bypass, not a fixture' || echo 'does not name its own scratch HOME/WA_INSTALL_DIR/WA_PORT' ): $(printf '%s' "$text" | cut -c1-150)"
  fi
  if [ -n "$detach" ] && [ "$names_all" != 1 ]; then
    offenders=$((offenders + 1))
    ok 0 "$file:$ln does not detach an installer it cannot isolate" "$detach with no HOME/WASM_AGENT_HOME/WA_INSTALL_DIR/WA_PORT in the same statement: $(printf '%s' "$text" | cut -c1-150)"
  fi
done <<ROWS
$(for f in scripts/test.sh scripts/test-*.sh; do
    awk -v FILE="$f" '
      { sub(/\r$/,"") }
      { if (buf=="") { start=NR; buf=$0 } else { buf=buf " " $0 } }
      { if (buf ~ /\\$/) { sub(/\\$/,"",buf); next } else { print FILE "\t" start "\t" buf; buf="" } }
      END { if (buf!="") print FILE "\t" start "\t" buf }
    ' "$f"
  done)
ROWS
# After a failed offender the loop counted it; when every statement is clean, nothing above printed a FAIL.
ok "$([ "$offenders" = 0 ] && echo 1)" "no row strips the guard, detaches an installer without isolating it, or hands it a credential ($rows_reached statements run an installer)" "$offenders offender(s) above"
# AND THE BUILDER ITSELF HAS NO PASS-THROUGH: a future edit that put one back would make every check above pass.
builder_cred="$(grep -vE '^[[:space:]]*#' scripts/lib/scratch-installer.sh | grep -nE 'GH_TOKEN|GITHUB_TOKEN|GH_CONFIG_DIR' | head -2)"
ok "$([ -z "$builder_cred" ] && echo 1)" \
  "scripts/lib/scratch-installer.sh carries no credential variable in its code (its comment names them to say why they are gone)" "$builder_cred"
# AND THE BRANCH'S OWN ROW GOES THROUGH THE LIBRARY (the six dimensions are the library's, so this is what makes the
# row safe to run anywhere, not only under the orchestrator's runner).
own="scripts/test-deploy-covering-release.sh"
own_code="$(grep -vE '^[[:space:]]*#' "$own")"
ok "$(printf '%s' "$own_code" | grep -q 'wa_installer_run' && ! printf '%s' "$own_code" | grep -qE -- '-u WASM_AGENT_IN_TURN|WASM_AGENT_IN_TURN=' && echo 1)" \
  "$own runs its deploy through wa_installer_run and carries no guard variable in its code (only in the comment that explains why it cannot)" \
  "$(printf '%s' "$own_code" | grep -nE -- '-u WASM_AGENT_IN_TURN|WASM_AGENT_IN_TURN=|wa_installer_run' | head -3)"

# THE ORIGINAL RULE OF THIS FILE (24/11), kept verbatim as one more check: a row that runs the installer names its
# own state dir, or every session on the machine pauses on a deploy-pending signal that no install will answer.
ok "$([ "$fails" = 0 ] && echo 1)" "every row that runs the installer names its own state dir ($checked row(s) checked, $runs installer invocation(s))" \
  "$fails file(s) run the installer with the real state dir"
# THE SIX DIMENSIONS ARE ALSO THE BUILDER'S CONTRACT (25/11, prebuilt-records-the-cover): scripts/lib/
# scratch-installer.sh REFUSES to run anything unless the environment it built passes the reviewed guard
# (scripts/lib/install-isolation.sh, release-node-updates) - so the two files cannot disagree.
GUARD_ENV="$(env -i PATH=/usr/local/bin:/usr/bin:/bin HOME="$R/home" WASM_AGENT_HOME="$R/home" \
  WA_INSTALL_DIR="$R/install" XDG_CONFIG_HOME="$R/config" WA_SENTINEL_UNIT_DIR="$R/units" \
  WA_SENTINEL_UNIT_SYSTEMCTL="$R/bin/systemctl-stub" WASM_AGENT_DB="$R/ledger.db" \
  WASM_AGENT_PORT=17999 WASM_AGENT_CLIENT_PORT=18000 \
  bash -c '. "$1/scripts/lib/install-isolation.sh"; wa_install_isolation_guard "$2" "$3"; echo "answer=$?"' _ "$ROOT" "$R" "$R/home" 2>&1)"
ok "$(printf '%s' "$GUARD_ENV" | grep -q 'answer=0' && echo 1)" \
  "the environment this file calls isolated is the one install-isolation.sh calls isolated" "$(printf '%s' "$GUARD_ENV" | tr '
' '|')"

printf '\nthe six dimensions and the rows: %d checks, %d failed\n' "$checks" "$failed"
[ "$failed" = 0 ] || guard_failed=$((guard_failed + failed))

# THE HARNESS OF THIS BRANCH CALLS THE BUILDER, which calls the guard (above). Named here so a regression in the
# row is red in this file, not only in the row.
for harness in scripts/test-deploy-covering-release.sh; do
  grep -Fq 'scratch-installer.sh' "$harness" && say_ok || say_bad "$harness does not source scripts/lib/scratch-installer.sh"
  grep -Fq 'wa_installer_run' "$harness" && say_ok || say_bad "$harness does not run its installer through wa_installer_run"
done

echo "installer data isolation ok ($checked row(s) checked, $runs installer invocation(s), all with their own state dir)"
