#!/usr/bin/env bash
# One answer to "which commit is installed here", and one answer to "may this replace it".
#
# Sourced, never executed, and side-effect free: functions only, so a caller that runs with "set -e" is not
# disturbed and nothing happens just because this file was read.
#
# WHY THIS FILE EXISTS, in one measurement. On 18/11 the node on "work" ran a binary built from 8 commits
# that were on no landed branch, shipped by a script from a detached HEAD, and its installed.txt said
# commit=14963b6f - the id of an OLDER landed commit that those 8 contained. A sentinel deploy of main then
# replaced it and removed features that had been working. Two things produced that: an install record
# written by the party that MEANT to install (a belief), and a downgrade guard that compared this tree
# against that belief instead of against the bytes that were running.
#
# So:
#
#   * the binary reports its own build (commit, tree, dirty, and the commits it contains) - "wa --build-info"
#     and "wa --contains <commit>", compiled in by rust/wa-host/build.rs - and EVERY install path writes
#     installed.txt from that answer, never from the commit the caller had in mind. wa_record_install is the
#     one writer, and it drops any identity field a caller tries to hand it.
#   * the ancestry question ("does the target contain what is running?") is asked by wa_ancestry_verdict,
#     about the RUNNING binary. A caller passes what it has: a repository (a tree install, answered by git,
#     which can also name the commits that would be lost) or the target binary (a release install, answered
#     from its embedded ancestry, with no checkout on the node).
#
# One rule, two sources of evidence, and a verdict vocabulary the callers share: yes (0), no (1), cannot
# tell (2). A "cannot tell" is never treated as a "no": refusing because you are ignorant would block the
# first install on a machine that never had one, and the guard exists to stop a KNOWN loss, not to stop
# installs.

# ---- the binary's own identity ---------------------------------------------------------------------

# wa_build_info <binary> -> the identity document on stdout; non-zero when the binary cannot answer.
#
# A binary older than --build-info does not refuse the flag, it RUNS it: the host hands unknown arguments to
# the Lua core, which may open the interpreter, the database and the node. So the probe is bounded, and a
# timeout tool that is absent means the probe is not made at all rather than made unbounded (a deploy that
# hangs on "what is installed" is worse than one that says it does not know).
WA_BUILD_INFO_TIMEOUT="${WA_BUILD_INFO_TIMEOUT:-20}"
wa_build_info() {
  local binary="${1:-}" out guard='' status
  [ -n "$binary" ] && [ -x "$binary" ] || return 1
  command -v timeout >/dev/null 2>&1 && guard=timeout
  [ -n "$guard" ] || return 1
  out="$(env -u WASM_AGENT_HOME -u WASM_AGENT_DB -u WASM_AGENT_LUA_ROOT -u WASM_AGENT_VAULT_URL \
        -u WASM_AGENT_VAULT_DIR -u WASM_AGENT_VAULT_KEYSTORE -u WASM_AGENT_VAULT_PASSPHRASE \
        "$guard" "$WA_BUILD_INFO_TIMEOUT" "$binary" --build-info 2>/dev/null)"
  status=$?
  [ "$status" = 0 ] || return 1
  case "$out" in *commit=*) printf '%s\n' "$out"; return 0 ;; esac
  return 1
}

# wa_build_field <document> <key> -> the value, or nothing when the document does not carry it.
wa_build_field() {
  printf '%s\n' "${1:-}" | sed -n "s/^$2=//p" | head -1 | tr -d '\r'
}

# wa_record_install <install-dir> <binary> [extra key=value lines...] -> writes <install-dir>/installed.txt
#
# The identity fields (commit, tree, dirty, build_info, built_epoch) come from the binary and ONLY from the
# binary: a caller that passes commit=... is ignored, because that is exactly the belief that made a record
# say 14963b6f for a binary of 8 unlanded commits. Everything else the caller passes (source, via, reason,
# hashes, install_dir) is appended in the order given.
#
# A binary that cannot answer is recorded as commit=unknown with build_info=absent: the record then says
# "nobody can tell", which the ancestry gate and verify-install.sh treat as unknown, instead of naming a
# commit nobody verified.
wa_record_install() {
  local dir="${1:-}" binary="${2:-}"
  [ "$#" -ge 2 ] && shift 2
  [ -n "$dir" ] || return 2
  [ -d "$dir" ] || return 2
  local info='' commit=unknown tree=unknown dirty=unknown source=unknown epoch=unknown ancestors=unknown available=absent
  local tmp line stamp
  if info="$(wa_build_info "$binary")"; then
    available=yes
    commit="$(wa_build_field "$info" commit)"; [ -n "$commit" ] || commit=unknown
    tree="$(wa_build_field "$info" tree)"; [ -n "$tree" ] || tree=unknown
    dirty="$(wa_build_field "$info" dirty)"; [ -n "$dirty" ] || dirty=unknown
    source="$(wa_build_field "$info" source)"; [ -n "$source" ] || source=unknown
    epoch="$(wa_build_field "$info" built_epoch)"; [ -n "$epoch" ] || epoch=unknown
    ancestors="$(wa_build_field "$info" ancestors)"; [ -n "$ancestors" ] || ancestors=unknown
  fi
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
  tmp="$dir/.installed.txt.record.$$"
  {
    printf 'commit=%s\n' "$commit"
    printf 'branch=%s\n' "$(wa_build_branch_hint "$dir")"
    printf 'dirty=%s\n' "$dirty"
    printf 'tree=%s\n' "$tree"
    printf 'build_info=%s\n' "$available"
    printf 'build_source=%s\n' "$source"
    printf 'built_epoch=%s\n' "$epoch"
    printf 'contains_commits=%s\n' "$ancestors"
    printf 'recorded_utc=%s\n' "$stamp"
    for line in "$@"; do
      case "$line" in
        commit=*|tree=*|dirty=*|build_info=*|build_source=*|built_epoch=*|contains_commits=*|recorded_utc=*)
          # The identity is the binary's. A caller's commit= is not written, and the drop is named so a
          # reader can see the caller was not believed rather than silently corrected.
          printf 'dropped_caller_field=%s\n' "${line%%=*}"
          continue ;;
        '') continue ;;
      esac
      printf '%s\n' "$line"
    done
  } > "$tmp" || { rm -f "$tmp"; return 3; }
  mv -f "$tmp" "$dir/installed.txt" || { rm -f "$tmp"; return 3; }
  return 0
}

