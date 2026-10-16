#!/usr/bin/env bash
# Human-run deterministic artifact build; never installs or starts a service.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[ -z "$(git status --porcelain)" ] || { echo 'clean committed source required' >&2; exit 1; }
: "${GO:?set GO to the absolute verified Go 1.27.2 executable}"
[ "$("$GO" version | awk '{print $3}')" = go1.27.2 ] || { echo 'Go 1.27.2 required' >&2; exit 1; }
export GOTOOLCHAIN=local CGO_ENABLED=0
TREE="$(git rev-parse HEAD^{tree})"
OUT="$ROOT/target/whatsapp-linux-$TREE"
[ ! -e "$OUT" ] || { echo 'fresh output required' >&2; exit 1; }
mkdir -p "$OUT"
GO_OUT="$(cygpath -m "$OUT/wa-whatsapp" 2>/dev/null || printf '%s' "$OUT/wa-whatsapp")"
(cd connectors/whatsapp && "$GO" mod verify && GOOS=linux GOARCH=amd64 "$GO" build -trimpath -o "$GO_OUT" .)
cp scripts/whatsapp-stt-local.py "$OUT/whatsapp-stt-local.py"
cp scripts/whatsapp-install.py "$OUT/whatsapp-install.py"
cp connectors/whatsapp/THIRD-PARTY-NOTICES.txt "$OUT/THIRD-PARTY-NOTICES.txt"
OUT_ARG="$(cygpath -m "$OUT" 2>/dev/null || printf '%s' "$OUT")"
python - "$OUT_ARG" "$(git rev-parse HEAD)" "$TREE" <<'PY'
import hashlib,json,pathlib,sys
out=pathlib.Path(sys.argv[1])
files={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in out.iterdir() if p.is_file()}
manifest={'schema':1,'source':sys.argv[2],'tree':sys.argv[3],'platform':'linux-amd64','files':files}
p=out/'manifest.json';p.write_text(json.dumps(manifest,sort_keys=True,indent=2)+'\n',encoding='utf-8')
print('manifest_sha256='+hashlib.sha256(p.read_bytes()).hexdigest())
PY
printf 'bundle=%s\n' "$OUT"
