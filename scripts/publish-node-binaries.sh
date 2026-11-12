#!/usr/bin/env bash
# Publish the node binaries for a commit, so a node that cannot afford a rebuild can deploy it
# (docs/COMPONENTS.md, "The node binary itself").
#
# WHY. A deploy ends in `cargo build` of `wa` and `wa-sentinel`. The components solved "build once,
# install everywhere" by publishing portable wasm; a binary is not portable, so the same idea needs one
# row per target triple and a release per commit:
#
#   release tag   node-<first 12 hex of the source commit>
#   pins          node-<sha12>.manifest - source_commit, the build's identity, one row per triple:
#                 <triple> <wa sha256> <wa bytes> <wa-sentinel sha256> <wa-sentinel bytes>
#                 plus compiled_inputs=<sha256>: the digest of the paths this binary is compiled from
#                 (rust/, wit/, Cargo files, code-mode build inputs; the ONE classification lives in
#                 scripts/lib/node-binaries.sh's wa_compiled_input). A deploy of a later commit whose
#                 compiled inputs hash to the same digest installs THIS release instead of compiling -
#                 a docs-only commit needs no binary of its own.
#   payload       wa-<triple>-<sha12>, wa-sentinel-<triple>-<sha12>
#
# The node asks for the release its OWN commit names, checks the manifest's source_commit against its
# 40-hex HEAD and every byte against the row, and only then caches or installs it
# (scripts/lib/node-binaries.sh). This script does the publishing half and never publishes: it prints
# the exact `gh release create` / `gh release upload` command, so publishing stays a reviewed action.
#
# HOW IT BUILDS, and why that is not `cargo build`. A Linux binary from a Windows or macOS box is a cross
# build: `cargo zigbuild --target <triple>.2.31` (cargo-zigbuild + zig, which is both the C compiler the
# C inside (`ring`, bundled SQLite, zstd, vendored Lua) needs and the linker). The `.2.31` suffix is
# zig's glibc-version floor: it links against symbols no newer than glibc 2.31, so the binary runs on
# Ubuntu 20.04 and everything newer (openclaw is 22.04/glibc 2.35), instead of inheriting the build
# host's. Measured on wasm_the_first (Windows x86_64, 16 threads) - the numbers are in the header of
# docs/COMPONENTS.md's distribution section.
#
# A cross build is exempt from wa-host's "a release build must embed the code-mode assets" rule
# (rust/wa-host/build.rs), because a cross build is not the artifact the BUILD host serves. It is,
# however, exactly the artifact the node serves - so this script embeds the assets itself when they are
# prepared (`scripts/lib/build-requirements.sh` names the directory), and refuses by name when they are
# not, unless --allow-empty-codemode says the artifact is a development one.
#
#   bash scripts/publish-node-binaries.sh                     # build both Linux targets, verify, print gh
#   bash scripts/publish-node-binaries.sh --check             # what would be built and uploaded; nothing built
#   bash scripts/publish-node-binaries.sh --from DIR          # verify artifacts built elsewhere, pin them
#   bash scripts/publish-node-binaries.sh --target aarch64-unknown-linux-gnu --commit <sha>
#   bash scripts/publish-node-binaries.sh --local             # any clean commit; refuses --publish
#   bash scripts/publish-node-binaries.sh --ensure            # exit 0 when a published release already covers
#                                                              # this commit's compiled inputs; build only otherwise
#   bash scripts/publish-node-binaries.sh --publish            # create/update the GitHub release itself
#   bash scripts/publish-node-binaries.sh --target-dir DIR     # the one cargo target directory (default rust/target)
#
# The toolchain is the script's own, never the caller's: it finds `zig` (PATH, then the pip `ziglang`
# package, then ~/.local/bin, /usr/local/bin, /opt/homebrew/bin, build/zig - `WA_ZIG` names one), puts
# its directory on PATH for the build, and exports ONE `CARGO_TARGET_DIR` so `wa-host`'s workspace and
# `wa-sentinel`'s own workspace land in the same tree. Measured 2026-11-10: a publisher that needed a
# human to recreate that environment worked only for the human, and `wa-sentinel`'s binary landed in
# rust/wa-sentinel/target where this script did not look.
#
# THE NORMAL PATH (docs/COMPONENTS.md, "How a landed commit gets its binary"): a landing ends with
# `--ensure --publish --target aarch64-unknown-linux-gnu`, so a commit that changed no compiled input
# costs a few release-list reads and a commit that did is built once, here, and published before any
# node deploys it. Without --publish nothing here runs gh, exactly as before.
#
# Exit codes: 0 ok; 2 missing tool/target/manifest/asset; 5 a binary is not the pinned one (hash or ELF
# machine); 6 a size differs from the pin; 7 no sha256 tool; 8 the build or the run failed.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="$ROOT/build/node-binaries"
FROM=""
CHECK=0
LOCAL=0
ENSURE=0
PUBLISH=0
COMMIT=""
GLIBC_FLOOR="2.31"
TARGETS=""
ALLOW_EMPTY=0
RUNNER="${WA_PUBLISH_RUNNER:-}"
TARGET_DIR_FLAG=""
say() { printf 'publish-node-binaries: %s\n' "$*"; }
fail() { printf 'publish-node-binaries: %s\n' "$*" >&2; exit "${2:-2}"; }
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || fail 'repo_value_required'; ROOT="$2"; shift 2 ;;
    --out) [ "$#" -ge 2 ] || fail 'out_value_required'; OUT="$2"; shift 2 ;;
    --from) [ "$#" -ge 2 ] || fail 'from_value_required'; FROM="$2"; shift 2 ;;
    --commit) [ "$#" -ge 2 ] || fail 'commit_value_required'; COMMIT="$2"; shift 2 ;;
    --target) [ "$#" -ge 2 ] || fail 'target_value_required'; TARGETS="$TARGETS $2"; shift 2 ;;
    --glibc) [ "$#" -ge 2 ] || fail 'glibc_value_required'; GLIBC_FLOOR="$2"; shift 2 ;;
    --runner) [ "$#" -ge 2 ] || fail 'runner_value_required'; RUNNER="$2"; shift 2 ;;
    --target-dir) [ "$#" -ge 2 ] || fail 'target_dir_value_required'; TARGET_DIR_FLAG="$2"; shift 2 ;;
    --check) CHECK=1; shift ;;
    --local) LOCAL=1; shift ;;
    --ensure) ENSURE=1; shift ;;
    --publish) PUBLISH=1; shift ;;
    --allow-empty-codemode) ALLOW_EMPTY=1; shift ;;
    -h|--help) sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail "unknown_option: $1" ;;
  esac
