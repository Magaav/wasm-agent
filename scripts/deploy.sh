#!/usr/bin/env bash
# Deploy a node: the one gate through which a build becomes the installed one.
#
#   bash scripts/deploy.sh [--reason "why"] [--session <id> --prompt "continue with…"]
#
# The tree it builds from is `..` when this script is run from a worktree, `WA_DEPLOY_ROOT` if that is set,
# and otherwise the runtime worktree recorded in <install>/runtime-worktree.txt. The last case is not a
# convenience: `request deploy` runs the copy installed beside the supervisor, whose parent is the install
# directory, so `..` alone is never a worktree there.
#
# Why this exists. Two parties install this node - the operator and the agent working in it - and for a day
# they installed over each other: the agent rebuilt from its worktree while a fix was being deployed from
# another, so "what is running" and "what is in main" disagreed, and a bug was diagnosed twice from a binary
# that did not contain the instrumentation meant to find it. That is not a code bug, it is a missing gate.
#
# So installing goes through here, and here refuses to install something that cannot be explained:
#
#   1. the tree must be clean - an install from a half-edited tree is a build nobody can reproduce;
#   2. the tree must not be behind origin/main - a node that cannot see main cannot see its own fixes, and
#      installing from a stale branch is how a node served a diff route that answered unknown_action:patch;
#   3. the install must not be a downgrade - this tree must contain the commit installed.txt names. Rules 1
#      and 2 are both about *this* tree, so neither had an opinion about the install being replaced, and a
#      deploy from main silently undid three fixes that were ahead of main (the whole story is at step 3);
#   4. the build must answer /health on a scratch port before it goes near the running node;
#   5. the restart is upgrade.sh's job, because it already waits for idle, stops by pid, verifies and rolls
#      back - and because the first version of this script reimplemented it, stopped one of two listeners on
#      the port, failed to bind, and then reported success because the *other* node answered /health. The
#      verification was reading someone else's outcome, which is the trap this project keeps writing down;
#   6. what was installed is recorded, and the pid answering must be the pid the install recorded.
set -uo pipefail

REASON=""
SESSION=""
PROMPT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --reason) REASON="${2:-}"; shift 2 ;;
    --session) SESSION="${2:-}"; shift 2 ;;
    --prompt) PROMPT="${2:-}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

INSTALL_DIR="${WA_INSTALL_DIR:-$HOME/AppData/Local/wasm-agent}"
[ -d "$INSTALL_DIR" ] || INSTALL_DIR="${WA_INSTALL_DIR:-$HOME/.local/share/wasm-agent}"
PORT="${WA_PORT:-8799}"
CLIENT_PORT="${WA_CLIENT_PORT:-8800}"
SENTINEL_CONFIG="${WASM_AGENT_HOME:-${USERPROFILE:-$HOME}}/.wasm-agent"

# The sentinel executes `run` scripts only from directories named here, and the install's own scripts (the
# whatsapp hooks, the preflight) live in <install>/scripts. Without this, every job whose action is `run`
# fails with "run is disabled: set WA_SENTINEL_SCRIPTS" - which is exactly how whatsapp-ingest was failing.
# Export it so the watcher this deploy starts or restarts inherits it; the service unit and the logon task
# set it too, because a watcher not started by this script must still have it.
#
# The path must be in the native form: the sentinel is a native Windows process, and a POSIX `/c/...`
# canonicalizes against `C:` into a directory that does not exist, after which every script is refused as
# "not inside WA_SENTINEL_SCRIPTS". This is the project's oldest trap, applied to itself.
WA_SCRIPTS_DIR="$INSTALL_DIR/scripts"
command -v cygpath >/dev/null 2>&1 && WA_SCRIPTS_DIR="$(cygpath -w "$WA_SCRIPTS_DIR")"
export WA_SENTINEL_SCRIPTS="${WA_SENTINEL_SCRIPTS:-$WA_SCRIPTS_DIR}"

# A machine-readable result, written on both sides of the outcome. `installed.txt` says what is installed;
# this says what the *deploy* did, so a woken run reads one small file instead of re-deriving the answer
# from installed.txt, deploy.log, hashes and the sentinel status. `fail` writes it too, so a refusal is a
# result and not only a log line.
write_result() { # ok detail
  _esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\r\n' '  '; }
  printf '{"ok":%s,"commit":"%s","branch":"%s","node_sha256":"%s","sentinel_sha256":"%s","watcher_pid":"%s","detail":"%s","reason":"%s","at":"%s"}\n' \
    "$1" "${COMMIT:-}" "${BRANCH:-}" "${HASH:-}" "${SENTINEL_HASH:-}" \
    "${SENTINEL_NEW_PID:-${SENTINEL_WATCH_PID:-}}" "$(_esc "$2")" "$(_esc "$REASON")" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$INSTALL_DIR/deploy-result.json" 2>/dev/null || true
}

