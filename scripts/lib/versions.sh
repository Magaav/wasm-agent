#!/usr/bin/env bash
# The version folders: one definition of where a version lives, what one is, and how it is made.
#
# WHY (Fable 24/11, slice (b), nine REQUIREMENTS - docs/UPDATE-DESIGN.md section 2.0). Today an install
# overwrites ~/.local/bin/wa and ~/.local/bin/lua-core in place while sessions run from them, and a
# rollback is a copy plus a restart. A version folder is a complete, immutable install that a process
# resolves ONCE from its own real executable path; "current" is a pointer, so a rollback is one rename.
#
# THE NINE, and where each one lives here:
#  1. WHERE: wa_share_root (ONE variable, WA_SHARE_ROOT; default the XDG data dir's wasm-agent), and
#     versions/<id> + current inside it, beside ui. <id> is the installed commit's sha12; the version's own
#     record (version.txt) also names binary_commit. Never in the PATH directory, never in ~/.wasm-agent.
#  2. A PROCESS IS ITS VERSION is the binary's shape (rust/wa-host/src/main.rs:88 resolves lua-core from
#     current_exe(), main.rs:130 holds it in a OnceLock): what makes it TRUE is that a version folder is
#     never edited, so wa_version_assemble refuses an id that exists instead of writing into it.
#  3. today's paths keep pointing at a version THROUGH the pointer: wa_version_link_legacy.
#  4. ONE atomic thing names current: wa_version_point (one rename over the link) and the record the
#     install already writes becomes a LINK into the version folder (wa_version_link_record), never a
#     second file written at switch time - two writes disagree after a cut.
#  5. MIGRATION per path, and what a cut leaves: see wa_version_link_legacy's order comments.
#  6. UNCHANGED FILES ARE HARD LINKS (wa_version_assemble links a member whose sha256 equals the previous
#     version's, else copies), folders are sealed read-only, and wa_version_disk reports REAL blocks.
#  7. RETENTION IS AUTOMATIC, N=3, after a healthy install; wa_version_prune refuses to remove current, the
#     one before it, a version a LIVE process runs from (its real /proc/<pid>/exe), or a pinned one.
#  8. THE SENTINEL's move and its old-supervisor fallback are the caller's order (deploy): this file only
#     makes sure the sentinel binary is a member of the same version folder.
#  9. REFUSE BEFORE STAGING: wa_version_need_bytes + wa_version_refuse_no_room, by name, before a byte is
#     written.
#
# Linux only, on purpose: Windows keeps the in-place install in this slice (requirement 9) and the launcher
# is not built untested. Everything here is builtins, ls/df/ln/cp/mv/sha256sum/readlink and /proc.

# 1. WHERE.
wa_share_root() { # -> the share root, no trailing slash. ONE variable names it.
  local root="${WA_SHARE_ROOT:-}"
  if [ -z "$root" ]; then
    local data="${XDG_DATA_HOME:-}"
    [ -n "$data" ] || data="${HOME:-}/.local/share"
    root="$data/wasm-agent"
  fi
  printf '%s\n' "${root%/}"
}
wa_versions_dir() { printf '%s/versions\n' "$(wa_share_root)"; }
wa_current_link() { printf '%s/current\n' "$(wa_share_root)"; }

# <commit> -> the version id (12 hex) or a refusal. Not a prefix guess: anything that is not a commit id is
# refused by name, because a folder named after a guess is a version nobody can resolve.
wa_version_id() {
  local commit="${1:-}"
  case "$commit" in
    '') printf 'version_id_invalid: empty commit\n' >&2; return 2 ;;
    *[!0-9a-f]*) printf 'version_id_invalid: %s is not a commit id\n' "$commit" >&2; return 2 ;;
  esac
  [ "${#commit}" -ge 12 ] || { printf 'version_id_invalid: %s is shorter than 12 hex\n' "$commit" >&2; return 2; }
  printf '%s\n' "${commit:0:12}"
}

