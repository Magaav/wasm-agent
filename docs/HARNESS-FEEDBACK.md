# Harness feedback recovery register (incomplete)

Recovery session: `child:dispatch:5cff88a0-bdca-4593-88e9-774cc54e27a5`.
Original draft: `child:dispatch:9306399f-ff1c-45fb-bbf0-64bbb277b11b`, branch `change/harness-efficiency`, HEAD `dc271bb` plus dirty draft. Original checkout and transcript remain untouched.

This checkpoint is NOT a completed delivery. The rough extraction in `scratch/harness-lines.txt` is an index of reports, not verified occurrence counts. No claim of 119 unique issues is made.

| Dedup key | Original evidence inspected | Classification/state | Falsifiable check / metric |
| --- | --- | --- | --- |
| scratch/write/workspace binding | Original draft session seq149–150 contains exact implementation intent and successful edit receipt; extraction entries 3,8,43,49 identify reporting sessions but their original calls are not yet inspected | Intentional isolation refusal; narrow session-owned exception partially transferred, unverified | Own scratch write succeeds; other session scratch and checkout writes refuse. Staging workaround calls decrease without increasing cross-session write acceptance |
| command/bash/~8KB | Original draft test file preserves claimed 8200/8300-byte measurement; reporting sessions in extraction entries3,27 not yet inspected | Uncertain until fresh native launch reproduction; long-command Rust draft NOT transferred | Compare exact requested bytes, terminal sentinel and heredoc file bytes for direct `-c` vs script-file launch. Partial successful commands must be zero |
| output/adopted-command/stderr | Original dirty operations.rs shows 8192-byte stderr view lacked bound metadata | Partial transfer, unverified; command-size failure is distinct | Emit >8192 stderr bytes with supervised descendant; bounded flag/size and durable original must agree. Unmarked truncation zero |

Remaining: preserve/transfer the complete long-command draft after reproduction; add and run regression tests with source Lua root; inspect original session calls for every retained complaint; deduplicate remaining extraction without promoting summaries to evidence. UI/gate and provider issues belong to other lanes. No arbitrary temp-root grant, fixed worker cap or broad rewrite is authorized.
