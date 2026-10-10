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
#   6. what was installed is recorded, and the pid answering must be the pid the install recorded;
#   7. the directory this deploy installs into must be the directory the service runs the node from, and the
#      port it will be restarted onto must be free of anything that is not that node. Rules 1-6 are all about
#      *this* tree; none of them asked the machine where its node lives, and on 2026-09-29 that cost 61,117
#      restarts: the unit ran a ten-day-old install at ~/.local/share/wasm-agent while this script's default
#      and upgrade.sh's Linux default were two other directories, the unit's process could not bind :8799
#      (`os error 98`, held by a stray node) and exited 0, and the deploy reported success. The answers live
#      in scripts/lib/service-target.sh, which is the one expression this project has for that question.
set -uo pipefail

# Refuse before even source/target resolution when the non-login shell lacks its tools.
# Use only builtins here: a missing dirname/date must not cause cascading false refusals.
for required in dirname date mkdir sed tr wc uname git; do
  command -v "$required" >/dev/null 2>&1 || { printf 'deploy: shell_environment_missing:%s; no installation attempted\n' "$required" >&2; exit 127; }
done

REQUIRE_MAIN=0
REASON=""
SESSION=""
PROMPT=""
REQUEST_ID=""
EXPECTED_SHA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --require-main) REQUIRE_MAIN=1; shift ;;
    --request-id) REQUEST_ID="${2:-}"; shift 2 ;;
    --expected-sha) EXPECTED_SHA="${2:-}"; shift 2 ;;
    --reason) REASON="${2:-}"; shift 2 ;;
    --session) SESSION="${2:-}"; shift 2 ;;
    --prompt) PROMPT="${2:-}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

INSTALL_DIR=""
# Which directory does this machine run its node from? `WA_INSTALL_DIR` is a caller's explicit statement;
# otherwise the service definition's ExecStart answers, then the node process holding the node's port, and
# only then the historical default. The helper is sourced from beside this script and shipped beside it by
# the deploy below, so an installed copy answers exactly as the checkout copy does - a deploy reading a
# different source of truth than the machine runs is the whole failure this rule exists for.
WA_LIB="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/lib/service-target.sh"
[ -f "$WA_LIB" ] && . "$WA_LIB"
EXPLICIT_INSTALL="${WA_INSTALL_DIR:-}"
PORT="${WA_PORT:-8799}"
CLIENT_PORT="${WA_CLIENT_PORT:-8800}"
if command -v wa_install_target >/dev/null 2>&1; then
  INSTALL_DIR="$(wa_install_target)"
  wa_read_service_claim || true
else
  # No helper beside this script: an install older than this rule. Fall back to the expression that was here
  # before and say so - a target this script chose without asking the machine is worth less than one the
  # machine named, and the absence of the check is evidence too.
  INSTALL_DIR="${WA_INSTALL_DIR:-$HOME/AppData/Local/wasm-agent}"
  [ -d "$INSTALL_DIR" ] || INSTALL_DIR="${WA_INSTALL_DIR:-$HOME/.local/share/wasm-agent}"
  WA_SERVICE_DIR=""
  WA_SERVICE_CLAIM=""
fi
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

# Explicit operator-selected privilege only for the verified installed sentinel's
# manager restart. Never infer sudo from a polkit failure or run the deploy as root.
sentinel_restart() {
  case "${WA_DEPLOY_SENTINEL_SUDO:-0}" in
    0) "$INSTALL_DIR/$SENTINEL_NAME" restart ;;
    1)
      case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) echo 'sentinel sudo restart is POSIX-only' >&2; return 1 ;; esac
      sudo -n env "WASM_AGENT_HOME=$(wa_home_dir)" "WA_INSTALL_DIR=$INSTALL_DIR" \
        "WA_SENTINEL_SUPERVISOR=${WA_SENTINEL_SUPERVISOR:-}" \
        "$INSTALL_DIR/$SENTINEL_NAME" restart ;;
    *) echo 'WA_DEPLOY_SENTINEL_SUDO must be 0 or 1' >&2; return 1 ;;
  esac
}

# A machine-readable result, written on both sides of the outcome. `installed.txt` says what is installed;
# this says what the *deploy* did, so a woken run reads one small file instead of re-deriving the answer
# from installed.txt, deploy.log, hashes and the sentinel status. `fail` writes it too, so a refusal is a
# result and not only a log line.
write_result() { # ok detail
  case "$REQUEST_ID" in *[!a-zA-Z0-9-]*) REQUEST_ID="" ;; esac
  _esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\r\n' '  '; }
  printf '{"ok":%s,"commit":"%s","branch":"%s","node_sha256":"%s","sentinel_sha256":"%s","watcher_pid":"%s","detail":"%s","reason":"%s","at":"%s","request_id":"%s","expected_sha":"%s"}\n' \
    "$1" "${COMMIT:-}" "${BRANCH:-}" "${HASH:-}" "${SENTINEL_HASH:-}" \
    "${SENTINEL_NEW_PID:-${SENTINEL_WATCH_PID:-}}" "$(_esc "$2")" "$(_esc "$REASON")" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(_esc "$REQUEST_ID")" "$(_esc "$EXPECTED_SHA")" > "$INSTALL_DIR/deploy-result.json" 2>/dev/null || true
  if [ -n "$REQUEST_ID" ]; then
    mkdir -p "$SENTINEL_CONFIG/sentinel/deploy-protocol/$REQUEST_ID"
    cp "$INSTALL_DIR/deploy-result.json" "$SENTINEL_CONFIG/sentinel/deploy-protocol/$REQUEST_ID/result.json" 2>/dev/null || true
  fi
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
        --prompt "Deploy failed: $*  This report does not establish what is installed. Evidence: $INSTALL_DIR/installed.txt and $INSTALL_DIR/deploy.log." \
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

