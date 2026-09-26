-- Real-terminal fixture: run under Orca with a scratch home and WA_CLI_PROBE_OUT.
-- First submit "first" + Shift+Enter + "second". During the blocked run, type
-- "draft" + Shift+Enter + "kept" without submitting; inspect the rendered frame.
-- After completion, Enter must submit the whole surviving draft.
local json = dofile("lua/vendor/json.lua")
local input = dofile("lua/core/cli_input.lua").new({ editor = true })
assert(input.editor, "probe needs a real raw terminal")
local size = json.decode(host.terminal_size())
local view = dofile("lua/core/cli_view.lua").new({ live = true, limit = size.columns,
  budget = 272000, title = "CLI TERMINAL PROOF" })
view.editor = true
local output = assert(host.getenv("WA_CLI_PROBE_OUT"), "WA_CLI_PROBE_OUT missing")
local function record(stage, text)
  assert(host.write_file(output, json.encode({ stage = stage, text = text,
    rows = size.rows, columns = size.columns })))
end
view:line("CLI proof: first / Shift+Enter / second / Enter")
view:prompt()
record("ready")
local text = input:poll(60000)
assert(text == "first\nsecond", "Shift+Enter submitted or lost a newline: " .. tostring(text))
view:accepted(text)
view:run_started()
view:event({ type = "round", n = 6 })
view:event({ type = "tool", name = "bash", arguments = { command = "proof" } })
view:event({ type = "usage", total = { prompt = 120400, completion = 1000, cached = 90540 }, prompt = 27200 })
record("running", text)
for i = 1, 20 do
  host.sleep(500)
  view:event({ type = "reasoning", text = "## Reasoning " .. i .. "\n\n- **rendered** item\n- `code` survives" })
end
host.sleep(10000)
view:answered("## Rendered answer\n\n- **bold** item\n- `code` item\n\n```lua\nprint('proof')\n```")
view:prompt()
record("idle")
text = input:poll(60000)
assert(text == "draft\nkept", "draft did not survive output: " .. tostring(text))
record("pass", text)
view:screen_off()
input:stop()
print("CLI TERMINAL PROOF PASS")
