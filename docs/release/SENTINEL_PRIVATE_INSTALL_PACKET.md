# Private installer packet preparer — execution not completed

scripts/prepare-sentinel-private-install.py clones exact clean committed producer tip into a private source main and private bare origin/main, reserves private directories, selects ports, emits exact command arrays/env/script hashes. It never executes install or removes a WA marker. Run OUTSIDE WA only after commit:
`python scripts/prepare-sentinel-private-install.py --repo "C:/Users/Victor/.wasm-agent/wa-worktree-childdispatch40f63603-1bc4-4a48-9812-12a1055151be" --head <exact tip> --packet "C:/Users/Victor/AppData/Local/Temp/wa-private-install-<unique>"`

Root must consume packet.json commands under its suspended assigned Job and new private environment. This preparer is NOT yet a self-contained supervised execute/normalize/verify harness: source-build receipts, real parent ownership seeding, private watcher starting when no watcher exists, port race revalidation, supported shell path conversion, installer side-effects audit and actual zero-skip verify success are still missing. Do NOT execute packet blindly as accepted proof; no successful installation claimed. Owner/session template intentionally not fabricated from nonexistent runtime facts. Exact usable effect admission remains quarantined.

Preparation command executed after this commit will validate actual source; no external installer execution performed by this lane. Original full stage remains unfinished, no external blocker asserted. This is an executable preparer, not full protocol acceptance.

No live actors/stores/install/main/push changes. Root outside execution does not permit marker stripping or global tasks/services/window effects. All prior receipts remain.

Agent: wasm-agent node=wasm_the_first session=child:dispatch:40f63603-1bc4-4a48-9812-12a1055151be
