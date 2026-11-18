#!/usr/bin/env bash
# Put back the binary pair the last install replaced, and bring the node back under it.
#
# WHY THIS IS A SCRIPT AND NOT A FLAG ON A DEPLOY. "Put the old one back" is the one action that has to
# work when the node it is about is not answering, so it may not need a tree, a network, a release feed
# or a build - only the copy the install already made. `scripts/deploy.sh` keeps that copy in
# <install>/rollback/ on every install (and `scripts/linux/bootstrap.sh` keeps the same pair in
# <install>/.prev for a release install), so a rollback is a rename plus a restart, and its evidence is
# a directory `ls` can show.
#
# It is deliberately narrow: the binary pair and the install record. It does not restore ui/, lua-core/,
# components or the tree - those are the tree's own concern and a mixed pair is a worse answer than an
# honest, narrow one (the same rule `bootstrap.sh --rollback` states).
#
#   bash scripts/rollback-node.sh                      # this node's install, the newest kept pair, restarted
#   bash scripts/rollback-node.sh --no-restart         # restore only (a test, or an operator's own restart)
#   bash scripts/rollback-node.sh --install DIR --from DIR --reason TEXT
#
# It runs OUTSIDE a node run: a node cannot replace itself. `wa update <node> --rollback` asks the
# node's own Sentinel for exactly this (lua/core/remote_update.lua, `request run`), and the sentinel is
# the process that performs it.
#
# Exit codes: 0 restored (or restored and not restarted, named); 2 usage; 3 no rollback copy;
#             4 the restore failed; 5 the restored binary does not run.
set -uo pipefail

say() { printf 'rollback-node: %s\n' "$*"; }
fail() { printf 'rollback-node: %s\n' "$*" >&2; exit "${2:-4}"; }

INSTALL="${WA_INSTALL_DIR:-$HOME/.local/bin}"
# The one writer of installed.txt and the one probe that asks a binary what it is
# (scripts/lib/install-record.sh). It ships beside this script (<install>/scripts/lib/), because the node
# this acts on may have no checkout, no network and no healthy node - only the install it is restoring.
for rollback_lib in "${WA_INSTALL_RECORD_LIB:-}" "$(dirname "$0")/lib/install-record.sh"; do
  [ -n "$rollback_lib" ] && [ -f "$rollback_lib" ] && . "$rollback_lib" && break
done
command -v wa_build_info >/dev/null 2>&1 \
  || { printf 'rollback-node: refused(install_record_lib_missing): scripts/lib/install-record.sh is not beside this script, and it is what makes the record the restored binary'"'"'s own answer; nothing was restored\n' >&2; exit 4; }
FROM=""
REASON=""
RESTART=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --install) [ "$#" -ge 2 ] || fail 'install_value_required' 2; INSTALL="$2"; shift 2 ;;
    --from) [ "$#" -ge 2 ] || fail 'from_value_required' 2; FROM="$2"; shift 2 ;;
    --reason) [ "$#" -ge 2 ] || fail 'reason_value_required' 2; REASON="$2"; shift 2 ;;
    --no-restart) RESTART=0; shift ;;
    -h|--help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) fail "unknown_option: $1" 2 ;;
  esac
done

[ -d "$INSTALL" ] || fail "install_missing: $INSTALL is not a directory; nothing was restored" 3
if [ -z "$FROM" ]; then
  # Two shapes, and both are real: a tree install keeps <install>/rollback, a release install keeps
  # <install>/.prev. The newest one that holds a pair wins, so one verb covers every node.
  if [ -f "$INSTALL/rollback/wa" ]; then FROM="$INSTALL/rollback"
  elif [ -f "$INSTALL/.prev/wa" ]; then FROM="$INSTALL/.prev"
  else
    fail "rollback_unavailable: neither $INSTALL/rollback/wa nor $INSTALL/.prev/wa exists - this install kept no previous pair (an install from before a rollback copy existed cannot be rolled back)" 3
  fi
fi
[ -d "$FROM" ] || fail "rollback_from_missing: $FROM is not a directory" 3
for f in wa wa-sentinel; do
  [ -f "$FROM/$f" ] || fail "rollback_incomplete: $FROM/$f is missing; nothing was restored" 3
done

