#!/usr/bin/env bash
# Does a deploy refuse to install somewhere the service does not run, and refuse a port a stray holds?
#
# The failure this exists for, measured on the cloud node on 2026-09-29: the unit ran
# `/home/ubuntu/.local/share/wasm-agent/wa`, a ten-day-old install, while the deploy's default and the process
# actually serving were two other directories. The unit's own process started, failed to bind :8799
# (`Address already in use (os error 98)` - a stray node, pid 644564, ppid 1, had held :8799 and :8800 for
# 3h10m), and *exited 0*, so systemd restarted it every three seconds: NRestarts=61117. The deploy reported
# success in that window, because the pid answering /health was the stray's.
#
# So this fixture does not describe the checks - it runs the deploy:
#
#   (a) a fake install the unit runs + a different install the deploy is pointed at -> refused, naming both
#       paths, before anything is built;
#   (b) a real TCP listener standing in for the stray, holding the port the deploy will be restarted onto ->
#       refused, naming the process (pid, parent, image), the port and the install it disagrees with;
#   (c) the agreeing case -> proceeds to the build.
#
# Each one is falsified rather than asserted in isolation, because a check that fires for the wrong reason is
# as wrong as one that never fires: (a) with the unit file gone, (b) and (a) with the *code as it was before
# the check this file is about* (the pinned baseline below), (c) with the port free and with the unit's
# drop-in repointing ExecStart - the operator's repair in the real incident - after which the refusal returns.
#
# That baseline is pinned by blob sha, and never read from `origin/main`. A baseline that is a branch makes
# this file's truth depend on when someone else merges: the day the check landed on main, "main has no opinion
# about it" stopped being true, and the check that says so went red with nothing wrong in the tree under test -
# and stayed red, because main will not lose the check again. A blob sha is the bytes themselves, so the
# comparison cannot drift, and the two below are scripts/deploy.sh and scripts/verify-install.sh as of
# 8f13258^ (2026-09-29), the revision immediately before "fix(deploy): one source of truth for where the node
# lives" added the check. Nothing in the comparison depends on where those bytes sit in history - and the
# pre-fix deploy.sh names no helper this test's scratch tree would have to have beside it, so the copy it runs
# is that code rather than today's code missing a module it now expects. `pin_blob` refuses to run a
# falsification whose baseline is absent or already contains the check, so the pin can neither go quiet nor
# invert.
#
# Hermetic: one temp directory per run, a fake install, a fake systemd unit, one listener created by `node`
# and killed on exit. No node binary is started, no build is run (the scratch tree has no `rust/`, so a run
# that stops refusing reaches the build and stops there - which is how a missing check shows up as a wrong
# outcome), and nothing outside the temp directory is touched.
#
#   bash scripts/test-deploy-service-target.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="$ROOT/scripts/deploy.sh"
VERIFY="$ROOT/scripts/verify-install.sh"
LIB="$ROOT/scripts/lib/service-target.sh"
fail_hard() { echo "test-deploy-service-target: $*" >&2; exit 1; }
[ -f "$DEPLOY" ] || fail_hard "no $DEPLOY"
[ -f "$VERIFY" ] || fail_hard "no $VERIFY"
[ -f "$LIB" ] || fail_hard "no $LIB - the one expression for where the node lives"
command -v node >/dev/null 2>&1 || { echo "test-deploy-service-target SKIPPED - needs node for the stray holder"; exit 3; }
. "$LIB"

# The baseline the two falsifications below compare against: the two scripts as they were before the check
# (8f13258^, 2026-09-29), pinned by blob sha because a branch is not a fixed point - see the header. The
# blobs are in the repository's own object store, so a full clone has them and a shallow one does not.
BASELINE_DEPLOY_BLOB=4537d08576b42c1637a377a46e59c546b3618af3
BASELINE_VERIFY_BLOB=87bc0ded2e8b333e256c2b0819d5e501a89c54a6
pin_blob() { # blob dest check-string what
  git -C "$ROOT" cat-file blob "$1" > "$2" 2>/dev/null \
    || fail_hard "pinned baseline $4 (blob $1) is not in this repository's object store; a shallow, filtered or exported checkout cannot show the code as it was before the check - run git fetch --unshallow rather than let this read as a pass"
  [ -s "$2" ] || fail_hard "pinned baseline $4 (blob $1) came back empty"
  if grep -qF "$3" "$2"; then
    fail_hard "pinned baseline $4 (blob $1) already contains \"$3\": it is not the code before the check, and every falsification against it would be inverted"
  fi
}

