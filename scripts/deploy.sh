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
# The build's progress file and its requirement check (29/10): the sentinel owns the one rebuild path, so
# whoever asked for it sees the same progress, and a missing toolchain is named (or fetched) before a build.
for wa_lib_part in build-status build-requirements deploy-components node-binaries retire-unshipped; do
  [ -f "$(dirname "$0")/lib/$wa_lib_part.sh" ] && . "$(dirname "$0")/lib/$wa_lib_part.sh"
done
command -v wa_status >/dev/null 2>&1 || { wa_status() { :; }; wa_status_follow() { :; }; wa_status_unfollow() { :; }; wa_status_compiled() { :; }; wa_phase() { :; }; }
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

# The sentinel executes `run` scripts only from directories named here, and the install's own scripts
# live in <install>/scripts. Without this, every job whose action is `run` fails with "run is disabled:
# set WA_SENTINEL_SCRIPTS".
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
  # The watcher this deploy starts inherits this process's environment, and this process has exported the
  # tree it builds from (WA_DEPLOY_ROOT) plus the pin and build-target names. A watcher that inherits them
  # hands them to the NEXT deploy, which then resolves its source tree to this deploy's detached build pin -
  # a worktree no landing ever fast-forwards, so that deploy waits its whole tree-wait bound and then
  # refuses `canonical_busy` naming the pin (measured on wasm_the_first 2026-11-11: 600 s, nothing built).
  # The supervisor is long-lived and must start from the machine's own answer, not from one deploy's.
  case "${WA_DEPLOY_SENTINEL_SUDO:-0}" in
    0) env -u WA_DEPLOY_ROOT -u WA_DEPLOY_PIN -u WA_DEPLOY_PIN_DIR -u WA_DEPLOY_BUILD_TARGET \
         -u WA_CODEMODE_TARGET_DIR "$INSTALL_DIR/$SENTINEL_NAME" restart ;;
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
  wa_status_unfollow
  wa_status failed "${WA_STATUS_PHASE:-preflight}: $(printf '%s' "$*" | cut -c1-90)"
  printf '%s\t%s\t%s\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "${COMMIT:-unknown}" "${BRANCH:-unknown}" "$*" \
    >> "$INSTALL_DIR/deploy.log" 2>/dev/null
  write_result false "$*"
  # A requested deploy is answered, including when the answer is no - but not from here. The report belongs to
  # the sentinel that spawned this script (`deploy_outcome`), which settles it from the `result.json` written
  # just above, from this process's exit status, or from its own watchdog. It used to be queued here, and that
  # is exactly the defect measured on 2026-11-10: this process is the one the swap kills, so a wake written
  # only by its last lines is a wake that never arrives when it matters. A hand-run deploy passes no --session
  # and has nobody to wake; a refusal at a shell is read by the person at the shell.
  exit 1
}

# The other half of "a refusal is evidence": a check that *could not run* is evidence too, and it must look
# like neither a refusal nor silence. A gate that goes blind quietly is worse than one that refuses, because
# nothing afterwards can tell that it never had an opinion. `note` records the same line as `fail` with a
# `note:` marker, so "was the gate blind that day?" is answerable from the same file.
note() {
  echo "deploy: $*"
  printf '%s\t%s\t%s\tnote: %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "${COMMIT:-unknown}" "${BRANCH:-unknown}" "$*" \
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

# A node cannot replace itself; a CLI turn may have the sentinel replace the node (scripts/lib/turn-guard.sh).
. "$(dirname "$0")/lib/turn-guard.sh"
case "$(turn_owner)" in
  node|unknown)
    fail "cannot deploy from a turn running on the node it would replace: it cannot become idle while this command waits. Build, then request it through wa-sentinel (request deploy); see skills/self-update/SKILL.md" ;;
  cli)
    sentinel_supervises "$INSTALL_DIR" \
      || fail "deploying from a CLI turn needs a sentinel supervising the node (wa-sentinel start); none is watching"
    note "deploying from a CLI turn: the sentinel replaces the node; this CLI restarts itself into its session when idle" ;;
esac

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
# The tree this command was pointed at. Everything checked before the pin below is checked HERE, and every
# fact recorded about where the deploy came from names this directory. If it is a canonical checkout a
# landing may move it at any moment; the build reads a pinned worktree instead (step 3c).
SOURCE_ROOT="$ROOT"
# Arm the checkout's git hooks by default (CRLF, main guard, generated prompt docs). Advisory: a
# config write cannot dirty the tree, and a failure here never stops a deploy.
[ -f "$ROOT/scripts/setup-hooks.sh" ] && bash "$ROOT/scripts/setup-hooks.sh" "$ROOT" || true
# From here a failure is drawn as a failed build: the rules below (clean, current, not a downgrade, the
# port, the toolchain) are the build's preflight, and each phase after it says how long it took.
command -v wa_build_env >/dev/null 2>&1 && wa_build_env
if command -v wa_status_begin >/dev/null 2>&1; then
  wa_status_begin "$ROOT" "$(git rev-parse HEAD 2>/dev/null)"
  wa_phase preflight
fi

# Protocol identity must be safe before any refusal writes per-request evidence.
if [ -n "$REQUEST_ID" ]; then
  case "$REQUEST_ID" in *[!a-zA-Z0-9-]*) REQUEST_ID=""; fail "invalid protocol request id" ;; esac
fi

# 0b. A canonical checkout that is mid-landing is not a tree to read. Measured on wasm_the_first
#     (2026-11-10/11): a deploy asked to install while the landing queue's holder had merged and not yet
#     pushed, so HEAD was a merge commit that was not on origin/main, and the deploy refused with "this
#     tree's commit ... is not on origin/main" - correct, and useless: the next attempt met the next
#     landing. The deploy now WAITS (bounded) for the tree to be exactly origin/main and clean, saying
#     what it is waiting for, instead of racing the queue. The pin below then takes the lease and cannot
#     be moved by a landing at all.
WA_TREE_WAIT="${WA_DEPLOY_TREE_WAIT:-600}"
case "$WA_TREE_WAIT" in ''|*[!0-9]*) WA_TREE_WAIT=600 ;; esac
TREE_WAITED=0
git fetch -q origin 2>/dev/null || true
while :; do
  HEAD_NOW="$(git rev-parse HEAD 2>/dev/null || true)"
  MAIN_NOW="$(git rev-parse origin/main 2>/dev/null || true)"
  DIRT_NOW="$(git status --porcelain | wc -l | tr -d ' ')"
  # A detached worktree is a build pin, and no landing ever moves one. Waiting the whole bound for it to
  # become origin/main was 600 s spent on an answer that cannot change (wasm_the_first 2026-11-11, where
  # the cause was WA_DEPLOY_ROOT inherited by the watcher from the deploy that started it). Say it once.
  if [ "$HEAD_NOW" != "$MAIN_NOW" ] && [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" = "HEAD" ]; then
    fail "refused(source_pin_stale): $SOURCE_ROOT is a detached worktree at ${HEAD_NOW:0:12} and origin/main is ${MAIN_NOW:0:12}; a landing never fast-forwards a detached tree, so this wait could only time out after ${WA_TREE_WAIT}s. Unset WA_DEPLOY_ROOT (a deploy exports it for the processes it starts and a watcher started by one inherits it), or point it at the canonical checkout. Nothing was built."
  fi
  [ "$HEAD_NOW" = "$MAIN_NOW" ] && [ "$DIRT_NOW" = "0" ] && break
  if [ "$TREE_WAITED" -ge "$WA_TREE_WAIT" ]; then
    fail "refused(canonical_busy): $SOURCE_ROOT is not exactly origin/main after waiting ${WA_TREE_WAIT}s (HEAD ${HEAD_NOW:0:12}, origin/main ${MAIN_NOW:0:12}, ${DIRT_NOW} uncommitted change(s)); a landing is in progress or the tree owns edits nobody has committed. Nothing was built. The queue's status names its holder."
  fi
  [ "$TREE_WAITED" = "0" ] && note "waiting for the canonical tree to be exactly origin/main: HEAD ${HEAD_NOW:0:12}, origin/main ${MAIN_NOW:0:12}, ${DIRT_NOW} uncommitted change(s) - a landing is in progress"
  sleep 5
  TREE_WAITED=$((TREE_WAITED + 5))
  [ $((TREE_WAITED % 60)) -eq 0 ] && note "still waiting for a quiet canonical tree after ${TREE_WAITED}s"
done
[ "$TREE_WAITED" = "0" ] || note "canonical tree is quiet after ${TREE_WAITED}s (origin/main ${MAIN_NOW:0:12}); continuing"

# 1. Clean. A build from a half-edited tree is not reproducible, and the file being edited is often the one
#    that matters.
DIRTY="$(git status --porcelain | wc -l | tr -d ' ')"
[ "$DIRTY" = "0" ] || fail "the tree has $DIRTY uncommitted change(s); commit or stash them first"

# 2. Current. Behind main is the failure this project has paid for repeatedly.
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
# Which main. origin/main always; and a checkout may name another remote as a source of main with
# `git config wa.deployRemote <remote>` - the laptop sandbox does (29/10): its operator's main arrives as a
# git bundle (remote `host`) before it is pushed anywhere, and the sentinel deploys it. The rules are the
# same against every named main: behind ANY of them refuses, and HEAD must be ON one of them. A tree behind
# origin/main is still refused when the other remote is ahead, so a stale laptop cannot undo GitHub's main.
MAIN_REFS=""
for MAIN_REMOTE in origin $(git config --get-all wa.deployRemote 2>/dev/null); do
  case " $MAIN_REFS " in *" $MAIN_REMOTE/main "*) continue ;; esac
  git fetch -q "$MAIN_REMOTE" 2>/dev/null || true
  git rev-parse --verify -q "$MAIN_REMOTE/main" >/dev/null && MAIN_REFS="$MAIN_REFS $MAIN_REMOTE/main"
done
MAIN_REFS="${MAIN_REFS# }"
DEPLOY_MAIN_REF=origin/main
for MAIN_REF in $MAIN_REFS; do
  [ "$(git rev-parse "$MAIN_REF")" = "$(git rev-parse HEAD)" ] && { DEPLOY_MAIN_REF="$MAIN_REF"; break; }
done
export WA_DEPLOY_MAIN_REF="$DEPLOY_MAIN_REF"
if [ -n "$MAIN_REFS" ]; then
  for MAIN_REF in $MAIN_REFS; do
    BEHIND="$(git rev-list --count "HEAD..$MAIN_REF" 2>/dev/null || echo 0)"
    [ "$BEHIND" = "0" ] || fail "this tree is $BEHIND commit(s) behind $MAIN_REF; merge main first (a node that cannot see main cannot see its own fixes)"
  done
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
  ON_MAIN=0
  for MAIN_REF in $MAIN_REFS; do git merge-base --is-ancestor HEAD "$MAIN_REF" 2>/dev/null && ON_MAIN=1; done
  [ "$ON_MAIN" = 1 ] \
    || fail "this tree's commit $(git rev-parse --short HEAD) is not on $(printf '%s' "$MAIN_REFS" | sed 's/ / or /g'); merge it to main and deploy from there - an unmerged deploy leaves main behind the live node"
fi
COMMIT="$(git rev-parse --short HEAD)"
# The release this commit IS, when it is one. Recorded at install so the node can answer "am I behind?"
# without resolving a tag back to a commit over the network: `lua/core/release.lua` compares tags, and
# an install with no tag answers `unknown` rather than "up to date". Empty is a fact (a commit that was
# never released), so the line is omitted rather than written as `release=`.
RELEASE="$(git describe --tags --exact-match "$COMMIT" 2>/dev/null | sed 's/^v//' || true)"
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

