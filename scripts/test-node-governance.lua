-- Node governance surfaces (docs/GRANT-POLICY.md, docs/TELEMETRY.md): the two read-only capabilities
-- the host now answers from the libraries it enforces, and the bounded stores those write into. No
-- component runs here, so this is the surfaces and their wiring, not the enforcement paths (those are
-- unit-tested in rust/wa-host/src/node_policy.rs and service_components.rs).
--
-- Two cases, because a policy file's PRESENCE is what turns the policy layer on and one process can
-- only load it once (`scripts/test.sh` runs each case in its own scratch home):
--   WA_GOVERNANCE_CASE=manifest -> no policy file in this home: manifest mode (loaded=false, mode,
--                                  decisions counted as manifest_mode, nothing refused)
--   anything else (default)     -> this file writes the policy file, then asks: policy mode
local json=dofile('lua/vendor/json.lua')
local checks=0
local function check(value,label)if not value then error('GOVERNANCE CHECK FAILED: '..label)end;checks=checks+1 end

check(type(host.policy_status)=='function','host.policy_status is a registered capability')
check(type(host.telemetry)=='function','host.telemetry is a registered capability')
local paths=host.paths()
check(type(paths.config)=='string' and paths.config~='','host.paths() names the config directory')

local policy_path=paths.config..'/policy.json'
local case=os.getenv('WA_GOVERNANCE_CASE') or 'policy'

if case=='manifest' then
  -- The upgrade rule: a node with no policy file keeps the behaviour it had before the policy layer
  -- existed - the manifest grant is the only gate - and says so (mode) instead of failing shut.
  check(host.path_kind(policy_path)=='missing','the manifest case is given a home with no policy file')
  local manifest=json.decode(host.policy_status())
  check(type(manifest)=='table','policy status is JSON')
  check(manifest.mode=='manifest','no policy file reports mode=manifest ('..tostring(manifest.mode)..')')
  check(manifest.loaded==false,'manifest mode is not a loaded policy')
  check(manifest.policy.error==nil,'an absent policy file is not an error')
  check(manifest.policy.components==0 and manifest.policy.rules==0,'no component or rule is counted')
  check(manifest.decisions.checks==0 and manifest.decisions.deny==0,'no call has been decided yet')
  check(manifest.decisions.manifest_mode==0,'no decision has come from manifest mode yet')
  check(type(manifest.audit)=='table' and type(manifest.audit.file.path)=='string',
    'the audit trail still names its file in manifest mode')
  local whole=json.decode(host.telemetry(''))
  check(type(whole.policy)=='table' and whole.policy.mode=='manifest','the telemetry summary carries the mode')
  print('node governance ok: '..checks..' checks (manifest mode)')
  return
end

-- The policy case: the policy is loaded once per node, on the first question about it, so the file has
-- to exist before that question - which is exactly the order a node lives in (operator writes it, then
-- starts wa).
local wrote=host.write_file(policy_path,json.encode({
  version=1,
  components={['wa-whatsapp']={capabilities={
    ['whatsapp.send']={sensitive=true,allow={'chat:self'},rate={per_minute=20},per_target={per_minute=6}},
  }}},
}))
check(wrote==true,'the fixture policy file is written')

local status=json.decode(host.policy_status())
check(type(status)=='table','policy status is JSON')
check(status.mode=='policy','a policy file that parses reports mode=policy ('..tostring(status.mode)..')')
check(status.loaded==true,'a policy file that parses is reported as loaded')
check(status.policy.error==nil,'a policy file that parses is not an error')
check(status.policy.components==1 and status.policy.rules==1,'the rule is counted ('..tostring(status.policy.rules)..')')
check(status.decisions.checks==0 and status.decisions.deny==0,'no call has been decided yet')
check(status.decisions.manifest_mode==0,'a loaded policy decides nothing in manifest mode')
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
check(whole.policy.mode=='policy','the summary carries the mode ('..tostring(whole.policy.mode)..')')
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
