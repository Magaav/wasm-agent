#!/bin/sh
# Keep the local forward to the rendezvous WhatsApp connector alive.
#
# The MCP binding talks to the connector at a numeric loopback URL. When the
# connector runs on the rendezvous, that loopback is an SSH forward. A scheduled
# task starts this script once; ssh's own keepalive detects a dead peer, and this
# loop reconnects when the ssh process exits for any other reason.
#
# Environment (all optional):
#   WA_WHATSAPP_TUNNEL_HOST           SSH host of the rendezvous (openclaw.ohana)
#   WA_WHATSAPP_TUNNEL_LOCAL_PORT     local loopback port (28787)
#   WA_WHATSAPP_TUNNEL_REMOTE_PORT    connector port on the host (28787)
#   WA_WHATSAPP_TUNNEL_RETRY_SECONDS  pause before reconnecting (5)
set -u
host=${WA_WHATSAPP_TUNNEL_HOST:-openclaw.ohana}
local_port=${WA_WHATSAPP_TUNNEL_LOCAL_PORT:-28787}
remote_port=${WA_WHATSAPP_TUNNEL_REMOTE_PORT:-28787}
retry=${WA_WHATSAPP_TUNNEL_RETRY_SECONDS:-5}

while :; do
  ssh -N -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
    -L "${local_port}:127.0.0.1:${remote_port}" "$host" || true
  sleep "$retry"
done
