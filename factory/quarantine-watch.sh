#!/bin/bash
# FACTORY RE-EXEC (orchestrator 23/11, Fable): run from a private copy, so an edit to this file can't break a run already started.
if [ "${WA_FACTORY_COPY:-}" != "$$" ]; then _c=$(mktemp "$HOME/Work/missions/_orch/run-copies/$(basename "$0").XXXXXX") && cp "$0" "$_c" && WA_FACTORY_COPY=$$ WA_FACTORY_ORIG="$0" exec bash "$_c" "$@"; fi
unset WA_FACTORY_COPY; case "$0" in */_orch/run-copies/*) trap 'rm -f -- "$0"' EXIT;; esac
# Follow the user journal for graph_db_quarantined and log time + what was running (Fable 23/11).
OUT=$HOME/Work/missions/_orch/evidence/quarantines.txt
journalctl --user -f -n 0 -o short-iso | grep --line-buffered graph_db_quarantined | while read -r line; do
  {
    echo "== $(date -u +%FT%TZ)"
    echo "$line"
    echo "deploys: $(systemctl --user list-units 'wa-deploy-*' --state=active --no-legend | awk '{print $1}' | tr '\n' ' ')"
    echo "missions: $(systemctl --user list-units 'mission-*' --state=active --no-legend | awk '{print $1}' | tr '\n' ' ')"
    echo "orch: $(systemctl --user list-units 'orch-*' --state=active --no-legend | awk '{print $1}' | tr '\n' ' ')"
    echo "installed: $(head -1 $HOME/.local/bin/installed.txt)  load: $(cut -d' ' -f1-3 /proc/loadavg)"
  } >> "$OUT"
done