# 3c. Lua fast path (docs/KERNEL.md, 05/11). Half of all changes touch only files nothing compiles
#     (Lua core, docs, scripts, tests, UI). Those keep the installed binary - built by an earlier
#     deploy and verified then - and install only the Lua tree beside it (lua-core/, every file pinned,
#     plus the binary's capability digest; the binary refuses a tree whose digest differs from its own).
#     Anything compiled - rust/, wit/ (host bindings are generated from it), Cargo files, code-mode build
#     inputs - takes the full build below. WA_DEPLOY_FULL=1 forces the full build.
#
#     "Which paths are compiled inputs" is NOT spelled here: scripts/lib/node-binaries.sh's
#     wa_compiled_input is the one definition, and the same function digests a published release's
#     compiled inputs (job relmatch), so "this change needs no new binary" and "that release IS this
#     commit's binary" can never disagree about the same file.
LUA_FAST=0
# The commit whose build the installed binary is (a previous fast path keeps it in binary_commit=).
INSTALLED_BINARY_COMMIT="$(sed -n 's/^binary_commit=//p' "$INSTALL_DIR/installed.txt" 2>/dev/null | head -1 | tr -d '[:space:]')"
[ -n "$INSTALLED_BINARY_COMMIT" ] || INSTALLED_BINARY_COMMIT="$INSTALLED_COMMIT"
INSTALLED_BIN="$INSTALL_DIR/wa"; [ -f "$INSTALLED_BIN.exe" ] && INSTALLED_BIN="$INSTALLED_BIN.exe"
# The fast path needs a binary that *runs* a staged Lua tree, not one that only verifies it. `--lua-tree`
# proves the bytes are complete and compatible; the property the fast path depends on is that the runtime
# then prefers those bytes over its compiled-in copy, because the deploy's own embedded check compares
# `EMBEDDED` against the tree. Measured 10/11 on wasm_the_first: the installed `a408c11b` verified a staged
# `67724745` tree with `--lua-tree` and then ran its own copy, so the check failed on the first differing
# module (`stale embedded module: lua/core/server.lua`) and the fast path could never install a Lua change
# there - the deploy refused, correctly, and the node stayed behind. This probe makes that decision in the
# one place it can still change the outcome: before the binary is chosen. Read-only, a throwaway tree.
lua_tree_mode() { # <binary> -> 0 when it runs the Lua tree it is given
  local binary="$1" dir home name out digest
  dir="$(mktemp -d)" || return 1
  home="$(mktemp -d)" || { rm -rf "$dir"; return 1; }
  mkdir -p "$dir/lua/core" "$dir/lua/vendor" 2>/dev/null || { rm -rf "$dir" "$home"; return 1; }
  cp "$ROOT/lua/core/init.lua" "$dir/lua/core/init.lua" 2>/dev/null || { rm -rf "$dir" "$home"; return 1; }
  name="lua/vendor/json.lua"
  { cat "$ROOT/$name" 2>/dev/null; printf '\n-- wa-lua-tree-mode-probe\n'; } > "$dir/$name" || { rm -rf "$dir" "$home"; return 1; }
  digest="$("$binary" --capability-digest 2>/dev/null | tr -d '[:space:]')"
  {
    printf 'capabilities %s\ncommit probe\n' "$digest"
    for name in lua/core/init.lua lua/vendor/json.lua; do
      printf '%s  %s\n' "$(sha256sum < "$dir/$name" | awk '{print $1}')" "$name"
    done
  } > "$dir/manifest.txt" || { rm -rf "$dir" "$home"; return 1; }
  local dir_arg="$dir" home_arg="$home" script_arg="$ROOT/scripts/probe-lua-tree-mode.lua"
  if command -v cygpath >/dev/null 2>&1; then
    dir_arg="$(cygpath -w "$dir")"; home_arg="$(cygpath -w "$home")"; script_arg="$(cygpath -w "$script_arg")"
  fi
  out="$(WA_LUA_TREE="$dir_arg" WASM_AGENT_LUA_ROOT='' WASM_AGENT_HOME="$home_arg" WA_SCRIPT="$script_arg" \
    timeout 60 "$binary" --db "$home_arg/probe.db" 2>&1)"
  rm -rf "$dir" "$home"
  case "$out" in *"lua tree mode ok"*) return 0 ;; esac
  return 1
}

if [ "${WA_DEPLOY_FULL:-0}" != 1 ] && [ -n "$INSTALLED_COMMIT" ] && [ -x "$INSTALLED_BIN" ] \
   && git merge-base --is-ancestor "$INSTALLED_COMMIT" HEAD 2>/dev/null; then
  CHANGED="$(git diff --name-only "$INSTALLED_COMMIT" HEAD)"
  COMPILED="$(printf '%s\n' "$CHANGED" | while IFS= read -r changed_path; do
    [ -n "$changed_path" ] || continue
    if command -v wa_compiled_input >/dev/null 2>&1; then
      wa_compiled_input "$changed_path" && printf '%s\n' "$changed_path"
    else
      # No node-binaries lib beside this deploy: fall back to the spelling this section used to carry, so a
      # missing helper costs the digest fallback and not the fast path.
      case "$changed_path" in
        lua/*|docs/*|tests/*|ui/*|modules/*|skills/*|jobs/*|benchmarks/*|review/*|reviews/*|review-evidence/*|fixtures/*|vault/*|scripts/*)
          case "$changed_path" in scripts/codemode*|scripts/build-*|scripts/provision-codemode*) printf '%s\n' "$changed_path" ;; esac ;;
        */*) printf '%s\n' "$changed_path" ;;
        *.md) ;;
        *) printf '%s\n' "$changed_path" ;;
      esac
    fi
  done)"
  INSTALLED_DIGEST="$("$INSTALLED_BIN" --capability-digest 2>/dev/null | tr -d '[:space:]')"
  if [ -n "$CHANGED" ] && [ -z "$(printf '%s' "$COMPILED" | tr -d '[:space:]')" ] && printf '%s' "$INSTALLED_DIGEST" | grep -qE '^[0-9a-f]{64}$'; then
    LUA_FAST=1
    echo "deploy: Lua fast path - $(printf '%s\n' "$CHANGED" | wc -l | tr -d ' ') changed file(s) since $INSTALLED_COMMIT, none compiled; keeping the installed binary"
    if ! lua_tree_mode "$INSTALLED_BIN"; then
      LUA_FAST=0
      echo "deploy: the installed binary does not run a staged Lua tree (it predates that mode, so its own copy would answer); building $COMMIT instead of reusing it"
    fi
  fi
fi

if [ "$LUA_FAST" = 1 ]; then
  wa_phase fetching
  wa_phase compiling
  WA_STATUS_DONE=0
  NEW="$INSTALLED_BIN"
  NEW_SENTINEL="$INSTALL_DIR/wa-sentinel"; [ -f "$NEW_SENTINEL.exe" ] && NEW_SENTINEL="$NEW_SENTINEL.exe"
  [ -x "$NEW_SENTINEL" ] || fail "Lua fast path: no installed sentinel at $NEW_SENTINEL"
  case "$(echo "$NEW_SENTINEL" | tr '[:upper:]' '[:lower:]')" in *.exe) SENTINEL_NAME="wa-sentinel.exe" ;; *) SENTINEL_NAME="wa-sentinel" ;; esac
  BUILD_LOGS="${WASM_AGENT_DATA:-${WASM_AGENT_HOME:-$HOME}/.wasm-agent}/build-logs"
  echo "deploy: compiled 0 crate(s) (Lua fast path)"
else
# 3d. The binary: a published build of THIS commit and this target, when there is one
#     (docs/COMPONENTS.md "The node binary itself", scripts/lib/node-binaries.sh). Two outcomes differ:
#     a refusal - node_hash_mismatch, node_size_mismatch, node_machine_mismatch, node_manifest_commit_mismatch
#     - means the bytes that claim to be this commit's are not, and the deploy stops with nothing
#     installed. Only "nothing is published for this commit and this target" reaches the build below, and
#     only when the disk can pay for one: a node that cannot afford a rebuild is the reason this path
#     exists (openclaw: 2 cores, 99% disk, and the wasmtime 50 upgrade is a full rebuild of ~600 crates).
#
#     The prove gate below is NOT skipped for a published binary. A release is a claim made by a script
#     on another machine; this deploy still proves the bytes on a scratch port, against the staged Lua
#     tree and the staged component, and records where they came from.
# wa-deploy-prebuilt-branch: begin
PREBUILT_BINARIES=0
BINARY_PROVENANCE="clean-built-by-deploy"
BINARY_RELEASE=""
# The commit the installed bytes are a build of, when that is not this tree's commit: a commit that
# changes no compiled input is installed from the newest published release of the same compiled inputs
# (scripts/lib/node-binaries.sh, wa_node_release_digest_search), so installed.txt must be able to name
# both the release and its source commit beside this tree's own commit=. Empty means "this tree's".
BINARY_SOURCE_COMMIT=""
# The directory the manifest verified (and its triple), from the `binary_verified:` line below: the
# sentinel install step reads the prebuilt supervisor back out of it. Empty on the build path.
BINARY_DIR=""
BINARY_TRIPLE=""
SENTINEL_SOURCE=""
BINARY_STAGE="$INSTALL_DIR/node-binary.next"
if [ "${WA_DEPLOY_BUILD_ONLY:-0}" = 1 ]; then
  echo "deploy: WA_DEPLOY_BUILD_ONLY=1 - this tree builds its own binary; no published one is installed"
elif ! command -v wa_node_binaries_prepare >/dev/null 2>&1; then
  note "no node-binaries helper beside this deploy (scripts/lib/node-binaries.sh), so no published binary was tried"
elif [ -z "$(wa_node_target_triple 2>/dev/null)" ]; then
  # A host with no published target (Windows, an architecture this channel does not ship) is not a node
  # that fell back: it builds, exactly as it always did, and the disk floor is not even asked - refusing
  # it there would be a refusal about a channel that was never meant for it (scripts/test-deploy-
  # preconditions.sh: a machine without cargo must still be refused as cargo_unavailable, not as this).
  note "this host ($(uname -s 2>/dev/null)/$(uname -m 2>/dev/null)) has no published node-binary target (Linux aarch64 and x86_64 only); building this tree"
else
  rm -rf "$BINARY_STAGE"
  wa_phase fetching
  echo "deploy: looking for a published binary for $(git rev-parse --short HEAD) ($(wa_node_target_triple 2>/dev/null || echo 'no published target for this host'))"
  BINARY_PLAN="$(wa_node_binaries_prepare "$ROOT" "$(git rev-parse HEAD)" "$BINARY_STAGE" "$INSTALL_DIR" 2>&1)"; BINARY_RC=$?
  while IFS= read -r binary_line; do
    [ -n "$binary_line" ] || continue
    case "$binary_line" in
      binary_source:*) echo "deploy: $binary_line" ;;
      binary_release:*)
        # `<tag> <40-hex source commit>`: the bytes are a published release's build of a DIFFERENT commit
        # than this tree's, which the digest fallback accepts because this commit changes no compiled
        # input. Both facts are recorded; neither is inferred later.
        BINARY_VERIFIED="${binary_line#binary_release: }"
        BINARY_RELEASE="${BINARY_VERIFIED%% *}"
        BINARY_SOURCE_COMMIT="${BINARY_VERIFIED##* }"
        ;;
      binary_verified:*)
        # `<triple> <dir> <sha12>`, read by field so a directory with a space in it survives: the last
        # space separates the sha12, and what is to the left of it is the directory.
        BINARY_VERIFIED="${binary_line#binary_verified: }"
        BINARY_TRIPLE="${BINARY_VERIFIED%% *}"
        BINARY_VERIFIED="${BINARY_VERIFIED#* }"
        BINARY_DIR="${BINARY_VERIFIED% *}"
        ;;
      *) note "binary: $binary_line" ;;
    esac
  done <<BINARY_LINES
