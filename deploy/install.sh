#!/usr/bin/env bash
# Stand up a wasm-agent node (and optionally the rendezvous+relay) on Ubuntu.
#
# Idempotent: re-running only fixes what is missing. It touches only
# wasm-agent's own files and systemd units — it does not modify Caddy or DNS,
# which are printed as instructions instead (they may be shared with other apps).
#
#   sudo bash deploy/install.sh                 # node only
#   sudo bash deploy/install.sh --with-relay    # node + rendezvous/relay
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
USER_NAME="${SUDO_USER:-$(id -un)}"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
ROOT="$(cd "$HERE/.." && pwd)"
WA="$USER_HOME/.local/bin/wa"
STATE="$USER_HOME/.wasm-agent"
WITH_RELAY=0
[ "${1:-}" = "--with-relay" ] && WITH_RELAY=1

step() { printf '  * %s\n' "$1"; }
ok()   { printf '    ok %s\n' "$1"; }

echo
echo "  wasm-agent deploy"
echo

step "state directory"
mkdir -p "$STATE"
chown "$USER_NAME":"$USER_NAME" "$STATE"
ok "$STATE"

step "configuration"
if [ -f "$STATE/env" ]; then
  ok "$STATE/env exists (left untouched)"
else
  install -o "$USER_NAME" -g "$USER_NAME" -m 600 "$HERE/env.example" "$STATE/env"
  ok "created $STATE/env from env.example — FILL IN THE KEYS"
fi

step "binary"
if [ -x "$WA" ]; then
  ok "$WA ($("$WA" --version 2>/dev/null || echo '?'))"
else
  echo "    ! $WA is missing."
  echo "      build it:  cd $ROOT/rust && cargo build --release --offline && mv target/release/wa $WA"
fi

step "node unit (wa-serve)"
install -m 644 "$HERE/wa-serve.service" /etc/systemd/system/wa-serve.service
ok "installed wa-serve.service"

if [ "$WITH_RELAY" = 1 ]; then
  step "rendezvous/relay unit (wa-rendezvous)"
  install -m 644 "$HERE/wa-rendezvous.service" /etc/systemd/system/wa-rendezvous.service
  ok "installed wa-rendezvous.service"
fi

step "enable and start"
systemctl daemon-reload
systemctl enable --now wa-serve.service >/dev/null 2>&1 || true
[ "$WITH_RELAY" = 1 ] && { systemctl enable --now wa-rendezvous.service >/dev/null 2>&1 || true; }
sleep 1
for unit in wa-serve wa-rendezvous; do
  if systemctl list-unit-files | grep -q "^$unit.service"; then
    printf '    %-16s %s\n' "$unit" "$(systemctl is-active "$unit" 2>/dev/null || echo inactive)"
  fi
done

echo
echo "  next (not automated: shared with other apps)"
echo "    1. DNS:  rendezvous.colmeio.com  A  <reserved public IP>"
echo "    2. Caddy: append deploy/caddy/rendezvous.colmeio.com.caddy to"
echo "       /etc/caddy/Caddyfile, then:"
echo "         caddy validate --config /etc/caddy/Caddyfile && systemctl restart caddy"
echo "       (reload does not work: the Caddyfile sets 'admin off')"
echo "    3. Firewall: allow 443/tcp (Caddy). Nothing else needs to be public —"
echo "       nodes dial the relay outbound. 8890 stays on localhost."
echo "    4. Verify:"
echo "         curl -s http://127.0.0.1:8799/health"
echo "         curl -s https://rendezvous.colmeio.com/health"
echo "         curl -s https://rendezvous.colmeio.com/relay/status"
echo "         wa nodes"
echo