# A refusal is evidence: the gate saying no, with a reason, at a moment. Printing to stderr is not enough -
# after the fact, "did it refuse anything?" has to be answerable. Every refusal is appended to
# <install>/deploy.log with the time, what it was about, and why.
fail() {
  echo "deploy: $*" >&2
  printf '%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${COMMIT:-unknown}" "${BRANCH:-unknown}" "$*" \
    >> "$INSTALL_DIR/deploy.log" 2>/dev/null
  write_result false "$*"
  # A requested deploy is answered, including when the answer is no. This is the other half of the wake
  # below: that one says the install landed, and without this one a deploy that failed *before* the swap
  # told nobody - the request was already `done` (it had been spawned), the node was untouched, and the
  # only trace was a line in deploy.log nobody had a reason to read. A hand-run deploy passes no --session
  # and wakes nobody: a refusal at a shell is read by the person at the shell.
  # The wording claims nothing about the install, because `fail` is reached on both sides of the swap.
  if [ -n "${SESSION:-}" ]; then
    FAIL_SENTINEL="${INSTALL_DIR:-}/wa-sentinel.exe"
    [ -x "$FAIL_SENTINEL" ] || FAIL_SENTINEL="${INSTALL_DIR:-}/wa-sentinel"
    if [ -x "$FAIL_SENTINEL" ]; then
      if "$FAIL_SENTINEL" request wake --session "$SESSION" \
        --prompt "The deploy you requested failed: $*  Nothing is claimed here about what is installed - $INSTALL_DIR/installed.txt and $INSTALL_DIR/deploy.log are the evidence. Fix the cause, then request deploy again." \
        --reason "deploy failed: $*" >/dev/null 2>&1; then
        echo "deploy: failure reported to $SESSION" >&2
      else
        echo "deploy: WARNING could not report the failure to $SESSION" >&2
      fi
    fi
  fi
  exit 1
}

# The other half of "a refusal is evidence": a check that *could not run* is evidence too, and it must look
# like neither a refusal nor silence. A gate that goes blind quietly is worse than one that refuses, because
# nothing afterwards can tell that it never had an opinion. `note` records the same line as `fail` with a
# `note:` marker, so "was the gate blind that day?" is answerable from the same file.
note() {
  echo "deploy: $*"
  printf '%s\t%s\t%s\tnote: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${COMMIT:-unknown}" "${BRANCH:-unknown}" "$*" \
    >> "$INSTALL_DIR/deploy.log" 2>/dev/null
}

if [ "${WASM_AGENT_IN_TURN:-}" = "1" ]; then
  fail "cannot deploy from a running turn: it cannot become idle while this command waits. Build, then request an upgrade through wa-sentinel; see skills/self-update/SKILL.md"
fi

# Which tree does this deploy build from? `dirname $0/..` is a worktree only when this script is run from
# one, and the sentinel's `deploy` verb runs the copy installed beside the supervisor - whose parent is the
# install directory. Resolve it the way upgrade.sh resolves the runtime worktree, and refuse loudly rather
# than build something that cannot say what it is.
resolve_root() {
  if [ -n "${WA_DEPLOY_ROOT:-}" ]; then printf '%s' "$WA_DEPLOY_ROOT"; return; fi
  local beside=""
  beside="$(cd "$(dirname "$0")/.." && pwd)"
  if git -C "$beside" rev-parse --is-inside-work-tree >/dev/null 2>&1; then printf '%s' "$beside"; return; fi
  local recorded=""
  if [ -f "$INSTALL_DIR/runtime-worktree.txt" ]; then
    recorded="$(tr -d '\r\n' < "$INSTALL_DIR/runtime-worktree.txt")"
  fi
  case "$recorded" in
    *\\*)
      if command -v cygpath >/dev/null 2>&1; then recorded="$(cygpath -u "$recorded")"; fi ;;
  esac
  if [ -n "$recorded" ] && git -C "$recorded" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '%s' "$recorded"; return
  fi
  printf ''
}
ROOT="$(resolve_root)"
[ -n "$ROOT" ] || fail "cannot tell which worktree to deploy from: run this script from one, set WA_DEPLOY_ROOT, or record it in $INSTALL_DIR/runtime-worktree.txt - a deploy that cannot say what it builds does not build"
[ -d "$ROOT" ] || fail "the worktree to deploy from does not exist: $ROOT"
cd "$ROOT" || fail "cannot enter the worktree to deploy from: $ROOT"

