#!/usr/bin/env bash
# Publish the pinned WASI components as a release bundle, so a node that never built wasm can deploy
# main with no manual step (docs/COMPONENTS.md "Distributing components").
#
# WHY. A component is a wasm32-wasip2 artifact, and wasm is portable: the same bytes run on Linux,
# Windows, x86_64 and arm64. So the graph - pinned in components.lock by sha256 and size - only has to
# be BUILT once, on the machine that has wasi-sdk, and every other node can install the pinned bytes
# instead of rebuilding them (a build is not byte-reproducible across checkout paths, so a rebuild
# cannot match the pin: components.lock). This script does the building half. It never publishes
# anything itself: it builds, verifies every artifact against components.lock, assembles the bundle
# (<name>.wasm + <name>.json manifest for every pinned name, plus components.lock), and prints the
# exact `gh release create` line for a human (or the coordinator) to run.
#
# The release tag is `components-<first 12 hex of sha256(components.lock)>`, so a node names the exact
# bundle its pins describe without reading anything but the pins, and a node whose lock differs asks
# for a different tag (deploy.sh: scripts/lib/deploy-components.sh).
#
#   bash scripts/publish-components.sh                  # build every component components.lock pins,
#                                                       # verify, bundle, print the gh command
#   bash scripts/publish-components.sh --check          # what would be built and uploaded; build nothing
#   bash scripts/publish-components.sh --from DIR       # verify artifacts built elsewhere, bundle them
#   bash scripts/publish-components.sh --repo DIR --out DIR
#
# Exit codes: 0 ok; 2 missing tool/lock/artifacts; 5 an artifact is not the pinned one (the line that
# would pin it is printed); 6 an artifact's size is not the pinned one.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
REPO_ROOT="$ROOT"
OUT="$ROOT/build/components-release"
FROM=""
CHECK=0
say() { printf 'publish-components: %s\n' "$*"; }
fail() { printf 'publish-components: %s\n' "$*" >&2; exit "${2:-2}"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || fail 'repo_value_required'; REPO_ROOT="$2"; shift 2 ;;
    --out) [ "$#" -ge 2 ] || fail 'out_value_required'; OUT="$2"; shift 2 ;;
    --from) [ "$#" -ge 2 ] || fail 'from_value_required'; FROM="$2"; shift 2 ;;
    --check) CHECK=1; shift ;;
    -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail "unknown_option: $1" ;;
  esac
done
[ -f "$REPO_ROOT/components.lock" ] || fail "components_lock_missing: $REPO_ROOT/components.lock"
. "$ROOT/scripts/lib/deploy-components.sh"

lock_sha="$(wa_component_lock_sha "$REPO_ROOT")" || fail "components_lock_unreadable: $REPO_ROOT/components.lock"
tag="$(wa_component_release_tag "$REPO_ROOT")" || fail "components_lock_unreadable: $REPO_ROOT/components.lock"
slug="$(wa_component_release_repo "$REPO_ROOT")"
commit="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || printf 'unknown')"

# Which components: exactly the names components.lock pins, in the lock's own order. Nothing here
# guesses a component: a wasm that is not pinned cannot be published by this script.
names="$(awk '/^[[:space:]]*(#|$)/ {next} $1 != "" && $2 ~ /^[0-9a-f]+$/ {print $1}' "$REPO_ROOT/components.lock")"
[ -n "$names" ] || fail "components_lock_empty: no pinned component in $REPO_ROOT/components.lock"

# The bundle directory is what ships: the build writes it, `--from` copies artifacts another machine
# built into it, and `--check --from` only reads them where they are (nothing is written). Everything is
# verified in the bundle directory that will be uploaded.
ART="$OUT"
[ "$CHECK" = 1 ] && [ -n "$FROM" ] && ART="$FROM"
assets=""
for name in $names; do
  assets="$assets $ART/$name.wasm $ART/$name.json"
done
assets="$assets $ART/components.lock"

if [ "$CHECK" = 1 ] && [ -z "$FROM" ]; then
  say "would build from $REPO_ROOT/scripts/build-components.sh: $(printf '%s ' $names)"
  say "bundle dir: $OUT"
  say "release tag: $tag (components.lock sha256 $lock_sha)"
  say "would publish $assets"
  exit 0
fi

if [ -n "$FROM" ] && [ "$ART" != "$FROM" ]; then
  mkdir -p "$ART" || fail "bundle_unwritable: $ART"
  for name in $names; do
    for file in "$name.wasm" "$name.json"; do
      [ -f "$FROM/$file" ] || fail "component_missing: $FROM/$file"
      cp -f "$FROM/$file" "$ART/.$file.tmp" && mv -f "$ART/.$file.tmp" "$ART/$file" \
        || fail "bundle_unwritable: $ART/$file"
    done
  done
  say "bundle assembled from $FROM into $ART"
fi

