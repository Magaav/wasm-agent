#!/usr/bin/env bash
# WHERE THE COMPONENT BUILD'S RUSTC WRAPPER LIVES, AND WHETHER THIS MACHINE CAN RUN IT.
#
# WHY THIS FILE (24/11, work). The wrapper install lived inside scripts/build-components.sh and trusted two
# things it had not measured: that a file it found at the wrapper's path was executable, and that the
# directory it chose would allow executing anything at all. On work at 20:56Z the deploy's fallback build
# died with
#
#   could not execute process `wa-remap-rustc` ... Permission denied (os error 13)
#   error: component codemode did not compile; nothing installed
#
# after two minutes of toolchain fetch - a line that names neither the file, nor its mode, nor the
# directory, nor the mount. Two causes deserve the same fix and the old code could not tell them apart:
#
#   * a wrapper left at the content-addressed path by an earlier run without its execute bit - -f was the
#     only test, so the file was trusted and never repaired; and
#   * a wrapper directory this process may not execute files from: a noexec /tmp, a directory it does not
#     own, or one another user created first under a shared /tmp (/tmp/wa-remap-rustc/<hash> is a FIXED,
#     guessable path by design).
#
# So this file proves both facts about the directory it returns, refuses the ones it cannot use, and falls
# back to a directory it can - by name, in the build's own log. A build that cannot get a working wrapper
# says so in one line instead of dying inside cargo with Permission denied.
#
# STDOUT CARRIES THE DIRECTORY AND NOTHING ELSE (every refusal is on stderr): the caller is
# WRAPPER_DIR="$(wa_remap_wrapper_dir ...)", and a reason that landed on stdout became part of a PATH entry.
#
# The directory is NOT a build input: measured 24/11 (docs/COMPONENTS.md, "The wrapper's own directory comes
# from TMPDIR and does not reach the bytes") - RUSTC_WRAPPER is the bare name wa-remap-rustc, two TMPDIRs
# build the pinned graph bytes 0539d026..., and neither TMPDIR nor the wrapper's path appears in the
# artifact. A fallback therefore cannot move a pinned sha256. What it must not do is move silently: every
# refused candidate is printed with its reason, and WA_REMAP_DIR - an explicit request - is never replaced
# by another directory; an override that cannot be used is a refusal.
#
# Sourced by scripts/build-components.sh; exercised by scripts/test-component-build-wrapper.sh.

_wa_remap_lib_dir="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
if ! command -v wa_component_sha_stdin >/dev/null 2>&1; then
  . "$_wa_remap_lib_dir/component-build-root.sh"
fi

# The content hash of the wrapper's sources: a changed wrapper is a different path, an unchanged one is the
# same path in every checkout and after every reboot.
wa_remap_wrapper_hash() { # <tree-root>
  local root="$1"
  { cat "$root/rust/wa-remap-rustc/Cargo.toml" "$root/rust/wa-remap-rustc/src/main.rs" "$root/scripts/wa-remap-rustc"; } 2>/dev/null \
    | wa_component_sha_stdin | cut -c1-16
}

# <path> -> the mount a path lives on and its options, for the line that names a noexec directory.
wa_remap_mount_of() {
  local path="$1" mount_line
  [ -r /proc/mounts ] || return 0
  mount_line="$(awk -v p="$path" '$2 != "" && index(p, $2) == 1 { if (length($2) > best) { best = length($2); line = $0 } } END { print line }' /proc/mounts 2>/dev/null)"
  [ -n "$mount_line" ] && printf '%s (%s)' "$(printf '%s' "$mount_line" | awk '{print $2}')" "$(printf '%s' "$mount_line" | awk '{print $4}')"
}

# <dir> -> 0 when this process can execute a file that lives in <dir>; 1 when it cannot, with the reason on
# stderr. The probe is a file this function writes and runs: only that answers about the MOUNT and the MODE
# together - `test -x` on an existing file answers about its bits alone and says nothing about a noexec
# mount, which is the pair that failed on work.
wa_remap_dir_runs_files() { # <dir>
  local dir="$1" probe="$1/.exec-probe.$$" why
  if [ -L "$dir" ]; then printf 'wa_remap_dir_is_a_symlink: %s is a symlink\n' "$dir" >&2; return 1; fi
  if [ ! -d "$dir" ]; then printf 'wa_remap_dir_missing: %s is not a directory\n' "$dir" >&2; return 1; fi
  if ! : > "$probe" 2>/dev/null; then
    printf 'wa_remap_dir_unwritable: %s cannot be written by uid %s (owned by uid %s)\n' \
      "$dir" "$(id -u)" "$(_wa_component_stat '%u' '%u' "$dir" 2>/dev/null)" >&2
    return 1
  fi
  printf '#!/bin/sh\nexit 0\n' > "$probe" 2>/dev/null && chmod 755 "$probe" 2>/dev/null
  if "$probe" >/dev/null 2>&1; then rm -f "$probe"; return 0; fi
  rm -f "$probe"
  why="$(wa_remap_mount_of "$dir")"
  printf 'wa_remap_dir_noexec: a file in %s cannot be executed here (a noexec mount%s, or a directory whose files this process may not run); cargo would fail with `Permission denied (os error 13)`\n' \
    "$dir" "${why:+ on $why}" >&2
  return 1
}

