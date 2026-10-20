-- The wave end's installation check.
--
-- A merged fix is not installed because it was merged. The only process that may replace this node is
-- the sentinel, and what it reads is its drop-box: `<config>/sentinel/requests/<id>.json` - the very
-- file `wa-sentinel request deploy` writes. So when a wave ends - the last child has settled and none
-- is running or queued - this module answers one question, "does this node already run origin/main?",
-- and when it does not, writes that one request file. It never installs, restarts, deploys or runs the
-- sentinel: the request is a question, the answer is `installed.txt` on a later turn, and the wave's
-- own report line says which of the two happened.
--
-- The order of the checks IS the safety property. An active wave, an unreadable install record, an
-- unreadable origin/main, a dirty build tree, an already pending request and a request already written
-- for this wave each end in "nothing was written", and each is named in the line rather than silently
-- doing nothing. The tree is checked before the write because a deploy builds the tree it is given:
-- a dirty one would install something nobody reviewed.
local json=dofile('lua/vendor/json.lua')
local output=dofile('lua/core/command_output.lua')
local M={}
M.NOT_NEEDED='deploy: not needed (installed == main)'
local function trim(v) return (tostring(v or ''):gsub('^%s+',''):gsub('%s+$','')) end
local function quote(v) v=tostring(v or '') return "'"..v:gsub("'","'\\''").."'" end
local function short(sha) return type(sha)=='string' and sha:sub(1,8) or '?' end
local function full_sha(v) return type(v)=='string' and #v==40 and not v:find('[^%x]') end

-- `installed.txt` records the commit two ways: a deploy's own `commit=` (which has been written short)
-- and the `source_commit_hint=`. `lua/core/update.lua` prefers the hint and so does this, so a
-- "not needed" answer never disagrees with `/update`'s view of the same file.
local function record_of(install)
  if type(install)~='string' or install=='' then return nil,'install_dir_unknown' end
  local raw=host.read_file(install..'/installed.txt')
  if not raw then return nil,'installed_record_missing' end
  local record={}
  for line in tostring(raw):gmatch('[^\r\n]+') do
    local key,value=line:match('^([^=]+)=(.*)$')
    if key then record[trim(key)]=trim(value) end
  end
  return record
end

-- The commit the install says it is running, or nil with the reason it cannot say.
function M.installed(install)
  local record,why=record_of(install)
  if not record then return nil,why end
  local commit=record.source_commit_hint
  if commit==nil or commit=='' then commit=record.commit end
  if commit==nil or commit=='' then return nil,'installed_commit_missing' end
  return commit
end

