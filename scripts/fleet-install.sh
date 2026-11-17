#!/bin/bash
# Install a node binary from a published artifact — and refuse to leave the node worse than it was.
#
#   fleet-install.sh <artifact-url> [--sha SHA256] [--sig SIGHEX --pub PUBKEY --manifest TEXT]
#
# Why every check below exists, in the order a failure would hurt:
#
# 1. **sha256** — the bytes are the ones that were published, not whatever a proxy served.
# 2. **the signature (optional)** — a manifest signed by the operator's `fleet-release` key, verified
#    offline with the node's own ed25519 (`wa` + `host.verify`), the same pattern the roster uses.
# 3. **it runs here, before anything is replaced** — `--version` on the downloaded file. On 17/11 a
#    native build (glibc 2.39) was installed on two hosts whose glibc is 2.31 and 2.35; both nodes died
#    on restart and could not be reached at all, because the node *is* the channel you would fix it
#    through. A three-second exec test turns that into a refusal with the old binary still in place.
# 4. **backup, then swap** — `wa.prev.<utc>` beside the binary, so the way back is one `cp`.
# 5. **health, then rollback** — after the restart the node must answer `/health`; if it does not, the
#    backup is put back and the node restarted again, so the failure ends with a working node and a
#    named reason instead of a dead one and a silent night.
set -uo pipefail

URL=${1:?artifact url}
shift
SHA=; SIG=; PUB=; MANIFEST=
while [ $# -gt 0 ]; do
  case $1 in
    --sha) SHA=${2:?}; shift 2 ;;
    --sig) SIG=${2:?}; shift 2 ;;
    --pub) PUB=${2:?}; shift 2 ;;
    --manifest) MANIFEST=${2:?}; shift 2 ;;
    --bin) TARGET=${2:?}; shift 2 ;;
    *) echo "fleet-install: unknown_option $1" >&2; exit 2 ;;
  esac
