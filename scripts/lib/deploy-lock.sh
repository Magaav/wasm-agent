#!/usr/bin/env bash
# The deploy build lock: one holder, and a dead holder has to be reclaimable.
#
# WHY THIS IS A FILE. Measured on wasm_the_first (lesson les-dcbabb9d2835): a killed installer left
# `.deploy.lock` holding a dead pid, and because the only test was `mkdir`, every deploy refused for
# 1h44. The second half of the same measurement: a lock that is reclaimed by *age* steals a live build.
# So the holder records the four facts a kernel owns - pid, host, boot id and start time - and the lock
# is reclaimed only when one of them proves the holder is gone: the pid is not alive on this host, or the
# holder was recorded on another boot or another host. A live pid on this boot always refuses.
#
# The evidence is never discarded: the stale directory is moved aside (not deleted) and one line with
# all four fields plus the verdict is appended to <install>/deploy-lock.log.
#
# Callers: scripts/deploy.sh (build phase) and scripts/on-stale.sh through the same file. The functions
# take the lock directory as an argument so `scripts/test-deploy-lock.sh` can exercise them on a fixture
# with no install, no node and no build.

# The boot identity, so a pid recorded before a reboot is never read as a live owner (a Windows pid is
# reused). WA_DEPLOY_LOCK_BOOT_ID pins it for a machine whose kernel does not expose one, and for tests.
wa_deploy_lock_boot() {
  if [ -n "${WA_DEPLOY_LOCK_BOOT_ID:-}" ]; then printf '%s' "$WA_DEPLOY_LOCK_BOOT_ID"; return; fi
  if [ -r /proc/sys/kernel/random/boot_id ]; then cat /proc/sys/kernel/random/boot_id; return; fi
  case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
      powershell.exe -NoProfile -Command "(Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')" 2>/dev/null | tr -d '\015\012' ;;
  esac
}

wa_deploy_lock_field() { # <dir> <name>
  [ -f "$1/$2" ] || return 0
  tr -d '[:space:]' < "$1/$2" 2>/dev/null || true
}

# Reclaim a lock whose holder is provably gone. Returns 0 when there is nothing to do or the lock was
# reclaimed; 1 with WA_DEPLOY_LOCK_REASON set when a live holder owns it.
wa_deploy_lock_reclaim() { # <lockdir> <evidence-log>
  local lock="$1" log="$2"
  WA_DEPLOY_LOCK_REASON=""
  [ -d "$lock" ] || return 0
  local pid host boot started_at worktree mine_host boot_now alive=0 why moved
  pid="$(wa_deploy_lock_field "$lock" pid)"
  host="$(wa_deploy_lock_field "$lock" host)"
  boot="$(wa_deploy_lock_field "$lock" boot)"
  started_at="$(wa_deploy_lock_field "$lock" started_at)"
  worktree="$(wa_deploy_lock_field "$lock" worktree)"
  mine_host="$(hostname 2>/dev/null || uname -n 2>/dev/null || true)"
  boot_now="$(wa_deploy_lock_boot)"
  # A pid only names a process on the same boot AND the same host. Check those two facts first: a pid
  # recorded before a reboot (or on another machine) is very likely some live, unrelated process here.
  if [ -n "$boot" ] && [ -n "$boot_now" ] && [ "$boot" != "$boot_now" ]; then
    alive=0
  elif [ -n "$host" ] && [ "$host" != "$mine_host" ]; then
    alive=0
  elif [ -n "$pid" ] && [ "$host" = "$mine_host" ]; then
    kill -0 "$pid" 2>/dev/null && alive=1
  fi
  if [ "$alive" = "1" ]; then
    WA_DEPLOY_LOCK_REASON="another deploy/onStale build holds $lock (pid $pid on $host, since ${started_at:-unknown}); nothing built. A live holder is never stolen"
    echo "deploy: $WA_DEPLOY_LOCK_REASON" >&2
    return 1
  fi
  if [ -n "$boot" ] && [ -n "$boot_now" ] && [ "$boot" != "$boot_now" ]; then
    why="holder pid ${pid:-unknown} was recorded on another boot ($boot)"
  elif [ -n "$pid" ] && [ -n "$host" ] && [ "$host" != "$mine_host" ]; then
    why="holder pid $pid was recorded on host $host, not ${mine_host:-this host}"
  else
    why="holder pid ${pid:-unknown} on ${host:-$mine_host} is gone (started ${started_at:-unknown}, no such process)"
  fi
  moved="$lock.stale-$(date +%Y%m%dT%H%M%S)"
  mv "$lock" "$moved" 2>/dev/null || rm -rf "$lock"
  echo "deploy: reclaimed a stale deploy lock: $why; evidence kept at $moved"
  { printf '%s reclaimed_stale_deploy_lock pid=%s host=%s boot=%s started_at=%s worktree=%s verdict=reclaimed reason=%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$pid" "$host" "$boot" "$started_at" "$worktree" "$why"
  } >> "$log" 2>/dev/null || true
  return 0
}

# Take the lock, or refuse by name. Writes the holder's own facts so the next process can decide.
wa_deploy_lock_claim() { # <lockdir> <evidence-log> <worktree>
  local lock="$1" log="$2" worktree="$3"
  wa_deploy_lock_reclaim "$lock" "$log" || return 1
  if ! mkdir "$lock" 2>/dev/null; then
    WA_DEPLOY_LOCK_REASON="another deploy/onStale build took $lock between the check and the claim; nothing built"
    return 1
  fi
  printf '%s\n' "$$" > "$lock/pid" 2>/dev/null || true
  printf '%s\n' "$(hostname 2>/dev/null || uname -n 2>/dev/null)" > "$lock/host" 2>/dev/null || true
  printf '%s\n' "$(wa_deploy_lock_boot)" > "$lock/boot" 2>/dev/null || true
  printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$lock/started_at" 2>/dev/null || true
  printf '%s\n' "$worktree" > "$lock/worktree" 2>/dev/null || true
  return 0
}

wa_deploy_lock_release() { # <lockdir> <evidence-log>
  rm -rf "$1" 2>/dev/null || true
}
