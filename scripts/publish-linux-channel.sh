#!/usr/bin/env bash
# Publish the PUBLIC Linux bundle channel for one commit: build the bundles, sign them, upload them, and write
# the index entry `scripts/install.sh` -> `scripts/linux/bootstrap.sh` install from.
#
# WHY (Fable, 22/11). The public installer reads `releases/index-linux.json`, and `wa release cut` published
# only `node-<sha12>` releases. Measured 22/11: six node releases cut that day, the channel's newest x86_64
# entry 23 days old (`v0.1.0-alpha.13` at `d80d86bd`, 30/10), and the fresh-install proof died with
# `core_lib_unreachable` (404 on `scripts/lib/release-signing.sh` at that commit). A machine with no node
# installs from the INDEX; an existing node updates from a `node-<sha12>` release. Two channels, and only one
# of them was being published.
#
# THE TAG: `wa-linux-<sha12>`, one release per commit - the shape the Android channel already uses
# (`wa-android-<sha12>`, scripts/release-android.sh). Deliberately NOT the `node-<sha12>` release: that one's
# SHA256SUMS + SHA256SUMS.sig are the node binaries' own trust root (scripts/publish-node-binaries.sh), and a
# second SHA256SUMS uploaded into it would silently re-point every node's verification at other bytes.
#
# TRUST, unchanged and checked in this order: the index entry pins sha256(bundle.manifest) and the archive's
# size; the manifest pins sha256(files.sha256); files.sha256 pins every member; the release's signed
# SHA256SUMS names the archive. `scripts/linux/bootstrap.sh` verifies all of it before it installs anything,
# and this script proves the same chain over the bytes it is about to upload - including the signature, which
# is made by wa-vault's `release-signing` key and verified here against the keys this tree trusts.
#
# WHAT IT DOES NOT DO: commit or push `releases/index-linux.json`. The index is the trust root and it is a
# commit on `main`; the caller that owns a checkout and a credential (`wa release cut`'s linux step) commits
# exactly that one path and reads it back. A script that also pushed main would be a second, unreviewed way to
# move the source of truth.
#
# Usage: bash scripts/publish-linux-channel.sh [--commit SHA] [--tree DIR] [--tag TAG]
#                                             [--targets "T T"] [--out DIR] [--index FILE]
#                                             [--reason TEXT] [--check] [--no-publish]
#   --commit SHA     the source commit (default HEAD; must be the checked-out HEAD, on origin/main unless the
#                    tree is a fixture - release-linux.sh enforces that per target)
#   --tree DIR       the checkout to build from (default: this script's repository)
#   --tag TAG        the release tag (default wa-linux-<sha12>)
#   --targets "T"    the triples to publish (default: x86_64-unknown-linux-musl aarch64-unknown-linux-musl)
#   --out DIR        the build/channel directory (default <tree>/build/linux-channel)
#   --index FILE     the index to write (default <tree>/releases/index-linux.json)
#   --reason TEXT    recorded in the release notes
#   --check          print what would be built and published; build nothing, upload nothing
#   --no-publish     build and sign the bundles, then stop: no gh, no index write, no upload (a proof run)
#
# Exit codes: 0 published (or built, with --no-publish); 1 a named refusal, printed as `linux-channel: <name>`.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
REPO="Magaav/wasm-agent"
commit=; tree="$ROOT"; tag=; targets=; out=; index=; reason=; check=0; publish=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --commit)  [ "$#" -ge 2 ] || { echo 'linux-channel: commit_value_required' >&2; exit 1; }; commit=$2; shift 2 ;;
    --tree)    [ "$#" -ge 2 ] || { echo 'linux-channel: tree_value_required' >&2; exit 1; }; tree=$2; shift 2 ;;
    --tag)     [ "$#" -ge 2 ] || { echo 'linux-channel: tag_value_required' >&2; exit 1; }; tag=$2; shift 2 ;;
    --targets) [ "$#" -ge 2 ] || { echo 'linux-channel: targets_value_required' >&2; exit 1; }; targets=$2; shift 2 ;;
    --out)     [ "$#" -ge 2 ] || { echo 'linux-channel: out_value_required' >&2; exit 1; }; out=$2; shift 2 ;;
    --index)   [ "$#" -ge 2 ] || { echo 'linux-channel: index_value_required' >&2; exit 1; }; index=$2; shift 2 ;;
    --reason)  [ "$#" -ge 2 ] || { echo 'linux-channel: reason_value_required' >&2; exit 1; }; reason=$2; shift 2 ;;
    --check)   check=1; shift ;;
    --no-publish) publish=0; shift ;;
    -h|--help) sed -n '2,41p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "linux-channel: unknown_option: $1" >&2; exit 1 ;;
  esac
