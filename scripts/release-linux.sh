#!/usr/bin/env bash
# Build a prebuilt Linux (glibc) release bundle of the node and, with --publish, record it in
# `releases/index-linux.json` - the channel `scripts/linux/bootstrap.sh` installs from.
#
# WHY. A fresh Linux machine should become a node in one command without a Rust toolchain, the
# code-mode asset fetch and a cold release build (minutes to tens of minutes on a 2-core arm64
# instance). The bundle is what the sandbox image ships in /opt/wasm-agent: `wa`, `wa-sentinel`,
# `ui/` and the MCP runtime scripts (lua/core/mcp.lua M.RUNTIME) - built here, natively, on a host of
# the bundle's architecture, with the same shipping build a deploy uses (scripts/codemode-build.mjs,
# so code mode is embedded and proven on these bytes).
#
# TRUST. Same chain as the Android channel (docs/release/RELEASE_INDEX.md): the committed index pins
# sha256(bundle.manifest); the manifest pins sha256(files.sha256); files.sha256 pins every member.
# This script does NOT commit the index - the entry is the trust root and is reviewed like code.
# Its own index is a sibling of releases/index.json on purpose: the phone's reader selects entries
# without a target filter, and a glibc bundle must never be offered to it.
#
# Usage: bash scripts/release-linux.sh [--commit SHA] [--out DIR] [--publish TAG] [--reason TEXT]
#                                      [--local] [--check]
#   --commit SHA   source commit (default HEAD; must be the checked-out, clean HEAD, on origin/main)
#   --out DIR      build directory (default: <repo>/build/linux-release, not versioned)
#   --publish TAG  upload the archive as an asset of GitHub release TAG (created as a pre-release when
#                  absent) and write its entry into releases/index-linux.json (not committed)
#   --reason TEXT  recorded in the release notes
#   --local        a test bundle from any clean commit (not required on main); refuses --publish
#   --check        print what would be built and published; build nothing
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
INDEX="$ROOT/releases/index-linux.json"
REPO="Magaav/wasm-agent"
commit=; out="$ROOT/build/linux-release"; tag=; reason=; local_only=0; check=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --commit)  [ "$#" -ge 2 ] || { echo 'release-linux: commit_value_required' >&2; exit 1; }; commit=$2; shift 2 ;;
    --out)     [ "$#" -ge 2 ] || { echo 'release-linux: out_value_required' >&2; exit 1; }; out=$2; shift 2 ;;
    --publish) [ "$#" -ge 2 ] || { echo 'release-linux: publish_tag_required' >&2; exit 1; }; tag=$2; shift 2 ;;
    --reason)  [ "$#" -ge 2 ] || { echo 'release-linux: reason_value_required' >&2; exit 1; }; reason=$2; shift 2 ;;
    --local)   local_only=1; shift ;;
    --check)   check=1; shift ;;
    -h|--help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "release-linux: unknown_option: $1" >&2; exit 1 ;;
  esac
done

say()  { printf 'release-linux: %s\n' "$*"; }
fail() { printf 'release-linux: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Linux ] || fail "not_linux: $(uname -s); the bundle is built natively on a Linux host of its architecture"
case "$(uname -m)" in
  aarch64|arm64) arch=arm64; triple=aarch64-unknown-linux-gnu ;;
  x86_64|amd64)  arch=x64;   triple=x86_64-unknown-linux-gnu ;;
  *) fail "arch_unsupported: $(uname -m)" ;;
esac
[ "$local_only" = 1 ] && [ -n "$tag" ] && fail 'local_not_publishable: a --local bundle is a test artefact; drop --local to publish'
case "$tag" in ''|v[0-9]*) ;; *) fail "tag_invalid: '$tag' (a release tag is v<semver>, e.g. v0.1.0-alpha.12)" ;; esac

head_sha=$(git -C "$ROOT" rev-parse HEAD)
commit=${commit:-$head_sha}
commit=$(git -C "$ROOT" rev-parse --verify -q "$commit^{commit}") || fail "commit_unknown: $commit"
[ "$commit" = "$head_sha" ] || fail "commit_not_checked_out: build from a checkout of $commit (HEAD is $head_sha)"
[ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ] || fail 'source_dirty: commit or stash before cutting a release'
if [ "$local_only" = 0 ]; then
  git -C "$ROOT" fetch -q origin 2>/dev/null || say 'fetch of origin failed; checking against the origin/main this clone has'
  git -C "$ROOT" merge-base --is-ancestor "$commit" origin/main \
    || fail "not_on_main: $commit is not on origin/main; releases are cut from main only (--local for a test bundle)"
