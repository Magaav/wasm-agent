# The speech-recognition venv's dependency pins

These three files are the pinned, hash-checked supply chain of the **Python worker the node's own
speech path runs**: `scripts/whatsapp-stt-local.py --worker`, spawned by the kernel's
`wa-kernel-runtime` text service (`src/service_stt.rs`, default `WA_STT_WORKER`, overridable) and by
the `wa-whatsapp` component's transcription. They do not belong to any Go program.

They used to live under `connectors/whatsapp/`, because the retired Go connector provisioned the same
venv. Phase 4 (11/11) removed that tree; the pins moved here because the worker they pin is what the
Rust/WASI path still runs, and deleting a verified wheel closure would have removed supply-chain
evidence from a path we keep.

| file | what it pins |
| --- | --- |
| `python-stt-dependency.json` | the PyPI metadata of `faster-whisper==1.2.1` (MIT): version, Requires-Python and the wheel's sha256 |
| `python-stt-linux-arm64.requirements.txt` | the 23-package CPython 3.12 / Linux aarch64 wheel closure, every line hash-pinned |
| `python-stt-linux-arm64.lock.json` | the same closure as structured data, with the target, the engine version and how each hash was verified |

Provisioning is a human, setup-time network step; the worker never downloads anything at message time
(`HF_HUB_OFFLINE=1`, `local_files_only=True`). `docs/WHATSAPP-TRANSCRIPTION.md` carries the commands.
