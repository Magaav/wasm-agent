#!/bin/bash
# WHICH BINARY MAY GRADE MAIN (Victor 27/11: no laptop install by default; order 27/11 18:40).
#
# The health loop judges main's tip by running main's own rows, so it needs a binary OF THAT TIP. It used to hand
# them ~/.local/bin/wa, the laptop's installed build, which lags main now that a landing does not install - so a
# row that needed the new code went red for a reason that had nothing to do with the tip. Then the first version
# of this file refused too eagerly: every tip came out "NOT GRADED: no binary of main's own" (18:23, 18:29, 18:34
# on fdeda1b8), and a loop that never grades is a watchdog that never barks.
#
#   wa_main_binary <sha>      prints the path of a binary of that tip, or nothing and a named reason on stderr
#                             (rc 1). NEVER ~/.local/bin. Order:
#                             1. the PUBLISHED release for the tip, or the newest release covering the tip's
#                                COMPILED INPUTS - asked of the deploy's own resolver
#                                (scripts/lib/node-binaries.sh: wa_node_binary_source_resolve), law 17: a
#                                second resolver would drift from the one that decides what a node runs;
#                             2. a build in this file's own target dir: niced, one at a time (flock), capped;
#                             3. a named refusal naming both attempts, and the caller alarms after 2 tips in a
#                                row that could not be graded.
set -uo pipefail

# The tip's own bytes from the release side, through the deploy's resolver.
wa_main_binary_release() { # <sha> <root> <stage>
  local sha=$1 root=$2 stage=$3 lib triple out dir
  lib=${WA_NODE_BINARIES_LIB:-$root/scripts/lib/node-binaries.sh}
  [ -r "$lib" ] || { echo "wa_main_binary: no release resolver at $lib" >&2; return 1; }
  # shellcheck disable=SC1090
  . "$lib" || { echo "wa_main_binary: could not source $lib" >&2; return 1; }
  command -v wa_node_binary_source_resolve >/dev/null 2>&1 || {
    echo "wa_main_binary: $lib defines no wa_node_binary_source_resolve" >&2; return 1; }
  # The deploy bounds its digest scan at 20 s because a deploy has a build waiting behind it. THIS caller's
  # fallback is a ten-minute build, so a slow scan is the cheaper answer: measured 27/11 - the first scan in a
  # fresh stage stopped at 23 releases inside its 20 s bound and reported "no release", and the same scan a
  # minute later, with the list warm, found the one covering the tip (fdeda1b8).
  export WA_NODE_RELEASE_DIGEST_SECONDS=${WA_NODE_RELEASE_DIGEST_SECONDS:-60}
  triple=$(wa_node_target_triple 2>/dev/null) || triple=""
  [ -n "$triple" ] || { echo "wa_main_binary: no prebuilt target triple on this machine" >&2; return 1; }
  mkdir -p "$stage" 2>/dev/null || true
  out=$(wa_node_binary_source_resolve "$root" "$sha" "$triple" "$stage" 2>/dev/null) || out=""
  dir=$(printf '%s\n' "$out" | head -1)
  [ -n "$dir" ] || { echo "wa_main_binary: the resolver named no release for ${sha:0:12}" >&2; return 1; }
  local f
  for f in "$dir/wa" "$dir/wa-$triple-${sha:0:12}" "$dir"/wa-"$triple"-*; do
    [ -x "$f" ] && { printf '%s\n' "$f"; return 0; }
  done
  echo "wa_main_binary: the resolver's dir $dir holds no binary of ${sha:0:12}" >&2
  return 1
}