done
# `--repo` is how the tests point this at a fixture tree; the real tree is the default.
# `git rev-parse`, not `[ -d .git ]`: in a linked worktree (this project's topology,
# skills/git-orchestrator) `.git` is a FILE holding `gitdir: ...`, so a directory test refuses every lane
# tree and every node worktree.
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 || fail "not_a_checkout: $ROOT"
. "$ROOT/scripts/lib/node-binaries.sh"
. "$ROOT/scripts/lib/build-requirements.sh"

# ---- the toolchain this script owns, not the caller's shell --------------------------------------
#
# Measured 2026-11-10 (the aarch64 publisher that had to be recreated by hand): `zig` was installed
# but not on PATH - it ships inside the pip package `ziglang` - and `CARGO_TARGET_DIR` was whatever
# the caller's shell happened to export. Two consequences, both silent: the publisher only worked
# after a human rebuilt the hidden environment, and `wa-sentinel` (its own workspace,
# rust/wa-sentinel/Cargo.toml) wrote its binary under rust/wa-sentinel/target while this script read
# rust/target, so a landing that published would have failed at "binary_missing". Both are this
# script's business: it finds zig, and it names ONE target directory for both crates. A caller needs
# no environment at all; `--target-dir` and `WA_ZIG` are the supported overrides.
find_zig() {
  local candidate
  if candidate="$(command -v zig 2>/dev/null)" && [ -n "$candidate" ]; then printf '%s\n' "$candidate"; return 0; fi
  local python_zig
  python_zig="$(python3 -c 'import ziglang,os;print(os.path.join(os.path.dirname(ziglang.__file__),"zig.exe" if os.name=="nt" else "zig").replace(chr(92),"/"))' 2>/dev/null)" \
    || python_zig="$(python -c 'import ziglang,os;print(os.path.join(os.path.dirname(ziglang.__file__),"zig.exe" if os.name=="nt" else "zig").replace(chr(92),"/"))' 2>/dev/null)" \
    || python_zig=""
  for candidate in \
    "${WA_ZIG:-}" \
    "$HOME/.local/bin/zig" \
    "$HOME/.local/bin/zig.exe" \
    "$HOME/.cargo/bin/zig" \
    "/usr/local/bin/zig" \
    "/opt/homebrew/bin/zig" \
    "$ROOT/build/zig/zig" \
    "$python_zig" ; do
    if [ -n "$candidate" ] && [ -f "$candidate" ] && [ -x "$candidate" ]; then printf '%s\n' "$candidate"; return 0; fi
  done
  return 1
}
ZIG_BIN="$(find_zig || true)"
if [ -n "$ZIG_BIN" ]; then
  ZIG_DIR="$(dirname "$ZIG_BIN")"
  case ":$PATH:" in
    *":$ZIG_DIR:"*) ;;
    *) PATH="$ZIG_DIR:$PATH"; export PATH
       say "zig: $ZIG_BIN (found outside PATH; its directory is on PATH for this build)" ;;
  esac
  # PATH is not enough, and that is measured, not guessed: `cargo-zigbuild` (0.24.1) resolves zig with
  # `which -a zig`, which on this host found nothing for a real `zig.exe` on a PATH that demonstrably
  # contained its directory - the landing of a33e57c7f579 failed with exactly
  # `Error: Failed to find zig / cannot find binary path` while this script had just printed the zig
  # it had found. The crate's own supported answer is `CARGO_ZIGBUILD_ZIG_COMMAND`: it names the
  # binary, is used verbatim, and skips the search entirely (src/zig/locate.rs::find_zig).
  CARGO_ZIGBUILD_ZIG_COMMAND="$ZIG_BIN"; export CARGO_ZIGBUILD_ZIG_COMMAND
