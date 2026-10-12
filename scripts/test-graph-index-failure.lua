-- Deterministic worker failure before publication; private process sets an invalid parse knob.
local json=dofile('lua/vendor/json.lua');local paths=dofile('lua/core/paths.lua')
local root=paths.data()..'/failed-index';assert(host.write_file(root..'/a.lua','function must_not_escape() end\n'))
local result=json.decode(host.graph_query('must_not_escape',json.encode({root=root})))
assert(result.error and result.error:find('invalid_graph_parse_timeout_ms',1,true),'exact parse failure visible')
assert(result.required_revision>0 and result.committed_revision==0 and result.next:find('read/grep',1,true),'revisions and recovery guidance')
assert(not result.items and not result.source and not result[1],'failure cannot masquerade as empty/fresh source')
print('graph failed index ok')
