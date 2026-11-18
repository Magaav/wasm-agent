#!/usr/bin/env bash
# scripts/module-report.mjs judged by fixtures: the counts, the flags and the exit code.
#
# WHY. The report is the map the "Modules over the monolith" rule in ARCHITECTURE.md is argued from:
# module count, size, build time, the win each module states, the co-change pairs that should merge, and
# the decision record the 30-day / 100-commit cooldown reads. A map nobody tests drifts from the tree
# silently and is then quoted as if it were the tree (scripts/test-wit-lint.sh exists for the same
# reason). This proves, on a fixture tree with a fixture git history:
#
#   1. what counts as a module: a crate (Cargo.toml under rust/), a component (rust/components/<name>,
#      counted once, not twice), a feature (modules/<id> WITH a module.json) - and a directory under
#      modules/ with no manifest is NOT counted;
#   2. a module's win line is read from its own manifest, and a module without one is FLAGGED, counted;
#   3. build time comes from the ledger and is printed in seconds, with the unmeasured ones as "-" -
#      a module nothing built is not a fast module;
#   4. a co-change pair over 70% of the last 50 commits is printed as a merge candidate and the ones
#      below it are not;
#   5. a split/merge recorded less than 30 days AND less than 100 commits ago is flagged too soon to
#      reverse; one that clears either threshold is not (ARCHITECTURE.md: "never sooner than 30 days or
#      100 commits" - the earlier of the two ends the cooldown, so both must be short to block);
#   6. the exit code is 0 with every one of those flags set - these are flags, not failures.
#
#   bash scripts/test-module-report.sh
#
# Temp tree, temp git repo, no toolchain, no network, seconds.
set -uo pipefail
cd "$(dirname "$0")/.."
checks=0; skipped=0
ok() { checks=$((checks + 1)); }
fail() { echo "module-report-selftest FAILED: $*" >&2; [ -n "${work:-}" ] && echo "work dir: $work" >&2; exit 1; }
skip() { echo "module-report-selftest SKIPPED: $*"; skipped=$((skipped + 1)); }
contains() { case "$1" in *"$2"*) ok ;; *) fail "$3: '$2' not in: $(printf '%s' "$1" | tail -20)" ;; esac; }
absent() { case "$1" in *"$2"*) fail "$3: '$2' should not be there: $(printf '%s' "$1" | tail -20)" ;; *) ok ;; esac; }

if ! command -v node >/dev/null 2>&1; then
  skip "node is not on PATH, and scripts/module-report.mjs is one node run"
  echo "module-report-selftest: $checks checks, $skipped skipped"; exit 0
fi
if ! command -v git >/dev/null 2>&1; then
  skip "git is not on PATH, and the co-change half of the report reads git history"
  echo "module-report-selftest: $checks checks, $skipped skipped"; exit 0
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/wa-module-report-XXXXXX")
trap 'rm -rf "$work"' EXIT
report() { node scripts/module-report.mjs --root "$work" "$@" 2>&1; }

# ---- the fixture tree: one of each kind, and one directory that is not a module -------------------
mkdir -p "$work/rust/a/src" "$work/rust/b/src" "$work/rust/c/src"
mkdir -p "$work/rust/components/comp/src" "$work/modules/feat" "$work/modules/bare"
for c in a b c; do printf '[package]\nname = "wa-%s"\nversion = "0.1.0"\n' "$c" > "$work/rust/$c/Cargo.toml"; done
printf '[package]\nname = "wa-comp"\nversion = "0.1.0"\n' > "$work/rust/components/comp/Cargo.toml"
printf 'fn a1() {}\nfn a2() {}\nfn a3() {}\n' > "$work/rust/a/src/lib.rs"
printf 'fn b() {}\n' > "$work/rust/b/src/lib.rs"
printf 'fn c() {}\n' > "$work/rust/c/src/lib.rs"
printf 'fn cc() {}\n' > "$work/rust/components/comp/src/lib.rs"
# a module WITH a win (the feature) and a component with a manifest but no win line.
printf '{"id":"feat","version":"0.1.0","win":"panel: 0 rust rebuild, swapped without a restart"}\n' > "$work/modules/feat/module.json"
printf '{"name":"comp","version":"0.1.0"}\n' > "$work/rust/components/comp/manifest.json"

# ---- a fixture history where a and b always move together, and c does not -------------------------
git -C "$work" init -q >/dev/null 2>&1 || fail "the fixture tree could not be a git repository"
n=0
for pair in "rust/a rust/b" "rust/a rust/b" "rust/a rust/b" "rust/a rust/b" "rust/c"; do
  n=$((n + 1))
  for p in $pair; do echo "touch $n" >> "$work/$p/src/lib.rs"; done
  git -C "$work" add -A >/dev/null 2>&1
  git -C "$work" -c user.email=t@t -c user.name=t commit -qm "c$n" >/dev/null 2>&1 || fail "fixture commit $n failed"