fi
# One target directory for both crates: `wa-host` (workspace rust/Cargo.toml) and `wa-sentinel`
# (its own workspace) otherwise resolve different `target/` roots, and the second one is invisible to
# the lookup below. Named here, exported, and used by the build loop - never read from the caller.
TARGET_DIR="${TARGET_DIR_FLAG:-$ROOT/rust/target}"
export CARGO_TARGET_DIR="$TARGET_DIR"

# The channel's published targets, and a landing publishes BOTH of them in one run: `work` is x86_64 Linux
# and compiles every update on 2 cores otherwise (measured 2026-11-11: ~100 s incremental, 19 min bootstrap).
# `wa_node_target_triple` (scripts/lib/node-binaries.sh) maps a node's uname to exactly one of these, and a
# deploy that finds no row for its triple falls back to building - the cost this pair exists to remove.
DEFAULT_RELEASE_TARGETS=" aarch64-unknown-linux-gnu x86_64-unknown-linux-gnu"
[ -n "$TARGETS" ] || TARGETS="$DEFAULT_RELEASE_TARGETS"
TARGETS="${TARGETS# }"
# The tag suffix carries the glibc floor: `<triple>.2.31` is cargo-zigbuild's spelling, and the plain
# triple is what the manifest rows and the node's own detection use.
ZIG_TARGETS=""
MANIFEST_TRIPLES=""
for target in $TARGETS; do
  case "$target" in
    aarch64-unknown-linux-gnu|x86_64-unknown-linux-gnu|aarch64-unknown-linux-musl|x86_64-unknown-linux-musl) ;;
    *) fail "target_unsupported: $target (aarch64|x86_64-unknown-linux-gnu|musl)" ;;
  esac
  case "$target" in
    *-musl) zig_target="$target" ;;
    *) zig_target="$target.$GLIBC_FLOOR" ;;
  esac
  ZIG_TARGETS="$ZIG_TARGETS $zig_target"
  MANIFEST_TRIPLES="$MANIFEST_TRIPLES $target"
done
ZIG_TARGETS="${ZIG_TARGETS# }"
MANIFEST_TRIPLES="${MANIFEST_TRIPLES# }"

HEAD_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)" || fail "not_a_checkout: $ROOT"
COMMIT="${COMMIT:-$HEAD_SHA}"
COMMIT="$(git -C "$ROOT" rev-parse --verify -q "$COMMIT^{commit}" 2>/dev/null)" || fail "commit_unknown: ${COMMIT:-$HEAD_SHA}"
if [ -z "$FROM" ]; then
  [ "$COMMIT" = "$HEAD_SHA" ] || fail "commit_not_checked_out: build from a checkout of $COMMIT (HEAD is $HEAD_SHA)"
  [ -z "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ] || fail 'source_dirty: commit or stash before publishing a build'
fi
TAG="$(wa_node_release_tag "$COMMIT")" || fail "commit_invalid: $COMMIT is not a 40-hex commit id"
SHORT="${TAG#node-}"
REPO_SLUG="$(wa_node_release_repo "$ROOT")"
if [ "$LOCAL" = 0 ] && [ -z "$FROM" ]; then
  git -C "$ROOT" fetch -q origin 2>/dev/null || say 'fetch of origin failed; checking against the origin/main this clone has'
  git -C "$ROOT" merge-base --is-ancestor "$COMMIT" origin/main 2>/dev/null \
    || fail "not_on_main: $COMMIT is not on origin/main; a node installs main (--local for a test artifact)"
fi
if [ "$PUBLISH" = 1 ]; then
  # Publishing is the landing's job now, but never for a test artifact and never for a run that built
  # nothing: both would put a tag on the channel that names something no node should install.
  [ "$LOCAL" = 0 ] || fail 'publish_local_refused: --local artifacts are test builds; they are never published'
  [ "$CHECK" = 0 ] || fail 'publish_check_refused: --check builds nothing, so there is nothing to publish'
fi

# ---- --ensure: is this commit already covered? ------------------------------------------------------
# A landing runs this before paying for a build. The question is not "does a release name this commit"
# but "does a published release have this commit's compiled inputs" - the same digest rule the deploy's
# fallback uses (scripts/lib/node-binaries.sh, wa_node_release_digest_search), so a Lua-only or docs-only
# landing answers in seconds and a rust change builds once. A matching-but-broken release is a refusal
# here exactly as it is in a deploy, never a reason to build around it.
if [ "$ENSURE" = 1 ]; then
  ensure_cache="$OUT/cache"
  ensure_tag=""
  ensure_commit=""
  ensure_missing=""
  for triple in $MANIFEST_TRIPLES; do
    out="$(wa_node_release_digest_search "$ROOT" "$COMMIT" "$triple" "$ensure_cache" 2>&1)"; rc=$?
    case "$rc" in
      0)
        found_tag="$(printf '%s\n' "$out" | sed -n 's/^release_tag=//p' | head -1)"
        found_commit="$(printf '%s\n' "$out" | sed -n 's/^release_commit=//p' | head -1)"
        ensure_tag="${ensure_tag:-$found_tag}"
        ensure_commit="${ensure_commit:-$found_commit}"
        ;;
      8) ensure_missing="$ensure_missing $triple" ;;
      *) printf '%s\n' "$out" >&2; fail "ensure_refused: the release that covers $COMMIT for $triple could not be verified" "$rc" ;;
    esac
  done
  if [ -z "$ensure_missing" ]; then
    say "covered: $ensure_tag covers the compiled inputs of $COMMIT for $MANIFEST_TRIPLES (source_commit $ensure_commit); nothing to build or publish"
    exit 0
  fi
  say "not covered for$ensure_missing; building $MANIFEST_TRIPLES (a deploy of $COMMIT needs this release)"