# 1. Clean. A build from a half-edited tree is not reproducible, and the file being edited is often the one
#    that matters.
DIRTY="$(git status --porcelain | wc -l | tr -d ' ')"
[ "$DIRTY" = "0" ] || fail "the tree has $DIRTY uncommitted change(s); commit or stash them first"

# 2. Current. Behind main is the failure this project has paid for repeatedly.
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git fetch -q origin 2>/dev/null || true
if git rev-parse --verify -q origin/main >/dev/null; then
  BEHIND="$(git rev-list --count HEAD..origin/main 2>/dev/null || echo 0)"
  [ "$BEHIND" = "0" ] || fail "this tree is $BEHIND commit(s) behind origin/main; merge main first (a node that cannot see main cannot see its own fixes)"
  # ... and a tree AHEAD of main is the other half of the same failure. An unmerged `change/`
  # branch deploys fine, and then main lags the live binary, so the next main-side deploy is
  # refused as a downgrade - measured twice in one day (8c13f19, 4d4753f). The live install
  # must be a commit that is on main: merge the change first. A scratch WA_INSTALL_DIR is a
  # test, not the operator's node, so it is exempt from this rule.
  if [ -z "${WA_INSTALL_DIR:-}" ]; then
    git merge-base --is-ancestor HEAD origin/main 2>/dev/null \
      || fail "this tree's commit $(git rev-parse --short HEAD) is not on origin/main; merge it to main and deploy from there - an unmerged deploy leaves main behind the live node"
  fi
fi
COMMIT="$(git rev-parse --short HEAD)"

echo "deploy: $BRANCH@$COMMIT -> $INSTALL_DIR (port $PORT)"

# 3. Never replace something better with something worse.
#
# The gap this closes, and it was not hypothetical. Rules 1 and 2 ask about *this* tree - is it clean, does
# it see main - and neither had any opinion about the install being replaced, so "deploy the newer thing" and
# "deploy the older thing" were the same command. A deploy from main then replaced an install built from a
# branch that was ahead of main, and silently undid three fixes: the in-turn refusal, installed.txt's
# via=/upgrade_sha256=/source_provenance=, and the sentinel's capture of the upgrade's own output. Nothing
# failed, nothing was recorded, and the only way to see it was to compare hashes by hand.
#
# The rule is ancestry, not equality. A deploy may move the install forward, or install the same commit
# again, but not to a commit that does not contain what is installed. A deliberate rollback is still
# possible - it is upgrade.sh's job, which takes an explicit binary, so the intent is on the command line
# instead of being inferred from whichever branch happens to be checked out.
INSTALLED_COMMIT="$(sed -n 's/^commit=//p' "$INSTALL_DIR/installed.txt" 2>/dev/null | head -1 | tr -d '[:space:]')"
if [ -z "$INSTALLED_COMMIT" ]; then
  # Nothing to compare against, and the two reasons are different things: no record at all is a first
  # install, while a record without a commit= line is a record that does not say. Neither is a downgrade.
  # Refusing because the answer is unknown would block the first install on a machine that never had one.
  if [ -f "$INSTALL_DIR/installed.txt" ]; then
    note "$INSTALL_DIR/installed.txt names no commit; cannot tell what is installed, so this is not treated as a downgrade"
  else
    echo "deploy: no install record at $INSTALL_DIR/installed.txt - first install, not a downgrade"
  fi
elif ! git cat-file -e "${INSTALLED_COMMIT}^{commit}" 2>/dev/null; then
  # A commit this tree does not have: a shallow clone, a different repository, or a branch that was never
  # fetched. Say which case it is and carry on. The gate cannot compare what it cannot resolve, and a refusal
  # here would be a refusal about its own ignorance rather than about the deploy.
  note "the install records commit $INSTALLED_COMMIT, which this tree does not have (shallow clone, different repository, or an unfetched branch); cannot tell whether this would be a downgrade"
elif ! git merge-base --is-ancestor "$INSTALLED_COMMIT" HEAD 2>/dev/null; then
  fail "downgrade refused: the install is commit $INSTALLED_COMMIT and this tree is $COMMIT, which does not contain it - deploying would replace newer work with older work"