done

say()  { printf 'linux-channel: %s\n' "$*" >&2; }
fail() { printf 'linux-channel: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s 2>/dev/null || echo unknown)" = Linux ] || fail "not_linux: $(uname -s 2>/dev/null || echo unknown); the bundle is built on Linux (scripts/release-linux.sh)"
command -v git >/dev/null 2>&1 || fail 'git_missing: this script reads the commit it publishes with git'
command -v sha256sum >/dev/null 2>&1 || fail 'sha256sum_missing: the trust chain is sha256 over the bytes uploaded'
[ -d "$tree/.git" ] || [ -f "$tree/.git" ] || fail "tree_not_a_checkout: $tree"

head_sha=$(git -C "$tree" rev-parse HEAD 2>/dev/null) || fail "tree_not_a_checkout: git rev-parse HEAD failed in $tree"
commit=${commit:-$head_sha}
commit=$(git -C "$tree" rev-parse --verify -q "$commit^{commit}") || fail "commit_unknown: $commit is not a commit of $tree"
[ "$commit" = "$head_sha" ] || fail "commit_not_checked_out: build the channel from a checkout of $commit (HEAD is $head_sha)"
[ -z "$(git -C "$tree" status --porcelain --untracked-files=no)" ] || fail 'source_dirty: commit before publishing a channel entry: the entry is the trust root for the bytes this tree would build'
short=$(printf '%.12s' "$commit")

tag=${tag:-wa-linux-$short}
case "$tag" in
  wa-linux-*) ;;
  v[0-9]*) ;;
  *) fail "tag_invalid: '$tag' (a channel release is wa-linux-<sha12>, or a v<semver> tag)" ;;
esac

# AN ALLOW-LIST, not a rejection list: the two static triples this channel publishes, because a bundle that is
# not static musl needs a libc floor on the installing machine - the 30/10 defect that made the first published
# bundle refuse on an older Ubuntu.
targets=${targets:-"x86_64-unknown-linux-musl aarch64-unknown-linux-musl"}
for triple in $targets; do
  case "$triple" in
    x86_64-unknown-linux-musl|aarch64-unknown-linux-musl) ;;
    *) fail "target_unsupported: $triple (this channel publishes x86_64-unknown-linux-musl and aarch64-unknown-linux-musl)" ;;
  esac
done

out=${out:-$tree/build/linux-channel}
index=${index:-$tree/releases/index-linux.json}
[ -f "$index" ] || fail "index_missing: $index (the channel's trust root must exist before a release is published into it)"
[ -f "$tree/scripts/release-linux.sh" ] || fail "builder_missing: $tree/scripts/release-linux.sh"
[ -f "$tree/scripts/sign-release.sh" ] || fail "signer_missing: $tree/scripts/sign-release.sh (the release-signing key lives in wa-vault)"
[ -f "$tree/scripts/lib/release-signing.sh" ] || fail "release_signing_lib_missing: $tree/scripts/lib/release-signing.sh (the verifier is what makes the signature worth anything; without it this script cannot tell a signed set from an unsigned one)"

assets=
for triple in $targets; do
  case "$triple" in x86_64-*) arch=x64 ;; *) arch=arm64 ;; esac
  name="wa-linux-$arch-musl-$short"
  assets="$assets $name.tar.gz"