fi

# ---- the code-mode assets: what makes this binary the node's binary ---------------------------------
ASSETS=""
ASSETS_WHY=""
if dir="$(wa_codemode_assets_dir "$ROOT")" && [ -f "$dir/receipt.json" ] && [ -f "$dir/quickjs.wasm" ] && [ -f "$dir/prelude.js" ]; then
  ASSETS="$dir"
else
  ASSETS_WHY="no prepared code-mode assets at $(wa_codemode_assets_dir "$ROOT") (a shipping build must embed them; run scripts/provision-codemode-assets.mjs)"
fi
CODEMODE=embedded
[ -n "$ASSETS" ] || CODEMODE=empty
if [ "$CODEMODE" = empty ] && [ "$ALLOW_EMPTY" = 0 ] && [ -z "$FROM" ]; then
  fail "codemode_assets_unprovisioned: $ASSETS_WHY; a node built this way starts every run with codemode_not_ready. Provision the pinned assets, or pass --allow-empty-codemode for a development artifact"
fi

# ---- what the pytest half prints and the deploy half reads -------------------------------------------
asset_list() {
  local triple
  for triple in $MANIFEST_TRIPLES; do
    printf 'wa-%s-%s wa-sentinel-%s-%s\n' "$triple" "$SHORT" "$triple" "$SHORT"
  done
}

if [ "$CHECK" = 1 ] && [ -z "$FROM" ]; then
  say "would build $COMMIT for: $MANIFEST_TRIPLES"
  say "with: cargo zigbuild --release --offline --locked -p wa-host --target <triple>.$GLIBC_FLOOR (and wa-sentinel likewise)"
  say "zig: ${ZIG_BIN:-none found (a build would refuse with zig_missing; pass WA_ZIG or install pip ziglang)}"
  [ -n "$ZIG_BIN" ] && say "cargo zigbuild uses: CARGO_ZIGBUILD_ZIG_COMMAND=$CARGO_ZIGBUILD_ZIG_COMMAND"
  say "cargo target dir: $TARGET_DIR (one directory for wa-host and wa-sentinel; --target-dir overrides)"
  say "code-mode assets: $CODEMODE${ASSETS:+ ($ASSETS)}${ASSETS_WHY:+ - $ASSETS_WHY}"
  say "compiled inputs: $(wa_compiled_inputs_digest "$ROOT" "$COMMIT" 2>&1) (a later commit with this digest installs this release)"
  say "release tag: $TAG   (repo $REPO_SLUG)${LOCAL:+ [--local: not publishable]}"
  say "would write $OUT/node-$SHORT.manifest and: $(asset_list)"
  say "would print (not run) the gh release command; nothing was built"
  exit 0
fi

mkdir -p "$OUT" || fail "bundle_unwritable: $OUT"

# ---- the artifact set, from a build here or from --from --------------------------------------------
emit_manifest() { # <out dir> -> manifest path, after every member is checked
  local dir="$1" triple manifest tmp digest
  manifest="$dir/node-$SHORT.manifest"
  tmp="$dir/.node-$SHORT.manifest.$$"
  # The compiled-inputs digest is a fact about the COMMIT, not about this machine's build, so it is read
  # out of the commit's tree here and refused by name when it cannot be: a release with no digest is a
  # release a docs-only descendant cannot use, which is the whole reason the row exists.
  digest="$(wa_compiled_inputs_digest "$ROOT" "$COMMIT")" || fail "compiled_inputs_unavailable: cannot digest the compiled inputs of $COMMIT" 2
  [ -n "$digest" ] || fail "compiled_inputs_unavailable: no sha256 tool for the compiled-inputs digest" 7
  {
    echo 'schema=wasm-agent-node-binaries/1'
    echo "source_commit=$COMMIT"
    echo "source_tree=$(git -C "$ROOT" rev-parse "$COMMIT^{tree}" 2>/dev/null || echo unknown)"
    echo "compiled_inputs=$digest"
    echo "rustc_version=$(rustc --version 2>/dev/null | sed 's/^rustc //')"
    echo "zig_version=$(zig version 2>/dev/null || echo unknown)"
    [ -n "${BUILD_SECONDS:-}" ] && echo "build_seconds=$BUILD_SECONDS"
    echo "glibc_floor=$GLIBC_FLOOR"
    echo "codemode=$CODEMODE"
    echo "built_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo '# target wa_sha256 wa_bytes wa-sentinel_sha256 wa-sentinel_bytes'
    for triple in $MANIFEST_TRIPLES; do
      local wa="$dir/wa-$triple-$SHORT" sentinel="$dir/wa-sentinel-$triple-$SHORT"
      [ -f "$wa" ] || fail "binary_missing: $wa" 2
      [ -f "$sentinel" ] || fail "binary_missing: $sentinel" 2
      printf '%s %s %s %s %s\n' "$triple" \
        "$(wa_node_sha256 "$wa")" "$(wc -c < "$wa" | tr -d '[:space:]')" \
        "$(wa_node_sha256 "$sentinel")" "$(wc -c < "$sentinel" | tr -d '[:space:]')"
    done
  } > "$tmp" || fail "manifest_unwritable: $tmp"
  mv -f "$tmp" "$manifest" || fail "manifest_unwritable: $manifest"
  printf '%s\n' "$manifest"
}