fi

# 4. Build.
echo "deploy: building"
( cd rust && cargo build --release --offline -p wa-host ) || fail "the build failed"
# The sentinel is its own crate, outside the `rust/` workspace (which lists only `wa-host`), so it is
# built with its own manifest. Asking the workspace for `-p wa-sentinel` fails - "package ID
# specification did not match any packages" - and that is how it came to be installed by hand at all.
( cd rust && cargo build --release --offline --manifest-path wa-sentinel/Cargo.toml ) || fail "the sentinel build failed"
NEW="rust/target/release/wa.exe"
[ -f "$NEW" ] || NEW="rust/target/release/wa"
[ -x "$NEW" ] || fail "no built binary at $NEW"

# The supervisor is part of what this installs, and leaving it out is how the node and the thing that
# restarts it drifted apart: `deploy.sh` replaced `wa.exe` while `wa-sentinel.exe` stayed at whatever
# version was last placed by hand, so a fixed stop/start path sat in the repo uninstalled and the
# e2e test refused to run - "the installed sentinel is the one just built" is a check the test makes
# and the gate did not. The sentinel is the only process that can replace the node; shipping the node
# without shipping it is shipping half a node.
NEW_SENTINEL="rust/wa-sentinel/target/release/wa-sentinel.exe"
[ -f "$NEW_SENTINEL" ] || NEW_SENTINEL="rust/wa-sentinel/target/release/wa-sentinel"
[ -x "$NEW_SENTINEL" ] || fail "no built sentinel at $NEW_SENTINEL"
NEW_SENTINEL_LOWER="$(echo "$NEW_SENTINEL" | tr '[:upper:]' '[:lower:]')"
case "$NEW_SENTINEL_LOWER" in
  *.exe) SENTINEL_NAME="wa-sentinel.exe" ;;
  *)     SENTINEL_NAME="wa-sentinel" ;;
esac

# 5. Prove it answers before it goes near the running node. A build that cannot start must not replace one
#    that is serving.
SCRATCH=$((PORT + 40))
SCRATCH_HOME="$(mktemp -d)"
WASM_AGENT_HOME="$SCRATCH_HOME" "$NEW" serve --port "$SCRATCH" --client-port "$((SCRATCH + 1))" --ui "$ROOT/ui" >"$SCRATCH_HOME/out.log" 2>&1 &
SCRATCH_PID=$!
ANSWERED=0
for _ in $(seq 1 100); do
  if ! kill -0 "$SCRATCH_PID" 2>/dev/null; then break; fi
  if curl -fsS -o /dev/null -m 2 "http://127.0.0.1:$SCRATCH/health" 2>/dev/null && curl -fsS -o /dev/null -m 2 "http://127.0.0.1:$SCRATCH/" 2>/dev/null; then ANSWERED=1; break; fi
  sleep 0.1
done
kill "$SCRATCH_PID" 2>/dev/null
wait "$SCRATCH_PID" 2>/dev/null
rm -rf "$SCRATCH_HOME"
[ "$ANSWERED" = "1" ] || fail "the new binary did not answer /health on the scratch port; not installing it"
echo "deploy: the new binary answers on a scratch port"

# 6. Install and restart, through the script that owns that job.
UPGRADE="$ROOT/scripts/upgrade.sh"
[ -f "$UPGRADE" ] || fail "no scripts/upgrade.sh to perform the install"
echo "deploy: installing through upgrade.sh"
# Persist only the explicitly selected runtime location; never move its git branch.
if [ -n "${WA_RUNTIME_WORKTREE:-}" ]; then
  [ -d "$WA_RUNTIME_WORKTREE" ] || fail "runtime worktree does not exist"
  RUNTIME_PATH="$(cd "$WA_RUNTIME_WORKTREE" && pwd)"
  command -v cygpath >/dev/null 2>&1 && RUNTIME_PATH="$(cygpath -w "$RUNTIME_PATH")"
  if [ -f "$INSTALL_DIR/runtime-worktree.txt" ]; then
    cp -f "$INSTALL_DIR/runtime-worktree.txt" "$INSTALL_DIR/runtime-worktree.txt.pre-upgrade" || fail "cannot back up runtime location"
  fi
  printf '%s\n' "$RUNTIME_PATH" > "$INSTALL_DIR/runtime-worktree.txt" || fail "cannot record runtime location"
