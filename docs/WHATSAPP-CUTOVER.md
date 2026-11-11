# WhatsApp cutover: Go/whatsmeow to the Rust/WASI component

The operator's 10/11 decision retires the Go connector, and the Rust path already sends
(`docs/SERVICE-COMPONENTS.md`, "The operator send on this path"). What is left is moving the **linked
device** from `wa-whatsapp.service` (whatsmeow, `/home/ubuntu/.local/state/wa-whatsapp`) to the
`wa-whatsapp` component. This document is the runbook; `scripts/whatsapp-adopt.mjs` is the tool.

**This has not been run against a live account.** The 10/11 measurement is: the session is exportable
(PN/LID with device id 66, registration id 2247398041, Noise/identity/signed-pre-key material and the
phone-signed ADV identity are all in `whatsmeow_device`), the exporter and importer produce a
`wacore::store::Device` that the Rust test and the `adopt_check` example accept, and a dry run on a
**copy** of openclaw's store produced a record the checker accepted. No live store was touched, no
service was stopped, and no Rust client was started against the live keys.

## The one decision the operator must make

A linked device is a set of keys the phone authorised. Two ways to move:

* **A. Migrate the existing session** (this runbook). No re-pair, no new device on the account. But
  the move is **one-way in practice**: the moment the Rust client connects it will receive and decrypt
  messages, which advances the Signal ratchet for those sender chains. Rolling back to the Go store
  afterwards leaves Go with a stale ratchet: messages received while Rust was connected can become
  undecryptable in Go (`waiting for this message`), and a clean recovery can require re-pairing Go as a
  new device. It needs the operator present for the first connect; it cannot be rehearsed on the live
  account.
* **B. Pair the Rust component as a new linked device**, with the phone in hand. WhatsApp allows
  several linked devices, the Go session is untouched until the new one is proven, and the retirement
  is a later, separate step. The cost is one more device entry and a pairing code the operator enters.

**Recommendation: B**, unless the account's device list must not grow. A is available and prepared, but
it trades a one-time pairing for a one-way ratchet risk on the personal account.

Either way: **never unlink or log out the current device** as part of the cutover. Stop the service,
keep its files, and let the operator decide what the phone shows after the proof.

## What moves and what does not

| From the Go store | To the component | Notes |
| --- | --- | --- |
| `whatsmeow_device` (PN, LID, registration id, Noise/identity/signed-pre-key, signed pre-key id and signature, ADV secret and account signatures, push name) | the `dev` key of `<components>/wa-whatsapp.state/kv.sqlite` | `scripts/whatsapp-adopt.mjs` builds the 64-byte key pairs (public derived), the ADVSignedDeviceIdentity protobuf and the JIDs |
| `journal.db` (messages, chats, holds, transcripts, outbox) | **not moved** | the component has its own index (`wa-whatsapp-index`); it fills from the live stream and history sync. The Go journal stays as evidence/rollback |
| app-state sync keys/versions, sessions, pre-keys | **not moved** | the Rust client creates fresh pre-keys and syncs app state after the first connect |
| `operator-authority.json` and the two capability tokens | not moved | the native operator route reads the same `~/.config/wa-whatsapp/operator-management-*.json` profiles (Phase 2) |

The device id and keys are what the phone and the server know. The library is not part of the identity,
which is why an import can work at all.

## Prerequisites

1. The node runs a binary built from a tree that contains Phase 2 (the `whatsapp_message` capability,
   `lua/core/whatsapp_operator.lua`) and this document. Deploy through Sentinel, not by hand
   (`skills/self-update/SKILL.md`).
2. The `wa-whatsapp` component, at the pinned bytes. Since 11/11 it is pinned in `components.lock`, so
   it is built once on the machine that has wasi-sdk (`scripts/publish-components.sh`) and every
   node's deploy installs the pinned artifact - no arm64 build on the account's node and no wasi-sdk
   there (`docs/COMPONENTS.md`, "Distributing components"). The bytes are wasm32-wasip2, so the CPU
   of the node is irrelevant. **Installed is not enabled**: the deploy writes the artifact, its pin
   and its manifest and creates no service definition, so nothing starts and nothing contacts
   WhatsApp until step 2 of the chosen option. Check with `wa features` and the `services` tool.
3. The operator is present. Option A needs him for the first connect; option B needs the phone for the
   pairing code.
4. Disk: the Go state is ~135 MB; keep it. The component state is small.

## Option A: migrate the existing session

Every step is on the node that holds the account (openclaw). Run as the node's user, never as root.

