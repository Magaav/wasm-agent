#!/usr/bin/env bash
# ONE answer to "run git without the session's redirect" (ARCHITECTURE.md law 17; factory-is-small-and-tested, 27/11).
#
# WHAT HAPPENED: `scripts/test-peer-update-installs.sh` and `factory/test-daily-line.sh` each wrote a scratch repository
# with `git init` and `git config user.name row`, and a suite started from a git hook - which exports GIT_DIR,
# GIT_INDEX_FILE and GIT_WORK_TREE to every child - sent those writes into the SHARED repository instead of their own
# scratch directory. The same incident, one layer down, as 24/11's session commits landing in another worktree
# (`scripts/test-git-env-isolation.sh`).
#
# Two functions, and nothing else in the tree may spell this list again:
#   wa_git_isolate  - drop git's redirect from THIS shell (use it at the top of a row that runs bare `git ...`);
#   wa_git          - run one command with the redirect dropped, whatever the calling shell carries.
#
# The guard is `scripts/test-rows-clear-git-env.mjs`: a row under scripts/ or factory/ that writes repository state
# must source this file (or clear the names itself, with a reason) or it fails by name.

wa_git_isolate() {
  unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
}

# wa_git [--git-dir <dir>] [--work-tree <dir>] <git args...>
#
# A row that INTENDS a fixture repository must say so through these two forms rather than by exporting GIT_DIR: this helper
# clears the environment's redirect on purpose (a git hook hands one to every child), so an exported GIT_DIR would be undone
# here - and a row that then wrote into the caller's repository instead of its fixture is the defect this file exists to
# prevent. --git-dir/--work-tree are passed to git after the clear, so the intent survives it.
wa_git() {
  wa_git_isolate
  local -a intent=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --git-dir)    intent+=("--git-dir=$2"); shift 2 ;;
      --work-tree)  intent+=("--work-tree=$2"); shift 2 ;;
      *) break ;;
    esac
  done
  command git "${intent[@]}" "$@"
}