# A staged copy that never reached its rename is residue, and nothing used to look for one.
#
# WHY (finding F6 of the review of change/deploy-unbound). Every install here stages a file beside its
# destination and renames it into place - `ship_file` as `<name>.ship.<pid>`, upgrade.sh's self-ship as
# `upgrade.sh.new.<pid>`, and the SENTINEL as a whole binary under `<name>.new.<pid>`. A SIGKILL between the
# copy and the rename leaves the staged file behind, and the sentinel is the size of a binary: the review
# measured a single leftover at 248 MB. Leftovers are now bounded, not ignored.
#
# The sweep can only touch a file one of our staging names would produce, and it is deliberately shy:
#   * the name must end in a numeric suffix (the pid) - an operator's own `.new` note is never touched;
#   * the file must be older than WA_DEPLOY_STAGING_AGE seconds (default 600), so a deploy running right now
#     - this one or a concurrent one - never has its staging eaten mid-install;
#   * at most WA_DEPLOY_STAGING_MAX files (default 8) and WA_DEPLOY_STAGING_BYTES bytes (default 536870912,
#     512 MiB) go per deploy, and hitting either bound is SAID in deploy.log rather than passed over;
#   * only $INSTALL_DIR and the three levels under it are searched, which covers scripts/lib - the deepest
#     place a staging name is written.
# Anything it cannot establish is left where it is: this is housekeeping, and a deploy that refused because
# of junk it could not classify would be worse than the junk.
sweep_stale_staging() {
  local age_minutes max_files max_bytes candidate suffix size removed=0 bytes=0 size_bytes
  age_minutes=$(( ${WA_DEPLOY_STAGING_AGE:-600} / 60 ))
  [ "$age_minutes" -ge 1 ] || age_minutes=1
  max_files="${WA_DEPLOY_STAGING_MAX:-8}"
  max_bytes="${WA_DEPLOY_STAGING_BYTES:-536870912}"
  while IFS= read -r candidate; do
    [ -f "$candidate" ] || continue
    suffix="${candidate##*.}"
    case "$suffix" in ''|*[!0-9]*) continue ;; esac
    [ "$suffix" = "$$" ] && continue
    [ -n "$(find "$candidate" -mmin +"$age_minutes" 2>/dev/null)" ] || continue
    if [ "$removed" -ge "$max_files" ]; then
      note "staging residue: the sweep stopped at its $max_files file bound; the rest is left in place"
      return 0
    fi
    size_bytes="$(wc -c < "$candidate" 2>/dev/null | tr -d ' ')"
    [ -n "$size_bytes" ] || size_bytes=0
    if [ $((bytes + size_bytes)) -gt "$max_bytes" ]; then
      note "staging residue: the sweep stopped at its $max_bytes byte bound with $bytes byte(s) removed; the rest is left in place"
      return 0
    fi
    if rm -f "$candidate"; then
      removed=$((removed + 1))
      bytes=$((bytes + size_bytes))
      note "staging residue swept: $(basename "$candidate") ($size_bytes byte(s)) - a staged copy whose rename never happened"
    fi
  done < <(find "$INSTALL_DIR" -maxdepth 3 -type f \( -name '*.ship.*' -o -name '*.new.*' \) 2>/dev/null)
  [ "$removed" -gt 0 ] && note "staging residue: removed $removed file(s), $bytes byte(s)"
  return 0
}

if [ "${WASM_AGENT_IN_TURN:-}" = "1" ]; then
  fail "cannot deploy from a running turn: it cannot become idle while this command waits. Build, then request an upgrade through wa-sentinel; see skills/self-update/SKILL.md"
fi

# 0a. The preconditions of running this at all: the platform's own shell, and an install directory that
#     exists. Each one refuses BY NAME, before anything is written, because the failure it replaces is a
#     deploy that "runs" for a while and then fails every write it attempts. (The third precondition - the
#     toolchain - is refused in step 4, where the build that needs it happens, so the questions that are
#     about *this tree* are answered first.)
#
#     WHY (reproduced 2026-10-02). A deploy was run from a bash with no LOCALAPPDATA - a WSL shell, where
#     `uname -s` is Linux and `HOME` is `/home/<user>` - against this repository, which is installed by the
#     platform's own shell (Git's bash on Windows). The historical default then resolved to
#     `<HOME>/AppData/Local/wasm-agent`, a directory that does not exist on that machine, and the script
#     went on: the target was a path nothing had ever installed into, every read of `installed.txt` and
#     `serve.pid` was empty, and the run ended in one of the later write failures instead of saying what
#     was wrong. `HOME=/home/victor` and a missing `$INSTALL_DIR` are both visible in the first second -
#     so they are refused in the first second, and `scripts/test-deploy-preconditions.sh` runs this script
#     under exactly that stripped environment and asserts each refusal by name.
#
#     Is this shell the platform's gate shell? `WASM_AGENT_HOME`, `LOCALAPPDATA`, `USERPROFILE` and every
#     default in `scripts/lib/service-target.sh` are asked in the gate shell's vocabulary. A Linux bash
#     with Windows interop (WSL) answers none of them the way this machine's install does, so it refuses
#     here rather than deploying into a path that will never be the running node.
is_wsl_bash() {
  if [ -n "${WSL_DISTRO_NAME:-}" ] || [ -n "${WSL_INTEROP:-}" ]; then return 0; fi
  case "$(uname -s 2>/dev/null)" in
    Linux*)
      case "$(uname -r 2>/dev/null)" in
        *icrosoft*|*WSL*) return 0 ;;
      esac ;;
  esac
  return 1
}
if is_wsl_bash; then
  fail "refused(not_the_gate_shell): this is a WSL (Linux) bash - uname -s=$(uname -s 2>/dev/null), uname -r=$(uname -r 2>/dev/null) - and this deploy installs a node for the platform whose gate shell it is, which on Windows is Git's bash and on Linux is that machine's bash. HOME here is ${HOME:-unset}, so the install directory and the service it must agree with are resolved in a different vocabulary from the machine's own. Run it in the platform's shell: 'C:/Program Files/Git/bin/bash.exe' for a Windows install (or scripts/install.sh), and the cloud tree's own bash for a Linux one. Nothing was written."
