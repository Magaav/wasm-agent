#!/bin/bash
. "$(cd "$(dirname "${WA_FACTORY_ORIG:-$0}")" && pwd)/lib/refresh-self.sh"   # refresh the clone between iterations
# FACTORY RE-EXEC (orchestrator 23/11, Fable): run from a private copy, so an edit to this file can't break a run already started.
if [ "${WA_FACTORY_COPY:-}" != "$$" ]; then _c=$(mktemp "$HOME/Work/missions/_orch/run-copies/$(basename "$0").XXXXXX") && cp "$0" "$_c" && WA_FACTORY_COPY=$$ WA_FACTORY_ORIG="$0" exec bash "$_c" "$@"; fi
unset WA_FACTORY_COPY; case "$0" in */_orch/run-copies/*) trap 'rm -f -- "$0"' EXIT;; esac
# slots5.sh 23/11 ~11:40Z (Victor "full speed", via Fable): MAX workers (default 5) and a load guard (<14). Based on slots4.sh.
# slots4.sh 23/11 ~07:45Z (orchestrator, Fable): like slots3, but counts LIVE workers by process.
# A worker = a process whose cwd is a mission dir and whose argv is a wa chat / run.sh / amend-run.sh / resume helper (~/Work/missions/<name>[/...]).
# Units undercount: amend-resumed workers run outside mission-* units. Three means three.
M=$HOME/Work/missions; next=("$@")
live() {
  for d in /proc/[0-9]*; do
    c=$(readlink $d/cwd 2>/dev/null) || continue
    case "$c" in $M/_*|$M) continue;; $M/*) ;; *) continue;; esac
    a=$(tr '\0' ' ' < $d/cmdline 2>/dev/null)
    case "$a" in *"wa chat"*|*/wa\ chat*|*amend-run.sh*|*/run.sh*|*resume-msg.sh*|*resume-generic.sh*) echo "${c#$M/}" | cut -d/ -f1;; esac
  done | sort -u
}
active() { { live; systemctl --user list-units 'mission-*' --state=active --no-legend | awk '{print $1}' | sed -E 's/^mission-//; s/(-r[0-9]*)?\.service$//'; } | sort -u | wc -l; }
for n in "${next[@]}"; do
  wa_factory_refresh_self
  while [ "$(active)" -ge "$(cat $M/_orch/max-workers 2>/dev/null || echo 5)" ] || [ "$(cut -d. -f1 /proc/loadavg)" -ge 14 ] \
     || ! wa-sentinel status 2>/dev/null | grep -qE 'requests: *0 waiting' \
     || systemctl --user list-units 'wa-deploy-*' --state=active --no-legend | grep -q .; do sleep 60; done
  B=$(git -C $HOME/wasm-agent/checkout fetch -q origin && git -C $HOME/wasm-agent/checkout rev-parse --short origin/main)
  mkdir -p $M/$n && cp $M/_queue/$n.md $M/$n/brief.md
  cd $M && ./launch.sh $n $B && ./start.sh $n && echo "$(date -u +%T) launched $n on $B (live before: $(live | tr '\n' ' '))"
  sleep 90
done
echo "$(date -u +%T) slots5.sh: done"