fi
WA_INSTALL_DIR="$INSTALL_DIR" WA_PORT="$PORT" WA_CLIENT_PORT="$CLIENT_PORT" \
  WA_UPGRADE_REASON="$REASON" WA_UPGRADE_VIA=deploy.sh \
  # upgrade.sh writes to a *file*, not into a pipe. A deploy runs detached, and a detached process's stdout
  # belongs to whoever spawned it - so when that parent went away, a write into the pipe raised SIGPIPE and
  # upgrade.sh died with exit 141 before it could say what it was doing. That transcript is also the evidence
  # that was missing: the failure was reported and nothing could say why.
  bash "$UPGRADE" "$(cd "$(dirname "$NEW")" && pwd)/$(basename "$NEW")" > "$INSTALL_DIR/deploy-upgrade.log" 2>&1
UPGRADE_STATUS=$?
# Reporting must never fail the deploy: with stdout gone, `sed` dies of EPIPE and pipefail would then report
# its status instead of upgrade.sh's.
sed "s/^/  upgrade: /" "$INSTALL_DIR/deploy-upgrade.log" 2>/dev/null | tail -20 || true
if [ "$UPGRADE_STATUS" = "3" ]; then
  fail "the node upgraded, but its script or install record failed (exit 3); inspect the live pid and installed.txt"
fi
[ "$UPGRADE_STATUS" = "0" ] || fail "upgrade.sh failed (exit $UPGRADE_STATUS); its own output is in $INSTALL_DIR/deploy-upgrade.log"

# 7. Verify that the node answering is *this* install: the listener's pid must be the pid the install
#    recorded. Without this, a second node on the port answers /health and the deploy reports success for
#    work it did not do.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*)
    LISTENER="$(netstat -ano -p TCP 2>/dev/null | awk -v p=":$PORT" '$1=="TCP" && $2 ~ p"$" && $4=="LISTENING" { print $5; exit }' | tr -d '\r')" ;;
  *)
    LISTENER="$(ss -ltnp 2>/dev/null | awk -v p=":$PORT" '$4 ~ p"$" { if (match($0,/pid=[0-9]+/)) { print substr($0,RSTART+4,RLENGTH-4); exit } }')" ;;
esac
RECORDED="$(tr -d '[:space:]' < "$INSTALL_DIR/serve.pid" 2>/dev/null)"
if [ -z "$RECORDED" ] || [ -z "$LISTENER" ] || [ "$RECORDED" != "$LISTENER" ]; then
  fail "the node answering on $PORT is pid $LISTENER, not the pid $RECORDED the install recorded - two nodes, one port"
fi
# An accumulated node.log can contain a bind error from a previous deployment.
# The recorded child owning this listener is the current startup verdict; a
# historical string is not evidence about that process. Also verify its artifact.
INSTALLED_NODE="$INSTALL_DIR/$(basename "$NEW")"
cmp -s "$NEW" "$INSTALLED_NODE" || fail "installed binary differs from the proved build"

# 8. Record what is installed, so "what is running" is answerable.
HASH="$(sha256sum < "$INSTALLED_NODE" 2>/dev/null | awk '{print $1}')"
[ -n "$HASH" ] || HASH="$(shasum -a 256 < "$INSTALLED_NODE" 2>/dev/null | awk '{print $1}')"

# The supervisor, installed *after* the node is confirmed answering - so a failed upgrade leaves a
# sentinel that still matches the node it supervises, rather than one rebuilt ahead of a node that
# rolled back. A running sentinel holds its own image open on Windows, so the copy is attempted and
# its failure is reported rather than fatal: the swap is completed by the one-shot restart below.
SENTINEL_HASH="(none)"
if [ -f "$INSTALL_DIR/$SENTINEL_NAME" ]; then
  cp -f "$NEW_SENTINEL" "$INSTALL_DIR/$SENTINEL_NAME" 2>/dev/null || true
  if cmp -s "$NEW_SENTINEL" "$INSTALL_DIR/$SENTINEL_NAME"; then
    echo "deploy: sentinel $SENTINEL_NAME updated"
  else
    # The file is locked by the running supervisor. Stop it, replace it, start it again - the verb
    # that exists for exactly this, and the reason it is not done by hand.
    OLD_SENTINEL_PID="$(netstat -ano -p TCP 2>/dev/null | awk -v p=":$PORT" '$1=="TCP" && $2 ~ p"$" && $4=="LISTENING" { print $5; exit }' | tr -d '\r')"
    if [ -f "$INSTALL_DIR/$SENTINEL_NAME" ]; then
      "$INSTALL_DIR/$SENTINEL_NAME" stop >/dev/null 2>&1 || true
      sleep 2
      cp -f "$NEW_SENTINEL" "$INSTALL_DIR/$SENTINEL_NAME" 2>/dev/null || true
      "$INSTALL_DIR/$SENTINEL_NAME" start >/dev/null 2>&1 || true
    fi
    if cmp -s "$NEW_SENTINEL" "$INSTALL_DIR/$SENTINEL_NAME"; then
      echo "deploy: sentinel $SENTINEL_NAME updated (restarted past the file lock)"
    else
      fail "could not install $SENTINEL_NAME - it is still the old build; the node and its supervisor would disagree"
    fi
  fi
  SENTINEL_HASH="$(sha256sum < "$INSTALL_DIR/$SENTINEL_NAME" 2>/dev/null | awk '{print $1}')"
  [ -n "$SENTINEL_HASH" ] || SENTINEL_HASH="$(shasum -a 256 < "$INSTALL_DIR/$SENTINEL_NAME" 2>/dev/null | awk '{print $1}')"