# The tip's own bytes from this machine, in a target dir nobody else uses.
wa_main_binary_build() { # <sha> <root> <target>
  local sha=$1 root=$2 target=$3 built=""
  built=$target/release/wa
  # CARGO IS NOT ON THE LOOP'S PATH. The health loop runs under systemd, whose PATH is the unit's, and this
  # node's toolchain lives in ~/wasm-agent/toolchain/cargo/bin - measured 27/11: with main's own lib and the
  # real tip the answer was "no cargo to build <sha>", so the build step could never run and every tip stayed
  # NOT GRADED even after the release resolver was fixed. Ask the same places the rest of the node does, and
  # put the toolchain's bin FIRST so its rustc is found too.
  local cargo_bin=""
  for cargo_bin in "${WA_MAIN_CARGO:-}" "$HOME/wasm-agent/toolchain/cargo/bin/cargo" "$HOME/.cargo/bin/cargo"                   "$HOME/.local/share/mise/shims/cargo"; do
    [ -n "$cargo_bin" ] && [ -x "$cargo_bin" ] && break
  done
  if [ -z "$cargo_bin" ] || [ ! -x "$cargo_bin" ]; then
    cargo_bin=$(command -v cargo 2>/dev/null) || cargo_bin=""
  fi
  [ -n "$cargo_bin" ] || { echo "wa_main_binary: no cargo to build ${sha:0:12} (looked in the toolchain, ~/.cargo, mise and PATH)" >&2; return 1; }
  local cargo_dir; cargo_dir=$(cd "$(dirname "$cargo_bin")" && pwd); PATH="$cargo_dir:$PATH"
  # CODE-MODE ASSETS: wa-capabilities/build.rs refuses to build without a prepared, verified asset directory
  # (exit 101, "code-mode assets required"), so this build failed on every tree even with the members and the
  # right crate. The repo owns both the path and the provisioner, so ask it (law 17) and export what it names.
  local assets=""
  if [ -r "$root/scripts/lib/build-requirements.sh" ]; then
    assets=$(bash -c '. "$1/scripts/lib/build-requirements.sh"; wa_codemode_assets_dir "$1"' _ "$root" 2>/dev/null)
  fi
  if [ -n "$assets" ]; then
    if [ ! -f "$assets/receipt.json" ] && [ -f "$root/scripts/provision-codemode-assets.mjs" ] && command -v node >/dev/null 2>&1; then
      node "$root/scripts/provision-codemode-assets.mjs" "$assets" >/dev/null 2>&1 || true
    fi
    [ -d "$assets" ] && export WA_CODEMODE_BUILD_ASSETS="$assets"
  fi
  mkdir -p "$target" 2>/dev/null || { echo "wa_main_binary: cannot create $target" >&2; return 1; }
  # ONE AT A TIME: two health runs must not build into the same target dir, and the loop has better things to do
  # than queue - the next tick picks it up.
  if command -v flock >/dev/null 2>&1; then
    exec 8>"$target/.build.lock"
    flock -n 8 || { echo "wa_main_binary: another build into $target is running" >&2; return 1; }
  fi
  local cap=${WA_MAIN_BUILD_CAP_SECONDS:-900} nice_level=${WA_MAIN_BUILD_NICE:-10} rc=0
  CARGO_TARGET_DIR="$target" nice -n "$nice_level" timeout "$cap" \
    "$cargo_bin" build --release --offline -p wa-host --manifest-path "$root/rust/Cargo.toml" >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 0 ] && [ -x "$built" ]; then printf '%s\n' "$built"; return 0; fi
  echo "wa_main_binary: the build of ${sha:0:12} in $target failed (rc $rc, cap ${cap}s)" >&2
  return 1
}

wa_main_binary() { # <sha> [release-stage] [target-dir] [repo-root]
  local sha=${1:?usage: wa_main_binary <sha> [release-stage] [target-dir] [repo-root]}
  local stage=${2:-$HOME/.wasm-agent/health-releases}
  local target=${3:-$HOME/wasm-agent/health-target}
  local root=${4:-$HOME/wasm-agent/checkout} out=""
  case "$sha" in [0-9a-f][0-9a-f]*) ;; *) echo "wa_main_binary: $sha is not a commit id" >&2; return 1;; esac

  # ONE call: the resolver is not free (it may look at the network), and asking twice could get two answers.
  local rerr; mkdir -p "$target" 2>/dev/null || true; rerr=$(mktemp -u "/tmp/wa-main-release.XXXXXX")
  local why_release
  if out=$(wa_main_binary_release "$sha" "$root" "$stage" 2>"$rerr"); then rm -f "$rerr"; printf '%s\n' "$out"; return 0; fi
  why_release=$(tail -1 "$rerr" 2>/dev/null); rm -f "$rerr"
  if out=$(wa_main_binary_build "$sha" "$root" "$target"); then printf '%s\n' "$out"; return 0; fi
  echo "wa_main_binary: NO BINARY OF ${sha:0:12} - release: ${why_release:-none}; build: ${target}; the installed binary (~/.local/bin/wa) is NOT used" >&2
  return 1
}

# A LOOP THAT NEVER GRADES MUST BARK. Two tips in a row that could not be graded is the alarm, because one can
# be a release that is still publishing; two is a resolver that cannot see anything.
wa_note_ungraded() { # <sha> [state-dir]  -> rc 0 quietly, rc 1 when ATTENTION is due (and prints the count)
  local sha=$1 dir=${2:-$HOME/.wasm-agent/health} f n
  mkdir -p "$dir" 2>/dev/null || true
  f=$dir/health-ungraded; touch "$f"
  grep -qx "${sha:0:12}" "$f" || printf '%s\n' "${sha:0:12}" >> "$f"
  n=$(grep -c . "$f")
  if [ "$n" -ge 2 ]; then printf '%s\n' "$n"; return 1; fi
  return 0
}
wa_note_graded() { rm -f "${1:-$HOME/.wasm-agent/health}/health-ungraded"; }
