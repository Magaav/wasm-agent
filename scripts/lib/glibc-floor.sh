#!/usr/bin/env bash
# The glibc floor, measured at BOTH ends: in the bytes a publisher is about to ship, and in the libc the
# host that installs them actually runs.
#
# WHY. 18/11, mail (Ubuntu, aarch64, glibc 2.35) was down for two days. The installed binary (commit
# 14963b6f) needed GLIBC_2.39 - it had been built on a host whose glibc was 2.39 and linked against it -
# and the sentinel retried 424 times on a message that says only "GLIBC_2.39 not found". The binary of
# 15/11 (842868c1) needed GLIBC_2.30, so nothing in the pipeline noticed the change. Neither the build nor
# the install asked the one question that catches it: *which glibc does this binary need, and which does
# this host have?* The node dies on a restart for a reason nobody can read, and because the node IS the
# channel you would fix it through, there is no way back in.
#
# So the question is asked twice, from ONE definition of the measurement:
#   * scripts/publish-node-binaries.sh reads the floor back out of every artifact and refuses to publish
#     one whose bytes need a newer glibc than its manifest claims (a pin is a promise to every node);
#   * scripts/fleet-install.sh, scripts/upgrade.sh and scripts/deploy.sh refuse such a binary BEFORE they
#     swap anything, naming both versions, so the installed binary keeps running and the operator reads
#     one sentence instead of a supervisor retry loop.
#
# ONE DEFINITION, ON PURPOSE, AND PROVED. The block between the two `wa-glibc-floor` markers is copied
# VERBATIM into scripts/fleet-install.sh, because that script is also handed out on its own - one file over
# curl, or a copy on a node without the lib - and a floor check that needs a lib beside it is a gate that is
# off exactly where it is needed (found in review of a9b60cc9: a standalone copy refused every install with
# `glibc_floor_lib_missing` instead of checking anything). scripts/test-glibc-floor.sh diffs the two blocks
# by their markers and fails on one differing line, so there is one implementation and not two that drift.
# Every other caller sources this file.
#
# WHAT THE MEASUREMENT IS, AND WHAT IT COSTS, is written down inside that block, so a standalone copy
# carries its own explanation.
#
# Sourced by scripts/publish-node-binaries.sh (via scripts/lib/node-binaries.sh's caller), scripts/upgrade.sh
# and scripts/deploy.sh; copied into scripts/fleet-install.sh. Exercised by scripts/test-glibc-floor.sh.

# wa-glibc-floor-begin
# THE MEASUREMENT AND THE GUARD - four functions, ONE behaviour, copied verbatim into
# scripts/fleet-install.sh between the same two markers (see the header of this file). Nothing in here may
# call anything outside this block: a standalone copy runs these four and nothing else.
#
# WHY THE MEASUREMENT IS A BYTE SCAN AND NOT `objdump -T`. A publisher reads artifacts of the OTHER
# architecture - that is what a cross build is - and `objdump` on the publishing host may not know a foreign
# machine (`objdump -T wa-aarch64` on an x86_64 binutils is "file format not recognized"). Every versioned
# symbol's name lives in the ELF's .dynstr as the literal string `GLIBC_<version>`, and the loader enforces
# the newest one, so `grep -a` over the bytes answers the same question for every artifact this project
# ships, on every host that can read a file. The cost of that shortcut, stated plainly: the scan counts ANY
# `GLIBC_x.y` string in the file, so a doc string, or an embedded copy of some other binary's floor, is read
# as a floor these bytes do not have, and a host below it would refuse a binary it can actually run.
# scripts/test-glibc-floor.sh measures the scan against `readelf -V`'s .gnu.version_r on real linked
# binaries - the check that catches such a string.

# Is this host's `sort` able to order versions? Answered by MEASURING an ordering only a version sort gets
# right - 2.9 below 2.10 - never by the name of the tool and never by a pair a byte sort also happens to
# get right (`2.2.5` vs `2.31` is that pair: a plain sort answers 2.31 too). Both ways a host can be
# without version order are caught here: a busybox `sort` REJECTS -V and every pipeline below answers
# nothing ("nothing" read as "not covered"), and a `sort` that ignores the flag silently answers byte
# order, which is wrong for 2.9 vs 2.10. Either way the comparison is "unknown" below, not "refused": it
# was a broken tool being blamed on every artifact in the fleet.
wa_glibc_sort_orders_versions() {
  [ "$(printf '%s\n%s\n' 2.9 2.10 | LC_ALL=C sort -V 2>/dev/null | tail -1)" = "2.10" ]
}