-- A short `commit=` still names one commit; compare as a prefix rather than refusing to recognise it.
-- Only a full 40-character answer is ever *asked for* here, and the shorter side must be long enough to
-- be an identity rather than a coincidence.
function M.same_commit(a,b)
  if type(a)~='string' or type(b)~='string' then return false end
  a,b=a:lower(),b:lower()
  if a==b then return true end
  local shorter,longer=(#a<= #b) and a or b,(#a<=#b) and b or a
  return #shorter>=7 and longer:sub(1,#shorter)==shorter
end

local function git(root,args)
  if type(root)~='string' or root=='' then return nil,'build_tree_unknown' end
  local result,why=output.run('git -C '..quote(root)..' '..args,root,120)
  if not result then return nil,'git_unavailable: '..tostring(why) end
  return result
end

-- The commit a deploy queued now would install: `origin/main` of the tree it builds from.
function M.target(main)
  local result,why=git(main,'rev-parse origin/main')
  if not result then return nil,why end
  if output.truncated(result) then return nil,output.TRUNCATED end
  local value=trim((output.preview(result):match('^[^\r\n]*') or ''))
  if result.code~=0 or not full_sha(value) then
    local said=trim(tostring(result.stderr or ''):gsub('[\r\n]+$',''))
    return nil,'origin_main_unreadable'..(said~='' and (': '..said) or '')
  end
  return value
end

-- Every dirty path, not a count and not a clipped view: the point of naming them is that whoever reads
-- the line can see what would have been installed.
function M.dirty(main)
  local result,why=git(main,'status --porcelain --untracked-files=all')
  if not result then return nil,why end
  local ok,text=pcall(output.complete,result,'wave source status')
  if not ok then return nil,output.TRUNCATED end
  local paths={}
  for line in tostring(text):gmatch('[^\r\n]+') do
    if not output.is_elision(line) then
      local path=trim(line:sub(4))
      if path~='' then paths[#paths+1]=path end
    end
  end
  return paths
end

-- The entries of a directory, or an empty list when it is not there. A listing that failed for another
-- reason is not an empty box, so it is reported rather than read as "nothing is pending".
local function entries(dir)
  local ok,raw=pcall(host.list_dir,dir)
  if not ok then return nil,tostring(raw) end
  local value=type(raw)=='string' and (function() local decoded,listing=pcall(json.decode,raw);return decoded and listing end)() or raw
  if type(value)~='table' then return nil,'listing_unreadable' end
  if value.error then
    -- "not there yet" is an empty box, not a failed read: the first wave on a fresh node sees it, and
    -- the sentinel creates the folder when it starts. Any other refusal is reported, never read as
    -- "nothing is pending" - that is how a second request would be written for a commit already queued.
    if host.path_kind and host.path_kind(dir)=='missing' then return {} end
    return nil,tostring(value.error)
  end
  return value.entries or value
end

local function sibling(requests_dir,name)
  return (tostring(requests_dir):gsub('[/\\][^/\\]*[/\\]?$',''))..'/'..name
end

-- Deploy requests already waiting, in the two folders a request spends its waiting life in, that name
-- this exact target. `expected_sha` and `target_commit` are the two ways a deploy request says which
-- commit it is for (protocol and legacy), and a second request for the same commit is one the sentinel
-- would perform twice.
function M.pending(requests_dir,target)
  local found={}
  for _,folder in ipairs({requests_dir,sibling(requests_dir,'claimed')}) do
    local list,why=entries(folder)
    if not list then return nil,why end
    for _,entry in ipairs(list) do
      local name=type(entry)=='table' and tostring(entry.name or '') or tostring(entry)
      if name:sub(-5)=='.json' then
        local raw=host.read_file(folder..'/'..name)
        local ok,request=pcall(json.decode,raw or '')
        if ok and type(request)=='table' and request.verb=='deploy' then
          local named=request.target_commit or request.expected_sha
          if M.same_commit(named,target) then
            found[#found+1]={id=name:gsub('%.json$',''),path=folder..'/'..name,target=named}
          end
        end
      end
    end
  end
  return found
end

-- The request file itself: the same fields `wa-sentinel request deploy --reason ...` writes, written
-- through `host.write_file` (temp, fsync, rename) so the watcher never reads a half-written one. No
-- `session` and no `prompt`: nobody is woken for this, because the install is owed to every turn that
-- runs after it, not to one conversation that asked.
function M.write(requests_dir,target,installed,now)
  now=now or host.now()
  local id=string.format('%d-%s',math.floor(now),host.uuid())
  local request={verb='deploy',
    reason='wave end: installed '..short(installed)..' is not origin/main '..short(target),
    queued_at=math.floor(now),target_commit=target}
  local path=tostring(requests_dir):gsub('[/\\]+$','')..'/'..id..'.json'
  local text=json.encode(request)..'\n'
  if not host.write_file(path,text) then return nil,'deploy_request_write_failed' end
  local back=host.read_file(path)
  if not back then return nil,'deploy_request_write_unverified' end
  if host.sha256(back)~=host.sha256(text) then return nil,'deploy_request_write_changed' end
  local ok,decoded=pcall(json.decode,back)
  if not ok or type(decoded)~='table' or decoded.verb~='deploy' or not M.same_commit(decoded.target_commit,target)
      or type(decoded.queued_at)~='number' then
    return nil,'deploy_request_unreadable'
  end
  return {id=id,path=path,text=text,sha256=host.sha256(text),request=request}
end

local function outcome(state,reason,detail)
  local out={state=state}
  assert(state~='skipped' or type(reason)=='string','wave_deploy_reason_required')
  if reason then out.reason=reason..(detail and (': '..detail) or '') end
  if state=='skipped' then out.line='deploy: skipped ('..out.reason..')'
  elseif state=='not_needed' then out.line=M.NOT_NEEDED end
  return out
end

local function lines(paths)
  local shown={}
  for index,path in ipairs(paths) do
    if index>8 then shown[#shown+1]='and '..(#paths-8)..' more';break end
    shown[#shown+1]=path
  end
  return table.concat(shown,', ')
end

-- Decide and, at most once per wave and per target, write the request.
--
-- `input` is gathered by the caller: `active` is the wave's own count of running or queued children,
-- `wave` is the wave id this decision belongs to, `install` holds `installed.txt`, `main` is the
-- canonical checkout a deploy builds from, and `requests` is the sentinel's drop-box. `state` is the
-- durable per-wave record the caller already owns, so running this twice in one wave cannot write two
-- requests - and a crash between the write and the save is still caught, by the pending scan.
function M.ensure(input)
  local state=input.state or {}
  local out
  -- Nothing may deploy mid-wave. The next finalize decides, and this one says why it did nothing.
  if (input.active or 0)>0 then
    out=outcome('skipped','wave active');out.active=input.active
    out.record=state
    return out
  end
  local installed,why=M.installed(input.install)
  if not installed then
    out=outcome('skipped','install record unreadable',why);out.record=state;return out
  end
  local target,why_target=M.target(input.main)
  if not target then
    out=outcome('skipped','origin/main unreadable',why_target);out.installed=installed;out.record=state;return out
  end
  if M.same_commit(installed,target) then
    out=outcome('not_needed');out.installed,out.target=installed,target;out.record=state
    return out
  end
  local paths,why_dirty=M.dirty(input.main)
  if not paths then
    out=outcome('skipped','source status unreadable',why_dirty);out.record=state;return out
  end
  if #paths>0 then
    out=outcome('skipped','source dirty',lines(paths));out.paths=paths;out.record=state
    return out
  end
  -- One request per wave id, even if the wave's end is finalized twice.
  if input.wave~=nil and state.wave==input.wave and state.request then
    out=outcome('skipped','already requested this wave',short(state.target or target))
    out.request=state.request;out.record=state
    return out
  end
  local pending,why_pending=M.pending(input.requests,target)
  if not pending then
    out=outcome('skipped','request queue unreadable',why_pending);out.record=state;return out
  end
  if #pending>0 then
    out=outcome('skipped','already pending',short(target));out.request=pending[1].id
    out.pending=#pending;out.record=state
    return out
  end
  local written,why_write=M.write(input.requests,target,installed,input.now)
  if not written then
    out=outcome('skipped','request not written',why_write);out.record=state;return out
  end
  state.wave=input.wave;state.target=target;state.installed=installed
  state.request=written.id;state.path=written.path;state.request_sha256=written.sha256
  state.at=written.request.queued_at
  out={state='queued',target=target,installed=installed,request=written.id,path=written.path,
    line='deploy: queued '..short(target),record=state}
  return out
end

-- The one line a wave's report carries about the install.
function M.line(value)
  return type(value)=='table' and value.line or nil
end

return M
