#!/usr/bin/env bash
# A RELEASE NAMED FOR THIS COMMIT, CARRYING THE COVER'S BYTES (25/11, Fable decision A).
#
# WHY. scripts/release-install.sh - the one path a node with no tree and no toolchain has (nextcloud) -
# fetches exactly one tag: node-<sha12> of the commit it is asked to install. A cut whose compiled inputs
# are unchanged since a previous release was answered by --ensure with "covered: node-<other12> covers ..."
# and published NOTHING, so release-install.sh said
#   node_release_unavailable: no prebuilt ... at node-<sha12>
# and the node could not be installed at all. The bytes for that commit exist; only the NAME did not.
#
# WHAT THIS DOES. Given a commit and the cover that --ensure found, it writes a release directory named for
# THIS commit whose binaries are the cover's bytes, byte for byte:
#   * it refuses by name when the commit's compiled-inputs digest is not the cover's (different bytes are a
#     different release: this never renames a mismatched build);
#   * it refuses by name when any asset's sha256 or size is not the cover manifest's pin for it;
#   * it refuses by name when the cover's manifest or a pinned asset is missing;
#   * the manifest names source_commit=<this commit>, keeps the cover's compiled_inputs and built_utc (the
#     bytes WERE built then), and records named_from=<cover tag>;
#   * SHA256SUMS is written over the new names and SIGNED with wa_release_sign_sums - the publisher's own
#     signer and format (scripts/lib/release-signing.sh), so a node verifies it exactly like any node build;
#   * the gh line it prints (and runs with --publish) carries --latest=false: a node release is never the
#     repository's Latest (item 28). It creates a NEW release; it never deletes or replaces one.
#
#   bash scripts/publish-named-release.sh --commit <sha> --cover-tag node-<sha12> [--out DIR] [--publish]
#
# Prints `named release ok: <tag> from <cover> (<n> assets, signed)`; the caller is landing-queue.mjs.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT" || exit 2
. "$ROOT/scripts/lib/node-binaries.sh" || { echo "publish-named-release: no scripts/lib/node-binaries.sh" >&2; exit 2; }
. "$ROOT/scripts/lib/release-signing.sh" || { echo "publish-named-release: no scripts/lib/release-signing.sh" >&2; exit 2; }
say() { printf 'publish-named-release: %s\n' "$*"; }
refuse() { printf 'publish-named-release: %s\n' "$*" >&2; exit 2; }

COMMIT=""; COVER_TAG=""; OUT=""; PUBLISH=0; REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --commit) COMMIT="${2:-}"; shift 2 ;;
    --cover-tag) COVER_TAG="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --repo) REPO="${2:-}"; shift 2 ;;
    --publish) PUBLISH=1; shift ;;
    *) refuse "usage: --commit <sha> --cover-tag node-<sha12> [--out DIR] [--repo owner/repo] [--publish]" ;;
  esac
done
[ -n "$COMMIT" ] || refuse "commit_missing: --commit <sha> is required"
[ -n "$COVER_TAG" ] || refuse "cover_missing: --cover-tag node-<sha12> is required (the release --ensure found)"
TAG="$(wa_node_release_tag "$COMMIT")" || refuse "commit_invalid: $COMMIT is not a 40-hex commit id"
SHORT="$(wa_node_short_sha "$COMMIT")" || refuse "commit_invalid: $COMMIT"
case "$COVER_TAG" in
  node-[0-9a-f][0-9a-f]*) COVER_SHORT="${COVER_TAG#node-}" ;;
  *) refuse "cover_invalid: $COVER_TAG is not a node-<sha12> tag" ;;
esac
[ -n "$REPO" ] || REPO="$(wa_node_release_repo "$ROOT" 2>/dev/null)" || REPO=""
OUT="${OUT:-$ROOT/rust/target/named-release/$SHORT}"
COVER_DIR="$OUT/../cover-$COVER_SHORT"
mkdir -p "$OUT" "$COVER_DIR" || refuse "out_unwritable: $OUT"

