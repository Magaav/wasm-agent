# Record / replay — bounded, per-component, on the node only

Status 12/11: **library landed, storage bounded by the host, recording not wired.** `rust/wa-bounded`
is the pure library: quota directory, content-addressed blob store, bounded record ring, zstd replay
files and a replay reader with blob resolution. The host now owns the *directory*: `store.rs` opens
`<home>/.wasm-agent/replays/` as a `BoundedDir` with the 500 MiB quota, expires files past 7 days on
the minute sweep, reports its usage through `host.telemetry`, and puts the 80 % crossing on the node's
log. Nothing writes a replay yet — "Wiring status and the precise TODO" below says exactly what is
left and why it is not in this change.

A replay answers one question: **what did the host tell this component, in order?** With that, a
failing WhatsApp turn, a transcript that never arrived, a component that trapped after 40 calls — all
of them can be re-run against the same answers instead of being argued about from logs.

## What is recorded

One `RecordRing` per component, in memory, bounded on every push by **bytes and age**:

| field | what |
| --- | --- |
| `seq` | monotonic within the ring; the match key when replaying |
| `ts` | the host's timestamp for the call |
| `interface`, `function` | e.g. `wa:kernel/kv`, `get` |
| `args` | bytes, or their sha256 + length when arguments are recorded as digests only |
| `result` | bytes, a digest, or a blob reference |
| `duration` | how long the host call took (µs in the file) |

Payload policy: up to `blob_threshold` (4 KiB default) inline; above it, spilled into the blob store
and referenced by sha256, so a 20 MB ring cannot be filled by one attachment and identical payloads
are stored once. With no blob store attached, an oversized payload is reduced to its digest — never
silently dropped, never allowed to grow memory. Results are always recorded; whether arguments are
recorded in full is a per-component policy (`RingConfig::keep_args`), because a component's arguments
can carry message text where its results do not.

## Where the host must intercept

The seam is the **host side of every imported function**, not the guest: the guest runs unchanged, the
kernel answers. Every `wa:kernel` import is answered by exactly one trait method, so a recorder wraps
those, and a replayer answers them from the file instead of doing the work.

| file | seam | interfaces to wrap |
| --- | --- | --- |
| `rust/wa-host/src/service_components.rs` | `impl wa::kernel::*::Host` / `HostX` for `State` (bindgen at the top of the file selects `world: "service-component"`) | `websocket` (`HostSocket::connect/send/recv/close`), `http` (`HostPending::start/poll`), `speech` (`HostJob::start/poll`), `kv` (`get/set/delete/delete_prefix/scan`), `log::write` (**see the exclusion below**), `credentials::get`, `lifecycle::stopping/report` (recorded, not replayed) |
| `rust/wa-host/src/core_component.rs` | `impl wa::kernel::host::Host::call` — the single untyped bridge every `host.*` from the Lua core crosses | one function; the cheapest interception point in the tree |
| `rust/wa-host/src/components.rs` | `run()` builds the linker with `wasmtime_wasi::p2::add_to_linker_sync`; a request component (`wasi:cli` world) imports no `wa:kernel` | `wasi:clocks/*` and `wasi:random/*` from the `WasiCtx` (see determinism), and the `env`/`file_env`/`config` values the grant injects |

Two rules for the recording wrapper, both learned from what a replay is for:

* **Write after the answer, in `seq` order, never instead of it.** Recording must not change the
  answer, the error, or the timing the guest sees. A host call that fails is recorded with its error
  as the result — the failure is the thing being replayed.
* **Do not record `log::write` message text.** Log lines are already in the component's log; a replay
  that repeats them duplicates the data AND puts message text in a second place. Record the call
  (interface, function, level, byte length) with the text replaced by its sha256 — enough to replay
  ordering, nothing to leak.

Replaying feeds the recorded result back through the same trait methods: `seq` matches, the recorded
`Payload` is resolved (inline bytes, or the blob from the store under its sha256) and returned. A blob
that is gone stops the replay with an error rather than substituting anything.

## Triggers

A save is cheap (the ring is already in memory) and always labelled with why:

| trigger | when |
| --- | --- |
| `error` | a host call returned `wa:kernel/types.error`, or a component's `tools/call` returned a failure |
| `timeout` | a run hit its deadline (`component_deadline`) or a call returned `again` past its deadline |
| `crash` | the supervisor saw a trap/restart of a service component |
| `transcription` | speech-to-text failed for the same message repeatedly (the five-minute case): the ring holds the failing `speech.start/poll` answers |
| `manual` | `wa replay save [--component NAME] [--trigger …] [--label …] [--pin]` |

A save inside a component run must not fail the run: if the heap or the quota refuses, log it
(`replay_save_refused:<why>`) and continue. Only the operator-facing `wa replay save` reports the
error as its result.

## Caps (defaults, in `wa_bounded::caps`)

| what | default | enforced by |
| --- | --- | --- |
| replay directory per node | 500 MB | `BoundedDir` quota, oldest unpinned evicted first |
| replay file age | 7 days | `BoundedDir::expire` |
| ring | last 5 min **or** 20 MB | `RecordRing` on every push |
| inline payload threshold | 4 KiB | `RingConfig::blob_threshold` |
| blob TTL | 24 h (unreferenced and unpinned) | `BlobStore::gc` |
| threshold report | 80 % | `Usage::over_threshold`, `on_threshold` callback |

Storage: `~/.wasm-agent/replays/<component>/` for the `.wrz` files and
`~/.wasm-agent/replays/<component>/blobs/` for the blob store (nested, so the quota does not count
files it does not own — see `BoundedDir` docs). `gc` and `expire` run on a timer (hourly is plenty)
and before every save.

A saved file holds its own reference on every blob it names (`ReplayHeader::release_blobs` when the
file is deleted or its pin is lifted), so deleting a replay can never delete the payload another
replay still needs — and the reverse: a `gc` cannot take a blob out from under a saved file.

Pinned replays (`SaveOptions::pin`) are never evicted and never expired, still count toward usage and
are reported as `pinned_bytes` — so an incident keeps its evidence without becoming invisible. Pinning
is an operator decision or a crash trigger's policy; it is not free.

## Determinism limits

A replay of *host calls* is only deterministic if the host was the only source of non-determinism:

* **clocks** — `wasi:clocks` (monotonic + wall) must be recorded with their answers, or replaced with a
  virtual clock derived from the replay. "Recorded" is safer and is what the ring is for; the ring
  stores them exactly like a `wa:kernel` call so a replay feeds back the same numbers.
* **random** — `wasi:random` (`get-random-bytes`, `get-random-u64`, and insecure variants) must be
  recorded, not re-seeded: a guest that branches on a random id must branch the same way.
* **scheduling and concurrency** — two components interleaving is not reproduced; a replay is
  single-threaded, call by call. A race whose outcome depends on interleaving cannot be reproduced,
  and a replay should not be presented as having reproduced it.
* **time-outs inside the guest** — the guest may read the clock, sleep, and compute; a replayed
  component that decides differently because it took longer is out of scope.
* **network and provider responses** — the host answer is replayed, so a still-changing upstream is
  invisible. That is the point, and also the limit: a replay proves "with these answers, it fails".
* **`again` / polling loops** — `poll` returning `again` N times is part of the recorded sequence.
  The replayer must preserve `again` answers verbatim, not collapse them to the final result, or a
  guest that counts polls behaves differently.
* **never replayed** — `lifecycle` (the supervisor decides), `log` (writes go to the log), `credential`
  values (recorded as a digest only; a replay gets `refused` unless the operator grants it), and any
  call the grant refused (recorded as `refused`, replayed as `refused`).

A file cannot be replayed partially: the header's record count, body length and body sha256 are
checked before the first record is decoded, and `Replay::verify` additionally refuses a record that
points at a blob the file did not declare. `Replay::verify_blobs` checks each blob against its key, so
a tampered or truncated file is refused whole rather than replayed with wrong answers.

## Privacy

Replays contain message data. Therefore:

* **Stored only on the node.** `~/.wasm-agent/replays/` is local state: never uploaded to the relay,
  never included in a support bundle, never attached to an issue.
* **Never in logs.** The log says `replay_saved:<name>:<trigger>:<records>:<bytes>` — never a record,
  an argument, a result, or a message body. `log::write` bodies are recorded as digests only (above).
* **Never in the prompt.** No tool, Lua capability or MCP path exposes a replay's contents to a model.
  Reading one is an operator action on the node (`wa replay show <file>`), and only a *summarised*
  account (interface, function, count, duration) should ever be handed to a model.