$BINARY_PLAN
BINARY_LINES
  case "$BINARY_RC" in
    0)
      PREBUILT_BINARIES=1
      NEW="$BINARY_STAGE/wa"
      NEW_SENTINEL="$BINARY_STAGE/wa-sentinel"
      # Presence, not the exec bit: a filesystem where `chmod` is a no-op (this checkout's /c mount) would
      # refuse a good binary, and the prove gate below executes it anyway - a file that cannot run fails there.
      [ -f "$NEW" ] && [ -f "$NEW_SENTINEL" ] || fail "refused(prebuilt_binary_incomplete): the staged binary is missing $NEW or $NEW_SENTINEL; nothing installed"
      SENTINEL_NAME="wa-sentinel"
      if [ -n "${WA_DEPLOY_BINARY_SOURCE:-}" ]; then
        BINARY_PROVENANCE="prebuilt-source"
        BINARY_COMMIT="$(git rev-parse HEAD)"
        BINARY_RELEASE="$WA_DEPLOY_BINARY_SOURCE"
        BINARY_SOURCE_COMMIT=""
      else
        BINARY_PROVENANCE="prebuilt-release"
        BINARY_COMMIT="$(git rev-parse HEAD)"
        BINARY_RELEASE="${BINARY_RELEASE:-$(wa_node_release_tag "$BINARY_COMMIT")}"
        BINARY_SOURCE_COMMIT="${BINARY_SOURCE_COMMIT:-$BINARY_COMMIT}"
      fi
      # The supervisor comes from the SAME verified directory, and it must still be the bytes the manifest
      # pins. WHY (openclaw, 06/11, the first prebuilt deploy of 75ac2964): the node installed and the
      # deploy then refused - `could not install wa-sentinel - it is still the old build; the node and its
      # supervisor would disagree` - because this script removes the staging directory (below, once the
      # proved node has been copied to its hash-named candidate) while the sentinel step was still reading
      # `$BINARY_STAGE/wa-sentinel` out of it. A prebuilt deploy has to install the prebuilt supervisor, so
      # that step takes it from the directory the manifest verified, and re-reads the pin here rather than
      # trusting the fetch: a cache entry is a directory on disk like any other.
      SENTINEL_SOURCE=""
      # Which commit's names the verified directory carries: the release's own when the bytes came from an
      # older commit's release (BINARY_SOURCE_COMMIT), this tree's otherwise. A prebuilt directory names its
      # files after the commit they were verified against, and that is the release's.
      BINARY_ASSET_COMMIT="${BINARY_SOURCE_COMMIT:-$BINARY_COMMIT}"
      if [ -n "$BINARY_DIR" ] && command -v wa_node_sentinel_file >/dev/null 2>&1; then
        if ! SENTINEL_SOURCE="$(wa_node_sentinel_file "$BINARY_DIR" "$BINARY_ASSET_COMMIT" "$BINARY_TRIPLE" 2>&1)"; then
          fail "refused(prebuilt_sentinel_missing): $SENTINEL_SOURCE; nothing installed"
        fi
        # The cache entry is a download, not a staged file: the staging copy this deploy used to install was
        # the one wa_node_binary_stage chmod'ed, and it is gone by now. A supervisor nobody can execute is
        # not an install, so set the bit here, on the same rule the staging step uses (best effort: a
        # filesystem without exec bits - a Windows mount - has nothing to set).
        chmod +x "$SENTINEL_SOURCE" 2>/dev/null || true
        if SENTINEL_PIN="$(wa_node_sentinel_pin "$BINARY_DIR" "$BINARY_ASSET_COMMIT" "$BINARY_TRIPLE" 2>/dev/null)"; then
          SENTINEL_SHA="$(wa_node_sha256 "$SENTINEL_SOURCE")" \
            || fail "refused(prebuilt_sentinel_unverifiable): no sha256sum or shasum here, so $SENTINEL_SOURCE cannot be checked against the manifest; nothing installed"
          [ "$SENTINEL_SHA" = "$SENTINEL_PIN" ] \
            || fail "refused(prebuilt_sentinel_mismatch): $SENTINEL_SOURCE is $SENTINEL_SHA and the manifest pins $SENTINEL_PIN, so this is not the supervisor that belongs to $BINARY_ASSET_COMMIT; nothing installed"
          echo "deploy: the prebuilt sentinel is the manifest's pinned bytes ($SENTINEL_SHA)"
        else
          note "$BINARY_DIR carries no manifest row for $BINARY_TRIPLE (WA_DEPLOY_BINARY_SOURCE), so the prebuilt sentinel is installed on the node's own proof below and not on a pin"
        fi
      else
        note "the prebuilt step named no verified directory, so the supervisor is taken from the staging copy"
      fi
      echo "deploy: installing the published binary; the prove gate below runs on it, then upgrade.sh"
      ;;
    8)
      # Nothing published for this commit/target (or this host has no published target), and - since the
      # resolver also asks whether the newest release of the same compiled inputs exists - nothing published
      # matches this commit's compiled inputs either. Building is the answer only if the disk can pay for a
      # run: the same floor scripts/test.sh refuses below.
      if command -v wa_node_disk_floor_ok >/dev/null 2>&1 && wa_node_disk_floor_ok "$ROOT"; then
        echo "deploy: no published binary for this commit; building this tree (disk floor ok)"
      else
        fail "refused(no_prebuilt_binary_and_disk_floor): no published binary for $(git rev-parse --short HEAD) on $(wa_node_target_triple 2>/dev/null || echo 'this host'), and this machine is below the disk floor a build needs - so neither path can install this commit. Publish it (bash scripts/publish-node-binaries.sh on a machine with cargo, then the printed gh command), pass WA_DEPLOY_BINARY_SOURCE=<dir>, or free space (scripts/reclaim-disk.sh). Nothing installed."
      fi
      ;;
    *)
      fail "refused(prebuilt_binary_refused): $BINARY_PLAN; nothing installed"
      ;;
  esac
fi
# wa-deploy-prebuilt-branch: end
if [ "$PREBUILT_BINARIES" = 0 ]; then
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
CARGO_REFUSAL="refused(cargo_unavailable): cargo is not on PATH (PATH=${PATH:-unset}); this step builds the tree with 'cargo build --release --offline --manifest-path rust/Cargo.toml', so a deploy without it cannot build what it would install. Install Rust (https://rustup.rs), or run the deploy on the tree that has the toolchain (the cloud tree builds this repository). Nothing was built and nothing was installed. To build or test without installing, use the gate's own command instead: bash scripts/test.sh."
# Every requirement of the build, from the files the toolchains leave behind - no cargo run, no network
# (scripts/lib/build-requirements.sh; ~40 ms when all is present). A missing one is provisioned when it can
# be (the code-mode assets always, as before; cargo and node when WA_BUILD_PROVISION=1 says this machine
# wants the sentinel to fetch them), and otherwise refused by the name a caller already reads.
deploy_requirements() {
  local check id detail
  if ! command -v wa_build_check >/dev/null 2>&1; then
    command -v cargo >/dev/null 2>&1 || fail "$CARGO_REFUSAL"
    return 0
  fi
  check="$(wa_build_check "$ROOT")" && { printf '%s\n' "$check" | grep '^low' | sed 's/^/deploy: requirement /'; return 0; }
  printf '%s\n' "$check" | grep -v '^ok' | sed 's/^/deploy: requirement /'
  WA_BUILD_MISSING="$(printf '%s\n' "$check" | awk '$1 == "missing" { printf " %s", $2 }')"
  for id in $WA_BUILD_MISSING; do
    detail="$(printf '%s\n' "$check" | sed -n "s/^missing $id *//p" | head -1)"
    case "$id:${WA_BUILD_PROVISION:-0}" in
      cargo:1|node:1|assets:*)
        [ "$id" = assets ] && note "code-mode assets not prepared; provisioning the pinned, checksum-verified packages"
        wa_phase provisioning "$id"
        wa_build_provision "$ROOT" "$id" || case "$id" in
          assets) fail "codemode_assets_unprovisioned: scripts/provision-codemode-assets.mjs could not prepare $(wa_codemode_assets_dir "$ROOT") (network to the npm registry?); nothing installed" ;;
          *) fail "refused(${id}_unprovisioned): $detail, and fetching it failed; nothing installed" ;;
        esac ;;
      cargo:*) fail "$CARGO_REFUSAL" ;;
      node:*) fail "codemode_build:node_build_tool_unavailable; nothing installed" ;;
      *) fail "refused(${id}_unavailable): $detail; nothing installed" ;;
    esac
  done
  wa_build_check "$ROOT" >/dev/null || fail "refused(requirements_unmet): still missing after provisioning:$WA_BUILD_MISSING; nothing installed"
  wa_phase preflight
}
deploy_requirements

# A deploy and onStale both build into rust/target/release. They must not do it at the same time:
# on 2026-10-22 onStale's build overwrote the deploy's proved candidate between proof and install, and
# the deploy correctly refused an installed binary that was not the proved one. The lock itself - and the
# reclaim of a dead holder's lock, with its evidence - is scripts/lib/deploy-lock.sh, tested by
# scripts/test-deploy-lock.sh. A live holder refuses; a holder whose pid is gone is moved aside and logged.
DEPLOY_LOCK="$INSTALL_DIR/.deploy.lock"
DEPLOY_LOCK_LOG="$INSTALL_DIR/deploy-lock.log"
DEPLOY_LOCK_LIB="$SOURCE_ROOT/scripts/lib/deploy-lock.sh"
[ -f "$DEPLOY_LOCK_LIB" ] || DEPLOY_LOCK_LIB="$(dirname "$0")/lib/deploy-lock.sh"
[ -f "$DEPLOY_LOCK_LIB" ] || fail "refused(deploy_lock_lib_missing): $DEPLOY_LOCK_LIB is not in this tree, so the build lock cannot tell a dead holder from a live one; nothing built"
. "$DEPLOY_LOCK_LIB"
if ! wa_deploy_lock_claim "$DEPLOY_LOCK" "$DEPLOY_LOCK_LOG" "$SOURCE_ROOT"; then
  fail "${WA_DEPLOY_LOCK_REASON:-another deploy/onStale build holds $DEPLOY_LOCK; nothing built}"
fi
trap 'wa_deploy_lock_release "$DEPLOY_LOCK" "$DEPLOY_LOCK_LOG"' EXIT

# 3c. PIN THE COMMIT THE BUILD READS. The build used to read the tree this command was pointed at, and on
#     wasm_the_first a landing merged into the canonical checkout while a deploy was staging it: the staged
#     tree named one commit's server.lua and the check read another's (`stale embedded module:
#     lua/core/server.lua`), three deploys failed in one night, and commit 2231fc6f could only make the
#     race retryable. Here the deploy takes the landing queue's own lease (so it waits for a landing in
#     progress, and a landing waits for it), creates a DETACHED worktree at the exact commit, and releases
#     the lease. Every later step - cargo, codemode, the Lua stage, the components, the shipped scripts -
#     reads only the pinned tree, which no landing can move because it is not the canonical checkout.
WA_DEPLOY_PIN="${WA_DEPLOY_PIN:-1}"
BUILD_PIN=""
BUILD_PIN_ROOT=""
if [ "$WA_DEPLOY_PIN" = "1" ]; then
  PIN_COMMIT="$(git rev-parse HEAD)"
  PIN_DIR="${WA_DEPLOY_PIN_DIR:-${TMPDIR:-/tmp}/wa-deploy-pins}"
  PIN_WAIT="${WA_DEPLOY_PIN_WAIT:-600}"
  PIN_OUT="$(mktemp 2>/dev/null || echo "$INSTALL_DIR/.deploy-pin.$$.json")"
  PIN_ERR="$(mktemp 2>/dev/null || echo "$INSTALL_DIR/.deploy-pin.$$.err")"
  if ! command -v node >/dev/null 2>&1; then
    rm -f "$PIN_OUT" "$PIN_ERR"
    fail "refused(pin_tool_unavailable): node is not on PATH, so this deploy cannot take the landing queue's lease and pin the commit it would build. A deploy never builds from the live canonical tree, because a landing can move it under the build. Install node, or set WA_DEPLOY_ALLOW_UNPINNED=1 as an explicit exception. Nothing was built."
  fi
  if ! ( cd "$SOURCE_ROOT" && node scripts/landing-queue.mjs pin --commit "$PIN_COMMIT" --pin-dir "$PIN_DIR" \
        --wait-timeout "$PIN_WAIT" --json ) > "$PIN_OUT" 2> "$PIN_ERR"; then
    PIN_REASON="$(tail -3 "$PIN_ERR" 2>/dev/null | tr '\n' ' ')"
    rm -f "$PIN_OUT" "$PIN_ERR"
    if [ "${WA_DEPLOY_ALLOW_UNPINNED:-0}" = "1" ]; then
      note "WA_DEPLOY_ALLOW_UNPINNED=1: building from $SOURCE_ROOT although the pin failed: $PIN_REASON"
    else
      fail "refused(deploy_pin_failed): could not pin $PIN_COMMIT for the build: ${PIN_REASON:-the queue gave no reason}. A deploy never builds from the live canonical tree, because a landing can move it under the build. Nothing was built. 'node scripts/landing-queue.mjs status' names the holder, if a landing is in progress."
    fi
  else
    BUILD_PIN_ROOT="$(node -e 'const fs=require("fs");const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));process.stdout.write(j.pin||"")' "$PIN_OUT" 2>/dev/null)"
    rm -f "$PIN_OUT" "$PIN_ERR"
    if [ -z "$BUILD_PIN_ROOT" ] || [ ! -d "$BUILD_PIN_ROOT" ]; then
      fail "refused(deploy_pin_unreadable): the queue answered but named no pinned worktree; nothing was built"
    fi
    BUILD_PIN="$PIN_COMMIT"
    ROOT="$BUILD_PIN_ROOT"
    export WA_DEPLOY_ROOT="$ROOT"
    cd "$ROOT" || fail "cannot enter the pinned worktree $ROOT"
    echo "deploy: building $PIN_COMMIT from pinned worktree $ROOT (the source checkout $SOURCE_ROOT stays free for landings)"
  fi
fi

