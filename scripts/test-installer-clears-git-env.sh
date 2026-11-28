#!/usr/bin/env bash
# AN INSTALLER DOES NOT INHERIT A GIT REPOSITORY (installer-refuses-a-target-it-was-not-given, item 7 - 25/11)
#
# A deploy, an upgrade or a bootstrap started from a shell that carries GIT_DIR/GIT_WORK_TREE/GIT_INDEX_FILE - a git hook
# hands those to every child - resolves SOMEBODY ELSE'S repository as its ROOT. The clear must come before the script's
# FIRST git call, which is what this row checks (order, not presence: a clear after the first `git` is decoration).
#
# Two halves:
#   1. STATIC: for each installer, the first `scripts/lib/git-env.sh`/`wa_git_isolate` line comes before the first `git ` call;
#   2. BEHAVIOURAL: with GIT_DIR naming another repository, the helper leaves the caller in ITS OWN tree, while plain git does
#      not - measured, so the static check cannot be satisfied by a comment.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
checks=0; failed=0
ok()  { checks=$((checks+1)); printf '  ok   %s\n' "$*"; }
bad() { checks=$((checks+1)); failed=$((failed+1)); printf '  FAIL %s\n' "$*"; }

INSTALLERS="scripts/deploy.sh scripts/upgrade.sh scripts/linux/bootstrap.sh scripts/termux/bootstrap.sh"
for script in $INSTALLERS; do
  [ -f "$script" ] || { bad "$script is missing"; continue; }
  first_clear=$(awk '/^[[:space:]]*#/ {next} /git-env\.sh|wa_git_isolate/ {print NR; exit}' "$script")
  first_git=$(awk '/^[[:space:]]*#/ {next} /(^|[;&|([[:space:]])git[[:space:]]/ {print NR; exit}' "$script")
  if [ -z "$first_git" ]; then
    ok "$script makes no git call, so nothing can be inherited"
  elif [ -z "$first_clear" ]; then
    bad "$script calls git (line $first_git) without ever clearing GIT_DIR (scripts/lib/git-env.sh)"
  elif [ "$first_clear" -lt "$first_git" ]; then
    ok "$script clears git's redirect (line $first_clear) before its first git call (line $first_git)"
  else
    bad "$script clears git's redirect at line $first_clear, AFTER its first git call at line $first_git - a clear that late is decoration"
  fi
done

# ---- behavioural: the helper is what makes the static check true -----------------------------------------------
OTHER="$(mktemp -d "${TMPDIR:-/tmp}/wa-other-repo.XXXXXX")"
trap 'rm -rf "$OTHER"' EXIT
env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE git init -q "$OTHER/fixture" 2>/dev/null
plain=$(GIT_DIR="$OTHER/fixture/.git" git -C "$ROOT" rev-parse --git-dir 2>/dev/null || true)
case "$plain" in
  ""|.git|"$(cd "$ROOT" && pwd -P)/.git") bad "plain git under GIT_DIR did not follow the inherited repository; the fixture cannot tell the two apart (got '$plain')" ;;
  *) ok "plain git under an inherited GIT_DIR answers with the OTHER repository ('$plain') - the defect this row exists for" ;;
esac
isolated=$(GIT_DIR="$OTHER/fixture/.git" bash -c '. "$1/scripts/lib/git-env.sh"; wa_git_isolate; cd "$1" && git rev-parse --git-dir' _ "$ROOT" 2>/dev/null || true)
# In a WORKTREE `--git-dir` answers the canonical checkout's `.git/worktrees/<name>`, which is this tree's git dir reached
# by indirection - so the assertion is "no longer the inherited repository", not "looks like a path I expected".
case "$isolated" in
  "$OTHER"*) bad "wa_git_isolate still answered the inherited repository ('$isolated')" ;;
  "") bad "wa_git_isolate resolved no repository at all under an inherited GIT_DIR" ;;
  *) ok "after wa_git_isolate the same command no longer answers the inherited repository ('$isolated')" ;;
esac

if [ "$failed" -gt 0 ]; then echo "installer-clears-git-env: FAILED ($checks checks, $failed failed)"; exit 1; fi
echo "installer-clears-git-env ok ($checks checks)"