fi

if [ ! -d "$INSTALL_DIR" ]; then
  fail "refused(install_dir_missing): the install directory does not exist and carries no install record: $INSTALL_DIR (installed.txt: absent, serve.pid: absent, source: ${WA_SERVICE_CLAIM:-no service and no node on :$PORT named one}). A deploy writes installed.txt, the scripts and the binary into this directory, so every write would fail one at a time and none of them would say why. Either this is a first install - create the directory first (mkdir -p) or run scripts/install.sh, which does - or the machine's own answer is being read in the wrong vocabulary: state it explicitly (WA_INSTALL_DIR=<where the node lives>) after checking it yourself with scripts/lib/service-target.sh. Nothing was written."
fi

# Before this deploy builds anything: collect what a killed earlier deploy left staged (see the rule above).
# It runs this early on purpose - a 248 MB leftover should not sit through a build, and the bound means the
# sweep's own cost cannot grow with the junk.
sweep_stale_staging

# 0. The machine's own answer to "where does the node live" is the service that runs it, and a deploy that
#    disagrees with that must refuse instead of installing quietly beside the running node. Two installs on
#    one machine is not a cosmetic problem: the service keeps running the old one, the deploy replaces the
#    other, and every verification that reads the wrong directory passes.
if [ -n "${WA_SERVICE_DIR:-}" ] && ! wa_same_dir "$WA_SERVICE_DIR" "$INSTALL_DIR"; then
  fail "the service runs the node from $WA_SERVICE_DIR (${WA_SERVICE_CLAIM:-no source named}) and this deploy would install into $INSTALL_DIR - they are different installs. Install where the service runs (WA_INSTALL_DIR=$WA_SERVICE_DIR), or repoint the service at $INSTALL_DIR and reload it, then deploy"
fi
if [ -n "${WA_SERVICE_DIR:-}" ] && [ -n "$EXPLICIT_INSTALL" ]; then
  echo "deploy: $INSTALL_DIR is where the machine runs its node (${WA_SERVICE_CLAIM:-unknown})"
elif [ -n "${WA_SERVICE_DIR:-}" ]; then
  echo "deploy: installing into $INSTALL_DIR because ${WA_SERVICE_CLAIM:-the machine named it} (not the old default)"
else
  # Neither a unit nor a running node: a machine that has never had one, or a probe that could not see them.
  # Both are "the target is unverified", which is a note and not a refusal - the check must not invent an
  # answer, and it must not be silent about not having one.
  note "no service definition and no node on :$PORT this deploy can name, so $INSTALL_DIR is the target only because nothing contradicted it"
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
if [ -n "$EXPECTED_SHA" ]; then
  ROOT="$(cd "$(dirname "$0")/.." && pwd)"
else
  ROOT="$(resolve_root)"
fi
[ -n "$ROOT" ] || fail "cannot tell which worktree to deploy from: run this script from one, set WA_DEPLOY_ROOT, or record it in $INSTALL_DIR/runtime-worktree.txt - a deploy that cannot say what it builds does not build"
[ -d "$ROOT" ] || fail "the worktree to deploy from does not exist: $ROOT"
cd "$ROOT" || fail "cannot enter the worktree to deploy from: $ROOT"

# Protocol identity must be safe before any refusal writes per-request evidence.
if [ -n "$REQUEST_ID" ]; then
  case "$REQUEST_ID" in *[!a-zA-Z0-9-]*) REQUEST_ID=""; fail "invalid protocol request id" ;; esac
fi

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
  # must be a commit that is on main: merge the change first.
  #
  # This check used to be waived by `WA_INSTALL_DIR` being set ("a scratch directory is a test, not the
  # operator's node"), which made the rule switchable off with an environment variable - so the very
  # deploy that needed it most, one into some other directory, was the one that skipped it (finding F5 of
  # the review of change/deploy-unbound). It is unconditional now. `--require-main` is still accepted, as a
  # no-op kept for callers that pass it; the *rule* has its own test (scripts/test-deploy-on-main.sh)
  # rather than an exemption any caller can take.
  git merge-base --is-ancestor HEAD origin/main 2>/dev/null \
    || fail "this tree's commit $(git rev-parse --short HEAD) is not on origin/main; merge it to main and deploy from there - an unmerged deploy leaves main behind the live node"
fi
COMMIT="$(git rev-parse --short HEAD)"
if [ -n "$EXPECTED_SHA" ]; then
  case "$REQUEST_ID" in ''|*[!a-zA-Z0-9-]*) fail "invalid protocol request id" ;; esac
  [ "$(git rev-parse HEAD)" = "$EXPECTED_SHA" ] || fail "source changed from expected SHA before build"
  [ "$(git rev-parse origin/main)" = "$EXPECTED_SHA" ] || fail "expected SHA is not exact origin/main"
fi

