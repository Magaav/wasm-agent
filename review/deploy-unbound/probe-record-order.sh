#!/usr/bin/env bash
# Attack 4: whose record stands? The observed order, the overlap (an interim record after a
# final one), and the deploy killed between its early final write and its last act.
# Run from the repository root:  bash review/deploy-unbound/probe-record-order.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
TREE="$W/tree"; INST="$W/install"; mkdir -p "$TREE/rust/target/release" "$INST/scripts" "$W/home"
git -C "$TREE" init -q --initial-branch=main
git -C "$TREE" config user.name f; git -C "$TREE" config user.email f@x.invalid
printf '#!/usr/bin/env bash\necho fixture node\n' > "$TREE/rust/target/release/wa"
cp -f "$TREE/rust/target/release/wa" "$INST/wa"
printf '#!/usr/bin/env bash\necho sentinel\n' > "$INST/wa-sentinel"
git -C "$TREE" add -A >/dev/null 2>&1; git -C "$TREE" commit -qm fixture
COMMIT="$(git -C "$TREE" rev-parse --short HEAD)"; FULL="$(git -C "$TREE" rev-parse HEAD)"
sha() { sha256sum < "$1" | awk '{print $1}'; }
awk '/^record_installed\(\) \{$/{on=1} on{print} on && /^\}$/{exit}' scripts/deploy.sh > "$W/rec-deploy.sh"
awk '/^record_install\(\) \{$/{on=1} on{print} on && /^\}$/{exit}' scripts/upgrade.sh > "$W/rec-upgrade.sh"
deploy_record() {
  cat > "$W/run-d.sh" <<EOF
set -uo pipefail
INSTALL_DIR="$INST"; COMMIT="$COMMIT"; BRANCH="main"; DIRTY=0
HASH="$(sha "$INST/wa")"; SENTINEL_HASH="$(sha "$INST/wa-sentinel")"; UPGRADE_HASH="$(sha "$ROOT/scripts/upgrade.sh")"
REASON="land the reviewed deliveries"; WA_SERVICE_DIR="$INST"
fail() { echo "REFUSED: \$*" >&2; exit 3; }
. "$W/rec-deploy.sh"
record_installed
EOF
  bash "$W/run-d.sh"; }
upgrade_record() {
  cat > "$W/run-u.sh" <<EOF
set -uo pipefail
INSTALL_DIR="$INST"; INSTALLED="$INST/wa"; NEW="$INST/wa"; PREVIOUS_COMMIT="$COMMIT"; SOURCE_COMMIT="$FULL"
WA_UPGRADE_VIA="$1"; WA_UPGRADE_REASON="an upgrade request"
file_hash() { [ -f "\$1" ] && sha256sum < "\$1" 2>/dev/null | awk '{print \$1}' || true; }
. "$W/rec-upgrade.sh"
record_install
EOF
  bash "$W/run-u.sh"; }
fields() { grep -E '^(commit|source_provenance|record_role|via|sentinel_sha256)=' "$INST/installed.txt" | tr '\n' ' '; echo; }
verify() { WA_INSTALL_DIR="$INST" WA_DEPLOY_ROOT="$TREE" WASM_AGENT_HOME="$W/home" WA_PORT=18995 bash scripts/verify-install.sh 2>&1; }

echo "########## CASE A: the observed order - upgrade.sh interim, then the deploy's final ##########"
upgrade_record deploy.sh >/dev/null; echo "  after upgrade.sh: $(fields)"
deploy_record >/dev/null;          echo "  after the deploy: $(fields)"
verify | grep -E 'installed.txt|install record' | sed 's/^/  /'

echo "########## CASE B: the OVERLAP - a final record, then a second deploy's upgrade.sh ##########"
deploy_record >/dev/null;           echo "  deploy A wrote:  $(fields)"
upgrade_record deploy.sh >/dev/null; echo "  deploy B overwrote it: $(fields)"
verify | grep -E 'install record' | sed 's/^/  /'

echo "########## CASE C: killed between the early final write and the last act ##########"
rm -f "$INST/installed.txt" "$INST/deploy-result.json" "$INST/deploy.log"
deploy_record >/dev/null
echo "  record left behind: $(fields)"
echo "  deploy-result.json: $([ -f "$INST/deploy-result.json" ] && echo present || echo ABSENT)"
verify | grep -E 'installed.txt|install record|installed commit|FAIL' | sed 's/^/  /'
echo "   (a non-zero exit below is the fixture's own /health, serve.pid and sentinel FAILs, never the record checks)"
exit 0
