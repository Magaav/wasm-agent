# Mission change/python-codeact — Python as a first-class CodeAct language, composed with JS through WIT

Victor 18/11: go all the way (not steps), like CodeAct only proved itself once it was THE way; models have
asked for Python and found it hard to find and use. Base: origin/main after polish-1811 lands (same
code-mode files). One implementation per behaviour. Build/test on this node only. Never push.

## Required behaviour

1. **Two peer run blocks.** ```js run``` and ```py run``` are both first-class ways to act, presented equally
   in the envelope (not an optional extra). The model picks per block.
2. **One tool bridge, defined once in WIT** (`wit/codeact/tools.wit`, world `wa:codeact`): QuickJS (today's
   runtime) and CPython built as a component (componentize-py) both import the same `tools` interface; the
   host implements it once. Data crosses as typed records, not JSON strings.
3. **Composition both ways.** From JS, `await py(code, input)` runs Python and returns its typed result; from
   Python, `js(code, input)` the reverse; nesting depth bounded (e.g. 3) and stated in the error.
   Shared `vars` (session state) visible to both.
4. **Fast by construction, measured.** Wizer pre-initialized snapshot for the Python component, wasmtime
   pooling allocator for both; report p50/p95 for: instantiate, first call, cross-language call, tool call.
5. **Libraries, locked.** The WIT Python component bakes stdlib + a pinned pure-Python set at build time.
   Heavy native libraries (numpy/pandas...) run through a host-Python tier from ONE hash-locked environment
   per node (`python/requirements.lock`, `--require-hashes`), built by deploy, never by a session. The model
   never runs pip; a new package is a lock change. No network from Python except through `tools.*`.
   Runs inside the session folder (session-home) with CPU/memory/time limits.
6. **Errors teach.** A Python traceback is returned trimmed to the model's own lines, with the failing line
   quoted; an unknown tool from Python names the identifier-safe form (polish-1811 item 2).
7. **Removable.** Everything behind one switch (WASM_AGENT_CODEACT_LANGS=js|js,py) so the A/B and a rollback
   are a config change, not a revert.

## Done when

- Proofs: a py-only task, a js-only task, js->py->js composition, a pandas task through the host tier, a
  refused `pip install`, a refused network call from Python, a bounded nesting error, latency table.
- A/B on the frozen real tasks (email, contacts, MCP search, a data task) js vs js,py: calls, failures,
  output tokens, wall time, and how often the model chose Python. Keep js,py as default if equal or better.
- Envelope/prompt text for the two blocks is shown to Victor verbatim before landing (envelope rule).
