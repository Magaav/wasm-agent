#!/usr/bin/env bash
# NOTHING THIS REPO RUNS MAY REACH THE OPERATOR'S INSTALL. THIS IS THE LINT THAT SAYS SO (25/11, Fable's G item).
#
# WHAT HAPPENED WITHOUT IT. On the night of 24/11 a harness (scripts/test-deploy-covering-release.sh, run by hand from
# a mission directory) reported
#
#     deploy covering release ok (16 checks, 0 failed)
#
# and left a wa-sentinel behind with HOME=/home/victor and no WASM_AGENT_PORT (pid 635976, killed at 00:38:06Z). It
# had also rewritten the LIVE ~/.config/systemd/user/wa-sentinel.service and ~/.local/bin/runtime-worktree.txt and run
# sentinels on the LIVE ledger. The harness had replaced HOME with a scratch directory - and replaced nothing else:
#
#     the unit dir   scripts/lib/sentinel-unit.sh:41   ${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user  -> inherited
#     the manager    XDG_RUNTIME_DIR                                                            -> inherited
#     the ledger     WASM_AGENT_DB                                                              -> inherited
#     the port       WASM_AGENT_PORT                                                            -> unset (= 8799)
#
# and it stripped the marker the turn guard reads (`env -u WASM_AGENT_IN_TURN`), which is why the deploy went ahead
# inside a turn at all. A green row that reaches the live node is worse than a red one: it is the only failure a
# reviewer cannot see.
#
# WHAT THIS FILE ASSERTS
#   A. the six dimensions, DYNAMICALLY, on a real child of scripts/lib/scratch-installer.sh: INSTALL_DIR, the unit
#      dir, the systemctl it is given (a stub under the scratch root, never /usr/bin/systemctl), the DB, XDG (both
#      config and runtime), the port (never 8799/8800/8801/8810), the guard marker preserved rather than stripped,
#      and no vault URL carried over. Plus the refusals: the operator home, a live port and an install dir outside
#      the scratch root are each refused by name before anything is created.
#   B. the CONCRETE CASE. A harness that reports "ok" and leaves a process behind is caught: this test starts two
#      replicas of what leaked that night (one with the scratch HOME and the inherited unit/ledger/port, one with the
#      live HOME a systemd unit hands a sentinel) and its checker must name each violation; then it starts the SAME
#      leftover through the wrapper and its checker must be clean. If the checker is ever loosened, this half fails.
#   C. every row that RUNS scripts/deploy.sh or scripts/upgrade.sh (statements, continuation lines joined; the
#      literal path or $DEPLOY/$UPGRADE): it may not strip the marker, and it may not detach (setsid/nohup/disown)
#      - except a statement that does both, re-roots the process tree on purpose and names its own scratch HOME,
#      WASM_AGENT_HOME, WA_INSTALL_DIR and WA_PORT, which is the one fixture whose SUBJECT is the guard itself
#      (scripts/test-deploy-ancestry.sh).
#
# WHAT IT DOES NOT COVER, said plainly so nobody reads a pass as more than it is: a row that STARTS a sentinel
# (wa-sentinel, bootstrap.sh, install.sh) is not in set C; the statements it scans are the ones that pass their
# environment inline, because a row that sets its variables in a function and calls `bash "$DEPLOY"` is judged by
# the function, not by that one line. The rows that reach an installer are counted and printed either way.
#
#   bash scripts/test-installer-data-isolation.sh
#
# Exit: 0 green; 1 a check failed. Its own scratch root only; it refuses to run when the root it made is the
# operator's home or store (scripts/lib/scratch-home.sh), and it never starts an installer (its children are shells
# that sleep, and it stops every one of them by pid).
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
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

checks=0; failed=0
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
ok "$([ "$offenders" = 0 ] && echo 1)" "no row strips the guard or detaches an installer without isolating it ($rows_reached statements run an installer)" "$offenders offender(s) above"
# AND THE BRANCH'S OWN ROW GOES THROUGH THE LIBRARY (the six dimensions are the library's, so this is what makes the
# row safe to run anywhere, not only under the orchestrator's runner).
own="scripts/test-deploy-covering-release.sh"
own_code="$(grep -vE '^[[:space:]]*#' "$own")"
ok "$(printf '%s' "$own_code" | grep -q 'wa_installer_run' && ! printf '%s' "$own_code" | grep -qE -- '-u WASM_AGENT_IN_TURN|WASM_AGENT_IN_TURN=' && echo 1)" \
  "$own runs its deploy through wa_installer_run and carries no guard variable in its code (only in the comment that explains why it cannot)" \
  "$(printf '%s' "$own_code" | grep -nE -- '-u WASM_AGENT_IN_TURN|WASM_AGENT_IN_TURN=|wa_installer_run' | head -3)"

printf '\ninstaller data isolation: %d checks, %d failed\n' "$checks" "$failed"
[ "$failed" = 0 ] || exit 1
exit 0
