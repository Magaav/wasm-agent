#!/usr/bin/env bash
# THE LANDING'S SECOND PUBLISH: the components bundle, and the sentence about installability.
#
# WHY THIS FILE (24/11). A landing publishes a node binary keyed by commit - and a node ALSO needs the
# components bundle keyed by the sha256 of components.lock. Nothing published that bundle per landing, so a
# landing that moved the lock published a binary whose bundle did not exist (components-df6f97708c72
# answered HTTP 404), and every node without a toolchain refused the update. scripts/publish-node-binaries.sh
# learns the two steps from here; scripts/test-publish-components-at-landing.sh proves them with a fixture
# bundle (the REAL scripts/publish-components.sh verification) and a gh that only records what it was asked.
#
# OFF UNTIL THE OPERATOR SAYS: WA_PUBLISH_COMPONENTS=1. A components release is a fleet-wide artifact that
# every node verifies against its lock, so turning it on is a decision, not a landing's convenience.
#
# WA_COMPONENTS_BUNDLE=<dir> publishes artifacts built where the pins were made; without it the bundle is
# rebuilt here, which needs cargo and the WASI toolchain (scripts/publish-components.sh refuses by name).

# ---- THE COMPONENTS BUNDLE THIS COMMIT NEEDS (24/11) --------------------------------------------
# A landing publishes a node binary keyed by commit; a node ALSO needs the components bundle keyed by the
# sha256 of components.lock (scripts/lib/deploy-components.sh, wa_component_release_tag). Nothing published
# that bundle per landing, so a landing that moved the lock published a binary whose bundle did not exist -
# components-df6f97708c72 answered HTTP 404 - and every node without a toolchain refused the update. This
# step runs on every --publish run INCLUDING the "covered" one, because a lock-only or docs-only landing
# publishes no binary at all and still needs its bundle.
#
# OFF UNTIL THE OPERATOR SAYS (WA_PUBLISH_COMPONENTS=1). A components release is a fleet-wide artifact that
# every node verifies against its lock, so turning it on is a decision, not a landing's convenience. With the
# flag off this step publishes nothing and says the sentence the land report carries.
#
# WHERE THE BYTES COME FROM: WA_COMPONENTS_BUNDLE=<dir> publishes artifacts built where the pins were made
# (scripts/publish-components.sh --from verifies every one against the lock before anything is printed for
# upload); without it the bundle is rebuilt HERE, which needs cargo and wasi-sdk - the landing host has the
# toolchain that builds node binaries, not necessarily that one, and publish-components.sh refuses by name.
# THE TWO QUESTIONS THIS FILE ASKS A PUBLISHED RELEASE (wa_release_tag_state, wa_release_http_status) live
# in scripts/lib/release-completeness.sh. publish-node-binaries.sh sources it first; a caller that sources
# only this file still gets them, from beside this file, rather than failing at the one moment a publish is
# half done.
if ! command -v wa_release_http_status >/dev/null 2>&1; then
  _wa_lcp_self="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  [ -f "$_wa_lcp_self/release-completeness.sh" ] && . "$_wa_lcp_self/release-completeness.sh"
