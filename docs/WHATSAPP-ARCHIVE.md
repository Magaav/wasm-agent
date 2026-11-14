# The WhatsApp index archives

The live index keeps **180 days**. What leaves that window is not deleted: once a month the oldest
month entirely outside it is cut into one file, compressed, encrypted at rest, kept up to **360 days
from the message date**, pushed to another disk or another node when the account node needs the space,
and restored on demand.

Operator requirement, 13/11. The index it operates on is `docs/SERVICE-COMPONENTS.md` ("The message
index") and `docs/WHATSAPP-COVERAGE.md`; the retention rules it completes are there too.

```text
wa-whatsapp component            index in its own kv (ix/…), 180-day window, prunes by age
  ↑ the same key layout and tokenizer, shared: rust/wa-whatsapp-index (keys, text, month)
wa-capabilities/whatsapp_archive the node's half: cut, list, restore, unload, push, expire
  ↓ rust/wa-whatsapp-archive     the file: one month, one manifest, one sealed body
  ↓ wa-keystore                  the key: a namespace sealer, never a key in hand
```

## The three clocks

| rule | value | where |
| --- | --- | --- |
| the live index keeps | 180 days (`index_retention_days`) | the component prunes by it; a history sync is bounded by it |
| one archive file per month | `whatsapp-archive-YYYY-MM.waa` | the node cuts the **oldest** month entirely outside the window |
| an archive is kept | month end + 360 days | `wa whatsapp archive expire` deletes it, unloading it first |

A month is **UTC** (`YYYY-MM`). The month is a storage decision, not a display one: a fixed zone makes
the boundary the same on every node and in every archive. An answer carries `at_local` for the
operator's own zone.

## What a cut removes, and what comes back

A cut archives the index's own key/value pairs for the month, not a re-encoding of the records:

```text
ix/m/<chat>/<inv(ts)>/<id>          the record (JSON)
ix/id/<chat>/<id>                   inv(ts)
ix/all/<ts>/<chat>/<id>             `history` | empty      (the age order retention walks)
ix/s/<sender>/<inv(ts)>/<id>/<chat>
ix/k/<kind>/<inv(ts)>/<id>/<chat>
ix/w/<token>/<inv(ts)>/<id>/<chat>  every token of the record's searchable text
ix/ocr/<chat>/<id>                  the OCR lane's mark, when it has one
ix/x/<chat>/<id>/<reactor>/<emoji>  reactions folded onto this month's messages
```

The layout and the tokenizer live in `rust/wa-whatsapp-index` (`keys`, `text`) and **both ends use
them**: the component writes and reads them, the node cuts and restores with them. A second copy of the
key format in the node is a cut that misses `ix/w/…` (a restored month nobody can search) or an extra
key pointing at a record that is not there. That is the one invariant this design spends its
duplication budget on.

Chat cards (`ix/ct/<chat>`, `docs/SERVICE-CONFIG` "names") are **not** archived: they are the name
bookkeeping of the account, not a message, and `whatsapp_contacts` must keep answering for a chat whose
messages have been archived.

## The file

```text
"WAWAARC1"                       8 bytes, so an operator can tell it from any other file
u32 manifest_len | manifest JSON in the clear
sealed body                      XChaCha20-Poly1305 (the node keystore) over a zstd frame

body after open + decompress:
  u32 count | (u16 klen | key | u32 vlen | value)*
  footer: "WAA1" | u64 entries | u64 bytes | sha256(entries)
```

The manifest is readable on purpose - it is what "self-describing" means, and what lets a push target
verify a file it cannot open:

```json
{"format":1,"month":"2026-03","chats":12,"messages":4821,"entries":33747,
 "component_version":"0.1.0","schema":"v3","compression":"zstd","seal":"xchacha20poly1305",
 "key_namespace":"wa-whatsapp-archive","payload_bytes":914233,"sha256":"…",
 "created_ms":1794600000000,"month_start_ms":1772323200000,"month_end_ms":1775001600000}
```

- `sha256` is over the **sealed body**, so `wa whatsapp archive push` and a receiving node can both
  prove the bytes arrived unchanged without any key. `verify_file` is that check.
- The body's own footer checksum covers the entries, so a key that opens but decompresses to the wrong
  bytes is refused too (`archive_payload_corrupt`).
- The seal's context is `whatsapp-archive|1|<month>`: a body sealed for April cannot be opened as
  March, so a file swapped between months fails instead of restoring the wrong one.
- The key is the node's keystore, derived for the namespace `wa-whatsapp-archive`
  (`docs/VAULT.md`). It is never printed, never stored beside the file, and never handed to the
  component: `seal`/`open` take a context and bytes.

## The order a cut obeys

1. collect the month's entries out of the index (read-only);
2. seal and compress them, write the file to `<month>.waa.partial`, `fsync`, rename;
3. **read the file back and verify** its manifest digest and entry count;
4. only then delete the index's keys, pointers first and the age key last.

A crash before 4 leaves the month in both places: the next cut replaces the file and deletes the keys.
A crash after 4 leaves nothing to redo. A cut that cannot verify its own file deletes nothing
(`archive_write_unverified`).

A cut also **refuses a month the window has not released** (`archive_month_not_due`), whether the node
chose the month or an operator named it: the archive never moves a message out of the live index while
the component is still keeping it.

## A restored month is read-only and marked

`wa whatsapp archive restore YYYY-MM` writes the archived pairs back:

- the record is written with `"restored": true`, and an answer built from it says `restored: true` and
  `restored_month: "YYYY-MM"` (`whatsapp_read`, `whatsapp_search` hits, `whatsapp_message`);
- the month gets one mark, `ix/arc/<YYYY-MM>`, holding its counts, digest and when it was loaded;
- retention **walks past a restored range** instead of deleting it (`index::prune`, one scan of `ix/arc/`
  per pass, then a cursor jump: the cost is the number of restored months, not the number of restored
  messages);
- `unload` deletes exactly what a restore wrote - the rows are found the way the cut found them, so an
  unload still works after the file has been pushed away - and leaves the file alone.

Bounds worth stating: an *edit* of an archived message that lands after the cut is written back into
the live index without the mark, and it is walked past with the range (so it lives until the month is
unloaded or expires). The archive is the authority for that month; a post-cut edit is not folded into
it.

## Pushing it off the node

`wa whatsapp archive push YYYY-MM [--to <node|dir>] [--keep-local]`:

- a **path** (`/mnt/cold/wa`, `~/wa-archive`) is another disk: the file is written there, re-read and
  verified, and the local copy is removed;
- a **single word** (`nextcloud`) is a node: the file travels in 96 KiB chunks over the existing mesh
  (`wa-mesh`, `host.mesh_call` → the peer's `whatsapp_archive` capability, action `receive`), the peer
  assembles it on its own disk, verifies the manifest itself and answers the digest it computed; the
  local copy is removed only when that digest is the manifest's (`archive_push_unverified` otherwise).

The default target is `nextcloud`, overridable with `--to` or `WA_WHATSAPP_ARCHIVE_PUSH` (a node name or
a directory). A push that cannot be verified deletes nothing: an archive that is in neither place is
the one outcome this refuses to produce.

## Commands and settings

```text
wa whatsapp archive list                      every archive, its month, counts, digest and expiry, and
                                              which months are loaded here; what is due next
wa whatsapp archive cut [YYYY-MM]             cut the oldest released month (or exactly that one)
wa whatsapp archive restore YYYY-MM           load it back, read-only and marked
wa whatsapp archive unload YYYY-MM            take it out again; the file stays
wa whatsapp archive push YYYY-MM [--to X]     to another disk or node, verified, local copy removed
wa whatsapp archive expire                    delete what is past its 360 days
                                              (--json prints the host answer)
```

| setting | default | meaning |
| --- | --- | --- |
| `index_retention_days` | `180` | the component's window; the archive must use the same number |
| `WA_WHATSAPP_KEEP_DAYS` | - | the window the node's archive uses, when it differs from the default; every answer reports the value it used |
| `WA_WHATSAPP_ARCHIVE_PUSH` | `nextcloud` | where `push` goes when `--to` is not given: a node name or a directory |

The archive directory is `<components>/wa-whatsapp.archive/` beside the state it came from.

## What is not covered

- **The monthly schedule is a command, not a timer.** `wa whatsapp archive cut` is what a monthly job
  (or an operator) runs; nothing in the node's own tick cuts a month. `list`/`status` always says which
  month is due, so a caller that asks first cannot cut by accident.
- **The mesh transport itself is not measured here.** The chunk protocol, the assembly and the digest
  comparison are (`rust/wa-whatsapp-archive`, `wa-capabilities/src/whatsapp_archive`), and the disk push
  is end to end; the transport between two nodes is `wa-mesh`'s own subject, and on this node there is
  no peer to push to.
- **A component-side cut is not on the table**, and that is the reason this is a node capability: a
  component's world has no filesystem (`rust/components/wa-whatsapp/wit/wa.wit`), so "one file per
  month, on another disk, on another node" is a node fact. The node reads the namespace it already owns
  and administers (`wa state export|import`), and the component keeps the two halves of the contract
  that are its own: the mark, the retention skip and the answer that says where a message came from.
