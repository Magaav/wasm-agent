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
        dst_path = "src/caller.lua", dst_line = 10,
        resolution = "import_exact", confidence = 98 },
      { kind = "mentions", path = "docs/notes.md", line = 3 },
    },
  }})
end
host.graph_search = function(_, options)
  local limit = json.decode(options).limit
  return json.encode({
    { kind="fn", name="target", path="src/target.lua", line=7, language="lua",
      signature="target(value)", score=1000, confidence="exact", reason="exact_name",
      matched_terms={"target"}, score_breakdown={exact=1000,bm25=80} },
    limit > 1 and { kind="fn", name="target_helper", path="src/helper.lua", line=2,
      language="lua", score=300, confidence="medium", reason="name_terms",
      matched_terms={"target"} } or nil,
  })
end
host.graph_overview = function(options)
  local requested=json.decode(options)
  assert(requested.limit == 1 and requested.aspects[1] == "languages")
  return json.encode({generation="abc",freshness="verified_snapshot",
    languages={total=2,returned=1,truncated=true,rows={{language="lua",files=4}}}})
end
host.graph_impact = function(options)
  local requested=json.decode(options)
  assert(requested.direction == "inbound" and requested.depth == 2)
  assert(requested.changes[1].path == "src/target.lua")
  return json.encode({generation="abc",impact={total=1,returned=1,truncated=false,
    rows={{name="caller",path="src/caller.lua",hop=1,direction="caller",
      via={resolution="import_exact",confidence=98}}}}})
end
host.graph_source = function(options)
  local selected = json.decode(options)
  assert(selected.path == "src/target.lua" and selected.name == "target" and selected.line == 7)
  return json.encode({symbol=selected,source="function target(value)\n  return value\nend",
    bytes=42,byte_offset=0,returned_bytes=42,eof=true,freshness="verified_snapshot"})
end

local graph = dofile("lua/core/graph.lua")
local found = assert(graph.query("match"))
assert(requested_limit == 13 and found.count == 12 and found.truncated)
assert(found.results[1].detail == nil and found.results[1].col == nil)
local explained = assert(graph.explain("target"))
assert(#explained.definitions == 1)
assert(#explained.definitions[1].callers == 1)
assert(explained.definitions[1].callers[1] == "src/caller.lua:42")
assert(explained.definitions[1].caller_evidence[1].resolution == "import_exact")
local searched = assert(graph.search_symbols("target", {limit=1}))
assert(searched.count == 1 and searched.truncated and searched.verdict == "ok")
assert(searched.results[1].confidence == "exact" and searched.results[1].signature == "target(value)")
assert(searched.results[1].score_breakdown.exact == 1000)
host.graph_search = function(_, options)
  assert(json.decode(options).prefer_implementations == true)
  return json.encode({{kind="var",name="topic",path="ui/components.js",line=10,
    score=410,confidence="medium",matched_terms={"topic"},unmatched_terms={"diff"},
    unmatched_definition_terms={"diff"},
    score_breakdown={partial_variable=-240}}})
end
local partial = assert(graph.search_symbols("diff topic", {prefer_implementations=true}))
assert(partial.verdict == "partial" and partial.results[1].unmatched_terms[1] == "diff")
assert(partial.next:find("bounded grep", 1, true))
local source = assert(graph.symbol_source(searched.results[1]))
assert(source.eof and source.source:find("return value", 1, true))
local overview=assert(graph.overview({aspects={"languages"},limit=1}))
assert(overview.languages.total == 2 and overview.languages.truncated)
local impact=assert(graph.impact({changes={{path="src/target.lua",lines={7}}}},
  {direction="inbound",depth=2,limit=5}))
assert(impact.impact.rows[1].via.resolution == "import_exact")
print("graph tool ok")
