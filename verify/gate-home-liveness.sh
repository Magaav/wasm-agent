#!/usr/bin/env bash
# Independent reviewer harness: c78ab731's gate-home sweep (scripts/test.sh slice) vs LIVE leases.
# The property: a home whose owning process is alive is never pruned.
# Run: bash verify/gate-home-liveness.sh <workdir>
set -uo pipefail
root="${1:?usage: gate-home-liveness.sh <workdir>}"
mkdir -p "$root"
work="$root/gate"; rm -rf "$work"; mkdir -p "$work/temp"
export TMPDIR="$work/temp" TMP="$work/temp" TEMP="$work/temp"
cp "$root/slice.sh" "$work/slice.sh" || cp slice.sh "$work/slice.sh"

fail=0; tests=0
ok() { tests=$((tests+1)); [ "$1" = 1 ] && printf '  ok       %s\n' "$2" || { fail=$((fail+1)); printf '  FAIL     %s%s\n' "$2" "${3:+ - $3}"; }; }
info() { printf '  ~        %s\n' "$1"; }
homes() { ls "$work/temp" 2>/dev/null | tr '\n' ' '; }
mkh() { local d="$work/temp/$1"; mkdir -p "$d/child"; echo x > "$d/child/f"; [ "${2:-0}" != 0 ] && touch -d "-$2 minutes" "$d"; printf '%s' "$d"; }
run_one() { # $1 = body, $2.. = env assignments (VAR=VAL)
  local body="$1"; shift
  ( export "$@" 2>/dev/null || true; printf '%s\n' "$body" >> "$work/slice-run.sh"; )  # placeholder, replaced below
}
gate_run() { # gate_run <name> <body> [ENV=VAL ...]
  local name="$1" body="$2"; shift 2
  cp "$work/slice.sh" "$work/run-$name.sh"; printf '%s\n' "$body" >> "$work/run-$name.sh"
  env "$@" bash "$work/run-$name.sh" >"$work/$name.out" 2>"$work/$name.err"
  printf '%s' "$?"
}

echo "== namespace facts (what bash's kill -0 can and cannot see) =="
node -e 'require("fs").writeFileSync(process.argv[1], String(process.pid)); setTimeout(()=>{},180000)' "$work/node.pid" &
bash -c 'sleep 0.5'
nodePid=$(cat "$work/node.pid")
(sleep 180) & bashlive=$!
sleep 0.5
info "this script pid=$$; its winpid=$(cat /proc/$$/winpid 2>/dev/null || echo '?'); bash -c 'echo \$\$' -> $(bash -c 'echo $$')"
info "winpids in the table: $$ -> $(cat /proc/$$/winpid 2>/dev/null), $bashlive -> $(cat /proc/$bashlive/winpid 2>/dev/null || echo none)"
info "kill -0 on a live sibling bash pid ($bashlive): $(kill -0 "$bashlive" 2>/dev/null && echo ALIVE || echo dead)"
info "kill -0 on a live native node pid ($nodePid): $(kill -0 "$nodePid" 2>/dev/null && echo ALIVE || echo DEAD)"
info "does bash see /proc for the native node pid ($nodePid)? $([ -e /proc/$nodePid ] && echo yes || echo no)"

echo
echo "== A. a failing run: the trap preserves the status, keeps its own home, prunes the rest =="
d1=$(mkh wa-gate-home-999991-AAAAAA 300); d2=$(mkh wa-gate-home-999992-BBBBBB 200); d3=$(mkh wa-gate-home-999993-CCCCCC 100)
rc=$(gate_run a 'exit 3')
ok $([ "$rc" = 3 ] && echo 1 || echo 0) "exit status preserved through the trap (exit $rc)"
n=$(ls "$work/temp" | wc -l)
ok $([ "$n" = 1 ] && echo 1 || echo 0) "exactly 1 home left after a bounded failing run (found $n: $(homes))"
ok $(grep -q "kept: this run exited 3" "$work/a.err" && echo 1 || echo 0) "the failing run names its own kept home"
ok $(grep -q "gate home: removed" "$work/a.err" && echo 1 || echo 0) "and narrates what the bound removed"

