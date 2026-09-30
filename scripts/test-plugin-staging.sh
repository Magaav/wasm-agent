#!/usr/bin/env bash
# The plugin staging function, tested against the event it was written for.
#
# The gate builds its WASM modules into a directory under the shared temp root and reads them from
# there ~1300 lines later. Measured on candidate tree 55e04252: that directory was gone by the time
# the first module was copied into it, and the gate died after 763 s on
# `cp: cannot create regular file '/tmp/tmp.PZulxpI9l4/echo.wasm': No such file or directory`, with
# no verdict line - a red gate that said nothing about the tree under test.
#
# The function under test is read out of scripts/test.sh, the way test-deploy-ship.sh reads the real
# block out of deploy.sh, so this cannot pass while the real code is wrong. Both halves are asserted:
# the module still arrives after its directory was removed, and a staging that cannot create the
# directory still fails - the copy is the assertion, and re-creating the directory must not turn a
# gate that cannot write a module into a gate that passes.
set -euo pipefail
cd "$(dirname "$0")/.."

stage_fn="$(sed -n '/^stage_plugin() {/,/^}/p' scripts/test.sh)"
if [ -z "$stage_fn" ]; then
  echo "FAIL: scripts/test.sh has no stage_plugin() to test" >&2
  exit 1
fi

checks=0
ok() { checks=$((checks + 1)); }
fail() { echo "FAIL: $1" >&2; exit 1; }

PLUGINS=""
work="$(mktemp -d)"
cleanup() { rm -rf "$work" 2>/dev/null || true; [ -z "$PLUGINS" ] || rm -rf "$PLUGINS" 2>/dev/null || true; }
trap cleanup EXIT

module="$work/echo.wasm"
printf 'a real module would be here\n' > "$module"

# 1. The event, reproduced with no function involved: a copy into a directory that is gone fails
# with the exact message the gate reported. Without this the fixture would be convenient, not real.
gone="$(mktemp -d)"
rm -rf "$gone"
if cp "$module" "$gone/echo.wasm" 2>"$work/plain-copy.err"; then
  fail "a copy into a removed directory must fail; the fixture does not reproduce the gate's event"
fi
grep -q 'No such file or directory' "$work/plain-copy.err" || fail "the reproduced error is not the reported one: $(cat "$work/plain-copy.err")"
ok

# 2. The real function, against the same event: the directory is removed before staging, so it has to
# be re-created where it is used, and the module must arrive whole.
PLUGINS="$(mktemp -d)"
rm -rf "$PLUGINS"
eval "$stage_fn"
stage_plugin "$module" echo 2>"$work/stage.err" || fail "staging failed after its directory was removed: $(cat "$work/stage.err")"
[ -d "$PLUGINS" ] || fail "the staging directory was not re-created"
[ -f "$PLUGINS/echo.wasm" ] || fail "the module did not arrive in the re-created directory"
cmp -s "$module" "$PLUGINS/echo.wasm" || fail "the staged module differs from the built one"
ok

# 3. A staging that had to re-create the directory says so: an unattributed red gate is the failure
# this file exists for, so the run names the event instead of leaving it to be inferred.
grep -q 'was missing' "$work/stage.err" || fail "a re-created directory was not reported: $(cat "$work/stage.err")"
ok

# 4. The assertion is not weakened. A directory that cannot be created must still fail the stage,
# rather than report a module it did not write.
: > "$work/blocked"
PLUGINS="$work/blocked/stage"
if ( eval "$stage_fn"; stage_plugin "$module" echo ) >/dev/null 2>&1; then
  fail "a staging that cannot create its directory must fail"
fi
ok

# 5. Staging into a directory that is there is unchanged: no note, module staged.
PLUGINS="$(mktemp -d)"
stage_plugin "$module" whatsapp-transcript 2>"$work/quiet.err" || fail "staging into an existing directory failed"
[ -f "$PLUGINS/whatsapp-transcript.wasm" ] || fail "the module was not staged into an existing directory"
[ ! -s "$work/quiet.err" ] || fail "an intact staging directory was reported as missing: $(cat "$work/quiet.err")"
ok

echo "plugin staging ok ($checks checks; a removed staging directory, a blocked one, an intact one)"