# ---- 1. the cover's manifest, then the digest rule that makes a rename honest ------------------------
# The channel this tag is read from: the release itself, or the local stub a test (and a hand-copied
# release) serves - exactly the base wa_node_binary_download uses.
BASE="$(wa_node_tag_base "$COVER_TAG" 2>/dev/null)"
cover_manifest="$COVER_DIR/node-$COVER_SHORT.manifest"
wa_node_fetch_asset "$REPO" "$COVER_TAG" "node-$COVER_SHORT.manifest" "$COVER_DIR" "$BASE" >/dev/null 2>&1 || \
  refuse "cover_manifest_missing: $COVER_TAG publishes no node-$COVER_SHORT.manifest, so there are no bytes to carry"
cover_digest="$(wa_node_manifest_value "$cover_manifest" compiled_inputs)"
cover_commit="$(wa_node_manifest_value "$cover_manifest" source_commit)"
[ -n "$cover_digest" ] || refuse "cover_manifest_incomplete: $cover_manifest names no compiled_inputs"
DIGEST="$(wa_compiled_inputs_digest "$ROOT" "$COMMIT" 2>/dev/null)" || refuse "compiled_inputs_unavailable: cannot digest $COMMIT"
# THE COVER IS VERIFIED THE WAY A NODE VERIFIES IT, BEFORE A BYTE IS COPIED OR A NEW SIGNATURE IS MADE.
# Its SHA256SUMS must be signed by a key this node already trusts, and every asset must match THOSE SIGNED
# SUMS - a manifest that lies about a sha256 is not evidence of anything, and the manifest travels in the
# same release as the sums (scripts/lib/node-binaries.sh: the signature is the only half that cannot be
# swapped with the bytes). The verifier is the product's own: no second implementation lives here.
VERIFY_DIR="$COVER_DIR/verify"
mkdir -p "$VERIFY_DIR" || refuse "out_unwritable: $VERIFY_DIR"
_saved_url="${WA_NODE_BINARIES_URL:-}"
WA_NODE_BINARIES_URL="$BASE"
vout="$(wa_node_verify_signature "$REPO" "$COVER_TAG" "$VERIFY_DIR" 2>&1)"; vrc=$?
WA_NODE_BINARIES_URL="$_saved_url"
if [ "$vrc" != 0 ]; then
  case "$vout" in
    *release_unsigned*) refuse "cover_unsigned: $COVER_TAG publishes no signed SHA256SUMS, so nothing it carries can be trusted ($vout)" ;;
    *) refuse "cover_signature_invalid: $COVER_TAG's SHA256SUMS is not signed by a key this node trusts (verifier rc $vrc): $vout" ;;
  esac
fi
SIGNED_SUMS="$VERIFY_DIR/SHA256SUMS"
[ -s "$SIGNED_SUMS" ] || refuse "cover_signature_invalid: $COVER_TAG's verifier accepted no SHA256SUMS"

if [ "$DIGEST" != "$cover_digest" ]; then
  refuse "named_release_refused: $COMMIT has compiled inputs $DIGEST, but $COVER_TAG ($cover_commit) has $cover_digest - different bytes are a different release, never a rename of this one"
fi

# ---- 2. every pinned asset: fetch the cover's bytes and assert the manifest's own pin -----------------
triples=""
while read -r triple _rest; do
  case "$triple" in ""|"#"*|*=*) continue ;; esac
  triples="$triples $triple"
done < "$cover_manifest"
[ -n "$triples" ] || refuse "cover_manifest_incomplete: $cover_manifest pins no triple"

assets="node-$SHORT.manifest"
for triple in $triples; do
  pin="$(wa_node_manifest_pin "$cover_manifest" "$triple")" || refuse "cover_manifest_incomplete: no pin for $triple in $COVER_TAG"
  set -- $pin
  want_sha="$1"; want_bytes="$2"; want_ssha="$3"; want_sbytes="$4"
  for pair in "wa-$triple-$COVER_SHORT:wa-$triple-$SHORT:$want_sha:$want_bytes" \
              "wa-sentinel-$triple-$COVER_SHORT:wa-sentinel-$triple-$SHORT:$want_ssha:$want_sbytes"; do
    from="${pair%%:*}"; rest="${pair#*:}"; to="${rest%%:*}"; rest="${rest#*:}"
    sha="${rest%%:*}"; bytes="${rest##*:}"
    wa_node_fetch_asset "$REPO" "$COVER_TAG" "$from" "$COVER_DIR" "$BASE" >/dev/null 2>&1 || \
      refuse "cover_asset_missing: $COVER_TAG carries no $from"
    signed_sha="$(awk -v n="$from" '$2 == n {print $1}' "$SIGNED_SUMS" | head -1)"
    [ -n "$signed_sha" ] || refuse "cover_incomplete: $from is not in $COVER_TAG's signed SHA256SUMS, so it is not part of what was signed"
    got="$(wa_node_sha256 "$COVER_DIR/$from")" || refuse "cover_asset_unreadable: $COVER_DIR/$from"
    size="$(wc -c < "$COVER_DIR/$from" | tr -d '[:space:]')"
    [ "$got" = "$signed_sha" ] || \
      refuse "cover_asset_mismatch: $COVER_TAG's $from is sha256=$got but its SIGNED sums say $signed_sha"
    [ "$got" = "$sha" ] && [ "$size" = "$bytes" ] || \
      refuse "cover_asset_mismatch: $COVER_TAG's $from is sha256=$got bytes=$size, its manifest pins $sha/$bytes"
    cp -f "$COVER_DIR/$from" "$OUT/$to" || refuse "out_unwritable: $OUT/$to"
    assets="$assets $to"
  done
