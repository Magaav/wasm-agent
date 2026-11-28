#!/bin/bash
# ONE TEST FOR slots5.sh, and it can fail.
#
# slots5.sh LAUNCHES workers, and a launch is expensive: a mission is created, briefed and started, then left
# running. Four conditions hold it back (enough workers already, load >= 14, requests waiting, a deploy active).
# The test asserts BOTH directions: it launches when nothing holds it, and launches NOTHING when any one guard is
# true - each guard alone, so a passing case names the guard that held.
#
# The load guard reads /proc/loadavg, which a test cannot write, so `cut` is stubbed to answer 0 for that file and
# delegate everything else. Without that, "nothing launched" would also pass on a busy machine and the guard cases
# would pass for the wrong reason (measured: at load 7-16 they did exactly that).
#
# WHAT IT CAN CATCH: a launch that ignores the worker cap, a launch during a waiting request or a live deploy, a
# launch on the wrong commit, a launch that starts nothing, and a brief not taken from the queue item.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d /tmp/wa-slots.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
checks=0; failed=0
fail() { echo "FAIL test-slots5: $*" >&2; failed=$((failed + 1)); }
ok() { checks=$((checks + 1)); [ "$1" = "$2" ] || fail "$3 (got $1, wanted $2)"; }

H="$WORK/home"; B="$WORK/bin"; M="$H/Work/missions"
mkdir -p "$B" "$M/_orch/run-copies" "$M/_queue" "$H/wasm-agent/checkout"
printf 'the brief from the queue\n' > "$M/_queue/alpha.md"

# launch.sh and start.sh are what a launch DOES. The path is baked in, so they need no environment.
printf '#!/bin/bash\nprintf "launch %%s %%s\\n" "$1" "$2" >> %s/launched\n' "$M/_orch" > "$M/launch.sh"
printf '#!/bin/bash\nprintf "start %%s\\n" "$1" >> %s/launched\n' "$M/_orch" > "$M/start.sh"
printf '#!/bin/bash\ncase "$*" in *rev-parse*) echo abc1234;; *) exit 0;; esac\n' > "$B/git"
# The load guard's file cannot be written by a test, so cut answers 0 for /proc/loadavg and delegates the rest.
cat > "$B/cut" <<'EOS'
#!/bin/bash
for a in "$@"; do [ "$a" = /proc/loadavg ] && { echo 0; exit 0; }; done
exec /usr/bin/cut "$@"
EOS
# wa-sentinel prints the line the test wrote into $WORK/reqline: read at RUN time, chosen per scenario.
printf '#!/bin/bash\ncat %s/reqline\n' "$WORK" > "$B/wa-sentinel"
# systemctl: which mission units and which deploys are active, from files the scenario writes.
printf '#!/bin/bash\ncase "$*" in *list-units*mission-*) cat %s/units 2>/dev/null; exit 0;; *list-units*wa-deploy-*) cat %s/deploys 2>/dev/null; exit 0;; *) exit 0;; esac\n' "$WORK" "$WORK" > "$B/systemctl"
chmod +x "$M/launch.sh" "$M/start.sh" "$B/"*

reqline() { printf 'requests: %s waiting\n' "$1" > "$WORK/reqline"; }
reset() { : > "$WORK/units"; : > "$WORK/deploys"; reqline 0; rm -f "$M/_orch/launched"; rm -rf "$M/alpha"; }
run() { HOME="$H" PATH="$B:/usr/bin:/bin" timeout 5 bash "$HERE/slots5.sh" "$@" >/dev/null 2>&1; }
launched() { if [ -f "$M/_orch/launched" ]; then wc -l < "$M/_orch/launched"; else echo 0; fi; }

# 1. nothing holds it back: launched AND started, on origin/main's sha, with the queue's item as its brief.
reset; printf 5 > "$M/_orch/max-workers"
run alpha
ok "$(grep -c '^launch alpha abc1234' "$M/_orch/launched" 2>/dev/null || echo 0)" "1" "with nothing holding it back the worker is launched on origin/main's sha"
ok "$(grep -c '^start alpha' "$M/_orch/launched" 2>/dev/null || echo 0)" "1" "and started, not only launched"
ok "$(head -1 "$M/alpha/brief.md" 2>/dev/null)" "the brief from the queue" "with the queue's item as its brief"

# 2. the worker cap: one active mission unit against max-workers=1 means WAIT.
reset; printf 1 > "$M/_orch/max-workers"; printf 'mission-other.service loaded active running\n' > "$WORK/units"
run alpha
ok "$(launched)" "0" "at the worker cap nothing is launched"

# 3. a request waiting: nobody is launched while the node has someone to answer.
reset; printf 5 > "$M/_orch/max-workers"; reqline 2
run alpha
ok "$(launched)" "0" "with requests waiting nothing is launched"

# 4. a deploy active: the install owns the machine, so nothing is launched.
reset; printf 5 > "$M/_orch/max-workers"; printf 'wa-deploy-1.service loaded active running\n' > "$WORK/deploys"
run alpha
ok "$(launched)" "0" "during a deploy nothing is launched"

# 5. and back to clear: the same setup as case 3 with the request answered DOES launch, so the guard cases above
#    are not passing because the script can never launch at all.
reset; printf 5 > "$M/_orch/max-workers"; reqline 0
run alpha
ok "$(launched)" "2" "with the request answered the launch happens (2 lines: launch + start)"

if [ "$failed" -gt 0 ]; then echo "test-slots5: $failed failed of $checks checks"; exit 1; fi
echo "test-slots5 ok ($checks checks)"
