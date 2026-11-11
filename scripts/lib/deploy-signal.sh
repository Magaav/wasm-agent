#!/usr/bin/env bash
# The deploy-pending signal: one small file an installer writes before it waits, and every running turn
# reads at its next step boundary (lua/core/deploy_pause.lua).
#
# WHY A FILE. The installer and the turns run in different processes (the installer is a script beside
# the node; the turns are inside it), so the signal has to be durable and readable by both. It is not a
# control channel: a turn only reads it, and a marker past its own bound is ignored, so a crashed
# installer cannot freeze the node.
#
# The record is deliberately small and self-describing: state, since (epoch seconds), bound_seconds,
# who wrote it, the commits on both sides and the writer's pid. `scripts/test-deploy-signal.sh` checks
# the shape and the atomic write; `scripts/test-deploy-pause.lua` checks the reader's judgement.

wa_deploy_signal_dir() { # <data-dir>
  printf '%s' "${1:-${WASM_AGENT_DATA:-${WASM_AGENT_HOME:-$HOME}/.wasm-agent}}"
}

wa_deploy_signal_path() { # <data-dir>
  printf '%s/deploy-pending.json' "$(wa_deploy_signal_dir "$1")"
}

# Write the marker atomically: a reader either sees the previous file or the whole new one, never a
# half-written JSON document it would have to guess about.
wa_deploy_signal_write() { # <data-dir> <from> <to> <bound-seconds> [writer]
  local dir path tmp bound
  dir="$(wa_deploy_signal_dir "$1")"
  path="$(wa_deploy_signal_path "$1")"
  bound="${4:-900}"
  case "$bound" in ''|*[!0-9]*|0) bound=900 ;; esac
  mkdir -p "$dir" 2>/dev/null || return 1
  tmp="$path.tmp.$$"
  printf '{"state":"deploy_pending","since":%s,"bound_seconds":%s,"by":"%s","from":"%s","to":"%s","pid":%s}\n' \
    "$(date +%s)" "$bound" "${5:-upgrade.sh}" "${2:-unknown}" "${3:-unknown}" "$$" > "$tmp" 2>/dev/null || return 1
  mv -f "$tmp" "$path" 2>/dev/null || { rm -f "$tmp"; return 1; }
}

wa_deploy_signal_clear() { # <data-dir>
  local path
  path="$(wa_deploy_signal_path "$1")"
  rm -f "$path" "$path".tmp.* 2>/dev/null || true
}