done

# ---- 3. the manifest names THIS commit, keeps the cover's identity and says where the bytes came from --
wa_node_manifest_value "$cover_manifest" built_utc >/dev/null 2>&1 || refuse "cover_manifest_incomplete: no built_utc"
{
  while IFS= read -r line; do
    case "$line" in
      source_commit=*) printf 'source_commit=%s\n' "$COMMIT" ;;
      named_from=*) ;;
      *) printf '%s\n' "$line" ;;
    esac
    case "$line" in
      source_commit=*) printf 'named_from=%s\n' "$COVER_TAG" ;;
    esac
  done < "$cover_manifest"
} > "$OUT/.node-$SHORT.manifest.$$" && mv -f "$OUT/.node-$SHORT.manifest.$$" "$OUT/node-$SHORT.manifest" || \
  refuse "manifest_unwritable: $OUT/node-$SHORT.manifest"
[ "$(wa_node_manifest_value "$OUT/node-$SHORT.manifest" source_commit)" = "$COMMIT" ] || \
  refuse "manifest_unwritable: the named manifest does not name $COMMIT"

# ---- 4. sums over the NEW names, the publisher's own signature, and the gh line -----------------------
( cd "$OUT" || exit 2
  for name in $assets; do wa_node_sha256 "$name" | sed "s|$|  $name|"; done > .SHA256SUMS.$$
) && mv -f "$OUT/.SHA256SUMS.$$" "$OUT/SHA256SUMS" || refuse "sums_unwritable: $OUT/SHA256SUMS"
wa_release_sign_sums "$OUT/SHA256SUMS" "$OUT/SHA256SUMS.sig" || \
  refuse "release_signing_unavailable: SHA256SUMS could not be signed, and an unsigned release is not published"
signed_key="$(sed -n 's/^key //p' "$OUT/SHA256SUMS.sig" | head -1)"

say "named release: $TAG carries the bytes of $COVER_TAG (compiled inputs $DIGEST, cover commit $cover_commit)"
say "bundle: $OUT ($(printf '%s' "$assets" | wc -w | tr -d '[:space:]') assets, signed with key $signed_key)"
if [ -n "$REPO" ]; then
  say "run: gh release create $TAG --latest=false --title '$TAG' --notes 'node build named for $COMMIT; bytes are $COVER_TAG (compiled inputs $DIGEST)' $(printf '%s ' $assets) SHA256SUMS SHA256SUMS.sig"
else
  say "warning: no owner/repo known (set WA_NODE_RELEASE_REPO), so only the bundle was written"
fi
if [ "$PUBLISH" = 1 ] && [ -n "$REPO" ]; then
  command -v gh >/dev/null 2>&1 || refuse "publish_unavailable: --publish needs gh"
  ( cd "$OUT" && gh release create "$TAG" --latest=false --title "$TAG" \
      --notes "node build named for $COMMIT; bytes are $COVER_TAG (compiled inputs $DIGEST)" \
      $assets SHA256SUMS SHA256SUMS.sig ) || refuse "publish_failed: gh release create $TAG"
  say "published $TAG (a NEW release; nothing was replaced or deleted)"
fi
say "named release ok: $TAG from $COVER_TAG ($(printf '%s' "$assets" | wc -w | tr -d '[:space:]') assets, signed)"
