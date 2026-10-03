local json=dofile('lua/vendor/json.lua')
local root,name,ref=host.getenv('WA_ALIAS_ROOT'),host.getenv('WA_ALIAS_NAME'),host.getenv('WA_ALIAS_REF')
local function call(action,args) return json.decode(host.resource(action,json.encode(args))) end
local owner={principal=name,session=name,run=name,keys={'session:'..name}}
assert(call('claim',owner).ok)
local args={git_common_dir=root..'/git',ref=ref}
local held=call('target_hold',args)
local inspection=call('target_inspect',args)
assert(host.write_file(root..'/'..name..'.json',json.encode({hold=held,inspection=inspection})))
if held.ok then
  while not host.read_file(root..'/release') do host.sleep(10) end
  assert(call('target_release',{git_common_dir=args.git_common_dir,ref=ref,receipt=held.receipt,evidence='Private two-process actual-ref alias check complete'}).ok)
end
assert(call('finish',owner).ok)