# A queued/running upgrade and a deploy both install the same binary and record. Refuse a deploy
# while an upgrade is active; onStale stands down on the shared lock for the build phase.
QUEUE_DIR="${WA_SENTINEL_DIR:-$HOME/.wasm-agent/sentinel}/queue"
UPGRADE_ACTIVE=0
for qf in "$QUEUE_DIR"/*.json; do
  [ -f "$qf" ] || continue
  grep -q '"verb":"upgrade"' "$qf" 2>/dev/null || continue
  if grep -q '"state":"running"' "$qf" 2>/dev/null || grep -q '"state":"queued"' "$qf" 2>/dev/null; then
    UPGRADE_ACTIVE=1; break
  fi
done
[ "$UPGRADE_ACTIVE" = "0" ] || fail "an upgrade request is active; refusing a second install"

# Where the compile writes. The pin above is a fresh worktree per commit, so a target dir inside it is
# cold on every deploy: measured 336 s of a 481 s deploy on wasm_the_first (2026-11-11) for a landing
# that changed no Rust at all. The target dir is build output, not state, so it lives in the data dir
# and is reused: a deploy whose Rust did not change recompiles only what its source path moved.
# WA_DEPLOY_BUILD_TARGET names another directory; a directory that cannot be created or written falls
# back to the pin's own target, which is the old (cold) behaviour and never a failed deploy.
DEPLOY_DATA="${WASM_AGENT_DATA:-${WASM_AGENT_HOME:-$HOME}/.wasm-agent}"
DEPLOY_BUILD_TARGET="${WA_DEPLOY_BUILD_TARGET:-$DEPLOY_DATA/build-cache/target}"
# A POSIX path handed to a native Windows process is silently unusable (AGENTS.md): cargo would write to
# C:\c\Users\... and this deploy would then look for the binary where it is not. Measured 2026-11-11: a
# build under /c/... created a stray C:\c tree. Convert once, here, and hand every consumer the same string.
if command -v cygpath >/dev/null 2>&1; then DEPLOY_BUILD_TARGET="$(cygpath -m "$DEPLOY_BUILD_TARGET" 2>/dev/null || printf '%s' "$DEPLOY_BUILD_TARGET")"; fi
if mkdir -p "$DEPLOY_BUILD_TARGET" 2>/dev/null && [ -w "$DEPLOY_BUILD_TARGET" ]; then
  DEPLOY_BUILD_TARGET="$(cd "$DEPLOY_BUILD_TARGET" && pwd)"
  export WA_CODEMODE_TARGET_DIR="$DEPLOY_BUILD_TARGET"
  printf 'deploy: compiling into the reusable target %s (%s)\n' "$DEPLOY_BUILD_TARGET" \
    "${WA_DEPLOY_BUILD_TARGET:+named by WA_DEPLOY_BUILD_TARGET}" | sed 's/ ()$//'
else
  DEPLOY_BUILD_TARGET="$ROOT/rust/target"
  unset WA_CODEMODE_TARGET_DIR
  note "the reusable build target is not writable ($WA_DEPLOY_BUILD_TARGET); compiling into the pin's own cold target"
fi

# The builds below are --offline --locked on purpose: exactly the lockfile, no network while building. A
# machine that never built these crates has nothing in its cargo cache for them, so the lockfile's exact
# crates are fetched first (--locked: no resolution, no newer version). No network is not fatal here: the
# offline build then proves whether the cache already holds them. 28/10, openclaw: "failed to download
# cc v1.4.7" for the sentinel.
wa_phase fetching
for manifest in rust/Cargo.toml rust/wa-sentinel/Cargo.toml; do
  ( cd "$ROOT" && cargo fetch --locked --manifest-path "$manifest" >/dev/null 2>&1 ) \
    || note "cargo fetch for $manifest did not complete; the offline build uses what the cache already has"
done

# BEGIN native code-mode shipping build (also exercised without any installer).
CODEMODE_BUILD_SCRIPT="$ROOT/scripts/codemode-build.mjs"; CODEMODE_BUILD_ROOT="$ROOT"
if command -v cygpath >/dev/null 2>&1; then
  CODEMODE_BUILD_SCRIPT="$(cygpath -w "$CODEMODE_BUILD_SCRIPT")"; CODEMODE_BUILD_ROOT="$(cygpath -w "$CODEMODE_BUILD_ROOT")"
fi
# The assets a tree that never built a shipping binary lacks (openclaw 26/10 and 28/10: a missing
# receipt.json, so that node could not update itself) are provisioned by deploy_requirements above.
# cargo's stderr goes to a file this deploy follows (WA_BUILD_CARGO_LOG), so `Compiling <crate>` reaches
# build-status.json while it happens; the last build's log stays in <data>/build-logs for a failure.
BUILD_LOGS="${WASM_AGENT_DATA:-${WASM_AGENT_HOME:-$HOME}/.wasm-agent}/build-logs"
mkdir -p "$BUILD_LOGS" 2>/dev/null || BUILD_LOGS="$(mktemp -d)"
: > "$BUILD_LOGS/wa-host.log"
CARGO_LOG_ARG="$BUILD_LOGS/wa-host.log"; command -v cygpath >/dev/null 2>&1 && CARGO_LOG_ARG="$(cygpath -w "$CARGO_LOG_ARG")"
wa_phase compiling
wa_status_follow "$BUILD_LOGS/wa-host.log" compiling
WA_BUILD_CARGO_LOG="$CARGO_LOG_ARG" node "$CODEMODE_BUILD_SCRIPT" build "$CODEMODE_BUILD_ROOT" > "$BUILD_LOGS/wa-host.receipt.json" \
  || { tail -25 "$BUILD_LOGS/wa-host.log" 2>/dev/null | sed 's/^/  cargo: /' >&2; fail "native code-mode shipping build/readiness failed; nothing installed"; }
# END native code-mode shipping build.
wa_status_unfollow
WA_STATUS_DONE="$(wa_status_compiled "$BUILD_LOGS/wa-host.log")"
# The sentinel is its own crate, outside the `rust/` workspace (which lists only `wa-host`), so it is
# built with its own manifest. Asking the workspace for `-p wa-sentinel` fails - "package ID
# specification did not match any packages" - and that is how it came to be installed by hand at all.
: > "$BUILD_LOGS/wa-sentinel.log"
wa_status_follow "$BUILD_LOGS/wa-sentinel.log" compiling
( cd rust && CARGO_TARGET_DIR="$DEPLOY_BUILD_TARGET" cargo build --release --offline --locked --manifest-path wa-sentinel/Cargo.toml ) 2> "$BUILD_LOGS/wa-sentinel.log" \
  || { tail -25 "$BUILD_LOGS/wa-sentinel.log" 2>/dev/null | sed 's/^/  cargo: /' >&2; fail "the sentinel build failed"; }
wa_status_unfollow
echo "deploy: compiled $WA_STATUS_DONE + $(wa_status_compiled "$BUILD_LOGS/wa-sentinel.log") crate(s) (logs in $BUILD_LOGS)"
NEW="$DEPLOY_BUILD_TARGET/release/wa.exe"
[ -f "$NEW" ] || NEW="$DEPLOY_BUILD_TARGET/release/wa"
[ -x "$NEW" ] || fail "no built binary at $NEW"

# The supervisor is part of what this installs, and leaving it out is how the node and the thing that
# restarts it drifted apart: `deploy.sh` replaced `wa.exe` while `wa-sentinel.exe` stayed at whatever
# version was last placed by hand, so a fixed stop/start path sat in the repo uninstalled and the
# e2e test refused to run - "the installed sentinel is the one just built" is a check the test makes
# and the gate did not. The sentinel is the only process that can replace the node; shipping the node
# without shipping it is shipping half a node.
NEW_SENTINEL="$DEPLOY_BUILD_TARGET/release/wa-sentinel.exe"
[ -f "$NEW_SENTINEL" ] || NEW_SENTINEL="$DEPLOY_BUILD_TARGET/release/wa-sentinel"
[ -x "$NEW_SENTINEL" ] || fail "no built sentinel at $NEW_SENTINEL"
NEW_SENTINEL_LOWER="$(echo "$NEW_SENTINEL" | tr '[:upper:]' '[:lower:]')"
case "$NEW_SENTINEL_LOWER" in
  *.exe) SENTINEL_NAME="wa-sentinel.exe" ;;
  *)     SENTINEL_NAME="wa-sentinel" ;;
esac
fi

# 5. Prove it answers before it goes near the running node. A build that cannot start must not replace one
#    that is serving.
fi

# 3d. The Lua tree, on every deploy (fast or full): lua/core + lua/vendor (.lua, .sql) and the two
#     embedded AGENTS docs, pinned, with the capability digest of the binary being installed. The binary
#     prefers it over its compiled-in copy only when everything verifies; installing it on full builds
#     too keeps it equal to HEAD, so a stale tree can never shadow a newer binary.
LUA_STAGE="$INSTALL_DIR/lua-core.next"
NEW_DIGEST="$("$NEW" --capability-digest 2>/dev/null | tr -d '[:space:]')"
printf '%s' "$NEW_DIGEST" | grep -qE '^[0-9a-f]{64}$' || fail "the binary being installed cannot state its capability digest"
# Staging copies from a checkout another session can be landing into at the same moment, and the check
# below used to re-read that checkout later. Measured 10/11 on wasm_the_first: landing #28 merged
# 3bea7b97 - which rewrites lua/core/server.lua (87 lines) - into the canonical tree and rolled it back
# while a deploy was running; the staged tree named 67724745's server.lua, the check read 3bea7b97's, and
# the deploy refused with `stale embedded module: lua/core/server.lua` although nothing was wrong with
# either tree. Staging is only meaningful from a tree that holds still, so the source is recorded before
# and after the copy: one retry, and then a refusal that names the race instead of blaming the binary.
stage_lua_tree() {
  local head_before dirty_before head_after dirty_after
  head_before="$(git rev-parse HEAD 2>/dev/null)"; dirty_before="$(git status --porcelain 2>/dev/null)"
  rm -rf "$LUA_STAGE" && mkdir -p "$LUA_STAGE" || return 1
  {
    echo "capabilities $NEW_DIGEST"
    echo "commit $COMMIT"
    ( cd "$ROOT" && { find lua/core lua/vendor -type f \( -name '*.lua' -o -name '*.sql' \); printf '%s\n' AGENTS.orchestrator.md AGENTS.subagents.md; } | LC_ALL=C sort ) | while read -r f; do
      mkdir -p "$LUA_STAGE/$(dirname "$f")" && cp "$ROOT/$f" "$LUA_STAGE/$f" || exit 1
      printf '%s  %s\n' "$(sha256sum < "$ROOT/$f" | awk '{print $1}')" "$f"
    done
  } > "$LUA_STAGE/manifest.txt" || return 1
  head_after="$(git rev-parse HEAD 2>/dev/null)"; dirty_after="$(git status --porcelain 2>/dev/null)"
  [ "$head_before" = "$head_after" ] && [ "$dirty_before" = "$dirty_after" ] || return 2
  return 0
}
stage_lua_tree; STAGE_RC=$?
if [ "$STAGE_RC" = 2 ]; then
  echo "deploy: the source tree moved while the Lua tree was staged ($(git rev-parse --short HEAD 2>/dev/null)); staging it again"
  stage_lua_tree; STAGE_RC=$?
fi
case "$STAGE_RC" in
  0) ;;
  2) fail "the Lua tree cannot be staged from a tree that holds still: $ROOT moved twice while it was copied. A deploy stages from its pinned worktree (step 3c), so this means the pin itself is being written to - nothing was installed; inspect $ROOT, then deploy again." ;;
  *) fail "cannot write the Lua tree" ;;
esac
STAGE_CHECK="$(WA_LUA_TREE="$LUA_STAGE" "$NEW" --lua-tree 2>&1)"
case "$STAGE_CHECK" in "installed lua tree: commit $COMMIT"*) echo "deploy: $STAGE_CHECK" ;; *) fail "the staged Lua tree does not verify against the binary: $STAGE_CHECK" ;; esac
# Only the two proving runs below see the staged tree (WA_LUA_TREE on their command lines); upgrade.sh
# and the restarted node must not inherit it - after the swap the node reads <install>/lua-core.

# 3e. Pinned components, the thing the core cannot run without (stream C of docs/KERNEL.md). A `wa`
#     built from this tree serves every `host.graph_*` call from the `graph` component, so a node that
#     gets this core and no `graph.wasm` answers every graph verb with
#     `graph_component_unavailable: component_not_installed:graph` while /health stays green. The core
#     and its components are one install: the bytes are taken from components.lock (never guessed),
#     verified by sha256 AND size, and the candidate binary then proves the pair answers before either
#     replaces what is running.
#
#     The set is every name components.lock pins - not just `graph` - because a component that is
#     built and tested but never shipped is a component whose `WA_*_COMPONENT` flag silently falls back
#     to the native path (the 08/11 finding, docs/FEATURES.md). Installing it here does not enable it:
#     what a node routes to is `policy.json`'s `features` section, and this file pins what a node has.
#
#     Where the bytes come from (docs/COMPONENTS.md "Distributing components"): the copy this node
#     already has, the bundle it fetched for the same lock before, or the release
#     `components-<short sha of components.lock>` that scripts/publish-components.sh uploads once from
#     the machine that has wasi-sdk - so a node with no wasm toolchain deploys main with no manual step
#     at all. Every fetched bundle is verified against components.lock before it is cached or staged and
#     cached under the lock's sha (repeated deploys do not refetch). WA_DEPLOY_COMPONENT_SOURCE=<dir>
#     installs what another machine built by hand; with no pinned bytes reachable this tree builds the
#     component, which needs wasi-sdk because tree-sitter and SQLite are C, and a deploy that builds must
#     say WA_DEPLOY_COMPONENT_REPIN=1 because the bytes it just built are not the pinned ones.
if ! command -v wa_component_stage >/dev/null 2>&1; then
  fail "refused(component_installer_missing): scripts/lib/deploy-components.sh is not beside this deploy, so the shipped components cannot be pinned and installed; a core installed without them answers their calls with component_not_installed:<name>. Nothing installed."
fi
COMPONENT_DIR="$(wa_components_dir)"
COMPONENT_STAGE="$INSTALL_DIR/components.next"
# The shipped set is the lock's own list, read once: no name is guessed here, and a component added to
# components.lock is installed by the next deploy without editing this stage.
COMPONENT_NAMES="$(wa_components_shipped "$ROOT")" || fail "refused(component_lock_unreadable): components.lock is not readable beside this deploy; the shipped components cannot be pinned, so nothing installed."
[ -n "$COMPONENT_NAMES" ] || fail "refused(component_lock_empty): components.lock pins no component; nothing installed."
case " $(echo $COMPONENT_NAMES) " in *" graph "*) ;; *) fail "refused(component_lock_incomplete): components.lock does not pin graph, which every host.graph_* call runs; nothing installed." ;; esac
COMPONENT_COUNT="$(printf '%s\n' "$COMPONENT_NAMES" | wc -l | tr -d '[:space:]')"
rm -rf "$COMPONENT_STAGE" && mkdir -p "$COMPONENT_STAGE" || fail "cannot stage components in $COMPONENT_STAGE"
if ! COMPONENT_ERROR="$(wa_components_prepare "$ROOT" "$COMPONENT_STAGE" "$INSTALL_DIR" $COMPONENT_NAMES 2>&1)"; then
  fail "refused(component_not_installable): $COMPONENT_ERROR; nothing installed. Either let the deploy fetch the pinned bytes from the release that components.lock names (default; WA_COMPONENT_RELEASE_REPO=<owner/repo> if the release is not in origin's repo), install them from a directory (WA_DEPLOY_COMPONENT_SOURCE=<dir> holding <name>.wasm and <name>.json for every pinned name from the machine that built them), or accept a local build of this tree with WA_DEPLOY_COMPONENT_REPIN=1."
fi
# One line per component, either `component_source:` (which bytes and why) or a staging note. Read
# without a pipe, so the resolved source can name what the staged bytes are in the line below.
while IFS= read -r component_line; do
  [ -n "$component_line" ] || continue
  case "$component_line" in
    component_source:*)
      echo "deploy: $component_line"
      case "$component_line" in
        *" this tree ("*) COMPONENT_SOURCE_SAID="this tree" ;;
        *) COMPONENT_SOURCE_SAID="${component_line#component_source: }"; COMPONENT_SOURCE_SAID="${COMPONENT_SOURCE_SAID% (*}"; COMPONENT_SOURCE_SAID="${COMPONENT_SOURCE_SAID#* }" ;;
      esac ;;
    *) note "component: $component_line" ;;
  esac
done <<COMPONENT_LINES
$COMPONENT_ERROR
COMPONENT_LINES
COMPONENT_SHA="$(cat "$COMPONENT_STAGE/graph.wasm.sha256")"
COMPONENT_SOURCE_SAID="${COMPONENT_SOURCE_SAID:-unrecorded}"
[ -z "${WA_DEPLOY_COMPONENT_SOURCE:-}" ] || COMPONENT_SOURCE_SAID="$WA_DEPLOY_COMPONENT_SOURCE"
echo "deploy: graph component staged from $COMPONENT_SOURCE_SAID (sha256 $COMPONENT_SHA, $(wc -c < "$COMPONENT_STAGE/graph.wasm" | tr -d '[:space:]') bytes)"
# What the set is, in one line, so a deploy log says which components this install placed.
COMPONENT_SET=""
for component_name in $COMPONENT_NAMES; do
  COMPONENT_SET="$COMPONENT_SET $component_name:$(cut -c1-12 "$COMPONENT_STAGE/$component_name.wasm.sha256")"
done
echo "deploy: $COMPONENT_COUNT pinned component(s) staged:$COMPONENT_SET"
[ "${WA_DEPLOY_COMPONENTS_DRY_RUN:-0}" != 1 ] || echo "deploy: WA_DEPLOY_COMPONENTS_DRY_RUN=1 - the component will be proved but not installed"
# The pair has to answer, not merely load: a component built for another engine, or a core whose
# graph path is broken, fails here with nothing installed.
COMPONENT_PROOF_HOME="$(mktemp -d)"
if ! WA_COMPONENTS_DIR="$COMPONENT_STAGE" WASM_AGENT_HOME="$COMPONENT_PROOF_HOME" WASM_AGENT_MANAGED=0 \
  WA_GRAPH_WATCH=0 WA_SCRIPT="$ROOT/scripts/check-graph-component.lua" \
  env -u WASM_AGENT_RENDEZVOUS -u WASM_AGENT_RELAY -u WA_GRAPH_ROOT -u WA_GRAPH_DB \
  "$NEW" --db "$COMPONENT_PROOF_HOME/proof.db" >"$COMPONENT_PROOF_HOME/proof.log" 2>&1; then
  tail -5 "$COMPONENT_PROOF_HOME/proof.log" 2>/dev/null | sed 's/^/  component: /' >&2
  rm -rf "$COMPONENT_PROOF_HOME"
  fail "refused(component_proof_failed): the candidate binary did not answer a graph call through the staged component; nothing installed"
fi
COMPONENT_PROOF="$(grep -c 'graph component ok' "$COMPONENT_PROOF_HOME/proof.log" 2>/dev/null)"
rm -rf "$COMPONENT_PROOF_HOME"
[ "$COMPONENT_PROOF" = "1" ] || fail "refused(component_proof_failed): the graph proof did not print its verdict; nothing installed"
echo "deploy: the candidate binary answers graph calls through the staged component"

wa_phase proving
SCRATCH=$((PORT + 40))
SCRATCH_HOME="$(mktemp -d)"
# The binary is checked against the bytes it is about to install, not against the checkout they were
# copied from: that checkout can move between the staging and this line (the race named above), and the
# staged tree's own manifest already pins every file's sha256 and the binary's capability digest. A
deploy must never refuse because another session landed while it ran.
EMBEDDED_ROOT="$LUA_STAGE"; EMBEDDED_SCRIPT="$ROOT/scripts/check-embedded-runtime.lua"; EMBEDDED_HOME="$SCRATCH_HOME"
if command -v cygpath >/dev/null 2>&1; then
  EMBEDDED_ROOT="$(cygpath -w "$EMBEDDED_ROOT")"; EMBEDDED_SCRIPT="$(cygpath -w "$EMBEDDED_SCRIPT")"
  EMBEDDED_HOME="$(cygpath -w "$EMBEDDED_HOME")"
fi
# The shipping build (codemode-build.mjs) already ran this check, stricter, on these exact bytes; its receipt
# names their hash. Run once, not three times (here and upgrade.sh 1b took ~1.5 s each; 29/10).
NEW_HASH="$(sha256sum < "$NEW" 2>/dev/null | awk '{print $1}')"
EMBEDDED_PROVEN=""
if [ "$LUA_FAST" != 1 ] && [ -n "$NEW_HASH" ] && grep -q '"native_checked":true' "${BUILD_LOGS:-/nonexistent}/wa-host.receipt.json" 2>/dev/null \
  && grep -q "\"binary_sha256\":\"$NEW_HASH\"" "$BUILD_LOGS/wa-host.receipt.json" 2>/dev/null; then
  EMBEDDED_PROVEN="$NEW_HASH"
  echo "deploy: embedded native code mode proven by the shipping build on these bytes (${NEW_HASH:0:12})"
elif ! WA_LUA_TREE="$LUA_STAGE" WASM_AGENT_HOME="$EMBEDDED_HOME" WASM_AGENT_LUA_ROOT='' \
  WA_EMBEDDED_SOURCE_ROOT="$EMBEDDED_ROOT" WA_SCRIPT="$EMBEDDED_SCRIPT" \
  "$NEW" --db "$EMBEDDED_HOME/embedded.db"; then
  rm -rf "$SCRATCH_HOME"
  fail "embedded runtime check failed; not installing it"
fi
# The proof node is a throwaway: it must not announce itself to the fleet. Inheriting the rendezvous
# made every deploy register a fresh key that no one could ever remove (the stale-node pile, 04/11).
# Its own --db too: the default database follows HOME, not WASM_AGENT_HOME, so without it the proof
# node opened the live node's memory.db, where its startup recovery could touch live sessions.
env -u WASM_AGENT_RENDEZVOUS -u WASM_AGENT_RELAY WA_LUA_TREE="$LUA_STAGE" WASM_AGENT_MANAGED=0 WASM_AGENT_HOME="$SCRATCH_HOME" "$NEW" --db "$SCRATCH_HOME/scratch.db" serve --port "$SCRATCH" --client-port "$((SCRATCH + 1))" --ui "$ROOT/ui" >"$SCRATCH_HOME/out.log" 2>&1 &
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
# upgrade.sh skips its own scratch proof for a hash in this file (its cache of builds that answered): this one did.
if [ -n "$NEW_HASH" ]; then
  { tail -19 "$INSTALL_DIR/.upgrade-proof" 2>/dev/null; echo "$NEW_HASH"; } > "$INSTALL_DIR/.upgrade-proof.tmp" 2>/dev/null \
    && mv -f "$INSTALL_DIR/.upgrade-proof.tmp" "$INSTALL_DIR/.upgrade-proof" 2>/dev/null
fi

# The proved bytes are copied to an immutable, hash-named candidate before upgrade.sh sees them.
# A concurrent build can overwrite rust/target/release/wa.exe, but it cannot overwrite this file.
CANDIDATE_HASH="$(sha256sum < "$NEW" 2>/dev/null | awk '{print $1}')"
[ -n "$CANDIDATE_HASH" ] || fail "cannot hash the proved binary"
CANDIDATE="$ROOT/rust/target/release/wa-deploy-$CANDIDATE_HASH"
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) CANDIDATE="$CANDIDATE.exe" ;; esac
# A node that installs a published binary may never have built here, so the directory cargo would have
# made for its output does not exist yet (openclaw after this change: no target dir at all).
mkdir -p "$(dirname "$CANDIDATE")" || fail "cannot create the candidate directory $(dirname "$CANDIDATE")"
cp -f "$NEW" "$CANDIDATE" || fail "cannot preserve the proved candidate"
chmod +x "$CANDIDATE" 2>/dev/null || true
# The staged published binary has been copied to the hash-named candidate: the stage is not install state.
[ "${PREBUILT_BINARIES:-0}" = 1 ] && rm -rf "$BINARY_STAGE"

# 6. Install and restart, through the script that owns that job.
UPGRADE="$ROOT/scripts/upgrade.sh"
[ -f "$UPGRADE" ] || fail "no scripts/upgrade.sh to perform the install"
if [ -n "$EXPECTED_SHA" ]; then
  [ "$(git rev-parse HEAD)" = "$EXPECTED_SHA" ] && [ -z "$(git status --porcelain)" ] || fail "source changed from expected SHA before install"
fi
echo "deploy: installing through upgrade.sh"
wa_phase installing
# No log to follow: the heartbeat keeps the row alive through upgrade.sh's wait for an idle node.
wa_status_follow /dev/null installing
# Default runtime source is canonical main, not the producer/integration lane that
# happened to build this release. Selection is read-only and refuses dirty/stale
# canonical state; explicit overrides remain deliberate active-wave knobs.
if [ -z "${WA_RUNTIME_WORKTREE:-}" ]; then
  BINDING_SCRIPT="${SOURCE_ROOT:-$ROOT}/scripts/runtime-install-binding.mjs"; BINDING_REPO="${SOURCE_ROOT:-$ROOT}"
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

# The verified Lua tree replaces the previous one right before the restart. The running node read its
# Lua once at start, so the swap is invisible to it; a failed upgrade puts the previous tree back.
rm -rf "$INSTALL_DIR/lua-core.prev"
{ [ ! -d "$INSTALL_DIR/lua-core" ] || mv "$INSTALL_DIR/lua-core" "$INSTALL_DIR/lua-core.prev"; } && mv "$LUA_STAGE" "$INSTALL_DIR/lua-core" \
  || fail "cannot swap the Lua tree into $INSTALL_DIR/lua-core"
restore_lua_tree() {
  rm -rf "$INSTALL_DIR/lua-core"
  [ ! -d "$INSTALL_DIR/lua-core.prev" ] || mv "$INSTALL_DIR/lua-core.prev" "$INSTALL_DIR/lua-core"
}
# block swapped in next to the Lua tree swap
# The component set goes in with the same rule as the tree: the previous set is recorded and every
# previous triple kept, a failed upgrade puts the whole set back, and a first install is removed again
# rather than left half-done. WA_COMPONENTS_DIR is the directory the core reads
# (components::component_dir()) and it is NOT under the install directory, because it holds components
# that are not this core's (wa-whatsapp and friends): this deploy replaces the pinned set and leaves the
# rest alone. Installing is not enabling - `wa features` says which of them the node routes to.
wa_components_record_set "$COMPONENT_DIR" $COMPONENT_NAMES || note "component: could not record the previous component set in $COMPONENT_DIR/.prev (the rollback still restores each component from its own previous triple)"
if ! COMPONENT_INSTALL="$(wa_components_install_set "$COMPONENT_STAGE" "$COMPONENT_DIR" $COMPONENT_NAMES 2>&1)"; then
  rm -rf "$COMPONENT_STAGE"
  wa_components_restore_set "$COMPONENT_DIR" $COMPONENT_NAMES >/dev/null 2>&1 || true
  fail "refused(component_install_failed): $COMPONENT_INSTALL; the Lua tree is installed but the component set is not, so this node must not be restarted"
fi
[ -z "$COMPONENT_INSTALL" ] || note "component: $COMPONENT_INSTALL"
rm -rf "$COMPONENT_STAGE"
restore_components() {
  wa_components_restore_set "$COMPONENT_DIR" $COMPONENT_NAMES || echo "deploy: could not restore the previous component set in $COMPONENT_DIR" >&2
}

# 6a. The grant policy is installed BEFORE the restart, not after it.
#
# The production bug of 06/11: a deploy installed `policy.json` 24 s after the node had started, so the
# running node kept the policy it had loaded at start-up and refused every WhatsApp send with a rule
# the operator had just written - "node started 14:55:13, file written 14:55:37". The install block
# lived at the end of this script, after `upgrade.sh` had already restarted the node, and nothing said
# so. Two fixes, both needed and both tested: this ordering here, and the running node's own reload
# (`node_policy::reload` watches the file's mtime and sha256 and swaps the policy atomically, so a
# policy written by any means is enforced within a second without a restart). The second fix is the
# safety net; the order is the contract, because a node should not have to be running on the wrong
# policy for even a second. `scripts/test-deploy-policy-order.sh` reads this file and fails when the
# install drifts back below the restart.
POLICY_INSTALLER="$ROOT/scripts/lib/install-default-policy.sh"
[ -f "$POLICY_INSTALLER" ] || POLICY_INSTALLER="$(dirname "$0")/lib/install-default-policy.sh"
WA_POLICY_DEST="$SENTINEL_CONFIG/policy.json"
if [ -f "$POLICY_INSTALLER" ]; then
  . "$POLICY_INSTALLER"
  install_default_policy "$ROOT/policies/default.json" "$WA_POLICY_DEST"
  case $? in
    0) ;; # installed, merged, or an operator's file kept - every line is on stdout above
    2) note "no policies/default.json in $ROOT: policy.json was not installed; the node runs in manifest mode (the manifest grant is the only gate)" ;;
    *) note "policy.json could not be installed at $WA_POLICY_DEST; the node runs in manifest mode (the manifest grant is the only gate)" ;;
  esac
  # What the per-rule merge could NOT bring into the node's file: a rule both sides changed (the node's
  # version was kept) or a file with no provable base, where the release's new entries were named instead
  # of added. `note` puts it in deploy.log; `record_installed` carries the same sentence into installed.txt,
  # because a warning only a log reader sees is the kind nobody reads - which is how the 07/11 index writes
  # were refused release after release with nothing on the node saying the rule had never arrived.
  WA_POLICY_WARNINGS="$(policy_merge_warnings "$WA_POLICY_DEST")"
  [ -z "$WA_POLICY_WARNINGS" ] || note "policy: $WA_POLICY_WARNINGS"
else
  note "scripts/lib/install-default-policy.sh is not in this tree: policy.json was not installed"
fi

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
  WA_UPGRADE_REASON="$REASON" WA_UPGRADE_VIA=deploy.sh WA_UPGRADE_EMBEDDED_PROVEN="$EMBEDDED_PROVEN" \
  bash "$UPGRADE" "$CANDIDATE" > "$INSTALL_DIR/deploy-upgrade.log" 2>&1
# wa-deploy-upgrade-invocation: end
UPGRADE_STATUS=$?
wa_status_unfollow
# Reporting must never fail the deploy: with stdout gone, `sed` dies of EPIPE and pipefail would then report
# its status instead of upgrade.sh's.
sed "s/^/  upgrade: /" "$INSTALL_DIR/deploy-upgrade.log" 2>/dev/null | tail -20 || true
if [ "$UPGRADE_STATUS" != "0" ] && [ "$UPGRADE_STATUS" != "3" ]; then
  restore_lua_tree
  restore_components
fi
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
    # The shared probe (ss, netstat, then /proc): `ss` alone is missing from slim images, where this read
    # "pid " and failed a deploy that had worked (28/10).
    LISTENER="$(wa_port_pid "$PORT")" ;;
esac
# Who started the node is who recorded it: the sentinel (sentinel/node.json) when it supervises, else
# upgrade.sh's own serve.pid.
# A watching sentinel is not always the node's owner (openclaw: wa-serve.service owns it and upgrade.sh
# records the new pid in serve.pid), so the listener must match whichever record names it.
RECORDED="$(tr -d '[:space:]' < "$INSTALL_DIR/serve.pid" 2>/dev/null)"
if sentinel_supervises "$INSTALL_DIR"; then
  SENTINEL_RECORDED="$(sed -n 's/.*"pid":\([0-9]*\).*/\1/p' "${WASM_AGENT_HOME:-$HOME}/.wasm-agent/sentinel/node.json" 2>/dev/null | head -1)"
  [ -n "$SENTINEL_RECORDED" ] && [ "$SENTINEL_RECORDED" = "$LISTENER" ] && RECORDED="$SENTINEL_RECORDED"