# 2b. The port this deploy will be restarted onto, and who is holding it right now.
#
# A node that cannot bind the port it is restarted onto does not fail visibly: on 2026-09-29 the unit's own
# process started, printed `[serve] bind 127.0.0.1:8799 failed: Address already in use (os error 98)`, and
# *exited 0* - a stray node (pid 644564, ppid 1, running for 3h10m) held :8799 and :8800 - so systemd saw a
# clean exit and restarted it every three seconds: 61,117 times. The deploy in that window reported success,
# because the pid answering /health was the stray's, not the one it had installed. This asks the question
# before anything is built or replaced: is the process on the port the one this deploy is about to restart?
# If it is not, the deploy stops and names the process, its parent and its image instead of installing beside
# it. Waiting until after the swap is what made the earlier version read someone else's outcome.
if command -v wa_port_pid >/dev/null 2>&1; then
  LISTENER_PID="$(wa_port_pid "$PORT")"
  SERVICE_PID="$(wa_service_pid)"
  RECORDED_PID="$(tr -d '[:space:]' < "$INSTALL_DIR/serve.pid" 2>/dev/null)"
  EXPECTED_PID="${SERVICE_PID:-$RECORDED_PID}"
  LISTENER_IMAGE=""
  [ -n "$LISTENER_PID" ] && LISTENER_IMAGE="$(wa_pid_image "$LISTENER_PID")"
  LISTENER_DIR=""
  [ -n "$LISTENER_IMAGE" ] && LISTENER_DIR="${LISTENER_IMAGE%/*}"
  [ "$LISTENER_DIR" = "$LISTENER_IMAGE" ] && LISTENER_DIR=""
  if [ -z "$LISTENER_PID" ]; then
    echo "deploy: nothing is listening on :$PORT; the restart will be the only node on it"
  elif [ -n "$EXPECTED_PID" ] && [ "$EXPECTED_PID" = "$LISTENER_PID" ]; then
    echo "deploy: :$PORT is held by $(wa_pid_label "$LISTENER_PID"), the node this deploy will restart"
  elif [ -n "$LISTENER_DIR" ] && wa_same_dir "$LISTENER_DIR" "$INSTALL_DIR"; then
    # The install is the right one, but nothing on this machine claims that pid: a service that is not running
    # it, or a serve.pid that is stale. Say which, and carry on rather than refusing on a bookkeeping gap.
    note ":$PORT is held by $(wa_pid_label "$LISTENER_PID"), whose install is this one, but neither the service (${SERVICE_PID:-none running}) nor serve.pid (${RECORDED_PID:-none recorded}) names it"
  else
    fail "cannot bind the port this node will be restarted onto: :$PORT is held by $(wa_pid_label "$LISTENER_PID")${LISTENER_IMAGE:+ (install ${LISTENER_DIR:-unknown})}, and this deploy installs into $INSTALL_DIR with the service (${SERVICE_PID:-none running}) and serve.pid (${RECORDED_PID:-none recorded}) naming neither. Stop that process, or deploy the install it belongs to"
  fi
  if [ -n "$LISTENER_DIR" ] && ! wa_same_dir "$LISTENER_DIR" "$INSTALL_DIR"; then
    fail "the node holding :$PORT runs $LISTENER_IMAGE, but this deploy would install into $INSTALL_DIR - two installs, one port; installing here would leave the running node untouched and the install that answers unrecorded"
  fi
else
  note "no service-target helper beside this script, so nothing asked who holds :$PORT"
fi

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
# NO RELEASE PROOF IS CONSULTED HERE, and that is the default. A deploy and a release are two stages,
# not one gate: `scripts/wave-release.mjs` is what runs the full gate and names the exact tree it
# certified, and this deploy is how a change that has landed becomes the installed one - the operator
# asks for it and wants to see it now. Tying the two together made the fast path wait on a
# certification it does not need, and it read the relation backwards: a deploy is evidence ABOUT a
# release, never the licence to make one. Nothing in this script asks a release for permission, and
# with the knob below unset the tree is not even handed to the proof lookup - no lookup, no refusal
# about a receipt nobody asked for, and the deploy decision cannot be changed by the presence or
# absence of gate evidence.
#
# What still guards this path is state, not paperwork: the tree must be clean (step 1), its HEAD must
# be on origin/main with nothing behind it (step 2), it may not be a downgrade of what is installed
# (step 3), the port it will be restarted onto must not be someone else's node (step 2b), and the
# install it writes must be the one the machine runs the node from (step 0).
#
# WA_DEPLOY_REQUIRE_RELEASE_PROOF=1 restores the strict behaviour for anyone who wants it - a
# release-only machine, or an operator who will not install without an exact-tree receipt: the proof
# is then looked up, and a tree without one is refused BY NAME. It is OFF by default because speed is
# the default path, and nothing selects it automatically.
#
# The knob is read by VALUE, not by emptiness (finding F5 of the review of change/deploy-unbound):
# `-n "${WA_DEPLOY_REQUIRE_RELEASE_PROOF:-}"` made `WA_DEPLOY_REQUIRE_RELEASE_PROOF=0` truthy, so an
# operator who wrote 0 to say "off" got the strict path and a refusal about a receipt they had just
# switched off. Only the values below are ON; unset, empty, 0, false, no and off are OFF.
REQUIRE_PROOF=0
case "$(printf '%s' "${WA_DEPLOY_REQUIRE_RELEASE_PROOF:-}" | tr '[:upper:]' '[:lower:]')" in
  1|true|yes|on) REQUIRE_PROOF=1 ;;
esac
if [ "$REQUIRE_PROOF" = "1" ] && [ -f "$ROOT/rust/Cargo.toml" ]; then
  echo "deploy: WA_DEPLOY_REQUIRE_RELEASE_PROOF is set - this deploy refuses a tree without a release proof"
  SOURCE_TREE="$(git rev-parse HEAD^{tree})"
  PROOF_REPO="$ROOT"; PROOF_SCRIPT="$ROOT/scripts/lib/full-gate-proof.mjs"
  if command -v cygpath >/dev/null 2>&1; then
    PROOF_REPO="$(cygpath -w "$PROOF_REPO")"; PROOF_SCRIPT="$(cygpath -w "$PROOF_SCRIPT")"
  fi
  # 2 is "no complete identical-tree receipt", and on this path that is a refusal, not a note.
  GATE_PROOF="$(node "$PROOF_SCRIPT" "$PROOF_REPO" "$SOURCE_TREE" 2>&1)" || true
  if printf '%s' "$GATE_PROOF" | grep -q '"verified":true'; then
    note "release proof: this tree carries complete exact-tree verification for $SOURCE_TREE: $GATE_PROOF"
  else
    fail "complete gate proof required for source tree $SOURCE_TREE (WA_DEPLOY_REQUIRE_RELEASE_PROOF is set): $GATE_PROOF"
  fi
