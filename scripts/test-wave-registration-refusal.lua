-- Item 4 of the harness-fixes mission (18/11): a repository with no wave registration refuses with the
-- reason AND the one command that fixes it, and a top-level operator session on such a node works in
-- place instead of being refused.
--
-- Measured on avell: every session in the checkout or its worktrees was refused
-- `workspace_wave_admission_refused:wave_registration_required`, with no way out but moving files by hand.
local json=dofile('lua/vendor/json.lua')
local workspaces=dofile('lua/core/workspaces.lua')
local checks=0
local function check(v,label) assert(v,label);checks=checks+1 end

-- 1. the absent-authority refusal carries the command ------------------------------------------------
local denied=workspaces.wave_admission_outcome('wave_registration_required',{operator_session=false})
check(denied.ok==false,'ITEM 4: a child session is still refused when the repository has no registration')
check(tostring(denied.message):find('workspace_wave_admission_refused:wave_registration_required',1,true)~=nil,
  'ITEM 4: the reason is named verbatim: '..tostring(denied.message))
check(tostring(denied.message):find('node scripts/wave-entry.mjs register <repo> <wave-config.json> <attestation.json>',1,true)~=nil,
  'ITEM 4: and the one command that fixes it: '..tostring(denied.message))

-- 2. a top-level operator session works in place -----------------------------------------------------
local admitted=workspaces.wave_admission_outcome('wave_registration_required',{operator_session=true})
check(admitted.ok==true and admitted.in_place==true,
  'ITEM 4: the operator session on a node with no wave authority is admitted in place')
check(tostring(admitted.note):find('node scripts/wave-entry.mjs register',1,true)~=nil,
  'ITEM 4: and the registration is still named, so the node can be given an owner: '..tostring(admitted.note))

-- 3. a refusal that registration cannot fix stays a refusal, without the command ---------------------
local frozen=workspaces.wave_admission_outcome('wave_closing_frozen',{operator_session=true})
check(frozen.ok==false,'ITEM 4: a closing freeze is not waived for an operator session')
check(tostring(frozen.message):find('wave_closing_frozen',1,true)~=nil
  and tostring(frozen.message):find('wave-entry.mjs register',1,true)==nil,
  'ITEM 4: an unrelated refusal keeps its own reason and offers no registration: '..tostring(frozen.message))

-- 4. one implementation: ensure() decides through this function, not with its own string ----------------
local source=host.read_file(dofile('lua/core/paths.lua').data()=='' and 'lua/core/workspaces.lua' or 'lua/core/workspaces.lua')
check(source~=nil,'ITEM 4: the module source is readable')
local uses=select(2,source:gsub('wave_admission_outcome%(',   ''))
check(uses==3,'ITEM 4: both admission sites and the definition use the one verdict (found '..tostring(uses)..')')
check(source:find("'workspace_wave_admission_refused:'..tostring",1,true)==nil,
  'ITEM 4: no site builds its own refusal sentence any more')

-- 5. the registration is documented where an operator looks -------------------------------------------
local docs=host.read_file('docs/WAVE-CONVERGENCE.md')
check(docs~=nil and docs:find('wave-entry.mjs register',1,true)~=nil,'ITEM 4: docs/WAVE-CONVERGENCE.md documents the registration')
check(docs~=nil and docs:find('absent_operator_in_place',1,true)~=nil,
  'ITEM 4: and what a session does on a node that has none')

print(json.encode({ok=true,checks=checks}))