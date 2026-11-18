#!/usr/bin/env bash
# Every install path asks the same question, and none of them treats "I cannot tell" as free passage.
#
# WHAT THIS EXISTS FOR. The ancestry guard was added to deploy.sh first, and the other installers grew their own
# version of it - each with a hole of its own:
#
#   * fleet-install.sh and linux/bootstrap.sh asked only the binary, so a node whose binary predates
#     --build-info was replaced with NO question at all;
#   * upgrade.sh fell back to installed.txt's commit= without asking whether the record was about the running
#     bytes (wa_record_describes), so it compared the candidate against a commit that is not what is installed;
#   * every one of them answered a verdict of 2 ("cannot tell") with a note and then installed.
#
# The rule now: wa_running_identity (scripts/lib/install-record.sh) is the one answer to "what is running here",
# and an unknown refuses unless the operator says --force --reason <text>, which is recorded.
#
# The fleet path is exercised END TO END (curl file:// for the artifact, a stub binary as the artifact and as the
# running node, a local HTTP server for /health), because that path can be driven without building a node. The
# refusals stop before anything is replaced; the one case that installs does so into a scratch directory with
# pkill shadowed, so it cannot touch this machine's node.
#
# Usage:  bash scripts/test-install-guards.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
checks=0; failed=0
ok()   { checks=$((checks + 1)); printf '  ok   %s\n' "$*"; }
bad()  { checks=$((checks + 1)); failed=$((failed + 1)); printf '  FAIL %s\n' "$*"; }
same() { [ "$2" = "$3" ] && ok "$1 ($2)" || bad "$1: got '$2' want '$3'"; }
shows() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1: '$3' not found in '$(printf '%s' "$2" | head -3 | tr '\n' ' ')'" ;; esac; }
hides() { case "$2" in *"$3"*) bad "$1: '$3' should not be there" ;; *) ok "$1" ;; esac; }

WORK="$(mktemp -d)"; trap 'kill %1 %2 2>/dev/null; rm -rf "$WORK"' EXIT
SHIM="$WORK/bin"; mkdir -p "$SHIM"
# pkill is shadowed so a passing run cannot touch this machine's node; systemctl answers "no service here".
printf '#!/bin/sh\nexit 0\n' > "$SHIM/pkill"; chmod +x "$SHIM/pkill"
printf '#!/bin/sh\nexit 1\n' > "$SHIM/systemctl"; chmod +x "$SHIM/systemctl"
export PATH="$SHIM:$PATH"

H40="$(printf 'a%.0s' $(seq 1 40))"
# A stub standing in for a node binary: it reports a build, answers --contains with an exit code, and answers the
# installer's Lua probe with "ok" so the one case that installs reaches its record step.
stub() { # <path> <commit> <dirty> <contains-exit>
  { echo '#!/bin/sh'; echo 'case "$1" in';
    echo "  --build-info) printf 'version=9.9.9\\ncommit=$2\\ntree=$H40\\ndirty=$3\\nsource=git\\nbuilt_epoch=1\\nancestors=3\\nancestors_complete=true\\n' ;;";
    echo "  --contains) exit $4 ;;";
    echo "  --version) echo 'wasm-agent 9.9.9' ;;";
    echo '  *) echo ok ;;'; echo 'esac'; } > "$1"
  chmod +x "$1"
}