else
  cp -f "$NEW_SENTINEL" "$INSTALL_DIR/$SENTINEL_NAME" 2>/dev/null || fail "could not place $SENTINEL_NAME"
  echo "deploy: sentinel $SENTINEL_NAME installed"
  SENTINEL_HASH="$(sha256sum < "$INSTALL_DIR/$SENTINEL_NAME" 2>/dev/null | awk '{print $1}')"
fi

# Replacing an executable file does not replace the already-running process.
# Even when the copy succeeds on Windows, a watcher can keep executing the old
# image indefinitely. Respect an intentionally stopped watcher; restart only
# one that was already watching, then prove its pid changed.
SENTINEL_WATCH_PID="$("$INSTALL_DIR/$SENTINEL_NAME" status 2>/dev/null \
  | awk '$1=="sentinel:" && $2=="watching" {gsub(/[^0-9]/,"",$4); print $4; exit}')"
if [ -n "$SENTINEL_WATCH_PID" ]; then
  echo "deploy: restarting the watching sentinel to load the installed image"
  "$INSTALL_DIR/$SENTINEL_NAME" restart || fail "node installed, but the sentinel could not restart"
  SENTINEL_NEW_PID=""
  for _ in $(seq 1 50); do
    SENTINEL_NEW_PID="$("$INSTALL_DIR/$SENTINEL_NAME" status 2>/dev/null \
      | awk '$1=="sentinel:" && $2=="watching" {gsub(/[^0-9]/,"",$4); print $4; exit}')"
    [ -n "$SENTINEL_NEW_PID" ] && [ "$SENTINEL_NEW_PID" != "$SENTINEL_WATCH_PID" ] && break
    sleep 0.1
  done
  [ -n "$SENTINEL_NEW_PID" ] && [ "$SENTINEL_NEW_PID" != "$SENTINEL_WATCH_PID" ] \
    || fail "node installed, but the sentinel did not start as a new watcher"
  echo "deploy: sentinel pid $SENTINEL_WATCH_PID -> $SENTINEL_NEW_PID"
elif [ ! -f "$SENTINEL_CONFIG/sentinel/stop" ]; then
  # No watcher, and no stop file, means nothing is left that can perform a request - a fresh install, a
  # reboot, or a watcher that died. Start one. The stop file is what `wa-sentinel stop` writes, so an
  # intentional stop is respected: this only fixes the case where there was never one, or it crashed.
  echo "deploy: no sentinel watching - starting one"
  "$INSTALL_DIR/$SENTINEL_NAME" start || fail "node installed, but the sentinel would not start"
  SENTINEL_NEW_PID=""
  for _ in $(seq 1 50); do
    SENTINEL_NEW_PID="$("$INSTALL_DIR/$SENTINEL_NAME" status 2>/dev/null \
      | awk '$1=="sentinel:" && $2=="watching" {gsub(/[^0-9]/,"",$4); print $4; exit}')"
    [ -n "$SENTINEL_NEW_PID" ] && break
    sleep 0.1
  done
  [ -n "$SENTINEL_NEW_PID" ] || fail "node installed, but the sentinel did not start watching"
  echo "deploy: sentinel started (pid $SENTINEL_NEW_PID)"
else
  echo "deploy: sentinel stopped by request (stop file present) - not starting it"
fi

