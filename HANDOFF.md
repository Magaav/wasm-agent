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

## Build state (pi/b2 worktree, this run)
- **Native `cargo test --lib` (component):** PASSES, 38 tests, no wasm target needed. The crate is now
  split: `queue`, `holds`, `posting`, `alerts` are pure modules compiled on every target (their tests
  run with `cargo test --lib`); `store` and `guest` (the old lib.rs body) are `#[cfg(target_arch =
  "wasm32")]`, which also removes the old off-wasm trait mismatch (wacore's traits want `Send`
  futures natively; on wasm the component uses `#[async_trait(?Send)]`).
- **`cargo clippy --lib`:** clean.
- **Guest `wasm32-wasip2`:** `cargo build --release --target wasm32-wasip2` BUILDS (7.9 MB,
  `wasm-tools validate` OK, exports `wa:kernel/service@0.1.0#run`).
- **Host:** `cargo build --release -p wa-host` BUILDS with the B2 `service_stt.rs` /
  `service_components.rs` / WIT changes (14 pre-existing warnings).
- Builds used `CARGO_TARGET_DIR` (`target-b2` guest, `target-b2-host` host), `--offline`, nothing
  outside the clone except those target dirs.

## Parity checklist
| item | status |
| --- | --- |
| warm worker / no idle stop | code done; host compiles |
| reply quoting the audio | code done, untested live |
| 5-min freshness (pickup), never-late, post_expired | done (queue + guest), unit-tested |
| no reposts (kv dedup, restart) | done |
| own-chat alerts batched | done, sending gated by `alerts` (default off: Go also sends them) |
| per-message fences (revoke/edit) | done through `holds.rs` (proven vs unproven); unverified that whatsapp-rust delivers protocol messages to `on_message` |
| chat holds | **ported**: `holds.rs` = Go's `mutationProof`/`mutate`/`reproveHolds` (posting-only vs compute holds, strengthen never weaken, re-prove at start), plus the static `held_chats` config; unit-tested |
| express lane | **ported**: `queue::take_express` (≤ 90 s notes, only while the main lane decodes a long one), wired in `dispatch`; unit-tested. The host's `speech` is still one worker, so the overlap is download/post, not decode |
| durable queue across restart | **ported**: `queue::snapshot`/`restore` through kv (`queue`, `holds` keys); an item in flight at a stop returns as an `interrupted_by_restart` notice and is never re-posted; unit-tested |
| group titles in alerts | **ported**: the group subject from `groups().get_metadata` is used instead of the sender's push name (`alerts::title_of`); unit-tested |
| segment streaming | done (host + WIT + worker + component) |
| post-then-edit (`stream_edits`, default off) | done, untested live |
| unit tests | **run**: `cd rust/components/wa-whatsapp && cargo test --lib` -> 38 passed |

## Remaining steps
1. ~~Make the unit tests run natively~~ done (38 tests). ~~Host build~~ done. ~~B3 prerequisites~~
   ported (holds, express lane, durable queue, group titles).
2. Gate on wasm_the_first: component blocks of `scripts/test.sh` (the parity script
   `scripts/test-component-whatsapp-parity.mjs`) plus the new native test command. `scripts/test.sh`
   has no block for `cargo test` in `rust/components/wa-whatsapp` yet (it is a separate workspace,
   not a member of `rust/Cargo.toml`); adding one is a coordinator change, not made here.
3. Rebase on origin/main. Step 0 (wasmtime 50) touches `service_components.rs` and
   `service_stt.rs`; C1 touches `capabilities.rs`. Check `git diff --stat` for unexpected
   deletions, then fast-forward only.
4. Deploy only after the gate passes, and with Victor's ok:
   - Host via the sentinel (`wa-sentinel request deploy` on openclaw after ff of
     `/local/projects/wasm-agent`).
   - Component: build on wasm_the_first, gzip, relay-copy in chunks, verify sha256, install into
     `~/.wasm-agent/components/` with the manifest, then `services restart wa-whatsapp`.
5. Test config (own chat ONLY):
   ```json
   {"log":"info","pair_phone":"5519994939204","post_transcripts":true,"post_allow":["own"],"stream_edits":true,"header_tag":"wasm"}
   ```
   Then ask Victor for a short (<15 s) and a long (>30 s) self voice note. Measure from the log:
   `first_text_ms`, `total_ms`, `edits`, `edit_errors`. Note how WhatsApp handles repeated
   edits, as observed.
6. Side-by-side day (posting to own chat only), then B3 cutover with Victor's go: `post_allow:["*"]`,
   `alerts:true`, stop Go (keep it installed for rollback).

## Safety rules (hard)
- Posting only to the own chat (`post_allow:["own"]`) until B3 is approved. Never `*` while Go posts.
- Logs carry metadata only, never transcript text. Segment text travels only over the worker pipe.
- Build only on wasm_the_first. Push only as Magaav from wasm_the_first. Never use the laptop company gh.
- Unknown sends never auto-retry.

## Gotchas
- The bindgen module is named `wa`, so the proto alias is `wap`.
- `from` is a WIT keyword.
- The crate is split: `src/lib.rs` is a shell (`pub mod alerts/holds/posting/queue`, then `store` and
  `guest` under `cfg(target_arch = "wasm32")`, with `wit_bindgen::generate!` before `mod guest` so
  the generated `export!`/`exports` are in textual scope). `src/guest.rs` is the old `lib.rs` body.
  Add host-testable decisions to the pure modules; anything touching `kv`/`http`/`speech` goes to
  `guest.rs`.
- New kv keys owned by the component: `queue` (queue snapshot), `holds` (holds + fences),
  `tx/<chat>/<id>` (dedup record, also the author a revoke is proved against), `fence/<id>` (written
  by older builds; still honoured, never removed).
- `cargo test --lib` and `cargo clippy --lib` in `rust/components/wa-whatsapp` are the native path
  (separate workspace, not a member of `rust/Cargo.toml`). The wasm build is still
  `cargo build --release --target wasm32-wasip2` from the same directory.
- Builds here used the seeded target dir in `$CARGO_TARGET_DIR` (`target-b2` guest,
  `target-b2-host` host, both `--offline`).