checks=0; failed=0
ok() { checks=$((checks + 1)); if [ "$1" = "1" ]; then printf '  ok   %s\n' "$2"; else failed=$((failed + 1)); printf '  FAIL %s%s\n' "$2" "${3:+ - $3}"; fi; }
note() { printf '  note %s\n' "$1"; }

W="$(mktemp -d "${TMPDIR:-/tmp}/wa-service-target-XXXXXX")" || fail_hard "no scratch directory"
STRAY_PID=""
STRAY_JOB=""
cleanup() {
  [ -n "$STRAY_PID" ] && kill "$STRAY_PID" 2>/dev/null
  [ -n "$STRAY_JOB" ] && kill "$STRAY_JOB" 2>/dev/null
  rm -rf "$W"
}
trap cleanup EXIT

# --- the fixture: two installs, a clean scratch tree, a home of its own ---------------------------------
INSTALL_SERVICE="$W/install-service"    # the directory the unit executes
INSTALL_TARGET="$W/install-target"      # the directory the deploy would install into
INSTALL_STRAY="$W/install-stray"        # the install a stray process would be running from
INSTALL_HOME="$W/home"
TREE="$W/tree"
mkdir -p "$INSTALL_SERVICE" "$INSTALL_TARGET" "$INSTALL_STRAY" "$INSTALL_HOME" "$TREE"
printf 'the node the service runs\n' > "$INSTALL_SERVICE/wa"
printf 'the node the deploy would install\n' > "$INSTALL_TARGET/wa"
git -C "$TREE" init -q --initial-branch=main
git -C "$TREE" -c user.name=fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m 'fixture tree'

PORT=""
PORT_BASE=$((20000 + RANDOM % 20000))
for candidate in $(seq "$PORT_BASE" $((PORT_BASE + 60))); do
  [ -z "$(wa_port_pid "$candidate")" ] && { PORT="$candidate"; break; }
done
[ -n "$PORT" ] || fail_hard "no free port to stand in for the node"
CLIENT=$((PORT + 1))

unit_service="$W/wa-serve.service"          # ExecStart names INSTALL_SERVICE
unit_target="$W/wa-serve-target.service"    # ExecStart names INSTALL_TARGET
write_unit() { # file install_dir
  printf '[Unit]\nDescription=wasm-agent node (fixture)\n\n[Service]\nUser=ubuntu\nRestart=always\nRestartSec=3\nExecStart=%s/wa serve --port %s --client-port %s --ui %s/ui\n\n[Install]\nWantedBy=multi-user.target\n' \
    "$2" "$PORT" "$CLIENT" "$2" > "$1"
}
write_unit "$unit_service" "$INSTALL_SERVICE"
write_unit "$unit_target" "$INSTALL_TARGET"
MISSING_UNIT="$W/wa-serve-deleted.service"

echo "fixture: service=$INSTALL_SERVICE target=$INSTALL_TARGET port=$PORT"

last_exit=0; last_out=""
# `install` may be empty: an empty WA_INSTALL_DIR is "the caller did not say", which is how the target falls
# through to the service definition and, with no unit at all, to the running node.
run_deploy() { # unit_file install_dir [deploy_script]
  local unit="$1" install="$2" script="${3:-$DEPLOY}"
  last_out="$(cd "$TREE" && env -u WASM_AGENT_IN_TURN -u WASM_AGENT_HOME \
      HOME="$INSTALL_HOME" USERPROFILE="$INSTALL_HOME" \
      WA_DEPLOY_ROOT="$TREE" WA_INSTALL_DIR="$install" WA_PORT="$PORT" WA_CLIENT_PORT="$CLIENT" \
      WA_SERVICE_UNIT_FILE="$unit" WA_PROC_ROOT="${PROC_ROOT_FIXTURE:-}" \
      bash "$script" --reason "service-target fixture" 2>&1)"
  last_exit=$?
}

