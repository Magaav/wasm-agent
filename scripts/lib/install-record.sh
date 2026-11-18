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
# tell (2). A "cannot tell" is neither a "yes" nor a "no", and EVERY caller treats it as a refusal of the
# ordinary move: UNKNOWN REFUSES. It is not the same refusal as a known loss - it says what could not be
# established and how to establish it - and it is overridable only by --force --reason <text>, which is
# recorded. (An earlier revision let "cannot tell" through with a note, on the argument that refusing out of
# ignorance blocks installs; measured 18/11, that is what let a deploy replace a build of 8 uncommitted-to-main
# commits: the running commit was simply absent from the deployer's checkout, the verdict was 2, and the deploy
# went on.) The one thing that is NOT a refusal is a first install: no record and no binary naming a commit
# is not ignorance about a loss, it is a machine that never had one, and the callers check that case before
# they ask.

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

# wa_contains <binary> <commit> -> 0 it contains the commit, 1 it does not, 2 cannot tell.
#
# WHY THIS IS A FUNCTION AND NOT A LINE. `wa --contains <commit>` is compiled in by rust/wa-host/build.rs, and
# a binary older than the flag does not refuse it: the host hands unknown arguments to the Lua core, which may
# open the interpreter, the database and the node. So the probe is bounded, its environment is scrubbed (no
# WASM_AGENT_HOME, no WASM_AGENT_DB, no WASM_AGENT_LUA_ROOT) and it runs with a scratch HOME under a timeout, so
# the worst case is one bounded process that cannot touch this node's state. A probe that cannot be made at all
# (no timeout tool, no binary) answers 2 - and the callers refuse on 2, they never read it as "no".
WA_CONTAINS_TIMEOUT="${WA_CONTAINS_TIMEOUT:-20}"
wa_contains() {
  local binary="${1:-}" commit="${2:-}" guard='' scratch status
  [ -n "$binary" ] && [ -x "$binary" ] || return 2
  [ -n "$commit" ] || return 2
  command -v timeout >/dev/null 2>&1 && guard=timeout
  [ -n "$guard" ] || return 2
  scratch="$(mktemp -d 2>/dev/null)" || return 2
  env -u WASM_AGENT_HOME -u WASM_AGENT_DB -u WASM_AGENT_LUA_ROOT -u WASM_AGENT_VAULT_URL       -u WASM_AGENT_VAULT_DIR -u WASM_AGENT_VAULT_KEYSTORE -u WASM_AGENT_VAULT_PASSPHRASE       HOME="$scratch" TMPDIR="$scratch"       "$guard" "$WA_CONTAINS_TIMEOUT" "$binary" --contains "$commit" >/dev/null 2>&1
  status=$?
  rm -rf "$scratch" 2>/dev/null
  case "$status" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
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

# wa_record_describes <install-dir> <binary> -> 0 the record's sha256 is this binary's, 1 it is another binary's,
# 2 the record names no sha256 (nothing to compare).
#
# WHY THIS EXISTS. The guard asks the running binary what it is (wa --build-info). A binary older than that flag
# cannot answer, and the record is then the only evidence - and the record can be a lie. MEASURED 18/11 on this
# machine's own node and on work: installed.txt said commit=14963b6f and sha256=4248d61b while the bytes are
# fc6a9d80, and 14963b6f IS an ancestor of main, so the guard let a deploy of main replace a build of 8 unlanded
# commits. But a record that names another sha256 is provably not about these bytes: its commit= says nothing
# about what is running, and the guard must not read it as if it did.
wa_record_describes() {
  local dir="${1:-}" binary="${2:-}" recorded actual
  [ -n "$dir" ] && [ -n "$binary" ] && [ -f "$binary" ] || return 2
  recorded="$(sed -n 's/^sha256=//p' "$dir/installed.txt" 2>/dev/null | head -1 | tr -d '[:space:]')"
  [ -n "$recorded" ] || return 2
  command -v sha256sum >/dev/null 2>&1 || return 2
  actual="$(sha256sum < "$binary" 2>/dev/null | awk '{print $1}')"
  [ -n "$actual" ] || return 2
  [ "$recorded" = "$actual" ] && return 0
  return 1
}

# ---- how much of a history is here? ----------------------------------------------------------------

# wa_ancestry_truncated <repository> <commit> -> 0 the history BELOW <commit> was cut by a shallow clone.
#
# A positive ancestry answer survives a truncated history; a negative one does not. `git merge-base
# --is-ancestor` can only walk the links the clone carries, so on a shallow checkout "not an ancestor" may
# mean "the link that proves it is not here". The distinction is exact rather than a flag: a shallow
# repository is only a problem for THIS question when the walk from the commit in question reaches one of the
# commits in .git/shallow (the boundary); a commit whose walk ends at real roots is answered completely even
# inside a shallow clone. Without that refinement every shallow clone would turn every verdict into "cannot
# tell", including the ones it can answer.
wa_ancestry_truncated() {
  local repository="${1:-}" commit="${2:-}" gitdir boundary reached hit
  [ -n "$repository" ] && [ -n "$commit" ] || return 1
  gitdir="$(git -C "$repository" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  [ -n "$gitdir" ] || return 1
  boundary="$gitdir/shallow"
  [ -s "$boundary" ] || return 1
  reached="$(git -C "$repository" rev-list "$commit" 2>/dev/null)" || return 1
  [ -n "$reached" ] || return 1
  # A boundary commit among the commits the walk reached = the walk stopped early.
  printf '%s\n' "$reached" | sort -u > "$gitdir/wa-ancestry-reached.$$" || return 1
  tr -d '\r' < "$boundary" | sort -u > "$gitdir/wa-ancestry-boundary.$$"
  comm -12 "$gitdir/wa-ancestry-reached.$$" "$gitdir/wa-ancestry-boundary.$$" | grep -q .
  hit=$?
  rm -f "$gitdir/wa-ancestry-reached.$$" "$gitdir/wa-ancestry-boundary.$$"
  [ "$hit" = 0 ]
}

# wa_ancestry_fetch_missing <repository> <commit> -> 0 the commit is here now.
#
# A shallow checkout (a CI clone, a node that clones with --depth) does not carry the running build's history,
# and one bounded fetch is cheaper for an operator than a refusal they have to work around. Best-effort by
# design: the caller asks the verdict again afterwards, and a fetch that cannot reach the commit leaves the
# answer exactly as unknown as it was.
WA_ANCESTRY_FETCH_TIMEOUT="${WA_ANCESTRY_FETCH_TIMEOUT:-60}"
wa_ancestry_fetch_missing() {
  local repository="${1:-}" commit="${2:-}" guard=''
  [ -n "$repository" ] && [ -n "$commit" ] || return 1
  git -C "$repository" rev-parse --git-dir >/dev/null 2>&1 || return 1
  git -C "$repository" cat-file -e "$commit^{commit}" 2>/dev/null && return 0
  command -v timeout >/dev/null 2>&1 && guard=timeout
  if [ "$(git -C "$repository" rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
    if [ -n "$guard" ]; then
      "$guard" "$WA_ANCESTRY_FETCH_TIMEOUT" git -C "$repository" fetch --quiet --unshallow >/dev/null 2>&1 || true
    else
      git -C "$repository" fetch --quiet --unshallow >/dev/null 2>&1 || true
    fi
  fi
  git -C "$repository" cat-file -e "$commit^{commit}" 2>/dev/null && return 0
  if [ -n "$guard" ]; then
    "$guard" "$WA_ANCESTRY_FETCH_TIMEOUT" git -C "$repository" fetch --quiet origin "$commit" >/dev/null 2>&1 || true
  else
    git -C "$repository" fetch --quiet origin "$commit" >/dev/null 2>&1 || true
  fi
  git -C "$repository" cat-file -e "$commit^{commit}" 2>/dev/null
}


# ---- what is running here, and is the record evidence? --------------------------------------------

# wa_running_identity <install-dir>
# Sets, and prints nothing:
#   WA_RUNNING_BIN              the installed binary ("$dir/wa" or "$dir/wa.exe"), "" when there is none
#   WA_RUNNING_COMMIT           the commit that is running, per the binary, else per the record, "" if neither
#   WA_RUNNING_SOURCE           binary | record | record_mismatch | unprovable | none   (who named it, or why
#                               nobody can: unprovable = a binary IS installed and nothing proves which commit
#                               it is, which is UNKNOWN and refuses; none = nothing is installed at all)
#   WA_RUNNING_DIRTY            true | false | unknown      (the binary's own answer only)
#   WA_RUNNING_RECORD_COMMIT    the record's commit= as written ("" when the record has none)
#   WA_RUNNING_RECORD_IS_BYTES  yes | no | unknown          (is the record about THESE bytes?)
#   WA_RUNNING_WHY              one sentence for a refusal
#
# WHY ONE FUNCTION. Every install path - deploy.sh, upgrade.sh, fleet-install.sh, linux/bootstrap.sh,
# rollback-node.sh - has to answer the same question before it replaces anything, and on 18/11 they answered it
# differently: deploy.sh trusted installed.txt, fleet-install.sh and bootstrap.sh asked only the binary and
# treated "it cannot say" as free passage, upgrade.sh fell back to the record without checking that the record
# was about the running bytes. A record naming another sha256 is provably not this binary's (wa_record_describes),
# so its commit= is not evidence about what is running; a node with no record and no binary naming a commit is a
# first install, and that is the one case that is not ignorance.
wa_running_identity() {
  local dir="${1:-}" candidate info commit recorded
  WA_RUNNING_BIN=""
  WA_RUNNING_COMMIT=""
  WA_RUNNING_SOURCE="none"
  WA_RUNNING_DIRTY="unknown"
  WA_RUNNING_RECORD_COMMIT=""
  WA_RUNNING_RECORD_IS_BYTES="unknown"
  WA_RUNNING_WHY="nothing is installed in ${dir:-an unnamed directory}"
  for candidate in "$dir/wa" "$dir/wa.exe"; do
    [ -x "$candidate" ] && { WA_RUNNING_BIN="$candidate"; break; }
  done
  if [ -n "$WA_RUNNING_BIN" ] && info="$(wa_build_info "$WA_RUNNING_BIN")"; then
    commit="$(wa_build_field "$info" commit)"
    WA_RUNNING_DIRTY="$(wa_build_field "$info" dirty)"; [ -n "$WA_RUNNING_DIRTY" ] || WA_RUNNING_DIRTY=unknown
    if [ -n "$commit" ] && [ "$commit" != unknown ]; then
      WA_RUNNING_COMMIT="$commit"
      WA_RUNNING_SOURCE="binary"
      WA_RUNNING_WHY="the running binary reports it"
      return 0
    fi
    WA_RUNNING_WHY="the installed binary cannot name its own commit (a build with no git and no stamp)"
  fi
  recorded="$(sed -n 's/^commit=//p' "$dir/installed.txt" 2>/dev/null | head -1 | tr -d '\r[:space:]')"
  [ "$recorded" = unknown ] && recorded=""
  WA_RUNNING_RECORD_COMMIT="$recorded"
  [ -n "$recorded" ] && WA_RUNNING_WHY="the install record names it, and the binary could not be asked"
  if [ -n "$WA_RUNNING_BIN" ]; then
    wa_record_describes "$dir" "$WA_RUNNING_BIN"
    case $? in
      0) WA_RUNNING_RECORD_IS_BYTES=yes ;;
      1) WA_RUNNING_RECORD_IS_BYTES=no
         if [ -n "$recorded" ]; then
           WA_RUNNING_WHY="the install record names commit $recorded for sha256 $(sed -n 's/^sha256=//p' "$dir/installed.txt" 2>/dev/null | head -1 | cut -c1-12), but the binary is $(sha256sum < "$WA_RUNNING_BIN" 2>/dev/null | cut -c1-12) - the record is about other bytes"
         else
           WA_RUNNING_WHY="the install record carries no commit= and no sha256= for the binary at $WA_RUNNING_BIN"
         fi ;;
      *) WA_RUNNING_RECORD_IS_BYTES=unproven
         # A RECORD WITH commit= AND NO sha256= IS A BELIEF, NOT EVIDENCE. Before this, the record was used as
         # the fallback whenever the binary could not answer - and sha256= was only ever checked when it was
         # present, so a record that named no bytes at all was trusted precisely where trust is most expensive:
         # the install whose binary predates --build-info. Round 3, item 1.
         if [ -n "$recorded" ]; then
           WA_RUNNING_WHY="the install record names commit $recorded and carries no sha256=, so nothing ties that commit to the bytes at $WA_RUNNING_BIN"
         fi ;;
    esac
  elif [ -z "$recorded" ]; then
    WA_RUNNING_WHY="nothing is installed in $dir"
    return 0
  fi
  # A RECORD ABOUT THESE BYTES THAT NAMES NO COMMIT IS STILL NOT EVIDENCE (round-4 item 1). The test below used to
  # be "the record is not about these bytes", so a record whose sha256= IS the binary's and whose commit= is
  # empty or unknown (the two spellings are one fact; the read above blanks "unknown") fell THROUGH to the
  # fallback, found nothing to claim, and left source=none with no commit - and source=none is what every caller
  # reads as "a first install": deploy.sh installed over the node and printed "the override above was recorded as
  # ancestry_unverified=yes" with no override given. Fail-open, inside the sentence that is meant to explain a
  # refusal. The record proves it is about these bytes and says nothing about where they come from, which is
  # exactly UNKNOWN, and UNKNOWN refuses.
  if [ -n "$WA_RUNNING_BIN" ] && { [ "$WA_RUNNING_RECORD_IS_BYTES" != yes ] || [ -z "$recorded" ]; }; then
    # A BINARY IS INSTALLED AND NOTHING PROVES WHICH COMMIT IT IS. This used to be "source=none, commit empty",
    # and every caller read that as a FIRST INSTALL: deploy.sh printed "this is a first install, not a
    # downgrade", fleet-install.sh and bootstrap.sh said "a first install", and upgrade.sh had no else branch
    # at all - so an old binary that cannot report its build was replaceable for free, with no ancestry
    # question asked (round-3 item 1). It is not a first install: something is installed. It is UNKNOWN, and
    # UNKNOWN REFUSES unless the operator says --force --reason.
    #
    # The record names other bytes, so its commit= is NOT what is running. Saying it is would be the 18/11
    # mistake with the opposite sign: a commit that looks safe because it is old, for bytes nobody can name.
    WA_RUNNING_COMMIT=""
    if [ "$WA_RUNNING_RECORD_IS_BYTES" = no ]; then
      WA_RUNNING_SOURCE="record_mismatch"
    else
      WA_RUNNING_SOURCE="unprovable"
      if [ -z "$recorded" ]; then
        if [ "$WA_RUNNING_RECORD_IS_BYTES" = yes ]; then
          WA_RUNNING_WHY="the install record beside $WA_RUNNING_BIN is about these very bytes (its sha256= is the binary's) but names no commit=, and the binary cannot name its own commit either - so nothing ties these bytes to a place in history"
        else
          WA_RUNNING_WHY="the binary at $WA_RUNNING_BIN cannot name its own commit and there is no install record beside it"
        fi
      fi
    fi
    return 0
  fi
  if [ -n "$recorded" ]; then
    WA_RUNNING_COMMIT="$recorded"
    WA_RUNNING_SOURCE="record"
  fi
  return 0
}

