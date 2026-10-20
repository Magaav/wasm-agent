#!/usr/bin/env bash
# Publish a prebuilt Android arm64 release and record it in `releases/index.json`.
#
# WHY. The phone cannot compile this workspace (measured rustc SIGSEGV on cranelift), so the
# release, not a build, is its update channel: `wa update` fetches an entry from the committed
# index, verifies `sha256(bundle.manifest)` against it, and installs through the same verified
# installer every other path uses. This script produces that asset and that entry.
#
# TRUST. The index is committed to protected `main` and is the trust root: a downloaded asset
# is refused unless its `bundle.manifest` hash equals what the index recorded. This script
# therefore does NOT commit anything - it writes the index and prints the exact commands, so
# the entry is reviewed like any other commit. Publishing bytes without a reviewed entry is
# useless by design: nothing installs from an asset the index does not name.
#
# Usage: bash scripts/release-android.sh [--commit SHA] [--ndk DIR] [--out DIR] [--check]
#                                        [--reason TEXT] [--no-publish]
#   --commit SHA   source commit to publish (default: HEAD; must be on origin/main)
#   --ndk DIR      Android NDK root (passed through to cross-build-android.sh)
#   --out DIR      build directory (default: build/android-release)
#   --check        print what would be built/published and exit; builds nothing
#   --no-publish   build and write the index entry, but do not create the GitHub release
#   --reason TEXT  recorded in the release notes
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
INDEX="$ROOT/releases/index.json"
REPO="Magaav/wasm-agent"
commit=; ndk=; out="$ROOT/build/android-release"; check=0; publish=1; reason=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --commit) [ "$#" -ge 2 ] || { echo 'release: commit_value_required' >&2; exit 1; }; commit=$2; shift 2 ;;
    --ndk)    [ "$#" -ge 2 ] || { echo 'release: ndk_value_required' >&2; exit 1; }; ndk=$2; shift 2 ;;
    --out)    [ "$#" -ge 2 ] || { echo 'release: out_value_required' >&2; exit 1; }; out=$2; shift 2 ;;
    --reason) [ "$#" -ge 2 ] || { echo 'release: reason_value_required' >&2; exit 1; }; reason=$2; shift 2 ;;
    --check)  check=1; shift ;;
    --no-publish) publish=0; shift ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "release: unknown_option: $1" >&2; exit 1 ;;
  esac
done

say() { printf 'release: %s\n' "$*"; }
fail() { printf 'release: %s\n' "$*" >&2; exit 1; }

git -C "$ROOT" fetch -q origin
commit=${commit:-$(git -C "$ROOT" rev-parse HEAD)}
[ "${#commit}" -eq 40 ] || fail "commit_invalid: '$commit' is not a 40-character sha"
git -C "$ROOT" merge-base --is-ancestor "$commit" origin/main ||
  fail "not_on_main: $commit is not on origin/main; releases are cut from main only"
[ -z "$(git -C "$ROOT" status --porcelain)" ] || fail 'source_dirty: commit or stash before cutting a release'
[ -f "$INDEX" ] || fail "index_missing: $INDEX (the trust root must exist before a release)"
short=$(printf '%.12s' "$commit")
tag="wa-android-$short"
asset="wa-android-bundle-$short.tar.gz"

if [ "$check" = 1 ]; then
  say "would build   $commit ($short)"
  say "would create  tag $tag, asset $asset"
  say "would publish $REPO release (gh) and write one entry into releases/index.json (not committed)"
  say "ndk: ${ndk:-<auto: WA_ANDROID_NDK, ANDROID_NDK_HOME, ANDROID_NDK_ROOT, ANDROID_HOME/ndk/*, ~/android-ndk-r27d>}"
  exit 0
fi

rm -rf -- "$out"
mkdir -p -- "$out"
say "building $short with the Android NDK"
build_args=(--out "$out")
[ -n "$ndk" ] && build_args+=(--ndk "$ndk")
bash "$ROOT/scripts/termux/cross-build-android.sh" "${build_args[@]}" ||
  fail 'build_failed: cross-build-android.sh did not produce a bundle'

manifest="$out/bundle/bundle.manifest"
archive="$out/wa-android-bundle.tar.gz"
[ -f "$manifest" ] || fail "bundle_incomplete: $manifest is missing"
[ -f "$archive" ] || fail "archive_missing: $archive (the bundle builder must archive)"
built_commit=$(sed -n 's/^source_commit=//p' "$manifest" | head -n 1)
[ "$built_commit" = "$commit" ] ||
  fail "release_commit_mismatch: the bundle records '$built_commit', not '$commit'"
manifest_sha=$(sha256sum "$manifest" | cut -d' ' -f1)
size=$(wc -c < "$archive" | tr -d ' ')
ndk_version=$(sed -n 's/^ndk_version=//p' "$manifest" | head -n 1)
rustc_version=$(sed -n 's/^rustc_version=//p' "$manifest" | head -n 1)
target=$(sed -n 's/^target_triple=//p' "$manifest" | head -n 1)
say "manifest sha256 $manifest_sha"
say "archive $asset ($size bytes), target ${target:-?}, NDK ${ndk_version:-?}"

url="https://github.com/$REPO/releases/download/$tag/$asset"
if [ "$publish" = 1 ]; then
  command -v gh >/dev/null || fail 'gh_missing: install the GitHub CLI to publish (or pass --no-publish)'
  notes="Android arm64 release for $commit.
target: ${target:-aarch64-linux-android}
ndk: ${ndk_version:-unknown}
rustc: ${rustc_version:-unknown}
bundle.manifest sha256: $manifest_sha
reason: ${reason:-none stated}"
  gh release create "$tag" "$archive" --repo "$REPO" --title "$tag" --notes "$notes" ||
    fail 'publish_failed: gh release create did not succeed'
  say "published $url"
else
  say "not published (--no-publish); asset left at $archive"
fi

python - "$INDEX" "$commit" "$short" "$manifest_sha" "$url" "$size" "${target:-aarch64-linux-android}" "${ndk_version:-}" "${rustc_version:-}" <<'PY' || fail 'index_update_failed'
import json,sys,datetime
path,commit,short,sha,url,size,target,ndk,rustc=sys.argv[1:10]
doc=json.load(open(path))
entry={"commit":commit,"commit_short":short,"manifest_sha256":sha,"url":url,"size":int(size),
       "target":target,"ndk":ndk,"rustc":rustc,
       "built_utc":datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}
doc["releases"]=[entry]+[r for r in doc.get("releases",[]) if r.get("commit")!=commit]
doc["generated_utc"]=entry["built_utc"]
json.dump(doc,open(path,"w"),indent=2)
open(path,"a").write("\n")
print("index updated: %s entries" % len(doc["releases"]))
PY

say 'this script does NOT commit the index; the entry is the trust root and is reviewed like code:'
say "  git add releases/index.json && git commit -m 'releases: $tag' && git push origin main"
say "then the phone runs: wa update --check, then wa update"
