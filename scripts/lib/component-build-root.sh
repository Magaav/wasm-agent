#!/usr/bin/env bash
# WHERE A COMPONENT BUILD HAPPENS, WHAT BUILDS IT, AND WHETHER THIS RUN MAY CLAIM THE PIN.
#
# WHY THIS IS A FILE OF ITS OWN. Both facts are part of the artifact, so the build, the publisher and the
# check that a fresh build is the pin have to agree on them exactly. Three copies of a constant is how the
# first cut of this went wrong: the root was `${TMPDIR:-/tmp}/wa-component-build`, which is one path only
# where TMPDIR is unset - macOS always sets it, so does many a container and CI runner - and a build there
# is a different path and therefore different bytes, with nothing saying so.
#
# So: ONE LITERAL PATH per OS family (below), `WA_COMPONENT_BUILD_ROOT` as the only override, and
# components.lock records the pair it was made with (`# TOOLCHAIN:`, `# BUILD-ROOT:`). A run that would
# build somewhere else is refused BY NAME - `build_root_mismatch` / `toolchain_mismatch` - instead of
# producing different bytes that then read as a mystery drift.
#
# WHAT THE PINS MEAN ON ANOTHER OS. The root reaches the artifact through Cargo's `-C metadata`, a hash of
# the canonical absolute path of a path package (measured 23/11: `libwa_mesh_core-8ee54b00c7a6cacd.rlib` at
# one path, `-cf7108a003359ad6.rlib` at another, same source, same compiler). `/tmp/wa-component-build` and
# `C:/wa-component-build` are different strings, so a Windows build cannot be the Linux pins: it builds and
# installs, but anything comparing bytes to this lock refuses with `build_root_mismatch` rather than
# reporting a difference. That is the honest statement, not a limitation to hide.
#
# Sourced by scripts/build-components.sh, scripts/publish-components.sh and
# scripts/test-component-lock-rebuild.sh.

# The one literal default. A bare `/tmp/...` on POSIX (not `$TMPDIR`, not `$HOME`), and one drive-rooted
# path on Windows - both chosen as the same string on every machine of that family.
wa_component_build_root_default() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) printf '%s' 'C:/wa-component-build' ;;
    *)                    printf '%s' '/tmp/wa-component-build' ;;
  esac
}

# The root THIS run builds in.
wa_component_build_root() { printf '%s' "${WA_COMPONENT_BUILD_ROOT:-$(wa_component_build_root_default)}"; }

wa_component_sha() { # <file>
  if command -v sha256sum >/dev/null 2>&1; then sha256sum < "$1" | awk '{print $1}'; else shasum -a 256 < "$1" | awk '{print $1}'; fi
}
wa_component_sha_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi
}

# The content hash a tree is named by: every file's name and bytes, in one order, on every machine.
wa_component_tree_hash() { # <dir>
  ( cd "$1" || return 1; find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum ) | wa_component_sha_stdin | cut -c1-16
}

# stat(1) is GNU on Linux and BSD on macOS; one caller, two spellings.
_wa_component_stat() { # <gnu-format> <bsd-format> <path>
  if stat -c '%a' "$3" >/dev/null 2>&1; then stat -c "$1" "$3"; else stat -f "$2" "$3"; fi
}

# A directory this process may build in: created 0700 when absent, and when it is already there it must be
# a real directory, owned by this user, and not writable by group or other. A fixed, guessable directory
# under a shared /tmp is exactly where another local user can prepare something for us to build in, so
# every one of those is a named refusal - never a chmod, never a warning.
wa_component_build_root_prepare() { # <dir>
  local dir="$1" owner perm last3 bits
  if [ -L "$dir" ]; then
    printf 'build_root_is_a_symlink: %s is a symlink; a build root has to be a directory this process owns (remove it, or set WA_COMPONENT_BUILD_ROOT to a fresh directory)\n' "$dir" >&2
    return 1
  fi
  if [ ! -e "$dir" ]; then
    mkdir -m 700 -- "$dir" 2>/dev/null || { printf 'build_root_unwritable: cannot create %s 0700 (a parent is missing or not writable by this user)\n' "$dir" >&2; return 1; }
    [ -L "$dir" ] && { printf 'build_root_is_a_symlink: %s appeared as a symlink while it was being created\n' "$dir" >&2; return 1; }
  fi
  if [ ! -d "$dir" ]; then
    printf 'build_root_not_a_directory: %s exists and is not a directory\n' "$dir" >&2; return 1
  fi
  owner="$(_wa_component_stat '%u' '%u' "$dir")"
  if [ "$owner" != "$(id -u)" ]; then
    printf 'build_root_not_owned: %s is owned by uid %s, this build runs as uid %s; a directory another user owns is not a place to build in (remove it with sudo, or set WA_COMPONENT_BUILD_ROOT to a directory this user owns)\n' "$dir" "$owner" "$(id -u)" >&2
    return 1
  fi
  perm="$(_wa_component_stat '%a' '%Lp' "$dir")"
  last3="${perm: -3}"
  bits=$((8#$last3))
  if [ $((bits & 8#022)) -ne 0 ]; then
    printf 'build_root_group_or_world_writable: %s has mode %s; only this user may write it (chmod 700 %s, or set WA_COMPONENT_BUILD_ROOT to a fresh directory)\n' "$dir" "$perm" "$dir" >&2
    return 1
  fi
  return 0
}

# The toolchain the pins were made with: components.lock's own line, else the constant this tree shipped
# with before the line existed.
wa_component_lock_toolchain() { # <repo-root>
  local t
  t="$(awk '/^# TOOLCHAIN: /{print $3; exit}' "$1/components.lock" 2>/dev/null)"
  printf '%s' "${t:-1.99.1}"
}
wa_component_lock_build_root() { # <repo-root>
  awk '/^# BUILD-ROOT: /{print $3; exit}' "$1/components.lock" 2>/dev/null
}

# Does THIS run build where the lock's bytes were made, with the compiler that made them?
# 0 they agree; 1 they do not (both refusals printed, each naming the mismatch); 2 the lock does not say.
wa_component_build_inputs_match_lock() { # <repo-root> <lock-toolchain> <lock-root>
  local repo="$1" want_root want_tool got_root got_tool rc=0
  want_root="$(wa_component_lock_build_root "$repo")"
  want_tool="$(wa_component_lock_toolchain "$repo")"
  got_root="$(wa_component_build_root)"
  got_tool="${WA_COMPONENT_TOOLCHAIN:-$(wa_component_lock_toolchain "$repo")}"
  if [ -z "$want_root" ]; then
    printf 'lock_does_not_record_the_build_root: %s/components.lock has no `# BUILD-ROOT:` line, so a build here cannot say whether it is where the pins were made\n' "$repo" >&2
    return 2
  fi
  if [ "$want_root" != "$got_root" ]; then
    printf 'build_root_mismatch: components.lock pins the build made in %s, this run builds in %s. The root reaches the bytes through Cargo -C metadata, so these cannot be the pinned bytes. Remove WA_COMPONENT_BUILD_ROOT (or set it to %s), or repin deliberately from a build there.\n' "$want_root" "$got_root" "$want_root" >&2
    rc=1
  fi
  if [ "$want_tool" != "$got_tool" ]; then
    printf 'toolchain_mismatch: components.lock pins the build made with rustc %s, this run builds with %s. Unset WA_COMPONENT_TOOLCHAIN to use the pinned one.\n' "$want_tool" "$got_tool" >&2
    rc=1
  fi
  return "$rc"
}

