#!/usr/bin/env bash
# The node's OWN pin store, read by the scripts that install on it.
#
# WHY THIS FILE EXISTS. A pin is the record an operator writes when they put a node somewhere on purpose
# (lua/core/pins.lua). It lived in the COORDINATOR's store only, and that store is read by the coordinator's
# deploy-request gate (lua/core/remote_update.lua) and by the node's own Lua update path (lua/core/update.lua).
# An install started on the node by anything else - upgrade.sh, fleet-install.sh, linux/bootstrap.sh, a hand-run
# deploy - never looked at it, so the three hand-made rollbacks of 18/11 were undone by the ordinary install
# paths on the very machines that had been put back on purpose.
#
# So the node keeps its own copy (a rollback writes it: lua/core/remote_update.lua M.admit, refreshed with the
# restored commit when the outcome is read), and these four read it before replacing anything. "Cannot tell"
# refuses, because a pin this parser does not understand is a record the node does not understand either.
#
# THE FORMAT IS pins.lua's: one record per block of key=value lines, blank-line separated, and the LAST record
# for a node is the one in force (state=active keeps it, state=cleared releases it). A record may name the node by
# its name (node=work) or its id (node_id=3f2a...), and a pin written under one is found by the other - that is
# what "resolve aliases to node ids before gating" means in practice.
#
# Sourced, never executed: functions only.

# wa_pins_file -> the store this node reads: <WASM_AGENT_HOME>/.wasm-agent/pins.txt, as lua/core/paths.lua.
wa_pins_file() {
  local root="${WASM_AGENT_HOME:-${USERPROFILE:-$HOME}}"
  printf '%s/.wasm-agent/pins.txt\n' "$root"
}

# wa_node_name -> what this node calls itself: <config>/node.name (lua/core/nodes.lua), else the hostname.
wa_node_name() {
  local root="${WASM_AGENT_HOME:-${USERPROFILE:-$HOME}}" name=''
  name="$(sed -n '1{p;q}' "$root/.wasm-agent/node.name" 2>/dev/null | tr -d '\r\n')"
  if [ -z "$name" ]; then name="$(uname -n 2>/dev/null || hostname 2>/dev/null || echo '')"; fi
  printf '%s\n' "$name"
}

# wa_pin_field <block> <key> -> the value, or nothing.
wa_pin_field() {
  printf '%s\n' "${1:-}" | sed -n "s/^$2=//p" | head -1 | tr -d '\r'
}

# wa_node_pin_active <name|node_id> [<node_id>] -> the active record block on stdout, 0 when there is one.
# The LAST record whose state is set decides: a later clear supersedes an earlier pin, exactly as pins.lua reads.
wa_node_pin_active() {
  local key="${1:-}" id="${2:-}" file block state
  [ -n "$key" ] || [ -n "$id" ] || return 1
  file="$(wa_pins_file)"
  [ -f "$file" ] || return 1
  block="$(awk -v key="$key" -v id="$id" '
    BEGIN { RS = ""; best = "" }
    {
      node = ""; nid = ""; state = ""
      n = split($0, lines, "\n")
      for (i = 1; i <= n; i++) {
        line = lines[i]; gsub(/\r/, "", line)
        if (line ~ /^node=/) node = substr(line, 6)
        else if (line ~ /^node_id=/) nid = substr(line, 9)
        else if (line ~ /^state=/) state = substr(line, 7)
      }
      if (state == "") next
      hit = 0
      if (key != "" && (node == key || nid == key)) hit = 1
      if (id != "" && (nid == id || node == id)) hit = 1
      if (hit) best = $0
    }
    END { if (best != "") print best }
  ' "$file" 2>/dev/null)"
  [ -n "$block" ] || return 1
  state="$(wa_pin_field "$block" state)"
  [ "$state" = active ] || return 1
  printf '%s\n' "$block"
  return 0
}