fi
short=$(printf '%.12s' "$commit")
name="wa-linux-$arch-$short"
asset="$name.tar.gz"
node_version=$(sed -n 's/^NODE_VERSION="\([0-9.]*\)"/\1/p' "$ROOT/scripts/install.sh" | head -n 1)
[ -n "$node_version" ] || fail 'node_pin_missing: scripts/install.sh has no NODE_VERSION'

if [ "$check" = 1 ]; then
  say "would build   $commit ($triple) natively"
  say "would write   $out/$asset (bundle $name/: wa, wa-sentinel, ui/, scripts/ MCP runtime, bundle.manifest, files.sha256)"
  [ -n "$tag" ] && say "would publish asset to $REPO release $tag (pre-release when created) and add an entry to releases/index-linux.json (not committed)"
  exit 0
fi

# ---- build: the deploy's own shipping build, on this tree --------------------------------------
. "$ROOT/scripts/lib/build-requirements.sh"
wa_build_env
if ! check_out=$(wa_build_check "$ROOT"); then
  missing=$(printf '%s\n' "$check_out" | awk '$1 == "missing" { print $2 }')
  for id in $missing; do
    case "$id" in
      assets) say 'provisioning the pinned code-mode assets'; wa_build_provision "$ROOT" assets || fail 'codemode_assets_unprovisioned' ;;
      *) fail "requirement_missing: $(printf '%s\n' "$check_out" | grep "^missing $id" | head -1)" ;;
    esac
  done
fi
for manifest in rust/Cargo.toml rust/wa-sentinel/Cargo.toml; do
  ( cd "$ROOT" && cargo fetch --locked --manifest-path "$manifest" >/dev/null 2>&1 ) \
    || say "cargo fetch for $manifest did not complete; the offline build uses the cache"
done
mkdir -p "$out"
say "building wa ($triple) - native code-mode shipping build"
node "$ROOT/scripts/codemode-build.mjs" build "$ROOT" > "$out/wa-host.receipt.json" 2> "$out/wa-host.log" \
  || { tail -25 "$out/wa-host.log" >&2; fail 'build_failed: wa (codemode-build.mjs)'; }
say 'building wa-sentinel'
( cd "$ROOT/rust" && cargo build --release --offline --locked --manifest-path wa-sentinel/Cargo.toml ) 2> "$out/wa-sentinel.log" \
  || { tail -25 "$out/wa-sentinel.log" >&2; fail 'build_failed: wa-sentinel'; }
wa_bin="$ROOT/rust/target/release/wa"
sentinel_bin="$ROOT/rust/wa-sentinel/target/release/wa-sentinel"
[ -x "$sentinel_bin" ] || sentinel_bin="$ROOT/rust/target/release/wa-sentinel"
[ -x "$wa_bin" ] || fail "no built binary at $wa_bin"
[ -x "$sentinel_bin" ] || fail 'no built wa-sentinel'

# ---- stage: exactly the shipped closure ---------------------------------------------------------
stage="$out/$name"
rm -rf -- "$stage" "$out/$asset"
mkdir -p "$stage/ui" "$stage/scripts"
install -m755 "$wa_bin" "$stage/wa"
install -m755 "$sentinel_bin" "$stage/wa-sentinel"
cp -r "$ROOT/ui/." "$stage/ui/"
# The MCP runtime the node spawns with Node: the list the node itself checks (lua/core/mcp.lua M.RUNTIME).
runtime=$(sed -n "/^M.RUNTIME={/,/}/p" "$ROOT/lua/core/mcp.lua" | grep -o "'[^']*\.mjs'" | tr -d "'")
[ -n "$runtime" ] || fail 'runtime_list_unreadable: lua/core/mcp.lua M.RUNTIME'
for file in $runtime; do
  [ -f "$ROOT/scripts/$file" ] || fail "runtime_file_missing: scripts/$file"
  install -m644 "$ROOT/scripts/$file" "$stage/scripts/$file"
