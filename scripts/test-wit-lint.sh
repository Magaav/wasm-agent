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
#     and the baseline exist for, and it is proved here rather than asserted;
#   * a WORLD ITEM is read like any other declaration: `export run: func(args: string)` is a func both
#     rules judge, and an inline `import x: interface {...}` opens a block whose own `}` closes it -
#     not the world around it. `world.wit` fails with four holes and their contexts;
#     `world-clean.wit` (a world of references only) does not.
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
json-name dirty.wit interface:tools run.config
poll-without-future dirty.wit interface:tools status
BASE
out=$(lint "$work/dirty" "$work/dirty/baseline.txt"); rc=$?
[ "$rc" = 0 ] && ok || fail "a recorded baseline must be accepted, exit $rc: $out"
contains "$out" "3 baselined (2 json-name, 1 poll-without-future), 0 new" "the baseline is counted as accepted, not as a pass over nothing, and by the rule it recorded"

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

# ---- the shapes that escaped the reader, and the false positives it raised -----------------------
# Each of these is a hole a review found in the first version of this check:
#   * a func split over two lines ('status:' then 'func(...)') and a %-escaped name (%poll) were not
#     funcs at all, so rule 2 never saw them;
#   * 'start: func() -> job' at interface level beside 'resource job { poll }' is the pair the rule is
#     about, and the two funcs are not siblings in the text;
#   * 'record r { args: string, payload-json: string }' hid both fields AND left the record open, so
#     every later declaration was attributed to it; a comma-separated field list was skipped whole;
#   * 'e.g. application/json' is a MIME type and 'never JSON' is a denial - neither is a field that
#     carries a JSON value;
#   * 'status: func() -> health' beside 'self-id: func() -> node-id' reads two values; only a -id the
#     poll func TAKES is a handle;
#   * 'resource terminal-input;' has no body: it names a resource and its declaration is over, so it
#     must not push a context (the two in wit/kernel-v2/deps/cli.wit left every later declaration in
#     that file one block too deep, and the next '}' popped the wrong block);
#   * 'start: func() -> own<job>' and 'start: func() -> result<borrow<job>, error>' are the start side
#     of 'resource job { poll }' too: the handle arrives wrapped, not bare;
#   * 'not empty, JSON text' says the value IS JSON - a negation only denies JSON when it governs the
#     mention, so a comma between 'not' and 'json' is not a denial.
mkdir -p "$work/shapes"
cat > "$work/shapes/shapes.wit" <<'WIT'
package wa:fixture@0.1.0;

interface shapes {
    type operation-id = string;

    submit: func(kind: string) -> result<operation-id, error>;

    /// The placement's state.
    status:
        func(id: operation-id) -> result<string, error>;

    %poll: func(id: operation-id) -> result<string, error>;

    /// The call, on one line with its record.
    record one-line { args: string, payload-json: string }

    /// A record whose last two fields share a line with its closing brace.
    record comma {
        /// The tool's JSON schema.
        schema: string, id: u32 }

    /// A record AFTER the one-liners: it belongs to the interface, not to the record above it.
    record later {
        /// The JSON body.
        payload: string,
    }

    /// What the transport says about itself.
    record media {
        /// The media type this header carries, e.g. application/json.
        content-type: string,
        /// The framing is never JSON: a framed byte stream.
        framing: string,
    }
}

interface node-info {
    self-id: func() -> node-id;
    status: func() -> health;
}

interface ops {
    type op-id = string;
    submit: func(kind: string) -> result<op-id, error>;
    poll: func(id: op-id) -> result<string, error>;
}

interface jobs {
    start: func() -> job;
    resource job {
        poll: func() -> result<string, error>;
    }
}
WIT
out=$(lint "$work/shapes"); rc=$?
[ "$rc" = 1 ] && ok || fail "the shapes fixture must fail, exit $rc: $out"
contains "$out" "6 new violation(s)" "the split status, the %poll, the interface-level start/job pair, the comma field, the later field and the id-taking poll: six, and exactly six"
contains "$out" "[interface:shapes] status" "a func split over two lines is a func"
contains "$out" "[interface:shapes] poll" "a %-escaped name is the name without its %"
contains "$out" "beside start handing out resource:job" "start at interface level is a sibling of the funcs inside its resource"
contains "$out" "[interface:shapes/record:comma] schema" "a field on a line that also closes its record is still a field"
contains "$out" "[interface:shapes/record:later] payload" "the one-line record was CLOSED: the next record belongs to the interface"
absent "$out" "record:one-line/record:later" "a one-line record does not stay open and swallow later declarations"
absent "$out" "content-type" "a MIME type is not a field that carries a JSON value"
absent "$out" "framing" "a doc that says a field is never JSON does not make it JSON"
absent "$out" "node-info" "status: func() -> health beside self-id: func() -> node-id reads two values"
contains "$out" "[interface:ops] poll" "a poll func that TAKES the id is the pair, and still fails"
listed=$(WIT_LINT_DIR="$work/shapes" WIT_LINT_BASELINE="$work/shapes/no-baseline.txt" bash scripts/wit-lint.sh --list 2>&1 || true)
contains "$listed" "record:one-line	field payload-json	string	ok" "a field of a one-line record is in the map, so rule 1 can judge it"

