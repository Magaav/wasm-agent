# WhatsApp cutover: Go/whatsmeow to the Rust/WASI component

**Status 11/11: done, and the Go connector is retired.** WhatsApp runs on the `wa-whatsapp` service
component (the linked device is on openclaw), and the Go/whatsmeow connector that used to hold the same
account is stopped and disabled there. Phase 4 then removed that connector from the tree entirely:
`connectors/whatsapp/` (57 files: Go source, its tests, `go.mod`/`go.sum`, a Windows build artifact), the
three `scripts/` entry points that built and installed it, its `wa-whatsapp.service` unit template and its
documentation. `scripts/test-whatsapp-go-retired.sh` refuses any of that coming back.

This page is now the **record of that migration** and of what it left behind. It is not a runbook to
repeat: there is no Go program in the tree to stop, start or roll back to. The live operating path is
[WHATSAPP-OPERABILITY.md](WHATSAPP-OPERABILITY.md) and
[SERVICE-COMPONENTS.md](SERVICE-COMPONENTS.md).

## What moved and what did not

| From the Go store | To the component | Notes |
| --- | --- | --- |
| `whatsmeow_device` (PN, LID, registration id, Noise/identity/signed-pre-key, signed pre-key id and signature, ADV secret and account signatures, push name) | the `dev` key of `<components>/wa-whatsapp.state/kv.sqlite` | `scripts/whatsapp-adopt.mjs` builds the 64-byte key pairs (public derived), the ADVSignedDeviceIdentity protobuf and the JIDs |
| `journal.db` (messages, chats, holds, transcripts, outbox) | **not moved** | the component has its own index (`wa-whatsapp-index`); it fills from the live stream and history sync. The Go journal stays on the host as evidence |
| app-state sync keys/versions, sessions, pre-keys | **not moved** | the Rust client creates fresh pre-keys and syncs app state after the first connect |
| `operator-authority.json` and the two capability tokens | not moved | the native operator route reads the same `~/.config/wa-whatsapp/operator-management-*.json` profiles (Phase 2) |

The device id and keys are what the phone and the server know. The library is not part of the identity,
which is why an import can work at all.

## Why the move was one-way in practice

A linked device is a set of keys the phone authorised, and two clients may not use them at once: the
server sees one device with two connections and the Signal ratchets race. Once the Rust client connects
and decrypts, the ratchet for those sender chains has advanced, so going back to the old Go store leaves
it with a stale ratchet - messages received while Rust was connected can become undecryptable there
(`waiting for this message`), and a clean recovery can require re-pairing as a new device. That risk is
why the cutover was done deliberately and why the two clients were never run together.

Rollback today is therefore **not** "start the old service": the program is not in the tree any more. It
would mean re-installing the Go connector from Git history - a decision for the operator, with the phone
in hand, and not something any script here does. Nothing in this tree unlinks, logs out or deletes a
linked device.

## The migration tool stayed, and it is inert

`scripts/whatsapp-adopt.mjs` (tested by the fast path, `scripts/test-whatsapp-adopt.mjs`) is the offline
reader of a **copy** of a Go/whatsmeow store: it builds the `wacore::store::Device` record the component
persists, and `rust/components/wa-whatsapp` has an `adopt_check` example that deserializes the record with
the real store type and proves every public key against its private key. It never connects, never starts a
service, and never prints key material; it exists so an old store can still be read, and it is not a Go
build or start path.

## Evidence kept

The `MANIFEST.json` of the export (source size and sha256, non-secret device facts), the checker line, the
component's log from its first connect, and the message id of the self-chat proof with its read-back.
`dev.json` holds private keys: 0600, and deleted once the component state was in place.

## What still sits on the host (operator action, no unlink)

The Go installation's files are still on openclaw: the tree removal was a repository change, and deleting
a running host's files is an operator action with the service already stopped. The commands are removal
only - they unlink no device, touch no phone, and remove no store the phone or the server needs:

```sh
set -eu
# 1. The unit this tree no longer generates (it was found inside the Go release directory).
systemctl --user disable --now wa-whatsapp.service || true
rm -f "$HOME/.config/systemd/user/wa-whatsapp.service"
systemctl --user daemon-reload

# 2. The Go release directory.
rm -rf "$HOME/.local/lib/wa-whatsapp"
# DO NOT delete ~/.local/wa-stt or ~/.local/wa-ocr-rapid: those venvs belong to the RECOGNIZER and the
# OCR worker, which the Rust path still runs (wa-kernel-runtime's service_stt/service_ocr). Check where
# they point first (WA_STT_PYTHON / WA_OCR_PYTHON, or the documented defaults) and only remove a venv
# that is no longer referenced.

# 3. The Go state, ONLY after the operator confirms: keep it as the last copy of the un-migrated
#    journal/sessions, move it aside rather than deleting it, and only when the Rust component is
#    proven connected on the account.
#    mv "$HOME/.local/state/wa-whatsapp" "$HOME/.local/state/wa-whatsapp.retired-$(date -u +%Y%m%dT%H%M%SZ)"
```

Never unlink the device in the phone's linked-devices list as part of this cleanup: the Rust component
is the device now, and the phone's entry for it is what keeps the account working.

## Known inert artifact: a send queued on a node without the component (#99)

`host.whatsapp_send` enqueues on the **calling node's** queue (`whatsapp.outbox`), and only a
`wa-whatsapp` component running on that same node consumes it (`worker::take`). A send issued from a
node that runs no component therefore stays `queued` with `attempts: 0` for ever: it is durable, it is
never delivered, and nothing exposes a way to cancel it once the tool has answered.

Measured 2026-11-11 while proving the Rust send from `wasm_the_first`: job id `4`, chat
`5519994939204@s.whatsapp.net`, state `queued`, `attempts: 0`, no worker on that node. It is inert until a
component is enabled there - which must never happen, because a second component on the account's keys is
exactly what the "one client per linked device" rule forbids. Do not hand-edit the queue to remove it; an
operator send belongs on the node that holds the account, through `whatsapp_operator`
(prepare -> approve -> send -> status).