done
# Nothing that could carry a secret or a machine's state belongs in a public bundle.
if find "$stage" \( -name 'env' -o -name '*.env' -o -name '*.db' -o -name '*.db-*' -o -name '*.key' -o -name '*.pem' \
     -o -name 'node.key' -o -name '.git' \) | grep -q .; then
  fail 'bundle_contains_state: env/db/key files in the staged bundle; refusing'
fi
"$stage/wa" --version >/dev/null 2>&1 || fail 'candidate_does_not_run: the built wa did not answer --version'

( cd "$stage" && find . -type f ! -name bundle.manifest ! -name files.sha256 -printf '%P\n' | LC_ALL=C sort \
    | while IFS= read -r f; do sha256sum -- "$f"; done ) > "$stage/files.sha256"
built_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
  echo 'schema=wa-linux-bundle/1'
  echo "source_commit=$commit"
  echo "source_tree=$(git -C "$ROOT" rev-parse "$commit^{tree}")"
  echo "target_triple=$triple"
  echo "arch=$arch"
  echo "rustc_version=$(rustc --version 2>/dev/null | sed 's/^rustc //')"
  echo "glibc=$(ldd --version 2>/dev/null | head -1 | awk '{print $NF}')"
  echo "node_version=$node_version"
  echo "wa_version=$("$stage/wa" --version 2>/dev/null | head -1)"
  echo "release_tag=$tag"
  echo "local_only=$local_only"
  echo "built_utc=$built_utc"
  echo "files_sha256=$(sha256sum "$stage/files.sha256" | cut -d' ' -f1)"
} > "$stage/bundle.manifest"
tar -C "$out" -czf "$out/$asset" "$name"
manifest_sha=$(sha256sum "$stage/bundle.manifest" | cut -d' ' -f1)
size=$(wc -c < "$out/$asset" | tr -d ' ')
say "bundle  $out/$asset ($size bytes)"
say "manifest sha256 $manifest_sha"

[ -n "$tag" ] || { say 'not published (no --publish TAG)'; exit 0; }

# ---- publish ------------------------------------------------------------------------------------
command -v gh >/dev/null || fail 'gh_missing: install the GitHub CLI to publish'
if gh release view "$tag" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "$tag" "$out/$asset" --repo "$REPO" --clobber || fail 'publish_failed: gh release upload'
else
  notes="Linux prebuilt node bundle(s) for $commit.
Install on a fresh Linux machine (see README, \"Linux node\"):
d=~/wasm-agent-bootstrap; ( [ -d \"\$d/.git\" ] || git clone --depth 1 https://github.com/$REPO.git \"\$d\" ) && bash \"\$d/scripts/linux/bootstrap.sh\"
reason: ${reason:-none stated}"
  gh release create "$tag" "$out/$asset" --repo "$REPO" --target "$commit" --title "$tag" --notes "$notes" --prerelease \
    || fail 'publish_failed: gh release create'
fi
url="https://github.com/$REPO/releases/download/$tag/$asset"
say "published $url"

[ -f "$INDEX" ] || cat > "$INDEX" <<'JSON'
{
  "schema": "wasm-agent-linux-release-index",
  "schema_version": 1,
  "doc": "README.md#linux-node",
  "notes": "newest first; one entry per published Linux bundle and target; read by scripts/linux/bootstrap.sh",
  "releases": []
}
JSON
python3 - "$INDEX" "$commit" "$short" "$manifest_sha" "$url" "$size" "$triple" "$arch" "$tag" "$built_utc" "$node_version" <<'PY' || fail 'index_update_failed'
import json,sys
path,commit,short,sha,url,size,triple,arch,tag,built,node=sys.argv[1:12]
doc=json.load(open(path))
entry={"tag":tag,"commit":commit,"commit_short":short,"target":triple,"arch":arch,"manifest_sha256":sha,
       "url":url,"size":int(size),"node_version":node,"built_utc":built}
doc["releases"]=[entry]+[r for r in doc.get("releases",[]) if not (r.get("commit")==commit and r.get("target")==triple)]
doc["generated_utc"]=built
with open(path,"w") as f: json.dump(doc,f,indent=2); f.write("\n")
print("release-linux: index updated: %d entries" % len(doc["releases"]))
PY
say 'this script does NOT commit the index; the entry is the trust root and is reviewed like code:'
say "  git add releases/index-linux.json && git commit -m 'releases: linux $arch $tag' && git push origin main"
