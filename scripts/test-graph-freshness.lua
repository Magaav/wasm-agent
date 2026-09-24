-- A real host query must rebuild a missed change instead of returning stale nodes.
local json = dofile("lua/vendor/json.lua")
local root = dofile("lua/core/paths.lua").data() .. "/graph-freshness-fixture"
local db = root .. "/graph.db"
local opts = json.encode({ root = root, db = db })
local function decode(raw)
  local value = json.decode(raw)
  assert(not value.error, tostring(value.error))
  return value
end
local function has(rows, name)
  for _, row in ipairs(rows) do
    if row.name == name then return true end
  end
  return false
end

assert(host.write_file(root .. "/a.rs", "fn alpha() {}\n"))
assert(decode(host.graph_status(opts)).ready == false)
assert(has(decode(host.graph_query("alpha", opts)), "alpha"))
local alpha = decode(host.graph_search("alpha", opts))[1]
assert(alpha.name == "alpha")
local alpha_source = decode(host.graph_source(json.encode({root=root,db=db,path=alpha.path,
  name=alpha.name,line=alpha.line,kind=alpha.kind})))
assert(alpha_source.source == "fn alpha() {}" and alpha_source.freshness == "verified_snapshot")
assert(decode(host.graph_status(opts)).ready == true)

assert(host.write_file(root .. "/a.rs", "fn bravo() {}\n"))
assert(decode(host.graph_status(opts)).ready == false)
assert(not has(decode(host.graph_query("alpha", opts)), "alpha"))
assert(has(decode(host.graph_query("bravo", opts)), "bravo"))
assert(#decode(host.graph_search("alpha", opts)) == 0)

assert(host.write_file(root .. "/b.lua", "local function beta() end\n"))
assert(has(decode(host.graph_query("beta", opts)), "beta"))
print("graph freshness ok")