# ---- a resource with no body: it names a resource, and its declaration is over --------------------
# wit/kernel-v2/deps/cli.wit:126 and :138 are 'resource terminal-input;' and 'resource terminal-output;'.
# The reader pushed both on the context stack and nothing ever popped them, so each declaration after
# them was read one block too deep and the next '}' closed the wrong block. Both halves are proved here:
# the context the declarations after it get, and that the name is still recorded - a bodyless resource
# is still the resource a start func hands out.
mkdir -p "$work/bodyless"
cat > "$work/bodyless/bodyless.wit" <<'WIT'
package wa:fixture@0.1.0;

interface handles {
    /// The input side of a terminal: a handle with no functions of its own.
    resource terminal-input;

    get-stdin: func() -> option<terminal-input>;
}

interface later {
    /// The JSON body of the request.
    body: string,
}

interface jobs {
    resource job;

    start: func() -> job;

    poll: func() -> result<string, error>;
}

interface braces {
    /// A record whose opening brace is on a line of its own.
    record split
    {
        /// The JSON name.
        name: string,
    }
}
WIT
out=$(lint "$work/bodyless"); rc=$?
[ "$rc" = 1 ] && ok || fail "the bodyless fixture must fail on its own holes, exit $rc: $out"
contains "$out" "3 new violation(s)" "body, poll and name: three holes, and exactly three"
contains "$out" "[interface:later] body" "a bodyless resource pushes nothing: the interface after it is where it says it is"
absent "$out" "interface:handles/interface:later" "the interfaces after it are not read as nested inside each other"
contains "$out" "[interface:jobs] poll" "and the funcs after it belong to their own interface, not to the resource above"
contains "$out" "beside start handing out resource:job" "the bodyless resource is still a resource: the start func returning it still pairs with the poll"
contains "$out" "[interface:braces/record:split] name" "a brace alone on its line still opens the block named above it"

# ---- a handle that arrives wrapped: own<job> and borrow<job> are the resource inside them ----------
# The pair is 'start' at interface level beside the funcs INSIDE the resource it hands out; the return
# type names that resource through a wrapper, so an unwrap that stopped at option/result read
# 'own<job>' as a type called 'own<job>' and the pair vanished.
mkdir -p "$work/wrapped"
cat > "$work/wrapped/wrapped.wit" <<'WIT'
package wa:fixture@0.1.0;

interface own-jobs {
    start: func() -> own<job>;
    resource job {
        poll: func() -> result<string, error>;
    }
}

interface borrowed-jobs {
    start: func() -> result<borrow<job>, error>;
    resource job {
        poll: func() -> result<string, error>;
    }
}

interface plain-jobs {
    start: func() -> job;
    resource job {
        poll: func() -> result<string, error>;
    }
}
WIT
out=$(lint "$work/wrapped"); rc=$?
[ "$rc" = 1 ] && ok || fail "the wrapped-handle fixture must fail, exit $rc: $out"
contains "$out" "3 new violation(s)" "own<job>, borrow<job> inside a result, and the bare job: three pairs, exactly three"
[ "$(printf '%s' "$out" | grep -c 'beside start handing out resource:job')" = 3 ] && ok || fail "each start hands out the resource it returns, wrapper or not: $out"

# ---- a negation has to govern the mention it denies ------------------------------------------------
# "never JSON" denies JSON. "not empty, JSON text" does not: the negation governs "empty", and the field
# carries JSON text. The four denials and the MIME type beside it stay clean, so this is a narrowing of
# the denial and not a removal of it.
mkdir -p "$work/negation"
cat > "$work/negation/negation.wit" <<'WIT'
package wa:fixture@0.1.0;

interface calls {
    record args {
        /// The user's own arguments: not empty, JSON text.
        args: string,
        /// The user's own arguments: never JSON.
        raw: string,
        /// The framing is never JSON: a framed byte stream.
        framing: string,
        /// The media type this header carries, e.g. application/json.
        content-type: string,
        /// Carries no JSON: the bytes are framed.
        bytes: string,
    }
}
WIT
out=$(lint "$work/negation"); rc=$?
[ "$rc" = 1 ] && ok || fail "the negation fixture must fail on the clause that IS JSON, exit $rc: $out"
contains "$out" "args: string" "'not empty, JSON text' says the value is JSON, and the negation does not govern it"
contains "$out" "1 new violation(s)" "and it is the only one: the denials and the MIME type are not violations"
absent "$out" "framing" "a clause that says the framing is never JSON is a denial"
absent "$out" "content-type" "a MIME type is not a value this field holds"
absent "$out" "bytes" "carries no JSON is a denial"