# A directory only this user writes: created 0700 when absent (only a directory THIS function just made is
# chmod-ed; an existing one is never changed), and when it is already there it must be a real directory,
# owned by this user, and not writable by group or other. The wrapper's path is fixed and guessable by
# design, so under a shared /tmp another local user can create it first - and a wrapper another user can
# write is a compiler invocation another user chooses, whose bytes become a published artifact.
wa_remap_dir_private() { # <dir>
  local dir="$1" owner perm last3 bits
  if [ -L "$dir" ]; then printf 'wa_remap_dir_is_a_symlink: %s is a symlink\n' "$dir" >&2; return 1; fi
  if [ ! -e "$dir" ]; then
    mkdir -p -- "$dir" 2>/dev/null || {
      printf 'wa_remap_dir_unwritable: cannot create %s (a parent is missing, or is not writable by uid %s)\n' "$dir" "$(id -u)" >&2
      return 1; }
    # 0700 for the directory this call created; the parent chain is not touched beyond making it.
    chmod 700 -- "$dir" 2>/dev/null || {
      printf 'wa_remap_dir_unwritable: cannot set 0700 on the %s this call created\n' "$dir" >&2
      return 1; }
  fi
  [ -d "$dir" ] || { printf 'wa_remap_dir_not_a_directory: %s exists and is not a directory\n' "$dir" >&2; return 1; }
  owner="$(_wa_component_stat '%u' '%u' "$dir" 2>/dev/null)"
  if [ -n "$owner" ] && [ "$owner" != "$(id -u)" ]; then
    printf 'wa_remap_dir_not_owned: %s is owned by uid %s and this build runs as uid %s (set WA_REMAP_DIR to a directory this user owns)\n' \
      "$dir" "$owner" "$(id -u)" >&2; return 1
  fi
  perm="$(_wa_component_stat '%a' '%Lp' "$dir" 2>/dev/null)"
  last3="${perm: -3}"
  if [ -n "$last3" ]; then
    bits=$((8#$last3))
    if [ $((bits & 8#022)) -ne 0 ]; then
      printf 'wa_remap_dir_group_or_world_writable: %s has mode %s; only this user may write the wrapper directory (chmod 700 %s, or set WA_REMAP_DIR)\n' \
        "$dir" "$perm" "$dir" >&2; return 1
    fi
  fi
  return 0
}

# <tree-root> <dir> -> put the wrapper for these sources in <dir>, executable, and prove it. 1 with the reason
# on stderr when it cannot be done. A file that is already there is REUSED only when it can be run: a copy left
# without its execute bit is repaired here instead of being handed to cargo (the old -f test trusted it).
wa_remap_install_one() { # <tree-root> <dir>
  local root="$1" dir="$2" ext native file
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ext=".exe" ;; *) ext="" ;; esac
  file="$dir/wa-remap-rustc$ext"
  wa_remap_dir_private "$dir" || return 1
  if [ -f "$file" ] && [ ! -x "$file" ]; then
    printf 'wa_remap_wrapper_not_executable: %s exists without an execute bit (mode %s); reinstalling it\n' \
      "$file" "$(_wa_component_stat '%a' '%Lp' "$file" 2>/dev/null)" >&2
    rm -f "$file" 2>/dev/null || true
  fi
  if [ ! -x "$file" ]; then
    if [ -n "$ext" ]; then
      # The native twin is compiled, not a `.cmd`: cmd.exe re-parses every argument and refuses a command
      # line over 8191 characters, and windows-sys alone passes one --check-cfg argument naming ~250
      # features - that is what broke the wa-whatsapp build (rust/wa-remap-rustc/src/main.rs).
      ( cd "$root" && cargo build --release --manifest-path rust/wa-remap-rustc/Cargo.toml >/dev/null 2>&1 ) || {
        printf 'wa_remap_wrapper_build_failed: cargo could not build rust/wa-remap-rustc in %s\n' "$root" >&2; return 1; }
      native="${CARGO_TARGET_DIR:-$root/rust/target}/release/wa-remap-rustc.exe"
      case "$native" in /*|[A-Za-z]:/*|[A-Za-z]:\\*) ;; *) native="$root/$native" ;; esac
      [ -f "$native" ] || { printf 'wa_remap_wrapper_build_failed: the wrapper build produced no %s\n' "$native" >&2; return 1; }
      cp "$native" "$dir/.wa-remap-rustc$ext.tmp.$$" && chmod 755 "$dir/.wa-remap-rustc$ext.tmp.$$" \
        && mv "$dir/.wa-remap-rustc$ext.tmp.$$" "$file"
    else
      # A POSIX host needs no compile: the wrapper is the exec in scripts/wa-remap-rustc.
      cp "$root/scripts/wa-remap-rustc" "$dir/.wa-remap-rustc.tmp.$$" && chmod 755 "$dir/.wa-remap-rustc.tmp.$$" \
        && mv "$dir/.wa-remap-rustc.tmp.$$" "$file"
    fi 2>/dev/null || {
      printf 'wa_remap_wrapper_install_failed: cannot install %s (is %s writable by uid %s?)\n' "$file" "$dir" "$(id -u)" >&2
      return 1; }
  fi
  [ -x "$file" ] || { printf 'wa_remap_wrapper_not_executable: %s is installed without an execute bit\n' "$file" >&2; return 1; }
  printf 'wa_remap_wrapper_state: %s %s\n' "$([ -x "$file" ] && echo present)" "$dir" >&2
  return 0
}

# <tree-root> -> print a directory holding an executable wrapper for these sources, and say on stderr which
# one and why (installed or reused, and every candidate that was refused). 1 when no candidate can be used:
# the caller then fails with THIS line instead of cargo's Permission denied.
wa_remap_wrapper_dir() { # <tree-root>
  local root="$1" hash base dir ext file reused why state
  case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ext=".exe" ;; *) ext="" ;; esac
  hash="$(wa_remap_wrapper_hash "$root")"
  [ -n "$hash" ] || { printf 'wa_remap_wrapper_sources_unreadable: cannot read rust/wa-remap-rustc and scripts/wa-remap-rustc under %s\n' "$root" >&2; return 1; }
  if [ -n "${WA_REMAP_DIR:-}" ]; then
    # An explicit request is an explicit refusal: never replaced by another directory behind the operator.
    base="$WA_REMAP_DIR"
    dir="$base/$hash"
    if [ -x "$dir/wa-remap-rustc$ext" ]; then state="reused"; else state="installed"; fi
    wa_remap_install_one "$root" "$dir" || return 1
    wa_remap_dir_runs_files "$dir" || return 1
    printf 'component build wrapper: %s (%s; WA_REMAP_DIR; sources %s)\n' "$dir" "$state" "$hash" >&2
    printf '%s\n' "$dir"
    return 0
  fi
  for base in "${TMPDIR:-/tmp}/wa-remap-rustc" "${HOME:-/nonexistent}/.cache/wa-remap-rustc"; do
    dir="$base/$hash"
    if [ -x "$dir/wa-remap-rustc$ext" ]; then reused=1; else reused=0; fi
    if ! why="$(wa_remap_install_one "$root" "$dir" 2>&1 >/dev/null)"; then
      printf 'component build wrapper: %s is unusable, trying the next directory: %s\n' "$dir" "$why" >&2
      continue
    fi
    if ! why="$(wa_remap_dir_runs_files "$dir" 2>&1 >/dev/null)"; then
      printf 'component build wrapper: %s is unusable, trying the next directory: %s\n' "$dir" "$why" >&2
      continue
    fi
    if [ "$reused" = 1 ]; then state="reused"; else state="installed"; fi
    printf 'component build wrapper: %s (%s; sources %s)\n' "$dir" "$state" "$hash" >&2
    printf '%s\n' "$dir"
    return 0
  done
  printf 'wa_remap_wrapper_unusable: no directory on this machine can hold an executable wa-remap-rustc (%s and %s were refused; the reason for each is above). A component build needs it: set WA_REMAP_DIR to a directory this user owns on a filesystem that allows executing files, or build the components where they were pinned.\n' \
    "${TMPDIR:-/tmp}/wa-remap-rustc" "${HOME:-/nonexistent}/.cache/wa-remap-rustc" >&2
  return 1
}