done
assets=${assets# }

# THE CREDENTIAL IS ASKED FOR BEFORE THE BUILD, not after it: a cut that spent the bundle build and then found
# gh signed out is the 19/11 defect (gh installed, its token unreadable in a unit) paid for twice.
if [ "$publish" = 1 ]; then
  command -v gh >/dev/null 2>&1 || fail 'gh_missing: install the GitHub CLI (gh auth status must answer for the account that owns the release)'
  gh auth status >/dev/null 2>&1 || fail 'publish_needs_credentials: gh here is missing or signed out (gh reads its token from the desktop keyring; a systemd user unit has no session bus to unlock it), so nothing was built and nothing was uploaded; run the cut from a desktop shell, or build with --no-publish and upload by hand'
fi

if [ "$check" = 1 ]; then
  say "would build   $commit ($targets) with scripts/release-linux.sh, one bundle per target"
  say "would sign    SHA256SUMS over $assets with scripts/sign-release.sh (wa-vault's release-signing key)"
  if [ "$publish" = 1 ]; then
    say "would publish $REPO release $tag (pre-release when created) with $assets SHA256SUMS SHA256SUMS.sig"
    say "would write   one entry per target into $index (not committed here)"
  else
    say 'would stop after signing (--no-publish: no gh, no index write)'
  fi
  exit 0
fi

mkdir -p "$out" || fail "out_unwritable: $out"
out=$(CDPATH= cd -- "$out" && pwd) || fail "out_unwritable: $out (cannot resolve it to an absolute path)"
paths=
for asset in $assets; do paths="$paths $out/$asset"; done
paths=${paths# }
rows=
installer_sha=
for triple in $targets; do
  case "$triple" in x86_64-*) arch=x64 ;; *) arch=arm64 ;; esac
  name="wa-linux-$arch-musl-$short"
  asset="$name.tar.gz"
  log="$out/build-$arch.log"
  say "building $triple -> $asset"
  if ! bash "$tree/scripts/release-linux.sh" --commit "$commit" --out "$out" --target "$triple" > "$log" 2>&1; then
    tail -20 "$log" >&2
    fail "build_failed: scripts/release-linux.sh --target $triple (log $log)"
  fi
  stage="$out/$name"
  [ -f "$stage/bundle.manifest" ] || fail "bundle_incomplete: $stage/bundle.manifest is missing after the build (log $log)"
  [ -f "$out/$asset" ] || fail "bundle_incomplete: $out/$asset is missing after the build (log $log)"
  mval() { sed -n "s/^$1=//p" "$stage/bundle.manifest" | head -1; }
  [ "$(mval source_commit)" = "$commit" ] || fail "commit_mismatch: the bundle records $(mval source_commit), not $commit"
  [ "$(mval target_triple)" = "$triple" ] || fail "target_mismatch: the bundle records $(mval target_triple), not $triple"
  [ "$(mval local_only)" = 0 ] || fail "local_bundle: the bundle was built with --local (a test artefact) and is not publishable"
  manifest_sha=$(sha256sum "$stage/bundle.manifest" | cut -d' ' -f1)
  size=$(wc -c < "$out/$asset" | tr -d ' ')
  [ -n "$manifest_sha" ] && [ -n "$size" ] || fail "bundle_unmeasurable: $out/$asset"
  if [ -f "$stage/scripts/linux/bootstrap.sh" ]; then
    installer_sha=$(sha256sum "$stage/scripts/linux/bootstrap.sh" | cut -d' ' -f1)
  fi
  rows="$rows$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$triple" "$(mval arch)" "$manifest_sha" "$asset" "$size" "$(mval node_version)" "$(mval built_utc)")"
  rows="$rows"$'\n'
  say "bundle  $out/$asset ($size bytes, manifest sha256 $manifest_sha)"
done

# ---- one SHA256SUMS over the archives, signed, and verified HERE --------------------------------------------
sums="$out/SHA256SUMS"
sums_new="$out/.SHA256SUMS.$$"
: > "$sums_new" || fail "sums_unwritable: $sums_new"
# A release can be revisited (a second target later, a rerun after a stop): the rows already published stay, and
# only the rows for the archives about to be uploaded are replaced. The same rule as scripts/release-linux.sh.
if [ "$publish" = 1 ] && command -v gh >/dev/null 2>&1 && gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then
  mkdir -p "$out/sums-prev"
  gh release download "$tag" --repo "$REPO" --pattern SHA256SUMS --dir "$out/sums-prev" >/dev/null 2>&1 || true
  if [ -s "$out/sums-prev/SHA256SUMS" ]; then
    grep -v -F -f <(for asset in $assets; do printf ' %s\n' "$asset"; done) "$out/sums-prev/SHA256SUMS" >> "$sums_new" 2>/dev/null || true
  fi
  rm -rf "$out/sums-prev"
fi
for asset in $assets; do
  ( cd "$out" && sha256sum "$asset" ) >> "$sums_new" || { rm -f "$sums_new"; fail "checksums_failed: sha256sum $asset"; }
done
LC_ALL=C sort -k2 "$sums_new" > "$sums" && rm -f "$sums_new" || fail 'checksums_failed: could not write SHA256SUMS'
say "checksums $sums ($(wc -l < "$sums" | tr -d ' ') asset(s))"

( cd "$tree" && bash scripts/sign-release.sh "$sums" "$sums.sig" ) \
  || fail 'release_not_signed: the sums were not signed by wa-vault, so no channel entry may name these bytes (WA_VAULT_ADMIN_URL/WA_VAULT_ADMIN_TOKEN where the vault reads them)'
say "signature $sums.sig ($(sed -n 's/^key //p' "$sums.sig"))"
( cd "$tree" && . scripts/lib/release-signing.sh && wa_release_verify_sums "$out" ) \
  || fail "release_key_not_trusted: the signature beside $sums does not verify against the keys $tree (and this node) trust; a machine installing from this entry would refuse it"

