#!/usr/bin/env bash
# Does `deploy.sh` refuse, BY NAME, the three preconditions a stripped shell breaks - and does it refuse
# before it writes anything?
#
# THE FAILURE THIS PINS (reproduced 2026-10-02). A deploy run from a bash with no LOCALAPPDATA (a WSL
# shell) selected a phantom install directory - `<HOME>/AppData/Local/wasm-agent`, with HOME=/home/<user> -
# and then failed every write it attempted, one at a time, instead of refusing. Nothing about that run was
# diagnosable from its output. The same class of failure hides a missing toolchain: `cargo` is not needed
# until step 4, so a machine without it reached the build and failed there.
#
# WHAT IS RUN, AND WHAT IS NOT. The REAL `scripts/deploy.sh` is executed, under a stripped environment,
# from a scratch Git tree that is NOT this repository and NOT the live install: a private HOME, private
# `WASM_AGENT_HOME`, a free port nobody is listening on, and `WA_DEPLOY_ROOT` pinned at the scratch tree.
# Every case is required to refuse at the preconditions, so the run cannot reach the build, the port, or
# any installed binary. The control case at the end proves the opposite direction: with the three
# preconditions satisfied the same script gets PAST them - a check that always refuses would be worse than
# no check.
#
# "NOTHING WAS WRITTEN" is asserted, not assumed: the private HOME must gain no file, the scratch tree must
# stay clean with no `rust/target`, and no install record may appear in the scratch install directory. The
# one thing a refusal IS allowed to write is its own evidence record in an install directory that already
# exists (`fail`/`note` append to `<install>/deploy.log` and rewrite `deploy-result.json` - that is the
# project's stated rule, "a refusal is evidence"), so the assertions name exactly which files may exist.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY="$ROOT_DIR/scripts/deploy.sh"
fail() { echo "test-deploy-preconditions: $*" >&2; exit 1; }
[ -f "$DEPLOY" ] || fail "no $DEPLOY to test"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/wa-deploy-preconditions-XXXXXX")" || fail "no scratch directory"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# A scratch tree that is a real Git repository with a commit and a stub Rust workspace, so anything that
# got past the preconditions has somewhere harmless to happen (and a build that fails immediately).
SCRATCH="$WORK/tree"
mkdir -p "$SCRATCH/rust" "$SCRATCH/scripts" || fail "cannot stage the scratch tree"
printf '[workspace]\n' > "$SCRATCH/rust/Cargo.toml"
git -C "$SCRATCH" init -q --initial-branch=main || fail "cannot init the scratch tree"
git -C "$SCRATCH" add -A
git -C "$SCRATCH" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m "fixture: a source tree" \
  || fail "cannot commit the scratch tree"

PORT=18987
CLIENT_PORT=18988
# The stripped environment. A private HOME with no AppData in it is the WSL case; PATH is the caller's
# minus the toolchain, on request.
run_deploy() { # label [--without-cargo] [--wsl] [--uname <dir>] [--install-dir <path>]
  local label="$1"; shift
  local without_cargo=0 wsl=0 uname_stub="" install=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --without-cargo) without_cargo=1; shift ;;
      --wsl) wsl=1; shift ;;
      --uname) uname_stub="$2"; shift 2 ;;
      --install-dir) install="$2"; shift 2 ;;
      *) break ;;
    esac
  done
  local home="$WORK/home-$label"
  mkdir -p "$home" || fail "cannot create the private home for $label"
  local out="$WORK/out-$label.txt"
  local -a env_cmd=(env -u LOCALAPPDATA -u APPDATA -u USERPROFILE -u WA_PORT -u WA_INSTALL_DIR)
  local path="$PATH"
  if [ "$without_cargo" = 1 ]; then
    # Git's own tools stay (the script needs uname, sed, date, git); the toolchain does not.
    path="/usr/bin:/bin"
  fi
  if [ -n "$uname_stub" ]; then path="$uname_stub:$path"; fi
  [ "$wsl" = 1 ] && env_cmd+=(WSL_DISTRO_NAME=Ubuntu WSL_INTEROP=/run/WSL/7_interop)
  [ -n "$install" ] && env_cmd+=(WA_INSTALL_DIR="$install")
  "${env_cmd[@]}" \
    HOME="$home" WASM_AGENT_HOME="$home" PATH="$path" \
    WA_DEPLOY_ROOT="$SCRATCH" WA_PORT="$PORT" WA_CLIENT_PORT="$CLIENT_PORT" \
    TMPDIR="$home/tmp" \
    bash "$DEPLOY" --reason "test-deploy-preconditions $label" > "$out" 2>&1
  local status=$?
  echo "  [$label] exit $status"
  sed 's/^/      /' "$out" | head -12
  RUN_STATUS=$status
  RUN_OUT="$out"
  RUN_HOME="$home"
}