fi
if [ -z "$RECORDED" ] || [ -z "$LISTENER" ] || [ "$RECORDED" != "$LISTENER" ]; then
  fail "the node answering on $PORT is pid $LISTENER, not the pid $RECORDED the install recorded - two nodes, one port"
fi
# An accumulated node.log can contain a bind error from a previous deployment.
# The recorded child owning this listener is the current startup verdict; a
# historical string is not evidence about that process. Also verify its artifact.
INSTALLED_NODE="$INSTALL_DIR/$(basename "$NEW")"
cmp -s "$CANDIDATE" "$INSTALLED_NODE" || fail "installed binary differs from the proved build"

# 8. Record what is installed, so "what is running" is answerable.
HASH="$(sha256sum < "$INSTALLED_NODE" 2>/dev/null | awk '{print $1}')"
[ -n "$HASH" ] || HASH="$(shasum -a 256 < "$INSTALLED_NODE" 2>/dev/null | awk '{print $1}')"

# The supervisor, installed *after* the node is confirmed answering - so a failed upgrade leaves a
# sentinel that still matches the node it supervises, rather than one rebuilt ahead of a node that
# rolled back. A running sentinel holds its own image open on Windows, so the copy is attempted and
# its failure is reported rather than fatal: the swap is completed by the one-shot restart below.
#
# WHERE THE BYTES COME FROM is one variable. The build path and the Lua fast path hand over the tree's own
# artifact ($NEW_SENTINEL, unchanged); a prebuilt install hands over the file the release's manifest pins
# (SENTINEL_SOURCE, resolved and sha-checked in the prebuilt branch above). The guard at the end of this
# block - "the installed file is the bytes this deploy meant to install" - therefore compares against the
# prebuilt supervisor's own bytes, not against a staging path that the same run may already have removed.
# wa-deploy-sentinel-install: begin
SENTINEL_SOURCE="${SENTINEL_SOURCE:-${NEW_SENTINEL:-}}"
[ -f "$SENTINEL_SOURCE" ] \
  || fail "refused(sentinel_source_missing): there is no supervisor to install at ${SENTINEL_SOURCE:-<unset>}; nothing installed"
