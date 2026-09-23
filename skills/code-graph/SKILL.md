---
name: code-graph
description: Navigate this codebase as a graph instead of grepping. Use before grep/read whenever you need to find where something is defined, who calls it, how two things connect, or which host.* capabilities the code uses.
---

# Navigate before you grep

The `graph` tool answers navigation questions directly from an index of the code,
so it costs one call where grep costs a search plus a read of every candidate.
Reach for it first; fall back to `grep`/`read` when you need the actual lines.

The node keeps the index fresh as files change, so you almost never call
`index` yourself.

## The four questions

```
graph {action:"explain", name:"append_turn"}
```
What is it, what does it use, who calls it. `definitions` lists each match with
its `kind`, definition `path:line`, the `uses` (calls, capabilities, macros) and
the `callers` at their exact call-site `path:line`. Start here when you know a symbol.

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