cmp -s "$UPGRADE" "$INSTALL_DIR/scripts/upgrade.sh" || fail "the node is installed but the sentinel's upgrade.sh differs from this release"
UPGRADE_HASH="$(sha256sum < "$INSTALL_DIR/scripts/upgrade.sh" 2>/dev/null | awk '{print $1}')"
[ -n "$UPGRADE_HASH" ] || fail "the node is installed but upgrade.sh could not be hashed"

# Ship this script beside the binary too. The sentinel's `deploy` verb resolves `scripts/deploy.sh`
# beside the installed binary first - that is where an install keeps the scripts it is allowed to run -
# but `upgrade.sh` ships only itself, so a `request deploy` from an installed node found no deploy.sh
# and failed before it reached the gate, then fell back to the watcher's cwd (a checkout it should not
# need). Installing from the checkout's copy here is the only chance to close that: a deploy has to
# leave the next one able to run with no human at a shell.
DEPLOY_SRC="$ROOT/scripts/deploy.sh"
[ -f "$DEPLOY_SRC" ] || DEPLOY_SRC="$0"
if [ -f "$DEPLOY_SRC" ]; then
  mkdir -p "$INSTALL_DIR/scripts"
  cmp -s "$DEPLOY_SRC" "$INSTALL_DIR/scripts/deploy.sh" \
    || cp -f "$DEPLOY_SRC" "$INSTALL_DIR/scripts/deploy.sh" \
    || fail "node installed, but could not ship deploy.sh beside the binary"
fi

# Ship the WhatsApp pipeline with the node it belongs to. `upgrade.sh` installs the binary, the UI and the
# self-update skill, and has never carried these: the scripts that read the inbox, the job files that
# schedule and trigger them, and the entry point that says "emit" were placed in <install>/scripts by hand.
# That is how the ingest came to emit on a topic (`app.message`) that no job listened for, with the mismatch
# invisible because nothing ever shipped the two together - the reply job's history was a wall of "waiting
# for explicit event ingress" and nothing could say why. A pipeline that exists on one machine's install
# directory is not deployed, so it is deployed here.
if [ -d "$ROOT/jobs" ] && [ -d "$ROOT/scripts" ]; then
  PIPELINE=0
  # The voice lane calls a pure internal WASM formatter from trusted Lua. Ship
  # the exact module alongside its scripts so installing the job cannot leave
  # it with a missing plugin at runtime.
  cargo build --manifest-path "$ROOT/rust/plugins/whatsapp-transcript/Cargo.toml" \
    --target wasm32-unknown-unknown --release --offline >/dev/null \
    || fail "could not build the WhatsApp transcript plugin"
  mkdir -p "$INSTALL_DIR/plugins" || fail "could not create the plugin directory"
  cp -f "$ROOT/rust/plugins/whatsapp-transcript/target/wasm32-unknown-unknown/release/wa_plugin_whatsapp_transcript.wasm" \
    "$INSTALL_DIR/plugins/whatsapp-transcript.wasm" \
    || fail "could not ship the WhatsApp transcript plugin"
  for source in "$ROOT"/scripts/whatsapp-*; do
    [ -f "$source" ] || continue
    cp -f "$source" "$INSTALL_DIR/scripts/" || fail "node installed, but could not ship $(basename "$source")"
    PIPELINE=$((PIPELINE + 1))
  done
  INSTALL_MIXED="$(cygpath -m "$INSTALL_DIR" 2>/dev/null || printf '%s' "$INSTALL_DIR")"
  for source in "$ROOT"/jobs/whatsapp-*.json; do
    [ -f "$source" ] || continue
    JOB_NAME="$(basename "$source" .json)"
    # The job files name their script as PREPARED_BY_INSTALL/... so one file works from a checkout and from
    # an install: this substitution is what that placeholder was written for.
    sed "s|PREPARED_BY_INSTALL|$INSTALL_MIXED|g" "$source" > "$INSTALL_DIR/scripts/$JOB_NAME.job.json" \
      || fail "node installed, but could not prepare job $JOB_NAME"
    # Skip an unchanged definition, and this is not an optimisation. `job put` and `job enable` both
    # increment the job's revision, and a delivery is pinned to a revision - so re-putting a job that did
    # not change *cancels every pending delivery* for it. On 2026-09-21 that turned eight freshly ingested
    # messages into `definition changed`/`cancelled` rows: the pipeline was connected and the deploy's own
    # bookkeeping dropped the first events through it.
    if cmp -s "$INSTALL_DIR/scripts/$JOB_NAME.job.json" "$INSTALL_DIR/scripts/$JOB_NAME.job.json.shipped" 2>/dev/null; then
      echo "deploy: job $JOB_NAME unchanged"
      continue
    fi
    if "$INSTALL_DIR/$SENTINEL_NAME" job put "$INSTALL_DIR/scripts/$JOB_NAME.job.json" >/dev/null 2>&1; then
      PIPELINE=$((PIPELINE + 1))
      # The store disables a job whose definition changed, and that is deliberate: editing invalidates
      # approval. So the deploy must not quietly re-enable it from the file - the operator's checkbox is the
      # switch, and a deploy that flips it back is a deploy fighting the person. It says so instead.
      if grep -q '"enabled"[[:space:]]*:[[:space:]]*true' "$source"; then
        echo "deploy: job $JOB_NAME changed; it is installed DISABLED (a changed definition needs re-approval)"
        note "job $JOB_NAME changed and was installed disabled - enable it to run it"
      fi
      cp -f "$INSTALL_DIR/scripts/$JOB_NAME.job.json" "$INSTALL_DIR/scripts/$JOB_NAME.job.json.shipped" \
        || echo "deploy: WARNING could not record the shipped revision of job $JOB_NAME"
    else
      echo "deploy: WARNING could not put job $JOB_NAME into the store"
    fi
  done
  # Durable, not only stdout: a deploy runs detached and its stdout belongs to nobody afterwards.
  note "shipped $PIPELINE pipeline file(s) into $INSTALL_DIR/scripts"