# wa_running_first_install -> 0 when NOTHING is installed here: no binary at all. That is the only case that is
# a first install (round-3 item 1). A record with no binary names no bytes, so it is not an install either; a
# binary with no provable commit is "unprovable", which refuses.
wa_running_first_install() {
  [ -z "${WA_RUNNING_BIN:-}" ] && [ -z "${WA_RUNNING_COMMIT:-}" ]
}

# ---- may this replace that? ------------------------------------------------------------------------

# wa_ancestry_verdict <repository|""> <target-commit|""> <running-commit> <target-binary|""> [running-binary|""]
#   -> 0 the target contains the running commit (or nothing is running, or the same commit again)
#   -> 1 the target does NOT contain it: replacing would lose committed work
#   -> 2 cannot tell (no running commit, a commit neither source has, a truncated history, a binary that
#          carries no ancestry) - AND EVERY CALLER REFUSES ON IT without --force --reason.
# Sets WA_ANCESTRY_LOST (one "short subject" line per commit that would be lost, when it can be named),
# WA_ANCESTRY_LOST_COUNT (how many, or unknown) and WA_ANCESTRY_WHY (a sentence for the refusal message).
#
# The 5th argument is the RUNNING binary, and it is what makes a missing commit decidable without a checkout:
# `wa --contains <target>` asked of the running build says whether the running build already contains the
# target. If it does, and the two commits differ, the target cannot contain the running build (no commit is
# its own ancestor), so a loss is KNOWN from a single answer - the 18/11 question, answered by the bytes that
# were running.
wa_ancestry_verdict() {
  local repository="${1:-}" target="${2:-}" running="${3:-}" binary="${4:-}" running_binary="${5:-}"
  local status asked
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
    # (a) Ask the RUNNING binary, before any git answer can stand in the way. It carries its own ancestry and
    #     can answer one question: does the running build contain the target commit? If it does - and the two
    #     commits differ - then the target cannot contain the running build (no commit is its own ancestor), so
    #     the loss is known with no checkout at all. This is the answer 18/11 needed: the deployer's clone had
    #     never seen the node's build, and the node's own binary could have told it.
    asked=''
    if [ -n "$target" ] && [ -n "$running_binary" ] && [ -x "$running_binary" ]; then
      wa_contains "$running_binary" "$target"
      asked=$?
    fi
    if [ "$asked" = 0 ]; then
      WA_ANCESTRY_LOST="$(printf '%s' "$running" | cut -c1-12) (the running build: it contains the target commit $(printf '%s' "$target" | cut -c1-12), so the target cannot contain it)"
      WA_ANCESTRY_LOST_COUNT=unknown
      WA_ANCESTRY_WHY="the running binary reports that it already contains the target commit $target, so $target does not contain the running commit $running"
      return 1
    fi
    if [ -n "$target" ] && ! git -C "$repository" cat-file -e "$target^{commit}" 2>/dev/null; then
      WA_ANCESTRY_WHY="the target commit $target is not in $repository, and neither source says anything about it"
      return 2
    fi
    if ! git -C "$repository" cat-file -e "$running^{commit}" 2>/dev/null; then
      # THE RUNNING COMMIT IS NOT IN THIS HISTORY. This is the 18/11 case, and it used to answer "cannot
      # tell" for every cause at once: a shallow clone, another repository, a commit on no branch. It is not
      # one thing, and the difference decides whether a deploy may proceed. (The running binary has already
      # been asked above; a "no" from it is not evidence either way, so git decides what it can.)
      #
      # (b) A shallow checkout's ignorance is not evidence either way.
      if [ "$(git -C "$repository" rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
        WA_ANCESTRY_WHY="this checkout is shallow and does not carry commit $running, so what it can see says nothing about what would be lost (fetch the history: git fetch --unshallow; or ask the running binary, which carries its own ancestry)"
        return 2
      fi
      # (c) A FULL history that does not carry the running commit: the running build was never pushed into
      #     this history, so nothing that comes from here can contain it. In 18/11 terms: the node ran a build
      #     of 8 commits that were on no landed branch, and the deployer's clone had never seen them.
      WA_ANCESTRY_LOST="$(printf '%s' "$running" | cut -c1-12) (the running build: it is on no branch this repository has, so no target built here contains it)"
      WA_ANCESTRY_LOST_COUNT=unknown
      WA_ANCESTRY_WHY="commit $running is not in $repository at all: the running build is not in this history"
      return 1
    fi
    if git -C "$repository" merge-base --is-ancestor "$running" "${target:-HEAD}" 2>/dev/null; then
      return 0
    fi
    if wa_ancestry_truncated "$repository" "$running"; then
      WA_ANCESTRY_WHY="the history below commit $running was cut by this shallow clone, so 'not an ancestor' is this clone's ignorance rather than a downgrade (fetch the history: git fetch --unshallow)"
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
    wa_contains "$binary" "$running"
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