# --- (a) the unit runs one install, the deploy is pointed at another: refused, by name -------------------
: > "$INSTALL_TARGET/deploy.log"
run_deploy "$unit_service" "$INSTALL_TARGET"
REFUSAL="$(grep -m1 'different installs' <<<"$last_out")"
ok "$([ "$last_exit" != "0" ] && [ -n "$REFUSAL" ] && echo 1 || echo 0)" \
  "a deploy pointed away from the install the service runs is refused" "exit $last_exit"
ok "$(grep -qF "$INSTALL_SERVICE" <<<"$REFUSAL" && echo 1 || echo 0)" "the refusal names the path the service runs" "${REFUSAL:0:110}"
ok "$(grep -qF "$INSTALL_TARGET" <<<"$REFUSAL" && echo 1 || echo 0)" "the refusal names the path the deploy would write"
ok "$(grep -q 'deploy: building' <<<"$last_out" && echo 0 || echo 1)" "and it refused before the build"
ok "$(grep -q 'different installs' "$INSTALL_TARGET/deploy.log" 2>/dev/null && echo 1 || echo 0)" \
  "the refusal is recorded in the install it refused to write" "$(tail -1 "$INSTALL_TARGET/deploy.log" 2>/dev/null | cut -c1-80)"
ok "$([ ! -f "$INSTALL_TARGET/installed.txt" ] && echo 1 || echo 0)" "and nothing was installed or recorded"

# Falsification 1: the evidence the check reads is gone (no unit file). The deploy must then proceed, and
# *say* that nothing could be asked - a check that goes blind silently is worse than one that refuses.
run_deploy "$MISSING_UNIT" "$INSTALL_TARGET"
ok "$(grep -q 'deploy: building' <<<"$last_out" && grep -q 'different installs' <<<"$last_out" && echo 0 || echo 1)" \
  "with no service definition the check disappears and the deploy proceeds" "exit $last_exit"
ok "$(grep -q 'the target only because nothing contradicted it' <<<"$last_out" && echo 1 || echo 0)" \
  "and that it could not ask, so a blind gate is visible afterwards"
ok "$(grep -q 'note: no service definition' "$INSTALL_TARGET/deploy.log" 2>/dev/null && echo 1 || echo 0)" \
  "the note is durable, not only on stdout"

# Falsification 2: the same disagreement, against the code as it was before the check existed. This is the
# outcome the cloud node paid 61,117 restarts for: two installs, one port, and a deploy that reported success.
pin_blob "$BASELINE_DEPLOY_BLOB" "$W/deploy-baseline.sh" 'different installs' "scripts/deploy.sh"
run_deploy "$unit_service" "$INSTALL_TARGET" "$W/deploy-baseline.sh"
ok "$(grep -q 'deploy: building' <<<"$last_out" && grep -q 'different installs' <<<"$last_out" && echo 0 || echo 1)" \
  "the deploy as it was before this check installs beside the running install without a word" "exit $last_exit"

# The operator's repair, and the reason it works: a drop-in that repoints ExecStart is what the coordinator
# did on the cloud node, and it is the one thing that makes the two paths agree.
mkdir -p "$unit_service.d"
printf '[Service]\nExecStart=\nExecStart=%s/wa serve --port %s --client-port %s --ui %s/ui\n' \
  "$INSTALL_TARGET" "$PORT" "$CLIENT" "$INSTALL_TARGET" > "$unit_service.d/90-repoint.conf"
run_deploy "$unit_service" "$INSTALL_TARGET"
ok "$(grep -q 'deploy: building' <<<"$last_out" && grep -q 'different installs' <<<"$last_out" && echo 0 || echo 1)" \
  "a unit whose drop-in repoints ExecStart is read, and the same deploy proceeds"
ok "$(grep -qF "$INSTALL_TARGET is where the machine runs its node" <<<"$last_out" && echo 1 || echo 0)" \
  "and it says the target came from the service rather than from a default"