fi

# The toolchain this step needs, refused BY NAME before anything is compiled. It is checked here rather
# than at the top of the script on purpose: a machine without cargo should still be told about the dirty
# tree, the tree behind main, the downgrade or the held port that this run would also have to refuse, and
# those questions are about this tree and are answered before the build. A machine without cargo used to
# reach the build and fail there with a build error that named no cause.
#
# Written as a one-line guard because `scripts/test-deploy-gate-policy.sh` reads the proof block above out
# of this file by its markers, and the `fi` of an unindented `if` here would close that block early.
case "${WA_DEPLOY_SENTINEL_SUDO:-0}" in
  0) ;;
  1) command -v sudo >/dev/null 2>&1 && sudo -n true || fail 'explicit sentinel sudo restart requested but noninteractive authority is unavailable; nothing installed' ;;
  *) fail 'WA_DEPLOY_SENTINEL_SUDO must be 0 or 1; nothing installed' ;;
esac
command -v cargo >/dev/null 2>&1 || fail "refused(cargo_unavailable): cargo is not on PATH (PATH=${PATH:-unset}); this step builds the tree with 'cargo build --release --offline --manifest-path rust/Cargo.toml', so a deploy without it cannot build what it would install. Install Rust (https://rustup.rs), or run the deploy on the tree that has the toolchain (the cloud tree builds this repository). Nothing was built and nothing was installed. To build or test without installing, use the gate's own command instead: bash scripts/test.sh."

( cd rust && cargo build --release --offline --locked -p wa-host ) || fail "the build failed"
# The sentinel is its own crate, outside the `rust/` workspace (which lists only `wa-host`), so it is
# built with its own manifest. Asking the workspace for `-p wa-sentinel` fails - "package ID
# specification did not match any packages" - and that is how it came to be installed by hand at all.
( cd rust && cargo build --release --offline --locked --manifest-path wa-sentinel/Cargo.toml ) || fail "the sentinel build failed"
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
EMBEDDED_ROOT="$ROOT"; EMBEDDED_SCRIPT="$ROOT/scripts/check-embedded-runtime.lua"; EMBEDDED_HOME="$SCRATCH_HOME"
if command -v cygpath >/dev/null 2>&1; then
  EMBEDDED_ROOT="$(cygpath -w "$EMBEDDED_ROOT")"; EMBEDDED_SCRIPT="$(cygpath -w "$EMBEDDED_SCRIPT")"
  EMBEDDED_HOME="$(cygpath -w "$EMBEDDED_HOME")"
fi
if ! WASM_AGENT_HOME="$EMBEDDED_HOME" WASM_AGENT_LUA_ROOT='' \
  WA_EMBEDDED_SOURCE_ROOT="$EMBEDDED_ROOT" WA_SCRIPT="$EMBEDDED_SCRIPT" \
  "$NEW" --db "$EMBEDDED_HOME/embedded.db"; then
  rm -rf "$SCRATCH_HOME"
  fail "embedded runtime check failed; not installing it"
fi
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
if [ -n "$EXPECTED_SHA" ]; then
  [ "$(git rev-parse HEAD)" = "$EXPECTED_SHA" ] && [ -z "$(git status --porcelain)" ] || fail "source changed from expected SHA before install"
fi
echo "deploy: installing through upgrade.sh"
# Default runtime source is canonical main, not the producer/integration lane that
# happened to build this release. Selection is read-only and refuses dirty/stale
# canonical state; explicit overrides remain deliberate active-wave knobs.
if [ -z "${WA_RUNTIME_WORKTREE:-}" ]; then
  BINDING_SCRIPT="$ROOT/scripts/runtime-install-binding.mjs"; BINDING_REPO="$ROOT"
  if command -v cygpath >/dev/null 2>&1; then
    BINDING_SCRIPT="$(cygpath -w "$BINDING_SCRIPT")"; BINDING_REPO="$(cygpath -w "$BINDING_REPO")"
  fi
  WA_RUNTIME_WORKTREE="$(node "$BINDING_SCRIPT" "$BINDING_REPO" 2>&1)" \
    || fail "canonical runtime binding refused: $WA_RUNTIME_WORKTREE"
fi
[ -d "$WA_RUNTIME_WORKTREE" ] || fail "runtime worktree does not exist"
RUNTIME_PATH="$(cd "$WA_RUNTIME_WORKTREE" && pwd)"
command -v cygpath >/dev/null 2>&1 && RUNTIME_PATH="$(cygpath -w "$RUNTIME_PATH")"
if [ -f "$INSTALL_DIR/runtime-worktree.txt" ]; then
  cp -f "$INSTALL_DIR/runtime-worktree.txt" "$INSTALL_DIR/runtime-worktree.txt.pre-upgrade" || fail "cannot back up runtime location"
fi
RUNTIME_RECORD="$INSTALL_DIR/.runtime-worktree.txt.$$"
printf '%s\n' "$RUNTIME_PATH" > "$RUNTIME_RECORD" && mv -f "$RUNTIME_RECORD" "$INSTALL_DIR/runtime-worktree.txt" \
  || fail "could not atomically record runtime worktree"
export WA_RUNTIME_WORKTREE="$RUNTIME_PATH"