# A local /health that answers 200, so the one installing case can finish and write its record.
WEB="$WORK/web"; mkdir -p "$WEB"; printf 'ok\n' > "$WEB/health"
PORT=""
for candidate_port in 18911 18912 18913 18914 18915; do
  ( cd "$WEB" && exec python3 -m http.server "$candidate_port" --bind 127.0.0.1 >/dev/null 2>&1 ) &
  server_pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(curl -s -o /dev/null -m 1 -w '%{http_code}' "http://127.0.0.1:$candidate_port/health" 2>/dev/null)" = 200 ] && break
    sleep 0.3
  done
  if [ "$(curl -s -o /dev/null -m 1 -w '%{http_code}' "http://127.0.0.1:$candidate_port/health" 2>/dev/null)" = 200 ]; then
    PORT="$candidate_port"; break
  fi
  kill "$server_pid" 2>/dev/null
done
[ -n "$PORT" ] && ok "a local /health is serving on 127.0.0.1:$PORT" || bad "could not start a local /health server"

# WASM_AGENT_HOME: the node's own pin store lives under it (scripts/lib/node-pins.sh), and a scratch one keeps
# this test away from whatever this machine is actually pinned to.
FLEET_HOME=""
fleet() { # <install-dir> <artifact> <args...> -> FLEET_OUT, FLEET_RC
  local dir="$1" artifact="$2"; shift 2
  # env, not a bare assignment: ${FLEET_HOME:+...} is one word, and "VAR=value command" only works when it is a
  # command-prefix assignment rather than an argument.
  FLEET_OUT="$(env HEALTH="http://127.0.0.1:${PORT:-9}/health" HEALTH_WAIT=2 ${FLEET_HOME:+WASM_AGENT_HOME=$FLEET_HOME} \
    bash "$ROOT/scripts/fleet-install.sh" "file://$artifact" --bin "$dir/wa" "$@" 2>&1)"
  FLEET_RC=$?
}

echo "test-install-guards: fleet-install.sh - a record that is not about these bytes"
# The node's binary predates --build-info (so it cannot name its commit) and its installed.txt names another
# sha256. The record's commit= is not evidence about what is running, and this used to be free passage.
A="$WORK/a"; mkdir -p "$A"
printf '#!/bin/sh\nexit 1\n' > "$A/wa"; chmod +x "$A/wa"
printf 'commit=%s\nsha256=%s\n' "$(printf 'b%.0s' $(seq 1 40))" "$(printf 'c%.0s' $(seq 1 64))" > "$A/installed.txt"
stub "$WORK/artifact-ok" "$(printf 'd%.0s' $(seq 1 40))" false 0
fleet "$A" "$WORK/artifact-ok" --reason "an ordinary fleet install"
[ "$FLEET_RC" != 0 ] && ok "it refused (exit $FLEET_RC)" || bad "fleet-install replaced a node whose record describes other bytes"
shows "the refusal is by name" "$FLEET_OUT" "downgrade_unprovable(record_not_this_binary)"
same "nothing was installed" "$(cat "$A/wa" 2>/dev/null | head -1)" "#!/bin/sh"

echo "test-install-guards: fleet-install.sh - a running binary built from a dirty tree"
B="$WORK/b"; mkdir -p "$B"
stub "$B/wa" "$(printf 'e%.0s' $(seq 1 40))" true 0
stub "$WORK/artifact-newer" "$(printf 'f%.0s' $(seq 1 40))" false 0
fleet "$B" "$WORK/artifact-newer" --reason "an ordinary fleet install"
[ "$FLEET_RC" != 0 ] && ok "it refused (exit $FLEET_RC)" || bad "fleet-install replaced bytes carrying uncommitted work"
shows "the refusal is by name" "$FLEET_OUT" "downgrade_refused(dirty_running_binary)"

echo "test-install-guards: fleet-install.sh - an old binary with no record is a first install, not a refusal"
# The one case that is NOT ignorance: nothing here names a commit and nothing claims to.
FIRST="$WORK/first"; mkdir -p "$FIRST"
bash -c 'true'
# no binary and no record at all, so wa_running_identity answers "none"
fleet "$FIRST" "$WORK/artifact-ok" --reason "the first install on this machine"
hides "it did not refuse on ancestry" "$FLEET_OUT" "ancestry_unknown"
shows "it said the running side names no commit" "$FLEET_OUT" "first install"
same "...and it installed" "$( [ -x "$FIRST/wa" ] && echo yes || echo no)" "yes"
same "...and the record is the artifact's own build" "$(sed -n 's/^commit=//p' "$FIRST/installed.txt" 2>/dev/null)" "$(printf 'd%.0s' $(seq 1 40))"
shows "...and says ancestry=first_install" "$(cat "$FIRST/installed.txt" 2>/dev/null)" "ancestry=first_install"