# 1. (c) The shell is not the platform's gate shell, in both of the forms the check reads.
#    1a: the environment markers WSL itself sets (this suite runs in the platform's shell, so the marker is
#    what stands in for the real WSL process).
run_deploy wsl --wsl
[ "$RUN_STATUS" -ne 0 ] || fail "a WSL bash was allowed to deploy"
grep -q 'refused(not_the_gate_shell)' "$RUN_OUT" || fail "the WSL shell was not refused by name"
grep -q 'uname -s=' "$RUN_OUT" || fail "the gate-shell refusal does not name the shell it is judging"
#    1b: the kernel signature, with no WSL environment at all - a stub `uname` that answers like WSL's.
UNAME_STUB="$WORK/uname-stub"
mkdir -p "$UNAME_STUB"
cat > "$UNAME_STUB/uname" <<'STUB'
#!/bin/sh
case "$1" in
  -s) printf 'Linux\n' ;;
  -r) printf '5.15.90.1-microsoft-standard-WSL2\n' ;;
  *) printf 'Linux\n' ;;
esac
STUB
chmod +x "$UNAME_STUB/uname"
run_deploy wsl-uname --uname "$UNAME_STUB"
[ "$RUN_STATUS" -ne 0 ] || fail "a Linux bash with WSL's kernel signature was allowed to deploy"
grep -q 'refused(not_the_gate_shell)' "$RUN_OUT" || fail "the kernel-signature shell was not refused by name"
grep -q 'uname -r=5.15.90.1-microsoft-standard-WSL2' "$RUN_OUT" || fail "the refusal does not quote the kernel signature it judged"
# The same stub, in a kernel that is NOT WSL: the check must not refuse a genuine Linux deploy.
cat > "$UNAME_STUB/uname" <<'STUB'
#!/bin/sh
case "$1" in
  -s) printf 'Linux\n' ;;
  -r) printf '6.8.0-generic\n' ;;
  *) printf 'Linux\n' ;;
esac
STUB
chmod +x "$UNAME_STUB/uname"
run_deploy linux-nonwsl --uname "$UNAME_STUB"
grep -q 'refused(not_the_gate_shell)' "$RUN_OUT" && fail "a genuine Linux (cloud) shell was refused as WSL"

# 2. (a) cargo is unavailable. Refused in step 4, where the build that needs it happens - after the
#    questions that are about this tree - so this case gives the run an install directory that exists and
#    lets it reach the build announcement.
INSTALL_NOCARGO="$WORK/install-nocargo"
mkdir -p "$INSTALL_NOCARGO"
run_deploy nocargo --without-cargo --install-dir "$INSTALL_NOCARGO"
[ "$RUN_STATUS" -ne 0 ] || fail "a deploy without cargo was allowed"
grep -q 'refused(cargo_unavailable)' "$RUN_OUT" || fail "the missing toolchain was not refused by name"
grep -q 'PATH=' "$RUN_OUT" || fail "the toolchain refusal does not show the PATH it searched"
grep -q 'deploy: building' "$RUN_OUT" || fail "the toolchain refusal did not come from step 4 (it must be the build step that refuses)"
# The refusal is evidence (the project's own rule: fail/note write <install>/deploy.log and
# deploy-result.json), so this case's install directory may hold exactly those two - and NOTHING of an
# install: no installed.txt, no binary, no scripts, no build output in the source tree.
grep -q '"ok":false' "$INSTALL_NOCARGO/deploy-result.json" || fail "the refusal was not recorded as a result"
grep -q 'refused(cargo_unavailable)' "$INSTALL_NOCARGO/deploy-result.json" || fail "the recorded result does not name the refusal"
for artifact in installed.txt wa.exe wa-sentinel.exe scripts plugins runtime-worktree.txt; do
  [ ! -e "$INSTALL_NOCARGO/$artifact" ] || fail "the refused deploy installed $artifact"