done

# The two decision records, written now that there is a history to point at: b (3 days, 4 commits) is
# inside the cooldown, c (60 days, 4 commits) is out of it on the date alone.
recent=$(date -u -d '-3 days' +%Y-%m-%d 2>/dev/null || date -u -v-3d +%Y-%m-%d)
old=$(date -u -d '-60 days' +%Y-%m-%d 2>/dev/null || date -u -v-60d +%Y-%m-%d)
first=$(git -C "$work" rev-list --max-parents=0 HEAD 2>/dev/null | head -1)
[ -n "$first" ] || fail "the fixture history has no first commit"
printf '{"decision":{"kind":"split","date":"%s","commit":"%s","measurement":"rebuild 41s -> 6s"}}\n' "$recent" "$first" > "$work/rust/b/module.json"
printf '{"decision":{"kind":"merge","date":"%s","commit":"%s","measurement":"co-change 80%% of 50"}}\n' "$old" "$first" > "$work/rust/c/module.json"

# ---- 1. the counts and the kinds -----------------------------------------------------------------
out=$(report --no-git); rc=$?
[ "$rc" = 0 ] && ok || fail "the report must exit 0 (flags, not failures), exited $rc: $out"
contains "$out" "5 modules = 3 crate(s), 1 component(s), 1 feature(s)" "a crate, a component (once, not twice), a feature with a manifest; modules/bare is not a module"
absent "$out" "feature:bare" "a modules/ directory with no module.json is not a module"

# ---- 2. the win line, and the flag for the ones without one --------------------------------------
contains "$out" "win       1/5 state a measured win; 4 flagged" "one module states a win; the other four are flagged and counted"
contains "$out" "FLAG no-win:" "the modules without a win are named"
# The rows are the report's body: every module, its size, and its own win line - not just the count.
contains "$out" "win: panel: 0 rust rebuild, swapped without a restart" "the win line itself is printed on the module's row"
contains "$out" "crate:a" "every module has a row (the default is all of them, not a top-N)"
contains "$out" "crate:b" "and so does one with no win at all"
contains "$out" "FLAG no win" "a row with no win says so where a reader looks: on the row"

# ---- 3. build time: measured where the ledger has it, '-' everywhere else ------------------------
timings="$work/timings.tsv"
printf 'crate\ta\t1200\t1 unit(s) compiled\ncrate\tb\t400\t0 units, warm\n' > "$timings"
out=$(report --no-git --timings "$timings")
contains "$out" "build     2/5 measured in this run" "the ledger's two rows are counted as measured"
contains "$out" "1.2s" "milliseconds are printed as seconds"
contains "$out" "0.4s" "and so is the warm row"
absent "$out" "1200" "the raw millisecond count is not printed"
out=$(report --no-git)
contains "$out" "build     0/5 measured in this run (- means not compiled here, not fast)" "with no ledger nothing claims a build time"

# ---- 4. co-change: over 70% is a merge candidate, under it is not ---------------------------------
out=$(report)
contains "$out" "co-change 1 pair(s) over 70% of the last 50 commit(s) (5 commit(s) read)" "exactly the a+b pair is over the line"
contains "$out" "FLAG merge-candidate: crate:a + crate:b (4/5 commits, 80%)" "the pair, its count and its share"
absent "$out" "crate:a + crate:c" "a pair below 70% is not a merge candidate"
out=$(report --no-git)
contains "$out" "not read (--no-git)" "--no-git says so instead of reading nothing as zero"

# ---- 5. the decision record: the cooldown is visible, and only flags inside it -------------------
out=$(report)
contains "$out" "decision  2 recorded; cooldown 30 day(s) or 100 commit(s)" "both decisions are listed with the cooldown it enforces"
contains "$out" "crate:b: split on $recent" "the recent split is printed with its date"
contains "$out" "rebuild 41s -> 6s" "and with its measurement"
contains "$out" "crate:c: merge on $old" "the old merge is printed too"
[ "$(printf '%s' "$out" | grep -c 'FLAG too soon to reverse')" = 1 ] && ok || fail "exactly one decision is inside the cooldown (3 days AND 4 commits), and the 60-day one is not: $out"

# ---- 6. this tree: the report runs here and its map is the tree's --------------------------------
out=$(node scripts/module-report.mjs --rows 3 2>&1); rc=$?
[ "$rc" = 0 ] && ok || fail "the report on this tree must exit 0, exited $rc: $out"
contains "$out" "modules =" "this tree's module count is printed"
contains "$out" "crate:wa-capabilities" "the largest crate is in the top of the map"
contains "$out" "co-change" "and the co-change half ran on real history"

echo "module-report-selftest ok ($checks checks, $skipped skipped)"