if [ -z "$FROM" ]; then
  command -v cargo >/dev/null 2>&1 || fail 'cargo_missing: the build half of this script needs cargo and, for a component with C inside, wasi-sdk (WASI_SDK=<dir>)'
  say "building $(printf '%s ' $names)into $OUT (needs wasi-sdk for a component with C inside)"
  mkdir -p "$OUT" || fail "bundle_unwritable: $OUT"
  # build-components.sh installs into WA_COMPONENTS_DIR: build straight into the bundle directory, so
  # the artifact that is verified below is the artifact that ships.
  WA_COMPONENTS_DIR="$OUT" bash "$REPO_ROOT/scripts/build-components.sh" $names \
    || fail 'build_failed: scripts/build-components.sh did not build every pinned component (needs wasi-sdk, WASI_SDK=<dir>)'
fi

# Verify every artifact against the pin BEFORE anything is printed for upload. A bundle that is not the
# pinned one must never reach a release: every node would then be asked to install bytes its lock
# refuses (the deploy verifies again, so the failure would land on each node instead of here).
#
# EVERY component is measured, and every drifted line is printed before this fails. Stopping at the first
# one is what left ten pins stale on 13/11: a run printed `artifact_not_pinned: agent-core`, a person
# committed that one line, and the next run printed the next one - while `agent-core`, `codemode`,
# `graph`, `hooks`, `memory`, `mesh`, `model-gateway`, `selfloop`, `telemetry-sink`, `wa-email` and
# `wa-whatsapp` were all not the build of main. One run now names all of them.
drift=""
drift_sha=0
drift_bytes=0
for name in $names; do
  pin="$(wa_component_pin "$REPO_ROOT" "$name")" || fail "component_pin_missing: $name"
  pin_sha="${pin%% *}"
  pin_bytes="${pin##* }"
  wasm="$ART/$name.wasm"
  [ -f "$wasm" ] || fail "component_missing: $wasm"
  [ -f "$ART/$name.json" ] || fail "component_missing: $ART/$name.json"
  actual="$(wa_component_sha256 "$wasm")" || fail 'sha256_tool_missing: no sha256sum or shasum'
  bytes="$(wc -c < "$wasm" | tr -d '[:space:]')"
  if [ "$actual" != "$pin_sha" ]; then
    say "measured $name: sha256 $actual ($bytes bytes); components.lock pins $pin_sha ($pin_bytes bytes)"
    drift="$drift$name $actual $bytes"$'\n'
    drift_sha=1
    continue
  fi
  if [ "$pin_bytes" != "-" ] && [ "$bytes" != "$pin_bytes" ]; then
    say "measured $name: sha256 $actual ($bytes bytes); components.lock pins $pin_bytes bytes"
    drift="$drift$name $actual $bytes"$'\n'
    drift_bytes=1
    continue
  fi
  say "verified $name: $actual ($bytes bytes)"
done

if [ -n "$drift" ]; then
  drifted_names="$(printf '%s' "$drift" | awk '{printf "%s ", $1}')"
  drifted_count="$(printf '%s' "$drift" | grep -c .)"
  pinned_count="$(printf '%s\n' $names | grep -c .)"
  say "$drifted_count of $pinned_count pinned component(s) are not the build of this tree. Commit these lines with the component change that caused each one:"
  printf '%s' "$drift" >&2
  if [ "$drift_sha" = 1 ]; then
    fail "artifact_not_pinned: ${drifted_names% } - not the build this tree pins (sha256); the lines above are what to commit" 5
  fi
  fail "artifact_not_pinned: ${drifted_names% } - the pinned size, not the pinned bytes; the lines above are what to commit" 6
fi

# The lock travels with the artifacts: it is the bundle's identity (the deploy compares it to its own
# before it caches or stages anything), and the tag is derived from it.
cp -f "$REPO_ROOT/components.lock" "$ART/.components.lock.tmp" && mv -f "$ART/.components.lock.tmp" "$ART/components.lock" \
  || fail "bundle_unwritable: $ART/components.lock"

say "bundle: $ART"
say "release tag: $tag (sha256 of components.lock: $lock_sha)"
say 'publishing is a human/coordinator action; this script never runs gh. The exact command:'
notes="Pinned WASI components for components.lock $lock_sha (source $commit)"
printf '\ngh release create %s -R %s --title %s --notes %s%s\n\n' \
  "$tag" "$slug" "$tag" "'$notes'" "$(printf ' %s' $assets)"
say 'If the tag already exists (a re-publish of the same lock), upload over it instead:'
printf '\ngh release upload %s -R %s%s --clobber\n\n' "$tag" "$slug" "$(printf ' %s' $assets)"
say "A node then needs nothing but this: bash scripts/deploy.sh (it fetches $tag, verifies every sha256"
say "against components.lock and caches it under <install>/components-cache/$lock_sha)."
say "publish-components ok: $tag $lock_sha"