# wa-deploy-upgrade-invocation: begin
# Everything upgrade.sh is told goes on the command's own lines, and the COMMENTS LIVE ABOVE IT on purpose.
# That is not style. bash drops a simple command's whole `VAR=value \` prefix when a comment line sits
# inside the continuation, and MEASURED on 2026-10-02 (`FOO=1 \` / `# comment` / `bash -c 'echo "[$FOO]"'`
# printed `[]`) it drops it silently while still running the command - so comment lines that were once
# between the assignments and `bash "$UPGRADE"` here meant upgrade.sh never received WA_UPGRADE_VIA,
# WA_UPGRADE_REASON or WA_INSTALL_DIR. The install record of a deploy then said `via=upgrade.sh` and
# `reason=upgrade requested` (the values that mean "someone ran upgrade.sh by hand"), which is exactly what
# installed.txt held on 2026-10-02 19:30 - the deploy's caller identity was erased by a comment.
#
# upgrade.sh writes to a *file*, not into a pipe. A deploy runs detached, and a detached process's stdout
# belongs to whoever spawned it - so when that parent went away, a write into the pipe raised SIGPIPE and
# upgrade.sh died with exit 141 before it could say what it was doing. That transcript is also the evidence
# that was missing: the failure was reported and nothing could say why.
WA_INSTALL_DIR="$INSTALL_DIR" WA_PORT="$PORT" WA_CLIENT_PORT="$CLIENT_PORT" \
  WA_UPGRADE_REASON="$REASON" WA_UPGRADE_VIA=deploy.sh \
  bash "$UPGRADE" "$(cd "$(dirname "$NEW")" && pwd)/$(basename "$NEW")" > "$INSTALL_DIR/deploy-upgrade.log" 2>&1
# wa-deploy-upgrade-invocation: end
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
SENTINEL_SWAP_STARTED=0
if [ -f "$INSTALL_DIR/$SENTINEL_NAME" ]; then
  cp -f "$NEW_SENTINEL" "$INSTALL_DIR/$SENTINEL_NAME" 2>/dev/null || true
  if cmp -s "$NEW_SENTINEL" "$INSTALL_DIR/$SENTINEL_NAME"; then
    echo "deploy: sentinel $SENTINEL_NAME updated"
  else
    # The file is locked by the running supervisor on Windows, and there the stop/replace/start dance below is
    # the way through it. On POSIX it is not locked at all: `cp` over a running image fails with ETXTBSY ("text
    # file busy"), while a *rename* over it succeeds - the running process keeps the inode it already mapped and
    # the new image is picked up by the restart below. The rename is not a shortcut, it is the shorter path than
    # stop/replace/start for the watcher nothing outside owns (a `nohup`) - and the `Restart=always` flap that
    # argument used to name is gone: a deploy under a supervisor now runs in a unit of its own, outside the
    # watcher's control group (`role::placement`, `rust/wa-sentinel/src/role.rs`).
    if [ -f "$INSTALL_DIR/$SENTINEL_NAME" ]; then
      case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*)
          # A Windows SCM stop is authoritative and synchronous. Never copy/start
          # after an access-denied/mismatched stop, or manufacture updated bytes.
          "$INSTALL_DIR/$SENTINEL_NAME" stop || fail "sentinel stop refused; installed supervisor left intact"
          sleep 2
          cp -f "$NEW_SENTINEL" "$INSTALL_DIR/$SENTINEL_NAME" \
            || fail "sentinel stopped but replacement failed; inspect before recovery"
          "$INSTALL_DIR/$SENTINEL_NAME" start || fail "sentinel replacement placed but manager start failed"
          SENTINEL_SWAP_STARTED=1
          ;;
        *)
          cp -f "$NEW_SENTINEL" "$INSTALL_DIR/$SENTINEL_NAME.new.$$" 2>/dev/null || true
          mv -f "$INSTALL_DIR/$SENTINEL_NAME.new.$$" "$INSTALL_DIR/$SENTINEL_NAME" 2>/dev/null || true
          ;;
      esac
    fi
    if cmp -s "$NEW_SENTINEL" "$INSTALL_DIR/$SENTINEL_NAME"; then
      echo "deploy: sentinel $SENTINEL_NAME updated (the running watcher keeps its old image until the restart below)"
    else
      # Do not leave the staged image behind for a failure that is about to be reported: it is a whole
      # binary. What a SIGKILL here would leave is swept by sweep_stale_staging() on the next deploy.
      rm -f "$INSTALL_DIR/$SENTINEL_NAME.new.$$" 2>/dev/null || true
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
if [ "$SENTINEL_SWAP_STARTED" = "1" ]; then
  # The Windows swap already loaded the candidate. A second restart would kill
  # work admitted by the fresh service for no installation benefit.
  [ -n "$SENTINEL_WATCH_PID" ] || fail "sentinel swap start answered but no watcher is proven"
  SENTINEL_NEW_PID="$SENTINEL_WATCH_PID"
  echo "deploy: sentinel swap already started the installed image (pid $SENTINEL_NEW_PID)"
elif [ -n "$SENTINEL_WATCH_PID" ]; then
  echo "deploy: restarting the watching sentinel to load the installed image"
  sentinel_restart || fail "node installed, but the sentinel could not restart"
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

# The install record, in one place, called twice - once here and once as this deploy's last write (step 8).
# It is a function because the record must exist the moment the facts it names are true, and because two
# copies of a record format drift apart.
#
# `record_role=final` is what separates this record from upgrade.sh's. upgrade.sh installs bytes and can
# only certify the hash it placed (`source_provenance=unverified-binary`); when THIS script calls it, its
# record says `record_role=interim` and `via=deploy.sh`, because the deploy is the owner of the install's
# record - it is the only party that knows the commit the binary was built from. So a reader who finds an
# interim record as the LAST one is looking at a deploy that did not finish its record step. That state was
# reached on 2026-10-02 19:30 and nothing could name it: installed.txt said `commit=unknown` while the node
# served 2f02b4c's build, and the only trace of the death was a line on a detached process's stdout. What
# killed that run is at the ship_file rule below.
record_installed() {
  local record_tmp reason_line
  record_tmp="$INSTALL_DIR/.installed.txt.deploy.$$"
  reason_line="$(printf '%s' "$REASON" | tr '\r\n' '  ')"
  # `install_dir=` is the record's own statement of where it was written, and of which directory the machine
  # runs the node from. A record that cannot say that is a record a later reader has to guess about - and
  # `~/.wasm-agent/installed.txt`, empty on the node this rule was written for, is what guessing looks like.
  printf 'commit=%s\nbranch=%s\ndirty=%s\nsha256=%s\nsentinel_sha256=%s\nupgrade_sha256=%s\ninstall_dir=%s\nservice_install_dir=%s\nsource_provenance=clean-built-by-deploy\nrecord_role=final\nvia=deploy.sh\nat=%s\nreason=%s\n' \
    "$COMMIT" "$BRANCH" "$DIRTY" "$HASH" "$SENTINEL_HASH" "$UPGRADE_HASH" "$INSTALL_DIR" "${WA_SERVICE_DIR:-unverified}" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$reason_line" \
    > "$record_tmp" && mv -f "$record_tmp" "$INSTALL_DIR/installed.txt" \
    || fail "node installed, but installed.txt could not be committed atomically"
}