rm -rf "$unit_service.d"
run_deploy "$unit_service" "$INSTALL_TARGET"
ok "$(grep -q 'different installs' <<<"$last_out" && echo 1 || echo 0)" \
  "removing the drop-in brings the refusal back - the falsification was the missing evidence"

# --- (b) a stray holds the port: refused, by process ----------------------------------------------------
node -e "require('net').createServer().listen($PORT,'127.0.0.1')" >"$W/stray.log" 2>&1 &
STRAY_JOB=$!
LISTEN_PID=""
# Generous, in tenths and then some: this runs on a loaded machine during a gate, and a fixture that fails
# because its own listener needed a second longer is a fixture nobody can trust. What it could not do is
# reported with what `node` said.
for _ in $(seq 1 150); do LISTEN_PID="$(wa_port_pid "$PORT")"; [ -n "$LISTEN_PID" ] && break; sleep 0.2; done
[ -n "$LISTEN_PID" ] || fail_hard "the fixture's own listener never held port $PORT (node said: $(head -2 "$W/stray.log" 2>/dev/null | tr '\n' ' '))"
# The pid that holds the port is the one the machine reports (that is what the deploy reads); `$!` is this
# shell's job, and it is only the handle this script kills at the end. Killing the job pid here instead of
# the holder's - which is what this fixture did first - killed the stray before the deploy could see it, and
# the case passed for the wrong reason until the deploy's own output was printed.
STRAY_PID="$LISTEN_PID"

# The process details a real machine reads from /proc come from a synthetic tree when there is no /proc for
# another pid (Windows). The *listener* is real either way; only the naming of the process is staged, and
# this says which of the two answered.
PROC_ROOT_FIXTURE=""
if [ ! -e "/proc/$LISTEN_PID" ]; then
  PROC_ROOT_FIXTURE="$W/proc"
  mkdir -p "$PROC_ROOT_FIXTURE/$LISTEN_PID"
  printf '%s (wa-fixture-stray) S 1 %s 1 0 -1 0\n' "$LISTEN_PID" "$LISTEN_PID" > "$PROC_ROOT_FIXTURE/$LISTEN_PID/stat"
  printf '%s\n' "$INSTALL_STRAY/wa" > "$PROC_ROOT_FIXTURE/$LISTEN_PID/exe"
  printf '%s\0serve\0--port\0%s\0' "$INSTALL_STRAY/wa" "$PORT" > "$PROC_ROOT_FIXTURE/$LISTEN_PID/cmdline"
  note "no /proc for pid $LISTEN_PID: the process naming is staged in $PROC_ROOT_FIXTURE (the port holder is real)"
else
  note "/proc/$LISTEN_PID is real: the process naming comes from the kernel"
fi

: > "$INSTALL_TARGET/deploy.log"
run_deploy "$unit_target" "$INSTALL_TARGET"
STRAY_REFUSAL="$(grep -m1 'cannot bind the port' <<<"$last_out")"
[ -n "$STRAY_REFUSAL" ] || printf '  note the deploy said this instead:\n%s\n' "$last_out"
ok "$([ "$last_exit" != "0" ] && [ -n "$STRAY_REFUSAL" ] && echo 1 || echo 0)" \
  "a deploy whose port is held by another process is refused" "exit $last_exit"
ok "$(grep -qF ":$PORT is held by pid $LISTEN_PID" <<<"$STRAY_REFUSAL" && echo 1 || echo 0)" \
  "the refusal names the process holding the port" "${STRAY_REFUSAL:0:120}"
ok "$(grep -q 'ppid' <<<"$STRAY_REFUSAL" && echo 1 || echo 0)" "it names the holder's parent"
ok "$(grep -qF "$INSTALL_TARGET" <<<"$STRAY_REFUSAL" && echo 1 || echo 0)" "and the install it disagrees with"
ok "$(grep -q 'deploy: building' <<<"$last_out" && echo 0 || echo 1)" "and it refused before the build"
if [ -n "$PROC_ROOT_FIXTURE" ]; then
  ok "$(grep -q 'ppid 1' <<<"$STRAY_REFUSAL" && grep -qF "$INSTALL_STRAY/wa" <<<"$STRAY_REFUSAL" && echo 1 || echo 0)" \
    "the stray is named by parent pid and by image, as the two-install case was"
