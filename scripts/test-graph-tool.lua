-- The model-facing graph must return a small, correctly located answer.
local json = dofile("lua/vendor/json.lua")
local requested_limit
host.graph_query = function(_, options)
  requested_limit = json.decode(options).limit
  local rows = {}
  for i = 1, requested_limit do
    rows[i] = { kind = "fn", name = "match" .. i, path = "src/x.lua", line = i,
      col = 3, lang = "lua", detail = "large signature" }
  end
  return json.encode(rows)
end
host.graph_explain = function()
  return json.encode({{
    node = { kind = "fn", name = "target", path = "src/target.lua", line = 7 },
    outgoing = {},
    incoming = {
      { kind = "calls", path = "src/caller.lua", line = 42,
        dst_path = "src/caller.lua", dst_line = 10 },
      { kind = "mentions", path = "docs/notes.md", line = 3 },
    },
  }})
end

local graph = dofile("lua/core/graph.lua")
local found = assert(graph.query("match"))
assert(requested_limit == 13 and found.count == 12 and found.truncated)
assert(found.results[1].detail == nil and found.results[1].col == nil)
local explained = assert(graph.explain("target"))
assert(#explained.definitions == 1)
assert(#explained.definitions[1].callers == 1)
assert(explained.definitions[1].callers[1] == "src/caller.lua:42")
print("graph tool ok")