if [ "$publish" = 0 ]; then
  say "built and signed, not published (--no-publish): $out"
  say "channel  $targets"
  exit 0
fi

# ---- upload beside the node release, then READ IT BACK -----------------------------------------------------
command -v gh >/dev/null 2>&1 || fail 'gh_missing: install the GitHub CLI (asked before the build; gh disappeared since)'
notes="Linux prebuilt node bundle(s) for the public installer channel, source commit $commit.
Install a node on a fresh Linux machine - one command, no checkout and no toolchain:
  curl -fsSL https://raw.githubusercontent.com/$REPO/main/scripts/install.sh | sh
The same command updates it. Verification: the signed SHA256SUMS beside these assets, and inside the bundle
bundle.manifest -> files.sha256 -> every member, which the installer checks before it installs anything.
reason: ${reason:-none stated}"
if gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  gh release upload "$tag" $paths "$sums" "$sums.sig" --repo "$REPO" --clobber || fail "publish_failed: gh release upload $tag"
else
  # shellcheck disable=SC2086
  gh release create "$tag" $paths "$sums" "$sums.sig" --repo "$REPO" --target "$commit" --title "$tag" --notes "$notes" --prerelease \
    || fail "publish_failed: gh release create $tag"
fi
# THE EFFECT, NOT THE COMMAND: ask the release what it carries and hold it to the bytes measured here.
listing=$(gh release view "$tag" --repo "$REPO" --json assets 2>/dev/null) || fail "publish_not_readback: gh release view $tag answered nothing after the upload"
for asset in $assets; do
  size=$(printf '%s\n' "$rows" | awk -F'\t' -v a="$asset" '$4 == a { print $5; exit }')
  case "$listing" in
    *"\"name\":\"$asset\""*) ;;
    *) fail "publish_not_readback: $tag does not list $asset after the upload: $(printf '%s' "$listing" | head -c 300)" ;;
  esac
  case "$listing" in
    *"\"size\":$size"*) ;;
    *) say "note: $asset is on $tag but its listed size did not match $size (gh reports the asset size; check it by hand)" ;;
  esac
done
say "published https://github.com/$REPO/releases/download/$tag"

# ---- the index entry: one write for the whole cut ----------------------------------------------------------
index_file=$index
command -v node >/dev/null 2>&1 || fail 'node_missing: the index is written with node (as scripts/release-linux.sh does, so the Windows tree can write it too)'
node - "$index_file" "$commit" "$short" "$tag" "$REPO" "${installer_sha:-}" "$rows" <<'JS' || fail "index_update_failed: $index_file"
const fs = require('fs');
const [file, commit, short, tag, repo, installer, rows] = process.argv.slice(2);
const doc = JSON.parse(fs.readFileSync(file, 'utf8'));
if (doc.schema !== 'wasm-agent-linux-release-index' || doc.schema_version !== 1) {
  console.error('linux-channel: index_invalid: ' + file + ' is not schema wasm-agent-linux-release-index v1');
  process.exit(1);
}
const entries = [];
for (const line of String(rows).split('\n')) {
  if (!line.trim()) continue;
  const [target, arch, manifest, asset, size, nodeVersion, built] = line.split('\t');
  const entry = { tag, commit, commit_short: short, target, arch, manifest_sha256: manifest,
    url: 'https://github.com/' + repo + '/releases/download/' + tag + '/' + asset,
    size: Number(size), node_version: nodeVersion, built_utc: built };
  if (installer) entry.installer_sha256 = installer;
  entries.push(entry);
}
if (entries.length === 0) { console.error('linux-channel: index_update_empty: no entry to write'); process.exit(1); }
const kept = (doc.releases || []).filter((r) => !entries.some((e) => e.commit === r.commit && e.target === r.target));
doc.releases = [...entries, ...kept];
doc.generated_utc = entries[entries.length - 1].built_utc;
fs.writeFileSync(file, JSON.stringify(doc, null, 2) + '\n');
console.log('linux-channel: index ' + file + ' (' + doc.releases.length + ' entries)');
JS

# ---- the channel has to be as new as the release it was cut with -------------------------------------------
fresh_out=$(bash "$tree/scripts/check-linux-channel-fresh.sh" --index "$index_file" --repo "$tree" 2>&1)
fresh_rc=$?
say "$(printf '%s' "$fresh_out" | head -1)"
case "$fresh_rc" in
  0) ;;
  1) fail "index_stale: $(printf '%s' "$fresh_out" | head -1)" ;;
  *) fail "index_freshness_unknown: the channel could not be judged: $(printf '%s' "$fresh_out" | head -1)" ;;
esac
say "tag      $tag"
say "index    $index_file (not committed here: the index is the trust root and a commit on main)"
say 'done'