fi

# Falsification 3: the same stray, against the same pinned baseline.
run_deploy "$unit_target" "$INSTALL_TARGET" "$W/deploy-baseline.sh"
ok "$(grep -q 'deploy: building' <<<"$last_out" && grep -q 'cannot bind' <<<"$last_out" && echo 0 || echo 1)" \
  "the deploy as it was before this check builds and installs with a stray on the port" "exit $last_exit"

# --- (c) no unit at all: the running process is the statement, and it is used ---------------------------
# The witness branch: on a machine with no unit this is the only place the answer can come from (it is the
# Windows case), and it must resolve the *running* node's directory, not a default. No WA_INSTALL_DIR, because
# a caller who has said where is a different case (the one above refuses when the two disagree).
run_deploy "$MISSING_UNIT" ""
ok "$(grep -q 'deploy: building' <<<"$last_out" && grep -q 'because the node on port' <<<"$last_out" && echo 1 || echo 0)" \
  "with no unit the deploy follows the node on the port and installs into that install" \
  "$(grep -m1 'installing into' <<<"$last_out")"
ok "$(grep -q 'cannot bind' <<<"$last_out" && echo 0 || echo 1)" "and it is not refused, because that node is the target"
[ -z "$(grep -m1 'because the node on port' <<<"$last_out")" ] && printf '  note the deploy said this instead:\n%s\n' "$last_out"

# --- (c) the agreeing case: the port is free, the unit names the install the deploy writes ----------------
kill "$LISTEN_PID" 2>/dev/null
kill "$STRAY_JOB" 2>/dev/null
STRAY_PID=""
for _ in $(seq 1 40); do [ -z "$(wa_port_pid "$PORT")" ] && break; sleep 0.1; done
: > "$INSTALL_TARGET/deploy.log"
run_deploy "$unit_target" "$INSTALL_TARGET"
ok "$(grep -qF "$INSTALL_TARGET is where the machine runs its node" <<<"$last_out" && echo 1 || echo 0)" \
  "with the unit and the target agreeing, the deploy says so at the start"
ok "$(grep -qF "nothing is listening on :$PORT" <<<"$last_out" && echo 1 || echo 0)" \
  "and it says the port is free before it goes near the install"
ok "$(grep -q 'deploy: building' <<<"$last_out" && grep -q 'different installs\|cannot bind' <<<"$last_out" && echo 0 || echo 1)" \
  "and it proceeds - the agreeing case is not refused" "exit $last_exit"
ok "$(grep -q 'note: no service definition' "$INSTALL_TARGET/deploy.log" 2>/dev/null && echo 0 || echo 1)" \
  "and no blind-gate note is recorded when the machine answered"

# --- the verifier asks the same question, so that \"what runs\" and \"what is verified\" are one directory --
run_verify() { # unit_file home_override
  ( cd "$TREE" && env -u WASM_AGENT_IN_TURN -u WASM_AGENT_HOME \
      HOME="$2" USERPROFILE="$2" WASM_AGENT_HOME="${3:-}" \
      WA_DEPLOY_ROOT="$TREE" WA_INSTALL_DIR="$INSTALL_TARGET" WA_PORT="$PORT" \
      WA_SERVICE_UNIT_FILE="$1" bash "$VERIFY" 2>&1 )
}
V_OUT="$(run_verify "$unit_service" "$INSTALL_HOME")"
V_LINE="$(grep -F 'the install is where the service runs it' <<<"$V_OUT" | head -1)"
ok "$(grep -q '^  FAIL the install is where the service runs it' <<<"$V_OUT" && echo 1 || echo 0)" \
  "the verifier fails when the install it read is not the one the service runs" "${V_LINE:0:120}"
ok "$(grep -qF "$INSTALL_SERVICE" <<<"$V_LINE" && grep -qF "$INSTALL_TARGET" <<<"$V_LINE" && echo 1 || echo 0)" \
  "naming both paths"

