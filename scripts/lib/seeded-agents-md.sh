#!/usr/bin/env bash
# Retire a <config>/AGENTS.md that an old scripts/install.ps1 seeded from this repository.
#
# The node reads <config>/AGENTS.md as the user's own global instructions (pi-style; see
# project_instructions in lua/core/agent.lua). A seeded copy is a stale snapshot of the repo's
# file, injected on top of the real project file. Policy, in order:
#   - absent: nothing to do;
#   - byte-identical to a published AGENTS.md (scripts/lib/seeded-agents-md.sha256): renamed to
#     AGENTS.md.seeded-backup (or a timestamped name if that exists), with a log line;
#   - starts with a published AGENTS.md title but differs: an edited seed, so it is the user's
#     now - kept, with a visible warning saying how to retire it;
#   - anything else: the user's own file, untouched and silent.
# Never deletes. Usage: retire_seeded_agents_md <config-dir> [<hash-list>]
retire_seeded_agents_md() {
  local config="$1" list="${2:-$(dirname "${BASH_SOURCE[0]}")/seeded-agents-md.sha256}"
  local file="$config/AGENTS.md"
  [ -f "$file" ] || return 0
  if [ ! -r "$list" ]; then
    echo "seeded AGENTS.md: hash list $list unreadable; $file left as is" >&2
    return 0
  fi
  local hash
  hash="$( (sha256sum "$file" 2>/dev/null || shasum -a 256 "$file") | cut -d' ' -f1)"
  if grep -qx "$hash" "$list"; then
    local backup="$file.seeded-backup"
    [ -e "$backup" ] && backup="$file.seeded-backup.$(date +%Y%m%d%H%M%S)"
    if mv "$file" "$backup"; then
      echo "seeded AGENTS.md: $file was an unedited copy of the repo's AGENTS.md; moved to $backup"
    else
      echo "seeded AGENTS.md: could not move $file to $backup; it stays injected as global instructions" >&2
    fi
    return 0
  fi
  local title
  title="$(head -1 "$file" | tr -d '\r')"
  case "$title" in
    "# AGENTS.md — working on wasm-agent"|"## Operator-selected direct workflow (2026-10-05)")
      echo "seeded AGENTS.md: WARNING $file looks like an edited copy of the repo's AGENTS.md; it is kept and" >&2
      echo "  injected as your global instructions. Rename it if that is not intended." >&2
      ;;
  esac
  return 0
}
