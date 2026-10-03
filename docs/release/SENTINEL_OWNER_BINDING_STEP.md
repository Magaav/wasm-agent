# Owner-bound return construction seam — intermediate implementation

New native sentinel_return module resolves parent user_id from authenticated runtime /session record, binds exact original intent+parent+owner immutably under lock. Events accept ONLY id/event_key; no payload session/instruction/verified authority. Resolve compares journal identity to immutable binding and rechecks runtime parent owner. Named onSentinelReturn Engine wake uses native deterministic instruction construction from resolved journal at existing prepared block seam. Verified phase still refuses until actual installation proof implemented. Local privileged filesystem is not an attested signature.

Private current-source Rust test exercises actual HTTP parent record lookup, legitimate held journal resolve, forged victim event refusal and changed journal parent refusal. All mock server threads joined. Full sentinel suite41passed0failed0ignored, jobs2threads2. Initial compiler emit error retained in transcript; corrected conversion and real test rerun passed. No provider call, no real Engine wake POST in this test. Normal required crate gate reaches this test.

Observer helper contains bounded ten-second event-slot emission into durable Engine queue but is deliberately NOT connected to watcher/deploy yet; cancellation/revision terminal settlement and actual installer verification remain unfinished. Existing effect quarantine remains. This is NOT full original task acceptance, no live install or I-am-updated claim. Next required step is actual private Engine busy wake/disabled/revision receipt evidence and fresh exact-source verifier/installer success before connecting effect path. No external implementation blocker asserted.

No live request/store/install/jobs/config/push/main changes; prior checkpoints/refusals preserved.

Agent: wasm-agent node=wasm_the_first session=child:dispatch:40f63603-1bc4-4a48-9812-12a1055151be