```sh
set -euo pipefail
STATE="$HOME/.local/state/wa-whatsapp"
COMP="$HOME/.wasm-agent/components/wa-whatsapp.state"
TMP="$(mktemp -d)"; chmod 700 "$TMP"

# 1. A consistent COPY of the device database. The live file is only read.
sqlite3 "$STATE/device-keys.db" ".backup '$TMP/device-keys-copy.db'"
chmod 600 "$TMP/device-keys-copy.db"

# 2. Export the session into a record the Rust client reads, and a kv file.
node /local/projects/wasm-agent/scripts/whatsapp-adopt.mjs export \
  --from "$TMP/device-keys-copy.db" --out "$TMP/out"

# 3. PROVE the record before anything is stopped: the checker deserializes it with the real
#    wacore::store::Device and confirms every public key is the one its private key derives.
cd /local/projects/wasm-agent/rust/components/wa-whatsapp
cargo run --offline --example adopt_check -- "$TMP/out/dev.json"
#   -> device ok pn=<pn>:<device>@s.whatsapp.net lid=<lid>@lid registration_id=... account=true

# 4. Import into a COPY of the component state, preserving the index and queue keys. The live
#    component store is not the destination (`--merge-into` + `--allow-state` is for a restored copy).
cp "$COMP/kv.sqlite" "$TMP/kv.copy.sqlite"
node /local/projects/wasm-agent/scripts/whatsapp-adopt.mjs export \
  --from "$TMP/device-keys-copy.db" --out "$TMP/out" --merge-into "$TMP/kv.copy.sqlite"
node /local/projects/wasm-agent/scripts/whatsapp-adopt.mjs check --kv "$TMP/kv.copy.sqlite"
```

Only now, with the operator present:

```sh
# 5. Stop the Go service (the unit, never the image). Keep every file.
systemctl --user stop wa-whatsapp.service
systemctl --user is-active wa-whatsapp.service || true      # must say inactive

# 6. Install the copy as the component's state. One atomic move, and the previous file kept.
mv "$COMP/kv.sqlite" "$COMP/kv.sqlite.before-cutover-$(date -u +%Y%m%dT%H%M%SZ)"
install -m 600 "$TMP/kv.copy.sqlite" "$COMP/kv.sqlite"

# 7. Start the component through the node's own service registry (the supported path).
wa services start wa-whatsapp          # or: the `services` tool, action=start
tail -f "$HOME/.wasm-agent/components/wa-whatsapp.service.log"
```

The log must say `device: restored (no pairing needed)` and reach a connected state. If it says
`device: new (pairing)` or reports an identity/handshake refusal, **stop**: do not pair, do not unlink;
go to Rollback.

```sh
# 8. Prove the send, to the operator's own number chat ONLY. The exact JID is the account's PN:
#    <pn>@s.whatsapp.net (never a contact, never a group).
#    Read it back through the index; the message id comes from whatsapp_send_status.
```

Then read the message back in the operator's own chat (`whatsapp_read` on the self JID, or the phone)
and confirm the text. The send and the echo are the two facts that make the cutover done.

## Option B: pair the Rust component as a new device

1. Stop nothing. The last deploy already installed the pinned component; installing it again is not a
   step, and enabling it is what starts it. Create the service definition and configure `pair_phone`
   (the account's own number) in it; `docs/SERVICE-COMPONENTS.md` and `docs/WHATSAPP-CONNECTOR.md`
   carry the pairing flow.
2. `services start wa-whatsapp`, read the one-time pairing code from the log, and enter it on the phone
   (WhatsApp > Linked devices > Link with phone number). Nothing is unlinked.
3. Prove the self-chat send and read-back exactly as in Option A step 8.
4. Keep the Go service stopped-and-disabled only after the proof, and only when the operator says so;
   Phase 4 then removes the connector tree.

## Rollback, and what it really means

* **Before step 7**: restore nothing was changed. Start `wa-whatsapp.service` again; the Go store is
  untouched.
* **After step 7 (component started, before any message arrives/sends)**: stop the component, restore
  `kv.sqlite` from `kv.sqlite.before-cutover-*`, start Go. The Noise handshake may already have
  happened; whether any message was decrypted in that window is visible in the component log (counts).
* **After the first message arrives or the proof send**: stopping Rust and starting Go is **not a
  guaranteed rollback**. The Rust client advanced Signal ratchets for senders it decrypted, so Go can
  show `waiting for this message` for those; the phone may also have marked the device differently.
  The safe recovery is to re-pair Go as a new device (the phone is needed) or to continue on Rust. No
  step in this runbook unlinks, logs out or deletes the session; that decision stays with the operator.
* **Never** run both clients on these keys at the same time: two processes on one linked device race
  the ratchet and the server sees one device with two connections. Stop one before starting the other.

## Evidence to keep

`MANIFEST.json` from each export (source size and sha256, non-secret device facts), the checker line,
the component's log from the first connect, and the message id of the self-chat proof with its read-back.
`dev.json` holds the private keys: keep it 0600 and delete it after the component state is installed.
The Go state directory stays until Phase 4, as the rollback copy of everything that was not migrated.

## Known inert artifact: a send queued on a node without the component (#99)

`host.whatsapp_send` enqueues on the **calling node's** queue (`whatsapp.outbox`), and only a
`wa-whatsapp` component running on that same node consumes it (`worker::take`). A send issued from a
node that runs no component therefore stays `queued` with `attempts: 0` for ever: it is durable, it
is never delivered, and nothing exposes a way to cancel it once the tool has answered.

Measured 2026-11-11 while proving the Rust send from `wasm_the_first`: job id `4`, chat
`5519994939204@s.whatsapp.net`, state `queued`, `attempts: 0`, no worker on that node. It is inert
until a component is enabled there - which must never happen, because a second component on the
account's keys is exactly what the "one client per linked device" rule forbids. Do not hand-edit the
queue to remove it; an operator send belongs on the node that holds the account, through
`whatsapp_operator` (prepare -> approve -> send -> status).
