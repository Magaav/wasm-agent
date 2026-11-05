# HANDOFF — stream B2 (wa-whatsapp posting parity + streaming)

Branch `change/wa-b2` (based on origin/main 0ac3c606). Not pushed, not deployed. openclaw runs
the B1 state unchanged (wa-whatsapp sha a0354660…, shadow, posting off; Go connector is the poster).

## Done (code written, WIP)
- **Host `rust/wa-host/src/service_stt.rs`**: warm worker. `prewarm()` starts the worker when a
  component with the `stt` grant starts. Idle stop only if `WA_STT_IDLE_SECONDS` > 0 (default never).
  Jobs carry `segments` (segment text from progress lines).
- **Host `service_components.rs`**: `job.segments(skip)`, plus the prewarm call.
- **WIT `wit/kernel/kernel.wit`**: `speech.job.segments: func(skip: u32) -> list<string>`
  (validated with wasm-tools; note `from` is a WIT keyword).
- **Worker `scripts/whatsapp-stt-local.py`**: opt-in `"segments": true` per request adds `text` to
  progress lines. Go never sends it, so Go is unchanged.
- **Component `rust/components/wa-whatsapp/src`**:
  - `queue.rs`: the seam for the future shared `wa:queue` component.
    - Interface: enqueue / take / done / fail / expire_stale.
    - `Policy` holds fresh window, backoff and attempts; given-up items return as `Notice`s.
  - `alerts.rs`: own-chat log with Go-identical wording; ≤1 message/min, 12 listed, 6 h drop.
  - `posting.rs`:
    - Allowlist gate (`post_allow`: `own` | exact JID | `*`), `held_chats`.
    - Go-identical chunks, `header_tag`, partial body, EditPacer.
  - `lib.rs` pipeline:
    - Admit: dedup via kv `tx/<chat>/<id>`; unsupported (view-once, >20 MB, bad timestamps);
      fence check.
    - Then queue → download → recognize with segment polling → post-then-edit (if streaming)
      → final post/edit quoting the audio (`build_quote_context_with_info`) → kv record → alerts.
    - Revoke/edit protocol messages fence the target ID (kv `fence/<id>`).
    - `status@broadcast` and newsletters are ignored.
- Docs: `docs/SERVICE-COMPONENTS.md` ("Speech and posting parity": settings table, rules, gaps) and
  `docs/WHATSAPP-TRANSCRIPTION.md` ("The wasm component path").

## Build state (wasm_the_first, worktree C:/Users/Victor/wa-build/b2)
- **Guest `wasm32-wasip2`:** BUILDS. Two harmless unused warnings: `alerts.rs:33` `len`, `queue.rs:64` `len`.
- **Native `cargo test --lib`:** FAILS TO COMPILE. `store.rs` trait impls don't match the native
  wacore traits (Send bounds differ off-wasm). The unit tests in queue.rs / alerts.rs / posting.rs
  have NOT run yet.
  - Fix option: move the three pure modules into a tiny test crate (`#[path]` includes, serde_json
    only).
  - Or gate `store` / bindings behind `cfg(target_arch = "wasm32")`.
- **Host `wa-host`:** the build was started then killed at handoff. NOT verified to compile with
  the new `JobState` / `Job` / `Request` shapes.

## Parity checklist
| item | status |
| --- | --- |
| warm worker / no idle stop | code done, host build unverified |
| reply quoting the audio | code done, untested live |
| 5-min freshness (pickup), never-late, post_expired | done (queue + lib) |
| no reposts (kv dedup, restart) | done |
| own-chat alerts batched | done, sending gated by `alerts` (default off: Go also sends them) |
| per-message fences (revoke/edit) | done; unverified that whatsapp-rust delivers protocol messages to on_message |
| chat holds | only static `held_chats` config; Go's unproven-mutation holds NOT ported (B3 prerequisite) |
| express lane | not ported (one recognizer) |
| durable queue across restart | not done (in memory; shared wa:queue component will bring it) |
| group titles in alerts | not done (DM push name only) |
| segment streaming | done (host + WIT + worker + component) |
| post-then-edit (`stream_edits`, default off) | done, untested live |
| unit tests | written, not run (see above) |

## Remaining steps
1. Make the unit tests run natively (see the fix options above). Run them, fix any failures.
2. Host build:
   `cd rust && CARGO_TARGET_DIR=/c/Users/Victor/wa-build/host-target-b2 WA_CODEMODE_ALLOW_EMPTY=1 cargo build --release --offline -p wa-host`.
   Fix any errors.
3. Gate on wasm_the_first: component blocks of `scripts/test.sh` plus the parity script.
4. Rebase on origin/main. Step 0 (wasmtime 50) touches `service_components.rs` and
   `service_stt.rs`; C1 touches `capabilities.rs`. Check `git diff --stat` for unexpected
   deletions, then fast-forward only.
5. Deploy only after the gate passes, and with Victor's ok:
   - Host via the sentinel (`wa-sentinel request deploy` on openclaw after ff of
     `/local/projects/wasm-agent`).
   - Component: build on wasm_the_first, gzip, relay-copy in chunks, verify sha256, install into
     `~/.wasm-agent/components/` with the manifest, then `services restart wa-whatsapp`.
6. Test config (own chat ONLY):
   ```json
   {"log":"info","pair_phone":"5519994939204","post_transcripts":true,"post_allow":["own"],"stream_edits":true,"header_tag":"wasm"}
   ```
   Then ask Victor for a short (<15 s) and a long (>30 s) self voice note. Measure from the log:
   `first_text_ms`, `total_ms`, `edits`, `edit_errors`. Note how WhatsApp handles repeated
   edits, as observed.
7. Side-by-side day (posting to own chat only), then B3 cutover with Victor's go: `post_allow:["*"]`,
   `alerts:true`, stop Go (keep it installed for rollback).

## Safety rules (hard)
- Posting only to the own chat (`post_allow:["own"]`) until B3 is approved. Never `*` while Go posts.
- Logs carry metadata only, never transcript text. Segment text travels only over the worker pipe.
- Build only on wasm_the_first. Push only as Magaav from wasm_the_first. Never use the laptop company gh.
- Unknown sends never auto-retry.

## Gotchas
- The bindgen module is named `wa`, so the proto alias is `wap`.
- `from` is a WIT keyword.
- Builds use seeded target dirs `guest-target-b2` / `host-target-b2` (copied from `-b`).
