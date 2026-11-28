#!/usr/bin/env bash
# THE FACTORY'S SYSTEMD UNITS RUN THE CLONE'S factory/ SCRIPTS, NEVER A HAND COPY (factory-is-small-and-tested, 27/11).
#
# Writes one user unit per factory service, each of the shape:
#
#   ExecStartPre=%h/wasm-agent/factory-clone/factory/clone.sh --refresh --quiet
#   ExecStart=/usr/bin/bash %h/wasm-agent/factory-clone/factory/<name>.sh
#   WorkingDirectory=%h/Work/missions
#
# The ExecStartPre is the "refreshed between runs" half: the clone is fetched and fast-forwarded to origin/main before the
# service body runs, so a landing on main changes what the loop does at its next tick. --refresh costs one fetch, and a
# no-op when nothing moved.
#
# Dry by default: prints the unit files it would write. `--apply` writes them under ~/.config/systemd/user and reloads the
# daemon; it never starts, stops or restarts a service - that is the operator's move (and a restart of the health loop in
# the middle of a landing is exactly what nobody wants).
set -uo pipefail

CLONE="${WA_FACTORY_CLONE:-$HOME/wasm-agent/factory-clone}"
DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
APPLY=0
# A `for arg in "$@"` loop cannot consume a VALUE (the value is visited as an argument of its own), so this parses with
# shift. Measured 27/11: the first version refused `--dir <path>` with "unknown argument <path>".
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --dir) DIR="${2:-}"; [ -n "$DIR" ] || { echo "factory/units.sh: --dir needs a directory" >&2; exit 2; }; shift 2 ;;
    -h|--help)
      echo "usage: factory/units.sh [--apply] [--dir <systemd user dir>]"
      echo "  writes one unit per factory service; dry run unless --apply"
      exit 0 ;;
    *) echo "factory/units.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

# One line per service: unit name suffix | script under factory/ | description.
SERVICES="
canary|canary.sh|wa factory: the canary
daily-line|daily-line.sh|wa factory: the daily line
disk-watch|disk-watch.sh|wa factory: disk watch
health-loop|health-loop.sh|wa factory: the health loop
paused-watchdog|paused-watchdog.sh|wa factory: the paused watchdog
quarantine-watch|quarantine-watch.sh|wa factory: the quarantine watch
reboot-snapshot|reboot-snapshot.sh|wa factory: the reboot snapshot
slots5|slots5.sh|wa factory: five slots
throughput-watch|throughput-watch.sh|wa factory: throughput watch
what-hurt|what-hurt-loop.sh|wa factory: what hurt
"

written=0
printf '%s\n' "$SERVICES" | while IFS='|' read -r name script description; do
  [ -n "$name" ] || continue
  unit="orch-$name.service"
  text="[Unit]
Description=$description (from the clone, 27/11)
[Service]
WorkingDirectory=%h/Work/missions
ExecStartPre=/usr/bin/bash %h/wasm-agent/factory-clone/factory/clone.sh --refresh --quiet
ExecStart=/usr/bin/bash %h/wasm-agent/factory-clone/factory/$script
Restart=always
RestartSec=30
[Install]
WantedBy=default.target
"
  if [ "$APPLY" = 1 ]; then
    printf '%s' "$text" > "$DIR/$unit" || exit 1
    echo "wrote $DIR/$unit"
  else
    echo "--- $unit"
    printf '%s' "$text"
  fi
done

DEFAULT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
if [ "$APPLY" = 1 ] && [ "$DIR" = "$DEFAULT_DIR" ]; then
  # Only the REAL unit directory reloads the daemon: a run against a temporary directory is a rehearsal and must not touch
  # the user's systemd (measured 27/11: the first version reloaded for any --dir).
  systemctl --user daemon-reload && echo "daemon reloaded; start a unit when you mean to (this script never restarts one)"
else
  echo "written to $DIR (not the user unit directory, so no daemon reload)"
fi