# <file> -> the newest glibc symbol version the file needs ("2.39"), empty when it needs none (a static
# binary, a PE, a shell script) or when this host cannot order the versions it finds. 2 when the file is not
# there.
#
# GLIBC_2.2.5 (the base every x86_64/aarch64 build needs) and GLIBC_2.31 are compared as VERSIONS, not as
# text: `sort -V` orders 2.2.5 below 2.31, and a plain sort puts "2.2.5" last ("2.2" > "2.3" byte-wise),
# which would report a floor of 2.2.5 as the newest thing in a 2.31 artifact. LC_ALL=C so a host's collation
# cannot change the answer `sort -V` gives.
wa_glibc_max_symbol() {
  local file="${1:-}" symbols newest
  [ -n "$file" ] && [ -f "$file" ] || return 2
  symbols="$(grep -a -o 'GLIBC_[0-9][0-9.]*[0-9]' "$file" 2>/dev/null | sed 's/^GLIBC_//')"
  [ -n "$symbols" ] || return 0
  newest="$(printf '%s\n' "$symbols" | LC_ALL=C sort -uV 2>/dev/null | tail -1)"
  if [ -z "$newest" ]; then
    # Symbol versions in the bytes and no way to order them here: "unknown" said out loud, on STDERR,
    # because a silent empty answer from this function reads as "the file needs nothing" - for a binary
    # that may need 2.39. The caller captures stdout, so STDERR is the channel the operator sees.
    printf 'glibc_floor_unknown: %s carries GLIBC symbol versions but this host\047s sort cannot order them (no -V), so its floor was not measured here; the exec/health proof downstream is the check that speaks for these bytes\n' \
      "$(basename "$file")" >&2
    return 0
  fi
  printf '%s\n' "$newest"
}

# <have> <need> -> 0 when <have> is at least <need>, as versions ("2.2.5" < "2.31" < "2.39"). 2 when the
# question cannot be answered here - a missing argument, or a `sort` with no version order - and 2 is
# "unknown", NOT "refused": the caller stands aside on 2 and lets the exec/health proof speak. A host whose
# `sort` has no -V refused every binary in this fleet before that distinction existed.
wa_glibc_covers() {
  local have="${1:-}" need="${2:-}" newest
  [ -n "$have" ] && [ -n "$need" ] || return 2
  wa_glibc_sort_orders_versions || return 2
  newest="$(printf '%s\n%s\n' "$have" "$need" | LC_ALL=C sort -V 2>/dev/null | tail -1)"
  [ -n "$newest" ] || return 2
  [ "$newest" = "$have" ]
}

