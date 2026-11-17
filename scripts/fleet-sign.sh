#!/bin/bash
# Sign one published artifact with the fleet's release key, so a node can refuse anything else.
#
#   fleet-sign.sh <artifact-file> [name]
#
# Writes beside the artifact (`<artifact>.manifest.json`, `<artifact>.manifest.sig`) and prints the
# three values `fleet-install.sh` wants: the manifest, its signature, and the public key to verify it.
#
# The manifest is ONE canonical line with sorted keys: a signature covers bytes, so the bytes have to be
# reproducible on the node that verifies them. The key lives in the operator's vault (`fleet-release`)
# and never travels: the node verifies against the public half, offline, the same way it verifies a
# roster. Measured 17/11: an unsigned, host-native build was installed on two hosts whose glibc could
# not run it, and both nodes died. A signed manifest would not have caught that on its own — the exec
# test in `fleet-install.sh` does — but together they close the class: the bytes are the operator's, and
# they run here or nothing is replaced.
set -uo pipefail
artifact=${1:?artifact path}
name=${2:-$(basename "$artifact")}
[ -f "$artifact" ] || { echo "fleet-sign: no such artifact: $artifact" >&2; exit 2; }
VAULT_DIR=${WASM_AGENT_VAULT_DIR:-$HOME/.wasm-agent/vault}
WA=$(command -v wa || echo "$HOME/.local/bin/wa")

sha=$(sha256sum "$artifact" | cut -d' ' -f1)
bytes=$(stat -c%s "$artifact")
commit=$(git -C "$(dirname "$artifact")" rev-parse HEAD 2>/dev/null || echo "")
built=$(date -u +%Y-%m-%dT%H:%M:%SZ)
manifest=$(python3 - "$name" "$sha" "$bytes" "$commit" "$built" <<'PY'
import json, sys
name, sha, size, commit, built = sys.argv[1:6]
print(json.dumps({"name": name, "sha256": sha, "bytes": int(size),
                  "commit": commit, "built_utc": built}, sort_keys=True, separators=(",", ":")))
PY
)
[ -n "$manifest" ] || { echo "fleet-sign: manifest_failed" >&2; exit 1; }

scratch=$(mktemp) || exit 1
printf '%s' "$manifest" > "$scratch"
sig=$(WASM_AGENT_VAULT_DIR="$VAULT_DIR" "$WA" vault sign fleet-release --from "$scratch" 2>/dev/null | tr -d '\n')
rm -f "$scratch"
[ -n "$sig" ] || { echo "fleet-sign: sign_failed (is fleet-release in the vault?)" >&2; exit 1; }
pub=$(WASM_AGENT_VAULT_DIR="$VAULT_DIR" "$WA" vault public-key fleet-release 2>/dev/null | tail -1)

printf '%s\n' "$manifest" > "$artifact.manifest.json"
printf '%s\n' "$sig" > "$artifact.manifest.sig"
printf 'MANIFEST=%s\nSIG=%s\nPUB=%s\nSHA=%s\n' "$manifest" "$sig" "$pub" "$sha"