# The version a folder records, or nothing. version.txt is the folder's own record (id, commit,
# binary_commit, assembled_utc, members).
wa_version_value() { # <version-dir> <field>
  sed -n "s/^$2=//p" "${1:-}/version.txt" 2>/dev/null | head -1
}

wa_version_dir() { # <id> -> the folder
  printf '%s/%s\n' "$(wa_versions_dir)" "${1:?id}"
}

# 9. THE DISK IS ASKED BEFORE ANYTHING IS WRITTEN.
#
# <staging-dir> [<previous-version-dir>] -> bytes this version will really add: a member whose relative path
# and sha256 match the previous version's is a link (no bytes), everything else is a copy. Folders cost
# nothing measurable here (a directory is one block), so they are not counted.
wa_version_need_bytes() {
  local stage="${1:-}" prev="${2:-}" total=0 path sha
  [ -d "$stage" ] || { printf 'version_need_unknown: no staging dir %s\n' "$stage" >&2; return 2; }
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ -n "$prev" ] && [ -f "$prev/$path" ]; then
      sha="$(sha256sum < "$stage/$path" 2>/dev/null | cut -d' ' -f1)"
      [ -n "$sha" ] && [ "$sha" = "$(sha256sum < "$prev/$path" 2>/dev/null | cut -d' ' -f1)" ] && continue
    fi
    total=$((total + $(wc -c < "$stage/$path")))
  done < <(cd "$stage" && find . -type f -printf '%P\n' | LC_ALL=C sort)
  printf '%s\n' "$total"
}

# <need-bytes> [<margin-bytes>] -> 0 when the share root's filesystem has room, else prints
# version_no_room free=<bytes> need=<bytes> margin=<bytes> and returns 3. The margin defaults to 512 MiB
# (WA_VERSION_MARGIN_BYTES), a working room for a node that keeps running while the install finishes.
wa_version_refuse_no_room() {
  local need="${1:?need}" margin="${2:-${WA_VERSION_MARGIN_BYTES:-536870912}}" root free avail
  root="$(wa_share_root)"
  mkdir -p "$root" 2>/dev/null || { printf 'version_root_unwritable: %s\n' "$root" >&2; return 4; }
  avail="$(df -P -k "$root" 2>/dev/null | awk 'NR==2 {print $4}')"
  case "$avail" in ''|*[!0-9]*) printf 'version_disk_unknown: df did not answer for %s\n' "$root" >&2; return 5 ;; esac
  free=$((avail * 1024))
  if [ "$free" -lt $((need + margin)) ]; then
    printf 'version_no_room free=%s need=%s margin=%s\n' "$free" "$need" "$margin" >&2
    return 3
  fi
  return 0
}

