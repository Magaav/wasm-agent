-- The seam's model-facing bytes: one fixed task set, one canonical line per script - the RESULT the model
-- receives from the run tool, in the loop's own encoding. It runs on the component path with the real guest
-- (scripts/test-codemode-component.sh) and compares against fixtures/codemode-seam-bytes.jsonl, which was
-- RECORDED ON main 522e12ae with the native host rendering the channel: CODEMODE_SEAM_BYTES_RECORD=1
-- rewrites it, and nothing else does.
--
-- Two things it is and is not. It IS the byte-for-byte answer to "did any byte a model reads move?" - the
-- value, the items, the attempts, the refusals, the unexecuted calls, the sandbox's own reason. It is NOT a
-- look at the control channel's own shape: the loop reaches host.codemode through a reference this probe
-- cannot wrap, and a step's kind never reaches the model. That shape is held by the seam's own tests
-- (rust/wa-capabilities/src/codemode_seam/tests.rs), which assert every field of it.
local json=dofile('lua/vendor/json.lua')
local env=host.getenv
host.getenv=function(k) if k=='WASM_AGENT_CODEMODE' then return nil end return env(k) end
local memory=dofile('lua/core/memory.lua'); memory.setup()
local tools=dofile('lua/core/tools.lua')
local policy=dofile('lua/core/codemode_policy.lua')
local seam=host.codemode
local sid=memory.start_session('','codemode seam bytes',{user_id='master'})
local ctx={session_id=sid,user_id='master'}
policy.pin(memory,'master',ctx)
local function normalise(text)
  -- A retained original is named by its absolute path under this run's home; the home is the one thing
  -- that differs between the recording and this run, so it is the one thing folded away.
  text=text:gsub('([^"%s]*)/%.wasm%-agent/','/<home>/.wasm-agent/')
  text=text:gsub('/tmp/wa%-[%w%-]+','/<tmp>')
  -- elapsed_ms is the host's own measurement of the capability call, not the seam's answer.
  text=text:gsub('"elapsed_ms":%d+','"elapsed_ms":<n>')
  return text
end
local cases = {
  {'value',     'return 1'},
  {'console',   'console.log("hi"); text("there"); return 2'},
  {'tool',      'const r = await tools.capabilities({}); return {role:r.role, has_read:(r.capabilities || []).some(c => (c.name || c) === "read")}'},
  {'fenced',    'try { await tools.subagent({task:"x"}); return "NO"; } catch (e) { return String((e && e.message) || e) }'},
  {'discovery', 'const a = await searchTools("capabilities"); return a.map(t => ({name:t.name, callable:t.callable, route:t.route}))'},
  {'global',    'const p = await describeTool("showCall"); return {name:p.name, callable:p.callable}'},
  {'throw',     'throw new Error("golden boom")'},
  {'store',     'store("k1","v1"); vars.remembered = "yes"; return 3'},
  {'sleep',     'const s = await sleep(1); return s'},
  {'pending',   'const p = await pending(); return {kind:typeof p, n:(p.ops || []).length}'},
  {'listing',   'const all = await searchTools("*"); return all.map(t => t.name)'},
}
-- Unknown is not yes: a node without the component answers the same scripts through the native loop, and
-- native bytes are not what this row measures. The capability itself is asked once, opened and finished, so
-- a fallback is a named failure here instead of a green comparison of the wrong path.
local guard_ok, guard = pcall(seam, json.encode({op='open',session='bytes-guard',owner=string.rep('0',64),code='return 1'}))
local guard_answer = guard_ok and (type(guard)=='string' and json.decode(guard) or guard) or nil
if type(guard_answer)~='table' or guard_answer.ok~=true or guard_answer.session~='bytes-guard' then
  print('codemode seam bytes FAILED: the seam capability did not answer ('..tostring(guard)..')')
  os.exit(1)
end
pcall(seam, json.encode({op='finish',session='bytes-guard'}))

local produced={}
for _, case in ipairs(cases) do
  local ok, result = pcall(function() return tools.dispatch(memory,'codemode',{code=case[2]},'master',ctx) end)
  produced[#produced+1]='result '..case[1]..' '..normalise(ok and json.encode(result) or json.encode({threw=tostring(result)}))
end
local path='fixtures/codemode-seam-bytes.jsonl'
local recording=host.getenv and host.getenv('CODEMODE_SEAM_BYTES_RECORD') or nil
if recording=='1' then
  local out=assert(io.open(path,'w'))
  for _,line in ipairs(produced) do out:write(line.."\n") end
  out:close()
  print(('codemode seam bytes recorded (%d cases, %d lines)'):format(#cases,#produced))
  return
end
local expected={}
local file=assert(io.open(path,'r'),'missing fixture '..path)
for line in file:lines() do if line~='' then expected[#expected+1]=line end end
file:close()
if #expected~=#produced then
  print(('codemode seam bytes FAILED: %d lines recorded, %d produced'):format(#expected,#produced))
  os.exit(1)
end
local bad=0
for i,line in ipairs(produced) do
  if line~=expected[i] then
    bad=bad+1
    if bad<=3 then
      print(('codemode seam bytes FAILED on line %d:'):format(i))
      print('  recorded: '..expected[i]:sub(1,400))
      print('  produced: '..line:sub(1,400))
    end
  end
end
if bad>0 then print(('codemode seam bytes FAILED (%d of %d lines differ)'):format(bad,#expected)); os.exit(1) end
print(('codemode seam bytes ok (%d cases, %d lines byte-identical)'):format(#cases,#produced))
