# Native worker-admission packaging repair

Producer: node 8b47de58bb47a330379aff5213d35fa9, session child:native-shipping-producer-20261004-v1.
Owned branch: change/wa-session-childnative-shipping-producer-20261004-v1.
Source/base: 3f54a90d9d23b105df93002a683135d62cde81e0 (fresh fetch, strict host-key checking, original allocated tree).

The wave shipper formerly followed only ESM regex matches in .mjs. It now follows declared literal require calls in .mjs/.cjs/.js as well, with a small lexical scan to exclude comments and string/template/regex prose. Existing traversal deduplication, cycle termination, realpath confinement and visible missing-dependency failure remain. Supported static forms and limitations are documented beside the scanner: exact unescaped filenames; no computed paths or template interpolation closure. This is not a general JavaScript parser. Risk: unusual JavaScript regex contexts outside the supported scanner conventions may require a parser later; no external parser dependency was added.

The manifest already covers scripts/lib/* and the other reached paths. No impact declaration, installer control paths, allocator, gates or runtime loops changed.

## Observed focused checks

Commands run from the owned checkout with explicit shell cd:

- node scripts/test-ship-wave.mjs: exit 0, 14 checks, 0 skipped. Stages actual production closure into disposable private installs. Baseline shipper bytes are read with git show from the exact base above: baseline shipping succeeds but NORMAL staged wave-entry check allocate fails Cannot find module test-verdict.cjs. Patched staged entry returns ok:true isolated_local_fixture JSON; invalid repository returns ok:false JSON/status 1. Staged gate-check conditional proof verdict succeeds. Deleting proof-verdict.cjs produces a refused proof verdict; deleting test-verdict.cjs prevents normal admission loading. Synthetic CJS/JS cycles, transitive export/import forms and prose controls pass; missing literal and scripts-root escape refuse.
- node scripts/test-wave-ship.mjs: exit 0, 5 checks, 0 skipped.
- node scripts/check-deploy-shipped.mjs: exit 0, 98 actual checks, 18 installer rules, 43 shipped files. Only note: transcript plugin is an installer-built artifact, not an absent skipped check.
- node scripts/test-gate-check.mjs: exit 1 after runner/isolation/browser assertions; missing required Windows run-key HTTP candidate. No current-source binary exists in this checkout. HTTP regression did not run. No substitute installed binary or build was used.
- node scripts/test-producer-admission.mjs: exit 0, terminal routine/local-case/independent-scope/strict-pre-release verdict, 0 skipped; suite does not emit a numeric check count. Browser logs validate contract only.
- git diff --check: exit 0.
- git fetch origin; git merge --ff-only origin/main: exit 0, already current.
- git merge-tree --write-tree origin/main HEAD before commit: exit 0, base tree 11a77bc56a7049c853a760e207c4d9e4ef01920a.

Raw operation logs retained under the private candidate home's .wasm-agent/operations:
op-1791135646949264-24204-28 (four-suite sequence, including gate-check failure),
op-1791135658539846-24204-34 (producer suite/sync/merge proof),
op-1791135542389905-24204-4 (successful fresh fetch).
Original blocked-run evidence remains preserved. WASM_AGENT_LUA_ROOT explicitly names canonical source; no Lua test was needed or run for this JS-only patch. Graph audit opt-in was unset.

Local committed delivery only; no push/fake upstream, main move, merge, deploy, restart, installation overwrite or operator-state mutation. Independent source review remains outstanding. Live admission is NOT claimed repaired before sanctioned publisher activation and a real native worker probe. gate_verified:false; release_verified:false. Full gate/build deliberately not run, as requested.
