#!/data/data/com.termux/files/usr/bin/bash
# The one command for a Termux node: clone the checkout if it is not there yet, then do
# whichever of the three things this node actually needs, and say which one it did.
#
#   1. nothing installed           -> a fresh install          (scripts/install-termux.sh)
#   2. an older preview installed  -> the one-time bootstrap   (scripts/termux/adopt-existing.sh)
#   3. already on the update track -> `wa update`              (the installed updater)
#
# WHY. The operator asked for one paste-able line, and the three-step form had a real
# failure mode of its own: an old preview has no `wa update`, so the operator has to know
# which of the two scripts to run, and `--adopt-existing` used to be able to refuse with
# `upstream_url_unknown` when the upstream was not passed. This script removes both
# questions: it picks the step from the installation's own state, and it defaults the
# upstream to the checkout's own remote instead of a hardcoded URL, so a normal `git clone`
# always records where updates come from. `--upstream` still overrides it.
#
# It runs no `wa setup`, touches no provider key, and never clears state: node state lives
# in ~/.wasm-agent, and every step it delegates to already guarantees that byte-for-byte.
# It is a dispatcher, not a second implementation - each step is the reviewed script the
# explicit form has always used, taken from the checkout being installed.
#
# Usage: the one-liner in the README, or from a checkout:
#   bash scripts/termux/bootstrap.sh [--checkout DIR] [--repo URL] [--upstream URL] [--check]
set -euo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
self_root=$(CDPATH= cd -- "$here/../.." && pwd)
. "$self_root/scripts/termux/release-lib.sh"
rl_paths

fail() { printf 'termux-bootstrap: %s\n' "$*" >&2; exit 1; }
note() { printf 'termux-bootstrap: %s\n' "$*"; }

checkout_dir=$self_root
repo_url=
upstream_url=
check_only=

while [ "$#" -gt 0 ]; do
  case "$1" in
    --checkout) [ "$#" -ge 2 ] || fail 'checkout_value_required'; checkout_dir=$2; shift 2 ;;
    --repo) [ "$#" -ge 2 ] || fail 'repo_value_required'; repo_url=$2; shift 2 ;;
    --upstream) [ "$#" -ge 2 ] || fail 'upstream_value_required'; upstream_url=$2; shift 2 ;;
    --check) check_only=1; shift ;;
    *)
      fail "unknown_bootstrap_option: $1 (the options are --checkout DIR, --repo URL, --upstream URL and --check)"
      ;;
  esac
done

command -v git >/dev/null 2>&1 || fail 'git_required: install git (pkg install git)'

# ---- the checkout: clone only if it is not there ----------------------------

if [ ! -d "$checkout_dir/.git" ]; then
  if [ -z "$repo_url" ]; then
    repo_url=$(git -C "$self_root" remote get-url origin 2>/dev/null || true)
  fi
  [ -n "$repo_url" ] ||
    fail "repo_url_unknown: '$checkout_dir' is not a checkout and no --repo was given (the options are --checkout DIR, --repo URL, --upstream URL and --check)"
  mkdir -p -- "$(dirname -- "$checkout_dir")" || fail "cannot create $(dirname -- "$checkout_dir")"
  note "cloning $repo_url into $checkout_dir"
  git clone --quiet --depth 1 "$repo_url" "$checkout_dir" ||
    fail "clone_failed: git clone $repo_url $checkout_dir"
else
  note "reusing the checkout at $checkout_dir"
fi
[ -f "$checkout_dir/scripts/termux/release-lib.sh" ] ||
  fail "not_a_wasm_agent_checkout: $checkout_dir/scripts/termux/release-lib.sh is missing"

# ---- the upstream to record, defaulted from the checkout --------------------

# The checkout's own remote, never a hardcoded URL: whatever the operator cloned from is
# what this node updates from. Any remote is tried if `origin` is somehow absent, and an
# explicit --upstream or WA_TERMUX_UPSTREAM_URL still wins.
if [ -z "$upstream_url" ]; then
  upstream_url=${WA_TERMUX_UPSTREAM_URL:-}
fi
if [ -z "$upstream_url" ]; then
  upstream_url=$(git -C "$checkout_dir" remote get-url origin 2>/dev/null || true)
fi
if [ -z "$upstream_url" ]; then
  first_remote=$(git -C "$checkout_dir" remote 2>/dev/null | head -n 1)
  if [ -n "$first_remote" ]; then
    upstream_url=$(git -C "$checkout_dir" remote get-url "$first_remote" 2>/dev/null || true)
  fi
fi

installed_commit=$(rl_get "$RL_INSTALL/installed.txt" source_commit)
recorded_remote=$(rl_get "$RL_INSTALL/installed.txt" source_remote)

path_present() { [ -e "$1" ] || [ -L "$1" ]; }

# ---- 3. already on the update track: hand over to the installed updater -----

# The test is exactly what an update needs (a recorded revision and an updater), not a
# guess about the layout, so a node that can update is updated rather than re-adopted.
if [ -n "$installed_commit" ] && [ -f "$RL_INSTALL/bin/wa-update" ]; then
  wa_bin=
  for candidate in "$RL_PREFIX/bin/wa" "$RL_INSTALL/bin/wa"; do
    if [ -f "$candidate" ]; then wa_bin=$candidate; break; fi
  done
  [ -n "$wa_bin" ] || fail "launcher_missing: $RL_INSTALL/bin/wa"
  note "this node is on the update track ($(printf '%.12s' "$installed_commit")); running 'wa update'"
  if [ -n "$recorded_remote" ]; then
    if [ -n "$check_only" ]; then exec sh "$wa_bin" update --check; fi
    exec sh "$wa_bin" update
  fi
  # No upstream recorded (a preview from before the updater) - pass the checkout's own.
  [ -n "$upstream_url" ] ||
    fail "upstream_url_unknown: $RL_INSTALL/installed.txt records no source_remote and $checkout_dir has no remote; pass --upstream <git-url>"
  if [ -n "$check_only" ]; then exec sh "$wa_bin" update --check --upstream "$upstream_url"; fi
  exec sh "$wa_bin" update --upstream "$upstream_url"
fi

# ---- 2. an older preview: the one-time bootstrap ----------------------------

if path_present "$RL_INSTALL"; then
  note "adopting the existing installation at $RL_INSTALL"
  if [ -n "$upstream_url" ]; then
    exec bash "$checkout_dir/scripts/termux/adopt-existing.sh" --upstream "$upstream_url"
  fi
  exec bash "$checkout_dir/scripts/termux/adopt-existing.sh"
fi

# ---- 1. nothing installed: a fresh install ----------------------------------

note 'no existing installation: installing fresh'
exec bash "$checkout_dir/scripts/install-termux.sh"