# 6. THE ASSEMBLER. <staging-dir> <id> [<previous-version-dir>]
#
# Copies or LINKS every member into versions/.staging-<id>, writes the folder's own record, seals the tree
# read-only and renames it into place - one rename, so versions/<id> is either complete or absent. The
# previous version is only read (for the sha256 comparison), never touched.
wa_version_assemble() {
  local stage="${1:?staging dir}" id="${2:?id}" prev="${3:-}" root versions tmp path sha linked copied
  case "$id" in ''|*[!0-9a-f]*) printf 'version_id_invalid: %s\n' "$id" >&2; return 2 ;; esac
  [ -d "$stage" ] || { printf 'version_staging_missing: %s\n' "$stage" >&2; return 2; }
  root="$(wa_share_root)"; versions="$(wa_versions_dir)"
  mkdir -p "$versions" || { printf 'version_root_unwritable: %s\n' "$versions" >&2; return 4; }
  [ ! -e "$versions/$id" ] || { printf 'version_exists: %s already names a version; a version is never rewritten\n' "$id" >&2; return 6; }
  tmp="$versions/.staging-$id"
  # A cut between the seal and the rename leaves this tree 0555 and read-only; rm -rf would then refuse forever and
  # every later install of that version would die with version_staging_unwritable (Fable fix 5). Make it writable
  # first - the tree is unfinished by definition.
  [ ! -d "$tmp" ] || chmod -R u+w "$tmp" 2>/dev/null || true
  rm -rf "$tmp" || { printf 'version_staging_unwritable: %s\n' "$tmp" >&2; return 4; }
  mkdir -p "$tmp" || { printf 'version_staging_unwritable: %s\n' "$tmp" >&2; return 4; }
  linked=0; copied=0
  # Directories first (find -depth order is the reverse: take the whole list once).
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    mkdir -p "$tmp/$path" || { printf 'version_staging_unwritable: %s\n' "$tmp/$path" >&2; return 4; }
  done < <(cd "$stage" && find . -mindepth 1 -type d -printf '%P\n' | LC_ALL=C sort)
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if [ -n "$prev" ] && [ -f "$prev/$path" ]; then
      sha="$(sha256sum < "$stage/$path" 2>/dev/null | cut -d' ' -f1)"
      if [ -n "$sha" ] && [ "$sha" = "$(sha256sum < "$prev/$path" 2>/dev/null | cut -d' ' -f1)" ] \
         && ln "$prev/$path" "$tmp/$path" 2>/dev/null; then
        linked=$((linked + 1)); continue
      fi
    fi
    cp -p "$stage/$path" "$tmp/$path" || { printf 'version_stage_failed: %s\n' "$path" >&2; return 4; }
    copied=$((copied + 1))
  done < <(cd "$stage" && find . -type f -printf '%P\n' | LC_ALL=C sort)
  # The folder's own record: the ONE place a version says what it is. binary_commit is recorded by the
  # caller (WA_VERSION_BINARY_COMMIT) because a covering release runs a binary built from another commit.
  {
    printf 'id=%s\n' "$id"
    printf 'commit=%s\n' "${WA_VERSION_COMMIT:-$id}"
    printf 'binary_commit=%s\n' "${WA_VERSION_BINARY_COMMIT:-}"
    printf 'install_dir=%s\n' "${WA_VERSION_INSTALL_DIR:-}"
    printf 'assembled_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'members=%s\n' "$((linked + copied))"
    printf 'linked=%s\n' "$linked"
    printf 'copied=%s\n' "$copied"
  } > "$tmp/version.txt" || { printf 'version_stage_failed: version.txt\n' >&2; return 4; }
  # Sealed read-only: a later install cannot edit a version in place even by accident (requirement 2).
  find "$tmp" -type d -exec chmod 0555 {} + 2>/dev/null || true
  find "$tmp" -type f -exec chmod a-w {} + 2>/dev/null || true
  mv -T "$tmp" "$versions/$id" || { printf 'version_rename_failed: %s\n' "$tmp" >&2; return 4; }
  printf 'version_assembled %s members=%s linked=%s copied=%s\n' "$id" "$((linked + copied))" "$linked" "$copied"
}

# 4. ONE ATOMIC THING. <id>: point current at versions/<id> with ONE rename. Readers see the old version or
# the new one, never a missing pointer, and nothing else is written.
wa_version_point() {
  local id="${1:?id}" versions current tmp
  versions="$(wa_versions_dir)"; current="$(wa_current_link)"
  [ -d "$versions/$id" ] || { printf 'version_absent: %s\n' "$versions/$id" >&2; return 2; }
  tmp="$current.tmp.$$"
  ln -sfn "versions/$id" "$tmp" || { printf 'version_pointer_unwritable: %s\n' "$tmp" >&2; return 4; }
  mv -T "$tmp" "$current" || { rm -f "$tmp"; printf 'version_pointer_failed: %s\n' "$current" >&2; return 4; }
  printf 'version_current %s\n' "$id"
}

wa_version_current() { # -> the id current names, or nothing
  local link id
  link="$(wa_current_link)"
  [ -L "$link" ] || return 1
  id="$(readlink "$link" 2>/dev/null)"
  printf '%s\n' "${id##*/}"
}