# Record what is installed HERE, not only at the end. Every fact this record names - the exact commit, the
# binary hash, the sentinel hash, the install directory - is already true at this point, and the steps that
# follow (shipping scripts, putting job definitions) can still refuse or die. Writing it now means a deploy
# that dies after the node is installed leaves the deploy's own exact-commit record, not upgrade.sh's
# interim one - which is the state that made `verify-install.sh` report `installed unknown is not an
# ancestor of tree ...` on 2026-10-02. The write at step 8 confirms the same content as the deploy's last
# act, so "the final record is deploy.sh's" holds whichever of the two the run reaches.
record_installed

# Ship one file beside the binary without ever rewriting a file in place.
#
# WHY (measured, 2026-10-02 19:30). This script ships its own copy into the install - the sentinel's `deploy`
# verb resolves `<install>/scripts/deploy.sh`, so a deploy has to leave the next one able to run - and the
# running script IS that path when the sentinel starts it. `cp -f` over it rewrites the very file bash is
# reading, and bash tracks its position by BYTE OFFSET into the file: rewrite it under a running script and
# the next read lands in the middle of a line. MEASURED in that run: the deploy printed
# `deploy: sentinel pid 16712 -> 2904`, then `/…/deploy.sh: line 534: syntax error near unexpected token '('`,
# and the shell exited there - silently, because a parse error reaches none of this script's own `fail`
# paths and deploy.log therefore got no line at all. Everything after it was skipped: the pipeline and the
# wave scripts were never shipped (two of them stayed at the 5b1ffdc build while the tree was 2f02b4c),
# installed.txt kept upgrade.sh's interim record, the recorded sentinel_sha256 was the pre-replacement
# sentinel's, deploy-result.json kept the previous deploy's verdict, and the session waiting for the wake
# was never told. MEASURED in the regression fixture (scripts/test-deploy-self-ship.sh): over a running
# script the `cp` form stops the run at that line - sometimes with status 0, which is worse.
#
# Staging beside the destination and renaming is the fix, and it is the pattern this project already uses
# for a running binary (upgrade.sh's sentinel swap): the interpreter keeps the bytes it already opened, the
# install gets the new file, and no reader is interrupted. MEASURED on this machine (Git bash on Windows),
# the rename form runs the rest of the script.
ship_file() { # source destination what
  local source="$1" destination="$2" what="$3" staged
  cmp -s "$source" "$destination" && return 0
  mkdir -p "$(dirname "$destination")" || fail "node installed, but could not create $(dirname "$destination")"
  staged="$destination.ship.$$"
  cp -f "$source" "$staged" || { rm -f "$staged"; fail "node installed, but could not stage $what"; }
  if mv -f "$staged" "$destination" && cmp -s "$source" "$destination"; then
    return 0
  fi
  rm -f "$staged"
  fail "node installed, but could not ship $what"
}

# Ship this script beside the binary too. The sentinel's `deploy` verb resolves `scripts/deploy.sh`
# beside the installed binary first - that is where an install keeps the scripts it is allowed to run -
# but `upgrade.sh` ships only itself, so a `request deploy` from an installed node found no deploy.sh
# and failed before it reached the gate, then fell back to the watcher's cwd (a checkout it should not
# need). Installing from the checkout's copy here is the only chance to close that: a deploy has to
# leave the next one able to run with no human at a shell.
DEPLOY_SRC="$ROOT/scripts/deploy.sh"
[ -f "$DEPLOY_SRC" ] || DEPLOY_SRC="$0"
if [ -f "$DEPLOY_SRC" ]; then
  ship_file "$DEPLOY_SRC" "$INSTALL_DIR/scripts/deploy.sh" "deploy.sh beside the binary"
fi

# ...and the helper that answers "where does this machine's node live", beside the copy of this script that
# will run the next deploy. Without it the installed copy would fall back to the old expression and lose
# exactly the check this rule added - the same way `request deploy` found no deploy.sh at all until that one
# was shipped.
LIB_SRC="$WA_LIB"
[ -f "$LIB_SRC" ] || LIB_SRC="$ROOT/scripts/lib/service-target.sh"
if [ -f "$LIB_SRC" ]; then
  ship_file "$LIB_SRC" "$INSTALL_DIR/scripts/lib/service-target.sh" "scripts/lib/service-target.sh beside deploy.sh"
fi