if [ -n "$FROM" ]; then
  # Verify what another machine built, before anything is printed for upload: the manifest it wrote must
  # be this commit's, and every binary must be the one its own manifest pins.
  [ -f "$FROM/node-$SHORT.manifest" ] || fail "manifest_missing: $FROM/node-$SHORT.manifest (--from needs the manifest the build wrote)" 2
  if [ "$(wa_node_manifest_value "$FROM/node-$SHORT.manifest" source_commit)" != "$COMMIT" ]; then
    fail "manifest_commit_mismatch: $FROM names source_commit=$(wa_node_manifest_value "$FROM/node-$SHORT.manifest" source_commit), asked for $COMMIT" 2
  fi
  # With --from the artifact's own manifest is the truth about code mode, not this host's asset directory:
  # the machine that built it is the one that had to embed them.
  CODEMODE="$(wa_node_manifest_value "$FROM/node-$SHORT.manifest" codemode)"
  [ -n "$CODEMODE" ] || CODEMODE=unknown
  if [ "$CODEMODE" != embedded ] && [ "$ALLOW_EMPTY" = 0 ]; then
    fail "codemode_assets_absent: $FROM's manifest records codemode=$CODEMODE; a node built this way starts every run with codemode_not_ready (--allow-empty-codemode to publish it anyway)" 2
  fi
  cp -f "$FROM/node-$SHORT.manifest" "$OUT/.node-$SHORT.manifest.$$" && mv -f "$OUT/.node-$SHORT.manifest.$$" "$OUT/node-$SHORT.manifest" \
    || fail "bundle_unwritable: $OUT" 2
  # The compiled-inputs row is a fact about $COMMIT, so it is RECOMPUTED here rather than trusted: the
  # machine that built the artifact had the same commit, so the answer must be the same, and a manifest
  # that disagrees is refused - a release whose digest is another tree's would be installed by every
  # docs-only descendant of a commit it is not the build of. An artifact published before this row
  # existed is given one here; nothing else about it changes.
  DIGEST="$(wa_compiled_inputs_digest "$ROOT" "$COMMIT")" || fail "compiled_inputs_unavailable: cannot digest the compiled inputs of $COMMIT" 2
  INCOMING="$(wa_node_manifest_value "$OUT/node-$SHORT.manifest" compiled_inputs)"
  if [ -n "$INCOMING" ] && [ "$INCOMING" != "$DIGEST" ]; then
    fail "compiled_inputs_mismatch: $FROM's manifest records compiled_inputs=$INCOMING and $COMMIT's tree is $DIGEST, so that manifest is not this commit's" 5
  fi
  awk -v d="$DIGEST" '
    /^compiled_inputs=/ {next}
    {print}
    /^source_tree=/ {print "compiled_inputs=" d; done = 1}
    END {if (!done) print "compiled_inputs=" d}
  ' "$OUT/node-$SHORT.manifest" > "$OUT/.node-$SHORT.manifest.$$.tmp" \
    && mv -f "$OUT/.node-$SHORT.manifest.$$.tmp" "$OUT/node-$SHORT.manifest" \
    || fail "manifest_unwritable: $OUT/node-$SHORT.manifest" 2
  for triple in $MANIFEST_TRIPLES; do
    for name in "wa-$triple-$SHORT" "wa-sentinel-$triple-$SHORT"; do
      [ -f "$FROM/$name" ] || fail "binary_missing: $FROM/$name" 2
      cp -f "$FROM/$name" "$OUT/.$name.$$" && mv -f "$OUT/.$name.$$" "$OUT/$name" || fail "bundle_unwritable: $OUT/$name" 2
    done
  done
  # The manifest travels with the binaries, so the pin checked below is the pin that ships.
  for triple in $MANIFEST_TRIPLES; do
    pin="$(wa_node_manifest_pin "$OUT/node-$SHORT.manifest" "$triple")" || fail "manifest_incomplete: no row for $triple" 2
    set -- $pin
    for pair in "wa-$triple-$SHORT:$1:$2" "wa-sentinel-$triple-$SHORT:$3:$4"; do
      name="${pair%%:*}"; rest="${pair#*:}"; want_sha="${rest%%:*}"; want_bytes="${rest##*:}"
      actual="$(wa_node_sha256 "$OUT/$name")" || fail 'sha256_tool_missing: no sha256sum or shasum' 7
      [ "$actual" = "$want_sha" ] || fail "artifact_not_pinned: $name is $actual, the manifest pins $want_sha" 5
      [ "$(wc -c < "$OUT/$name" | tr -d '[:space:]')" = "$want_bytes" ] || fail "artifact_not_pinned: $name is not $want_bytes bytes" 6
    done
  done
  say "verified $FROM against its own manifest (source_commit $COMMIT, compiled_inputs $DIGEST)"