was=$(sed -n 's/^commit=//p' "$INSTALL/installed.txt" 2>/dev/null | head -1 | tr -d '[:space:]')
to=$(sed -n 's/^commit=//p' "$FROM/installed.txt" 2>/dev/null | head -1 | tr -d '[:space:]')
[ -n "$REASON" ] || REASON="operator rollback"
say "restoring ${to:-the previous pair} from $FROM (replacing ${was:-the installed one}); reason: $REASON"

# Stop the supervisor first: it would otherwise restart the node from the binary this is replacing.
STOPPED=0
if [ "$RESTART" = 1 ] && command -v systemctl >/dev/null 2>&1; then
  if systemctl --user is-active -q wa-sentinel.service 2>/dev/null; then
    systemctl --user stop wa-sentinel.service && STOPPED=1 || say 'the sentinel service did not stop; the swap is still safe, the restart below is not'
  fi
fi

# Rename, never overwrite in place: the replacement is complete before it is the file the path names.
for f in wa wa-sentinel; do
  cp -p "$FROM/$f" "$INSTALL/.$f.rollback" || fail "rollback_failed: could not copy $FROM/$f; nothing was changed" 4
  mv -f "$INSTALL/.$f.rollback" "$INSTALL/$f" || fail "rollback_failed: could not put $FROM/$f in place" 4
  chmod 755 "$INSTALL/$f" 2>/dev/null || true
done
[ -x "$INSTALL/wa" ] || fail "rollback_does_not_run: $INSTALL/wa is not executable after the restore; the copy is still in $FROM" 5
VERSION="$("$INSTALL/wa" --version 2>&1 | head -1)"
[ -n "$VERSION" ] || fail "rollback_does_not_run: $INSTALL/wa --version answered nothing; the copy is still in $FROM" 5

# THE RECORD IS THE RESTORED BINARY'S OWN ANSWER. A rollback writes installed.txt by copying the older
# record - and that record was itself somebody's claim, which is exactly how a node came to run a build of 8
# unlanded commits under commit=14963b6f (18/11). So the identity fields come from `wa --build-info` of the
# binary that is now installed, and the rollback's own facts (what it replaced, why) are appended beside them.
wa_record_install "$INSTALL" "$INSTALL/wa" \
  "via=rollback-node.sh" \
  "rollback_of=${was:-unknown}" \
  "rollback_from=$FROM" \
  "rollback_reason=$REASON" \
  "rollback_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  "source_provenance=rollback-restored-pair" \
  "record_role=final" \
  || say 'installed.txt was not rewritten; the binaries were restored (the record still names the pair that was replaced)'
if [ -f "$FROM/installed.txt" ]; then
  # The rest of the older record (its release tag, manifest digest, upgrade hash) is still true of these
  # bytes and is not something this script can re-derive, so it is carried over - the identity lines above
  # are not, because they are the binary's to say.
  while IFS= read -r line; do
    case "$line" in
      commit=*|tree=*|dirty=*|build_info=*|build_source=*|built_epoch=*|contains_commits=*|recorded_utc=*|via=*|rollback_*=|source_provenance=*|record_role=*|branch=*|'') continue ;;
    esac
    printf '%s\n' "$line"
  done < "$FROM/installed.txt" >> "$INSTALL/installed.txt.carried" 2>/dev/null || true
  if [ -s "$INSTALL/installed.txt.carried" ]; then
    cat "$INSTALL/installed.txt.carried" >> "$INSTALL/installed.txt" && rm -f "$INSTALL/installed.txt.carried" \
      || say 'the older record'"'"'s extra fields were not carried over; the identity fields are the restored binary'"'"'s'
  else
    rm -f "$INSTALL/installed.txt.carried"
  fi
fi
say "record: installed.txt now names the restored binary's own build ($(sed -n 's/^commit=//p' "$INSTALL/installed.txt" | head -1))"
say "restored: $VERSION"

if [ "$RESTART" = 1 ]; then
  if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    systemctl --user start wa-sentinel.service 2>/dev/null \
      || say 'the sentinel service did not start; start it: systemctl --user start wa-sentinel.service'
  else
    say 'no systemd user session here; start the node yourself (the pair is restored)'
  fi
elif [ "$STOPPED" = 1 ]; then
  say 'the sentinel was stopped for the swap and --no-restart was given; start it when you mean to'
fi
say 'rollback ok'
exit 0