# THE AWAIT THIS RECORD ACTUALLY NAMES (round-4 item 7). Before round 3 a pin DEFAULTED its await to the commit it
# rolled back from, so pins already written on live nodes carry await=<that commit> - and honouring it releases the
# pin on exactly the move it exists to stop. The files are NOT migrated (an append-only store a new build silently
# rewrites is a worse risk than a rule at the read): an await equal to rolled_back_from is ignored unless the record
# says await_explicit=yes, which is what a record written by lua/core/pins.lua now carries when an OPERATOR named
# the commit. wa_pin_await_note is the one-line statement of that, printed once by the gate.
wa_pin_await_value() {
  local block="${1:-}" await from explicit
  await="$(wa_pin_field "$block" await)"
  [ -n "$await" ] || return 0
  from="$(wa_pin_field "$block" rolled_back_from)"
  explicit="$(wa_pin_field "$block" await_explicit)"
  if [ -n "$from" ] && [ "$await" = "$from" ] && [ "$explicit" != yes ]; then return 0; fi
  printf '%s' "$await"
}
wa_pin_await_note() {
  local block="${1:-}" await from explicit
  await="$(wa_pin_field "$block" await)"
  from="$(wa_pin_field "$block" rolled_back_from)"
  explicit="$(wa_pin_field "$block" await_explicit)"
  [ -n "$await" ] && [ -n "$from" ] && [ "$await" = "$from" ] && [ "$explicit" != yes ] || return 0
  printf 'node-pin: await=%s is IGNORED on this record: it is the commit the pin rolled back from, which is not a release (a legacy pin; nothing was rewritten)\n' "$(printf '%s' "$await" | cut -c1-12)"
}
# wa_pin_summary <block> -> one line a human (and a refusal) can act on.
wa_pin_summary() {
  local block="${1:-}" node commit reason until_ await from
  node="$(wa_pin_field "$block" node)"; [ -n "$node" ] || node="$(wa_pin_field "$block" node_id)"
  commit="$(wa_pin_field "$block" commit)"; [ -n "$commit" ] || commit=unknown
  reason="$(wa_pin_field "$block" reason)"
  until_="$(wa_pin_field "$block" until)"
  await="$(wa_pin_await_value "$block")"
  from="$(wa_pin_field "$block" rolled_back_from)"
  printf '%s pinned to %s' "${node:-?}" "$(printf '%s' "$commit" | cut -c1-12)"
  [ -n "$from" ] && printf ' (rolled back from %s)' "$(printf '%s' "$from" | cut -c1-12)"
  [ -n "$reason" ] && printf '; reason: %s' "$reason"
  [ -n "$until_" ] && printf '; until %s' "$until_"
  [ -n "$await" ] && printf '; awaits %s' "$(printf '%s' "$await" | cut -c1-12)"
  printf '\n'
}

# wa_pin_released <block> <target-commit> [<tree>] -> 0 released, 1 not, 2 cannot tell (never a release).
# Same three ways as lua/core/pins.lua M.released: the target IS the pinned commit, the target IS the awaited
# commit, or the target CONTAINS the awaited commit (asked of git in <tree>, when there is one).
wa_pin_released() {
  local block="${1:-}" target="${2:-}" tree="${3:-}" pinned await
  [ -n "$target" ] || return 2
  pinned="$(wa_pin_field "$block" commit)"
  [ -n "$pinned" ] && [ "$pinned" = "$target" ] && return 0
  await="$(wa_pin_await_value "$block")"
  [ -n "$await" ] || return 1
  [ "$await" = "$target" ] && return 0
  [ -n "$tree" ] && [ -d "$tree" ] || return 2
  command -v git >/dev/null 2>&1 || return 2
  git -C "$tree" cat-file -e "$await^{commit}" 2>/dev/null || return 2
  git -C "$tree" cat-file -e "$target^{commit}" 2>/dev/null || return 2
  if git -C "$tree" merge-base --is-ancestor "$await" "$target" 2>/dev/null; then return 0; fi
  return 1
}

# wa_pin_escape <node> [<pin block>] -> how to get out of a pin, in the words the CLI accepts.
# It names what releases THIS pin: a pin with no awaited commit is never released by an install (round-3
# item 2: await used to be defaulted to the commit a rollback went back from, so the next deploy of main
# released the pin on the move it was written to stop, and this sentence promised that).
wa_pin_escape() {
  local name="${1:-}" block="${2:-}" await=""
  [ -n "$name" ] || name='<node>'
  # No block handed over? Read the one that is in force, so the sentence is about THIS node's pin and not
  # about a pin in general.
  [ -n "$block" ] || block="$(wa_node_pin_active "$name" "")"
  [ -n "$block" ] && await="$(wa_pin_await_value "$block")"
  if [ -n "$await" ]; then
    printf "wa update %s --unpin --reason <text> (releases it and records why); or install a target that contains the awaited commit %s (that releases it by itself); or pass --force --reason <text> and it is recorded"       "$name" "$(printf '%s' "$await" | cut -c1-12)"
  else
    printf "wa update %s --unpin --reason <text> (releases it and records why); this pin names no awaited commit, so no ordinary install releases it; or pass --force --reason <text> and it is recorded" "$name"
  fi
}

# wa_node_pin_gate <name> [<node_id>] [<target-commit>] [<tree>]
#   -> 0 the node may move (no pin, or this target releases it) - one line on stdout says which
#   -> 3 the node is pinned and this target does not release it
# Prints the record either way, so a caller's refusal can quote it.
wa_node_pin_gate() {
  local name="${1:-}" id="${2:-}" target="${3:-}" tree="${4:-}" block note
  block="$(wa_node_pin_active "$name" "$id")" || return 0
  # one line, once, for a record whose await is the commit it rolled back from (round-4 item 7)
  note="$(wa_pin_await_note "$block")"
  [ -n "$note" ] && printf '%s\n' "$note"
  if [ -n "$target" ]; then
    wa_pin_released "$block" "$target" "$tree"
    case $? in
      0) printf 'node-pin: %s\nnode-pin: this move releases it: the target contains the awaited commit\n' "$(wa_pin_summary "$block")"; return 0 ;;
      *) : ;;
    esac
  fi
  printf 'node-pin: %s\n' "$(wa_pin_summary "$block")"
  return 3
}
