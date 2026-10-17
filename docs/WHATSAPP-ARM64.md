# WhatsApp Linux ARM64 deployment correction

This is a scoped correction to [operator operability](WHATSAPP-OPERABILITY.md), not
live acceptance. Coordinator's original preflight receipt is
`/home/ubuntu/.wasm-agent/session-scratch/66393336386465352d303934312d343835342d613762352d643736346234633738343663/whatsapp-live/preflight.receipt.json`
(operation `op-1792244459526715-491509-13`, coordinator-reported, not worker-executed).
It reports Linux/aarch64, ubuntu uid1001, Python3.12.3, Go1.22.2 linux/arm64,
Node24.21.0, caddy/ffmpeg, lingering enabled, no new connector/state/owners/STT
virtualenv/models. The service bus was unavailable in that native environment.
No production installation, service/account/profile change or pairing is claimed.

## Actual blocker and correction

The original frozen bundle was **Linux AMD64 only**. That was a genuine deployment
contract defect; successful Windows tests/cross-build did NOT establish target CPU
compatibility. Its manifest digest
`52d5688071ef3b6b14c4b6277727059e2defc43ad150327fde291ed87c24392a`, source
`5673efab71d700660fbdb0b7da12b68cac333525` and all original artifacts/receipts remain
unchanged. Never relabel or run that AMD64 executable on the ARM64 server.

The existing builder now takes explicit `WA_WHATSAPP_GOARCH=arm64` or `amd64`
(default retained as amd64), forces Linux/CGO0 and emits schema3 at
`target/whatsapp-linux-<arch>-<tree>/`. The frozen reviewed installer supplies the
shared nonexecuting ELF64 class/endian/machine inspector. The builder verifies
frozen hashes BEFORE loading that helper, checks actual output ELF machine183/62,
exact `go version -m` GOOS/GOARCH and retains module-graph/build-info logs bound in
the manifest. Commit/tree, complete source snapshot, SDK executable hash, readonly
module closure and all member/no-overwrite/source-drift checks remain mandatory.

Schema3 adds `target:{goos,goarch,elf_machine}` plus `platform:linux-arm64` or
`linux-amd64`. Release names include `<tree>-<platform>` to avoid same-source CPU
collisions. The NEW reviewed installer accepts legacy schema2 AMD64 bundles, but
now independently checks actual ELF architecture AND real host OS/CPU in BOTH
default dry-run and apply before any copy/mkdir/state mutation. Windows/macOS,
wrong CPU, unsupported target, manifest/ELF or schema3-target disagreement refuse.
There is NO host-check override. Cross-build generation is supported on Windows;
installer dry-run is not a cross-host success certificate. Mocked-host positive
fixtures are explicitly synthetic, not Linux runtime proof. Older installers do
not acquire these checks retroactively: always invoke the NEW reviewed installer.

## Coordinator: obtain verified native Go only if building on cloud

Installed Go1.22.2 is too old and must NOT be used or globally replaced. The worker
obtained fresh official Go1.27.2 Linux/arm64 metadata/archive, verified SHA/size,
and inspected the archived go executable without executing it. Public inputs:

- `https://go.dev/dl/go1.27.2.linux-arm64.tar.gz`
- archive SHA256 `94f3e30b8e374bc285e7dadc11e0865726b9bc6e85b841ccceaabc0214c6b7c8`
- archive bytes67076180; archived `go/bin/go` ELF machine183
- executable SHA256 `0e893a1a4ab5d00e64bcd9b22060a53377f90c076434ff0aa1bd2a330b657691`

The earlier checksum-verified Windows Go1.27.2 SDK remains the cross-build compiler;
its binding is preserved, not relabelled as a Linux SDK. Coordinator may simply
transfer the new ARM64 service bundle and need not build on the server. If building
there instead, use a fresh private SDK directory, then BEFORE any execution:

```sh
umask 077
mkdir -m 700 "$FRESH_PRIVATE_SDK"
curl --fail --location --proto '=https' --proto-redir '=https' \
  https://go.dev/dl/go1.27.2.linux-arm64.tar.gz -o "$FRESH_PRIVATE_SDK/go.tar.gz"
printf '94f3e30b8e374bc285e7dadc11e0865726b9bc6e85b841ccceaabc0214c6b7c8  %s\n' "$FRESH_PRIVATE_SDK/go.tar.gz" | sha256sum -c -
tar -xzf "$FRESH_PRIVATE_SDK/go.tar.gz" -C "$FRESH_PRIVATE_SDK"
printf '0e893a1a4ab5d00e64bcd9b22060a53377f90c076434ff0aa1bd2a330b657691  %s\n' "$FRESH_PRIVATE_SDK/go/bin/go" | sha256sum -c -
export GO="$FRESH_PRIVATE_SDK/go/bin/go"
export GO_SHA256=0e893a1a4ab5d00e64bcd9b22060a53377f90c076434ff0aa1bd2a330b657691
export PYTHON3=/usr/bin/python3 GOTOOLCHAIN=local WA_WHATSAPP_GOARCH=arm64
export GOPATH="$PWD/target/gopath" GOCACHE="$PWD/target/gocache" GOMODCACHE="$PWD/target/gomodcache"
"$GO" version
bash scripts/build-whatsapp.sh
```

Use a clean exact committed checkout of delivered main; don't overwrite dirty cloud
work. The new bundle's source/manifest/digests are in the settled worker report and
local evidence receipt. No old output directory was reused. Same-source AMD64 and
ARM64 builds are distinct immutable outputs. Installation commands remain the
reviewed `scripts/whatsapp-install.py` dry-run then explicit coordinator apply from
[connector setup](WHATSAPP-CONNECTOR.md); release path is returned, not guessed.
Read back host `uname -sm`, manifest target, ELF header/artifact hash and installed
manifest/source. The worker cross-build is NOT evidence the executable ran on Linux.

## Python3.12/aarch64: reviewed static distribution closure

No engine/default/model was swapped. faster-whisper remains1.2.1, multilingual
small CPU/int8, original-language transcribe, EN shipped default/PT explicit per
account. No hosted fallback. Public PyPI metadata and retained wheel bytes establish
an available CPython3.12/Linux/aarch64 closure, not runtime/recognition readiness:

- `connectors/whatsapp/python-stt-linux-arm64.lock.json`:23 exact packages, official
  PyPI file URLs/SHA256, wheel tags, target dependency edges, Python constraints,
  native/runtime inspection and detailed-audit digest.
- `connectors/whatsapp/python-stt-linux-arm64.requirements.txt`: same23 pins/hashes
  for `--require-hashes --only-binary=:all:` setup. Windows-only colorama was
  excluded after evaluating actual Linux/Python3.12.3 markers, not trusted from
  pip's Windows-host marker resolution.
- Native primary distributions: ctranslate2 **4.8.3** cp312/aarch64,
  onnxruntime **1.31.0** cp312/aarch64, av **19.0.1** cp312/abi3/aarch64.
  NumPy2.5.4, hf-xet1.7.0, tokenizers0.23.3, protobuf7.36.2 and PyYAML6.0.3 also
  have compatible native wheels. Metadata constraints/ABI tags were checked;
  every retained native shared object inspected was ELF machine183.
- Conservative observed version-tag maxima: GLIBC2.28, GLIBCXX3.4.22,
  CXXABI1.3.11. External DT_NEEDED sonames after bundled libraries:
  `ld-linux-aarch64.so.1`, `libc.so.6`, `libdl.so.2`, `libgcc_s.so.1`, `libm.so.6`,
  `libpthread.so.0`, `librt.so.1`, `libstdc++.so.6`, `libz.so.1`.
  Coordinator must verify actual host glibc>=2.28 and those libraries/version tags;
  target Python3.12 alone is not OS-library proof. Worker did NOT run ldd/imports
  or any downloaded wheel code, install dependencies, load weights or claim accuracy.

After host/library review, coordinator provisions a PRIVATE venv using the reviewed
source lock. Public packages are setup-time downloads only; no runtime model fetch:

```sh
python3 -m venv "$HOME/.local/wa-stt"
PY="$HOME/.local/wa-stt/bin/python"
LOCK="$SOURCE/connectors/whatsapp/python-stt-linux-arm64.requirements.txt"
# Native Linux/aarch64 resolution, pinned hashes; refuse source builds/fallbacks.
"$PY" -m pip download --only-binary=:all: --require-hashes -r "$LOCK" -d "$FRESH_PRIVATE_WHEELS"
"$PY" -m pip install --no-index --find-links "$FRESH_PRIVATE_WHEELS" --only-binary=:all: --require-hashes -r "$LOCK"
"$PY" -m pip check
"$PY" -c 'import av, ctranslate2, onnxruntime, faster_whisper; print(av.__version__, ctranslate2.__version__, onnxruntime.__version__)'
```

These commands are coordinator-only actual execution, NOT worker evidence. Provision
small model explicitly as in connector docs, record cache hashes, then run offline
`HF_HUB_OFFLINE=1 WA_WHATSAPP_STT_MODELS="$MODELS" "$PY" "$RELEASE/whatsapp-stt-local.py" --check`.
If native imports/compute capabilities/model loading fail, keep posting OFF and retain
the failure. No silent downgrade, new engine, remote provider or claim of real
compatibility based only on metadata. Static availability found no distribution
blocker; real ARM64 loader, CPU/int8, model and audio acceptance remain mandatory.

## Service bus and live authority

Coordinator owns the real `/run/user/1001/bus` inspection. First prove the socket
exists, correct uid/ownership and intended ubuntu user-manager identity. If verified,
use **per-command** `XDG_RUNTIME_DIR=/run/user/1001` and
`DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus` for `systemctl --user` reads/
subsequent authorized actions. Do not fabricate/create a bus, change global runtime
settings or treat `No medium found` as proof a service is missing/failed. Linger=yes
is not proof the current command can reach the manager. No worker service action.
Then follow all legacy ownership/settlement, OFF initialization/PT/all-chats,
human-only private pairing and live audio/navigation/reconnect/latency proofs in
[operability](WHATSAPP-OPERABILITY.md). Those safety boundaries are unchanged.

## LICENSE discrepancy: reconciled, not normalized

Read-only check of canonical Windows LICENSE observed21 CRLF pairs, SHA256
`3ba67e35278e6891c1b4b448d67f44861856f7e2e8c38e2d6c008a87ed3b2334`.
Git blob and old frozen bundle LICENSE have zero CRLF, identical SHA256
`ac64b7d2ad13c9045a337887dc39c2c24e0c4502f96da3b52ae69e0b901b039e`.
Replacing ONLY CRLF with LF in the canonical read bytes makes them exactly equal
to that blob. `git ls-files --eol LICENSE` reports canonical `i/lf w/crlf` with
`text=auto eol=lf`; the worker checkout is `i/lf w/lf`. No file was edited or
normalized. The old receipt/artifact is not wrong on this evidence: frozen source
hashes bind **Git archive/blob bytes**, not platform worktree conversions.
Verify source via `git show "$SOURCE:LICENSE" | sha256sum` and compare frozen/member
bytes directly; do not use raw canonical worktree hashing as an archive oracle.

## Focused proof and limits

Private positive/negative tests (17 total:7 frozen-builder,6 architecture admission,
4 local STT/installer; zero skips) passed in settled
`op-1792244877686999-13792-541`, alongside119 shipping-closure checks. They
cover both actual Go cross-build architectures,
ELF/build-setting disagreement, unsupported targets, same-target no-overwrite,
source/frozen drift, legacy schema2 compatibility, host OS/CPU dry-run/apply refusal,
relabelled AMD64 manifest refusal and preservation of private synthetic unknown
state. A mocked Linux-host fixture copies ONLY synthetic files into a private temp
release and emits an unregistered unit; this is NOT real Linux/systemd execution.
Public dependency audits execute only installed trusted stdlib/pip metadata helpers,
never downloaded packages. Original AMD64 receipts remain immutable. Self-review,
focused checks and canonical integration only; no release gate or production E2E.