# 4. THE RECORD IS THE POINTER'S OWN FILE. <install-dir>: make <install>/installed.txt a LINK to
# current/installed.txt, so the pointer is the only thing that says which version is current. The previous
# record (if it was a real file) is kept as installed.txt.stale.<ts> - evidence, never the answer.
wa_version_link_record() {
  local install="${1:?install dir}" record="$1/installed.txt" current
  current="$(wa_current_link)"
  [ -f "$current/installed.txt" ] || { printf 'version_record_missing: %s/installed.txt\n' "$current" >&2; return 2; }
  if [ -L "$record" ]; then ln -sfn "$current/installed.txt" "$record" || return 4; printf 'version_record_linked %s\n' "$record"; return 0; fi
  if [ -f "$record" ]; then
    mv "$record" "$record.stale.$(date -u +%Y%m%dT%H%M%SZ)" || { printf 'version_record_busy: %s\n' "$record" >&2; return 4; }
  fi
  ln -s "$current/installed.txt" "$record" || { printf 'version_record_unwritable: %s\n' "$record" >&2; return 4; }
  printf 'version_record_linked %s\n' "$record"
}

# 3 + 5. TODAY'S PATHS THROUGH THE POINTER, and the order that keeps a cut survivable.
#
# FIX 4 (Fable 25/11): THE PROGRAM MUST NEVER BE ABSENT. The first version of this function moved each real path
# aside and then linked, so between the two renames there was no wa on PATH and no ExecStart - a node that could
# not start. Now:
#   - for a FILE (wa, wa-sentinel): the old copy is kept with a HARD LINK (no bytes, no copy), and the link through
#     the pointer is renamed OVER the file - one rename, the path always resolves;
#   - for a DIRECTORY (lua-core, scripts, ui): an atomic EXCHANGE where the system has it (coreutils mv --exchange,
#     i.e. renameat2 RENAME_EXCHANGE), and only when it does not, the two renames - and the function SAYS which one
#     it used, so the report can name it per machine.
# Nothing is deleted: the kept copies are <name>.stale.<ts>, listed by wa clean and removed only on command.

wa_version_has_exchange() { # 0 when this mv can exchange two paths atomically
  case "${WA_VERSION_EXCHANGE:-}" in
    1) return 0 ;; 0) return 1 ;;
  esac
  local probe
  probe="$(mktemp -d 2>/dev/null)" || return 1
  : > "$probe/a"; : > "$probe/b"
  if mv --exchange "$probe/a" "$probe/b" 2>/dev/null; then rm -rf "$probe"; WA_VERSION_EXCHANGE=1; return 0; fi
  rm -rf "$probe"; WA_VERSION_EXCHANGE=0; return 1
}

