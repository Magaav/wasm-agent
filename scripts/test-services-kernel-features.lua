-- Kernel features from docs/KERNEL.md ("Lessons taken from DeepSeek Harness"), the decision layer:
-- start by imports (`supervise`), profiles as layers (`profile_dump`), per-component limits, the
-- registration ledger, and the `services` tool's new admin cues.
--
-- Self-contained: nothing here needs an installed component, a node or the network. What it asserts is
-- the layer that decides - which definition waits for which interface, what the effective
-- configuration is, what a component is allowed to spend - and the transactional upgrade's refusals,
-- which are all refusals *before* anything runs. The installed-artifact half (a real candidate
-- started beside a real old instance) is `cargo test -p wa-kernel-runtime install`, because it needs
-- bytes and a process.
local json=dofile('lua/vendor/json.lua')
local services=dofile('lua/core/services.lua')
local tools=dofile('lua/core/tools.lua')
local checks=0
local function check(value,label)checks=checks+1;if not value then error('KERNEL FEATURE CHECK FAILED: '..label)end end
local function decode(raw)local ok,v=pcall(json.decode,tostring(raw or ''));if ok and type(v)=='table' then return v end end
local master={role='master'}
local function host_action(request)return decode(host.service(json.encode(request))) or {} end
local function encodes(value)return json.encode(value)end

-- A host without the service capability (a minimal build) reports a skip rather than failing.
if not host.service then print('kernel feature checks: skipped (no host.service in this build)');return end

-- The registry's own store (lua/core/services.lua keeps one meta row).
assert(json.decode(host.sql_exec('CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL)','[]')).ok)

