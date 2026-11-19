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
# IT RESTORES THE MATCHING LUA TREE WITH THE BINARY (item 2 of the node-ops round, #20/#35). A deploy
# swaps <install>/lua-core and <install>/lua-core.prev together with the binaries, and a rollback that
# put back only the binary left the node running the OLD binary under the NEW Lua tree - the 19/11
# report said "installed tree ignored" all day, and the node answered with code its binary never
# shipped. So when <install>/lua-core.prev exists it is swapped back in the same act, and the answer
# names which tree is now installed.
#
# IT IS DONE ONLY WHEN THE NODE IS RUNNING THE RESTORED BINARY. "Restart it and hope" is not a
# rollback: the previous 19/11 attempt printed 'rollback ok' while the service had failed to start, so
# the node was running nothing at all. Restart then READS /proc/<pid>/exe (or, where /proc is absent,
# the supervisor's own report) and compares it with the file just restored: same device and inode,
# not merely the same name. Anything else - no process, a different binary, a read this script cannot
# make - is a named failure with the one command that finishes the job by hand.
#
# It still does not restore ui/, components or the tree - those are the tree's own concern and a mixed
# pair is a worse answer than an honest, narrow one (the same rule `bootstrap.sh --rollback` states).
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
# The identity check a rollback ends on is a library, so it can be tested against a real pid
# (scripts/lib/rollback-verify.sh); a check nobody can test is a check nobody can trust.
for rollback_verify in "${WA_ROLLBACK_VERIFY_LIB:-}" "$(dirname "$0")/lib/rollback-verify.sh" "$(dirname "$0")/../scripts/lib/rollback-verify.sh"; do
  [ -n "$rollback_verify" ] && [ -f "$rollback_verify" ] && . "$rollback_verify" && break
done
command -v wa_running_binary_verdict >/dev/null 2>&1 \
  || fail "refused(rollback_verify_lib_missing): scripts/lib/rollback-verify.sh is not beside this script, and it is what proves which binary the node is running; nothing was restored" 4

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
# THE LUA TREE THAT MATCHES THE BINARY. A deploy keeps the tree it replaces in lua-core.prev (and, for a
# release install, .prev/lua-core); a binary rolled back without its tree runs the code it shipped. The
# swap is a rename in both directions, so an interrupted rollback leaves one of the two trees whole.
LUA_RESTORED="none"
LUA_PREV=""
for candidate in "$FROM/lua-core" "$INSTALL/lua-core.prev" "$FROM/lua-core.prev"; do
  [ -d "$candidate" ] && { LUA_PREV="$candidate"; break; }
done
if [ -n "$LUA_PREV" ]; then
  rm -rf "$INSTALL/lua-core.rolling"
  { [ ! -d "$INSTALL/lua-core" ] || mv "$INSTALL/lua-core" "$INSTALL/lua-core.rolling"; }     && mv "$LUA_PREV" "$INSTALL/lua-core"     || fail "rollback_lua_failed: the Lua tree at $LUA_PREV could not be put in place of $INSTALL/lua-core; the binaries are restored and the Lua tree is at $INSTALL/lua-core.rolling (move it back by hand)" 4
  rm -rf "$INSTALL/lua-core.rolling"
  LUA_RESTORED="$LUA_PREV"
  say "restored the matching Lua tree from $LUA_PREV into $INSTALL/lua-core"
else
  # Named, never silent: an install from before the tree pair existed kept no previous tree, and a node
  # running an old binary under a new tree is the exact state this item exists to end.
  say "warning: no previous Lua tree was kept ($INSTALL/lua-core.prev and $FROM/lua-core are both absent), so the tree beside this binary is whatever the last install put there - a binary older than its tree is not a rollback, and a fresh install is the only way to make the pair match"
fi
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
restored_commit="$(sed -n 's/^commit=//p' "$INSTALL/installed.txt" 2>/dev/null | head -1 | tr -d '[:space:]')"
say "record: installed.txt now names the restored binary's own build (${restored_commit:-unknown})"
case "$restored_commit" in
  ''|unknown)
    # A ROLLBACK CAN LEAVE A NODE NOTHING CAN IDENTIFY, AND THE NEXT INSTALL WILL REFUSE IT.
    # A pair whose record names no commit (a release install older than the record that names one), or a binary
    # older than --build-info, is restored and cannot say what it is. That is honest - the record is the binary's
    # own answer, never a guess - and it is also a state the operator must not discover from the NEXT command: an
    # ordinary install now refuses this node as running_commit_unprovable rather than replacing bytes nobody can
    # name (round-3 item 1). Said here, with the one override, while the operator is still looking at it.
    say "warning: the restored binary cannot name its own commit, so the next ordinary install on this node will refuse it as running_commit_unprovable until it is rebuilt from a build that carries --build-info (or installed with --force --reason <text>, which is recorded). What IS running is recorded: sha256=$(sha256sum < "$INSTALL/wa" 2>/dev/null | cut -c1-12) in $INSTALL/installed.txt"
    ;;
esac
say "restored: $VERSION"

# IS THE NODE RUNNING THE BYTES THIS SCRIPT JUST PUT BACK?
#
# `rollback ok` used to be printed after `systemctl start` returned, and a start that failed still
# printed it: measured 19/11, the service was dead and the operator read a success line. So the answer
# is not the start command's exit, it is the running process. Two independent facts are required:
#   1. the process the supervisor reports is alive, and
#   2. /proc/<pid>/exe resolves to the file restored here - compared by st_dev and st_ino, because a
#      path is a name and the question is which bytes are executing.
# Where a check cannot be made (no /proc, no pid reported, an unreadable link) this script says it
# cannot and refuses the success claim: unknown is not yes.
if [ "$RESTART" = 1 ]; then
  if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    systemctl --user start wa-sentinel.service 2>/dev/null \
      || say 'the sentinel service did not start; the pair is restored but nothing is running it'
    # Give the service a bounded moment to exec the binary before the link is read: a start that returns
    # before the child execs would otherwise be read as 'mismatch' for a node that is fine.
    pid=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      pid="$(wa_supervised_pid)"
      [ -n "$pid" ] && [ "$pid" != 0 ] && [ -e "/proc/$pid/exe" ] && break
      sleep 1
    done
    verdict="$(wa_running_binary_verdict "$pid" "$INSTALL/wa")"
    case "$verdict" in
      ok*)
        say "the node (pid $pid) is running the restored binary: $(printf '%s' "$verdict" | cut -d' ' -f2-)"
        ;;
      mismatch*)
        fail "rollback_not_effective: the pair was restored and the node was started, but the running process is NOT the restored binary ($verdict). This is not a rollback: the node is still executing the bytes this script meant to replace. Stop it and install a matching pair, or start the restored binary by hand: $INSTALL/wa" 5
        ;;
      *)
        fail "rollback_unverified: the pair was restored and a start was asked for, but this script cannot prove which binary is running (${verdict#unknown }). Unknown is not yes: check it yourself with 'systemctl --user show wa-sentinel.service -p MainPID --value' and read /proc/<pid>/exe before believing this node is rolled back." 5
        ;;
    esac
  else
    say 'no systemd user session here; start the node yourself (the pair is restored), then check it with: readlink -f /proc/<pid>/exe (it must be this install'"'"'s wa)'
  fi
elif [ "$STOPPED" = 1 ]; then
  say 'the sentinel was stopped for the swap and --no-restart was given; start it when you mean to, then check it with: readlink -f /proc/<pid>/exe'
fi
say "rollback ok${LUA_RESTORED:+ (binary and Lua tree)}"
exit 0
