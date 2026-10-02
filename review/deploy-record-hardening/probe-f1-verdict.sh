#!/usr/bin/env bash
# F1: does verify-install.sh fail BY NAME on a `final` record whose deploy verdict is missing/stale/not-ok?
set -uo pipefail
REPO="$1"
echo "=== verifier body: $REPO/scripts/verify-install.sh (sha256 $(sha256sum < "$REPO/scripts/verify-install.sh" | cut -c1-16)) ==="
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-f1-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
TREE="$WORK/source"; INSTALL="$WORK/install"; HOMED="$WORK/home"; MOCK="$WORK/mock-bin"
mkdir -p "$TREE" "$INSTALL" "$HOMED" "$MOCK"
SHIPPED="scripts/deploy.sh scripts/upgrade.sh skills/self-update/SKILL.md skills/git-orchestrator/SKILL.md skills/git-orchestrator/scripts/audit.mjs"
for rel in $SHIPPED; do mkdir -p "$(dirname "$TREE/$rel")"; cp -f "$REPO/$rel" "$TREE/$rel"; done
git -C "$TREE" init -q --initial-branch=main
git -C "$TREE" config user.name fixture; git -C "$TREE" config user.email fixture@example.invalid
git -C "$TREE" config core.hooksPath "$WORK/no-hooks"
for rel in $SHIPPED; do
  case "$rel" in skills/*) d="$HOMED/.wasm-agent/$rel" ;; *) d="$INSTALL/$rel" ;; esac
  mkdir -p "$(dirname "$d")"; cp -f "$TREE/$rel" "$d"
done
mkdir -p "$TREE/rust/target/release"; printf 'fixture binary\n' > "$TREE/rust/target/release/wa"
cp -f "$TREE/rust/target/release/wa" "$INSTALL/wa"
mkdir -p "$TREE/rust/wa-sentinel/target/release"
printf '#!/usr/bin/env bash\necho "sentinel: watching (pid 5678)"\necho "requests: readable"\n' > "$TREE/rust/wa-sentinel/target/release/wa-sentinel"
cp -f "$TREE/rust/wa-sentinel/target/release/wa-sentinel" "$INSTALL/wa-sentinel"
git -C "$TREE" add -A >/dev/null 2>&1; git -C "$TREE" commit -qm 'built artifact fixture'
C="$(git -C "$TREE" rev-parse --short HEAD)"
hash() { sha256sum < "$1" | awk '{print $1}'; }
write_record() {
  printf 'commit=%s\nbranch=main\ndirty=0\nsha256=%s\nsentinel_sha256=%s\ninstall_dir=%s\nsource_provenance=clean-built-by-deploy\nrecord_role=final\nvia=deploy.sh\nat=%s\nreason=fixture deploy\n' \
    "$C" "$(hash "$INSTALL/wa")" "$(hash "$INSTALL/wa-sentinel")" "$INSTALL" "$1" > "$INSTALL/installed.txt"
}
verdict() { printf '{"ok":%s,"commit":"%s","detail":"%s","at":"%s"}\n' "$2" "$C" "$3" "$1" > "$INSTALL/deploy-result.json"; }
printf '#!/usr/bin/env bash\necho "{\"ok\":true}"\n' > "$MOCK/curl"
printf '#!/usr/bin/env bash\necho "LISTEN 0 4096 127.0.0.1:8799 0.0.0.0:* users:((\"wa\",pid=1234,fd=3))"\n' > "$MOCK/ss"
printf '#!/usr/bin/env bash\necho 1234\n' > "$MOCK/powershell.exe"
chmod +x "$MOCK"/*; printf '1234\n' > "$INSTALL/serve.pid"
run() { (cd "$TREE" && env -u WASM_AGENT_HOME HOME="$HOMED" USERPROFILE="$HOMED" WA_INSTALL_DIR="$INSTALL" \
        WA_DEPLOY_ROOT="$TREE" PATH="$MOCK:$PATH" bash "$REPO/scripts/verify-install.sh" --json 2>&1); }
case_of() {
  local label="$1" out status
  out="$(run)"; status=$?
  printf '  %-22s exit=%s  %s\n' "$label" "$status" "$(printf '%s' "$out" | node /tmp/wa-review-eaf6/report.cjs)"
}
write_record '2026-10-02T19:30:02Z'; rm -f "$INSTALL/deploy-result.json"; case_of "A missing verdict"
write_record '2026-10-02T19:30:02Z'; verdict '2026-10-02T19:29:00Z' true 'an earlier deploy'; case_of "B stale verdict"
write_record '2026-10-02T19:30:02Z'; verdict '2026-10-02T19:31:00Z' false 'upgrade.sh failed'; case_of "C non-ok verdict"
write_record '2026-10-02T19:30:02Z'; verdict '2026-10-02T19:31:00Z' true 'installed the fixture node'; case_of "D control (matching)"
echo "--- human-readable verdict of the missing-verdict run ---"
rm -f "$INSTALL/deploy-result.json"; run | tail -3
