#!/usr/bin/env bash
# GIT ENVIRONMENT ISOLATION (G blocker, 24/11): a session's commit lands in ITS OWN worktree.
#
# WHAT HAPPENED: 11:49:31Z, a commit by the deploy-hold worker (783ae80c) landed in another live session's
# worktree (~/Work/missions/whatsapp-read-is-consistent/wt), taking its staged components.lock and moving
# its HEAD - from a command that said `cd <its own wt> && git add -A lua scripts && git commit -F m.txt`.
# An explicit `cd` beats any working directory, so only git's own environment can do it.
#
# THE MECHANISM (file:line): rust/wa-operation/src/process.rs:76 is the one place every tool child is
# spawned, and it removed the names in rust/wa-operation/src/lib.rs:36 - none of git's. A node that carries
# a GIT_* (git exports GIT_DIR and GIT_INDEX_FILE to every hook it runs) therefore handed one repository's
# identity to every session it served, in every worktree at once.
#
# THIS ROW starts TWO REAL NODES, each with its own home and database, from a parent that carries those
# three names - the hook's own shape - and has each of them commit 50 times into its own worktree of ONE
# shared repository AT THE SAME MOMENT, then checks from git itself that neither commit, neither HEAD and
# neither staged file moved between them.
#   red before: one session's commits land in the other's worktree (that is the incident)
#   green after: every commit is in its own worktree, and a staged file stays staged
# Hermetic: its own scratch HOME, databases and repository; no rendezvous, no provider, no port, nothing
# on the live node.
set -u
BIN="${1:-${WA_BIN:-rust/target/release/wa}}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
S="$(mktemp -d "${TMPDIR:-/tmp}/wa-git-env-XXXXXX")"
trap 'rm -rf "$S"' EXIT
S="$(cd "$S" && pwd -P)"
checks=0
ok() { checks=$((checks + 1)); }
no() { echo "git env isolation: $*" >&2; exit 1; }
# Every git command this ROW runs has no inherited redirect of its own (the redirect belongs to the two
# nodes it starts, below) - and the wrapper's own reads must never be the thing that is redirected.
gitq() { env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE git "$@"; }

[ -x "$BIN" ] || no "no binary at $BIN"
gitq init -q --initial-branch=main "$S/repo/main" || no "could not create the scratch repository"
gitq -C "$S/repo/main" -c user.name=fixture -c user.email=fixture@invalid commit -q --allow-empty -m base \
  || no "could not make the base commit"
for name in s1 s2; do
  gitq -C "$S/repo/main" worktree add -q -b "$name" "$S/repo/$name" >/dev/null 2>&1 \
    || no "could not create worktree $name"
done
S1="$S/repo/s1"
S2="$S/repo/s2"
# Each session's HOME is its own, and its commits are authored by the fixture identity in that home: the
# child inherits HOME (it must - it is the session's), so this is how the row fixes the author without
# passing -c user.name on any command line.
for pair in a b; do
  mkdir -p "$S/home-$pair"
  printf '[user]\n\tname = fixture %s\n\temail = fixture-%s@invalid\n[commit]\n\tgpgsign = false\n' \
    "$pair" "$pair" > "$S/home-$pair/.gitconfig"
done
# THE SHAPE A GIT HOOK LEAVES: ONE repository's git dir, index and worktree, exported to every child.
# Both nodes inherit the same three values, and that is the incident: the parent's git context pointed at
# one worktree, and the other session's command committed there whatever its own `cd` said.
HOOK_GIT_DIR="$(gitq -C "$S1" rev-parse --absolute-git-dir)" || no "could not read the first worktree's git dir"
BASE="$(gitq -C "$S1" rev-parse HEAD)" || no "could not read the base commit"

session() { # label, own worktree, the other worktree, its home
  env -u WASM_AGENT_VAULT_URL -u WASM_AGENT_OPENCODE_GO_VAULT_URL \
      HOME="$4" WASM_AGENT_HOME="$4" WASM_AGENT_LUA_ROOT="$ROOT" \
      WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0 \
      GIT_DIR="$HOOK_GIT_DIR" GIT_INDEX_FILE="$HOOK_GIT_DIR/index" GIT_WORK_TREE="$S1" \
      GIT_TERMINAL_PROMPT=0 \
      WA_SCRIPT="$ROOT/scripts/test-git-env-isolation.lua" \
      WA_TEST_GIT_WT="$2" WA_TEST_GIT_OTHER_WT="$3" WA_TEST_GIT_LABEL="$1" WA_TEST_GIT_SCRATCH="$S" \
      "$BIN" --db "$S/$1.db"
}

session a "$S1" "$S2" "$S/home-a" >"$S/a.log" 2>&1 &
pida=$!
session b "$S2" "$S1" "$S/home-b" >"$S/b.log" 2>&1 &
pidb=$!
wait "$pida"; ca=$?
wait "$pidb"; cb=$?
# BOTH sessions' verdicts are printed when either one failed: on a node that hands a redirect down, the
# session that OWNS the worktree is the victim and the other is the one whose commits went astray, and a
# report of one line would name only half of what happened.
bad=0
[ "$ca" = 0 ] || bad=1
grep -q 'git env isolation ok' "$S/a.log" || bad=1
[ "$cb" = 0 ] || bad=1
grep -q 'git env isolation ok' "$S/b.log" || bad=1
if [ "$bad" != 0 ]; then
  echo "git env isolation: session a (exit $ca): $(tail -2 "$S/a.log" | tr '\n' ' ')" >&2
  echo "git env isolation: session b (exit $cb): $(tail -2 "$S/b.log" | tr '\n' ' ')" >&2
  exit 1
fi
ok; ok

# ---- and now from git itself, not from the sessions' own bookkeeping ------------------------
subjects_a="$(gitq -C "$S1" log --format=%s)"
subjects_b="$(gitq -C "$S2" log --format=%s)"
for subject in $subjects_a; do
  case "$subject" in
    base|a-[0-9]*) ok ;;
    *) no "worktree s1 carries a commit that is not session a's: $subject" ;;
  esac
done
for subject in $subjects_b; do
  case "$subject" in
    base|b-[0-9]*|b-final) ok ;;
    *) no "worktree s2 carries a commit that is not session b's: $subject" ;;
  esac
done
count_a="$(printf '%s\n' "$subjects_a" | grep -c '^a-[0-9]')"
count_b="$(printf '%s\n' "$subjects_b" | grep -c '^b-[0-9]')"
[ "$count_a" = 50 ] || no "session a has $count_a of its 50 commits in its own worktree"
[ "$count_b" = 50 ] || no "session b has $count_b of its 50 commits in its own worktree"
ok; ok
[ "$(gitq -C "$S2" rev-parse HEAD)" != "$BASE" ] || no "worktree s2 never moved: session b's commits went somewhere else"
ok
staged="$(gitq -C "$S1" diff --cached --name-only)"
[ "$staged" = "a-staged-only.txt" ] || no "session a's staged file is not still staged in its own worktree: '$staged'"
ok
if gitq -C "$S2" log --format= --name-only | grep -qx 'a-staged-only.txt'; then
  no "session b's commit swallowed session a's staged file"
fi
ok
echo "git env isolation ok ($checks checks, two sessions, 50 commits each, one repository)"