fi
components_step() { # needs ROOT, COMMIT, REPO_SLUG, OUT
  local tag state rc dir expected missing present asset status notes lock_sha paths name
  tag="$(wa_release_components_tag "$ROOT" "$COMMIT" 2>/dev/null)"
  if [ -z "$tag" ]; then
    say "components: components.lock at ${COMMIT:0:12} cannot be read, so the bundle this commit needs is unknown; nothing is claimed about installability"
    return 2
  fi
  # THE SET THIS LANDING OWES, from the lock alone: every pinned name's module and manifest, and the lock
  # itself. Named before anything is fetched or built, so a tag that already holds all of it costs NOTHING
  # (no bundle is produced) and a tag that holds part of it is known to hold part of it.
  expected=""
  for name in $(awk '/^[[:space:]]*(#|$)/ {next}; $1 != "" && $2 ~ /^[0-9a-f]+$/ {print $1}' "$ROOT/components.lock"); do
    expected="$expected $name.wasm $name.json"
  done
  expected="$expected components.lock"
  if [ -z "$expected" ]; then
    say "components: components.lock at ${COMMIT:0:12} pins no component; nothing is claimed about installability"
    return 2
  fi
  state="$(wa_release_tag_state "$REPO_SLUG" "$tag")"; rc=$?
  case "$rc" in
    2) say "components: could not ask the release channel about $tag ($state); installability is UNKNOWN, not assumed"; return 2 ;;
  esac
  # IS THE SET THERE? A published tag is not a complete tag: the per-landing publish makes the node binary
  # first and this bundle after it, and a run that died halfway left part of a set. So the assets are asked
  # for their status either way, and the answer decides between "complete", "complete it" and "refuse".
  missing=""; present=0
  for asset in $expected; do
    status="$(wa_release_http_status "$(wa_release_asset_url "$REPO_SLUG" "$tag" "$asset")")" || true
    case "$status" in
      200) present=$((present + 1)) ;;
      404) missing="$missing $asset" ;;
      *) if [ "${WA_PUBLISH_COMPONENTS:-0}" = 1 ]; then
           # NEVER AN UPLOAD OVER SOMETHING NOBODY CAN SEE (Fable, 24/11; Victor: nothing overwritten).
           fail "components_publish_unanswerable: $tag/$asset answered '${status}', so this run cannot tell whether it is published - uploading could replace an asset nobody can see; nothing was uploaded and nothing was replaced" 8
         fi
         say "components: $tag/$asset could not be asked (${status}), so whether this landing is installable by download is UNKNOWN, not assumed"
         return 2 ;;
    esac
  done
  local owed=0
  owed=$(printf '%s\n' $expected | grep -c .)
  if [ -z "$missing" ] && [ "$rc" = 0 ]; then
    say "components: $tag already holds every asset ($present of $owed); nothing was uploaded and nothing was replaced"
    return 0
  fi
  if [ "${WA_PUBLISH_COMPONENTS:-0}" != 1 ]; then
    if [ "$rc" = 0 ]; then
      say "components: $tag exists but holds $present of $owed assets (missing:${missing}); a node cannot install this commit by download until they are there. WA_PUBLISH_COMPONENTS=1 uploads only the missing ones - nothing already published is replaced"
    else
      say "components: $tag is NOT published, so this landing is not installable by download on a node without a toolchain (the node binary above is). WA_PUBLISH_COMPONENTS=1 publishes the bundle from this landing - a components release is fleet-wide, so that is the operator's word to give"
    fi
    return 0
  fi
  dir="$OUT/components-release"
  if [ -n "${WA_COMPONENTS_BUNDLE:-}" ]; then
    bash "$ROOT/scripts/publish-components.sh" --repo "$ROOT" --out "$dir" --from "$WA_COMPONENTS_BUNDLE" \
      || { rc=$?; fail "components_publish_failed: scripts/publish-components.sh refused the bundle in ${WA_COMPONENTS_BUNDLE} (rc=$rc); nothing was uploaded, and the lines above say which artifact is not its pin" "$rc"; }
  else
    bash "$ROOT/scripts/publish-components.sh" --repo "$ROOT" --out "$dir" \
      || { rc=$?; fail "components_publish_failed: scripts/publish-components.sh could not build and verify the pinned set (rc=$rc; a WASI toolchain and the pinned rustc are needed here, or name WA_COMPONENTS_BUNDLE=<dir> with artifacts built where the pins were made); nothing was uploaded" "$rc"; }
  fi
  for asset in $expected; do
    [ -f "$dir/$asset" ] || fail "components_publish_failed: $asset is not in the verified bundle; nothing was uploaded" 2
  done
  command -v gh >/dev/null 2>&1 || fail 'publish_tool_missing: --publish needs gh on PATH and an authenticated account (gh auth status)' 2
  lock_sha="$(wa_component_lock_sha "$ROOT" 2>/dev/null)"
  notes="Pinned WASI components for components.lock $lock_sha (source $COMMIT)"
  if [ "$rc" = 0 ]; then
    # COMPLETE THE RELEASE, NEVER REPLACE IT: only the assets that answered 404 are uploaded, and
    # `gh release upload` runs WITHOUT `--clobber` (which is gone from this file), so a published asset
    # cannot be overwritten even by a bug here.
    paths=""
    for asset in $missing; do
      paths="$paths $dir/$asset"
    done
    say "components: $tag holds $present of $owed assets; uploading only the missing:${missing}"
    gh release upload "$tag" -R "$REPO_SLUG" $paths \
      || fail "publish_failed: gh release upload $tag (the missing assets only - nothing already published is replaced)" 8
    say "components: $tag is at https://github.com/$REPO_SLUG/releases/tag/$tag (completed: added${missing}; no published asset was replaced)"
    return 0
  fi
  # NOTHING IS PUBLISHED UNDER THIS TAG: create it with the whole verified set. Never GitHub's latest, for
  # the same reason the node releases are not - a bundle keyed by a lock digest is an artifact row.
  paths=""
  for asset in $expected; do
    if command -v cygpath >/dev/null 2>&1; then paths="$paths $(cygpath -m "$dir/$asset")"; else paths="$paths $dir/$asset"; fi
  done
  gh release create "$tag" -R "$REPO_SLUG" --title "$tag" --notes "$notes" --latest=false $paths \
    || fail "publish_failed: gh release create $tag" 8
  say "components: $tag is at https://github.com/$REPO_SLUG/releases/tag/$tag (published)"
  return 0
}

# After a --publish run: the one sentence about whether a node can install this commit by download, asked of
# every URL the release and the lock name (scripts/check-release-complete.sh). A REPORT, not a gate: the
# publish already happened and the landing is what it is - the orchestrator records the row.
publish_report() { # needs ROOT, COMMIT
  local line
  line="$(bash "$ROOT/scripts/check-release-complete.sh" "$COMMIT" 2>&1 | tail -1)"
  say "installable-by-download: ${line:-unknown (the completeness check printed nothing)}"
  return 0
}
