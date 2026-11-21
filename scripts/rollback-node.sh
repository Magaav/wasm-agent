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

# WHICH UNIT RUNS THE NODE - DETECTED BEFORE ANYTHING IS STOPPED (item 1 of the node-ops round).
#
# MEASURED 19/11: this stopped wa-sentinel.service and only THEN asked wa_node_units which unit serves.
# wa_node_units lists a unit whose MainPID != 0, so the supervisor it had just stopped was invisible,
# UNIT came back empty, and the script failed 'rollback_unverified' WITHOUT restarting anything: the node
# stayed down with its binary already replaced. On this node (wa-serve.service serving, wa-sentinel.service
# inactive) the stop was a no-op and the restart path worked, which is why the defect needed a
# sentinel-supervised node to show itself.
#
# So the serving unit is recorded FIRST, and the SAME unit is stopped and restarted afterwards. When
# nothing is detected but a supervisor is running, the supervisor is what gets stopped (it would restart
# the node from the binary being replaced) and it is recorded for the restart as well.
UNIT_BEFORE=""
STOPPED_UNIT=""
if [ "$RESTART" = 1 ] && command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  UNIT_BEFORE="$(wa_node_unit)"
fi
if [ "$RESTART" = 1 ] && command -v systemctl >/dev/null 2>&1; then
  if [ -n "$UNIT_BEFORE" ]; then
    say "the node is served by ${UNIT_BEFORE}; it is stopped for the swap and the same unit is restarted after it"
    systemctl --user stop "$UNIT_BEFORE" && STOPPED_UNIT="$UNIT_BEFORE" \
      || say "the unit $UNIT_BEFORE did not stop; the swap is still safe, the restart below is not"
  elif systemctl --user is-active -q wa-sentinel.service 2>/dev/null; then
    systemctl --user stop wa-sentinel.service && STOPPED_UNIT=wa-sentinel.service \
      || say 'the sentinel service did not stop; the swap is still safe, the restart below is not'
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
LUA_RESTORED=""
LUA_VERIFIED=""
BINARY_VERIFIED=""
LUA_WANT=""
LUA_PREV=""
for candidate in "$FROM/lua-core" "$INSTALL/lua-core.prev" "$FROM/lua-core.prev"; do
  [ -d "$candidate" ] && { LUA_PREV="$candidate"; break; }
done
LUA_ASIDE=""
if [ -n "$LUA_PREV" ]; then
  # The tree being replaced is KEPT ASIDE, never deleted (item 5 of the node-ops round): a rollback that
  # removed it left an operator who rolled back to a broken pair with nothing to roll FORWARD to. The
  # aside directory is named with the stamp, so two rollbacks in a row cannot overwrite each other.
  # The identity of the tree being restored is read BEFORE any move: after the swap its path is gone
  # (its bytes ARE the live tree), and an identity read from a moved-away path is a fact about nothing.
  LUA_WANT="$(wa_lua_tree_identity "$LUA_PREV")"
  LUA_ASIDE="$INSTALL/lua-core.rolled-back-$(date -u +%Y%m%dT%H%M%SZ)"
  if [ -d "$INSTALL/lua-core" ]; then
    mv "$INSTALL/lua-core" "$LUA_ASIDE" || fail "rollback_lua_failed: the Lua tree now at $INSTALL/lua-core could not be moved aside to $LUA_ASIDE; the binaries are restored and the tree is untouched" 4
  fi
  if ! mv "$LUA_PREV" "$INSTALL/lua-core"; then
    [ ! -d "$LUA_ASIDE" ] || mv "$LUA_ASIDE" "$INSTALL/lua-core" 2>/dev/null || true
    fail "rollback_lua_failed: the Lua tree at $LUA_PREV could not be put in place of $INSTALL/lua-core; the binaries are restored and the previous tree is $LUA_PREV" 4
  fi
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

# THE LUA TREE, as an IDENTITY and not as a directory (item 5 of the node-ops round). The manifest a
# deploy writes into <install>/lua-core names the commit and the digest of the inputs, so "which tree is
# installed" is a question with an answer. It is asked HERE and not inside the restart branch: a
# --no-restart rollback swaps the tree too, and a tree that cannot name itself is a refusal, never a
# silence - unknown is not yes.
if [ -n "$LUA_RESTORED" ]; then
  want="${LUA_WANT:-}"
  want_commit="${want%%|*}"; want_inputs="${want#*|}"
  [ "$want_inputs" = "$want" ] && want_inputs=""
  have="$(wa_lua_tree_identity "$INSTALL/lua-core")"
  have_commit="${have%%|*}"; have_inputs="${have#*|}"
  [ "$have_inputs" = "$have" ] && have_inputs=""
  if [ -z "$want_commit" ] || [ -z "$want_inputs" ] || [ -z "$want" ]; then
    fail "rollback_lua_unverified: the Lua tree was put back from $LUA_RESTORED, but that tree's manifest.txt names no source_commit/lua_inputs, so which tree was restored cannot be proven. The binary is verified; the tree is not." 5
  fi
  if [ "$have_commit" != "$want_commit" ] || [ "$have_inputs" != "$want_inputs" ]; then
    fail "rollback_lua_not_effective: $INSTALL/lua-core names ${have_commit:-no commit}/${have_inputs:-no digest}, not the restored ${want_commit}/${want_inputs}. The binary is the restored one and the tree beside it is NOT, so this is not a rollback." 5
  fi
  say "the Lua tree is the restored one (source_commit ${want_commit} / lua_inputs ${want_inputs})"
  LUA_VERIFIED="source_commit ${want_commit} / lua_inputs ${want_inputs}"
