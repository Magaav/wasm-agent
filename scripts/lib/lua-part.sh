#!/usr/bin/env bash
# THE LUA CORE AS A PART (Fable 25/11, _queue/lua-core-is-a-signed-part.md).
#
# WHY. Today the Lua tree rides inside the host artifact (rust/wa-host/build.rs embeds lua/core and lua/vendor),
# so a tree-less node downloads 55,570,056 bytes of program for a landing that changed only Lua - 54 of the 167
# landings of the last week were Lua-only. The tree is 5,545,620 bytes (1,654,295 as a .tar.gz), so making it a
# PART of the same lock turns that download into ~1.6 MB with no host build.
#
# THE LOCK LINE, in the shape components.lock already uses (`agent-core <sha256> <bytes>`, 11 pins today):
#
#   lua-core <sha256 of the part file> <bytes> interface=<capability digest>
#
# `interface=` is the interface VERSION, and it is not a new invention: the host already declares its capability
# surface (rust/wa-capabilities/src/capabilities.rs:373), the tree manifest already carries `capabilities <digest>`,
# and rust/wa-host already ignores a tree whose digest differs. What is new is that the PART DECLARES it as data,
# so a mismatch can be refused BY NAME BEFORE the pointer moves (both directions), instead of being noticed at
# start by a process that then silently falls back to the embedded copy.
#
# THE PART FILE: lua-core-<sha12>.tar.gz holding `manifest.txt` (the tree's own manifest: `capabilities <digest>`,
# `commit <sha>`, one `sha256  path` line per file) and the tree beside it - exactly what rust/wa-host reads from
# <install>/lua-core today (main.rs:95-125), so the host parses nothing new.
#
# WHAT THIS FILE DOES: read the lock, verify a part against it (bytes, digest, every file), declare its interface,
# and refuse a mismatch by name. It downloads nothing and moves no pointer: the switch is scripts/lib/versions.sh's
# business (a member is filled, then `wa_version_point`), and the download belongs to the publish/fetch step.

# <lock-file> <part> <field> -> the value, or nothing. Fields: sha256 bytes interface
wa_lua_part_lock_value() {
  local lock="${1:?lock}" part="${2:?part}" field="${3:?field}" line
  [ -f "$lock" ] || return 1
  line="$(sed -n "s/^[[:space:]]*${part}[[:space:]]\{1,\}//p" "$lock" | head -1)"
  [ -n "$line" ] || return 1
  case "$field" in
    sha256) printf '%s\n' "$(printf '%s' "$line" | awk '{print $1}')" ;;
    bytes)  printf '%s\n' "$(printf '%s' "$line" | awk '{print $2}')" ;;
    interface) printf '%s\n' "$(printf '%s' "$line" | tr ' ' '\n' | sed -n 's/^interface=//p' | head -1)" ;;
    *) return 1 ;;
  esac
}

# <part-file> <lock> -> 0 or a named refusal on stderr.
#   lua_part_missing          no such file
#   lua_part_not_pinned       the lock has no lua-core line
#   lua_part_size_mismatch    the file's size is not the lock's bytes
#   lua_part_digest_mismatch  its sha256 is not the lock's sha256
# The size is checked FIRST because it is cheap and catches a truncated download before hashing 1.6 MB.
wa_lua_part_verify_file() {
  local part="${1:?part file}" lock="${2:?lock}" want_sha want_bytes got_sha got_bytes
  [ -f "$part" ] || { printf 'lua_part_missing: %s\n' "$part" >&2; return 2; }
  want_sha="$(wa_lua_part_lock_value "$lock" lua-core sha256)" || { printf 'lua_part_not_pinned: %s has no lua-core line\n' "$lock" >&2; return 3; }
  want_bytes="$(wa_lua_part_lock_value "$lock" lua-core bytes)"
  got_bytes="$(wc -c < "$part" | tr -d '[:space:]')"
  if [ -n "$want_bytes" ] && [ "$got_bytes" != "$want_bytes" ]; then
    printf 'lua_part_size_mismatch: %s is %s bytes, the lock pins %s\n' "$part" "$got_bytes" "$want_bytes" >&2
    return 4
  fi
  got_sha="$(sha256sum < "$part" | awk '{print $1}')"
  if [ "$got_sha" != "$want_sha" ]; then
    printf 'lua_part_digest_mismatch: %s is %s, the lock pins %s\n' "$part" "$got_sha" "$want_sha" >&2
    return 5
  fi
  return 0
}

