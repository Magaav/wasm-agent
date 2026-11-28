#!/usr/bin/env bash
# main-health GRADES THE TIP IT IS TOLD, NOT THE CHECKOUT'S LOCAL `main` (28/11, operator).
#
# MEASURED on the live loop: it announced "grading 12379703" and main-health graded 9eaa1dbc - the checkout's local
# `main` branch, which lags origin/main by however long nobody pulled. So the verdict line and the attribution named a
# commit nobody had measured, and a green page could be about an hours-old tree. The suite now takes --sha (the tip the
# caller claimed) and otherwise defaults to origin/main AFTER a fetch.
#
# The suite itself is faked: this row is about WHICH COMMIT is checked out and stamped into the report, not about the
# rows inside it.
# ONE OWNER for "run git where this row means, not where the caller redirects git" (27/11): a suite started from a git
# hook exports GIT_DIR/GIT_INDEX_FILE/GIT_WORK_TREE, and a bare `git init`/`git config` then writes into the shared
# repository instead of this row’s fixture. scripts/lib/git-env.sh is the one place that clears them.
. "$(cd "$(dirname "$0")/.." && pwd)/scripts/lib/git-env.sh"
git() { wa_git "$@"; }
set -u
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
repo=$work/repo; mkdir -p "$repo/scripts"
git init -q -b main "$repo"
git -C "$repo" config user.email t@example.invalid
git -C "$repo" config user.name t

# a fake fast path: it writes the result file main-health reads and says nothing else.
cat > "$repo/scripts/fast.sh" <<'EOS'
#!/usr/bin/env bash
printf '{"summary":{"ok":true,"checks":2,"passed":2,"failed":0,"skipped":0},"checks":[{"name":"a","status":"pass"},{"name":"b","status":"pass"}]}\n' > "${WA_FAST_RESULT:?}"
exit 0
EOS
chmod +x "$repo/scripts/fast.sh"
git -C "$repo" add -A >/dev/null; git -C "$repo" commit -q -m one
OLD=$(git -C "$repo" rev-parse HEAD)

# the newer tip lives on another branch: a commit on `main` would move it, and the point is that main is STALE.
git -C "$repo" checkout -q -b side
git -C "$repo" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m two
NEW=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" checkout -q main

# origin/main points at NEW while the LOCAL branch main stays at OLD - the exact live shape.
git -C "$repo" update-ref refs/remotes/origin/main "$NEW"
[ "$(git -C "$repo" rev-parse main)" = "$OLD" ] || { echo 'harness: local main is not the stale one' >&2; exit 2; }

mkdir -p "$work/m"
run() { WA_MAIN_HEALTH_REPO=$repo WA_MAIN_HEALTH_ROOT=$work/root WA_MISSIONS_ROOT=$work/m \
  WA_SUITE_LOCK=$work/lock WA_MAIN_HEALTH_NICE=0 WA_MAIN_HEALTH_OUT=$work/out.json \
  bash "$here/scripts/main-health.sh" "$@" > "$work/log" 2>&1; }

fail() { echo "main-health-grades-the-tip: $1" >&2; echo '--- log:' >&2; tail -5 "$work/log" >&2; echo '--- json:' >&2; cat "$work/out.json" 2>/dev/null >&2; exit 1; }

# 1) THE CALLER'S TIP WINS: --sha NEW while the local main is OLD.
run --sha "$NEW" || fail "the suite refused a tip it was given (exit $?)"
got=$(jq -r '.sha // empty' "$work/out.json" 2>/dev/null)
[ "$got" = "$NEW" ] || fail "the report is stamped $got, not the tip it was told to grade (${NEW:0:8})"

# 2) NO --sha: origin/main, after a fetch, NOT the stale local branch.
rm -f "$work/out.json"
run || fail "the suite refused to run without --sha (exit $?)"
got=$(jq -r '.sha // empty' "$work/out.json" 2>/dev/null)
[ "$got" = "$NEW" ] || fail "without --sha it graded ${got:0:8} - the stale local main (${OLD:0:8}) instead of origin/main (${NEW:0:8})"

echo "main-health grades the tip it is told (--sha ${NEW:0:8}) and otherwise origin/main after a fetch, never a local main that only moves when a human pulls"
