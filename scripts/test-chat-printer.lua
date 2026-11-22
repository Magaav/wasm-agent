-- The chat printer hands the view a REDACTED tool result, and a file change with every field its diff
-- block needs. Review r1 of tui-diff-view (21/11): a merge of two new branches into the printer left the
-- tool_result branch with no `ready = ...` line, so the view got the raw event (the secret redactor
-- skipped) and the `change` branch overwrote its own event with a fieldless one - the view tests drive
-- cli_view directly and could not see it. This row drives the printer itself.
local secret = "sk-FAKE-PRINTERSECRET-0123456789abcdef"
local native_getenv = host.getenv
host.getenv = function(key)
  if key == "WASM_AGENT_LLM_API_KEY" then return secret end
  return native_getenv(key)
end
local chat = dofile("lua/core/chat.lua")
local seen = {}
local view = { event = function(_, e) seen[#seen + 1] = e end, warn = function(_, w) error("view warned: " .. tostring(w)) end }
local emit = chat._printer(view)
local checks = 0
local function check(v, label) if not v then error("check failed: " .. label) end checks = checks + 1 end

emit({ type = "tool_result", name = "bash", result = { code = 0, stdout = "token " .. secret .. " end" } })
local r = seen[#seen]
check(r and r.type == "tool_result" and r.name == "bash", "the tool result reaches the view as a tool_result")
check(type(r.result) == "table" and type(r.result.stdout) == "string", "with its result table")
check(not r.result.stdout:find(secret, 1, true), "and the secret in its stdout is REDACTED before the view sees it")

emit({ type = "tool_result", name = "read", result = "plain " .. secret })
check(type(seen[#seen].result) == "string" and not seen[#seen].result:find(secret, 1, true), "a string result is redacted too")

emit({ type = "change", name = "edit", path = "a.lua", before = "b1", after = "a1", recorded = true, added = 2, removed = 1, created = false })
local c = seen[#seen]
check(c.type == "change" and c.path == "a.lua" and c.before == "b1" and c.after == "a1", "a change keeps its path and both content addresses")
check(c.added == 2 and c.removed == 1 and c.recorded == true, "and its counts")

emit({ type = "bash_changes", command = "sed -i x f", files = { { path = "f" } }, refused = {} })
check(seen[#seen].type == "bash_changes" and seen[#seen].command == "sed -i x f" and #seen[#seen].files == 1, "a shell command's changes reach the view")

-- The two fields this printer learned with the card's own name for a change (Victor 22/11): `deleted`
-- names the card Delete, and a change made on ANOTHER node is its own event, because the peer's answer
-- carries no text to draw. Both are allow-listed here, so an event that loses them says so.
emit({ type = "change", name = "bash", path = "b.lua", before = "b1", after = "e3b0", recorded = true,
  added = 0, removed = 3, created = false, deleted = true })
local gone = seen[#seen]
check(gone.type == "change" and gone.path == "b.lua" and gone.deleted == true, "a removal keeps its path and its deleted fact")
check(gone.created == false and gone.after == "e3b0", "and the addresses the card reads its lines from")
emit({ type = "remote_change", capability = "write", node = "peer-one", path = "/srv/x.md", ok = false,
  error = "not_peer_operator" })
local remote = seen[#seen]
check(remote.type == "remote_change" and remote.node == "peer-one" and remote.path == "/srv/x.md",
  "a change made on another node reaches the view as one row's worth of facts")
check(remote.ok == false and remote.error == "not_peer_operator", "including that it did not happen")
emit({ type = "remote_change", capability = "edit", node = "peer-one", path = "/srv/x.md", ok = true,
  before_text = "one\n", after_text = "two\n" })
local peer = seen[#seen]
check(peer.type == "remote_change" and peer.before_text == "one\n" and peer.after_text == "two\n",
  "and the two texts the peer sent, which are what the card is drawn from")
print("chat printer ok (" .. checks .. " checks)")