echo "test-install-guards: fleet-install.sh - an artifact that cannot say whether it goes backwards"
C="$WORK/c"; mkdir -p "$C"
stub "$C/wa" "$(printf '1%.0s' $(seq 1 40))" false 0
stub "$WORK/artifact-blind" "$(printf '2%.0s' $(seq 1 40))" false 2
fleet "$C" "$WORK/artifact-blind" --reason "an ordinary fleet install"
[ "$FLEET_RC" != 0 ] && ok "it refused (exit $FLEET_RC)" || bad "fleet-install installed an artifact that cannot answer"
shows "the refusal is by name" "$FLEET_OUT" "refused(ancestry_unknown)"
shows "it quotes what could not be established" "$FLEET_OUT" "cannot answer"

echo "test-install-guards: fleet-install.sh - --force --reason goes on, and the record carries it"
D="$WORK/d"; mkdir -p "$D"
stub "$D/wa" "$(printf '3%.0s' $(seq 1 40))" false 0
fleet "$D" "$WORK/artifact-blind" --reason "the older release is what this node must run"
[ "$FLEET_RC" != 0 ] && ok "a --force --reason install without --force still refused (exit $FLEET_RC)" || bad "a bare --reason overrode the refusal"
fleet "$D" "$WORK/artifact-blind" --force --reason "the older release is what this node must run"
same "--force --reason installs -> 0" "$FLEET_RC" "0"
shows "it said the override out loud" "$FLEET_OUT" "OVERRIDE, recorded"
shows "...and recorded who/why/when" "$FLEET_OUT" "force_requested reason=the older release is what this node must run"
shows "the install record carries the override" "$(cat "$D/installed.txt" 2>/dev/null)" "ancestry=override"
shows "...with the reason" "$(cat "$D/installed.txt" 2>/dev/null)" "ancestry_override=the older release is what this node must run"
shows "...and the commit the artifact reports" "$(cat "$D/installed.txt" 2>/dev/null)" "commit=$(printf '2%.0s' $(seq 1 40))"

echo "test-install-guards: fleet-install.sh - the node's OWN pin refuses the install"
# A pin in the coordinator's store gates requests made through that coordinator; an install started HERE read
# nothing, which is how the three hand-made rollbacks of 18/11 were undone. The node keeps its own copy, and this
# is the path that reads it. The pin names the node by its NAME and its ID, and both spellings find it.
FLEET_HOME="$WORK/pinhome"; mkdir -p "$FLEET_HOME/.wasm-agent"
printf 'testnode\n' > "$FLEET_HOME/.wasm-agent/node.name"
printf 'schema=wasm-agent-pins/1\nid=aaaa1111\nnode=testnode\nnode_id=node-77\nkind=rollback\nstate=active\ncommit=unknown\nrolled_back_from=%s\nreason=held where the operator put it\nawait=%s\n\n' \
  "$(printf '4%.0s' $(seq 1 40))" "$(printf '4%.0s' $(seq 1 40))" > "$FLEET_HOME/.wasm-agent/pins.txt"
E="$WORK/e"; mkdir -p "$E"
stub "$E/wa" "$(printf '5%.0s' $(seq 1 40))" false 0
fleet "$E" "$WORK/artifact-ok" --reason "an ordinary fleet install"
[ "$FLEET_RC" != 0 ] && ok "it refused (exit $FLEET_RC)" || bad "fleet-install moved a node that carries its own pin"
shows "the refusal is by name" "$FLEET_OUT" "node_pinned"
shows "it quotes the pin" "$FLEET_OUT" "held where the operator put it"
shows "it names the ways out" "$FLEET_OUT" "--unpin"
FLEET_HOME="$WORK/pinhome-by-id"; mkdir -p "$FLEET_HOME/.wasm-agent"
printf 'othername\n' > "$FLEET_HOME/.wasm-agent/node.name"
printf 'schema=wasm-agent-pins/1\nid=bbbb2222\nnode=somebody-else\nnode_id=othername\nkind=pin\nstate=active\ncommit=unknown\nreason=found by the id\n\n' > "$FLEET_HOME/.wasm-agent/pins.txt"
F2="$WORK/e2"; mkdir -p "$F2"
stub "$F2/wa" "$(printf '6%.0s' $(seq 1 40))" false 0
fleet "$F2" "$WORK/artifact-ok" --reason "an ordinary fleet install"
[ "$FLEET_RC" != 0 ] && ok "a pin is found by the node id even when the name does not match" || bad "a pin recorded under the node id was not found"
shows "...and the refusal names it" "$FLEET_OUT" "found by the id"
FLEET_HOME="$WORK/pinhome"
fleet "$E" "$WORK/artifact-ok" --force --reason "the operator decides this node moves anyway"
same "--force --reason installs over the node's own pin -> 0" "$FLEET_RC" "0"
shows "...saying the override out loud" "$FLEET_OUT" "OVERRIDE, recorded"
shows "...and the install record carries it" "$(cat "$E/installed.txt" 2>/dev/null)" "ancestry=override"
FLEET_HOME=""

