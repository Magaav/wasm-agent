#!/bin/bash
# THE LOCK AND THE MEMBERS GO TOGETHER - one owner for that question, so a row and its test ask the same thing.
#
# 26dcbb41 deleted `members = [...]` from rust/Cargo.toml on 27/11 and nothing in the fast path noticed. With no
# members cargo wants the lock REWRITTEN, so every `--locked` build refuses ("cannot update the lock file ...
# because --locked was passed"); it surfaced hours later as a failed RELEASE PUBLISH, not as a red landing.
#
#   wa_cargo_lock_matches <root>   -> 0 when `cargo metadata --locked --offline` accepts the tree's lock,
#                                     1 and the first line of cargo's own refusal on stdout when it does not.
#
# Offline and locked on purpose: this runs inside a landing, where the registry may be unreachable and where a
# lock rewrite would be a change nobody asked for.
# WHERE CARGO IS: the same four places the health loop learned to look (factory/lib/main-binary.sh), because the
# loop's PATH has no toolchain and neither does a landing row's.
wa_cargo_bin() {
  local c=""
  for c in "${WA_MAIN_CARGO:-}" "$HOME/wasm-agent/toolchain/cargo/bin/cargo" "$HOME/.cargo/bin/cargo" \
           "$HOME/.local/share/mise/shims/cargo"; do
    [ -n "$c" ] && [ -x "$c" ] && { printf '%s\n' "$c"; return 0; }
  done
  c=$(command -v cargo 2>/dev/null) && [ -n "$c" ] && { printf '%s\n' "$c"; return 0; }
  return 1
}

wa_cargo_lock_matches() { # <root>
  local root=${1:?wa_cargo_lock_matches needs the tree root} out rc cargo_bin
  [ -r "$root/rust/Cargo.toml" ] || { echo "no rust/Cargo.toml under $root"; return 1; }
  cargo_bin=$(wa_cargo_bin) || { echo "no cargo to ask (looked in the toolchain, ~/.cargo, mise and PATH)"; return 1; }
  out=$("$cargo_bin" metadata --locked --offline --manifest-path "$root/rust/Cargo.toml" --format-version 1 2>&1 >/dev/null)
  rc=$?
  if [ "$rc" = 0 ]; then return 0; fi
  printf '%s\n' "$out" | grep -vE '^warning: profiles for the non root package|^package:|^workspace:' | head -3
  return 1
}
