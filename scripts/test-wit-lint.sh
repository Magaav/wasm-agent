#!/usr/bin/env bash
# scripts/wit-lint.sh judged by fixtures, because a gate nobody proves is a gate that can quietly
# judge less (the rule scripts/test-component-pins.sh --self-test already keeps here).
#
# The two rules it proves, and the ways they must NOT fire:
#
#   1. a `string` field or parameter that carries JSON is named `*-json` - and a mention of a JSON FILE
#      ("native (hooks.json) or claude (settings.json)") is not a mention of a JSON value, or
#      hooks.wit's `kind: string` would fail on main today;
#   2. a `status`/`poll`/`await-*`/`wait-*` func beside a func handing out an operation id fails unless
#      its doc says "`legacy wrapper over <future-func>`".
#
# And the blind spots each rule documents, from the failing side and the passing side:
#   * a parameter's doc only counts when it speaks about that parameter BY NAME: a function doc
#     describing its RETURN value ("The JSON text of one granted key") must not flag its `key`
#     parameter, while "`config` is the non-secret configuration object (JSON text)" must flag it;
#   * an op-id-returning `submit` beside a `poll` fails, and fails no longer once the poll's doc carries
#     the marker - the same tree, one line of doc, both verdicts. That is the before/after the rules
#     and the baseline exist for, and it is proved here rather than asserted.
#
#   bash scripts/test-wit-lint.sh
#
# Fixtures in a temp tree, no toolchain, no network, no node beyond the one the lint itself uses.
set -uo pipefail
cd "$(dirname "$0")/.."
checks=0; skipped=0
ok() { checks=$((checks + 1)); }
fail() { echo "wit-lint-selftest FAILED: $*" >&2; [ -n "${work:-}" ] && echo "work dir: $work" >&2; exit 1; }
skip() { echo "wit-lint-selftest SKIPPED: $*"; skipped=$((skipped + 1)); }
contains() { case "$1" in *"$2"*) ok ;; *) fail "$3: '$2' not in: $(printf '%s' "$1" | tail -12)" ;; esac; }
absent() { case "$1" in *"$2"*) fail "$3: '$2' should not be there: $(printf '%s' "$1" | tail -12)" ;; *) ok ;; esac; }

if ! command -v node >/dev/null 2>&1; then
  skip "node is not on PATH, and scripts/wit-lint.sh is one node run"
  echo "wit-lint-selftest: $checks checks, $skipped skipped"; exit 0
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/wa-wit-lint-XXXXXX")
trap 'rm -rf "$work"' EXIT
lint() { # <dir> [baseline]
  if [ -n "${2:-}" ]; then WIT_LINT_DIR="$1" WIT_LINT_BASELINE="$2" bash scripts/wit-lint.sh 2>&1
  else WIT_LINT_DIR="$1" WIT_LINT_BASELINE="$1/no-baseline.txt" bash scripts/wit-lint.sh 2>&1; fi
}

# ---- the clean seam -----------------------------------------------------------------------------
mkdir -p "$work/clean"
cat > "$work/clean/clean.wit" <<'WIT'
package wa:fixture@0.1.0;

interface tools {
    record call {
        /// The user's own arguments, as JSON.
        args-json: string,
        /// native (hooks.json) or claude (settings.json): a FILE name, never a value.
        kind: string,
    }

    /// The placement this seam hands out; the answer arrives through a future in the real seam.
    type op-id = string;

    /// Start placing one job.
    submit: func(kind: string) -> result<op-id, error>;

    /// The placement's state, for the component that still calls it.
    /// legacy wrapper over submit
    poll: func(id: op-id) -> result<string, error>;

    /// The JSON text of one granted key (a string value unquoted), or none: this describes the
    /// RETURN value, so it must not flag the key parameter below.
    get: func(key: string) -> result<option<string>, error>;
}
WIT
out=$(lint "$work/clean"); rc=$?
[ "$rc" = 0 ] && ok || fail "the clean seam must pass, exit $rc: $out"
contains "$out" "wit-lint ok" "a passing seam says so"
contains "$out" "1 named *-json" "args-json is counted as named"
absent "$out" "FAIL" "a clean seam reports no failure line"

# ---- the same seam with three holes -------------------------------------------------------------
mkdir -p "$work/dirty"
cat > "$work/dirty/dirty.wit" <<'WIT'
package wa:fixture@0.1.0;