# -> the host's glibc version ("2.35") on stdout, non-zero when this host has no glibc to compare with
# (musl, macOS, Windows). Called DIRECTLY (not in `$(...)`) it also sets the two globals the refusal
# sentence needs - `WA_GLIBC_HOST_VALUE` (the same version) and `WA_GLIBC_HOST_FROM` (where it came
# from). A command substitution runs in a subshell, so a caller that wants the "where from" half calls this
# directly and reads the globals; a caller that wants only the number may substitute it.
#
# `ldd --version` first, as the mission and the node's own operators read it ("ldd (GNU libc) 2.44",
# "ldd (Ubuntu GLIBC 2.35-0ubuntu3.8) 2.35"); the first `<major>.<minor>` in its first line is the version,
# including on the distributions that put the package version after it. A musl `ldd` answers "musl libc
# ... Version 1.2.5": that is NOT a glibc version and is refused as "unknown" instead of compared, because a
# glibc-linked binary cannot run there at all and the exec proof downstream is the check that can say so.
#
# WA_GLIBC_HOST stands in for the probe in fixtures only (the same pattern as WA_BOOTSTRAP_LIBC in
# scripts/linux/bootstrap.sh): a test cannot change the libc of the machine it runs on, and a check that can
# only be tested on one glibc version is not tested.
wa_glibc_host_version() {
  local out
  WA_GLIBC_HOST_FROM=''
  WA_GLIBC_HOST_VALUE=''
  if [ -n "${WA_GLIBC_HOST:-}" ]; then
    WA_GLIBC_HOST_FROM='WA_GLIBC_HOST, a fixture stand-in for `ldd --version`'
    WA_GLIBC_HOST_VALUE="$WA_GLIBC_HOST"
    printf '%s\n' "$WA_GLIBC_HOST"
    return 0
  fi
  if command -v ldd >/dev/null 2>&1; then
    out="$(ldd --version 2>&1 | head -1)"
    case "$out" in
      *musl*|*Musl*) return 1 ;;
    esac
    out="$(printf '%s\n' "$out" | grep -o '[0-9][0-9]*\.[0-9][0-9]*' | head -1)"
    if [ -n "$out" ]; then
      WA_GLIBC_HOST_FROM='ldd --version'
      WA_GLIBC_HOST_VALUE="$out"
      printf '%s\n' "$out"
      return 0
    fi
  fi
  if command -v getconf >/dev/null 2>&1; then
    out="$(getconf GNU_LIBC_VERSION 2>/dev/null)"
    case "$out" in
      glibc\ [0-9]*)
        WA_GLIBC_HOST_FROM='getconf GNU_LIBC_VERSION'
        WA_GLIBC_HOST_VALUE="${out#glibc }"
        printf '%s\n' "${out#glibc }"
        return 0 ;;
    esac
  fi
  return 1
}

# <binary> [<label>] -> 0 when this host can run it, or when the question cannot be asked here (no file, no
# glibc symbol in it, a host whose libc is not glibc, or no version order on this host's `sort` - the
# exec/health proof downstream is the check that speaks for those). 3 when the binary needs a newer glibc
# than this host has: the refusal sentence is printed on STDOUT, both versions in it, for the caller to
# print in its own vocabulary. An "unknown" is a note on STDERR and an ALLOW, never a refusal.
#
# The callers do NOT swap, restart or record anything before this returns 0 - that is the whole point:
# "GLIBC_2.39 not found" arrives once per supervisor retry on a node that is already dead, and there is no
# remote channel left to send a correction through.
wa_glibc_guard() {
  local file="${1:-}" label need have covered
  [ -n "$file" ] && [ -f "$file" ] || return 0
  label="${2:-$(basename "$file")}"
  need="$(wa_glibc_max_symbol "$file")" || return 0
  [ -n "$need" ] || return 0
  # Called directly, never in `$(...)`: the "where from" half lives in a global (a substitution would be a
  # subshell and the refusal would have to guess the probe's name).
  wa_glibc_host_version >/dev/null || return 0
  have="$WA_GLIBC_HOST_VALUE"
  [ -n "$have" ] || return 0
  wa_glibc_covers "$have" "$need"
  covered=$?
  case "$covered" in
    0) return 0 ;;
    2)
      # Both versions are known and the comparison is not: that is "unknown", so the bytes are allowed
      # through and the note goes where the operator reads it (a caller captures STDOUT and discards an
      # allow). Nothing is worse than a check that refuses a binary it simply could not measure.
      printf 'glibc_floor_unknown: %s needs GLIBC_%s and this host has glibc %s (%s), but this host cannot compare the two (its sort has no -V), so it was allowed through; the exec/health proof downstream is the check that speaks for it\n' \
        "$label" "$need" "$have" "${WA_GLIBC_HOST_FROM:-ldd --version}" >&2
      return 0 ;;
  esac
  printf 'glibc_floor_exceeded: %s needs GLIBC_%s and this host has glibc %s (%s), so it was refused before anything was replaced and the installed binary was left alone. The artifact was linked against a newer libc than this node runs: publish it with a floor this fleet can run (cargo zigbuild --target <triple>.<floor>), or install a static musl build\n' \
    "$label" "$need" "$have" "${WA_GLIBC_HOST_FROM:-ldd --version}"
  return 3
}
# wa-glibc-floor-end