else
  say 'the Lua tree was not part of this rollback (no previous tree was kept), so only the binary is proven'
fi


# THE RESTART, AND THE TWO FACTS THAT MAKE IT A ROLLBACK.
#
# `rollback ok` used to be printed after `systemctl start` returned, and a start that failed still printed
# it: measured 19/11 the service was dead and the operator read a success line. Item 5 of the node-ops round
# added three more defects, each measured on this node:
#   * the unit was ASSUMED to be wa-sentinel.service, while the node here runs wa-serve.service - the check
#     answered 'unverified' on a node that was serving, so it could not fail honestly;
#   * START was asked of a unit that was already active, which is a no-op: the old binary kept serving and
#     the script then compared /proc/<pid>/exe of the process it never restarted;
#   * only the binary was compared, so a rollback that put the binary back and left the NEW Lua tree beside
#     it printed ok - the node answered with code its binary never shipped.
# So: the unit is DETECTED (wa_node_unit), the verb is RESTART, the pid read is the one that SERVES
# (wa_serving_pid: the child, when a sentinel supervises), and BOTH the binary and the Lua tree must match
# before this script says ok. Everything it cannot prove it refuses by name.
REASON_TAIL=""
if [ "$RESTART" = 1 ]; then
  if ! command -v systemctl >/dev/null 2>&1 || ! systemctl --user show-environment >/dev/null 2>&1; then
    say 'no systemd user session here; start the node yourself (the pair is restored), then check it with: readlink -f /proc/<pid>/exe (it must be this install wa)'
    REASON_TAIL="there is no systemd user session here, so no unit was restarted and no serving pid was read"
  else
    # EXACTLY THE UNIT THAT WAS STOPPED (item 1): the serving unit recorded before the swap, then the one
    # stopped, then - only for a node that had nothing to stop - whatever serves now.
    UNIT="${UNIT_BEFORE:-${STOPPED_UNIT:-$(wa_node_unit)}}"
    if [ -z "$UNIT" ]; then
      UNIT="$(wa_node_unit)"
    fi
    if [ -z "$UNIT" ]; then
      fail "rollback_unverified: no running systemd unit was found whose process serves this node (wa_node_units saw none), so there is nothing to restart and nothing to read. The pair IS restored. Start the node by hand ($INSTALL/wa serve ...), then check /proc/<pid>/exe against $INSTALL/wa." 5
    fi
    say "restarting $UNIT (detected: its process serves this node)"
    systemctl --user restart "$UNIT" 2>/dev/null \
      || say "the restart of $UNIT failed; the pair is restored and nothing is running it"
    # A bounded wait for the SERVING process to exist: a restart returns before the child execs.
    pid=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      pid="$(wa_serving_pid)"
      [ -n "$pid" ] && [ -e "/proc/$pid/exe" ] && break
      sleep 1
    done
    verdict="$(wa_running_binary_verdict "$pid" "$INSTALL/wa")"
    case "$verdict" in
      ok*) BINARY_VERIFIED="$pid"; say "the node ($UNIT, serving pid $pid) runs the restored binary: $(printf '%s' "$verdict" | cut -d' ' -f2-)" ;;
      
      mismatch*)
        fail "rollback_not_effective: $UNIT was restarted, but the process serving this node is NOT the restored binary ($verdict). This is not a rollback: the node still executes the bytes this script meant to replace. Stop $UNIT and install a matching pair, or start the restored binary by hand: $INSTALL/wa" 5 ;;
      *)
        fail "rollback_unverified: $UNIT was restarted, but this script cannot prove which binary serves (${verdict#unknown }). Unknown is not yes: read /proc/$pid/exe yourself before believing this node is rolled back." 5 ;;
    esac
  fi
elif [ -n "$STOPPED_UNIT" ]; then
  say "the unit $STOPPED_UNIT was stopped for the swap and --no-restart was given; start it when you mean to, then check it with: readlink -f /proc/<pid>/exe"
  REASON_TAIL="--no-restart was given, so no unit was restarted and no serving pid was read"
fi

# THE LAST LINE IS ONE CLAIM, AND IT NEEDS BOTH HALVES (item 2 of the node-ops round, report text 10).
#
# MEASURED 19/11: with no systemd session, with --no-restart, and on an install that kept no previous
# Lua tree, this script still ended 'rollback ok (binary verified; ...)' - a success line for a rollback
# whose tree it never compared and whose node it never restarted. The operator reads the last line, so
# the last line says exactly what was proven: 'rollback ok' only when the serving process executes the
# restored binary AND the tree beside it is the restored tree, both by identity; otherwise
# 'rollback_unverified' with every unproven half named.
if [ -n "$BINARY_VERIFIED" ] && [ -n "$LUA_VERIFIED" ]; then
  say "rollback ok (binary and Lua tree both verified: serving pid $BINARY_VERIFIED executes $INSTALL/wa, and lua-core is $LUA_VERIFIED)"
else
  unproven=""
  if [ -z "$BINARY_VERIFIED" ]; then
    unproven="${unproven}binary_not_read_by_this_run (no serving pid was proven to execute $INSTALL/wa); "
  fi
  if [ -n "$LUA_RESTORED" ] && [ -z "$LUA_VERIFIED" ]; then
    unproven="${unproven}lua_tree_not_compared; "
  fi
  if [ -z "$LUA_RESTORED" ]; then
    unproven="${unproven}no_previous_lua_tree_was_kept (the tree beside this binary is whatever the last install put there, and this run did not compare it); "
  fi
  say "rollback_unverified: the pair WAS restored and these are the parts this run could NOT prove: ${unproven}${REASON_TAIL:-}"
fi
exit 0
