#!/usr/bin/env bash
# THE FACTORY'S SYSTEMD UNITS RUN THE CLONE'S factory/ SCRIPTS, IN THE SHAPE THEY RUN IN TODAY (factory-is-small-and-tested,
# 27/11).
#
# A service's shape is not a detail: the reviewer caught units.sh turning the canary into a `Restart=always` loop when it is
# a TIMER today (`orch-canary.timer` + a oneshot service, every 60 s). A loop and a timer differ in what a failure means,
# in what the journal shows and in whether two runs can overlap - so the shape is read from the units as they are, and this
# script reproduces it. The table below is the census of 27/11; the schedule strings are copied verbatim from the timers.
#
# The clone's `clone.sh --refresh` is the service's ExecStartPre (and the timer service's too), so a landing on main changes
# what a tick does. Dry by default; `--apply` writes into the user unit directory and reloads the daemon there, and it never
# starts, stops or restarts anything.
set -uo pipefail

CLONE="${WA_FACTORY_CLONE:-$HOME/wasm-agent/factory-clone}"
DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
DEFAULT_DIR="$DIR"
APPLY=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --dir) DIR="${2:-}"; [ -n "$DIR" ] || { echo "factory/units.sh: --dir needs a directory" >&2; exit 2; }; shift 2 ;;
    -h|--help)
      echo "usage: factory/units.sh [--apply] [--dir <systemd user dir>]"
      echo "  writes one unit (or a timer pair) per factory service; dry run unless --apply"
      exit 0 ;;
    *) echo "factory/units.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

# name | script | shape | schedule (timers only, verbatim from today's timers) | description
#
# shape=loop  -> Restart=on-failure, like orch-slots5/orch-what-hurt today
# shape=timer -> a oneshot service + a .timer with this schedule, like orch-canary/daily/disk/snapshot/throughput today
SERVICES="
canary|canary.sh|timer|OnBootSec=2min\nOnUnitActiveSec=60s\nAccuracySec=5s|wa factory: the canary (every minute)
daily|daily-line.sh|timer|OnCalendar=*-*-* 08:00:00 America/Sao_Paulo|wa factory: the daily line (08:00)
disk|disk-watch.sh|timer|OnUnitActiveSec=5min|wa factory: disk watch (every 5 min)
health-loop|health-loop.sh|loop||wa factory: the health loop
nightly-suite|nightly-suite.sh|timer|OnCalendar=*-*-* 03:00:00 America/Sao_Paulo\nPersistent=true\nAccuracySec=5min|wa factory: the nightly full suite (03:00 BRT, no parallel width, advisory)
paused-watchdog|paused-watchdog.sh|loop||wa factory: the paused watchdog
quarantine-watch|quarantine-watch.sh|loop||wa factory: the quarantine watch
snapshot|reboot-snapshot.sh|timer|OnUnitActiveSec=10min|wa factory: the reboot snapshot (every 10 min)
slots5|slots5.sh|loop||wa factory: five slots
throughput|throughput-watch.sh|timer|OnCalendar=*:2/10|wa factory: throughput watch (every 10 min at :2)
what-hurt|what-hurt-loop.sh|loop||wa factory: what hurt
"

emit_service() { # unit script shape description schedule
  local unit="$1" script="$2" shape="$3" description="$4"
  printf '[Unit]\nDescription=%s (from the clone, 27/11)\n[Service]\n' "$description"
  if [ "$shape" = timer ]; then
    printf 'Type=oneshot\n'
  fi
  printf 'WorkingDirectory=%%h/Work/missions\n'
  # A timer service that cannot see main must not run stale code either: the same refresh, before the body.
  printf 'ExecStartPre=/usr/bin/bash %s/factory/clone.sh --refresh --quiet\n' "$CLONE"
  printf 'ExecStart=/usr/bin/bash %s/factory/%s\n' "$CLONE" "$script"
  if [ "$shape" = loop ]; then
    printf 'Restart=on-failure\nRestartSec=30\n'
  fi
}

emit_timer() { # unit schedule description
  printf '[Unit]\nDescription=%s\n[Timer]\n%b\n[Install]\nWantedBy=timers.target\n' "$3" "$2"
}

# The list goes through a file, not a pipe: a command inside the loop body can read stdin, and a pipe would then swallow the
# rest of the services (measured 27/11: the first version emitted ONE unit of ten).
SERVICES_FILE="$(mktemp "${TMPDIR:-/tmp}/factory-units-XXXXXX")"
trap 'rm -f "$SERVICES_FILE"' EXIT
printf '%s\n' "$SERVICES" > "$SERVICES_FILE"
while IFS='|' read -r name script shape schedule description; do
  [ -n "$name" ] || continue
  unit="orch-$name"
  svc="$(emit_service "$unit.service" "$script" "$shape" "$description")"
  if [ "$shape" = timer ]; then
    tm="$(emit_timer "$unit.timer" "$schedule" "$description")"
    files=("$unit.service" "$unit.timer")
    texts=("$svc" "$tm")
  else
    files=("$unit.service")
    texts=("$svc")
  fi
  for i in "${!files[@]}"; do
    if [ "$APPLY" = 1 ]; then
      printf '%s' "${texts[$i]}" > "$DIR/${files[$i]}" || exit 1
      echo "wrote $DIR/${files[$i]}"
    else
      printf '\n--- %s\n' "${files[$i]}"
      printf '%s' "${texts[$i]}"
    fi
  done
done < "$SERVICES_FILE"

if [ "$APPLY" = 1 ] && [ "$DIR" = "$DEFAULT_DIR" ]; then
  systemctl --user daemon-reload && echo "daemon reloaded; enable/start a unit when you mean to (this script never restarts one)"
else
  echo "written to $DIR (not the user unit directory, so no daemon reload)"
fi