SENTINEL_HASH="(none)"
SENTINEL_SWAP_STARTED=0
if [ -f "$INSTALL_DIR/$SENTINEL_NAME" ]; then
  cp -f "$SENTINEL_SOURCE" "$INSTALL_DIR/$SENTINEL_NAME" 2>/dev/null || true
  if cmp -s "$SENTINEL_SOURCE" "$INSTALL_DIR/$SENTINEL_NAME"; then
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
          cp -f "$SENTINEL_SOURCE" "$INSTALL_DIR/$SENTINEL_NAME" \
            || fail "sentinel stopped but replacement failed; inspect before recovery"
          "$INSTALL_DIR/$SENTINEL_NAME" start || fail "sentinel replacement placed but manager start failed"
          SENTINEL_SWAP_STARTED=1
          ;;
        *)
          cp -f "$SENTINEL_SOURCE" "$INSTALL_DIR/$SENTINEL_NAME.new.$$" 2>/dev/null || true
          mv -f "$INSTALL_DIR/$SENTINEL_NAME.new.$$" "$INSTALL_DIR/$SENTINEL_NAME" 2>/dev/null || true
          ;;
      esac
    fi
    if cmp -s "$SENTINEL_SOURCE" "$INSTALL_DIR/$SENTINEL_NAME"; then
      echo "deploy: sentinel $SENTINEL_NAME updated (the running watcher keeps its old image until the restart below)"
    else
      # Do not leave the staged image behind for a failure that is about to be reported: it is a whole
      # binary. What a SIGKILL here would leave is swept by sweep_stale_staging() on the next deploy.
      rm -f "$INSTALL_DIR/$SENTINEL_NAME.new.$$" 2>/dev/null || true
      fail "could not install $SENTINEL_NAME from $SENTINEL_SOURCE - it is still the old build; the node and its supervisor would disagree"
    fi
  fi
  SENTINEL_HASH="$(sha256sum < "$INSTALL_DIR/$SENTINEL_NAME" 2>/dev/null | awk '{print $1}')"
  [ -n "$SENTINEL_HASH" ] || SENTINEL_HASH="$(shasum -a 256 < "$INSTALL_DIR/$SENTINEL_NAME" 2>/dev/null | awk '{print $1}')"
else
  cp -f "$SENTINEL_SOURCE" "$INSTALL_DIR/$SENTINEL_NAME" 2>/dev/null || fail "could not place $SENTINEL_NAME"
  echo "deploy: sentinel $SENTINEL_NAME installed"
  SENTINEL_HASH="$(sha256sum < "$INSTALL_DIR/$SENTINEL_NAME" 2>/dev/null | awk '{print $1}')"
fi
# wa-deploy-sentinel-install: end

