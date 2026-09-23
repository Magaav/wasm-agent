---
name: code-graph
description: Use the graph for explicit dependency questions or to audit a code patch's possible missed callers. Grep/read remain normal navigation; graph leads require source verification.
---

# Dependency leads and patch impact

The `graph` tool answers relationship questions from an index of the code. Use it
when a dependency question is explicit; use `grep`/`read` for ordinary source
navigation and to verify any graph lead. The opt-in patch audit uses the graph
at the end of a native `write`/`edit` run, not as a mandatory first search.

`graph {action:"audit"}` checks the current run's recorded patch against resolved
callers not read through native `read`/`read_many`; use `source:"git"` for the
current staged-and-unstaged Git patch, including shell edits. `graph {action:"audit_report",
hours:48}` summarizes the trial. `audit_feedback` records an operator-reviewed
outcome for a run with leads; never label a catch yourself. See
`docs/GRAPH-PATCH-AUDIT.md` for the limits and decision rule.
After an audit follow-up step, use `audit_assess` to record your usefulness
grade (0-3), concrete reason and critique. This is your opinion, not a confirmed
catch; grade 3 only means the lead prompted a patch or test revision.

The node refreshes the index as files change. Every answer verifies the indexed
source bytes; if verification or refresh fails, the tool reports an error. Use
`grep`/`read` in that case rather than treating an empty graph result as evidence.

## The four questions

```
graph {action:"explain", name:"append_turn"}
```
What is it, what does it use, who calls it. `definitions` lists each match with
its `kind`, definition `path:line`, the `uses` (calls, capabilities, macros) and
the `callers` at their exact call-site `path:line`. Exact names and member
suffixes suppress unrelated substring matches. Start here when you know a symbol.

```
graph {action:"path", from:"choose_worker", to:"append_turn"}
```
How A reaches B, **in the direction of use**: a step exists when the previous
node calls, uses or imports the next one. It does not walk back up to callers,
so `path` from a callee to its caller is *not found* — ask `explain` for "who
calls this", and do not read a shared callee as connecting two functions that
merely both call it. `steps` is a chain; each step's `via` names the edge that
reached it. Mentions in prose are deliberately ignored, so a hop is a real
call/import, not a coincidence.
Each `via` includes the call-site `path:line`; the step's own `path:line` is
the destination definition. Cite the former for the hop.
For a known start and end, try `path` before broad name queries. The graph
follows literal Rust `lua.call_string("entrypoint", ...)` calls into Lua and
statically named `pcall`/`xpcall` targets.

```
graph {action:"query", name:"routing_session"}
```
Ranked, compact symbol matches. Use it when you know a word but not the symbol.
The default shows 12 results and `truncated` says whether more exist; pass
`limit` to see more. Known symbols belong in `explain`, not broad `query` calls.
Literal HTTP route patterns are indexed too: query `"/subagents"` to find the
route line, then use its enclosing handler name as the start of `path`.

```
graph {action:"caps"}
```
The `host.*` capabilities and how often each is called, most-used first. This is
the answer to "what is this code allowed to do, and who does it" — a `host.*`
call is a typed edge, not a string.

## Reading the result

- `kind` is `fn`, `method`, `struct`, `module`, `field`, `var`, `capability`,
  `doc`, and so on. `method` means it lives in an `impl`.
- A `caller`/`use` with `-> path:line` was resolved to a definition. One without
  it is a name the index could not pin down (an external call, or a name that is
  ambiguous across files) — treat it as a lead, not a fact.
- `host.<name>` entries are capabilities. If you need to know whether a
  capability is reachable from a run, `caps` plus `explain` answers it without
  reading the host.

## Limits — when the graph is not enough

- It indexes syntax, not semantics. A call through a differently-named module
  alias may resolve to the wrong `M.x`, and trait/generic identity is not
  modelled. If `explain` shows no caller you expected, confirm with `grep`.
- Rust, Lua, JavaScript/TypeScript, Bash, PowerShell and Markdown are indexed. Other files are not.
- It is a map, not the territory: always `read` the file before you edit it.