# ---- a parameter's baseline key carries its function --------------------------------------------
# WIT has no per-parameter doc, so 'run(config: string)' and 'reload(config: string)' can be documented
# identically in one interface. A key that named only the parameter would let the second one through
# as already recorded - the hole this proves closed.
mkdir -p "$work/member"
cat > "$work/member/member.wit" <<'WIT'
package wa:fixture@0.1.0;

interface svc {
    /// config is the non-secret configuration object (JSON text) from the registry definition.
    run: func(config: string) -> result<_, string>;
    /// config is the non-secret configuration object (JSON text) from the registry definition.
    reload: func(config: string) -> result<_, string>;
}
WIT
printf 'json-name member.wit interface:svc run.config\n' > "$work/member/run-only.txt"
out=$(lint "$work/member" "$work/member/run-only.txt"); rc=$?
[ "$rc" = 1 ] && ok || fail "a baselined parameter of one func must not cover another func's, exit $rc: $out"
contains "$out" "reload.config" "the new func's parameter is the one that fails"
contains "$out" "1 new violation(s)" "run.config is accepted and reload.config is not"
printf 'json-name member.wit interface:svc config\n' > "$work/member/bare.txt"
out=$(lint "$work/member" "$work/member/bare.txt"); rc=$?
[ "$rc" = 1 ] && ok || fail "a key without its function must not accept anything, exit $rc: $out"
contains "$out" "2 new violation(s)" "a parameter key with no function in it matches neither parameter"

# ---- a world item: an exported func is a func, and an inline interface is a block, not the world's end
# wit/kernel/host.wit ends with three world-level funcs ('export run: func(entry: string,
# args: list<string>)', ':92' and ':97'). Every line starting with export/import used to be accumulated
# as a use statement until its ';', so those three were never funcs at all: rule 1 never read their
# parameters and rule 2 never saw them beside one another. The same accumulator swallowed an inline
# 'import x: interface {...}': its brace pushed nothing, so its own '}' popped the WORLD, and every
# declaration after it was read outside the world it sits in. Both halves are proved here, and the
# clean world beside them proves the shape itself is not a violation.
mkdir -p "$work/world"
cat > "$work/world/world.wit" <<'WIT'
package wa:fixture@0.1.0;

interface types {
    type operation-id = string;
}

world core-component {
    import types;

    /// Run the entry with the args the caller passes: the args are the user's own JSON text.
    export run: func(args: string) -> result<_, string>;

    export submit: func() -> operation-id;

    /// The placement's state, for the caller that still polls it.
    export status: func(id: operation-id) -> result<string, error>;

    import wa:kernel/log@0.1.0;

    import handles: interface {
        /// config is the non-secret configuration object (JSON text) from the registry definition.
        open: func(config: string) -> result<_, string>;
    }

    /// The last answer: the payload is the JSON text of the last one.
    export last: func(payload: string) -> result<_, string>;

    export stop: func();
}
WIT
out=$(lint "$work/world"); rc=$?
[ "$rc" = 1 ] && ok || fail "the world fixture must fail, exit $rc: $out"
contains "$out" "4 new violation(s)" "the exported funcs and the inline interface: four holes, and exactly four"
contains "$out" "[world:core-component] run.args" "a world-level 'export run: func(args: string)' is a func, and rule 1 judges its parameter"
contains "$out" "[world:core-component] status" "a world-level status is the polling func rule 2 exists for"
contains "$out" "beside submit handing out operation-id" "and the handle it sits beside is read in the world, not skipped with it"
contains "$out" "[world:core-component/interface:handles] open.config" "an inline 'import handles: interface {...}' is a block: its funcs are read INSIDE it"
contains "$out" "[world:core-component] last.payload" "and its '}' closed that block, not the world: the declaration after it is still the world's"
absent "$out" "[world:core-component/interface:handles] last" "the world did not end at the inline interface"

mkdir -p "$work/world-clean"
cat > "$work/world-clean/clean.wit" <<'WIT'
package wa:fixture@0.1.0;

interface service {
    ping: func() -> result<u32, string>;
}

world svc {
    import types;
    export service;
    include other-world;
}
WIT
out=$(lint "$work/world-clean"); rc=$?
[ "$rc" = 0 ] && ok || fail "a world of references alone is not a violation, exit $rc: $out"
contains "$out" "0 new" "import/export/include of an existing interface declare nothing and are judged as nothing"

# ---- this tree: the check passes here, and the names it accepts are named ------------------------
out=$(bash scripts/wit-lint.sh 2>&1); rc=$?
[ "$rc" = 0 ] && ok || fail "the tree's own wit/ must pass, exit $rc: $out"
contains "$out" "wit-lint ok" "the tree's verdict line"
contains "$out" "5 baselined (3 json-name, 2 poll-without-future)" "the five shapes main has are the five this tree records, and the two kinds are counted apart (three JSON-carrying names, two poll funcs)"
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

