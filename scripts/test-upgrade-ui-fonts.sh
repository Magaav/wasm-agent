#!/usr/bin/env bash
# DOES AN INSTALL CARRY THE UI THE RELEASE SHIPS - the faces included? (mission fonts-install item 1, 21/11)
#
# The failure this exists for, measured on this node: ~/.local/share/wasm-agent/ui was dated 16/11 and held no
# fonts/ directory, although ui/index.html loads ui/fonts.css and ui/fonts.css names ui/fonts/*.ttf. The node
# served a stylesheet 404 for every UI change since, and 'wa setup fonts' - whose whole job is to copy those
# faces into the user's font directory - found no bundle on the machine that had just shipped the page.
#
# WHAT IT DOES. It RUNS scripts/upgrade.sh against a scratch install and a scratch release tree, with the
# node-facing steps stubbed the way scripts/test-upgrade-idle.sh stubs them (a curl that answers /health, a
# candidate proved by hash), and then reads the installed ui/ back off disk:
#
#   1. every file the installer declares is copied, faces and fonts.css included;
#   2. the faces arrive even though they are one directory down (fonts/ did not exist in the install before);
#   3. 'wa setup fonts' would find a COMPLETE bundle in that installed ui/ - the same three files, present;
#   4. a release that carries ui/fonts.css and NOT its faces is refused, naming what is missing, before the
#      node is touched (a release that loads fonts.css cannot ship without the files it names);
#   5. a downgrade to a release from BEFORE the faces existed (one with no ui/fonts.css) still installs: an
#      older release legitimately has no fonts, and the rollback path must keep working.
#
# Hermetic: mktemp per run, a scratch HOME, WA_INSTALL_DIR and WA_HOME_BEFORE_OVERRIDE, no sentinel, no
# watchdog, no real node, and nothing outside the temp tree is read or written.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d /tmp/wa-uifonts-XXXXXX)"
# THE PIDS THIS TEST STARTS, and only those: the stub node is killed by the pid the stub watchdog recorded, never
# by a name pattern (a pkill here once took down a runner's own watcher, 21/11).
PIDS="$WORK/pids"
: > "$PIDS"
cleanup() {
  while read -r pid; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done < "$PIDS"
  rm -rf "$WORK"
}
trap cleanup EXIT

checks=0; failed=0
ok()  { checks=$((checks + 1)); printf '  ok   %s\n' "$*"; }
bad() { checks=$((checks + 1)); failed=$((failed + 1)); printf '  FAIL %s\n' "$*"; }

# A scratch home that is not the operator's: the guard every row here relies on.
case "${HOME:-}" in
  '') echo "REFUSED uifonts: HOME is not set, so a scratch home cannot be proven distinct" >&2; exit 2 ;;
esac
if [ -z "${WASM_AGENT_HOME:-}" ] || [ "${WASM_AGENT_HOME}" = "${HOME}" ] \
   || [ "${WASM_AGENT_HOME}" = "${HOME}/.wasm-agent" ] \
   || [ "${WASM_AGENT_HOME#${HOME}/.wasm-agent/}" != "${WASM_AGENT_HOME}" ]; then
  echo "REFUSED uifonts: WASM_AGENT_HOME (${WASM_AGENT_HOME:-unset}) must be a scratch home, not $HOME or its store" >&2
  exit 2
fi