else
  # ---- build ---------------------------------------------------------------------------------------
  command -v cargo >/dev/null 2>&1 || fail 'cargo_missing: the build half needs cargo'
  command -v cargo-zigbuild >/dev/null 2>&1 || fail 'cargo_zigbuild_missing: cargo install cargo-zigbuild (and put zig on PATH: pip install ziglang)'
  [ -n "$ZIG_BIN" ] || fail 'zig_missing: no zig was found on PATH, in the pip package `ziglang`, in ~/.local/bin or in build/zig; install it (pip install ziglang) or name it with WA_ZIG=/path/to/zig'
  # Windows spawns a `zig cc` process per C file, and 16 at once runs the desktop heap out: measured on
  # wasm_the_first, `cargo zigbuild` at the default 16 jobs failed with `Not enough quota is available to
  # process this command. (os error 1816)` inside cc-rs, on zstd/lua, not on anything this tree wrote.
  # 6 jobs built the same target in 4m44s. Unix hosts keep cargo's own default.
  if [ -z "${CARGO_BUILD_JOBS:-}" ] && command -v cygpath >/dev/null 2>&1; then
    export CARGO_BUILD_JOBS=6
    say "CARGO_BUILD_JOBS=6 (a Windows host runs out of desktop heap above that: os error 1816)"
  fi
  say "building $COMMIT for $MANIFEST_TRIPLES (glibc floor $GLIBC_FLOOR, code-mode $CODEMODE${ASSETS:+ from $ASSETS})"
  BUILD_SECONDS=""
  build_started=$(date +%s)
  # The pin this build claims must be the pin it produces: the target's own glibc floor is read back
  # from the bytes below, so a `--glibc` this toolchain cannot honour is a refusal, not a quiet lie.
  export WA_CODEMODE_BUILD_ASSETS="${ASSETS:-}"
  [ -n "$ASSETS" ] || unset WA_CODEMODE_BUILD_ASSETS
  [ -n "$ASSETS" ] || export WA_CODEMODE_ALLOW_EMPTY=1
  WA_BUILD_SOURCE_COMMIT="$COMMIT" WA_BUILD_SOURCE_TREE="$(git -C "$ROOT" rev-parse "$COMMIT^{tree}")"
  export WA_BUILD_SOURCE_COMMIT WA_BUILD_SOURCE_TREE
  for zig_target in $ZIG_TARGETS; do
    triple="${zig_target%%.2.*}"
    started=$(date +%s)
    ( cd "$ROOT/rust" && cargo zigbuild --release --offline --locked -p wa-host --target "$zig_target" ) > "$OUT/build-wa-$triple.log" 2>&1 \
      || { tail -20 "$OUT/build-wa-$triple.log" >&2; fail "build_failed: wa for $zig_target (log $OUT/build-wa-$triple.log)" 8; }
    ( cd "$ROOT/rust" && cargo zigbuild --release --offline --locked --manifest-path wa-sentinel/Cargo.toml --target "$zig_target" ) > "$OUT/build-sentinel-$triple.log" 2>&1 \
      || { tail -20 "$OUT/build-sentinel-$triple.log" >&2; fail "build_failed: wa-sentinel for $zig_target (log $OUT/build-sentinel-$triple.log)" 8; }
    say "built $triple in $(( $(date +%s) - started ))s"
    target_dir="$TARGET_DIR"
    wa_bin="$target_dir/$zig_target/release/wa"
    sentinel_bin="$target_dir/$zig_target/release/wa-sentinel"
    # cargo names the directory after the triple WITHOUT the glibc suffix.
    [ -f "$wa_bin" ] || wa_bin="$target_dir/$triple/release/wa"
    [ -f "$sentinel_bin" ] || sentinel_bin="$target_dir/$triple/release/wa-sentinel"
    [ -f "$wa_bin" ] || fail "binary_missing: no built wa for $zig_target under $target_dir" 8
    [ -f "$sentinel_bin" ] || fail "binary_missing: no built wa-sentinel for $zig_target under $target_dir" 8
    cp -f "$wa_bin" "$OUT/.wa-$triple-$SHORT.$$" && mv -f "$OUT/.wa-$triple-$SHORT.$$" "$OUT/wa-$triple-$SHORT" || fail "bundle_unwritable: $OUT" 2
    cp -f "$sentinel_bin" "$OUT/.wa-sentinel-$triple-$SHORT.$$" && mv -f "$OUT/.wa-sentinel-$triple-$SHORT.$$" "$OUT/wa-sentinel-$triple-$SHORT" || fail "bundle_unwritable: $OUT" 2
    chmod +x "$OUT/wa-$triple-$SHORT" "$OUT/wa-sentinel-$triple-$SHORT" 2>/dev/null || true
  done
  BUILD_SECONDS=$(( $(date +%s) - build_started ))
  emit_manifest "$OUT" >/dev/null || fail "manifest_unwritable: $OUT" 2
  say "total build: ${BUILD_SECONDS}s for $MANIFEST_TRIPLES"