fi

RECORD_TMP="$INSTALL_DIR/.installed.txt.deploy.$$"
REASON_LINE="$(printf '%s' "$REASON" | tr '\r\n' '  ')"
printf 'commit=%s\nbranch=%s\ndirty=%s\nsha256=%s\nsentinel_sha256=%s\nupgrade_sha256=%s\nsource_provenance=clean-built-by-deploy\nvia=deploy.sh\nat=%s\nreason=%s\n' \
  "$COMMIT" "$BRANCH" "$DIRTY" "$HASH" "$SENTINEL_HASH" "$UPGRADE_HASH" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$REASON_LINE" \
  > "$RECORD_TMP" && mv -f "$RECORD_TMP" "$INSTALL_DIR/installed.txt" \
  || fail "node installed, but installed.txt could not be committed atomically"

echo "deploy: installed $COMMIT ($HASH)"
echo "deploy: recorded in $INSTALL_DIR/installed.txt"
echo "deploy: /health -> $(curl -s -m 5 "http://127.0.0.1:$PORT/health" | head -c 260)"
write_result true "installed $COMMIT; watcher ${SENTINEL_NEW_PID:-${SENTINEL_WATCH_PID:-none}}"
VERDICT="[deploy result] ok commit=$COMMIT node_sha=$HASH sentinel_sha=$SENTINEL_HASH watcher=${SENTINEL_WATCH_PID:-none}->${SENTINEL_NEW_PID:-none}. Evidence: $INSTALL_DIR/deploy-result.json and installed.txt; run scripts/verify-install.sh for the checks."

# The continuation, and the reason this script takes --session/--prompt at all: the deploy is performed
# detached (the sentinel cannot replace itself while it is the process running the replacement), so the
# wake is the only completion signal the run that asked for this will ever see. Queued *here* - after the
# new node answered /health - and performed by the **new** watcher, which is the one thing that can
# honestly say the upgrade landed. A failure to queue it is reported and does not fail the deploy: the
# node and the sentinel are already installed, and saying so is better than rolling back over a wake.
if [ -n "$SESSION" ]; then
  SENTINEL_BIN="$INSTALL_DIR/wa-sentinel.exe"
  [ -x "$SENTINEL_BIN" ] || SENTINEL_BIN="$INSTALL_DIR/wa-sentinel"
  if [ -x "$SENTINEL_BIN" ] && [ -n "$PROMPT" ]; then
    "$SENTINEL_BIN" request wake --session "$SESSION" --prompt "$PROMPT

$VERDICT" \
      --reason "deploy finished: $REASON" >/dev/null 2>&1 \
      && echo "deploy: continuation queued for $SESSION" \
      || echo "deploy: WARNING could not queue the continuation for $SESSION; the install itself is done"
  else
    echo "deploy: WARNING no sentinel beside $INSTALL_DIR to queue the continuation with"
  fi
fi
