-- Private source-root fixture. No provider, production store, or node restart.
local json=dofile('lua/vendor/json.lua')
local function call(action,args) return json.decode(host.resource(action,json.encode(args or {}))) end
local function check(value,label) assert(value,label); print('CHECK '..label) end
local mode=host.getenv('WA_TARGET_MODE')
local root=host.getenv('WA_TARGET_ROOT')
local args={git_common_dir=root..'/git',ref='refs/heads/fixture'}
local alice={principal='alice',session='session-a',run='resource-run-a',keys={'session:session-a'}}
local bob={principal='bob',session='session-b',run='resource-run-b',keys={'session:session-b'}}
local function with_receipt(receipt)
  return {git_common_dir=args.git_common_dir,ref=args.ref,receipt=receipt}
end
local function quote(s) return "'"..s:gsub("'","'\\''").."'" end
if mode=='hold' or mode=='crash' then
  check(call('claim',alice).ok,'trusted Lua session admission')
  local inspection=call('target_inspect',args)
  check(inspection.complete and inspection.admissible and #inspection.conflicts==0,'complete fresh typed inventory')
  local held=call('target_hold',args)
  check(held.ok and held.receipt.kind=='held-target-resource','native held receipt')
  local r=held.receipt
  check(r.principal=='alice' and r.session==alice.session and r.run==alice.run and r.boot~='', 'receipt binds actual resource owner')
  check(type(r.process_id)=='number' and type(r.creation_stamp)=='string','actual native process identity')
  check(r.scope.ref==args.ref and r.scope.git_common_dir~='', 'normalized target scope')
  check(call('target_check',with_receipt(r)).held,'held check before effect')
  host.write_file(root..'/receipt.json',json.encode(r))
  if mode=='crash' then
    host.write_file(root..'/ready','held')
    host.sleep(60000)
  else
    -- The native process retains its target lease while the owned external
    -- process performs fresh inspection, reservation and private Git CAS.
    local effect=host.getenv('WA_TARGET_EFFECT')
    check(host.sha256(host.read_file(effect))==host.getenv('WA_TARGET_EFFECT_SHA256'),'external effect source bytes pinned')
    local result=json.decode(host.exec('node '..quote(effect)..' effect '..quote(root)..' '..quote(host.getenv('WA_TARGET_BINARY')),host.getenv('WASM_AGENT_LUA_ROOT'),30))
    check(result.ok and result.settled==true,'owned external publication effect settled')
    check(call('target_inspect',args).admissible,'fresh inspection preserves held exclusion')
    check(call('target_check',with_receipt(r)).held,'same receipt held after external effect')
    local release=with_receipt(r); release.evidence='Private fixture CAS readback and owned external operation settled'
    check(call('target_release',release).ok,'explicit evidenced release')
    check(call('finish',alice).ok,'normal session settlement after target release')
  end
elseif mode=='contend' then
  check(call('claim',bob).ok,'competing owner admitted independently')
  local inspect=call('target_inspect',args)
  check(inspect.complete and not inspect.admissible and #inspect.conflicts==1,'foreign held target visible in complete inventory')
  check(call('target_hold',args).error=='target_lease_held_or_unavailable','OS-held exclusion across external effect')
  local r=json.decode(host.read_file(root..'/receipt.json'))
  check(call('target_check',with_receipt(r)).error=='target_not_held','copied receipt never establishes authority')
  check(call('reconcile',{key=r.key,principal=r.principal,run=r.run,evidence='private live-owner negative'}).error=='resource_owner_active_or_unavailable','live held owner cannot be reconciled')
  check(call('finish',bob).ok,'competing session settles')
elseif mode=='restart' then
  check(call('claim',bob).ok,'fresh restart session admitted')
  local r=json.decode(host.read_file(root..'/receipt.json'))
  check(call('target_check',with_receipt(r)).error=='target_not_held','restart cannot adopt exported receipt')
  local inventory=call('target_inspect',args)
  check(inventory.complete and not inventory.admissible,'crashed claim remains a conflict after OS lease release')
  local found=false
  for _,claim in ipairs(inventory.claims) do
    if claim.key==r.key then found=claim.liveness=='lease_released' and claim.boot==r.boot end
  end
  check(found,'positive OS lease release observed without inventing drain')
  check(call('target_hold',args).error=='target_conflicts_or_incomplete','crash never authorizes automatic reacquisition')
elseif mode=='forged' then
  local r=json.decode(host.read_file(root..'/receipt.json'))
  check(call('target_check',with_receipt(r)).error=='resource_context_required','receipt alone cannot establish current owner')
  local forged={git_common_dir=args.git_common_dir,ref=args.ref,boot=r.boot,process_id=r.process_id,receipt=r}
  check(call('target_hold',forged).error=='target_caller_identity_forbidden','supplied nonempty boot and PID refused')
else error('unknown fixture mode') end
print('native target '..mode..' ok')