# The branch a record names, from a git checkout that happens to be above the install. It is a hint about
# the SOURCE, never about the bytes (the binary embeds no branch), so it is allowed to say nothing.
wa_build_branch_hint() {
  local dir="${1:-}" root
  root="$(dirname "$dir")"
  git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null | head -1 || true
}

# ---- may this replace that? ------------------------------------------------------------------------

# wa_ancestry_verdict <repository|""> <target-commit|""> <running-commit> <target-binary|"">
#   -> 0 the target contains the running commit (or nothing is running, or the same commit again)
#   -> 1 the target does NOT contain it: replacing would lose committed work
#   -> 2 cannot tell (no running commit, a commit neither source has, a shallow checkout, a binary that
#          carries no ancestry)
# Sets WA_ANCESTRY_LOST (one "short subject" line per commit that would be lost, when it can be named),
# WA_ANCESTRY_LOST_COUNT (how many, or unknown) and WA_ANCESTRY_WHY (a sentence for the refusal message).
wa_ancestry_verdict() {
  local repository="${1:-}" target="${2:-}" running="${3:-}" binary="${4:-}" status shallow
  WA_ANCESTRY_LOST=""
  WA_ANCESTRY_LOST_COUNT=0
  WA_ANCESTRY_WHY=""
  running="$(printf '%s' "$running" | tr -d '[:space:]')"
  if [ -z "$running" ] || [ "$running" = unknown ]; then
    WA_ANCESTRY_WHY="the running binary names no commit, so no committed work can be shown to be at risk"
    return 2
  fi
  if [ -n "$target" ] && [ "$running" = "$target" ]; then
    WA_ANCESTRY_WHY="the target is the running commit"
    return 0
  fi
  # 1. git, when this machine holds the repository: authoritative, and the only source that can name the
  #    commits that would be lost (which is what a refusal has to list to be actionable).
  if [ -n "$repository" ] && git -C "$repository" rev-parse --git-dir >/dev/null 2>&1; then
    if ! git -C "$repository" cat-file -e "$running^{commit}" 2>/dev/null; then
      WA_ANCESTRY_WHY="commit $running is not in $repository (a shallow clone, another repository, or a branch that was never fetched)"
      return 2
    fi
    if git -C "$repository" merge-base --is-ancestor "$running" "${target:-HEAD}" 2>/dev/null; then
      return 0
    fi
    shallow="$(git -C "$repository" rev-parse --is-shallow-repository 2>/dev/null || echo false)"
    if [ "$shallow" = true ]; then
      WA_ANCESTRY_WHY="this checkout is shallow, so a missing ancestor is this tree's ignorance rather than a downgrade"
      return 2
    fi
    # Bounded: a refusal a reader cannot finish is a refusal nobody reads, so the count is stated beside
    # the trimmed list.
    WA_ANCESTRY_LOST="$(git -C "$repository" log --oneline --no-decorate "$running" --not "${target:-HEAD}" 2>/dev/null | head -20)"
    WA_ANCESTRY_LOST_COUNT="$(git -C "$repository" rev-list --count "$running" --not "${target:-HEAD}" 2>/dev/null || echo unknown)"
    WA_ANCESTRY_WHY="commit $running is not an ancestor of ${target:-HEAD}"
    return 1
  fi
  # 2. the target binary's own embedded ancestry (a release install: the node has no checkout at all).
  if [ -n "$binary" ] && [ -x "$binary" ]; then
    "$binary" --contains "$running" >/dev/null 2>&1
    status=$?
    case "$status" in
      0) return 0 ;;
      1) WA_ANCESTRY_WHY="the target binary does not contain commit $running"
         WA_ANCESTRY_LOST="$(printf '%s' "$running" | cut -c1-12) (the target carries no checkout, so it cannot name the commits it would drop)"
         WA_ANCESTRY_LOST_COUNT=unknown
         return 1 ;;
      *) WA_ANCESTRY_WHY="the target binary cannot answer whether it contains $running"
         return 2 ;;
    esac
  fi
  WA_ANCESTRY_WHY="neither a repository nor a target binary was given"
  return 2
}
