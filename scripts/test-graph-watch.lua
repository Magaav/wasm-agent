-- Real OS event proof. The external Node writer bypasses all native mutation hints.
local json=dofile('lua/vendor/json.lua');local paths=dofile('lua/core/paths.lua')
local root=paths.data()..'/watched-source';local db=paths.data()..'/watched-graph.db'
assert(host.write_file(root..'/a.lua','function initial() return 1 end\n'))
local options=json.encode({root=root,db=db});local first=json.decode(host.graph_query('initial',options));assert(first[1].name=='initial')
local status=json.decode(host.graph_status(options));assert(status.watch_registered,'actual OS registration required')
local before=status.committed_revision
local script=paths.data()..'/external-graph-writer.cjs'
assert(host.write_file(script,"require('node:fs').writeFileSync("..json.encode(root..'/a.lua')..","..json.encode('function external() return 2 end\n')..");console.log('external write done');\n"))
local written=json.decode(host.exec('node "'..script..'"',nil,10));assert(written.code==0 and written.stdout:find('external write done',1,true),'external writer must settle')
local command=dofile('lua/core/platform.lua').os()=='windows' and 'ping -n 2 127.0.0.1 >NUL' or 'sleep 1'
assert(json.decode(host.exec(command,nil,5)).code==0)
-- Status verifies only. No query admission may repair a missed hint before this assertion.
local after=json.decode(host.graph_status(options));assert(after.ready and after.committed_revision>before,'OS event must actually publish the changed graph in the background')
local source=json.decode(host.graph_source(json.encode({root=root,db=db,path='a.lua',name='external',line=1})));assert(source.source=='function external() return 2 end')
print('graph external watch ok')
