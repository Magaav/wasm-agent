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
#
# Exit codes: 0 ok; 2 missing tool/target/manifest/asset; 5 a binary is not the pinned one (hash or ELF
# machine); 6 a size differs from the pin; 7 no sha256 tool; 8 the build or the run failed.
set -uo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
OUT="$ROOT/build/node-binaries"
FROM=""
CHECK=0
LOCAL=0
COMMIT=""
GLIBC_FLOOR="2.31"
TARGETS=""
ALLOW_EMPTY=0
RUNNER="${WA_PUBLISH_RUNNER:-}"
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
    --check) CHECK=1; shift ;;
    --local) LOCAL=1; shift ;;
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

[ -n "$TARGETS" ] || TARGETS=" aarch64-unknown-linux-gnu x86_64-unknown-linux-gnu"
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
  say "code-mode assets: $CODEMODE${ASSETS:+ ($ASSETS)}${ASSETS_WHY:+ - $ASSETS_WHY}"
  say "release tag: $TAG   (repo $REPO_SLUG)${LOCAL:+ [--local: not publishable]}"
  say "would write $OUT/node-$SHORT.manifest and: $(asset_list)"
  say "would print (not run) the gh release command; nothing was built"
  exit 0
fi

mkdir -p "$OUT" || fail "bundle_unwritable: $OUT"

# ---- the artifact set, from a build here or from --from --------------------------------------------
emit_manifest() { # <out dir> -> manifest path, after every member is checked
  local dir="$1" triple manifest tmp
  manifest="$dir/node-$SHORT.manifest"
  tmp="$dir/.node-$SHORT.manifest.$$"
  {
    echo 'schema=wasm-agent-node-binaries/1'
    echo "source_commit=$COMMIT"
    echo "source_tree=$(git -C "$ROOT" rev-parse "$COMMIT^{tree}" 2>/dev/null || echo unknown)"
    echo "rustc_version=$(rustc --version 2>/dev/null | sed 's/^rustc //')"
    echo "zig_version=$(zig version 2>/dev/null || echo unknown)"
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
  say "verified $FROM against its own manifest (source_commit $COMMIT)"
else
  # ---- build ---------------------------------------------------------------------------------------
  command -v cargo >/dev/null 2>&1 || fail 'cargo_missing: the build half needs cargo'
  command -v cargo-zigbuild >/dev/null 2>&1 || fail 'cargo_zigbuild_missing: cargo install cargo-zigbuild (and put zig on PATH: pip install ziglang)'
  command -v zig >/dev/null 2>&1 || fail 'zig_missing: pip install ziglang (or unpack a zig tarball) and put it on PATH'
  # Windows spawns a `zig cc` process per C file, and 16 at once runs the desktop heap out: measured on
  # wasm_the_first, `cargo zigbuild` at the default 16 jobs failed with `Not enough quota is available to
  # process this command. (os error 1816)` inside cc-rs, on zstd/lua, not on anything this tree wrote.
  # 6 jobs built the same target in 4m44s. Unix hosts keep cargo's own default.
  if [ -z "${CARGO_BUILD_JOBS:-}" ] && command -v cygpath >/dev/null 2>&1; then
    export CARGO_BUILD_JOBS=6
    say "CARGO_BUILD_JOBS=6 (a Windows host runs out of desktop heap above that: os error 1816)"
  fi
  say "building $COMMIT for $MANIFEST_TRIPLES (glibc floor $GLIBC_FLOOR, code-mode $CODEMODE${ASSETS:+ from $ASSETS})"
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
    target_dir="${CARGO_TARGET_DIR:-$ROOT/rust/target}"
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
  emit_manifest "$OUT" >/dev/null || fail "manifest_unwritable: $OUT" 2
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
  elif [ -n "$native_arch" ] && printf '%s\n' $TARGETS | grep -q "^$native_arch"; then
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
# gh is a native process: a /c/... path is not one it can open (AGENTS.md's oldest trap). Converted here,
# in the line a human pastes, so the printed command works from this shell.
asset_paths=""
for asset in $assets; do
  p="$OUT/$asset"
  if command -v cygpath >/dev/null 2>&1; then p="$(cygpath -m "$p")"; fi
  asset_paths="$asset_paths $p"
done
notes="Prebuilt node binaries for $COMMIT (${MANIFEST_TRIPLES// /, }, glibc <= $GLIBC_FLOOR, code-mode $CODEMODE)"
say 'publishing is a human/coordinator action; this script never runs gh. The exact command:'
printf '\ngh release create %s -R %s --target %s --title %s --notes %s%s\n\n' \
  "$TAG" "$REPO_SLUG" "$COMMIT" "$TAG" "'$notes'" "$asset_paths"
say 'If the tag already exists (a re-publish of the same commit), upload over it instead:'
printf '\ngh release upload %s -R %s --clobber%s\n\n' "$TAG" "$REPO_SLUG" "$asset_paths"
say "A node then needs nothing but this: bash scripts/deploy.sh (it fetches $TAG for its own triple,"
say "checks source_commit and every sha256/size, caches it under <install>/node-binaries/$SHORT)${RUN_DONE:+; ran: $RUN_DONE}"
say "publish-node-binaries ok: $TAG"