interface tools {
    record call {
        /// The user's own arguments, as JSON.
        args: string,
        kind: string,
    }

    type op-id = string;

    submit: func(kind: string) -> result<op-id, error>;

    status: func(id: op-id) -> result<string, error>;

    /// The JSON text of one granted key (a string value unquoted), or none: this describes the
    /// RETURN value, so it must not flag the key parameter below.
    get: func(key: string) -> result<option<string>, error>;

    /// config is the non-secret configuration object (JSON text) from the registry definition.
    run: func(config: string) -> result<_, string>;
}
WIT
out=$(lint "$work/dirty"); rc=$?
[ "$rc" = 1 ] && ok || fail "the dirty seam must fail, exit $rc: $out"
contains "$out" "args: string" "rule 1 names the field whose doc says JSON"
contains "$out" "config: string" "rule 1 names the parameter its function doc describes"
contains "$out" "status" "rule 2 names the polling func"
contains "$out" "3 new violation(s)" "all three holes are counted"
contains "$out" "beside" "rule 2 says what it sits beside"
contains "$out" "3 new violation(s)" "the three holes, and exactly three: kind: string (its doc names only FILES) and key: string (its doc describes the RETURN value) are not among them"

# ---- the same holes, recorded: fails before, passes after, one line each -------------------------
cat > "$work/dirty/baseline.txt" <<'BASE'
# the three this fixture has, recorded the way main's own file records them
json-name dirty.wit interface:tools/record:call args
json-name dirty.wit interface:tools config
poll-without-future dirty.wit interface:tools status
BASE
out=$(lint "$work/dirty" "$work/dirty/baseline.txt"); rc=$?
[ "$rc" = 0 ] && ok || fail "a recorded baseline must be accepted, exit $rc: $out"
contains "$out" "3 baselined, 0 new" "the baseline is counted as accepted, not as a pass over nothing"

# ... and a baseline line the check no longer flags is a failure: the file must shrink.
out=$(lint "$work/clean" "$work/dirty/baseline.txt"); rc=$?
[ "$rc" = 1 ] && ok || fail "a stale baseline line must fail, exit $rc: $out"
contains "$out" "still lists" "a closed hole must leave the baseline"

# ... and the marker alone turns the polling hole into a pass: the same tree, one doc line.
cp -R "$work/dirty" "$work/marked"
rm -f "$work/marked/baseline.txt"
sed 's|^    status: func|    /// legacy wrapper over submit\
    status: func|' "$work/dirty/dirty.wit" > "$work/marked/dirty.wit"
out=$(lint "$work/marked"); rc=$?
[ "$rc" = 1 ] && ok || fail "the marked tree still has rule 1 holes, exit $rc: $out"
absent "$out" "status" "legacy wrapper over <future-func> accepts the polling func"
contains "$out" "2 new violation(s)" "the other two holes are still holes"

# ---- this tree: the check passes here, and the names it accepts are named ------------------------
out=$(bash scripts/wit-lint.sh 2>&1); rc=$?
[ "$rc" = 0 ] && ok || fail "the tree's own wit/ must pass, exit $rc: $out"
contains "$out" "wit-lint ok" "the tree's verdict line"
contains "$out" "5 baselined" "the five shapes main has are the five this tree records (three JSON-carrying names, two poll funcs)"
listed=$(bash scripts/wit-lint.sh --list 2>&1)
for expected in "codemode.wit	interface:types/record:tool-facts	field schema-json" \
                "hooks.wit	interface:types/record:decision	field updated-input-json" \
                "model.wit	interface:types/record:tool-def	field schema-json" \
                "quickjs.wit	interface:quickjs/record:spec	field tools-json"; do
  case "$listed" in
    *"$expected"*) ok ;;
    *) fail "the tree's own map must show '$expected', as it is one of the names that already comply" ;;
  esac
done
contains "$listed" "kernel/kernel.wit	interface:http/resource:pending	poll	result<response, error>	baselined" "the poll func main has is the one the baseline records, and the list says so"
if printf '%s\n' "$listed" | grep -q 'FAIL'; then
  fail "the tree's own list must have no failing name: $(printf '%s\n' "$listed" | grep 'FAIL' | head -3)"
else ok; fi

echo "wit-lint-selftest ok ($checks checks, $skipped skipped)"

