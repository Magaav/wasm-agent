# slim-bash-result fixtures: three REAL answers from the base

Recorded on the base commit `899fdd47` of branch `change/slim-tool-results`, so the removed field
set is measured from data instead of a list somebody typed (mission rule 14). Nothing here is a
reconstruction.

| file | what it is | how it was recorded |
|---|---|---|
| `old-local-bash.json` | the answer a caller got from `tools.bash({command:"echo hi"})` - 38 fields, 1,408 bytes of JSON for 3 bytes of stdout | one real dispatch in a scratch home on the base tree: `tools.dispatch(memory,'bash',{command='echo hi'},'master',ctx)` |
| `old-script-bash.json` | the value a SCRIPT received for the same command inside a run block - 40 fields (the status stamp adds one) | the same run, through `tools.dispatch(memory,'codemode',{code='text(JSON.stringify(await tools.bash({command:"echo hi"})));'})` |
| `old-remote-bash.json` | an OLD PEER's answer: `node:"nextcloud"`, 196 bytes of stdout, 1,608 bytes of envelope, with `/home/ubuntu/.wasm-agent/...` paths in it | copied verbatim from the node's own recorded result store (`~/.wasm-agent/tool-results/60cd56b7...txt`), the same answer `docs/missions/reports/write-names-its-node.md` cites |

The captures above came from this mission's scratch home (`/tmp/slim-capture/home`), which is why the
paths and operation ids inside them are scratch ones; `old-remote-bash.json` keeps the peer's real
paths, which is exactly the point of the mission.

`scripts/test-slim-bash-result.lua` reads all three. It derives the removed key set from
`old-local-bash.json` and its `lua/core/bash_result.lua` allow-list, so a field added to the record
later is covered by the row without editing it.