echo "test-install-guards: fleet-install.sh - a binary that cannot name its commit is UNKNOWN (item 1)"
# Round 3 of the review: "nothing names a commit" was read as "a first install", so an install whose binary
# predates --build-info (and whose record carries no sha256=) was replaced with no ancestry question at all.
C="$WORK/c"; mkdir -p "$C"
printf '#!/bin/sh\nexit 1\n' > "$C/wa"; chmod +x "$C/wa"
fleet "$C" "$WORK/artifact-ok" --reason "an ordinary fleet install"
[ "$FLEET_RC" != 0 ] && ok "it refused (exit $FLEET_RC)" || bad "fleet-install replaced a binary nothing could identify"
shows "the refusal is by name" "$FLEET_OUT" "refused(running_commit_unprovable)"
shows "it says something IS installed" "$FLEET_OUT" "Something IS installed here"
hides "...and it does not call it a first install" "$FLEET_OUT" "a first install, not a downgrade"
same "nothing was installed" "$(head -1 "$C/wa")" "#!/bin/sh"

echo "test-install-guards: fleet-install.sh - a record with commit= and no sha256= is not evidence (item 1)"
D="$WORK/d"; mkdir -p "$D"
printf '#!/bin/sh\nexit 1\n' > "$D/wa"; chmod +x "$D/wa"
printf 'commit=%s\nvia=linux-bootstrap\n' "$(printf 'e%.0s' $(seq 1 40))" > "$D/installed.txt"
D_BEFORE="$(cat "$D/installed.txt")"
fleet "$D" "$WORK/artifact-ok" --reason "an ordinary fleet install"
[ "$FLEET_RC" != 0 ] && ok "it refused (exit $FLEET_RC)" || bad "a record with no sha256= was trusted"
shows "the refusal is by name" "$FLEET_OUT" "refused(running_commit_unprovable)"
shows "it names the missing sha256" "$FLEET_OUT" "no sha256="
same "the record was not touched" "$(cat "$D/installed.txt")" "$D_BEFORE"
fleet "$D" "$WORK/artifact-ok" --force --reason "the rebuilt artifact is newer than anything on that box"
hides "with --force --reason it goes on" "$FLEET_OUT" "refused(running_commit_unprovable)"
shows "the record names the artifact's own build" "$(sed -n 's/^commit=//p' "$D/installed.txt" 2>/dev/null)" "$(printf 'd%.0s' $(seq 1 40))"

echo "test-install-guards: fleet-install.sh - a missing pin reader is a refusal, not a skip (item 6)"
# The gate used to be wrapped in "if [ -n "$NODE_PIN_LIB" ]": a copy of this script that could not find
# scripts/lib/node-pins.sh SKIPPED the pin silently. It refuses now, before anything is replaced.
ALONE="$WORK/alone"; mkdir -p "$ALONE/lib"
cp "$ROOT/scripts/fleet-install.sh" "$ALONE/fleet-install.sh"
# the record lib is there; the PIN reader is what is missing, which is the case this is about
cp "$ROOT/scripts/lib/install-record.sh" "$ALONE/lib/install-record.sh"
E="$WORK/e"; mkdir -p "$E"
printf '#!/bin/sh\nexit 1\n' > "$E/wa"; chmod +x "$E/wa"
E_OUT="$(env HEALTH="http://127.0.0.1:9/health" HEALTH_WAIT=1 WA_NODE_PINS_LIB=/nonexistent/node-pins.sh \
  bash "$ALONE/fleet-install.sh" "file://$WORK/artifact-ok" --bin "$E/wa" --reason "an ordinary fleet install" 2>&1)"; E_RC=$?