fi

# ---- verify every member BEFORE anything is printed for upload --------------------------------------
# A bundle that is not the one its manifest pins must never reach a release: every node would then be
# asked to install bytes its own check refuses, and the failure would land on each node instead of here.
for triple in $MANIFEST_TRIPLES; do
  pin="$(wa_node_manifest_pin "$OUT/node-$SHORT.manifest" "$triple")" || fail "manifest_incomplete: no row for $triple" 2
  set -- $pin
  for pair in "wa-$triple-$SHORT:$1:$2" "wa-sentinel-$triple-$SHORT:$3:$4"; do
    name="${pair%%:*}"; rest="${pair#*:}"; want_sha="${rest%%:*}"; want_bytes="${rest##*:}"
    file="$OUT/$name"
    [ -f "$file" ] || fail "binary_missing: $file" 2
    actual="$(wa_node_sha256 "$file")" || fail 'sha256_tool_missing: no sha256sum or shasum' 7
    bytes="$(wc -c < "$file" | tr -d '[:space:]')"
    [ "$actual" = "$want_sha" ] || fail "artifact_not_pinned: $name is $actual, the manifest pins $want_sha" 5
    [ "$bytes" = "$want_bytes" ] || fail "artifact_not_pinned: $name is $bytes bytes, the manifest pins $want_bytes" 6
    shape="$(wa_node_binary_shape "$file")"
    want_machine="$(wa_node_triple_machine "$triple")"
    [ -z "$want_machine" ] || [ "$shape" = "elf:$want_machine" ] \
      || fail "machine_mismatch: $name is $shape, $triple needs elf:$want_machine" 5
    # The floor the manifest claims, read back from the symbol versions the linker actually left: a
    # binary that needs a newer glibc than the pin says installs on a node that cannot run it.
    newest="$(grep -a -o 'GLIBC_2\.[0-9]\+' "$file" 2>/dev/null | sed 's/^GLIBC_//' | sort -uV | tail -1)"
    if [ -n "$newest" ] && [ "$newest" != "$GLIBC_FLOOR" ] && [ "$(printf '%s\n%s\n' "$GLIBC_FLOOR" "$newest" | sort -V | tail -1)" != "$GLIBC_FLOOR" ]; then
      fail "glibc_floor_exceeded: $name needs GLIBC_$newest, the pin says $GLIBC_FLOOR" 5
    fi
    say "verified $name: $actual ($bytes bytes, $shape${newest:+, glibc <= $newest})"
  done
done

# ---- the run: a binary that cannot start is not a release -------------------------------------------
# Proven by execution, or reported as skipped - never assumed. A Linux host that cannot execute the
# release's architecture (Windows, macOS, an arm64 laptop asked for x86_64) can still publish, but it
# says so here and the deploy's own prove gate runs the binary on the node before installing it.
RUN_DONE=""
# A runner prefix is used from THIS host, so it may need this host's path rewritten into its own world:
# `wsl -d Ubuntu -- <path>` runs a Linux binary, and the path it needs is /mnt/<drive>/... - the /c/...
# form this shell prints does not exist inside that VM (measured: "No such file or directory").
runner_path() {
  local path="$1" p
  case "$RUNNER" in
    *wsl*)
      p="$(cygpath -u "$path" 2>/dev/null || printf '%s' "$path")"
      printf '/mnt/%s\n' "${p#/}" ;;
    *) printf '%s\n' "$path" ;;
  esac
}
# Git Bash rewrites an argument that looks like a POSIX path into C:/Program Files/Git/... before wsl.exe
# sees it (measured: "C:/Program Files/Git/mnt/c/...: No such file or directory"), so the one variable
# MSYS honours is set for exactly this call.
run_through_runner() {
  case "$RUNNER" in
    *wsl*) MSYS2_ARG_CONV_EXCL='*' $RUNNER "$@" ;;
    *) $RUNNER "$@" ;;
  esac
}
native_arch=""
if [ "$(uname -s 2>/dev/null)" = Linux ]; then
  case "$(uname -m)" in aarch64|arm64) native_arch=aarch64- ;; x86_64|amd64) native_arch=x86_64- ;; esac
