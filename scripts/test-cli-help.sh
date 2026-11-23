#!/usr/bin/env bash
# `wa <verb> --help` IS A QUESTION, AND A QUESTION RUNS NOTHING.
#
# WHY THIS ROW EXISTS (Fable, 23/11). MEASURED 09:30Z, and again by this mission in a scratch home on this machine:
# `wa update --help` RAN A LOCAL UPDATE. It answered with the update's own report - "no sentinel watcher
# ownership was verified, so nothing can safely accept this deploy: the request was not queued" - and exit 1. It
# did not install anything only because the runtime check refused first on that machine. The same shape held for
# every other acting verb: the flag travelled into the verb as an argument and the verb acted. The caller who most
# needs to ask "what does this do" before acting is the one who could least safely ask.
#
# WHAT IT CHECKS, for every verb lua/core/cli_help.lua declares (read from the tree, so a verb added there is a
# verb this row drives):
#   * `wa <verb> --help` exits 0, answers with a `usage: wa <verb>` line, and prints NOTHING ELSE - an acting
#     verb that ran would put its own report on stdout, and that is the failure this row is for;
#   * `-h` is the same question (driven for update, the measured case);
#   * the answer is the text this tree declares (scripts/lib/cli-help-verbs.lua prints it), byte for byte;
#   * the verbs whose acting form reaches the FLEET (bind, network, fleet, promote, demote, revoke, accept,
#     unbind) are NOT driven here - on a tree without the guard the discrimination check would make them ask a
#     live rendezvous (factory rule 13) - and the module check proves the guard answers for them instead;
#   * `wa update <node> --help` keeps remote_update.lua's detailed help: the guard must not swallow the words a
#     better help already had.
#
# Hermetic: its own HOME and database, no rendezvous, no network, no vault. It refuses to run on the operator's
# home. A Linux or Windows host alike - it only runs the binary.
#
#   bash scripts/test-cli-help.sh        (prints "cli-help ok (<n> checks)")
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
# NOT under $TMPDIR: a node sets TMPDIR inside its own store (<home>/.wasm-agent/tmp), and a scratch HOME there
# is inside the operator's store - which scripts/lib/scratch-home.lua refuses, correctly. /tmp is outside every home.
T=$(mktemp -d /tmp/wa-cli-help.XXXXXX) || { printf 'FAIL tmpdir_unavailable\n' >&2; exit 1; }
trap 'rm -rf "$T"' EXIT
original_home="${WA_HOME_BEFORE_OVERRIDE:-${HOME:-}}"
unset WASM_AGENT_HOME
export HOME="$T/home"
mkdir -p "$HOME"
if [ -n "$original_home" ] && [ "$(cd "$HOME" && pwd -P)" = "$(cd "$original_home" 2>/dev/null && pwd -P)" ]; then
  printf 'REFUSED scratch_home_is_real: refusing to run in %s\n' "$HOME" >&2; exit 2
fi
export WASM_AGENT_HOME="$HOME" WA_HOME_BEFORE_OVERRIDE="$original_home"
export WASM_AGENT_DB="$T/memory.db" XDG_CACHE_HOME="$T/cache"
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
# No rendezvous, no relay, nothing managed: this row must never ask a live fleet anything (rule 13).
export WASM_AGENT_RENDEZVOUS= WASM_AGENT_RELAY= WASM_AGENT_MANAGED=0
export WASM_AGENT_LUA_ROOT="$ROOT"
BIN="${WA_BIN:-$ROOT/rust/target/release/wa}"
[ -x "$BIN" ] || BIN="$BIN.exe"
[ -x "$BIN" ] || { printf 'no wa binary at %s (build it first, or set WA_BIN)\n' "$BIN" >&2; exit 2; }

