#!/usr/bin/env bash
# A READER THAT WALKED AWAY IS NOT A CRASH (Fable, 25/11).
#
# MEASURED on this node with the base binary:
#
#   wa --version   2>err | (exec 0<&-; read)   ->  'thread 'main' panicked at library/std/src/io/stdio.rs:...:
#                                                 failed printing to stdout: Broken pipe (os error 32)'
#   wa --build-info …                          ->  the same
#   wa features | head -1                       ->  the same, which is the brief's `wa call <node> ... | head`
#
# Every one of those exits 101 and prints a panic two lines long, so an ordinary pipeline reads to a person as a
# crash of the tool. The fix is one panic hook in the binary (rust/wa-host/src/main.rs,
# `quiet_when_the_reader_leaves`): a print-macro panic whose payload says stdout + EPIPE exits 141 - 128 + SIGPIPE,
# the shell's own convention - with NOTHING on stderr, and every other panic keeps its handler and its message.
#
# What this row holds, on the real binary and a scratch home of its own:
#   1. a reader that closes before the first write: each Rust-printing subcommand exits 141 and says nothing;
#   2. `wa features | head -1` - the brief's shape - prints its first line and leaves no panic text behind;
#   3. the CONTROL: a reader that stays gets the whole output and a clean 0, so "quiet" is not "prints nothing";
#   4. a subcommand that prints from the Lua surface (`wa help`) is checked too: it never panicked, and this row
#      says so rather than assuming it (it is the case the hook must NOT have been needed for).
#
#   bash scripts/test-broken-pipe.sh            (WA_BIN names the binary under test; else `wa` on PATH)
#
# Scratch only: its own HOME with scripts/lib/scratch-home.sh's guard, and no node, no database and no network are
# needed by any command it runs.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd)"
. "$ROOT/scripts/lib/scratch-home.sh"
if [ -n "${WA_ROW_SCRATCH_ROOT:-}" ]; then W="$WA_ROW_SCRATCH_ROOT/row-broken-pipe"; else W="$(TMPDIR=/tmp mktemp -d /tmp/wa-broken-pipe.XXXXXX)"; fi
mkdir -p "$W/home" || exit 1
wa_scratch_home_guard "$W/home" || { echo 'broken-pipe REFUSED: the scratch home is the operator node home' >&2; exit 2; }
export HOME="$W/home" WASM_AGENT_HOME="$W/home"

WA="${WA_BIN:-}"
if [ -z "$WA" ]; then WA="$(command -v wa 2>/dev/null || true)"; fi
if [ -z "$WA" ] || [ ! -x "$WA" ]; then
  echo 'SKIP broken-pipe: no wa binary (set WA_BIN, or put wa on PATH)'
  exit 3
fi

trap 'rm -rf "$W"' EXIT

checks=0
ok() { checks=$((checks + 1)); }
fail() { echo "broken-pipe FAILED: $*" >&2; exit 1; }

# A READER THAT IS ALREADY GONE when the writer starts: the read end is closed before the first write, so the first
# print gets EPIPE and nothing else can mask it. (A reader that stays, or a slow one, is the race this avoids.)
closed_reader() { ( exec 0<&-) ; }

# 1. EVERY RUST-PRINTING SUBCOMMAND: quiet 141, nothing on stderr.
gone() { # <args...>
  local err="$W/err.$checks" rc
  "$WA" "$@" 2>"$err" | closed_reader
  rc=${PIPESTATUS[0]}
  [ "$rc" = 141 ] || fail "wa $* with a closed reader must exit 141 (128 + SIGPIPE), got $rc; stderr: $(head -2 "$err" | tr '\n' ' ')"
  if grep -qiE 'panicked|Broken pipe|os error 32' "$err"; then
    fail "wa $* still printed the crash: $(head -2 "$err" | tr '\n' ' ')"
  fi
  [ -s "$err" ] && fail "wa $* said something on stderr to a reader that left: $(head -2 "$err" | tr '\n' ' ')"
  ok
}
gone --version
gone --build-info
gone features

# 2. THE BRIEF'S SHAPE: `... | head -1` prints its first line and leaves no panic text behind.
"$WA" features 2>"$W/err.head" | head -1 > "$W/first-line"
[ -s "$W/first-line" ] || fail 'wa features | head -1 printed nothing'
ok
if grep -qiE 'panicked|Broken pipe|os error 32' "$W/err.head"; then
  fail "wa features | head -1 printed the crash: $(head -2 "$W/err.head" | tr '\n' ' ')"
fi
ok

# 3. THE CONTROL: a reader that STAYS changes nothing - the same exit code and the same bytes as the run with no
#    pipe at all, so "quiet" above is about the reader leaving, not about a command that prints nothing. (`wa
#    features`'s own exit code in a scratch home is 3: it reports that no component is installed, which is this home's
#    truth and not this row's subject - hence the comparison rather than a number.)
direct="$("$WA" features 2>/dev/null)"; direct_rc=$?
piped="$("$WA" features 2>/dev/null | cat)"; piped_rc=${PIPESTATUS[0]}
[ "$piped_rc" = "$direct_rc" ] || fail "a reader that stays changed the exit code ($direct_rc unpiped, $piped_rc piped)"
[ "$piped" = "$direct" ] || fail 'a reader that stays got different bytes'
count=$(printf '%s\n' "$piped" | grep -c . || true)
[ "$count" -ge 2 ] || fail "wa features printed $count line(s) to a reader that stays; the control needs a real multi-line output"
ok
version="$("$WA" --version 2>/dev/null)"; version_rc=$?
[ "$version_rc" = 0 ] || fail "wa --version into a reader that stays must exit 0, got $version_rc"
case "$version" in wasm-agent*) ok ;; *) fail "wa --version printed something else: $version" ;; esac

# 4. THE LUA PRINT PATH: `wa help` writes through the interpreter, never panicked, and must stay quiet too.
"$WA" help 2>"$W/err.help" | closed_reader
rc=${PIPESTATUS[0]}
case "$rc" in
  0|141) ok ;;
  *) fail "wa help with a closed reader exited $rc (0 or 141 are quiet); stderr: $(head -2 "$W/err.help" | tr '\n' ' ')" ;;
esac
if grep -qiE 'panicked|Broken pipe|os error 32' "$W/err.help"; then
  fail "wa help printed the crash: $(head -2 "$W/err.help" | tr '\n' ' ')"
fi
ok

echo "broken pipe ok ($checks checks): a reader that leaves is a quiet 141 for every printing subcommand, and a reader that stays still gets the output"