done
TARGET=${TARGET:-$HOME/.local/bin/wa}
HEALTH=${HEALTH:-http://127.0.0.1:8799/health}
# How long a restarted node gets to answer /health. 30 s was too short: after a pkill the sentinel
# restarts the node on its own next check, and a boot measured 17/11 took ~80 s - a healthy artifact was
# rolled back as dead (and the rollback then looked dead too).
UNIT=${UNIT:-}
say() { printf 'fleet-install: %s\n' "$*"; }
die() { printf 'fleet-install: %s\n' "$*" >&2; exit 1; }

# The staging directory is beside the target, not in /tmp: a node whose /tmp is mounted `noexec` would
# refuse every binary as "does not run here", and the guard would cry wolf until nobody believed it.
stage_parent=$(dirname "$TARGET")
mkdir -p "$stage_parent" 2>/dev/null
tmp=$(mktemp -d "$stage_parent/.fleet-install.XXXXXX") || die "no_stage_dir"
trap 'rm -rf "$tmp"' EXIT

say "download $URL"
# Bounded and retried: 17/11 a download from the work container hung for 10 minutes on a stalled HTTP/2
# stream, and the install waited with it.
curl -fsSL --retry 4 --retry-all-errors --connect-timeout 20 --max-time "${DOWNLOAD_TIMEOUT:-300}" \
  -o "$tmp/wa" "$URL" || die "download_failed"

# 1. the bytes
if [ -n "$SHA" ]; then
  got=$(sha256sum "$tmp/wa" | cut -d' ' -f1)
  [ "$got" = "$SHA" ] || die "sha_mismatch got=$got want=$SHA"
  say "sha ok ($SHA)"
fi

# 2. who signed it (optional; nodes that pin a fleet-release key pass these three)
if [ -n "$SIG" ] && [ -n "$PUB" ]; then
  [ -n "$MANIFEST" ] || die "signature_given_without_manifest"
  probe="$tmp/verify.lua"
  cat > "$probe" <<'LUA'
local manifest = host.getenv('FI_MANIFEST') or ''
local signature = host.getenv('FI_SIG') or ''
local pubkey = host.getenv('FI_PUB') or ''
if manifest == '' or signature == '' or pubkey == '' then print('false') return end
print(tostring(host.verify(pubkey, manifest, signature)))
LUA
  # The verifier is the node's **own** binary, never the downloaded artifact: a binary must not be asked
  # to certify itself, and the installed one is the ed25519 implementation this node already trusts.
  verifier=$(command -v wa 2>/dev/null || echo "$TARGET")
  verified=$(FI_MANIFEST="$MANIFEST" FI_SIG="$SIG" FI_PUB="$PUB" \
    WA_SCRIPT="$probe" "$verifier" --db "$tmp/v.db" 2>/dev/null | tail -1)
  [ "$verified" = "true" ] || die "signature_invalid ($verified)"
  say "signature ok"
fi

# 3. does it run HERE, before anything is replaced
chmod +x "$tmp/wa"
if ! "$tmp/wa" --version >/dev/null 2>&1; then
  detail=$("$tmp/wa" --version 2>&1 | head -1)
  die "artifact_does_not_run_here: $detail — nothing was replaced"
fi
say "runs here: $("$tmp/wa" --version)"

# 4. backup and swap
backup="$TARGET.prev.$(date -u +%Y%m%dT%H%M%SZ)"
cp -p "$TARGET" "$backup" 2>/dev/null || say "no previous binary to back up"
install -m755 "$tmp/wa" "$TARGET" || die "install_failed"
say "installed $TARGET (backup $backup)"

# 4b. the Lua tree beside the binary outranks the one compiled into it (wa-host main.rs "An installed Lua
# tree"): a binary install keeps the tree it finds, so the node runs the OLD Lua while `wa --version`
# reports the new build. 17/11: four installs of the codeact fix and every one of them executed commit
# 14963b6f's Lua - presence is not freshness, in the payload too. Move it aside; the way back is `mv`.
lua_dir="$(dirname "$TARGET")/lua-core"
if [ -f "$lua_dir/manifest.txt" ]; then
  stale="$lua_dir.stale.$(date -u +%Y%m%dT%H%M%SZ)"
  mv "$lua_dir" "$stale" || die "cannot_move_stale_lua_tree ($lua_dir)"
  say "moved aside the installed Lua tree ($(sed -n 's/^commit //p' "$stale/manifest.txt" | head -1)): $stale"
fi

# 5. restart, prove it, roll back if it does not
restart() {
  if [ -n "$UNIT" ]; then systemctl --user restart "$UNIT" 2>/dev/null || sudo -n systemctl restart "$UNIT" 2>/dev/null; fi
  if command -v pkill >/dev/null 2>&1; then pkill -f "wa serve --port 8799" 2>/dev/null; fi
}
restart
code=000
for _ in $(seq 1 "${HEALTH_WAIT:-150}"); do
  code=$(curl -s -o /dev/null -m 2 -w '%{http_code}' "$HEALTH" 2>/dev/null || echo 000)
  [ "$code" = "200" ] && break
  sleep 1
done
if [ "$code" != "200" ]; then
  say "UNHEALTHY after restart (last=$code) — rolling back"
  if [ -f "$backup" ]; then
    install -m755 "$backup" "$TARGET" && say "restored $backup"
    restart
    for _ in $(seq 1 "${HEALTH_WAIT:-150}"); do
      code=$(curl -s -o /dev/null -m 2 -w '%{http_code}' "$HEALTH" 2>/dev/null || echo 000)
      [ "$code" = "200" ] && break
      sleep 1
    done
    [ "$code" = "200" ] && die "rolled_back_healthy_after_all (the artifact was refused)" \
                         || die "rolled_back_still_unhealthy: check $TARGET by hand"
  fi
  die "unhealthy_and_no_backup"
fi
# 6. the Lua the node actually loads has to be the one this artifact was built with. `mode()` answering
# nil for a mode the env declares is the signature of a tree (or a build) that predates the code: it is a
# check a healthy `/health` cannot make, and the reason a green install shipped a dead fix.
probe="$tmp/lua.lua"
cat > "$probe" <<'LUA'
local ok, raw = pcall(dofile, 'lua/core/raw_code.lua')
if not ok or type(raw) ~= 'table' or type(raw.mode) ~= 'function' then print('unloadable') return end
local want = tostring(host.getenv('WASM_AGENT_RAW_CODE') or ''):lower()
if want == '1' or want == 'true' then want = 'on' end
if want == '' then print('skip') return end
local got = tostring(raw.mode())
print(want == got and 'ok' or ('mismatch: env says ' .. want .. ', this Lua says ' .. got))
LUA
verdict=$("$TARGET" --db "$tmp/l.db" >/dev/null 2>&1; WA_SCRIPT="$probe" "$TARGET" --db "$tmp/l.db" 2>/dev/null | tail -1)
case "$verdict" in
  ok|skip) say "lua matches this artifact ($verdict)" ;;
  *)
    say "LUA MISMATCH after install ($verdict) — rolling back"
    if [ -f "$backup" ]; then install -m755 "$backup" "$TARGET"; fi
    if [ -n "${stale:-}" ] && [ -d "$stale" ]; then mv "$stale" "$lua_dir"; fi
    restart
    die "rolled_back_lua_mismatch: $verdict"
    ;;
esac

say "healthy (200) — installed $(basename "$TARGET") from $URL"