-- 1. Start by imports. A definition whose component is not installed is not an error and not a start:
--    it waits, and the answer names the reason (nothing to read imports from) rather than inventing an
--    interface. Config order cannot even be observed here, because there is no order to observe: the
--    supervisor plans from the artifacts.
local supervised=host_action({action='supervise',definitions={{name='kernel-feature-absent'}}})
check(supervised.ok==true,'supervise answers ok when a definition simply waits: '..encodes(supervised))
check(next(supervised.started or {})==nil,'nothing started for a component that is not installed')
check(#(supervised.waiting or {})==1,'one definition waits: '..encodes(supervised))
check(supervised.waiting[1].name=='kernel-feature-absent','the waiting entry names the definition')
check(supervised.waiting[1].reason=='not_installed','and says it is not installed, not that an interface is missing')
check(type(supervised.waiting[1].waiting_for)=='table' and #supervised.waiting[1].waiting_for==0,'with no interface invented')

-- 2. `status` answers "why is this not running" with the wait, not with `not_running`.
local waiting_status=host_action({action='status',name='kernel-feature-absent'})
check(waiting_status.state=='waiting','a supervised definition that waits is not reported as not_running: '..encodes(waiting_status))
check(waiting_status.waiting_reason=='not_installed','and carries the reason')
-- A name nobody supervises keeps the old answer.
check(host_action({action='status',name='kernel-feature-nobody'}).state=='not_running','an unsupervised name is still not_running')

-- 3. Profiles as layers: base -> node -> user -> patch, rows by id, and the effective result printed.
local dumped=host_action({action='profile_dump'})
check(dumped.ok==true,'profile_dump answers')
check(#dumped.order==4 and dumped.order[1]=='base' and dumped.order[4]=='patch','the layer order is the contract: '..encodes(dumped.order))
check(type(dumped.effective.rows)=='table','the effective rows are the answer, by id')
check(type(dumped.effective.rows.default)=='table','the base layer ships a default row')
check(type(dumped.effective.layers)=='table' and #dumped.effective.layers>=1,'and which layers existed is visible')
local named=host_action({action='profile_dump',name='kernel-feature-absent'})
check(named.component=='kernel-feature-absent','profile_dump with a name answers for that component')
check(type(named.config)=='table' and type(named.limits)=='table','with the config it would start with and its limits')
check(named.config.limits==nil,'limits belong to the kernel, not to guest configuration')

-- 4. Per-component limits: declared in the manifest, capped by the node, and readable.
local limits=host_action({action='limits'})
check(type(limits.node)=='table','the node caps are readable')
check(type(limits.node.memory_mb)=='number' and limits.node.memory_mb>=16 and limits.node.memory_mb<=4096,'memory_mb is inside the enforced range')
check(type(limits.node.cpu_ms)=='number' and limits.node.cpu_ms>=10,'cpu_ms is a real budget, not zero')
check(limits.node.source~=nil,'and the answer says where the cap came from')

-- 5. Revocable registrations: the ledger is readable (counts by kind, never a payload).
local ledger=host_action({action='registrations'})
check(type(ledger.total)=='number','the registration ledger answers with a total')
check(type(ledger.kinds)=='table' and ledger.kinds.bus_subscription~=nil,'and counts per kind')

-- 6. The transactional upgrade refuses before anything is installed, and says which stage.
local missing=host_action({action='upgrade',name='kernel-feature-absent'})
check(missing.ok==false and missing.error=='upgrade_source_required','an upgrade with no source is refused')
-- An empty Lua table encodes as `[]`, so this arrives as "no source object" rather than "no wasm": both
-- are the same refusal to the operator (nothing to install), and both are refused before any stage.
local empty=host_action({action='upgrade',name='kernel-feature-absent',source={}})
check(empty.error=='upgrade_source_wasm_required' or empty.error=='upgrade_source_required','a source with no artifact is refused: '..tostring(empty.error))
local absent=host_action({action='upgrade',name='kernel-feature-absent',source={wasm='/nonexistent/x.wasm'}})
check(tostring(absent.error):match('^upgrade_source_unreadable')~=nil,'an unreadable artifact is refused by name: '..tostring(absent.error))
check(absent.mode=='install','and the answer says whether it would have been an install or an upgrade')

-- 7. The `services` tool's admin cues, through the registry (master only, never a child agent).
local profile=services.control({action='profile_dump'},master)
check(profile.ok==true,'services: profile_dump is master-readable')
check(services.control({action='profile_dump'},{role='guest'}).error=='forbidden','profile_dump is forbidden to a guest')
check(services.control({action='profile_dump'},{role='master',subagent={}}).error=='services_management_forbidden_for_subagent','and to a child agent')
check(services.control({action='upgrade',name='kernel-feature-absent',source={}},master).error=='service_unknown','upgrade names a definition this node does not have')
local names={};for _,entry in ipairs(tools.admin)do names[entry['function'].name]=true end
check(names.services,'services is an admin tool')
local schema
for _,entry in ipairs(tools.admin)do if entry['function'].name=='services' then schema=entry['function'].parameters.properties.action end end
local enum={};for _,action in ipairs(schema.enum)do enum[action]=true end
check(enum.upgrade and enum.profile_dump,'the tool schema offers the new actions')

-- 8. Boot is start-by-imports: an enabled definition whose component is not installed makes autostart
--    report a wait, not a failure (the old loop would have tried and errored).
local revision=services.inventory().revision
local stored=services.control({action='put',expected_revision=revision,definition={name='kernel-feature-absent'}},master)
if stored.ok then
 local rows=decode(host.sql_query('SELECT value FROM meta WHERE key=?',encodes({'services.v1'})))
 local state=decode(rows[1].value)
 state.services['kernel-feature-absent'].enabled=true
 host.sql_exec('UPDATE meta SET value=? WHERE key=?',encodes({encodes(state),'services.v1'}))
 local boot=services.autostart()
 check(boot.ok==true,'autostart with an enabled but uninstalled definition is not a failure: '..encodes(boot))
 check(#(boot.waiting or {})==1 and boot.waiting[1].name=='kernel-feature-absent','it waits, and names what it waits on')
 check(next(boot.started or {})==nil,'and starts nothing it cannot start')
else
 print('kernel features: enabled-definition boot check skipped ('..tostring(stored.error)..')')
end

print('kernel feature checks: '..checks)