[ "$E_RC" != 0 ] && ok "a copy with no pin reader refuses (exit $E_RC)" || bad "a copy with no pin reader installed anyway"
shows "the refusal is by name" "$E_OUT" "node_pins_lib_missing"
shows "...and says nothing was installed" "$E_OUT" "nothing was installed"
same "the running binary was not replaced" "$(head -1 "$E/wa")" "#!/bin/sh"
grep -qF 'NODE_PIN_LIB:-}" ]; then' "$ROOT/scripts/fleet-install.sh" \
  && bad "the pin gate is still wrapped in a skip" || ok "the pin gate no longer has a skip path"

echo "test-install-guards: upgrade.sh and bootstrap.sh ask the same question (structural)"
# These two cannot be run here without building a node (they install one), so what is asserted is that they route
# through the same identity function and the same refusals - and that neither still says "carrying on".
for script in scripts/upgrade.sh scripts/linux/bootstrap.sh scripts/fleet-install.sh scripts/deploy.sh; do
  if grep -q 'wa_running_identity' "$ROOT/$script"; then ok "$script asks wa_running_identity"; else bad "$script has its own idea of what is running"; fi
done
for script in scripts/upgrade.sh scripts/linux/bootstrap.sh scripts/fleet-install.sh; do
  if grep -qE 'refused\(ancestry_unknown\)|ancestry_unknown' "$ROOT/$script"; then ok "$script refuses an unknown verdict by name"; else bad "$script still installs on an unknown verdict"; fi
  if grep -q 'cannot tell whether this' "$ROOT/$script" && grep -q 'carrying on' "$ROOT/$script"; then bad "$script still carries on past a 'cannot tell'"; else ok "$script does not carry on past a 'cannot tell'"; fi
done
grep -q 'wa_record_describes' "$ROOT/scripts/lib/install-record.sh" && ok "the record-vs-bytes check is the shared one" || bad "no shared record-vs-bytes check"
if grep -qE '^FORCE=0; REASON=""' "$ROOT/scripts/fleet-install.sh"; then bad "fleet-install.sh still wipes --force/--reason after parsing them"; else ok "fleet-install.sh keeps the --force/--reason it parsed"; fi


echo "test-install-guards: no backticks inside a double-quoted message (they run)"
# bootstrap.sh refused a downgrade with:  fail "... the sentinel's `wa update <node> --rollback` (it records a pin) ..."
# Between DOUBLE quotes that is a command substitution: the refusal RAN 'wa update <node> --rollback' as a command
# and put its output in the middle of the sentence, on the one path where the node is already in trouble. A
# message is quoted with ' or with escaped backticks; it is never executed.
FIXTURE="$WORK/backtick-fixture.sh"
printf '%s\n' 'fail "use the sentinel'"'"'s `wa update <node> --rollback` (it records a pin)"' > "$FIXTURE"
if grep -qE '(fail|say|die|note|printf|echo) "[^"]*`' "$FIXTURE"; then ok "the check catches the shape that was shipped"; else bad "the check does not catch a backtick inside a double-quoted message"; fi
if grep -nE '(fail|say|die|note|printf|echo) "[^"]*`' "$ROOT"/scripts/deploy.sh "$ROOT"/scripts/upgrade.sh \
     "$ROOT"/scripts/fleet-install.sh "$ROOT"/scripts/linux/bootstrap.sh "$ROOT"/scripts/publish-node-binaries.sh \
     "$ROOT"/scripts/publish-components.sh "$ROOT"/scripts/rollback-node.sh "$ROOT"/scripts/lib/*.sh 2>/dev/null; then
  bad "an installer still runs a command inside a message (backticks in double quotes)"
else
  ok "no installer message runs a command"
fi

printf 'test-install-guards: %s checks, %s failed\n' "$checks" "$failed"
[ "$failed" = 0 ] || exit 1