V_OUT="$(run_verify "$unit_target" "$INSTALL_HOME")"
ok "$(grep -q '^  ok   the install is where the service runs it' <<<"$V_OUT" && echo 1 || echo 0)" \
  "the verifier passes when they agree" "$(grep -F 'the install is where the service runs it' <<<"$V_OUT" | head -1 | cut -c1-110)"

pin_blob "$BASELINE_VERIFY_BLOB" "$W/verify-baseline.sh" 'where the service runs' "scripts/verify-install.sh"
OLD_OUT="$( ( cd "$TREE" && env -u WASM_AGENT_IN_TURN HOME="$INSTALL_HOME" USERPROFILE="$INSTALL_HOME" \
    WA_DEPLOY_ROOT="$TREE" WA_INSTALL_DIR="$INSTALL_TARGET" WA_PORT="$PORT" \
    WA_SERVICE_UNIT_FILE="$unit_service" bash "$W/verify-baseline.sh" 2>&1 ) )"
ok "$(grep -q 'where the service runs' <<<"$OLD_OUT" && echo 0 || echo 1)" \
  "the verifier as it was before this check has no opinion about it at all - the same disagreement verifies clean"

# --- the skills question is the same class, and the verifier now names both paths -----------------------
# Two directories, one of which the node reads: `<home>/.wasm-agent/skills` (paths.config() .. "/skills") and
# `<home>/skills`, which is where `upgrade.sh` writes when it runs with WASM_AGENT_HOME set - which every
# supervisor this project installs does (the sentinel unit on Linux, the launcher install-sentinel-task.ps1
# writes on Windows).
SKILL_HOME="$W/skill-home"
mkdir -p "$SKILL_HOME/.wasm-agent/skills/self-update" "$SKILL_HOME/skills/self-update"
printf 'what the node reads\n' > "$SKILL_HOME/.wasm-agent/skills/self-update/SKILL.md"
printf 'what a deploy wrote\n' > "$SKILL_HOME/skills/self-update/SKILL.md"
V_OUT="$(run_verify "$unit_target" "$SKILL_HOME" "$SKILL_HOME")"
S_LINE="$(grep -F 'the skills a deploy writes are the skills the node reads' <<<"$V_OUT" | head -1)"
ok "$(grep -q '^  FAIL the skills a deploy writes' <<<"$V_OUT" && echo 1 || echo 0)" \
  "a deploy writing skills outside the node's scan root is reported, not compared one-sided"
ok "$(grep -qF "$SKILL_HOME/skills" <<<"$S_LINE" && grep -qF "$SKILL_HOME/.wasm-agent/skills" <<<"$S_LINE" && echo 1 || echo 0)" \
  "naming where the deploy writes and where the node reads" "${S_LINE:0:130}"

# The same two directories, this time with WASM_AGENT_HOME unset - the way an operator at a shell has it, and
# the way a verifier would have missed this entirely if it trusted its own environment instead of the files.
V_OUT="$(run_verify "$unit_target" "$SKILL_HOME")"
ok "$(grep -q '^  FAIL the skills a deploy writes' <<<"$V_OUT" && echo 1 || echo 0)" \
  "with WASM_AGENT_HOME unset the durable trace is still found, not read off this shell" \
  "$(grep -F 'the skills a deploy writes' <<<"$V_OUT" | head -1 | cut -c1-120)"

rm -rf "$SKILL_HOME/skills"
V_OUT="$(run_verify "$unit_target" "$SKILL_HOME")"
ok "$(grep -q '^  ok   the skills a deploy writes are the skills the node reads' <<<"$V_OUT" && echo 1 || echo 0)" \
  "with nothing outside the scan root the two expressions name one directory, and the check says so" \
  "$(grep -F 'the skills a deploy writes are the skills the node reads' <<<"$V_OUT" | head -1 | cut -c1-120)"

printf '\n'
if [ "$failed" -eq 0 ]; then
  echo "deploy service-target ok ($checks checks)"
else
  echo "deploy service-target FAILED ($failed of $checks)"
fi
exit "$([ "$failed" -eq 0 ] && echo 0 || echo 1)"