# The install's facts are true HERE - the node's bytes, the sentinel's bytes, the shipped upgrade.sh - so the
# record is written here, before the sentinel proof below, which can refuse entirely on its own. Measured
# 2026-10-20: six deploys installed correctly and every one of them left an `interim` record naming the
# PREVIOUS commit, because this step sat forty lines under a proof that kept failing; `verify-deployed.sh`
# then refused an install that was right, and the notice could only say "this does not establish what is
# installed". The record describes the install; the sentinel proof has its own verdict in deploy-result.json.
UPGRADE_HASH="$(sha256sum < "$INSTALL_DIR/scripts/upgrade.sh" 2>/dev/null | awk '{print $1}')"
[ -n "$UPGRADE_HASH" ] || UPGRADE_HASH=missing
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
  local record_tmp reason_line record_commit
  record_tmp="$INSTALL_DIR/.installed.txt.deploy.$$"
  reason_line="$(printf '%s' "$REASON" | tr '\r\n' '  ')"
  # Which commit the record NAMES. A prebuilt install names the 40-hex id the manifest was verified
  # against (node-binaries.sh compares source_commit to the full id; `node-<sha12>` is only the release's
  # name, and twelve hex can collide), so `commit=` is a full id there. The build path keeps writing the
  # short id it has always written: its ancestor and record checks read it the same way, and changing that
  # shape is not this rule's business.
  record_commit="$COMMIT"
  case "${BINARY_PROVENANCE:-}" in
    prebuilt-*) [ -n "${BINARY_COMMIT:-}" ] && record_commit="$BINARY_COMMIT" ;;
  esac
  # A prebuilt record's commit= is the manifest's 40-hex identity or it is not a record of a verified
  # install: a short id is a name that can collide, and it would be the id the checks downstream compare.
  # Checked BEFORE the write, so a record no reader can act on is never the one that lands.
  case "${BINARY_PROVENANCE:-}" in
    prebuilt-*)
      if [ "${#record_commit}" != 40 ] || [ -n "$(printf '%s' "$record_commit" | tr -d '0123456789abcdef')" ]; then
        fail "installed.txt would record commit=$record_commit for a prebuilt install, which is not a 40-hex commit id; the record must name the id the manifest was verified against"
      fi
      # ...and the commit the BYTES are a build of, when that is another one (the digest fallback): it is
      # the id a later fast-path deploy reads back as binary_commit=, so it is held to the same rule.
      if [ -n "${BINARY_SOURCE_COMMIT:-}" ] && { [ "${#BINARY_SOURCE_COMMIT}" != 40 ] || [ -n "$(printf '%s' "$BINARY_SOURCE_COMMIT" | tr -d '0123456789abcdef')" ]; }; then
        fail "installed.txt would record binary_source_commit=$BINARY_SOURCE_COMMIT, which is not a 40-hex commit id; the record must name the id the manifest's source_commit was verified against"
      fi ;;
  esac
  # `install_dir=` is the record's own statement of where it was written, and of which directory the machine
  # runs the node from. A record that cannot say that is a record a later reader has to guess about - and
  # `~/.wasm-agent/installed.txt`, empty on the node this rule was written for, is what guessing looks like.
  printf 'commit=%s\nbranch=%s\ndirty=%s\nsha256=%s\nsentinel_sha256=%s\nupgrade_sha256=%s\ninstall_dir=%s\nservice_install_dir=%s\nsource_provenance=clean-built-by-deploy\nrecord_role=final\nvia=deploy.sh\nsource_worktree=%s\nbuild_pin=%s\nat=%s\nreason=%s\n' \
    "$record_commit" "$BRANCH" "$DIRTY" "$HASH" "$SENTINEL_HASH" "$UPGRADE_HASH" "$INSTALL_DIR" "${WA_SERVICE_DIR:-unverified}" \
    "${SOURCE_ROOT:-$ROOT}" "${BUILD_PIN:-unpinned}" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$reason_line" \
    > "$record_tmp" || fail "node installed, but installed.txt could not be written"
  # `source_provenance=clean-built-by-deploy` keeps its meaning - the bytes are a clean build of exactly
  # this commit, verified by this deploy (pinned, hashed, proved on a scratch port), never an unverified
  # hand-placed binary - and WHERE the build ran is a separate fact, because a reader that conflates the
  # two would have to guess, and a node that installs a published binary must be able to say so.
  if [ -n "${BINARY_RELEASE:-}" ]; then
    # binary_commit= keeps its meaning for its existing readers (the Lua fast path reads it back as the
    # commit whose build the installed binary is): the bytes' own commit. binary_source_commit= is the same
    # fact under the name a digest-fallback install needs - the release's source commit, which differs from
    # this tree's commit= exactly when the install reused an older commit's compiled inputs.
    printf 'binary_source=%s\nbinary_release=%s\nbinary_commit=%s\nbinary_source_commit=%s\n' \
      "${BINARY_PROVENANCE:-prebuilt-release}" "$BINARY_RELEASE" \
      "${BINARY_SOURCE_COMMIT:-${BINARY_COMMIT:-$COMMIT}}" "${BINARY_SOURCE_COMMIT:-${BINARY_COMMIT:-$COMMIT}}" >> "$record_tmp" \
      || fail "node installed, but the binary source lines could not be written"
  fi
  # Appended as its own line, only when this commit is a release: a command substitution would strip the
  # newline and leave `reason=` and `release=` sharing a line, which no reader parses.
  if [ -n "$RELEASE" ]; then
    printf 'release=%s\n' "$RELEASE" >> "$record_tmp" || fail "node installed, but the release line could not be written"
  fi
  # The Lua tree this install runs (lua-core/), and for a fast-path deploy the commit whose build the
  # binary is: the binary was clean-built by that earlier deploy; this one installed only the tree.
  printf 'lua_tree=%s\nlua_fast_path=%s\n' "$COMMIT" "$LUA_FAST" >> "$record_tmp" || fail "node installed, but the Lua tree line could not be written"

  # Which component bytes this install placed, and where: the core answers every `host.graph_*` call
  # from them, so "what is running" includes them (a node whose graph component is missing answers
  # every graph call with component_not_installed:graph and looks healthy otherwise). `component_set=`
  # names the whole pinned set with the first 12 hex of each sha, so one line answers "which components
  # did this deploy install" - and `wa features` answers which of them the node routes to.
  printf 'components_dir=%s\ncomponent_graph_sha256=%s\ncomponent_set=%s\n' "${COMPONENT_DIR:-unrecorded}" "${COMPONENT_SHA:-unrecorded}" "${COMPONENT_SET:-unrecorded}" >> "$record_tmp" || fail "node installed, but the component lines could not be written"
  if [ "$LUA_FAST" = 1 ]; then
    printf 'binary_commit=%s\n' "$INSTALLED_BINARY_COMMIT" >> "$record_tmp" || fail "node installed, but the binary commit line could not be written"
  fi
  # The policy step's own warnings (6a), on one line: the rules this deploy could not bring into the
  # node's file because both sides had changed them, or a file with no provable base. installed.txt is what
  # a reader trusts for "what does this install do", so a conflict is named here and not only in deploy.log.
  if [ -n "${WA_POLICY_WARNINGS:-}" ]; then
    printf 'policy_warnings=%s\n' "$(printf '%s' "$WA_POLICY_WARNINGS" | tr '\r\n' '  ')" >> "$record_tmp" \
      || fail "node installed, but the policy warning line could not be written"
  fi
  mv -f "$record_tmp" "$INSTALL_DIR/installed.txt" \
    || fail "node installed, but installed.txt could not be committed atomically"
  # A record nobody can act on is worse than no record: `unknown` is exactly what a staleness check reads
  # as "nothing to do". Measured 2026-10-22 - the install succeeded and the record said commit=unknown, so
  # nothing downstream could tell what was running. Refuse to commit such a record instead.
  local recorded_commit
  recorded_commit="$(sed -n 's/^commit=//p' "$INSTALL_DIR/installed.txt" 2>/dev/null | head -1)"
  case "$recorded_commit" in
    ''|unknown) fail "installed.txt would record commit=unknown; refusing to write a record no check can use" ;;
  esac
}

# Record what is installed HERE, not only at the end. Every fact this record names - the exact commit, the
# binary hash, the sentinel hash, the install directory - is already true at this point, and the steps that
# follow (shipping scripts, putting job definitions) can still refuse or die. Writing it now means a deploy
# that dies after the node is installed leaves the deploy's own exact-commit record, not upgrade.sh's
# interim one - which is the state that made `verify-install.sh` report `installed unknown is not an
# ancestor of tree ...` on 2026-10-02. The write at step 8 confirms the same content as the deploy's last
# act, so "the final record is deploy.sh's" holds whichever of the two the run reaches.
record_installed
# Defined and called here, not a hundred lines down: 7d026c71 (22/10) fixed a call that ran above the
# definition (`command not found`, commit=unknown) by moving both below the sentinel proof, which undid
# 44af0cc9's rule above - a refused proof again left the interim record (found by test-deploy-record.sh on the
# v0.1.0-alpha.12 gate, 30/10).

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

# Ship this script BEFORE the sentinel proof, not after it. The comment that used to sit beside this block
# says a deploy "has to leave the next one able to run with no human at a shell" - and it was placed thirty
# lines below the one step that can refuse. MEASURED 2026-10-20: the installed copy read the status line by
# field position (`$2=="watching"`), the line grew an `up`, so the proof found no pid and refused AFTER the
# node was installed; the parser that reads the line by meaning was already in the tree (7f1300df) and could
# never arrive, because shipping it was the step the refusal skipped. Nine deploys, one afternoon. A deploy
# that fails its proof still leaves the next one able to read the line.
DEPLOY_SRC="$ROOT/scripts/deploy.sh"
[ -f "$DEPLOY_SRC" ] || DEPLOY_SRC="$0"
if [ -f "$DEPLOY_SRC" ]; then
  ship_file "$DEPLOY_SRC" "$INSTALL_DIR/scripts/deploy.sh" "deploy.sh beside the binary"
fi

# Replacing an executable file does not replace the already-running process.
# Even when the copy succeeds on Windows, a watcher can keep executing the old
# image indefinitely. Respect an intentionally stopped watcher; restart only
# one that was already watching, then prove its pid changed.
SENTINEL_WATCH_PID="$("$INSTALL_DIR/$SENTINEL_NAME" status 2>/dev/null \
  | awk '/^[ 	]*sentinel:/ && /watching/ && match($0, /pid[ 	]+[0-9]+/) { s = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", s); print s; exit }')"
if [ "$SENTINEL_SWAP_STARTED" = "1" ]; then
  # The Windows swap already loaded the candidate. A second restart would kill
  # work admitted by the fresh service for no installation benefit.
  [ -n "$SENTINEL_WATCH_PID" ] || fail "sentinel swap start answered but no watcher is proven"
  SENTINEL_NEW_PID="$SENTINEL_WATCH_PID"
  echo "deploy: sentinel swap already started the installed image (pid $SENTINEL_NEW_PID)"
elif [ -n "$SENTINEL_WATCH_PID" ] && [ -r "/proc/$SENTINEL_WATCH_PID/exe" ] \
  && cmp -s "/proc/$SENTINEL_WATCH_PID/exe" "$INSTALL_DIR/$SENTINEL_NAME"; then
  # The watcher already runs these exact bytes (a node-only change): a restart would load nothing (29/10).
  SENTINEL_NEW_PID="$SENTINEL_WATCH_PID"
  echo "deploy: the watching sentinel (pid $SENTINEL_WATCH_PID) already runs the installed image - not restarting it"
elif [ -n "$SENTINEL_WATCH_PID" ]; then
  echo "deploy: restarting the watching sentinel to load the installed image"
  sentinel_restart || fail "node installed, but the sentinel could not restart"
  SENTINEL_NEW_PID=""
  for _ in $(seq 1 50); do
    SENTINEL_NEW_PID="$("$INSTALL_DIR/$SENTINEL_NAME" status 2>/dev/null \
      | awk '/^[ 	]*sentinel:/ && /watching/ && match($0, /pid[ 	]+[0-9]+/) { s = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", s); print s; exit }')"
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
  env -u WA_DEPLOY_ROOT -u WA_DEPLOY_PIN -u WA_DEPLOY_PIN_DIR -u WA_DEPLOY_BUILD_TARGET \
    -u WA_CODEMODE_TARGET_DIR "$INSTALL_DIR/$SENTINEL_NAME" start || fail "node installed, but the sentinel would not start"
  SENTINEL_NEW_PID=""
  for _ in $(seq 1 50); do
    SENTINEL_NEW_PID="$("$INSTALL_DIR/$SENTINEL_NAME" status 2>/dev/null \
      | awk '/^[ 	]*sentinel:/ && /watching/ && match($0, /pid[ 	]+[0-9]+/) { s = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", s); print s; exit }')"
    [ -n "$SENTINEL_NEW_PID" ] && break
    sleep 0.1
  done
  if [ -z "$SENTINEL_NEW_PID" ]; then
    # This proof has failed on every deploy since 2026-10-20 14:56 while a watcher was demonstrably alive
    # (pid unchanged, `start` answering "already watching" in the same second). A refusal that names no
    # evidence cost five deploys their diagnosis, so print what the proof actually saw: the status line it
    # could not read, and the pid file the status binary resolved - which is `$HOME/.wasm-agent/sentinel`,
    # the one input that can differ between the watcher's environment and this deploy's.
    echo "deploy: the watcher proof saw no pid - last status from $INSTALL_DIR was:"
    "$INSTALL_DIR/$SENTINEL_NAME" status 2>&1 | head -6 | sed 's/^/    /'
    echo "    HOME=${HOME:-unset} -> ${HOME:-<unset>}/.wasm-agent/sentinel/sentinel.pid"
    echo "    USERPROFILE=${USERPROFILE:-unset}"
    echo "    on disk: $(cat "${HOME:-}/.wasm-agent/sentinel/sentinel.pid" 2>/dev/null || echo 'no pid file at that path')"
    fail "node installed, but the sentinel did not start watching"
  fi
  echo "deploy: sentinel started (pid $SENTINEL_NEW_PID)"
else
  echo "deploy: sentinel stopped by request (stop file present) - not starting it"
fi

cmp -s "$UPGRADE" "$INSTALL_DIR/scripts/upgrade.sh" || fail "the node is installed but the sentinel's upgrade.sh differs from this release"
UPGRADE_HASH="$(sha256sum < "$INSTALL_DIR/scripts/upgrade.sh" 2>/dev/null | awk '{print $1}')"
[ -n "$UPGRADE_HASH" ] || fail "the node is installed but upgrade.sh could not be hashed"


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

# Ship this script beside the binary too. The sentinel's `deploy` verb resolves `scripts/deploy.sh`
# beside the installed binary first - that is where an install keeps the scripts it is allowed to run -
# but `upgrade.sh` ships only itself, so a `request deploy` from an installed node found no deploy.sh
# and failed before it reached the gate, then fell back to the watcher's cwd (a checkout it should not
# need). Installing from the checkout's copy here is the only chance to close that: a deploy has to
# leave the next one able to run with no human at a shell.
# The self-ship that used to live here moved above the sentinel proof: a deploy that cannot prove its
# watcher still has to install the script that reads the line. See the block before that proof.

# ...and the helper that answers "where does this machine's node live", beside the copy of this script that
# will run the next deploy. Without it the installed copy would fall back to the old expression and lose
# exactly the check this rule added - the same way `request deploy` found no deploy.sh at all until that one
# was shipped.
LIB_SRC="$WA_LIB"
[ -f "$LIB_SRC" ] || LIB_SRC="$ROOT/scripts/lib/service-target.sh"
if [ -f "$LIB_SRC" ]; then
  ship_file "$LIB_SRC" "$INSTALL_DIR/scripts/lib/service-target.sh" "scripts/lib/service-target.sh beside deploy.sh"