* **TTL and quota by default.** 7 days, 500 MB per node, unpinned replays evicted oldest-first: raw
  data with a deadline, not an archive that grows.
* **Pins are explicit** and visible in `usage`, so "there is evidence nobody deleted" cannot be true
  while the disk says otherwise.

## Wiring status and the precise TODO

What exists: the replay **directory** is a bounded store (`store.rs`) — 500 MiB quota from
`wa_bounded::caps`, files past 7 days expired by the minute sweep, usage and percentage in
`host.telemetry` (format `store` or the default JSON), the 80 % crossing on the node's log, and
`pinned_bytes` reported so an incident's evidence is counted rather than invisible. A save that
cannot fit will therefore fail visibly (`replay_save_refused:<why>`) instead of filling the disk.

What does not exist: **no `RecordRing` is created and no replay is saved**, because the interception
seam is being changed by the WASI 0.3 / wasmtime 50 work (the same freezing reason the `wit/kernel`
0.2 job has). Writing the wrapper now would mean writing it twice, against a `Store` shape that is
about to change.

The exact call sites, so the next change does not have to re-derive them:

| file | seam | call |
| --- | --- | --- |
| `rust/wa-host/src/service_components.rs` | every `impl wa::kernel::*::Host` for `State` — and the `HostCallGuard` added by the policy/telemetry wiring is already the one place each answered call passes through | `ring.push(NewRecord { interface: "wa:kernel/<iface>", function, args, result, duration })` **after** the answer, in `seq` order, never instead of it |
| `rust/wa-host/src/core_component.rs` | `impl wa::kernel::host::Host::call` — the single untyped bridge every `host.*` from the Lua core crosses | the same push; one function, the cheapest interception point in the tree |
| `rust/wa-host/src/components.rs` | `run()` — a request component (`wasi:cli` world) imports no `wa:kernel` | `wasi:clocks/*` and `wasi:random/*` answers, which is where its non-determinism is |
| `rust/wa-host/src/services.rs` | the supervisor's restart branch (already carries `restart_reason`) | `replay::save(ring, &dir, &SaveOptions { trigger: Trigger::Crash, .. }, now)` on `trap`/`error` |

Rules that must survive that change (from the sections above, restated where they are enforced):
record after the answer and never instead of it; a failed host call is recorded **with** its error;
`log::write` bodies are recorded as digests only; `lifecycle` and credential values are recorded as
refusals/digests and never replayed; a save inside a component run may not fail the run — it logs
`replay_save_refused:<why>` and continues; only the operator-facing `wa replay save` reports the
error as its result.

Two things it needs before it can land: the async `Store`/`future<T>` shape from wasmtime 50 (so the
wrapper is written once), and `wit/kernel` 0.2 frozen (so the interface/function names the records
carry are the stable ones). Until both are true, the honest state is: **bounded, measured, not
recording**.

Privacy is unchanged and now has two more surfaces to respect: neither `host.telemetry` nor
`host.policy_status` may ever return a replay's contents — `host.telemetry` returns the replay
*usage* (bytes, files, pinned bytes) and nothing else, and a replay's records are readable only by an
operator on the node (`wa replay show <file>`).

## Open questions / next steps

1. **Wiring** is the open work: `service_components.rs` (all `wa::kernel` `Host` impls) and
   `core_component.rs::host::Host::call`, plus a `wasmtime_wasi` `WasiCtx` that records clocks and
   random. It needs the WASI 0.3 / wasmtime 50 upgrade to land first, because that changes how host
   calls (and `future<T>` completions) reach a `Store` — the wrapper should be written once, against
   the async shape.
2. **A virtual clock** for replay (`Recorded` vs `Virtual`) — recorded answers reproduce the run, a
   virtual clock makes it repeatable across machines. Probably both: recorded by default, virtual
   when replaying with `--fast`.
3. **Multi-component sequencing.** The ring is per component; a channel turn that spans a service
   component and the Lua core has two rings and two replays. Joining them (a shared `seq` space, or a
   parent replay that references children) is undesigned.
4. **Replay-driven debugging UI** — feeding a saved replay through `wa-window` with a step/continue
   control is the natural next step and needs nothing new from this library except `next_record`.
5. **Compression default (3) is untuned.** Records full of digests do not compress; records full of
   payloads do. A per-file choice based on a sample would be a knob with a measurement behind it.
