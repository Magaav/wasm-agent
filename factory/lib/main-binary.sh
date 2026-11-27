#!/bin/bash
# WHICH BINARY MAY GRADE MAIN (Victor 27/11: no laptop install by default).
#
# The health loop judges main's tip by running main's own rows. It used to hand them `~/.local/bin/wa`,
# which is THE LAPTOP'S INSTALLED BUILD - and with the new rule that a landing does not install, that binary
# lags main, so a row that needs the new code goes red for a reason that has nothing to do with the tip. This
# file is the one answer to "which binary is main's": never the installed one.
#
#   wa_main_binary <sha>      prints the path, or nothing and a named reason on stderr; rc 1 when it cannot
#                             name one. Order:
#                             1. a PUBLISHED bundle for that sha (a node-<sha12> release on this host);
#                             2. the tree's own build, when its recorded build commit IS that sha;
#                             3. build it, in its own target dir (never in the checkout's release dir, so a
#                                health run cannot replace the binary a person is using);
#                             4. otherwise refuse, naming what was tried - a verdict from an unknown binary
#                                is worse than no verdict.
set -uo pipefail

wa_main_binary() { # <sha> [release-dir] [target-dir]
  local sha=${1:?usage: wa_main_binary <sha> [release-dir] [target-dir]}
  local rel=${2:-$HOME/.wasm-agent/releases}
  local target=${3:-$HOME/wasm-agent/health-target}
  local short=${sha:0:12} candidate=""

  # 1. A published bundle for exactly this sha. The release is named after the commit and carries the node
  #    built from it, so it is the tip's own bytes without a build here.
  for candidate in "$rel/node-$short/wa-x86_64-unknown-linux-gnu-$short" "$rel/node-$short/wa-x86_64-unknown-linux-gnu"; do
    if [ -x "$candidate" ]; then printf '%s\n' "$candidate"; return 0; fi
  done

  # 2. The tree's own build, when it says it is THIS commit. A build of another commit is exactly the
  #    failure this file exists to prevent, so it is not "close enough".
  local built="$target/release/wa"
  if [ -x "$built" ]; then
    local have
    have=$(WA_BIN="$built" "$built" --build-info 2>/dev/null | sed -n 's/^commit=//p' | head -1)
    if [ "$have" = "$sha" ]; then printf '%s\n' "$built"; return 0; fi
  fi

  # 3. Build it, in the target dir this file owns.
  if command -v cargo >/dev/null 2>&1; then
    local root
    root=$(git -C "${4:-$PWD}" rev-parse --show-toplevel 2>/dev/null) || root=""
    if [ -n "$root" ] && CARGO_TARGET_DIR="$target" cargo build --release --offline -p wa --manifest-path "$root/rust/Cargo.toml" >/dev/null 2>&1; then
      if [ -x "$built" ]; then printf '%s\n' "$built"; return 0; fi
    fi
    echo "wa_main_binary: tried the published bundle ${rel}/node-${short} and a build in ${target}, and neither produced ${short}" >&2
    return 1
  fi

  echo "wa_main_binary: no published bundle for ${short} and no cargo to build one; the installed binary (~/.local/bin/wa) is NOT used" >&2
  return 1
}