fi
# deploy.sh and upgrade.sh source it: an installed copy run by the sentinel needs it beside them.
ship_file "$ROOT/scripts/lib/turn-guard.sh" "$INSTALL_DIR/scripts/lib/turn-guard.sh" "scripts/lib/turn-guard.sh beside deploy.sh"
# ...and the build's progress file and requirement check, which it sources too (29/10).
ship_file "$ROOT/scripts/lib/build-status.sh" "$INSTALL_DIR/scripts/lib/build-status.sh" "scripts/lib/build-status.sh beside deploy.sh"
ship_file "$ROOT/scripts/lib/deploy-lock.sh" "$INSTALL_DIR/scripts/lib/deploy-lock.sh" "scripts/lib/deploy-lock.sh beside deploy.sh (the build lock a dead holder cannot block)"
ship_file "$ROOT/scripts/lib/deploy-signal.sh" "$INSTALL_DIR/scripts/lib/deploy-signal.sh" "scripts/lib/deploy-signal.sh beside deploy.sh (the deploy-pending signal)"
ship_file "$ROOT/scripts/lib/build-requirements.sh" "$INSTALL_DIR/scripts/lib/build-requirements.sh" "scripts/lib/build-requirements.sh beside deploy.sh"

ship_file "$ROOT/scripts/lib/deploy-components.sh" "$INSTALL_DIR/scripts/lib/deploy-components.sh" "scripts/lib/deploy-components.sh beside deploy.sh"
# ...and the node-binary resolver, for the same reason the component lib is shipped: `request deploy` runs the
# INSTALLED copy of this script, and a copy with no resolver beside it does not refuse - it notes "no
# node-binaries helper" and builds the tree, which is the one thing a node without a toolchain (openclaw, 2
# cores, no disk for ~600 crates) cannot do. Measured 06/11: the prebuilt path was reached only from the tree.
ship_file "$ROOT/scripts/lib/node-binaries.sh" "$INSTALL_DIR/scripts/lib/node-binaries.sh" "scripts/lib/node-binaries.sh beside deploy.sh"
# ...and the rule that retires a script this release no longer ships: it runs at the end of THIS deploy, from
# the copy beside deploy.sh, so an installed `request deploy` prunes exactly as the checkout deploy does.
ship_file "$ROOT/scripts/lib/retire-unshipped.sh" "$INSTALL_DIR/scripts/lib/retire-unshipped.sh" "scripts/lib/retire-unshipped.sh beside deploy.sh"
# The disk-reclaim job's own files. The job is installed below, and a run step is only useful if the install
# has the pass AND the floor it is compared with: measured 2026-11-11, the install held a `reclaim-disk.sh`
# from an older era and no `reclaim-disk.mjs` at all, so enabling the job would have run a script that could
# not start - a job that is on and never works, which reads exactly like a disk with nothing to report.
ship_file "$ROOT/scripts/reclaim-disk.sh" "$INSTALL_DIR/scripts/reclaim-disk.sh" "disk-reclaim job entry point"
ship_file "$ROOT/scripts/reclaim-disk.mjs" "$INSTALL_DIR/scripts/reclaim-disk.mjs" "the disk reclaim report pass"
ship_file "$ROOT/scripts/check-disk-floor.sh" "$INSTALL_DIR/scripts/check-disk-floor.sh" "the build floor the reclaim report compares against"
ship_file "$ROOT/scripts/lib/proc-use.mjs" "$INSTALL_DIR/scripts/lib/proc-use.mjs" "the reclaim pass's process evidence"
ship_file "$ROOT/components.lock" "$INSTALL_DIR/components.lock" "components.lock beside deploy.sh (the pins this install verified)"
ship_file "$ROOT/scripts/codemode-build.mjs" "$INSTALL_DIR/scripts/codemode-build.mjs" "offline native shipping build contract"
ship_file "$ROOT/scripts/check-graph-component.lua" "$INSTALL_DIR/scripts/check-graph-component.lua" "the graph component proof the deploy runs"
ship_file "$ROOT/scripts/check-embedded-runtime.lua" "$INSTALL_DIR/scripts/check-embedded-runtime.lua" "embedded source and native asset readiness checker"
ship_file "$ROOT/scripts/verify-install.sh" "$INSTALL_DIR/scripts/verify-install.sh" "installation verifier"
ship_file "$ROOT/scripts/sentinel-install-proof.mjs" "$INSTALL_DIR/scripts/sentinel-install-proof.mjs" "request-bound installation proof"
ship_file "$ROOT/scripts/sentinel-historical-proof.mjs" "$INSTALL_DIR/scripts/sentinel-historical-proof.mjs" "verification-only historical generation proof"
ship_file "$ROOT/scripts/measure-sentinel-io.ps1" "$INSTALL_DIR/scripts/measure-sentinel-io.ps1" "bounded read-only Windows idle measurement"
ship_file "$ROOT/scripts/install-sentinel-service.ps1" "$INSTALL_DIR/scripts/install-sentinel-service.ps1" "explicit external Windows SCM installer"
ship_file "$ROOT/scripts/web-core.mjs" "$INSTALL_DIR/scripts/web-core.mjs" "read-only web adapter core"
ship_file "$ROOT/scripts/web-http-outcomes.mjs" "$INSTALL_DIR/scripts/web-http-outcomes.mjs" "recoverable web HTTP evidence and pending handles"
# The MCP runtime also lives in <data>/scripts, where scripts/install.sh puts it and where a node started
# without its install dir in the environment looks. A deploy that refreshed only the install copy left that
# one stale - mcp-client.mjs without web-core.mjs - and every web_search died at import (28/10).
MCP_RUNTIME="mcp-client.mjs mcp-client-core.mjs mcp-server-core.mjs mcp-session.mjs mcp-web.mjs mcp-mail.mjs web-core.mjs web-http-outcomes.mjs"
MCP_DATA_SCRIPTS="${WASM_AGENT_HOME:-$HOME}/.wasm-agent/scripts"
if [ -d "$MCP_DATA_SCRIPTS" ]; then
  for MCP_FILE in $MCP_RUNTIME; do
    ship_file "$ROOT/scripts/$MCP_FILE" "$MCP_DATA_SCRIPTS/$MCP_FILE" "MCP runtime ($MCP_FILE) in the data directory"
  done
fi

# 6b. After the restart: which *installed* components the node's policy file does not name. The file
# itself was installed before the restart (step 6a), because a policy written after a node started used
# to leave that node on the old policy for its whole life (the 06/11 bug). This listing has to come
# after the restart only because it reads the component directory the upgrade just populated; a
# component it names has its sensitive capabilities (kv.write, net.dial, http.request,
# credentials.read, whatsapp.send, exec.run) refused with `no_policy` until a rule is added.
if [ -f "$WA_POLICY_DEST" ]; then
  UNRULED_COMPONENTS="$(policy_unlisted_components "$WA_POLICY_DEST" "$SENTINEL_CONFIG/components" | tr '\n' ' ')"
  if [ -n "$UNRULED_COMPONENTS" ]; then
    note "installed component(s) with no rule in $WA_POLICY_DEST: $UNRULED_COMPONENTS - their sensitive capabilities (kv.write, net.dial, http.request, credentials.read, whatsapp.send, exec.run) are refused with no_policy; add a rule for each"
  fi
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
  for source in "$ROOT"/scripts/whatsapp-* "$ROOT"/scripts/mcp-*.mjs; do
    [ -f "$source" ] || continue
    cp -f "$source" "$INSTALL_DIR/scripts/" || fail "node installed, but could not ship $(basename "$source")"
    PIPELINE=$((PIPELINE + 1))
  done
  # ...and the modules those scripts import, *derived from the imports* rather than listed by hand.
  #
  # The glob above ships `scripts/whatsapp-*` and nothing else, and that is how the install came to hold a
  # reader whose own import was absent: `5cc38d1` moved the WebSocket runtime into
  # `scripts/lib/websocket-runtime.mjs`, the install got the new reader (`whatsapp-read.mjs`, deleted 10/11
  # with the Node bridge) and no `lib/`, and every
  # delivery then failed at step 2 - the transcribe step, which runs the same reader - with
  # `{"step":"read","error":"process_output_unreadable: ... ERR_MODULE_NOT_FOUND"}`, one per 30 s tick,
  # while the deploy reported success. A pipeline that cannot start is not a deployed pipeline, and a
  # hand-written list would have been wrong in exactly the same way one commit later. So the list is the
  # imports.
  MODULES=""
  for source in "$ROOT"/scripts/whatsapp-* "$ROOT"/scripts/mcp-*.mjs; do
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
  # A file this tree no longer ships must not stay in the install. The proof below reads the *install*, so a
  # script deleted from the tree kept its import and failed every later deploy with "imports ..., which this
  # deploy did not install": the Node bridge went on 10/11, `whatsapp-reply.mjs` stayed in the install from an
  # older deploy importing the `whatsapp-mcp-client.mjs` that went with it, and the deploy that installed an
  # unrelated fix recorded `ok=false` (2026-11-11). Only the two globs this block ships are pruned, and a file
  # is removed only when the tree does not have it, so nothing this deploy means to install can be deleted.
  # ...and the same rule for EVERY shipped family, not only the two globs above: a `scripts/lib/*` import, a
  # wave script, a subagent-return script or a job definition whose tree file is gone is exactly as stale as
  # `whatsapp-reply.mjs` was. Moved to <install>/scripts/.retired/<utc>/, never deleted, so the old bytes stay
  # recoverable (scripts/lib/retire-unshipped.sh owns the list and the proof).
  if command -v retire_unshipped >/dev/null 2>&1; then
    retire_unshipped "$INSTALL_DIR" "$ROOT" || fail "could not retire the shipped scripts this tree no longer has"
  else
    note "no scripts/lib/retire-unshipped.sh beside this deploy: a script main deleted can survive in $INSTALL_DIR/scripts"
  fi
  # And prove the install is import-closed, so a script that cannot load is a refused deploy instead of a
  # silent run of failing deliveries: every relative import of a shipped script must resolve inside
  # <install>/scripts, next to the script that names it.
  for source in "$INSTALL_DIR"/scripts/whatsapp-* "$INSTALL_DIR"/scripts/mcp-*.mjs; do
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
  for source in "$ROOT"/scripts/subagent-return-* "$ROOT"/scripts/sentinel-return-* "$ROOT"/scripts/on-stale.sh "$ROOT"/scripts/deploy-shipped.json; do
    [ -f "$source" ] || continue
    cp -f "$source" "$INSTALL_DIR/scripts/" \
      || fail "node installed, but could not ship $(basename "$source")"
    PIPELINE=$((PIPELINE + 1))
  done
  for source in "$ROOT"/jobs/whatsapp-*.json "$ROOT"/jobs/on-subagent-return.json "$ROOT"/jobs/subagent-return-observe.json "$ROOT"/jobs/on-sentinel-return.json "$ROOT"/jobs/sentinel-return-observe.json "$ROOT"/jobs/on-stale.json "$ROOT"/jobs/disk-reclaim.json; do
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
# An old scripts/install.ps1 seeded <config>/AGENTS.md with the repo's own file, which the node now
# reads as the user's global instructions. Retire an unedited seed (moved, never deleted; an edited one
# is kept with a warning). Advisory: it never fails a deploy that already installed.
if [ -f "$ROOT/scripts/lib/seeded-agents-md.sh" ]; then
  . "$ROOT/scripts/lib/seeded-agents-md.sh"
  retire_seeded_agents_md "$SENTINEL_CONFIG" "$ROOT/scripts/lib/seeded-agents-md.sha256" || true
fi
write_result true "installed $COMMIT; watcher ${SENTINEL_NEW_PID:-${SENTINEL_WATCH_PID:-none}}"
wa_phase ""
wa_status installed done "" "$(( $(wa_status_now 2>/dev/null || date +%s) - ${WA_STATUS_STARTED:-0} ))s"
VERDICT="[deploy result] ok commit=$COMMIT node_sha=$HASH sentinel_sha=$SENTINEL_HASH watcher=${SENTINEL_WATCH_PID:-none}->${SENTINEL_NEW_PID:-none}. Evidence: $INSTALL_DIR/deploy-result.json and installed.txt; run scripts/verify-install.sh for the checks."

# The result is written; the notice is not sent from here. `write_result` above is the durable verdict - it
# names the request id it was run for - and the sentinel that spawned this script settles the session's report
# from it (`deploy_outcome`: the wait on this process, this file, or its watchdog). The wake used to be queued
# here, after the swap, and that is the defect the watchdog exists for: this process is the one the swap
# stops, the restart signals and the sentinel replacement outlives, so a report written only by its last lines
# is a report that arrives only when nothing went wrong. Nothing to do here now, and no WARNING that implies
# the session was told.
echo "deploy: result recorded (request ${REQUEST_ID:-hand-run}); the sentinel reports it to ${SESSION:-nobody}"
echo "$VERDICT"