done

# 3. (b) The install directory is missing and there is no install record - the reproduced phantom path.
run_deploy phantom
[ "$RUN_STATUS" -ne 0 ] || fail "a missing install directory was allowed"
grep -q 'refused(install_dir_missing)' "$RUN_OUT" || fail "the missing install directory was not refused by name"
# The path it refused is the one the stripped environment implies, which is the whole point: it is not the
# live install and it is not a directory anything has ever written into.
grep -q "$WORK/home-phantom/AppData/Local/wasm-agent" "$RUN_OUT" \
  || fail "the refusal does not name the phantom path the environment implied (see $RUN_OUT)"

# Nothing was written, in all the refusing cases: the private HOME gained no install tree, the scratch
# source tree is still clean with no build output, and no install record exists anywhere under the scratch
# root. (The `nocargo` case above is the one whose install directory exists, and it is asserted separately:
# its directory may hold the refusal's own evidence record and nothing else.)
for label in wsl wsl-uname phantom; do
  home="$WORK/home-$label"
  [ ! -e "$home/AppData" ] || fail "$label: the refusal created $home/AppData"
  [ -z "$(find "$home" -type f -not -path '*/tmp/*' 2>/dev/null | head -1)" ] || fail "$label: the refusal wrote a file into the private home"
done
[ -z "$(git -C "$SCRATCH" status --porcelain)" ] || fail "a precondition run wrote into the scratch source tree: $(git -C "$SCRATCH" status --porcelain | head -3)"
[ ! -e "$SCRATCH/rust/target" ] || fail "a precondition run started a build"
[ -z "$(find "$WORK/home-phantom" -name 'installed.txt' 2>/dev/null | head -1)" ] || fail "an install record appeared for a refused deploy"

# 4. The control: the same stripped environment with the toolchain on PATH and an install directory that
#    exists. The preconditions must NOT fire, and the run must get past them (it stops later, at the
#    fixture's stub build - which is not what this test is about). A check that refuses everything is not
#    a check.
INSTALL="$WORK/install-control"
mkdir -p "$INSTALL"
env -u LOCALAPPDATA -u APPDATA -u USERPROFILE \
  HOME="$WORK/home-control" WASM_AGENT_HOME="$WORK/home-control" PATH="$PATH" \
  WA_DEPLOY_ROOT="$SCRATCH" WA_PORT="$PORT" WA_CLIENT_PORT="$CLIENT_PORT" \
  WA_INSTALL_DIR="$INSTALL" \
  bash "$DEPLOY" --reason "test-deploy-preconditions control" > "$WORK/out-control.txt" 2>&1
CONTROL_STATUS=$?
echo "  [control] exit $CONTROL_STATUS"
sed 's/^/      /' "$WORK/out-control.txt" | head -12
for token in 'refused(not_the_gate_shell)' 'refused(cargo_unavailable)' 'refused(install_dir_missing)'; do
  grep -q "$token" "$WORK/out-control.txt" && fail "the control case was refused by $token"
done
grep -q "deploy: .* -> $INSTALL (port $PORT)" "$WORK/out-control.txt" \
  || fail "the control run never got past the preconditions (see $WORK/out-control.txt)"
[ ! -e "$INSTALL/installed.txt" ] || fail "the control run installed something; it must stop at the stub build"

echo "deploy preconditions ok (a WSL shell and a phantom install directory each refuse by name before any write; the toolchain refusal comes from the build step and records its own evidence; nothing was installed, no build started, and the control run gets past all three)"