ship_file "$ROOT/scripts/verify-install.sh" "$INSTALL_DIR/scripts/verify-install.sh" "installation verifier"
ship_file "$ROOT/scripts/sentinel-install-proof.mjs" "$INSTALL_DIR/scripts/sentinel-install-proof.mjs" "request-bound installation proof"
ship_file "$ROOT/scripts/sentinel-historical-proof.mjs" "$INSTALL_DIR/scripts/sentinel-historical-proof.mjs" "verification-only historical generation proof"
ship_file "$ROOT/scripts/measure-sentinel-io.ps1" "$INSTALL_DIR/scripts/measure-sentinel-io.ps1" "bounded read-only Windows idle measurement"
ship_file "$ROOT/scripts/install-sentinel-service.ps1" "$INSTALL_DIR/scripts/install-sentinel-service.ps1" "explicit external Windows SCM installer"

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
  # ...and the modules those scripts import, *derived from the imports* rather than listed by hand.
  #
  # The glob above ships `scripts/whatsapp-*` and nothing else, and that is how the install came to hold a
  # reader whose own import was absent: `5cc38d1` moved the WebSocket runtime into
  # `scripts/lib/websocket-runtime.mjs`, the install got the new `whatsapp-read.mjs` and no `lib/`, and every
  # delivery then failed at step 2 - the transcribe step, which runs the same reader - with
  # `{"step":"read","error":"process_output_unreadable: ... ERR_MODULE_NOT_FOUND"}`, one per 30 s tick,
  # while the deploy reported success. A pipeline that cannot start is not a deployed pipeline, and a
  # hand-written list would have been wrong in exactly the same way one commit later. So the list is the
  # imports.
  MODULES=""
  for source in "$ROOT"/scripts/whatsapp-*; do
    [ -f "$source" ] || continue
    MODULES="$MODULES$(grep -o '\./lib/[A-Za-z0-9._-]*' "$source" 2>/dev/null | sed 's|^\./lib/||')
"
  done
  MODULES="$(printf '%s' "$MODULES" | sed '/^$/d' | sort -u)"
  for module in $MODULES; do
    [ -f "$ROOT/scripts/lib/$module" ] \
      || fail "a shipped script imports scripts/lib/$module, which is not in this tree"
    mkdir -p "$INSTALL_DIR/scripts/lib" || fail "node installed, but could not create $INSTALL_DIR/scripts/lib"
    cp -f "$ROOT/scripts/lib/$module" "$INSTALL_DIR/scripts/lib/" \
      || fail "node installed, but could not ship scripts/lib/$module"
    PIPELINE=$((PIPELINE + 1))
  done
  # And prove the install is import-closed, so a script that cannot load is a refused deploy instead of a
  # silent run of failing deliveries: every relative import of a shipped script must resolve inside
  # <install>/scripts, next to the script that names it.
  for source in "$INSTALL_DIR"/scripts/whatsapp-*; do
    [ -f "$source" ] || continue
    for relative in $(grep -o '\./[A-Za-z0-9._/-]*' "$source" 2>/dev/null | sort -u); do
      [ -f "$INSTALL_DIR/scripts/${relative#./}" ] \
        || fail "$(basename "$source") imports $relative, which this deploy did not install"
    done
  done
  INSTALL_MIXED="$(cygpath -m "$INSTALL_DIR" 2>/dev/null || printf '%s' "$INSTALL_DIR")"
  # The `onSubagentReturn` hook's own scripts, shipped beside the job that names them and before that job
  # is put: a definition installed ahead of its script is a job that fails on the machine it was installed
  # on. They import only Node builtins, so there is no `./lib/...` closure to derive here - unlike the
  # WhatsApp pipeline above, whose modules are found from the imports it writes.
  for source in "$ROOT"/scripts/subagent-return-* "$ROOT"/scripts/sentinel-return-* "$ROOT"/scripts/deploy-shipped.json; do
    [ -f "$source" ] || continue
    cp -f "$source" "$INSTALL_DIR/scripts/" \
      || fail "node installed, but could not ship $(basename "$source")"
    PIPELINE=$((PIPELINE + 1))
  done
  for source in "$ROOT"/jobs/whatsapp-*.json "$ROOT"/jobs/on-subagent-return.json "$ROOT"/jobs/subagent-return-observe.json "$ROOT"/jobs/on-sentinel-return.json "$ROOT"/jobs/sentinel-return-observe.json; do
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

# Ship wave continuation/entry scripts with their literal module closure.
WAVE_SHIP="$ROOT/scripts/ship-wave.mjs"; WAVE_ROOT="$ROOT"; WAVE_INSTALL="$INSTALL_DIR"
if command -v cygpath >/dev/null 2>&1; then
  WAVE_SHIP="$(cygpath -w "$WAVE_SHIP")"; WAVE_ROOT="$(cygpath -w "$WAVE_ROOT")"; WAVE_INSTALL="$(cygpath -w "$WAVE_INSTALL")"
fi
node "$WAVE_SHIP" "$WAVE_ROOT" "$WAVE_INSTALL" || fail "node installed, but wave continuation scripts are not import-closed"

record_installed
echo "deploy: installed $COMMIT ($HASH)"
echo "deploy: recorded in $INSTALL_DIR/installed.txt"
echo "deploy: /health -> $(curl -s -m 5 "http://127.0.0.1:$PORT/health" | head -c 260)"
if [ -n "$EXPECTED_SHA" ]; then
  [ "$(git rev-parse HEAD)" = "$EXPECTED_SHA" ] && [ -z "$(git status --porcelain)" ] \
    && [ "$(git ls-remote origin refs/heads/main | awk '{print $1}')" = "$EXPECTED_SHA" ] \
    || fail "source changed before final installation record"
fi
PROOF_NODE_SCRIPT="$ROOT/scripts/sentinel-install-proof.mjs"; PROOF_NODE_ROOT="$ROOT"; PROOF_NODE_INSTALL="$INSTALL_DIR"
if command -v cygpath >/dev/null 2>&1; then
  PROOF_NODE_SCRIPT="$(cygpath -w "$PROOF_NODE_SCRIPT")"; PROOF_NODE_ROOT="$(cygpath -w "$PROOF_NODE_ROOT")"; PROOF_NODE_INSTALL="$(cygpath -w "$PROOF_NODE_INSTALL")"
fi
if [ -n "$EXPECTED_SHA" ]; then
  node "$PROOF_NODE_SCRIPT" record "$PROOF_NODE_ROOT" "$PROOF_NODE_INSTALL" \
    || fail "final source/artifact/script/UI/process identity recording failed"
fi
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
