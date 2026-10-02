#!/usr/bin/env bash
# Does a HAND-RUN upgrade (via=upgrade.sh) launder a deploy's INTERIM record into `final` and thereby hide
# the deploy death from the verifier? Uses the real verify-install.sh and the real record_install from upgrade.sh.
set -uo pipefail
REPO="$1"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-launder-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
TREE="$WORK/source"; INSTALL="$WORK/install"; HOMED="$WORK/home"; MOCK="$WORK/mock-bin"
mkdir -p "$TREE" "$INSTALL" "$HOMED" "$MOCK"
SHIPPED="scripts/deploy.sh scripts/upgrade.sh skills/self-update/SKILL.md skills/git-orchestrator/SKILL.md skills/git-orchestrator/scripts/audit.mjs"
for rel in $SHIPPED; do mkdir -p "$(dirname "$TREE/$rel")"; cp -f "$REPO/$rel" "$TREE/$rel"; done
git -C "$TREE" init -q --initial-branch=main; git -C "$TREE" config user.name f; git -C "$TREE" config user.email f@x.invalid
git -C "$TREE" config core.hooksPath "$WORK/no-hooks"
for rel in $SHIPPED; do case "$rel" in skills/*) d="$HOMED/.wasm-agent/$rel" ;; *) d="$INSTALL/$rel" ;; esac; mkdir -p "$(dirname "$d")"; cp -f "$TREE/$rel" "$d"; done
printf 'the bytes a deploy installed before it died\n' > "$INSTALL/wa"
printf '#!/usr/bin/env bash\necho "sentinel: watching (pid 5678)"\necho "requests: readable"\n' > "$INSTALL/wa-sentinel"
git -C "$TREE" add -A >/dev/null 2>&1; git -C "$TREE" commit -qm 'built artifact fixture'
H="$(sha256sum < "$INSTALL/wa" | awk '{print $1}')"; SH="$(sha256sum < "$INSTALL/wa-sentinel" | awk '{print $1}')"
# The state a deploy that died after installing the node leaves: upgrade.sh's INTERIM record, now the last one.
printf 'commit=unknown\nbranch=unknown\ndirty=unknown\nsha256=%s\nsentinel_sha256=%s\nupgrade_sha256=missing\nsource_commit_hint=unknown\nsource_provenance=unverified-binary\nrecord_role=interim\nvia=deploy.sh\nat=2026-10-02T19:30:00Z\nreason=upgrade requested\n' "$H" "$SH" > "$INSTALL/installed.txt"
# ... and the verdict beside it is the LAST verdict, from an EARLIER deploy, and it is not ok (the live shape).
printf '{"ok":false,"commit":"","branch":"main","node_sha256":"","sentinel_sha256":"","watcher_pid":"","detail":"an earlier deploy refused","reason":"probe","at":"2026-10-02T19:00:00Z"}\n' > "$INSTALL/deploy-result.json"
printf '#!/usr/bin/env bash\necho "{\"ok\":true}"\n' > "$MOCK/curl"
printf '#!/usr/bin/env bash\necho "LISTEN 0 4096 127.0.0.1:8799 0.0.0.0:* users:((\"wa\",pid=1234,fd=3))"\n' > "$MOCK/ss"
printf '#!/usr/bin/env bash\necho 1234\n' > "$MOCK/powershell.exe"; chmod +x "$MOCK"/*; printf '1234\n' > "$INSTALL/serve.pid"
run_verify() {
  (cd "$TREE" && env -u WASM_AGENT_HOME HOME="$HOMED" USERPROFILE="$HOMED" WA_INSTALL_DIR="$INSTALL" \
    WA_DEPLOY_ROOT="$TREE" PATH="$MOCK:$PATH" bash "$REPO/scripts/verify-install.sh" --json 2>&1) | node -e '
let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const j=JSON.parse(s);
console.log("   verdict: "+(j.ok?"PASS":"FAIL")+" (checks="+j.checks+" failed="+j.failed+" skipped="+j.skipped+")");
for(const r of j.results.filter(r=>/final one|verdict matches|installed commit|clean/.test(r.name)))
  console.log("   ["+r.status+"] "+r.name+" :: "+String(r.detail).slice(0,150));
for(const r of j.results.filter(r=>r.status==="fail"&&!/final one|verdict matches|installed commit|clean/.test(r.name)))
  console.log("   [also failing] "+r.name);});'
}
echo "1) BEFORE: the record a dead deploy left (record_role=interim, via=deploy.sh)"; run_verify
# Now the hand-run upgrade, exactly as an operator runs it: the real record_install, WA_UPGRADE_VIA unset.
awk '/^record_install\(\) \{$/{on=1} on{print} on && /^\}$/{exit}' "$REPO/scripts/upgrade.sh" > "$WORK/upgrade-record.sh"
{
  echo 'set -uo pipefail'
  echo "INSTALL_DIR=\"$INSTALL\"; INSTALLED=\"$INSTALL/wa\""
  echo 'file_hash() { [ -f "$1" ] && sha256sum < "$1" 2>/dev/null | awk "{print \$1}" || true; }'
  cat "$WORK/upgrade-record.sh"
  echo 'record_install && echo "record_install: exit 0"'
} > "$WORK/run-upgrade.sh"
bash "$WORK/run-upgrade.sh"
echo "   the record now says: $(grep -E '^(record_role|via|commit|source_provenance|at)=' "$INSTALL/installed.txt" | tr '\n' ' ')"
echo "2) AFTER a hand-run upgrade that changed NO bytes:"; run_verify
