#!/usr/bin/env bash
# Retire the shipped scripts this release no longer ships.
#
# MEASURED 2026-11-11: the Node WhatsApp bridge was deleted from main (`whatsapp-read.mjs` went with it).
# The next deploy shipped the new set - a copy loop, which is a UNION with what the last deploy left - so
# the install kept running the deleted reader, and the install's own scripts closure reported `ok:false`
# while `verify-deployed.sh` passed (it compares the files the tree still names, not the ones it does not).
#
# A deploy installs a SET. A file the tree no longer has must not survive from the previous release, and a
# file somebody put in the install by hand must not be mistaken for one of ours: this retires only the
# names `scripts/deploy-shipped.json` declares shipped, and only when the tree no longer has them.
#
# Nothing is deleted: the bytes are MOVED to <install>/scripts/.retired/<utc>/<path>, which is recovery
# evidence for the operator and is never re-shipped. The move is noted with its count and directory.
#
# The job definitions are the one family whose tree home is `jobs/`, not `scripts/`: `foo.job.json` and its
# `foo.job.json.shipped` marker are shipped from `jobs/foo.json`, and the marker is what keeps an unchanged
# definition from being re-put (a re-put cancels every pending delivery for that job).
retire_unshipped() { # <install-dir> <tree-root>
  local install="${1:-}" root="${2:-}" stamp name pattern target job retired=0
  [ -n "$install" ] && [ -n "$root" ] || { printf 'retire_unshipped: install and tree required\n' >&2; return 2; }
  [ -d "$install/scripts" ] && [ -d "$root/scripts" ] || return 0
  stamp="$install/scripts/.retired/$(date -u +%Y%m%dT%H%M%SZ)"
  # Read the globs as data, never expand them against the caller's cwd: a `for pattern in whatsapp-*` in a
  # checkout whose cwd happens to hold a matching file is a different (and silently shorter) list. Each
  # glob is expanded against the INSTALL, which is the set being pruned.
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    for target in "$install/scripts/"$pattern; do
      [ -f "$target" ] || continue
      name="${target#"$install/scripts/"}"
      case "$name" in
        *.job.json|*.job.json.shipped)
          job="${name%%.job.json*}"
          [ -f "$root/jobs/$job.json" ] && continue ;;
        *)
          [ -f "$root/scripts/$name" ] && continue ;;
      esac
      mkdir -p "$(dirname "$stamp/$name")" || { printf 'retire_unshipped: cannot create %s\n' "$(dirname "$stamp/$name")" >&2; return 2; }
      mv -f "$install/scripts/$name" "$stamp/$name" \
        || { printf 'retire_unshipped: cannot retire %s\n' "$name" >&2; return 2; }
      retired=$((retired + 1))
    done
  done <<'SHIPPED'
deploy.sh
verify-install.sh
verify-deployed.sh
check-embedded-runtime.lua
check-graph-component.lua
codemode-build.mjs
measure-sentinel-io.ps1
install-sentinel-service.ps1
sentinel-install-proof.mjs
sentinel-historical-proof.mjs
on-stale.sh
deploy-shipped.json
whatsapp-*
mcp-*.mjs
subagent-return-*
sentinel-return-*
wave-*
*.job.json
*.job.json.shipped
lib/*
SHIPPED
  [ "$retired" -gt 0 ] && printf 'retired %s shipped script(s) this release no longer ships into %s\n' "$retired" "$stamp"
  return 0
}