fi
for triple in $MANIFEST_TRIPLES; do
  if [ -n "$RUNNER" ]; then
    if run_through_runner "$(runner_path "$OUT/wa-$triple-$SHORT")" --version >/dev/null 2>&1 \
      && run_through_runner "$(runner_path "$OUT/wa-sentinel-$triple-$SHORT")" --help >/dev/null 2>&1; then
      say "ran $triple through --runner: wa --version and wa-sentinel --help answered"
      RUN_DONE="$RUN_DONE $triple"
    else
      fail "run_failed: $RUNNER could not execute wa-$triple-$SHORT --version (or wa-sentinel --help)" 8
    fi
  # The question is per TRIPLE: can THIS host execute THIS row? Asking it about the SET of targets is a
  # different question, and a wrong one - measured 2026-11-11 on wa-desktop (Ubuntu x86_64), the first
  # Linux host to publish both rows: `$TARGETS` holds x86_64 somewhere, so the aarch64 row was executed
  # too and a 481s verified build ended in `run_failed: wa-aarch64-... --version did not answer on this
  # host`. A host that can run one row must still report SKIPPED for the other.
  elif [ -n "$native_arch" ] && printf '%s\n' "$triple" | grep -q "^$native_arch"; then
    if "$OUT/wa-$triple-$SHORT" --version >/dev/null 2>&1; then
      say "ran $triple natively: wa --version answered"
      RUN_DONE="$RUN_DONE $triple"
    else
      fail "run_failed: wa-$triple-$SHORT --version did not answer on this host" 8
    fi
  else
    say "run: SKIPPED for $triple (this host ($(uname -s)/$(uname -m)) cannot execute it; the deploy proves it on the node before installing)"
  fi
done

# ---- print the publish command (never run it) --------------------------------------------------------
say "bundle: $OUT"
say "release tag: $TAG (source_commit $COMMIT)"
say "pins: $OUT/node-$SHORT.manifest"
assets="$(asset_list) node-$SHORT.manifest"
# SHA256SUMS for the node release, built from the bytes about to be uploaded: the manifest is the pin a
# deploy verifies (source_commit + sha256/size per triple), and this is the same set in the flat form every
# other release of this project publishes, so a mirror, an audit or a human with `sha256sum -c` needs no
# knowledge of the manifest's shape. It lies beside the manifest, never instead of it.
{
  for asset in $assets; do
    [ -f "$OUT/$asset" ] || fail "binary_missing: $OUT/$asset" 2
    ( cd "$OUT" && sha256sum "$asset" ) || fail 'sha256_tool_missing: no sha256sum or shasum' 7
  done
} > "$OUT/.SHA256SUMS.$$" && mv -f "$OUT/.SHA256SUMS.$$" "$OUT/SHA256SUMS" || fail "bundle_unwritable: $OUT/SHA256SUMS" 2
assets="$assets SHA256SUMS"
say "checksums $OUT/SHA256SUMS ($(wc -l < "$OUT/SHA256SUMS" | tr -d '[:space:]') asset(s))"
# gh is a native process: a /c/... path is not one it can open (AGENTS.md's oldest trap). Converted here,
# in the line a human pastes, so the printed command works from this shell.
asset_paths=""
for asset in $assets; do
  p="$OUT/$asset"
  if command -v cygpath >/dev/null 2>&1; then p="$(cygpath -m "$p")"; fi
  asset_paths="$asset_paths $p"
done
notes="Prebuilt node binaries for $COMMIT (${MANIFEST_TRIPLES// /, }, glibc <= $GLIBC_FLOOR, code-mode $CODEMODE)"
if [ "$PUBLISH" = 1 ]; then
  say 'the release is published by --publish (idempotent: a tag that exists is uploaded over, never recreated)'
else
  say 'publishing is a human/coordinator action unless --publish is passed; this script never runs gh otherwise. The exact command:'
fi
printf '\ngh release create %s -R %s --target %s --title %s --notes %s%s\n\n' \
  "$TAG" "$REPO_SLUG" "$COMMIT" "$TAG" "'$notes'" "$asset_paths"
say 'If the tag already exists (a re-publish of the same commit), upload over it instead:'
printf '\ngh release upload %s -R %s --clobber%s\n\n' "$TAG" "$REPO_SLUG" "$asset_paths"
if [ "$PUBLISH" = 1 ]; then
  command -v gh >/dev/null 2>&1 \
    || fail 'publish_tool_missing: --publish needs gh on PATH and an authenticated account (gh auth status)' 2
  if gh release view "$TAG" -R "$REPO_SLUG" >/dev/null 2>&1; then
    gh release upload "$TAG" -R "$REPO_SLUG" --clobber $asset_paths \
      || fail "publish_failed: gh release upload $TAG" 8
    say "published $TAG (uploaded over the existing release): https://github.com/$REPO_SLUG/releases/tag/$TAG"
  else
    gh release create "$TAG" -R "$REPO_SLUG" --target "$COMMIT" --title "$TAG" --notes "$notes" $asset_paths \
      || fail "publish_failed: gh release create $TAG" 8
    say "published $TAG: https://github.com/$REPO_SLUG/releases/tag/$TAG"
  fi
fi
say "A node then needs nothing but this: bash scripts/deploy.sh (it fetches $TAG for its own triple,"
say "checks source_commit and every sha256/size, caches it under <install>/node-binaries/$SHORT)${RUN_DONE:+; ran: $RUN_DONE}"
say "publish-node-binaries ok: $TAG"
