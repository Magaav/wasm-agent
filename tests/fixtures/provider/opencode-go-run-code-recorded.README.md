# opencode-go-run-code-recorded.sse

A real opencode-go / deepseek-v4.1-flash stream, recorded on this node 21/11/2026 through the vault
route (WASM_AGENT_VAULT_URL + /opencode-go/v1/chat/completions, one x-opencode-session per capture),
with one declared tool, run (its code argument is the script), and a prompt that asked for a
JavaScript script.

It is the evidence for the live run tool: the provider writes the tool call arguments as FOURTEEN
separate SSE frames, and the script itself crosses frame boundaries mid-string (an escape and a
newline are split across chunks). The stdout/output fallbacks inside the recorded script are the
model own words, kept byte for byte - the fixture is evidence, not a hand-written sample.

Used by rust/wa-capabilities/src/host.rs (the tool_call_delta emission) and by
scripts/test-run-code-live.lua (the incremental code decoder, against the same bytes).
