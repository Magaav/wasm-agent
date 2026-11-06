-- Node governance surfaces (docs/GRANT-POLICY.md, docs/TELEMETRY.md): the two read-only capabilities
-- the host now answers from the libraries it enforces, and the bounded stores those write into. No
-- component runs here, so this is the surfaces and their wiring, not the enforcement paths (those are
-- unit-tested in rust/wa-host/src/node_policy.rs and service_components.rs).
local json=dofile('lua/vendor/json.lua')
local checks=0
local function check(value,label)if not value then error('GOVERNANCE CHECK FAILED: '..label)end;checks=checks+1 end

check(type(host.policy_status)=='function','host.policy_status is a registered capability')
check(type(host.telemetry)=='function','host.telemetry is a registered capability')
local paths=host.paths()
check(type(paths.config)=='string' and paths.config~='','host.paths() names the config directory')

-- The policy is loaded once per node, on the first question about it, so the file has to exist before
-- that question - which is exactly the order a node lives in (operator writes it, then starts wa).
local policy_path=paths.config..'/policy.json'
local wrote=host.write_file(policy_path,json.encode({
  version=1,
  components={['wa-whatsapp']={capabilities={
    ['whatsapp.send']={sensitive=true,allow={'chat:self'},rate={per_minute=20},per_target={per_minute=6}},
  }}},
}))
check(wrote==true,'the fixture policy file is written')

local status=json.decode(host.policy_status())
check(type(status)=='table','policy status is JSON')
check(status.loaded==true,'a policy file that parses is reported as loaded')
check(status.policy.error==nil,'a policy file that parses is not an error')
check(status.policy.components==1 and status.policy.rules==1,'the rule is counted ('..tostring(status.policy.rules)..')')
check(status.decisions.checks==0 and status.decisions.deny==0,'no call has been decided yet')
check(type(status.recent_refusals)=='table' and #status.recent_refusals==0,'no refusals yet')
check(type(status.state)=='table' and status.state.capability_buckets==0,'budgets start empty')
check(type(status.audit)=='table' and type(status.audit.file.path)=='string','the audit trail names its file')
check(status.audit.file.path:find('/audit/',1,true)~=nil or status.audit.file.path:find('\\audit\\',1,true)~=nil,
  'the audit trail lives in the audit directory: '..tostring(status.audit.file.path))
check(status.audit.file.written==0 and status.audit.file.rotations==0,'nothing audited yet, nothing rotated')
check(status.audit.error==nil,'the audit trail opened')
check(host.path_kind(paths.config..'/audit')=='dir','the bounded audit directory exists')

-- The telemetry capability: every format is text, and the JSON form carries the bounded stores and a
-- compact policy summary, so an operator reads one document instead of three.
local whole=json.decode(host.telemetry(''))
check(type(whole)=='table','the default format is JSON')
check(type(whole.stats)=='table' and whole.stats.components==0,'an idle process has no component series')
check(type(whole.store)=='table' and type(whole.store.quotas)=='table','the store report travels with it')
check(whole.store.quotas.service_log_bytes==52428800,'a service log is capped at 50 MiB per component')
check(whole.store.quotas.audit_bytes==33554432,'the audit directory is capped at 32 MiB')
check(whole.store.quotas.telemetry_bytes==268435456,'the telemetry directory is capped at 256 MiB')
check(whole.store.quotas.replay_bytes==524288000,'the replay directory is capped at 500 MiB')
check(whole.store.quotas.replay_max_age_secs==604800,'a replay expires after 7 days')
check(whole.policy.loaded==true and whole.policy.decisions.checks==0,'the policy summary is in the same document')
check(type(whole.snapshot)=="table" and type(whole.snapshot.path)=='string','the snapshot path is named')

local stats=json.decode(host.telemetry('stats'))
check(type(stats)=='table' and type(stats.stats)=='table' and type(stats.store)=='table','stats carries the store report')
local store=json.decode(host.telemetry('store'))
check(type(store)=='table' and store.threshold_pct==80,'the store report keeps the 80% alert line')
check(json.decode(host.telemetry('rollups'))~=nil,'rollups answer is JSON')
check(json.decode(host.telemetry('traces'))~=nil,'traces answer is JSON')
check(type(host.telemetry('prometheus'))=='string','prometheus answers text')

-- A request the host does not know is answered with the whole picture, not with an error: a typo must
-- not read as "no telemetry".
local unknown=json.decode(host.telemetry('nonsense'))
check(type(unknown)=='table' and type(unknown.stats)=='table','an unknown format falls back to the JSON picture')

print('node governance ok: '..checks..' checks')
