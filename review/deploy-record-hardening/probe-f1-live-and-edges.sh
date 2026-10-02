#!/usr/bin/env bash
# (a) the LIVE install's own two files, copied into a private fixture: what does the tip's verifier say?
# (b) two edges of the new check: a verdict with no `at=`, and a record with no `at=`.
set -uo pipefail
REPO="$1"; LIVE="$2"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-live-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
TREE="$WORK/source"; INSTALL="$WORK/install"; HOMED="$WORK/home"; MOCK="$WORK/mock-bin"
mkdir -p "$TREE" "$INSTALL" "$HOMED" "$MOCK"
SHIPPED="scripts/deploy.sh scripts/upgrade.sh skills/self-update/SKILL.md skills/git-orchestrator/SKILL.md skills/git-orchestrator/scripts/audit.mjs"
for rel in $SHIPPED; do mkdir -p "$(dirname "$TREE/$rel")"; cp -f "$REPO/$rel" "$TREE/$rel"; done
git -C "$TREE" init -q --initial-branch=main; git -C "$TREE" config user.name f; git -C "$TREE" config user.email f@x.invalid
git -C "$TREE" config core.hooksPath "$WORK/no-hooks"
for rel in $SHIPPED; do case "$rel" in skills/*) d="$HOMED/.wasm-agent/$rel" ;; *) d="$INSTALL/$rel" ;; esac; mkdir -p "$(dirname "$d")"; cp -f "$TREE/$rel" "$d"; done
cp -f "$LIVE/wa" "$INSTALL/wa" 2>/dev/null || printf 'a fixture binary\n' > "$INSTALL/wa"
printf '#!/usr/bin/env bash\necho "sentinel: watching (pid 5678)"\necho "requests: readable"\n' > "$INSTALL/wa-sentinel"
git -C "$TREE" add -A >/dev/null 2>&1; git -C "$TREE" commit -qm 'built artifact fixture'
printf '#!/usr/bin/env bash\necho "{\"ok\":true}"\n' > "$MOCK/curl"
printf '#!/usr/bin/env bash\necho "LISTEN 0 4096 127.0.0.1:8799 0.0.0.0:* users:((\"wa\",pid=1234,fd=3))"\n' > "$MOCK/ss"
printf '#!/usr/bin/env bash\necho 1234\n' > "$MOCK/powershell.exe"; chmod +x "$MOCK"/*; printf '1234\n' > "$INSTALL/serve.pid"
H="$(sha256sum < "$INSTALL/wa" | awk '{print $1}')"; SH="$(sha256sum < "$INSTALL/wa-sentinel" | awk '{print $1}')"
report() { node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);
console.log("   verdict "+(j.ok?"PASS":"FAIL")+" checks="+j.checks+" failed="+j.failed+" skipped="+j.skipped);
for(const r of j.results.filter(r=>/final one|verdict matches/.test(r.name)))
  console.log("   ["+r.status+"] "+r.name+" :: "+String(r.detail).slice(0,190));});'; }
run_verify() { (cd "$TREE" && env -u WASM_AGENT_HOME HOME="$HOMED" USERPROFILE="$HOMED" WA_INSTALL_DIR="$INSTALL" \
    WA_DEPLOY_ROOT="$TREE" PATH="$MOCK:$PATH" bash "$REPO/scripts/verify-install.sh" --json 2>&1) | report; }

echo "(a) the LIVE install's installed.txt + deploy-result.json, byte for byte, in a private fixture:"
cp -f "$LIVE/installed.txt" "$INSTALL/installed.txt"; cp -f "$LIVE/deploy-result.json" "$INSTALL/deploy-result.json"
echo "    live record_role/via: $(grep -E '^(record_role|via|commit)=' "$LIVE/installed.txt" | tr '\n' ' ')"
echo "    live verdict: $(head -c 90 "$LIVE/deploy-result.json")"
run_verify

echo "(b) edge 1: a deploy's final record, an ok verdict with NO \\\"at\\\" field (its age cannot be established):"
printf 'commit=deadbee\nbranch=main\ndirty=0\nsha256=%s\nsentinel_sha256=%s\ninstall_dir=%s\nsource_provenance=clean-built-by-deploy\nrecord_role=final\nvia=deploy.sh\nat=2026-10-02T19:30:02Z\nreason=fixture\n' "$H" "$SH" "$INSTALL" > "$INSTALL/installed.txt"
printf '{"ok":true,"commit":"deadbee","detail":"an ancient deploy with no timestamp"}\n' > "$INSTALL/deploy-result.json"
run_verify

echo "(c) edge 2: a deploy's final record with NO \\\"at\\\" line, beside a stale ok verdict:"
printf 'commit=deadbee\nbranch=main\ndirty=0\nsha256=%s\nsentinel_sha256=%s\ninstall_dir=%s\nsource_provenance=clean-built-by-deploy\nrecord_role=final\nvia=deploy.sh\nreason=fixture\n' "$H" "$SH" "$INSTALL" > "$INSTALL/installed.txt"
printf '{"ok":true,"commit":"deadbee","detail":"an earlier deploy","at":"2020-01-01T00:00:00Z"}\n' > "$INSTALL/deploy-result.json"
run_verify
