#!/usr/bin/env bash
# F6 end-to-end: does the REAL deploy.sh collect residue that a killed copy left staged?
# Private install dir, scratch git tree, no cargo on PATH -> the deploy refuses at the build, after the sweep.
set -uo pipefail
REPO="$1"; LABEL="$2"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-f6e2e-XXXXXX")"
BIG="$WORK/big.bin"; head -c 40000000 /dev/urandom > "$BIG" || dd if=/dev/urandom of="$BIG" bs=1M count=40 2>/dev/null
TREE="$WORK/tree"; INSTALL="$WORK/install"; HOMED="$WORK/home"; mkdir -p "$TREE/scripts" "$TREE/rust" "$INSTALL/scripts/lib" "$HOMED"
git -C "$TREE" init -q --initial-branch=main; git -C "$TREE" config user.name f; git -C "$TREE" config user.email f@x.invalid
printf 'tree\n' > "$TREE/README"; git -C "$TREE" add -A >/dev/null 2>&1; git -C "$TREE" commit -qm fixture
git -C "$TREE" update-ref refs/remotes/origin/main "$(git -C "$TREE" rev-parse HEAD)"
# Residue #1: a staged copy killed mid-write (SIGKILL), exactly the sentinel shape and the measured size class.
cp -f "$BIG" "$INSTALL/wa-sentinel.exe.new.777777" & CP_PID=$!
sleep 0.2; kill -9 "$CP_PID" 2>/dev/null; wait "$CP_PID" 2>/dev/null
# Residue #2: a killed ship_file staging of a shipped script.
cp -f "$BIG" "$INSTALL/scripts/lib/service-target.sh.ship.888888" & CP2=$!
sleep 0.2; kill -9 "$CP2" 2>/dev/null; wait "$CP2" 2>/dev/null
touch -d '3 hours ago' "$INSTALL/wa-sentinel.exe.new.777777" "$INSTALL/scripts/lib/service-target.sh.ship.888888" 2>/dev/null
echo "[$LABEL] before: $(ls -l "$INSTALL"/wa-sentinel.exe.new.777777 "$INSTALL"/scripts/lib/service-target.sh.ship.888888 2>&1 | awk '{printf "%s(%s bytes) ", $NF, $5}')"
GIT_BIN="$(dirname "$(command -v git)")"
cd "$TREE" && env -u WASM_AGENT_IN_TURN -u LOCALAPPDATA -u APPDATA HOME="$HOMED" WASM_AGENT_HOME="$HOMED" \
  PATH="/usr/bin:/bin:$GIT_BIN" WA_DEPLOY_ROOT="$TREE" WA_INSTALL_DIR="$INSTALL" WA_PORT=8987 WA_CLIENT_PORT=8988 \
  bash "$REPO/scripts/deploy.sh" --reason "f6-e2e $LABEL" > "$WORK/out.txt" 2>&1; DEPLOY_EXIT=$?
echo "[$LABEL] deploy exit=$DEPLOY_EXIT ; last line: $(tail -1 "$WORK/out.txt" | cut -c1-110)"
echo "[$LABEL] deploy.log sweep lines:"; grep -a 'staging residue' "$INSTALL/deploy.log" 2>/dev/null | sed "s/^/      /" || echo "      (no sweep note in deploy.log)"
echo "[$LABEL] after: $(ls "$INSTALL"/wa-sentinel.exe.new.777777 "$INSTALL"/scripts/lib/service-target.sh.ship.888888 2>&1 | sed "s|$WORK|<work>|g" | tr '\n' ' ')"
du -sh "$INSTALL" 2>/dev/null | sed "s|$WORK|<work>|" | sed "s/^/[$LABEL] install dir on disk: /"
rm -rf "$WORK"