# THE RELEASE TREE: the ui/ a commit ships, with the faces, plus the scripts upgrade.sh insists are beside it.
make_release() { # dir release-id [with-fonts]
  local dir="$1" id="$2" with_fonts="${3:-yes}"
  mkdir -p "$dir/ui/fonts" "$dir/scripts/lib" "$dir/skills"
  for name in index.html app.js components.js style.css render.wasm manifest.webmanifest service-worker.js icon-192.png icon-512.png; do
    printf '%s %s\n' "$id" "$name" > "$dir/ui/$name"
  done
  if [ "$with_fonts" = "yes" ]; then
    # THE STYLESHEET NAMES THE FACES, exactly as ui/fonts.css does (three url() lines), because that is what
    # makes "a release that ships fonts.css must ship the files it names" a check with something to read.
    {
      printf '/* %s fonts.css */\n' "$id"
      for face in JetBrainsMono-Regular.ttf JetBrainsMono-Bold.ttf; do
        printf '@font-face { font-family: "JetBrains Mono"; src: url("fonts/%s") format("truetype"); }\n' "$face"
      done
      printf '@font-face { font-family: "wa Icons"; src: url("fonts/waIcons-Regular.ttf") format("truetype"); }\n'
    } > "$dir/ui/fonts.css"
    for face in waIcons-Regular.ttf JetBrainsMono-Regular.ttf JetBrainsMono-Bold.ttf OFL-JetBrainsMono.txt LICENSE-SymbolsNerdFont-MIT.txt; do
      printf '%s %s\n' "$id" "$face" > "$dir/ui/fonts/$face"
    done
  fi
  cp -f "$ROOT/scripts/upgrade.sh" "$dir/scripts/upgrade.sh"
  # The libs upgrade.sh sources are the INSTALLER's, not the code under test: turn-guard, service-target,
  # glibc-floor, install-record, node-pins. Copied from this tree so they can never be a stale fixture.
  cp -f "$ROOT"/scripts/lib/*.sh "$dir/scripts/lib/"
}

# THE CANDIDATE: it names its own build (upgrade.sh refuses a candidate that cannot) and answers --version.
# THE CANDIDATE IS ALSO THE NODE: it names its own build (upgrade.sh refuses a candidate that cannot), and
# when upgrade.sh STARTS it ('serve') it listens on the port this script gave it. The listener is not
# decoration: upgrade.sh keeps the install only when the pid on the port is the pid it recorded, so a stub
# that exits would take the release for a failure and roll it back - the UI copy runs before that, but the
# rollback would then restore the .pre-upgrade files and hide what was just installed.
CANDIDATE="$WORK/candidate"
cat > "$CANDIDATE" <<'WASH'
#!/bin/sh
case "$1" in
  --build-info) printf 'version=9.9.9\ncommit=1111111111111111111111111111111111111111\ntree=2222222222222222222222222222222222222222\ndirty=false\nsource=git\nbuilt_epoch=1795000000\nancestors=1\nancestors_complete=true\n' ;;
  --version) echo 'wasm-agent 9.9.9' ;;
  serve)
    port=''
    while [ $# -gt 0 ]; do case "$1" in --port) shift; port="${1:-}" ;; esac; shift; done
    exec python3 -c "
import http.server, sys
port = int(sys.argv[1])
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'{\"ok\":true,\"build\":\"9.9.9\"}'
        self.send_response(200); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', port), H).serve_forever()
" "$port" ;;
  *) exit 0 ;;
esac
WASH
chmod +x "$CANDIDATE"
HASH="$(sha256sum < "$CANDIDATE" | awk '{print $1}')"

# THE NODE-FACING STEPS, stubbed: curl answers /health (what wait_health reads) and the pid/port probes answer
# nothing, so the script reaches its UI copy and its restart without a node, a sentinel or a watchdog.
STUB="$WORK/bin"
mkdir -p "$STUB"
# The idle gate reads the node's own /health: a worker that keeps REPORTING is doing work, so the upgrade
# waits for it (and this test would wait 900 s for a worker it never described). The same fixture
# scripts/test-upgrade-idle.sh uses: an idle node with a live worker.
cat > "$STUB/curl" <<'SH'
#!/bin/sh
printf '%s' '{"ok":true,"build":"9.9.9","node_state":{"busy_threads":0,"queue":0,"state":"idle"},"subagents":{"active":0,"queued":0,"running":0},"runs":[],"queue":0,"worker":"alive"}'
SH
chmod +x "$STUB/curl"

# THE WATCHDOG IS STUBBED, because the switch is its job and a node cannot replace itself: with WA_WATCHDOG=1
# upgrade.sh hands the swap to it and this stub starts the new node on the harness's port, exactly as the real
# one does - the pid recorded in <home>/kernel.pid must be the pid LISTENING, which is what upgrade.sh checks.
make_watchdog() { # install-dir
  cat > "$1/wa-watchdog" <<'WSH'
#!/bin/sh
case "$1" in
  swap)
    binary="$2"
    home=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --home) shift; home="${1:-}" ;;
        --sha256|--wait-ms) shift ;;
      esac
      shift
    done
    [ -n "$home" ] || exit 2
    mkdir -p "$home"
    # THE REAL WATCHDOG STOPS THE OLD KERNEL before the new one takes the port (that is what makes the listener
    # check meaningful), so the stub does too: the pid it stops is the one the install recorded, never a pattern.
    old=''
    [ -f "${binary%/*}/serve.pid" ] && old="$(tr -d '[:space:]' < "${binary%/*}/serve.pid")"
    [ -n "$old" ] && kill "$old" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      ss -ltn 2>/dev/null | grep -q ":${WA_TEST_PORT:-1} " || break
      sleep 0.1
    done
    "$binary" serve --port "${WA_TEST_PORT:-1}" >/dev/null 2>&1 &
    echo $! >> "${WA_TEST_PIDS:-/dev/null}"
    echo $! > "$home/kernel.pid"
    # WAIT FOR THE PORT TO LISTEN - not for curl. curl is stubbed in this harness (it answers the idle gate),
    # so asking it would report "up" before the new kernel ever bound, and upgrade.sh would then find no pid on
    # the port and roll back the UI it had just installed. The kernel's own socket table is the answer.
    for _ in $(seq 1 100); do
      if ss -ltn 2>/dev/null | grep -q ":${WA_TEST_PORT:-1} "; then exit 0; fi
      sleep 0.1
    done
    exit 1 ;;
  *) exit 0 ;;
esac
WSH
  chmod +x "$1/wa-watchdog"
}

install_for() { # name -> echoes the scratch install dir, prepared with a record and the proof cache
  local inst="$WORK/$1"
  mkdir -p "$inst/scripts/lib" "$inst/ui"
  make_watchdog "$inst"
  cp -f "$CANDIDATE" "$inst/wa.candidate"
  chmod +x "$inst/wa.candidate"
  cp -f "$ROOT"/scripts/lib/*.sh "$inst/scripts/lib/"
  # an installed node already on disk: the binary, and ONE asset so the .pre-upgrade backup has something
  cp -f "$CANDIDATE" "$inst/wa"
  printf 'old index\n' > "$inst/ui/index.html"
  printf 'commit=1111111111111111111111111111111111111111\ntree=2222222222222222222222222222222222222222\ndirty=false\nsha256=%s\n' "$HASH" > "$inst/installed.txt"
  printf '%s\n' "$HASH" > "$inst/.upgrade-proof"
  printf '%s\n' "$inst"
}

run_upgrade() { # install release-tree
  WA_TEST_PORT="$(free_port)"
  # A NODE IS ALREADY RUNNING on it, as on every machine an upgrade is asked for: upgrade.sh reads the listener's
  # pid to stop it and to compare against the pid the watchdog records, and an install with nothing listening
  # takes a different path (start_node) that this test is not about.
  "$1/wa" serve --port "$WA_TEST_PORT" >/dev/null 2>&1 &
  STUB_NODE=$!
  echo "$STUB_NODE" >> "$PIDS"
  printf '%s\n' "$STUB_NODE" > "$1/serve.pid"
  for _ in $(seq 1 50); do
    ss -ltn 2>/dev/null | grep -q ":$WA_TEST_PORT " && break
    sleep 0.1
  done
  env -u WASM_AGENT_IN_TURN -u WASM_AGENT_RENDEZVOUS -u WASM_AGENT_RELAY \
    WA_INSTALL_DIR="$1" WA_PORT="$WA_TEST_PORT" WA_SENTINEL_SCRIPTS="$WORK/no-sentinel" \
    WA_WATCHDOG=1 WA_TEST_PORT="$WA_TEST_PORT" WA_TEST_PIDS="$PIDS" \
    WA_IDLE_TIMEOUT=5 WA_UPGRADE_IDLE_POLL=1 \
    WASM_AGENT_HOME="$WORK/home" WA_HOME_BEFORE_OVERRIDE="$WORK/home" \
    PATH="$STUB:$PATH" \
    bash "$2/scripts/upgrade.sh" "$CANDIDATE" 2>&1
}

mkdir -p "$WORK/home"

# ONE FREE PORT for the whole run, asked of the kernel rather than guessed: every upgrade below starts its
# stub node on it, and upgrade.sh's own listener check reads the pid that ends up there.
# A FRESH FREE PORT PER UPGRADE, asked of the kernel rather than guessed. It has to be fresh: upgrade.sh checks
# that the pid LISTENING is the pid its watchdog recorded, so a stub node left over from an earlier case on a
# shared port made the next switch look like a failure and rolled the UI back.
free_port() {
  local port
  port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
  [ -n "$port" ] || { echo "REFUSED uifonts: no free port could be measured" >&2; exit 2; }
  printf '%s' "$port"
}

echo "--- 1. a release WITH the faces: they reach the installed ui/, fonts.css first and the faces beside it ---"
RELEASE="$WORK/release-with-fonts"
make_release "$RELEASE" new yes
INST="$(install_for with-fonts)"
OUT="$(run_upgrade "$INST" "$RELEASE")"
printf '%s\n' "$OUT" | sed 's/^/    /'
if [ -f "$INST/ui/fonts.css" ]; then ok "the installed ui/ carries fonts.css"; else bad "the installed ui/ has no fonts.css (the page loads it): $OUT"; fi
faces_present=0
for face in waIcons-Regular.ttf JetBrainsMono-Regular.ttf JetBrainsMono-Bold.ttf OFL-JetBrainsMono.txt LICENSE-SymbolsNerdFont-MIT.txt; do
  [ -f "$INST/ui/fonts/$face" ] && faces_present=$((faces_present + 1))
done
if [ "$faces_present" = 5 ]; then ok "all five files in ui/fonts/ were installed, into a directory that did not exist"; else bad "only $faces_present of 5 files reached $INST/ui/fonts/: $OUT"; fi
# 3. THE BUNDLE 'wa setup fonts' READS: the same three faces its own list names, in ui/fonts.
setup_faces=0
for face in waIcons-Regular.ttf JetBrainsMono-Regular.ttf JetBrainsMono-Bold.ttf; do
  [ -f "$INST/ui/fonts/$face" ] && setup_faces=$((setup_faces + 1))
done
if [ "$setup_faces" = 3 ]; then ok "'wa setup fonts' finds a complete bundle in the installed ui/fonts/"; else bad "the installed bundle is incomplete ($setup_faces of 3 faces), so the setup would refuse: $OUT"; fi
if [ -f "$INST/ui/index.html.pre-upgrade" ]; then ok "the asset that was already there was backed up before the swap"; else bad "no .pre-upgrade backup was taken of the installed index.html"; fi

echo "--- 2. a release whose fonts.css has NO faces beside it is REFUSED, naming what is missing ---"
HALF="$WORK/release-half-fonts"
make_release "$HALF" half yes
rm -f "$HALF"/ui/fonts/*.ttf
INST2="$(install_for half)"
BEFORE_INDEX="$(cat "$INST2/ui/index.html")"
OUT2="$(run_upgrade "$INST2" "$HALF")"
printf '%s\n' "$OUT2" | sed 's/^/    /'
case "$OUT2" in
  *"missing release UI asset: fonts/"*) ok "the refusal names the faces the release does not carry" ;;
  *) bad "expected a missing-release-asset refusal naming fonts/, got: $OUT2" ;;
esac
if [ "$(cat "$INST2/ui/index.html")" = "$BEFORE_INDEX" ]; then ok "and nothing in the installed ui/ was replaced"; else bad "the install was touched although the release was incomplete"; fi

echo "--- 3. a DOWNGRADE to a release from before the faces existed still installs ---"
OLD="$WORK/release-old"
make_release "$OLD" old no
rm -f "$OLD/ui/fonts.css"; rmdir "$OLD/ui/fonts" 2>/dev/null || true
INST3="$(install_for old)"
OUT3="$(run_upgrade "$INST3" "$OLD")"
printf '%s\n' "$OUT3" | sed 's/^/    /'
case "$OUT3" in
  *"missing release UI asset: fonts.css"*) bad "an older release without fonts/ was refused: $OUT3" ;;
  *) ok "an older release that carries no ui/fonts.css is installed anyway (the rollback path keeps working)" ;;
esac
if [ -f "$INST3/ui/index.html" ] && ! [ "$(cat "$INST3/ui/index.html")" = "old index" ]; then
  ok "and its own index.html was installed"
else
  bad "the older release's index.html did not reach the installed ui/: $OUT3"
fi

rm -rf "$WORK"
trap - EXIT
if [ "$failed" -eq 0 ]; then echo "ui fonts install: ok ($checks checks)"; exit 0; fi
echo "ui fonts install: FAILED ($checks checks, $failed failed)"
exit 1
