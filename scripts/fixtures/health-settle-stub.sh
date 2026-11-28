#!/bin/bash
# A RESOLVER STAND-IN for scripts/test-health-settles.sh: it refuses its first N asks and then hands back a
# complete-looking bundle for the tip, so the wait in factory/lib/main-binary.sh can be measured in seconds instead of
# the ten minutes a real publish takes. Everything it needs comes from the environment:
#   WA_SETTLE_CALLS   file that counts asks
#   WA_SETTLE_REFUSE  how many asks to refuse (default 0)
#   WA_SETTLE_BUNDLE  the dir to hand back
#   WA_SETTLE_TRIPLE  the target triple
#   WA_SETTLE_SHA     the tip's full commit id
wa_node_target_triple() { printf '%s\n' "${WA_SETTLE_TRIPLE:-x86_64-unknown-linux-gnu}"; }

wa_node_binary_source_resolve() {
  local n
  n=$(cat "${WA_SETTLE_CALLS:-/dev/null}" 2>/dev/null || echo 0)
  n=$((n + 1))
  [ -n "${WA_SETTLE_CALLS:-}" ] && printf '%s\n' "$n" > "$WA_SETTLE_CALLS"
  if [ "$n" -le "${WA_SETTLE_REFUSE:-0}" ]; then
    printf 'node_binary_missing: nothing published for %s yet (ask %s)\n' "${WA_SETTLE_SHA:0:12}" "$n" >&2
    return 8
  fi
  local short=${WA_SETTLE_SHA:0:12} triple=${WA_SETTLE_TRIPLE:-x86_64-unknown-linux-gnu}
  mkdir -p "$WA_SETTLE_BUNDLE" || return 2
  : > "$WA_SETTLE_BUNDLE/wa-$triple-$short"
  chmod +x "$WA_SETTLE_BUNDLE/wa-$triple-$short"
  printf '%s\n' "$WA_SETTLE_BUNDLE"
  printf 'release_tag=node-%s\nrelease_commit=%s\n' "$short" "$WA_SETTLE_SHA"
  return 0
}
