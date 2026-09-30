-- Reviewer probe (did not author the delivery).  Offline; no network, no spend.
-- Q: with WASM_AGENT_LUA_ROOT *unset*, which module does the wire load, and what does the
--    credential seam's second return value actually reach?
local function say(k, v) print(k .. ': ' .. tostring(v)) end

say('lua root (getenv)', tostring(host.getenv('WASM_AGENT_LUA_ROOT')))
say('store path in force', tostring(host.getenv('WASM_AGENT_OPENAI_SUB_STORE')))

local ok_wire, wire = pcall(dofile, 'lua/core/subscription_wire.lua')
say('wire dofile ok', ok_wire)
if not ok_wire then say('wire error', tostring(wire)) os.exit(1) end

local name = wire.CREDENTIAL_MODULE
say('wire.CREDENTIAL_MODULE', tostring(name))
say('wire source sha256 (LOADED_SOURCES)', tostring(LOADED_SOURCES['lua/core/subscription_wire.lua']))

local ok_cred, cred = pcall(dofile, name)
say('dofile(CREDENTIAL_MODULE) ok', ok_cred)
say('credential is table', type(cred))
say('credential.token is function', type(cred) == 'table' and type(cred.token) or 'n/a')
say('credential source sha256 (LOADED_SOURCES)', tostring(LOADED_SOURCES[name]))

-- negative control: the pass above must not be "dofile always answers"
local ok_neg, neg = pcall(dofile, 'lua/core/definitely-not-registered.lua')
say('negative control ok (must be false)', ok_neg)
say('negative control error', tostring(neg))

-- seam, two return values, store pointed at a path that does not exist
local v, f = wire.credential()
say('credential() first value type', type(v))
say('credential() second value code', type(f) == 'table' and tostring(f.code) or tostring(f))
say('credential() second value sentence', tostring(f))

-- limits(): first value must stay {} (display data), second must carry the taxonomy
local l1, l2 = wire.limits()
say('limits() first value is empty table', type(l1) == 'table' and next(l1) == nil)
say('limits() second value', tostring(l2))

-- complete(): the code must be FIRST in the raised text, with no `file:line:` prefix
local ok_c, err = pcall(wire.complete, 'gpt-6-luna', {}, nil, false, {})
say('complete(known model, no credential) ok', ok_c)
say('complete(known model, no credential) error', tostring(err))
os.exit(0)