pass=0; failed=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { failed=$((failed+1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | tail -6 | sed 's/^/     /'; }

# THE LIST comes from the tree, in the same run: the verbs, and the lines that answer for each of them.
verdict=$(WA_SCRIPT="$ROOT/scripts/lib/cli-help-verbs.lua" "$BIN" --db "$T/verbs.db" 2>&1)
lister_ok=1
case "$verdict" in *"cli-help-verbs ok ("*) lister_ok=0 ;; esac
verbs=$(printf '%s\n' "$verdict" | sed -n 's/^### verb //p')
if [ -z "$verbs" ]; then
  # A tree without the module (this row on the base it must fail on) still drives the measured case below.
  verbs="update land release clean session steer mission backup restore setup init remember forget services eval whatsapp approve call"
fi
text_of() { printf '%s\n' "$verdict" | awk -v v="$1" '$0 == "### verb " v { f = 1; next } f && $0 == "### end" { exit } f'; }
# A verb whose own layer already answers --help (the binary's release CLI) is held to the SHAPE, not to this
# tree's text: its words are older than this guard and it runs nothing either (the exit/usage checks prove it).
delegated=$(printf '%s\n' "$verdict" | sed -n 's/^### delegate //p')

# THE MEASURED DEFECT FIRST, so a red run names it and not a missing fixture file.
out=$("$BIN" update --help 2>&1); rc=$?
if [ "$rc" = 0 ] && [ "${out%%\n*}" = "${out%%\n*}" ] && printf '%s\n' "$out" | head -1 | grep -q '^usage: wa update'; then
  ok 'wa update --help answers with its usage'
else
  bad 'wa update --help runs nothing (measured 23/11: it ran a local update)' "$out"
fi
out=$("$BIN" update -h 2>&1); rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$out" | head -1 | grep -q '^usage: wa update' \
  && ok 'wa update -h is the same question' || bad 'wa update -h prints usage and exits 0' "$out"

fleet=" bind unbind accept promote demote revoke network fleet "
driven=0; skipped=""
for verb in $verbs; do
  case "$fleet" in
    *" $verb "*)
      skipped="$skipped $verb"
      continue ;;
  esac
  driven=$((driven+1))
  out=$("$BIN" "$verb" --help 2>&1); rc=$?
  first=$(printf '%s\n' "$out" | head -1)
  extra=$(printf '%s\n' "$out" | grep -vE '^usage: wa |^  ' || true)
  if [ "$rc" != 0 ]; then
    bad "wa $verb --help exits 0 (it answered exit $rc)" "$out"; continue
  fi
  case "$first" in
    "usage: wa $verb"*) ok "wa $verb --help answers with its usage" ;;
    *) bad "wa $verb --help answers with a usage line, not with a report" "$out"; continue ;;
  esac
  if [ -n "$extra" ]; then bad "wa $verb --help runs nothing (other output)" "$extra"; continue; fi
  expected=$(text_of "$verb")
  case " $(printf '%s' "$delegated" | tr '\n' ' ') " in *" $verb "*) expected="" ;; esac
  if [ "$lister_ok" = 0 ] && [ -n "$expected" ]; then
    if [ "$out" = "$expected" ]; then ok "wa $verb --help is the text this tree declares"
    else bad "wa $verb --help is the text this tree declares" "$(diff <(printf '%s\n' "$expected") <(printf '%s\n' "$out") | head -8)"; fi
  fi
done
ok "the row drove $driven acting verbs" && [ -n "$skipped" ] \
  && printf '     not driven (their acting form reaches a fleet; the module check covers them):%s\n' "$skipped"

# THE DETAILED HELP THAT ALREADY EXISTED IS NOT SWALLOWED: \`wa update <node> --help\` is remote_update.lua's.
out=$("$BIN" update some-node --help 2>&1); rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$out" | grep -q -- '--rollback' && printf '%s\n' "$out" | grep -q -- '--pin' \
  && ok 'wa update <node> --help keeps the detailed help the verb already had' || bad 'wa update <node> --help keeps its own words' "$out"

# \`wa --help\` and \`wa -h\` are the shortest form of the same question as \`wa help\`.
helped=$("$BIN" help 2>&1 | head -1)
for flag in --help -h; do
  out=$("$BIN" "$flag" 2>&1); rc=$?
  [ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | head -1)" = "$helped" ] \
    && ok "wa $flag is wa help" || bad "wa $flag is wa help" "$out"
done

if [ "$lister_ok" = 0 ]; then ok "$(printf '%s\n' "$verdict" | tail -1)"
else bad 'the acting-verb list of lua/core/cli_help.lua is readable and its own checks pass' "$verdict"; fi

if [ "$failed" = 0 ]; then printf '\ncli-help ok (%d checks)\n' "$pass"; exit 0; fi
printf '\ncli-help: %d passed, %d FAILED\n' "$pass" "$failed" >&2
exit 1
