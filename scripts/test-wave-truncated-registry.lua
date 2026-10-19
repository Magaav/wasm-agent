-- The measured failure, as a fixture: a repository carrying enough worktrees that
-- `git worktree list --porcelain` does not fit the host's bounded exec view.
--
-- The guard that used to fail read canonical main from the FIRST line of that listing. This script
-- asserts, on one real repository:
--   1. canonical main still resolves, and resolves to the primary checkout, through the shared
--      `lua/core/git_repository.lua` helper both guards now use;
--   2. the exec view of that listing really is clipped, and the clipping is visible in the text;
--   3. the removed first-line parse fails on exactly what the host used to hand back (pure tail of
--      the same listing) - the causal negative control;
--   4. a clipped INPUT refuses with `output_truncated_requires_bounded_command`, never with a
--      repository-blaming `canonical_main_missing`/`canonical_main_unavailable`;
--   5. a changeset that does not fit the view is still measured whole, so the shipped-path verdict
--      cannot silently lose the path that makes it `required`.
local json=dofile('lua/vendor/json.lua')
local memory=dofile('lua/core/memory.lua');memory.setup()
local platform=dofile('lua/core/platform.lua')
local command_output=dofile('lua/core/command_output.lua')
local git_repository=dofile('lua/core/git_repository.lua')
local wave=dofile('lua/core/wave_autoflush.lua')
local checks=0
local function check(value,label) assert(value,label);checks=checks+1 end
local function q(value) return "'"..tostring(value):gsub("'","'\\''").."'" end
local function normalize(value)
  local text=tostring(value or ''):gsub('\\','/'):gsub('/+$','')
  return platform.os()=='windows' and text:lower() or text
end
local main=assert(host.getenv('WA_FIXTURE_MAIN'),'fixture repository required')
local tip=assert(host.getenv('WA_FIXTURE_TIP'),'fixture tip required')
local base=assert(host.getenv('WA_FIXTURE_BASE'),'fixture base required')

-- 1. Canonical main, from the bounded fact. This is the guard both modules run.
local identity=git_repository.identity(main)
check(normalize(identity.main)==normalize(main),'canonical main resolves to the primary checkout: '..tostring(identity.main))
check(git_repository.branch(identity.main)=='main','the resolved canonical main worktree is on main')
check(identity.common~='' and identity.key~='','the repository identity carries its common git dir')

-- 2. The listing that caused this really is clipped, and the clipping is visible.
local listing=assert(command_output.run('git -C '..q(main)..' worktree list --porcelain',main,120),'the worktree listing ran')
check(command_output.truncated(listing),'the fixture listing is clipped by the bounded exec view')
local preview=command_output.preview(listing)
check(preview:find('bytes elided by the host',1,true)~=nil,'the clipping is visible in the text itself')
check(preview:match('^worktree%s')~=nil,'the bounded view keeps the first line')
local complete=command_output.complete(listing,'git worktree list --porcelain')
check(#complete>24*1024,'the complete listing is larger than the 24 KiB view: '..#complete..' bytes')

-- 3. Causal negative control: the same listing, as the host used to return it (a pure 24 KiB
-- tail), cannot answer the canonical-main question the guards were removed from. The tail starts
-- mid-line, so its first whole `worktree ` line is either absent or some other worktree - never the
-- primary checkout, which is the listing's first line and therefore the first thing the old view
-- dropped.
local old_view=complete:sub(-(24*1024))
local old_first=old_view:match('^worktree%s+([^\r\n]+)')
check(old_first==nil or normalize(old_first)~=normalize(identity.main),'the old tail-only view cannot name the canonical main worktree: '..tostring(old_first))
check(complete:sub(1,#('worktree '))=='worktree ','the primary checkout is the complete listing first line')
check(old_view:sub(1,#('worktree '))~='worktree ','the old view does not start at the listing first line')

-- 4. A clipped input refuses by name. A one-line `rev-parse` cannot clip in reality, so the
-- clipping is simulated exactly as the host would report it, including an unreadable original.
local function with_exec(replacement,body)
  local native=host.exec
  host.exec=replacement(native)
  local ok,err=pcall(body)
  host.exec=native
  assert(ok,err)
end
local function clipped() return json.encode({code=0,ok=true,stdout='',output_truncated=true,stdout_truncated=true,stdout_path='/nonexistent/wa-fixture-stdout'}) end
with_exec(function(native) return function(command,cwd,seconds)
  if tostring(command):find('--git-common-dir',1,true) then return clipped() end
  return native(command,cwd,seconds)
end end,function()
  local ok,err=pcall(git_repository.identity,main)
  check(not ok,'a clipped repository fact is refused')
  check(tostring(err):find(command_output.TRUNCATED,1,true)~=nil,'the refusal names the truncation: '..tostring(err))
  check(tostring(err):find('canonical_main',1,true)==nil,'the refusal never blames canonical main')
end)

-- 5. The impact measurement on the real clipped changeset, and its refusal when the whole path
-- set cannot be read at all.
local sid=memory.start_session('','subagent',{id='truncation-fixture',user_id='master'})
local ctx={user_id='master',session_id=sid,run_id='truncation-fixture'}
local diff=assert(command_output.run('git -C '..q(main)..' diff --name-only -z '..base..' '..tip,main,120),'the path set ran')
check(command_output.truncated(diff),'the fixture changeset does not fit the bounded exec view either')
local measured=wave.capture(memory,ctx,main,tip,base)
check(measured.error==nil,'a clipped path set is still measured whole: '..tostring(measured.error))
check(measured.verdict=='required','the shipped path inside a clipped path set is still seen: '..tostring(measured.verdict))
check(#measured.shipped==1 and measured.shipped[1]=='lua/core/marker.lua','the shipped path is named exactly: '..json.encode(measured.shipped))
with_exec(function(native) return function(command,cwd,seconds)
  if tostring(command):find('diff --name-only -z',1,true) then return clipped() end
  return native(command,cwd,seconds)
end end,function()
  local refused=wave.capture(memory,{user_id='master',session_id=sid,run_id='clipped-path-set'},main,tip,base)
  check(refused.verdict=='unknown','an unreadable path set cannot produce a verdict')
  check(tostring(refused.error):find(command_output.TRUNCATED,1,true)~=nil,'the impact refusal names the truncation: '..tostring(refused.error))
end)
-- 6. A clipped listing read as a COUNT is a lower bound, and the elision marker is not a line of
-- command output: the status health line must say "at least" instead of a number that looks measured.
local status=dofile('lua/core/status.lua')
with_exec(function() return function()
  return json.encode({code=0,ok=true,output_truncated=true,stdout=' M one.lua\n M two.lua\n[3 bytes elided by the host: x]\n'})
end end,function()
  local line=status.working_tree()
  check(line=='at least 2 changed','a clipped status listing is a lower bound, not a count: '..tostring(line))
end)
print(json.encode({ok=true,checks=checks,skipped=0,listing_bytes=#complete,view_bytes=#preview}))