wa_version_link_legacy() { # <install-dir>
  local install="${1:?install dir}" share ts name target aside tmp
  share="$(wa_share_root)"; ts="$(date -u +%Y%m%dT%H%M%SZ)"
  for name in wa wa-sentinel; do
    target="$share/current/$name"; tmp="$install/$name.tmp.$$"
    [ -f "$target" ] || continue
    if [ -f "$install/$name" ] && [ ! -L "$install/$name" ]; then
      # The old bytes are kept by a HARD LINK (no copy), and the file itself is never moved away.
      [ -e "$install/$name.stale.$ts" ] || ln "$install/$name" "$install/$name.stale.$ts" 2>/dev/null ||         cp -p "$install/$name" "$install/$name.stale.$ts" 2>/dev/null || true
    fi
    ln -sfn "$target" "$tmp" && mv -T "$tmp" "$install/$name" || {
      rm -f "$tmp"; printf 'version_legacy_unwritable: %s
' "$install/$name" >&2; return 4; }
  done
  for name in lua-core scripts; do
    target="$share/current/$name"; tmp="$install/$name.tmp.$$"
    [ -d "$target" ] || continue
    ln -sfn "$target" "$tmp" || { printf 'version_legacy_unwritable: %s
' "$tmp" >&2; return 4; }
    if [ -d "$install/$name" ] && [ ! -L "$install/$name" ]; then
      if wa_version_has_exchange && mv --exchange "$tmp" "$install/$name" 2>/dev/null; then
        : # the link is in place and the old tree is now at $tmp: keep it under its own name
        mv -T "$tmp" "$install/$name.stale.$ts" 2>/dev/null && printf 'version_legacy_exchanged %s
' "$name"
      else
        aside="$install/$name.stale.$ts"
        mv "$install/$name" "$aside" || { rm -f "$tmp"; printf 'version_legacy_busy: %s
' "$install/$name" >&2; return 4; }
        mv -T "$tmp" "$install/$name" || { mv "$aside" "$install/$name"; printf 'version_legacy_unwritable: %s
' "$install/$name" >&2; return 4; }
        printf 'version_legacy_two_renames %s (this mv cannot exchange)
' "$name"
      fi
    else
      mv -T "$tmp" "$install/$name" || { rm -f "$tmp"; printf 'version_legacy_unwritable: %s
' "$install/$name" >&2; return 4; }
    fi
  done
  if [ -d "$share/ui" ] && [ ! -L "$share/ui" ] && [ -d "$share/current/ui" ]; then
    ln -sfn "current/ui" "$share/ui.tmp.$$" || return 4
    if wa_version_has_exchange && mv --exchange "$share/ui.tmp.$$" "$share/ui" 2>/dev/null; then
      mv -T "$share/ui.tmp.$$" "$share/ui.stale.$ts" 2>/dev/null && printf 'version_legacy_exchanged ui
'
    else
      mv "$share/ui" "$share/ui.stale.$ts" 2>/dev/null && mv -T "$share/ui.tmp.$$" "$share/ui" 2>/dev/null || true
      printf 'version_legacy_two_renames ui
'
    fi
  fi
  printf 'version_legacy_linked %s
' "$install"
}

# 6. THE RECORD IS THE POINTER'S OWN FILE - so a writer must never REPLACE it (Fable 25/11, fix 6).
#
# installed.txt is a symlink into current/ once a node is adopted. Every READER is unaffected (a link is
# transparent to read_file, cat, grep), but a writer that does the usual "write a temp file, mv it onto the
# record" REPLACES THE LINK with a regular file - and then the pointer and the record can disagree again, which is
# the exact defect requirement 4 removes. So the writers ask this first:
#
#   wa_version_refuse_record_replace <path>   0 when <path> is a regular file (or absent): writing it is fine,
#                                            4 and version_record_is_a_link when it is a LINK: write the record into
#                                            the staging tree instead and let version-install.sh link it.
wa_version_refuse_record_replace() {
  local path="${1:?record path}"
  [ -L "$path" ] || return 0
  printf 'version_record_is_a_link: %s points at the current version; write the record into the staging tree (WA_VERSION_STAGING) and let the install link it
' "$path" >&2
  return 4
}

# 5b. THE ROLLBACK MUST NOT WRITE THROUGH THE POINTER (Fable 25/11, fix d).
#
# upgrade.sh own rollback restores $BACKUP over $INSTALL_DIR/wa. Once a node is on a version folder that path is a
# LINK into the sealed current version, and a sealed version is read-only and never edited: the copy would either
# fail or (worse) replace the pointer's own file. So the restore asks this first, and the answer for a link is that
# the rollback IS a pointer move - which the deploy performs with wa_version_point, and which costs one rename.
#
#   wa_version_restore_program <installed-path> <backup-file>
#     0  restored (a regular file path: the live in-place install, unchanged behaviour)
#     3  version_rollback_is_a_pointer: the path is a link; move the pointer back instead
wa_version_restore_program() {
  local installed="${1:?installed path}" backup="${2:?backup}"
  if [ -L "$installed" ]; then
    printf 'version_rollback_is_a_pointer: %s is a link into the current version; roll back with wa_version_point <previous> (one rename), not with a file copy\n' "$installed" >&2
    return 3
  fi
  [ -f "$backup" ] || { printf 'version_rollback_backup_missing: %s\n' "$backup" >&2; return 4; }
  cp -f "$backup" "$installed.new" && mv -f "$installed.new" "$installed"
}

# 7. RETENTION. [<keep=3>]
#
# Removed only when ALL of these hold: it is not current, not the version before current, no LIVE process
# runs from it (its real /proc/<pid>/exe), and it is not pinned (versions/.pinned, or the current record's
# build_pin=). The legacy wa.prev/wa.pre/lua-core.stale copies are never touched here.
wa_version_live_ids() {
  local versions exe id
  versions="$(wa_versions_dir)"
  for exe in /proc/[0-9]*/exe; do
    exe="$(readlink -f "$exe" 2>/dev/null)" || continue
    case "$exe" in "$versions"/*) id="${exe#"$versions"/}"; printf '%s\n' "${id%%/*}" ;; esac
  done | LC_ALL=C sort -u
}
wa_version_pinned_ids() {
  local versions current
  versions="$(wa_versions_dir)"
  [ ! -f "$versions/.pinned" ] || sed -n 's/^[[:space:]]*//; s/[[:space:]]*$//; /^$/d; /^#/d; p' "$versions/.pinned"
  current="$(wa_current_link)"
  [ ! -f "$current/installed.txt" ] || sed -n 's/^build_pin=//p' "$current/installed.txt" 2>/dev/null | head -1 | cut -c1-12
}
wa_version_prune() {
  local keep="${1:-3}" versions current before live pinned id order i=0 removed=0 path
  versions="$(wa_versions_dir)"; current="$(wa_current_link)"
  [ -d "$versions" ] || { printf 'version_prune_none: no versions dir\n'; return 0; }
  live="$(wa_version_live_ids)"; pinned="$(wa_version_pinned_ids)"
  before="$(readlink "$current" 2>/dev/null)"; before="${before##*/}"
  # Newest first by the folder's own assembled_utc, then by id (a stable order for a tie).
  order="$(for path in "$versions"/*/version.txt; do
             [ -f "$path" ] || continue
             printf '%s %s\n' "$(sed -n 's/^assembled_utc=//p' "$path" | head -1)" "$(basename "$(dirname "$path")")"
           done | LC_ALL=C sort -r | awk '{print $2}')"
  for id in $order; do
    i=$((i + 1))
    [ "$i" -le "$keep" ] && continue
    [ "$id" = "$before" ] && continue
    printf '%s\n' "$live" | grep -qx "$id" && { printf 'version_kept_live %s\n' "$id"; continue; }
    [ -n "$pinned" ] && printf '%s\n' "$pinned" | grep -qx "$id" && { printf 'version_kept_pinned %s\n' "$id"; continue; }
    chmod -R u+w "$versions/$id" 2>/dev/null || true
    rm -rf "$versions/$id" && { printf 'version_pruned %s\n' "$id"; removed=$((removed + 1)); }
  done
  printf 'version_prune_done removed=%s kept_at_least=%s\n' "$removed" "$keep"
}

# REPORT: REAL DISK, not apparent size. <id> -> bytes on disk (blocks) and apparent bytes.
wa_version_disk() {
  local dir real apparent
  dir="$(wa_version_dir "${1:?id}")"
  [ -d "$dir" ] || { printf 'version_absent: %s\n' "$dir" >&2; return 2; }
  real="$(du -s -B1 "$dir" 2>/dev/null | awk '{print $1}')"
  apparent="$(du -s -B1 --apparent-size "$dir" 2>/dev/null | awk '{print $1}')"
  printf 'version_disk %s real=%s apparent=%s\n' "${1}" "${real:-?}" "${apparent:-?}"
}