# <part-file> <lock> <destination-dir> -> 0, or a named refusal. Unpacks, then verifies EVERY file against the
# tree manifest's own `sha256  path` lines (the same check rust/wa-host does at start, done here BEFORE a pointer
# can name the tree). A path that escapes the destination is refused: a tarball is untrusted input.
wa_lua_part_unpack() {
  local part="${1:?part}" lock="${2:?lock}" dest="${3:?dest}" tmp line sha path bad=0
  wa_lua_part_verify_file "$part" "$lock" || return $?
  tmp="${dest}.unpack.$$"
  rm -rf "$tmp"; mkdir -p "$tmp" || { printf 'lua_part_dest_unwritable: %s\n' "$tmp" >&2; return 6; }
  tar xzf "$part" -C "$tmp" --no-same-owner 2>/dev/null \
    || { rm -rf "$tmp"; printf 'lua_part_unpack_failed: %s\n' "$part" >&2; return 7; }
  if [ ! -f "$tmp/manifest.txt" ]; then
    rm -rf "$tmp"; printf 'lua_part_manifest_missing: %s has no manifest.txt\n' "$part" >&2; return 8
  fi
  while IFS= read -r line; do
    case "$line" in
      capabilities\ *|commit\ *|'') continue ;;
      *'  '*) sha="${line%%  *}"; path="${line#*  }" ;;
      *) continue ;;
    esac
    case "$path" in /*|*..*) rm -rf "$tmp"; printf 'lua_part_unsafe_path: %s\n' "$path" >&2; return 9 ;;
    esac
    [ -f "$tmp/$path" ] || { printf 'lua_part_file_missing: %s\n' "$path" >&2; bad=1; continue; }
    [ "$(sha256sum < "$tmp/$path" | awk '{print $1}')" = "$sha" ] || { printf 'lua_part_file_mismatch: %s\n' "$path" >&2; bad=1; }
  done < "$tmp/manifest.txt"
  if [ "$bad" != 0 ]; then rm -rf "$tmp"; return 10; fi
  rm -rf "$dest"; mv -T "$tmp" "$dest" || { printf 'lua_part_dest_unwritable: %s\n' "$dest" >&2; return 6; }
  return 0
}

# <part-dir> <host-interface-digest> -> 0 or lua_part_interface_mismatch, BY NAME, in both directions: a part built
# for a host that offers more (or fewer) capabilities than this one is refused before anything switches.
wa_lua_part_interface() {
  local dir="${1:?part dir}" host="${2:?host interface digest}" needs
  needs="$(sed -n 's/^capabilities //p' "$dir/manifest.txt" 2>/dev/null | head -1 | tr -d '[:space:]')"
  [ -n "$needs" ] || { printf 'lua_part_interface_undeclared: %s/manifest.txt has no capabilities line\n' "$dir" >&2; return 2; }
  if [ "$needs" != "$host" ]; then
    printf 'lua_part_interface_mismatch: part needs %s, host offers %s\n' "$needs" "$host" >&2
    return 3
  fi
  return 0
}

# <part-file> <lock> <tree-dir> <host-interface-digest> -> 0, or a named refusal, and the tree-dir holds the part.
#
# This is the ONE call that puts a part into a version folder: verify it, unpack it beside where it will live, check
# the interface BOTH ways (the part names what it needs, the host names what it offers), and only then replace the
# tree. Nothing is written over a tree that has not passed all three - which is what makes "refuse before the switch"
# true rather than aspirational, because wa_version_point runs after this returns 0 and not before.
#
# The host interface is passed IN on purpose: today it comes from the running node's own tree manifest
# (sed -n 's/^capabilities //p' <install>/lua-core/manifest.txt) - the tree a host runs must already match the host,
# so it IS the host's declaration until a verb prints it. That verb (wa --interface) is the next commit.
wa_lua_part_fill() {
  local part="${1:?part}" lock="${2:?lock}" tree="${3:?tree dir}" host="${4:?host interface digest}" staging
  wa_lua_part_verify_file "$part" "$lock" || return $?
  staging="${tree}.part.$$"
  rm -rf "$staging"
  wa_lua_part_unpack "$part" "$lock" "$staging" || { rm -rf "$staging"; return $?; }
  if ! wa_lua_part_interface "$staging" "$host"; then
    # The part is refused BEFORE it can be named by a pointer, and nothing of the tree it would replace is touched.
    rm -rf "$staging"
    return 11
  fi
  rm -rf "$tree"
  mv -T "$staging" "$tree" || { printf 'lua_part_dest_unwritable: %s\n' "$tree" >&2; return 6; }
  printf 'lua_part_filled %s interface=%s\n' "$tree" "$host"
  return 0
}

# <program> -> the interface THAT PROGRAM declares, on stdout, or a named refusal.
#
# `wa --interface` is the declaration (commit 0cb4675c); taking it from the program that will RUN the tree is the
# only correct source. The earlier version of this file inferred it from a manifest, which is right only while a
# node already runs a tree - it says nothing about the NEW host a part is being prepared for.
#
#   lua_part_interface_undeclared_by_host   the program answered nothing like a digest
#   lua_part_host_missing                  the program is not there or not executable
wa_lua_part_host_interface() {
  local program="${1:?program}" answer
  [ -x "$program" ] || { printf 'lua_part_host_missing: %s
' "$program" >&2; return 2; }
  answer="$("$program" --interface 2>/dev/null | head -1)"
  case "$answer" in
    ''|*[!0-9a-f]*) printf 'lua_part_interface_undeclared_by_host: %s answered %s (it predates wa --interface?)
' "$program" "${answer:-<nothing>}" >&2
                    return 3 ;;
  esac
  [ "${#answer}" = 64 ] || { printf 'lua_part_interface_undeclared_by_host: %s answered %s characters, not a digest
' "$program" "${#answer}" >&2; return 3; }
  printf '%s
' "$answer"
  return 0
}