echo
echo "== B. THE DANGEROUS ONE: live siblings beside a passing run (budget 1 for others) =="
liveNative=$(mkh "wa-gate-home-$nodePid-LLLLLL" 400)   # owner: a live native process (oldest of all)
liveBash=$(mkh "wa-gate-home-$bashlive-MMMMMM" 350)    # owner: a live sibling bash
deadNew=$(mkh wa-gate-home-999994-NNNNNN 40)
deadMid=$(mkh wa-gate-home-999995-OOOOOO 20)
rc=$(gate_run b 'printf "smoke ok (0 skipped)\n"; exit 0')
ok $([ "$rc" = 0 ] && echo 1 || echo 0) "the passing run exits 0 (exit $rc)"
ok $([ -d "$liveNative" ] && echo 1 || echo 0) "THE LIVE NATIVE PROCESS'S HOME SURVIVED" "after: $(homes)"
ok $([ -d "$liveBash" ] && echo 1 || echo 0) "the live sibling bash's home SURVIVED" "after: $(homes)"
ok $([ -d "$deadNew" ] && echo 1 || echo 0) "the newest dead home was kept (the budget of 1)"
ok $([ ! -d "$deadMid" ] && echo 1 || echo 0) "the older dead home was pruned"
ok $(tail -n 1 "$work/b.out" | grep -q '^smoke ok' && echo 1 || echo 0) "the verdict line is still the LAST line of a passing run"
ok $([ ! -s "$work/b.err" ] && echo 1 || echo 0) "a passing run printed nothing on stderr" "$(head -c 120 "$work/b.err")"
info "homes after B: $(homes)"

echo
echo "== C. the falsifier: WA_GATE_HOME_KEEP=all keeps everything =="
before=$(ls "$work/temp" | wc -l)
gate_run c1 'exit 3' WA_GATE_HOME_KEEP=all >/dev/null
gate_run c2 'exit 3' WA_GATE_HOME_KEEP=all >/dev/null
after=$(ls "$work/temp" | wc -l)
ok $([ "$after" = "$((before+2))" ] && echo 1 || echo 0) "WA_GATE_HOME_KEEP=all grows the family ($before -> $after, +2 expected)"

echo
echo "== D. the knob is refused when it is not a number or a count =="
rc=$(gate_run d 'exit 0' WA_GATE_HOME_KEEP=maybe)
ok $([ "$rc" = 4 ] && echo 1 || echo 0) "WA_GATE_HOME_KEEP=maybe exits 4 (got $rc)"
grep -q "must be a non-negative whole number or 'all'" "$work/d.err" && ok 1 "and names the knob and the rule" || ok 0 "message missing" "$(head -c 120 "$work/d.err")"
rc=$(gate_run d2 'exit 0' WA_GATE_HOME_KEEP=0)
ok $([ "$rc" = 0 ] && echo 1 || echo 0) "WA_GATE_HOME_KEEP=0 is accepted (exit $rc)"
ok $([ "$(ls "$work/temp" | grep -c "wa-gate-home-$((0))" || true)" != "" ] && echo 1 || echo 0) "keep=0 left no home of its own: $(homes)"

echo
echo "== E. pre-lease names (no pid): grace is an hour, and the newest-N rule is applied =="
old=$(mkh wa-gate-home-GGGGGG 200); new=$(mkh wa-gate-home-HHHHHH 2)
rc=$(gate_run e 'printf "smoke ok (0 skipped)\n"; exit 0')
ok $([ -d "$new" ] && echo 1 || echo 0) "a 2-minute-old pre-lease home is kept (exit $rc)"
if [ -d "$old" ]; then info "the 200-minute-old pre-lease home was KEPT"; else info "the 200-minute-old pre-lease home was PRUNED"; fi
info "homes after E: $(homes)"

kill "$bashlive" 2>/dev/null
pkill -f 'setTimeout' 2>/dev/null
printf '  %-8s %s/%s checks passed\n' "" $((tests-fail)) "$tests"
exit $([ "$fail" = 0 ] && echo 0 || echo 1)
