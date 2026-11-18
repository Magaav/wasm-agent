-- MCP extension registry/policy. Platform execution stays in host.operation.
local json=dofile('lua/vendor/json.lua')
local paths=dofile('lua/core/paths.lua')
local platform=dofile('lua/core/platform.lua')
local read_sessions=dofile('lua/core/mcp_session.lua')
local M={KEY='mcp.extensions.v1'}
local function fail(error,extra)local result=extra or {};result.ok=false;result.error=error;return result end
local function decode(raw)local ok,value=pcall(json.decode,tostring(raw or ''));if not ok or type(value)~='table' then return nil end;return value end
local function query(sql,params)local value=decode(host.sql_query(sql,json.encode(params or {})));if not value or value.error then error(value and value.error or 'mcp_store_unreadable') end;return value end
local function exec(sql,params)local value=decode(host.sql_exec(sql,json.encode(params or {})));if not value or value.error or value.ok~=true then error(value and value.error or 'mcp_store_write_unverified') end;return value end
local function load_store()
 local rows=query('SELECT value FROM meta WHERE key=?',{M.KEY});local raw=rows[1] and rows[1].value
 if not raw then return {schema=1,revision=0,servers={}},nil end
 local value=decode(raw);if not value or value.schema~=1 or type(value.servers)~='table' or type(value.revision)~='number' then error('mcp_store_corrupt') end
 return value,raw
end
local function mutate(expected,change)
 local ok,value=pcall(function()
  local current,raw=load_store();if raw~=expected then return fail('mcp_store_changed') end
  local result=change(current);if result.error then return result end
  current.revision=current.revision+1;local encoded=json.encode(current);local saved
  -- One native atomic CAS statement. No Lua-spanning transaction on the
  -- shared connection: another worker must never join our BEGIN/COMMIT.
  if expected==nil then saved=exec('INSERT OR IGNORE INTO meta(key,value) VALUES(?,?)',{M.KEY,encoded})
  else saved=exec('UPDATE meta SET value=? WHERE key=? AND value=?',{encoded,M.KEY,expected}) end
  if saved.changes~=1 then return fail('mcp_store_changed') end
  return result
 end)
 if not ok then return fail(tostring(value)) end;return value
end
local function absolute(value)return type(value)=='string' and (value:sub(1,1)=='/' or value:match('^%a:[/\\]')) end
-- Where the MCP runtime (`mcp-*.mjs`, `web-*.mjs`) lives on disk. The Lua core is embedded in the
-- binary; these files are not. A node that cannot name their directory answers every MCP tool with
-- `mcp_script_directory_unbound` (and `web_adapter_not_installed` from the web facade), which is what a
-- fresh install did: the installer shipped `upgrade.sh` and nothing else.
--
-- Order: the explicit override, the checkout root used in development, the install directory, then the
-- node's own data directory. The last one needs no environment variable and no install layout - the host
-- always reports it - so a new node, or a node in a brand-new cluster, finds the runtime without being
-- told where it is.
local function script_candidates()
 local list={}
 local function add(dir)if type(dir)=='string' and dir~='' and absolute(dir) then list[#list+1]=dir end end
 add(host.getenv('WA_MCP_SCRIPT_DIR'))
 local root=host.getenv('WASM_AGENT_LUA_ROOT');if root and root~='' then add(root..'/scripts') end
 local install=host.getenv('WA_INSTALL_DIR');if install and install~='' then add(install..'/scripts') end
 -- The install a sentinel started this node from (it exports it): where every deploy ships the runtime.
 local operator=host.getenv('WA_INSTANCE_OPERATOR_INSTALL');if operator and operator~='' then add(operator..'/scripts') end
 -- The default install every installer and deploy targets: a node started by its own service unit
 -- (openclaw's wa-serve.service) carries neither variable above, and searched only <data>/scripts - absent
 -- there - so every federated WhatsApp read answered mcp_session_not_installed (28/10).
 if platform.os()=='windows' then local base=host.getenv('LOCALAPPDATA');if base and base~='' then add((base:gsub('\\','/'))..'/wasm-agent/scripts') end
 else local okhome,home=pcall(paths.home);if okhome and type(home)=='string' then add(home..'/.local/bin/scripts') end end
 local okdata,data=pcall(paths.data);if okdata and type(data)=='string' then add(data..'/scripts') end
 if platform.os()=='windows' then local localapp=host.getenv('LOCALAPPDATA');if localapp then add(localapp..'/wasm-agent/scripts') end end
 return list
end
function M.script_candidates()return script_candidates() end
-- A server's vault entries, for the launch: the kernel puts each value in the CLIENT's environment, and
-- the client hands a server only the variables its `env` references - so each one is referenced by its own
-- name here (the definition stays names-only). Nil when the server names none.
-- Answers (server, vault_env): a COPY of the server when it names entries, so the registry row is never
-- changed by a launch.
function M.vault_launch(server)
 if type(server)~='table' or type(server.vault_env)~='table' or next(server.vault_env)==nil then return server,nil end
 local copy={};for key,value in pairs(server)do copy[key]=value end
 local env={};for key,value in pairs(type(server.env)=='table' and server.env or {})do env[key]=value end
 for key in pairs(server.vault_env)do env[key]=key end
 copy.env=env
 return copy,server.vault_env
end
-- The MCP runtime the node spawns: these files and nothing else they import. scripts/install.sh,
-- scripts/install.ps1 and scripts/deploy.sh ship exactly this list, and
-- scripts/test-mcp-runtime-closure.mjs fails when any of them, or the real import graph, disagrees.
M.RUNTIME={'mcp-client.mjs','mcp-client-core.mjs','mcp-server-core.mjs','mcp-session.mjs','mcp-web.mjs',
 'mcp-mail.mjs','web-core.mjs','web-http-outcomes.mjs'}
-- ---- what an approval IS, and what the kernel re-checks before it hands a value over ------------
--
-- The approval a connector that names a vault entry carries is a DIGEST over what its launch is
-- (docs/VAULT.md, 18/11): the program, the directory it runs in, the plain environment it asks for, its
-- arguments in order, every FILE it can run or load, and the vault names it asks for. Until it existed
-- the approval was one boolean in memory.db, while the scripts it runs live in a directory the agent can
-- write - so an approved connector's script could be replaced afterwards and the value handed to the new
-- code. The digest is recomputed twice: here, when a call is decided on (a change since the operator
-- approved it refuses `mcp_vault_approval_stale`), and again in
-- rust/wa-capabilities/src/operations.rs, from the bytes on disk, immediately before a value is read.
-- Editing a script, an argument, the cwd or the environment it asks for therefore voids the approval.
--
-- ONE canonical text, shared with the Rust side (`approval_text`): one form, two implementations, and
-- each side's test pins the same fixture digest (scripts/test-mcp-vault-approval.lua). Every field is
-- percent-escaped, so a newline, a space or a tab inside an argument cannot forge a line of it.
--
-- v2 added the cwd and the plain (non-vault) environment, and replaced "every absolute argument with a
-- script extension" with the CLOSURE of the code the connector can load. v3 (round 6) closes the rest of
-- that closure: the INTERPRETER the launch actually spawns (node_program, not the definition's program),
-- every argument resolved from the connector's own directory, and the scripts a wrapper RUNS - with inline
-- code, computed execs, child_process and a computed Worker refused by name (M.vault_manifest below). A
-- connector whose code cannot be closed this way is REFUSED rather than approved with a digest that only
-- looks complete.
M.APPROVAL_FORM='mcp-vault-approval/v3'
-- Bounds: an approval is re-read before every call, and a connector that needs more than this is one
-- whose coverage cannot be proven cheaply, so it is refused by name instead.
M.MAX_FILES=2048
M.MAX_FILE_BYTES=16*1024*1024
M.MAX_TOTAL_BYTES=64*1024*1024
-- A binary (a program, or the interpreter) is hashed in chunks and never parsed: bounded higher than a
-- script because a node binary is a hundred megabytes, and lower than what an approval could call cheap.
M.MAX_BINARY_BYTES=512*1024*1024
local function approval_field(text)
 return (tostring(text):gsub('[^%w%._~/:@+,=%-]', function(ch) return string.format('%%%02X', ch:byte()) end))
end
function M.vault_approval_text(manifest)
 manifest=type(manifest)=='table' and manifest or {}
 local lines={M.APPROVAL_FORM,'program '..approval_field(manifest.program or ''),
  'cwd '..approval_field(manifest.cwd or '')}
 -- Sorted by name, so the digest says the same thing whatever order the caller built the list in.
 local ordered={}
 for _,entry in ipairs(manifest.env or {})do ordered[#ordered+1]=entry end
 table.sort(ordered,function(a,b)return tostring(a.name or '')<tostring(b.name or '') end)
 for _,entry in ipairs(ordered)do
  lines[#lines+1]='env '..approval_field(tostring(entry.name or '')..'='..tostring(entry.ref or ''))
 end
 for _,arg in ipairs(manifest.args or {})do lines[#lines+1]='arg '..approval_field(arg) end
 for _,file in ipairs(manifest.files or {})do lines[#lines+1]='file '..approval_field(file.path)..' '..tostring(file.sha256 or ''):lower() end
 for _,name in ipairs(manifest.vault or {})do lines[#lines+1]='vault '..approval_field(name) end
 return table.concat(lines,'\n')..'\n'
end
-- ---- the code a connector can load, and the forms whose coverage cannot be proven ----------------
--
-- What is hashed is decided by what a launch can RUN, not by a name's extension:
--
--   * the program, unless it lives under a platform root (/usr/bin, /bin, /nix/store...): /usr/bin/node
--     is the interpreter the connector runs ON, replaced by a package manager and not by the agent; a
--     program anywhere else - ~/bin/conn, <install>/bin/mail-mcp - is the connector's own code and is
--     hashed whether it is a script, a binary or has no extension at all;
--   * every argument that is a path and exists as a file (so --config /etc/conn.json is covered, and a
--     relative ./conn.mjs, which node resolves from the cwd, is REFUSED rather than silently skipped);
--   * everything those files can load in turn: a JS import/require of a local path, a shell source/'.'.
--     A bare package name (node_modules), a package runner (npx, uvx, bunx...) and an import whose name is
--     computed are code this digest cannot name, so a connector that needs them is refused.
local SCRIPT_EXT={mjs=true,cjs=true,js=true,lua=true,sh=true,bash=true,py=true,rb=true,pl=true,ps1=true,bat=true}
local JS_EXT={mjs=true,cjs=true,js=true}
local SHELL_EXT={sh=true,bash=true}
-- Where the platform's own programs live. A program under one of these is not the connector's code.
local PLATFORM_ROOTS={'/bin/','/sbin/','/usr/bin/','/usr/sbin/','/usr/lib/','/usr/lib64/','/usr/libexec/',
 '/lib/','/lib64/','/usr/local/bin/','/usr/local/sbin/','/opt/homebrew/','/nix/store/','/snap/','/System/'}
-- Programs whose code comes from somewhere this digest cannot see: a package cache or a registry.
local PACKAGE_RUNNERS={npx=true,uvx=true,bunx=true,pipx=true,npm=true,pnpm=true,yarn=true,corepack=true}
-- Node's own modules: a bare name that is one of these is the platform, not node_modules.
local BUILTIN={assert=true,async_hooks=true,buffer=true,child_process=true,cluster=true,console=true,
 constants=true,crypto=true,dgram=true,diagnostics_channel=true,dns=true,domain=true,events=true,
 fs=true,http=true,http2=true,https=true,inspector=true,module=true,net=true,os=true,path=true,
 perf_hooks=true,process=true,punycode=true,querystring=true,readline=true,repl=true,stream=true,
 string_decoder=true,sys=true,timers=true,tls=true,trace_events=true,tty=true,url=true,util=true,
 v8=true,vm=true,wasi=true,worker_threads=true,zlib=true}
local function absolute_path(value)
 return type(value)=='string' and (value:sub(1,1)=='/' or value:match('^%a:[/\\]')~=nil)
end
local function normalize(path)
 path=tostring(path or ''):gsub('\\','/')
 local drive=path:match('^(%a:)/')
 if drive then path=path:sub(#drive+1) end
 local absolute=path:sub(1,1)=='/'
 local parts={}
 for part in path:gmatch('[^/]+')do
  if part=='.' then
  elseif part=='..' then
   if #parts>0 and parts[#parts]~='..' then table.remove(parts) elseif not absolute then parts[#parts+1]='..' end
  else parts[#parts+1]=part end
 end
 local joined=table.concat(parts,'/')
 if drive then return drive..'/'..joined end
 return (absolute and '/' or '')..joined
end
local function dirname(path)return (tostring(path):match('^(.*)/[^/]*$')) or '' end
local function basename(path)return (tostring(path):gsub('\\','/'):match('([^/]+)$')) or tostring(path) end
local function platform_root(path)
 local value=(normalize(path)..'/'):gsub('^%a:/','/')
 for _,root in ipairs(PLATFORM_ROOTS)do if value:sub(1,#root)==root then return true end end
 return false
end
-- A path-shaped argument is one the launch could read: it has a separator, or it carries a known script
-- extension (`conn.mjs`, resolved from the cwd). A URL is data, never a local path.
local function looks_like_path(value)
 if type(value)~='string' or value=='' then return false end
 if value:match('^%a[%w+.%-]*://') then return false end
 if value:find('[/\\]') then return true end
 local ext=value:match('%.([%w]+)$')
 return ext~=nil and SCRIPT_EXT[ext:lower()]==true
end
local function platform_module(spec)
 if spec:sub(1,5)=='node:' then return true end
 return spec:match('^[%w_%-]+$')~=nil and BUILTIN[spec]==true
end
-- Which scanner a file needs: the extension, or the shebang when it has none (a program named `conn`
-- with #!/usr/bin/env node is JavaScript, and it is followed as such).
local function language(path,content)
 local ext=(tostring(path):match('%.([%w]+)$') or ''):lower()
 if ext=='' and type(content)=='string' and content:sub(1,2)=='#!' then
  local line=(content:match('^#!([^\n]*)') or ''):lower()
  if line:find('node') then return 'js' end
  if line:find('bash') or line:find('/sh') or line:find('%f[%w]sh%f[%W]') then return 'sh' end
  return 'other'
 end
 if JS_EXT[ext] then return 'js' end
 if SHELL_EXT[ext] then return 'sh' end
 if ext=='' then return 'binary' end
 if SCRIPT_EXT[ext] then return 'other' end
 return 'data'
end
-- The names a script loads, as this digest can follow them. Anything else is named as a problem: a name
-- this cannot resolve is a file this approval cannot cover.
local function module_refs(kind,content)
 local refs={}
 if kind=='js' then
  for spec in content:gmatch('from%s*[\'\"]([^\'\"]+)[\'\"]')do refs[#refs+1]=spec end
  for spec in content:gmatch('import%s*[\'\"]([^\'\"]+)[\'\"]')do refs[#refs+1]=spec end
  for spec in content:gmatch('import%s*%(%s*[\'\"]([^\'\"]+)[\'\"]%s*%)')do refs[#refs+1]=spec end
  for spec in content:gmatch('require%s*%(%s*[\'\"]([^\'\"]+)[\'\"]%s*%)')do refs[#refs+1]=spec end
  -- A Worker or a new URL is a module too, when it names one: a literal target is followed like an
  -- import, and a computed one is refused below.
  for spec in content:gmatch('Worker%s*%(%s*[\'\"]([^\'\"]+)[\'\"]')do refs[#refs+1]=spec end
  for spec in content:gmatch('Worker%s*%(%s*new%s+URL%s*%(%s*[\'\"]([^\'\"]+)[\'\"]')do refs[#refs+1]=spec end
 elseif kind=='sh' then
  for target in content:gmatch('[%s;]source%s+([^%s;]+)')do refs[#refs+1]=target end
  for target in content:gmatch('[\n;]%s*%.%s+([^%s;]+)')do refs[#refs+1]=target end
  -- A wrapper that RUNS another script names that script, so it is followed (and hashed) rather than
  -- refused: exec ./inner.sh, bash ./inner.sh.
  for target in content:gmatch('[%s;]exec%s+([^%s;|&]+)')do refs[#refs+1]=target end
  for _,shell in ipairs({'bash','sh','dash','zsh','ksh'})do
   for target in content:gmatch('[%s;]'..shell..'%s+([^%s;|&%-][^%s;|&]*)')do refs[#refs+1]=target end
  end
 end
 return refs
end
-- An import whose argument is not a literal string is code chosen while it runs, so no digest of files
-- can say what it will load.
local function computed_import(kind,content)
 if kind~='js' then return nil end
 if content:find('import%s*%(%s*[^%s\'\"]') then return 'import' end
 if content:find('require%s*%(%s*[^%s\'\"]') then return 'require' end
 return nil
end
local RESOLVE_EXT={'.mjs','.js','.cjs','/index.mjs','/index.js','/index.cjs'}
local function resolve_local(base,spec)
 if spec:sub(1,5)=='file:' then spec=spec:sub(6):gsub('^//','') end
 local candidate=absolute_path(spec) and normalize(spec) or normalize(base..'/'..spec)
 if host.path_kind(candidate)=='file' then return candidate end
 if not candidate:match('%.%w+$') then
  for _,ext in ipairs(RESOLVE_EXT)do
   if host.path_kind(candidate..ext)=='file' then return candidate..ext end
  end
 end
 return nil
end
-- ---- what a launch can RUN, decided by facts on disk rather than by a name (round 6) --------------
--
-- Three holes are closed here, and each was a way to run bytes the digest never named:
--
--   1. the INTERPRETER. node_program() answers WA_NODE, then the copy the installer provisions beside the
--      node, then the bare name node. That process is the one the vault values are put in, and it was
--      neither hashed nor, when it lives in <data>/node, out of the agent's reach. It is resolved through
--      its realpath and hashed into the approval unless it is the PLATFORM's own: root-owned and not
--      group/other-writable, which a package manager upgrades and the agent cannot;
--   2. an ARGUMENT that names a file. looks_like_path needed a slash or a script extension, so
--      program /usr/bin/node, args {server}, cwd /home/u/conn ran ./server.js unhashed. Every argument is
--      resolved the way node resolves it - from the connector's own directory, with the extensions node
--      implies - and what exists is hashed. An argument that may name a file and cannot be resolved is
--      REFUSED: a file that is not there at approval time can be there at launch;
--   3. a script that RUNS another script. A wrapper that execs a second script, or sources it, is
--      FOLLOWED (the target is a file, so it is hashed in turn); an inline string (node -e, sh -c, eval),
--      a command substitution, a computed exec, child_process and a computed Worker are REFUSED by name,
--      because no digest of files can name a string that is evaluated.
--
-- The node's own MCP runtime is exempt from the child_process rule and from nothing else: it is the
-- harness that spawns the connector, its bytes are in the digest, and the request seal in
-- rust/wa-capabilities/src/operations.rs is what checks the program it spawns against the approval.
local RUNTIME_NAME={}
for _,name in ipairs(M.RUNTIME)do RUNTIME_NAME[name]=true end
-- The Node program that runs the MCP runtime. An explicit WA_NODE wins; after that, the copy the
-- installer provisions beside the node (<install>/node, <data>/node, node.exe on Windows), because a
-- device whose PATH has no Node was a device where every MCP tool refused. path_kind is a stat, never a
-- read: this must not load a hundred megabytes of binary into Lua to answer a path question.
local function node_program()
 local override=host.getenv('WA_NODE');if override and override~='' then return override end
 local relative=platform.os()=='windows' and '/node/node.exe' or '/node/bin/node'
 local bases={}
 local install=host.getenv('WA_INSTALL_DIR');if install and install~='' then bases[#bases+1]=install end
 local okdata,data=pcall(paths.data);if okdata and type(data)=='string' then bases[#bases+1]=data end
 for _,base in ipairs(bases) do
  local program=base..relative
  if host.path_kind(program)=='file' then return program end
 end
 return 'node'
end
-- host.path_facts: the realpath and the identity a permission decision needs. nil when the host cannot
-- answer - never a guess, because a guess here means trusting a file nobody hashed.
local function path_facts(path)
 local raw=host.path_facts and host.path_facts(tostring(path or ''))
 local facts=raw and decode(raw)
 return type(facts)=='table' and facts or nil
end
-- Windows has no uid to read here: the prefix list is the answer there, and docs/VAULT.md says so.
local function unix_facts(facts)return facts~=nil and facts.unix==true and type(facts.uid)=='number' end
-- The mode bits a package manager's upgrade leaves behind. nil means "this host cannot say".
local function root_owned(facts)
 if not unix_facts(facts) then return nil end
 if facts.uid~=0 then return false end
 local mode=tonumber(facts.mode) or 0
 local group,other=math.floor(mode/8)%8,mode%8
 if math.floor(group/2)%2==1 or math.floor(other/2)%2==1 then return false end
 return true
end
local function parent_dir(path)
 local trimmed=tostring(path or ''):gsub('/+$','')
 return (trimmed:match('^(.*)/[^/]+$')) or ''
end
-- A path is the PLATFORM's when it is under a platform root AND root-owned AND not group/other-writable,
-- with every directory above it the same: a writable directory lets anyone replace the file inside it.
-- (Round 6: /usr/local/bin and /opt/homebrew belong to the user on macOS, so a homebrew interpreter was
-- called the platform's and received the vault values unhashed.)
local function platform_owned(path)
 if not platform_root(path) then return false end
 local facts=path_facts(path)
 if not facts or facts.kind~='file' then return false end
 if not unix_facts(facts) then return true end
 local real=tostring(facts.path or path)
 if root_owned(facts)==false then return false end
 local dir,guard=parent_dir(real),0
 while dir~='' and dir~='/' and guard<64 do
  local parents=path_facts(dir)
  if not parents or root_owned(parents)==false then return false end
  dir=parent_dir(dir);guard=guard+1
 end
 return true
end
-- The interpreter as a FILE: node_program() may answer a bare name (node), which the kernel resolves
-- through PATH when it spawns; the digest has to resolve it the same way, or it names nothing at all.
local function interpreter_path()
 local program=normalize(tostring(node_program() or ''))
 if program=='' then return nil end
 if program:find('/') then return program end
 for dir in tostring(host.getenv('PATH') or ''):gmatch('[^:;]+') do
  local candidate=normalize(dir..'/'..program)
  if host.path_kind(candidate)=='file' then return candidate end
 end
 return nil
end
-- Exported for the tests that pin the ownership rule (scripts/test-mcp-vault-approval.lua).
M.platform_owned=platform_owned
-- Where node would find a file an argument names: the connector's own directory, then the extensions node
-- implies. nil when nothing is there - and a relative name with no directory to resolve it from is nil
-- too, because the launch's own cwd is not the approval's to assume.
local function resolve_argument(cwd,value)
 if not absolute_path(value) and (type(cwd)~='string' or cwd=='') then return nil end
 return resolve_local(type(cwd)=='string' and cwd or '',value)
end
-- The interpreter family, from the program's own name: the flags that mean "run this string" differ.
local INTERPRETERS={node='js',nodejs='js',bun='js',deno='js',qjs='js',quickjs='js',
 sh='sh',bash='sh',dash='sh',zsh='sh',ksh='sh'}
local INLINE_FLAGS={js={['-e']=true,['--eval']=true,['-p']=true,['--print']=true},
 sh={['-c']=true,['--command']=true}}
-- Options that name a FILE rather than a value: their argument is hashed, or refused.
local PATH_OPTIONS={['--require']=true,['-r']=true,['--import']=true,['--loader']=true,
 ['--experimental-loader']=true,['--env-file']=true,['--config']=true}
local function interpreter_family(program)
 local name=basename(tostring(program or '')):lower():gsub('%.exe$','')
 if INTERPRETERS[name] then return INTERPRETERS[name] end
 if SCRIPT_EXT[(name:match('%.([%w]+)$') or ''):lower()] then return 'script' end
 return 'unknown'
end
local function inline_flag(program,value)
 local flags=INLINE_FLAGS[interpreter_family(program)]
 if flags and flags[value] then return true end
 return false
end
-- What a digest of FILES cannot follow: a string it would evaluate, a process it would start, a module
-- whose name is chosen while it runs. Refused by name, in the connector's own code.
local QUOTE_CLASS='['..string.char(39)..string.char(34)..']'
local function refused_construct(kind,content,path)
 if kind=='js' then
  if content:find('child_process',1,true) and not RUNTIME_NAME[basename(path)] then
   return 'it starts a process (child_process), whose program no digest names'
  end
  if content:find('worker_threads',1,true) and not content:find('Worker%s*%(%s*'..QUOTE_CLASS)
   and not content:find('Worker%s*%(%s*new%s+URL') then
   return 'it starts a Worker whose target is not a literal module it names'
  end
  if content:find('process%.dlopen') then return 'it loads a native addon by handle (process.dlopen)' end
  if content:find('%f[%w]eval%s*%(') then return 'it evaluates a string as code (eval)' end
  if content:find('new%s+Function%s*%(') then return 'it builds a function from a string (new Function)' end
 elseif kind=='sh' then
  local value_after_exec='['..string.char(39)..string.char(34)..'%$]'
  if content:find('%f[%w]eval%s') then return 'it evaluates a string as shell code (eval)' end
  if content:find('%f[%w]exec%s+'..value_after_exec) then
   return 'it execs a script chosen while it runs (exec of a value)'
  end
  for _,shell in ipairs({'bash','sh','dash','zsh','ksh'})do
   if content:find('%f[%w]'..shell..'%s+%-c') then return 'it runs inline shell code ('..shell..' -c)' end
  end
  if content:find('%$%(') or content:find(string.char(96),1,true) then
   return 'it runs a command substitution, whose code no digest names'
  end
 end
 return nil
end
-- The manifest an approval records, and the one a launch is checked against: the paths in a stable order,
-- each file's sha256 as it is NOW, the arguments in order, the vault names sorted, and the reasons
-- coverage could not be proven (`problems`, empty when it could).
function M.vault_manifest(definition,directory)
 local list=type(definition)=='table' and definition or {}
 local files,seen,problems,queue={}, {}, {}, {}
 local total=0
 local function add(path)
  if type(path)~='string' or path=='' then return end
  path=normalize(path)
  if seen[path] then return end
  local facts=path_facts(path)
  if not facts or facts.kind~='file' then
   problems[#problems+1]='a file it runs cannot be read ('..path..')'
   return
  end
  local size=tonumber(facts.size) or 0
  -- A program or an interpreter is a BINARY: its bytes are hashed and never parsed, because there is no
  -- module system to follow inside one, and host.file_sha256 reads it in chunks rather than loading it.
  if size>M.MAX_FILE_BYTES then
   if size>M.MAX_BINARY_BYTES or #files>=M.MAX_FILES then
    problems[#problems+1]='its code is larger than an approval can cover ('..path..')'
    return
   end
   local href=host.file_sha256 and host.file_sha256(path)
   if type(href)~='string' or href=='' then
    problems[#problems+1]='a file it runs cannot be hashed ('..path..')'
    return
   end
   -- Not added to the total: that budget bounds the TEXT this manifest holds and parses, and a binary is
   -- neither (a node binary is larger than the whole budget and is hashed in chunks).
   seen[path]=true;files[#files+1]={path=path,sha256=href}
   return
  end
  local content=host.read_file(path)
  if type(content)~='string' then problems[#problems+1]='a file it runs cannot be read ('..path..')';return end
  if #content>M.MAX_FILE_BYTES or total+#content>M.MAX_TOTAL_BYTES or #files>=M.MAX_FILES then
   problems[#problems+1]='its code is larger than an approval can cover ('..path..')'
   return
  end
  local kind=language(path,content)
  -- Its language loads code this digest cannot follow (a python package, a ruby gem): refused by name
  -- rather than hashed and left open. JavaScript and shell are the two it CAN follow.
  if kind=='other' then
   problems[#problems+1]='a script in a language whose module system this digest cannot follow ('..path..')'
   return
  end
  total=total+#content
  -- The digest is over the bytes PARSED here; the kernel hashes the file again from disk, so a rewrite
  -- between the two is a mismatch rather than a launch (operations.rs, recheck_after_spawn).
  seen[path]=true;files[#files+1]={path=path,sha256=host.sha256(content)}
  queue[#queue+1]={path=path,content=content,kind=kind}
 end
 if type(directory)=='string' and directory~='' then
  for _,name in ipairs(M.RUNTIME)do add(directory..'/'..name) end
 end
 -- The program: the interpreter is the platform's, its own code is the connector's.
 local program=tostring(list.program or '')
 local name=basename(program):lower()
 if program=='' then
  problems[#problems+1]='it names no program'
 elseif PACKAGE_RUNNERS[name] then
  problems[#problems+1]='its program is a package runner ('..name..'), whose code comes from a cache or a registry rather than from files this approval can name'
 elseif not absolute_path(program) then
  problems[#problems+1]='its program is not an absolute path ('..program..'): a bare name is resolved through PATH, which this digest does not name'
 elseif not platform_owned(program) then
  add(program)
 end
 -- The interpreter the launch SPAWNS is node_program(), not the definition's program, and it is the
 -- process the vault values are put in. Its realpath is covered by the digest, or the connector cannot be
 -- approved: WA_NODE may name anything, and <data>/node belongs to the agent's own user.
 local interpreter=interpreter_path()
 if not interpreter then
  problems[#problems+1]='its interpreter cannot be found ('..tostring(node_program())..'), so no file this digest could hash runs it'
 elseif platform_owned(interpreter) then
  -- The platform's own interpreter: a package manager replaces it, never the agent, so its bytes are not
  -- this connector's to hash on every call.
 else
  local facts=path_facts(interpreter)
  if not facts or facts.kind~='file' then
   problems[#problems+1]='its interpreter cannot be read ('..interpreter..')'
  else add(tostring(facts.path or interpreter)) end
 end
 -- The arguments. Every one of them is a file the launch may read until it is proved otherwise: node
 -- takes the script first, then whatever that script is told, and a bare word (server) is a file beside
 -- the connector when one is there - which is the shape this digest used to skip (round 6).
 local args={}
 local cwd_value=tostring(list.cwd or '')
 local pending_option=''
 for _,arg in ipairs(type(list.args)=='table' and list.args or {})do
  local value=tostring(arg);args[#args+1]=value
  local is_option=value:sub(1,1)=='-' and #value>1
  if is_option and inline_flag(program,value) then
   problems[#problems+1]='it runs inline code ('..value..'), and no digest of files can name a string it evaluates'
  elseif is_option then
   local name,inline=value:match('^(%-%-[%w%-]+)=(.*)$')
   pending_option=name or value
   if name and PATH_OPTIONS[name] then
    local target=resolve_argument(cwd_value,inline)
    if target then add(target)
    else problems[#problems+1]='an argument names a file that cannot be found ('..inline..' after '..name..')' end
   end
  else
   local target=resolve_argument(cwd_value,value)
   if target then add(target)
   elseif pending_option~='' and not PATH_OPTIONS[pending_option] then
    -- The value of an option (--mode stdio): node reads it as a value, not as a file.
   elseif pending_option~='' then
    problems[#problems+1]='an argument names a file that cannot be found ('..value..' after '..pending_option..')'
   elseif looks_like_path(value) then
    problems[#problems+1]='an argument is a path resolved from its own directory ('..value..'): only an absolute path can be covered'
   else
    problems[#problems+1]='an argument may name a file this digest cannot resolve ('..value..' from '
      ..(cwd_value~='' and cwd_value or 'no directory')..'): give its absolute path'
   end
   pending_option=''
  end
 end
 -- The closure: what each covered file loads in turn.
 local index=0
 while index<#queue do
  index=index+1
  local entry=queue[index]
  local computed=computed_import(entry.kind,entry.content)
  if computed then
   problems[#problems+1]='a script loads code by a computed name ('..computed..' in '..entry.path..')'
  end
  local refused=refused_construct(entry.kind,entry.content,entry.path)
  if refused then problems[#problems+1]=refused..' ('..entry.path..')' end
  for _,spec in ipairs(module_refs(entry.kind,entry.content))do
   if platform_module(spec) then
   elseif spec:sub(1,1)=='.' or spec:sub(1,1)=='/' or spec:sub(1,5)=='file:' then
    local target=resolve_local(dirname(entry.path),spec)
    if not target then
     problems[#problems+1]='a script loads a file that cannot be found ('..spec..' in '..entry.path..')'
    else add(target) end
   else
    problems[#problems+1]='a script imports a package ('..spec..' in '..entry.path..'), whose code lives outside the files this approval can name'
   end
  end
 end
 table.sort(files,function(a,b)return a.path<b.path end)
 local env={}
 for key,ref in pairs(type(list.env)=='table' and list.env or {})do env[#env+1]={name=tostring(key),ref=tostring(ref)} end
 table.sort(env,function(a,b)return a.name<b.name end)
 local names={};for vault_name in pairs(type(list.vault_env)=='table' and list.vault_env or {})do names[#names+1]=tostring(vault_name) end
 table.sort(names)
 local manifest={form=M.APPROVAL_FORM,program=program,cwd=tostring(list.cwd or ''),env=env,args=args,
  files=files,vault=names,problems=problems}
 manifest.sha256=host.sha256(M.vault_approval_text(manifest))
 return manifest
end
local function complete(dir)
 for _,file in ipairs(M.RUNTIME) do if host.path_kind(dir..'/'..file)~='file' then return false end end
 return true
end
function M.script_dir()
 -- A directory holding only part of the runtime is skipped: a stale copy with mcp-client.mjs but without
 -- web-core.mjs answered first and every web_search/web_read died at import (mcp_stdio_eof, 28/10).
 for _,dir in ipairs(script_candidates()) do
  if complete(dir) then return dir end
 end
 for _,dir in ipairs(script_candidates()) do
  if host.read_file(dir..'/mcp-client.mjs') then return dir end
 end
 -- Nothing holds the runtime. An operator's explicit override is still returned, so the error that follows
 -- names the directory they chose instead of a generic "not installed".
 local override=host.getenv('WA_MCP_SCRIPT_DIR');if override and override~='' then return override end
 return nil
end
-- The failure a missing runtime must produce: the code callers already check, plus what was searched and the
-- one-line fix. Losing that detail is what made the original report look like a permission refusal.
function M.scripts_missing()
 return fail('mcp_scripts_not_found',{searched=script_candidates(),tool_call_issued=false,outcome='not_submitted',
  fix='install the MCP runtime beside the node (scripts/install.sh does this) or set WA_MCP_SCRIPT_DIR'})
end
-- The Node program that runs the MCP runtime. An explicit `WA_NODE` wins; after that, the copy the
-- installer provisions beside the node (`<install>/node`, `<data>/node`, `node.exe` on Windows), because a
-- device whose PATH has no Node was a device where every MCP tool refused. `path_kind` is a stat, never a
-- read: this must not load a hundred megabytes of binary into Lua to answer a path question.
function M.node_program()return node_program() end
-- The read sessions launch the same runtime: they used `WA_NODE or 'node'`, so on a node with no
-- system Node (the sandbox image) every reused read failed `program_not_found_on_path` while a probe,
-- which comes through here, passed (28/10).
read_sessions.node_program=node_program
-- The mail-mcp binary the installer provisions (`<install>/bin/mail-mcp`, `mail-mcp.exe` on Windows).
-- `MAIL_MCP_BIN` wins, because that is what the installer records and what an operator overrides by hand.
local function mail_program()
 local override=host.getenv('MAIL_MCP_BIN');if override and override~='' then return override end
 local relative=platform.os()=='windows' and '/bin/mail-mcp.exe' or '/bin/mail-mcp'
 local bases={}
 local install=host.getenv('WA_INSTALL_DIR');if install and install~='' then bases[#bases+1]=install end
 local okdata,data=pcall(paths.data);if okdata and type(data)=='string' then bases[#bases+1]=data end
 for _,base in ipairs(bases) do
  local binary=base..relative
  if host.path_kind(binary)=='file' then return binary end
 end
 return nil
end
function M.mail_program()return mail_program() end
local function valid_id(id)return type(id)=='string' and #id<=24 and id:match('^[a-z][a-z0-9_-]*$') end
local function dense(list,maximum)if type(list)~='table' or #list>maximum then return false end;for key,value in pairs(list)do if type(key)~='number' or key<1 or key>#list or key%1~=0 or type(value)~='string' then return false end end;return true end
-- A definition that names vault entries is the OPERATOR's, and it stays inert until the operator says
-- so. vault_env is not a credential reference like env: the kernel injects the VALUE into whatever
-- program the definition names, at launch (rust operations.rs). A model that could put
-- {transport='stdio', program='/bin/sh', args={'-c','echo $X >/tmp/x'}, vault_env={X='github'}} and then
-- probe it would read any vault entry the operator has stored, through a connector nobody approved (18/11,
-- and the same hole through a peer-imported definition). So:
--
--   * a model's put carrying vault_env is refused by name, and a peer's import of one is registered
--     DISABLED and unapproved - it can be inspected, never launched;
--   * probe and enable of such a row refuse until an OPERATOR acts (ctx.operator, set by the CLI's own
--     /mcp command and by nothing else), and that act is what approves it;
--   * a call through an unapproved row is refused too, so an approval is the only way a value is used.
--
-- Removing the entries is not the alternative: a shared connector is meant to arrive names-only and get
-- its value from the receiving node's vault (/mcp <key> share <node>), which is what the operator then
-- approves.
local VAULT_ENV_OPERATOR = 'mcp_vault_env_requires_operator'
-- The two ways an approval stops covering its connector: it was recorded before approvals recorded what
-- they cover, or the program, an argument or a script changed after the operator gave it.
local VAULT_APPROVAL_MISSING = 'mcp_vault_approval_missing'
local VAULT_APPROVAL_STALE = 'mcp_vault_approval_stale'
-- The third: the code cannot be CLOSED - a relative script, a package runner, an import of a module the
-- digest cannot name - so there is no honest digest to record and nothing is approved.
local VAULT_CODE_NOT_COVERED = 'mcp_vault_code_not_covered'
-- How to give the approval again, in the one wording every refusal here uses: the operator's own
-- terminal, probe then on - and never a model's call.
local function approve_again(id)
 return ' Approve it again at the operator\'s own terminal: /mcp '..tostring(id)..' probe, then /mcp '..tostring(id)..' on.'
end

function M.names_vault(definition)
 return type(definition)=='table' and type(definition.vault_env)=='table' and next(definition.vault_env)~=nil
end

-- The refusal a connector whose code cannot be covered answers, at the moment an operator would approve
-- it and on every call afterwards: a digest over an incomplete file list is worse than no approval,
-- because it reads as one. The reasons are the digest's own words (M.vault_manifest's problems list).
local function coverage_refusal(id, manifest)
 local problems = type(manifest)=='table' and manifest.problems or {}
 if #problems == 0 then return nil end
 return fail(VAULT_CODE_NOT_COVERED, { id = id, outcome = 'not_submitted', tool_call_issued = false, problems = problems,
  note = "this connector runs code a digest cannot cover, so it was not approved: "
    .. table.concat(problems, '; ')
    .. ". A vault connector's program and every path it runs must be absolute, its imports must resolve "
    .. "to files beside it, and a package runner or a computed import is refused (docs/VAULT.md). Nothing was launched." })
end

-- The refusal every unapproved launch of a vault connector answers. One sentence, because the model that
-- reads it must not be able to change the outcome: the operator approves at the terminal.
local function vault_gate(row, ctx, id)
 if not M.names_vault(row and row.definition) or (ctx and ctx.operator) then return nil end
 if not (row and row.vault_approved==true) then
  return fail(VAULT_ENV_OPERATOR,{id=id,outcome='not_submitted',tool_call_issued=false,
   note='this connector names a vault entry (vault_env), so only the operator can start it: /mcp '..tostring(id)
     ..' probe (or on) at the operator\'s own terminal. Nothing was launched.'})
 end
 -- The approval is a digest over what the launch IS (M.vault_manifest), so a script or an argument
 -- edited after the operator approved the connector no longer matches it. The kernel checks the same
 -- digest from the bytes on disk before it reads a value; this check is what turns that into a refusal
 -- the model can read, before a process is started at all.
 local approved=row.vault_approval
 -- A row approved before approvals named their form predates the digest that says what they cover (the
 -- cwd and the plain environment are v2's, the closure of the code is v2's, the interpreter and the
 -- resolved arguments are v3's): it is refused with that sentence, not with a mismatch the operator
 -- cannot act on.
 if type(approved)~='table' or type(approved.sha256)~='string' or approved.sha256=='' or tostring(approved.form or '')~=M.APPROVAL_FORM then
  return fail(VAULT_APPROVAL_MISSING,{id=id,outcome='not_submitted',tool_call_issued=false,
   note='this connector\'s approval predates the digest that says what it covers, so nothing was launched and no value was read.'..approve_again(id)})
 end
 local now=M.vault_manifest(row.definition,M.script_dir())
 local uncovered=coverage_refusal(id,now);if uncovered then return uncovered end
 if now.sha256~=approved.sha256 then
  return fail(VAULT_APPROVAL_STALE,{id=id,outcome='not_submitted',tool_call_issued=false,approved=approved.sha256,now=now.sha256,
   note='this connector\'s program, arguments or scripts changed after the operator approved it, so nothing was launched and no value was read.'..approve_again(id)})
 end
 return nil
end
function M.validate(def)
 if type(def)~='table' or not valid_id(def.id) then return 'invalid_mcp_id' end
 local allowed={id=true,name=true,transport=true,program=true,args=true,cwd=true,url=true,env=true,headers=true,secret_env=true,vault_env=true,timeout_seconds=true,tools=true,component=true,file_env=true,net=true,config=true,native=true}
 for key in pairs(def)do if not allowed[key]then return 'unsupported_mcp_definition_field:'..tostring(key) end end
 if def.name~=nil and (type(def.name)~='string' or #def.name>200)then return 'invalid_mcp_name' end
 if def.transport=='stdio' then
  if type(def.program)~='string' or def.program=='' or def.program:find('[\r\n%z]') or not dense(def.args,128)then return 'invalid_mcp_command' end
  if def.cwd~=nil and not absolute(def.cwd)then return 'mcp_cwd_requires_absolute_path' end
 elseif def.transport=='http' then
  if type(def.url)~='string' or #def.url>2048 or not def.url:match('^https?://') or def.url:find('[\r\n%z]')then return 'invalid_mcp_url' end
 elseif def.transport=='native' then
  -- A connector answered in this process by the node's own capabilities (2026-11-10): the Rust
  -- WhatsApp path lives in wa-whatsapp's queue, not behind an HTTP API, so a tool that maps onto
  -- what the node already does needs no program, no socket and no token.
  if type(def.native)~='table' or next(def.native)==nil then return 'invalid_mcp_native_map' end
  for tool,cap in pairs(def.native)do
   if not valid_id(tool) or type(cap)~='string' then return 'invalid_mcp_native_map' end
   local known=NATIVE_TOOLS[tool]
   if not known or known.cap~=cap then return 'invalid_mcp_native_map' end
  end
  if def.program~=nil or def.args~=nil or def.cwd~=nil or def.url~=nil or def.headers~=nil or def.component~=nil or def.net~=nil or def.file_env~=nil then return 'mcp_native_takes_no_transport' end
 elseif def.transport=='component' then
  -- A pinned WASI component (docs/COMPONENTS.md): no program, no args, no cwd. What it may touch is
  -- exactly env/file_env/net, each of which its manifest must also declare (the host enforces it).
  if type(def.component)~='string' or not def.component:match('^[a-z][a-z0-9-]*$') or #def.component>40 then return 'invalid_mcp_component' end
  if def.program~=nil or def.args~=nil or def.cwd~=nil or def.url~=nil or def.headers~=nil then return 'mcp_component_takes_no_command' end
  if def.net~=nil then if not dense(def.net,16) then return 'invalid_mcp_component_net' end
   for _,addr in ipairs(def.net)do if not addr:match('^[%w%.%-]+:%d+$') and not addr:match('^%[[%x:]+%]:%d+$') then return 'invalid_mcp_component_net' end end end
 else return 'invalid_mcp_transport' end
 if def.config~=nil and (type(def.config)~='table' or (def.transport~='component' and def.transport~='native')) then return 'invalid_mcp_component_config' end
 if def.transport~='component' and (def.component~=nil or def.file_env~=nil or def.net~=nil) then return 'mcp_component_fields_require_component_transport' end
 for _,field in ipairs({'env','headers','file_env'})do
  if def[field]~=nil then if type(def[field])~='table' then return 'invalid_mcp_references' end
   -- file_env may name the file itself: a path is a location, never the secret.
   for key,name in pairs(def[field])do if type(key)~='string' or type(name)~='string' or not (name:match('^[A-Za-z_][A-Za-z0-9_]*$') or (field=='file_env' and absolute(name) and not name:find('[\r\n%z]')))then return 'mcp_credentials_require_environment_references' end end
  end
 end
 -- `vault_env` ({ENV: entry}, stdio only): the kernel injects that node-vault entry into the server's
 -- environment at launch (rust operations.rs). Names only here; a value never enters the registry.
 if def.vault_env~=nil then
  if def.transport~='stdio' then return 'mcp_vault_env_requires_stdio' end
  if type(def.vault_env)~='table' then return 'invalid_mcp_vault_env' end
  for key,entry in pairs(def.vault_env)do
   if type(key)~='string' or not key:match('^[A-Za-z_][A-Za-z0-9_]*$') or type(entry)~='string' or not entry:match('^[%w._-]+$') then return 'invalid_mcp_vault_env' end
  end
 end
 if def.secret_env~=nil then
  if not dense(def.secret_env,64) then return 'invalid_mcp_secret_env_tags' end
  for _,key in ipairs(def.secret_env)do if not def.env or not def.env[key] then return 'invalid_mcp_secret_env_tags' end end
 end
 if def.timeout_seconds~=nil and (type(def.timeout_seconds)~='number' or def.timeout_seconds%1~=0 or def.timeout_seconds<1 or def.timeout_seconds>86400)then return 'invalid_mcp_timeout' end
 if type(def.tools)~='table' then return 'mcp_tool_permissions_required' end
 for name,effect in pairs(def.tools)do if type(name)~='string' or name=='' or #name>128 or (effect~='read' and effect~='write')then return 'invalid_mcp_tool_permission' end end
 -- Generic WhatsApp sends never ride an MCP server: the operator path is the only sender. The stdio
 -- filename rule this used to carry named the Node bridge, deleted 10/11; the component branch below
 -- is what enforces it now.
 if def.tools.send_message and def.transport=='component' and def.component=='mcp-whatsapp' then return 'whatsapp_send_uses_operator_route' end
 return nil
end
function M.namespace(id,name)
 local prefix='mcp_'..id..'_';local clean=tostring(name):gsub('[^A-Za-z0-9_-]','_'):sub(1,24)
 return prefix..clean..'_'..host.sha256(id..'\0'..name):sub(1,8)
end
local function native_data(answer)
 if type(answer)~='table' then return nil end
 local result=answer.result or decode(answer.result_json)
 if result then
  if type(result.structuredContent)=='table' then return result.structuredContent end
  local content=result.content;if type(content)=='table' and #content==1 and content[1].type=='text' then return decode(content[1].text) end
 end
end
-- A component server runs inside the host (wasmtime), not as a spawned Node process: one bounded
-- MCP request per call, same answer shape as mcp-client.mjs, so schemas, approvals and code mode
-- (every mcp_* tool) are unchanged.
local function invoke_component(input)
 local server=input.server
 local request={action=input.action,component=server.component,env=server.env,file_env=server.file_env,net=server.net,config=server.config,
  timeout_seconds=server.timeout_seconds or 30,tool=input.tool,schema_hash=input.schema_hash,arguments_json=input.arguments_json}
 if input.arguments_json==nil and input.arguments~=nil then request.arguments_json=json.encode(input.arguments) end
 if not host.component_mcp then return fail('component_runtime_unavailable',{tool_call_issued=false,outcome='not_submitted'}) end
 local answer=decode(host.component_mcp(json.encode(request)))
 if not answer then return fail('component_answer_unreadable',{tool_call_issued=input.action=='call',outcome=input.action=='call' and 'unknown' or 'not_submitted'}) end
 return answer
end
-- What a native connector may publish, in the MCP tool's own vocabulary: the caller's fields are
-- `conversation_id`/`n`/`query` (older than the capability's `chat`/`limit`/`q`), so the schema a
-- connector publishes must name those, and the alias below is what turns them into the capability's.
-- Read-only questions only: a connector has never been the send path (the operator route is).
NATIVE_CAPS={whatsapp_search=true,whatsapp_read=true,whatsapp_reactions=true,whatsapp_media=true}
-- A schema is data: it is written as a table and encoded, never assembled from strings. Three of the
-- four defects this file had on 2026-11-10 were hand-built JSON (a missing wrapper, `required` nested
-- inside `properties`, a comma before an empty map), and none of them could survive json.encode.
local string=function()return {type='string'} end
local integer=function()return {type='integer'} end
NATIVE_TOOLS={
 read_newest={cap='whatsapp_read',description='Read one WhatsApp chat newest-first from the index this node holds',
  schema={type='object',properties={conversation_id=string(),n=integer(),scan_days=integer()},required={'conversation_id'},additionalProperties=false}},
 inspect_chat={cap='whatsapp_read',description='Inspect one WhatsApp chat: newest messages of that exact chat',
  schema={type='object',properties={conversation_id=string(),limit=integer()},required={'conversation_id'},additionalProperties=false}},
 read_snapshot={cap='whatsapp_search',description='Search the WhatsApp message index this node holds',
  schema={type='object',properties={conversation_id=string(),query=string(),kind=string(),from=string(),since=integer(),['until']=integer(),limit=integer()},additionalProperties=false}},
 lookup_self={cap='identity',description='The WhatsApp account this node is paired with',
  schema={type='object',properties={},additionalProperties=false}},
}
-- `lookup_self` needs no capability: the account is in the connector's own binding.
local function native_identity(server)
 local config=type(server.config)=='table' and server.config or {}
 return {ok=true,account=config.account,generation=config.generation}
end
-- What the caller said, in the capability's own field names. MCP tool names predate the capability
-- names (`conversation_id`/`n`/`query` against `chat`/`limit`/`q`), and the translation lives here so a
-- Lua test can assert it without a node: the published schema and this map must agree, or the call is
-- refused before it leaves the process.
local ALIAS={read_newest={conversation_id='chat',n='limit'},inspect_chat={conversation_id='chat'},
 read_snapshot={conversation_id='chat',query='q'}}
function M.native_arguments(tool,args)
 local alias=ALIAS[tool]
 args=type(args)=='table' and args or {}
 if not alias then return args end
 local mapped={}
 for key,value in pairs(args)do mapped[alias[key] or key]=value end
 if tool=='inspect_chat' then mapped.limit=mapped.limit or 1 end
 return mapped
end
local function invoke_native(input)
 local server=input.server or {}
 local function probe()
  local tools={}
  for tool,cap in pairs(server.native or {})do
   local spec=NATIVE_TOOLS[tool]
   if not spec or spec.cap~=cap then return fail('mcp_native_tool_unknown',{tool=tool}) end
   tools[#tools+1]={name=tool,description=spec.description,input_schema_json=json.encode(spec.schema)}
  end
  table.sort(tools,function(a,b)return a.name<b.name end)
  return {ok=true,tools=tools,schema_hash=host.sha256(json.encode(tools))}
 end
 if input.action=='probe' or input.action=='list' then return probe() end
 local tool=tostring(input.tool or '')
 local cap=(server.native or {})[tool]
 if not cap then return fail('mcp_tool_not_approved') end
 local args=input.arguments
 if args==nil and type(input.arguments_json)=='string' then args=decode(input.arguments_json) end
 args=type(args)=='table' and args or {}
 -- The MCP tool names are older than the capability names; translate the fields the caller knows
 -- (`conversation_id`, `n`, `query`) onto the capability's own (`chat`, `limit`, `q`) and drop what
 -- the capability does not take, so a tool call is the same question whichever door asked it.
 local known=NATIVE_TOOLS[tool]
 if not known then return fail('mcp_native_tool_unknown',{tool=tool}) end
 args=M.native_arguments(tool,args)
 local answer
 if cap=='identity' then answer=native_identity(server)
 elseif NATIVE_CAPS[cap] then
  if type(host[cap])~='function' then return fail(cap..'_unavailable',{tool_call_issued=false}) end
  local ok,raw=pcall(host[cap],json.encode(args))
  if not ok then return fail(cap..'_failed',{detail=tostring(raw):sub(1,160)}) end
  answer=decode(raw)
  if type(answer)~='table' then return fail(cap..'_answer_unreadable') end
 else return fail('mcp_native_capability_unknown') end
 local ok=answer.ok~=false and answer.error==nil
 return {ok=ok,error=answer.error,tool_call_issued=true,session_mode='native',
  result={structuredContent=answer,content={{type='text',text=json.encode(answer)}}}}
end
M.invoke_native=invoke_native
M.invoke_component=invoke_component
function M.invoke(input,ctx)
 ctx=ctx or {}
 if input.server and input.server.transport=='native' then return invoke_native(input) end
 if input.server and input.server.transport=='component' then return invoke_component(input) end
 local directory=M.script_dir()
 if input.persistent_read and host.getenv('WA_MCP_SESSION_MODE')~='request' then
  if not directory or not host.read_file(directory..'/mcp-session.mjs') then return fail('mcp_session_not_installed',{outcome='not_submitted',tool_call_issued=false}) end
  return read_sessions.invoke(input,ctx,directory)
 end
 local directory=M.script_dir();if not directory then local missing=M.scripts_missing();missing.error='mcp_script_directory_unbound';return missing end
 local client=directory..'/mcp-client.mjs';if not host.read_file(client)then return fail('mcp_client_not_installed',{tool_call_issued=false,outcome='not_submitted'}) end
 local request=paths.data()..'/mcp/requests/'..host.uuid()..'.json'
 input.result_file=request..'.result.json'
 local vault_env;input.server,vault_env=M.vault_launch(input.server)
 -- A launch that injects a vault value carries the approval it was given. The operator's own probe has
 -- no recorded one yet - it is what records it - so the manifest of this launch is its expectation, and
 -- the kernel still re-reads every byte before it reads a value.
 if vault_env and not input.vault_approval then input.vault_approval=M.vault_manifest(input.server,M.script_dir()) end
 if not host.write_file(request,json.encode(input))then return fail('mcp_request_not_written',{tool_call_issued=false,outcome='not_submitted'}) end
 local timeout=input.server.timeout_seconds or 30
 local start=decode(host.operation('start',json.encode({program=node_program(),args={client,'--request-file',request},cwd=ctx.cwd or platform.cwd(),timeout_seconds=math.min(86400,timeout+3),owner=ctx.session_id or 'mcp-control',vault_env=vault_env,vault_approval=input.vault_approval})))
 if not start or start.error or not start.operation_id then return fail('mcp_operation_not_started',{detail=start,tool_call_issued=false,outcome='not_submitted',request=request}) end
 local id=start.operation_id
 local settled=decode(host.operation('await',json.encode({id=id,wait_for='settled'})))
 if not settled or settled.error or not settled.settled then
  pcall(host.operation,'cancel',json.encode({id=id}));return fail('mcp_operation_unsettled',{operation_id=id,request=request,tool_call_issued=input.action=='call',outcome=input.action=='call' and 'unknown' or 'not_submitted'})
 end
 local raw=settled.stdout_path and host.read_file(settled.stdout_path);local answer=decode(raw)
 if answer and (settled.ok==false or settled.error or settled.code and settled.code~=0) then
  return fail('mcp_operation_failed',{observed=answer,operation=settled,operation_id=id,request=request,tool_call_issued=input.action=='call',outcome=input.action=='call' and 'unknown' or 'not_submitted'})
 end
 if answer and answer.result_path then
  if answer.result_path~=input.result_file then return fail('mcp_result_path_mismatch',{operation_id=id,outcome='unknown',tool_call_issued=input.action=='call'}) end
  local retained=host.read_file(answer.result_path)
  if not retained or #retained~=answer.result_bytes or host.sha256(retained)~=answer.result_sha256 then return fail('mcp_result_artifact_unverified',{operation_id=id,outcome='unknown',tool_call_issued=input.action=='call'}) end
  answer.evidence={path=input.result_file,sha256=answer.result_sha256,bytes=answer.result_bytes}
  local parsed=decode(retained)
  if parsed then parsed.evidence=answer.evidence end
  answer=parsed
 end
 if not answer then return fail('mcp_operation_result_unreadable',{operation_id=id,request=request,tool_call_issued=input.action=='call',outcome=input.action=='call' and 'unknown' or 'not_submitted'}) end
 answer.operation_id=id;answer.request=request
 return answer
end
function M.close_read_sessions()return read_sessions.close() end
function M.inventory()
 local store=load_store();local servers={}
 for id,row in pairs(store.servers)do
  -- A stale connector is still enabled: the call it refused changed nothing about the operator's decision.
  -- Saying so here is what makes the refusal actionable instead of looking like a connector that went away.
  local observed=row.probe_stale and ('enabled, but its tool list changed since the last probe ('..tostring(row.probe_stale.error or 'schema_changed')..') - re-probe to approve it')
   or (row.probe and (row.probe.ok and 'last probe passed' or 'last probe failed') or 'not verified')
  local definition,probe,last_call=row.definition,row.probe,row.last_call
  -- A RETIRED connector (the WhatsApp family, since 11/11) is not a failing one: its program was removed
  -- from this tree, and what its last probe recorded - the command line with port 28787/8787, "stopped,
  -- port held by space-serve", "down ~37h" - is not a fact about this node any more. The row keeps what
  -- identifies it and what it used to offer, and drops the words that read as a live incident: measured
  -- 13/11, session b393f280 spent ten rounds chasing them instead of using the one surface.
  if M.whatsapp_family(id) then
   local kept={}
   for key,value in pairs(type(definition)=='table' and definition or {})do
    if key~='program' and key~='args' and key~='env' then kept[key]=value end
   end
   kept.retired=true
   definition=kept
   probe=type(probe)=='table' and {ok=false,retired=true,tools=probe.tools} or nil
   last_call=nil
   observed='retired: the Go connector was removed on 11/11; WhatsApp is mcp_whatsapp_*'
  end
  -- vault_approved: the operator has started this connector at its own terminal, which is what lets the
  -- kernel inject the entry it names (M.names_vault). Carried here so /mcp can say which state a connector
  -- that names vault entries is in; absent for every definition that names none.
  servers[#servers+1]={id=id,name=row.definition.name or id,definition=definition,enabled=row.enabled==true,revision=row.revision,
   probe=probe,probe_stale=row.probe_stale,last_call=last_call,session_mode='read-reuse/write-request',observed_status=observed,
   vault_approved=(M.names_vault(row.definition) and (row.vault_approved==true or nil)) or nil}
 end
 table.sort(servers,function(a,b)return a.id<b.id end)
 return {ok=true,revision=store.revision,servers=servers,templates={},can_manage=true,schema_faults=M.SCHEMA_FAULTS,
  adapters={{id='whatsapp',name='WhatsApp',profile_managed=true,capabilities={'scoped linked-device journal reads','explicit self/target identity','draft visibility unsupported; general sends refused'},note='Linked-device connector only. Private deterministic transcript policy is activated by the operator separately; no generic send authority, Chrome fallback or automatic wake.'}},
  note='Explicit trusted connectors; last probe is not live health. Approved reads may reuse idle-bounded sessions; writes and WhatsApp stay request-scoped. Jobs owns wakes.'}
end
-- The model's `mcp` list (operator 17/11): one compact row per connector - what it is, how it starts and
-- which tools it approved - instead of the inventory, which carried each tool's schema in the probe, the
-- stale probe and the definition (140 KB for two servers). Schemas are searchTools' job; `id` gives that
-- one connector's full inventory row.
function M.summary(id)
 local inventory=M.inventory();local rows={}
 for _,server in ipairs(inventory.servers or {})do
  if id==nil or server.id==id then
   if id~=nil then return {ok=true,revision=inventory.revision,server=server} end
   local d=type(server.definition)=='table' and server.definition or {}
   local tools=type(d.tools)=='table' and d.tools or {}
   local count=0;for _ in pairs(tools)do count=count+1 end
   rows[#rows+1]={id=server.id,name=server.name,enabled=server.enabled,transport=d.transport,program=d.program,args=d.args,url=d.url,
    tools=tools,tool_count=count,status=server.observed_status,revision=server.revision}
  end
 end
 if id~=nil then return fail('unknown_mcp_connector',{id=id}) end
 return {ok=true,revision=inventory.revision,servers=rows,
  note='One row per connector. Tool schemas: searchTools("select:<names>"); a connector\'s full row: mcp({action:"list",id}).'}
end
function M.control(args,ctx)
 args=args or {};ctx=ctx or {};if ctx.role~='master' and ctx.role~='admin' then return fail('forbidden') end
 if ctx.subagent then return fail('mcp_management_forbidden_for_subagent') end
 local action=args.action or 'list';if action=='list' then return M.inventory() end
 local store,raw=load_store()
 if args.expected_revision~=store.revision then return fail('mcp_store_revision_changed',{revision=store.revision}) end
 if action=='put' then
  local problem=M.validate(args.definition);if problem then return fail(problem) end
  local vault=M.names_vault(args.definition)
  -- Read it the other way round: no operator context and no peer means a MODEL asked. A definition that
  -- makes the kernel inject a vault value is never a model's to write.
  if vault and not ctx.operator and not ctx.peer then return vault_gate({definition=args.definition},ctx,args.definition.id) end
  return mutate(raw,function(current)
   local old=current.servers[args.definition.id]
   -- Inert either way: even the operator's own definition carries no approval until the operator starts it
   -- (/mcp <id> probe, then on), so a registry written by an older binary - or by a peer's import - cannot
   -- become a launch path by itself.
   current.servers[args.definition.id]={definition=args.definition,enabled=false,vault_approved=false,revision=(old and old.revision or 0)+1}
   return {ok=true,id=args.definition.id,enabled=false,vault_env=vault or nil,
    note=(vault and ('names a vault entry: inert until the operator approves it (/mcp '..args.definition.id..' probe, then on)') or nil)}
  end)
 end
 local row=store.servers[args.id];if not row then return fail('unknown_mcp_server') end
 if action=='remove' then
  -- Removal is the one action that leaves nothing to inspect, so it refuses an enabled connector:
  -- turn it off first, which is already durable and visible, and then drop the dead definition.
  if row.enabled then return fail('mcp_server_enabled_disable_first') end
  return mutate(raw,function(current)current.servers[args.id]=nil;return {ok=true,id=args.id,removed=true}end)
 end
 if action=='enable' or action=='disable' then
  -- The manifest the operator's "on" records, computed ONCE: the coverage refusal comes before the
  -- registry is touched, and the row stores the same digest that was checked.
  local approval
  if action=='enable' then
   local gate=vault_gate(row,ctx,args.id);if gate then return gate end
   if ctx.operator and M.names_vault(row.definition) then
    approval=M.vault_manifest(row.definition,M.script_dir())
    local uncovered=coverage_refusal(args.id,approval);if uncovered then return uncovered end
   end
  end
  if action=='enable' and (not row.probe or row.probe.ok~=true or not row.probe.schema_hash)then return fail('mcp_probe_required') end
  if action=='enable' then
   local found,total={},0;for _,tool in ipairs(row.probe.tools or {})do if row.definition.tools[tool.name] then found[tool.name]=true;total=total+#(tool.input_schema_json or '')+#tostring(tool.description or '') end end
   for name in pairs(row.definition.tools)do if not found[name] then return fail('mcp_approved_tool_missing:'..name) end end
   if total>131072 then return fail('mcp_selected_schema_budget_exceeded',{bytes=total,maximum=131072}) end
  end
  return mutate(raw,function(current)
   current.servers[args.id].enabled=action=='enable'
   if action=='enable' then
    current.servers[args.id].probe_stale=nil
    -- The operator's own "on" is the approval a vault connector waits for - and it records WHAT it
    -- approves (M.vault_manifest), so a script or an argument changed later voids it.
    if ctx.operator and M.names_vault(row.definition) then
     current.servers[args.id].vault_approved=true
     current.servers[args.id].vault_approval=approval or M.vault_manifest(current.servers[args.id].definition,M.script_dir())
    end
   end
   return {ok=true,id=args.id,enabled=action=='enable',vault_approved=current.servers[args.id].vault_approved==true or nil}
  end)
 elseif action=='probe' then
  -- The gate is BEFORE invoke: an unapproved vault connector is never launched, so the value is never
  -- handed to a program a model chose.
  local gate=vault_gate(row,ctx,args.id);if gate then return gate end
  -- A probe is the operator's own act and what records the approval, so the coverage check is here too:
  -- nothing is probed, and no digest is recorded, for a connector whose code cannot be closed.
  local approval
  if ctx.operator and M.names_vault(row.definition) then
   approval=M.vault_manifest(row.definition,M.script_dir())
   local uncovered=coverage_refusal(args.id,approval);if uncovered then return uncovered end
  end
  local answer=M.invoke({action='probe',server=row.definition,vault_approval=approval},ctx)
  -- A fresh probe is the one operation that may replace the cached catalogue, so it is also what clears a
  -- staleness note: the next call is measured against the list this probe just read.
  local saved=mutate(raw,function(current)
   current.servers[args.id].probe=answer;current.servers[args.id].probe_stale=nil;current.servers[args.id].enabled=false
   if approval then
    current.servers[args.id].vault_approved=true
    current.servers[args.id].vault_approval=approval
   end
   return {ok=true}
  end)
  if not saved.ok then answer.registry_observation_error=saved.error end
  return answer
 end
 return fail('unknown_mcp_action')
end
-- The connector ids whose tools are the WhatsApp surface, and are therefore NOT published through a
-- namespace.
--
-- Since 11/11 (#118) WhatsApp has exactly one surface on every node, `mcp_whatsapp_<verb>`
-- (`lua/core/whatsapp.lua`), with the same names everywhere and no hash suffix. A registry connector
-- in this family - `whatsapp_native`, `whatsapp_wasm`, `whatsapp` - would publish the same questions a
-- second time as `mcp_whatsapp_native_read_newest_47452e4e`, which is the spelling a model burned six
-- calls on before guessing a phone number (session 570a0da0). It stays in the registry, it can still be
-- probed and its rows can still be disabled by the operator, but its tools are not offered to the model
-- and a call to one is refused with the name to use instead. The half that `mcp_command.lua` shows is
-- the `/mcp` view, which says `superseded_by_mcp_whatsapp` rather than pretending they are callable.
function M.whatsapp_family(id)
 return type(id)=='string' and (id=='whatsapp' or id:sub(1,9)=='whatsapp_')
end
-- Every connector tool's schema this node could not read, by catalogue name, from the last
-- `M.schemas()`: `{name=..., connector=..., error='mcp_cached_schema_invalid'}`.
--
-- A cached probe whose `inputSchema` cannot be read as a JSON object is a tool nobody can call safely:
-- the schema is what guards its arguments, and offering it without one invites a call the server refuses
-- (or worse, one it accepts and should not have). So it is not offered - and the reason is kept HERE
-- rather than thrown, because one connector's bad cache must not take the node's whole tool list down
-- with it. `M.inventory()` carries the list, so `/mcp` can say which connector to re-probe.
M.SCHEMA_FAULTS = {}
function M.schema_faults() return M.SCHEMA_FAULTS end

function M.schemas()
 local ready=query("SELECT name FROM sqlite_master WHERE type='table' AND name='meta'",{})
 if #ready==0 then return {} end -- schema-only bootstrap, not a cached empty store
 local store=load_store();local schemas,seen={},{};M.SCHEMA_FAULTS={}
 for id,row in pairs(store.servers)do if row.enabled and row.probe and row.probe.ok and not M.whatsapp_family(id) then
  for _,tool in ipairs(row.probe.tools or {})do if row.definition.tools[tool.name] then
   local name=M.namespace(id,tool.name);if seen[name]then error('mcp_namespace_collision') end;seen[name]=true
   -- The server's own bytes, kept exactly (`json.raw` is the validated raw-JSON carrier: a pydantic
   -- server stamps `$schema`/`$defs` inside its `inputSchema` and they must travel untouched), and a
   -- payload that is not a JSON object is refused BY NAME instead of published as an empty schema.
   -- Publishing `properties: {}` for a tool whose server declares properties is what made a model guess
   -- argument names on 13/11 (three refusals before it found `q`); a fault says which connector is
   -- unreadable, which is what the operator can act on. `scripts/test-tool-schema-fidelity.lua` proves
   -- the declaration reaches `searchTools`/`describeTool` intact.
   local ok,parameters=pcall(json.raw,tool.input_schema_json)
   if ok and type(parameters)=='table' then
    schemas[#schemas+1]={type='function',['function']={name=name,description='MCP '..id..' / '..tool.name..': '..tostring(tool.description or ''),parameters=parameters}}
   else
    M.SCHEMA_FAULTS[#M.SCHEMA_FAULTS+1]={name=name,connector=id,tool=tool.name,error='mcp_cached_schema_invalid'}
   end
  end end
 end end
 table.sort(schemas,function(a,b)return a['function'].name<b['function'].name end);return schemas
end
-- The `outputSchema` each offered connector tool declared at its last probe, by catalogue name (the
-- probe keeps the server's whole tool object, `mcp-client-core.mjs`/`components.rs`). Read only to print
-- a return shape in the connector index (lua/core/return_shapes.lua); never part of the catalogue, so
-- the declaration hash and what the provider is sent stay exactly as they were.
function M.output_schemas()
 local out={}
 local ready=query("SELECT name FROM sqlite_master WHERE type='table' AND name='meta'",{})
 if #ready==0 then return out end
 local store=load_store()
 for id,row in pairs(store.servers)do if row.enabled and row.probe and row.probe.ok and not M.whatsapp_family(id) then
  for _,tool in ipairs(row.probe.tools or {})do
   if row.definition.tools[tool.name] and type(tool.outputSchema)=='table' then out[M.namespace(id,tool.name)]=tool.outputSchema end
  end
 end end
 return out
end
function M.resolve_tool(name)
 local store=load_store()
 for id,row in pairs(store.servers)do if row.enabled and row.probe and row.probe.ok and not M.whatsapp_family(id) then
  for _,tool in ipairs(row.probe.tools or {})do if M.namespace(id,tool.name)==name and row.definition.tools[tool.name] then return id,row,tool,store end end
 end end
end
-- The one-surface replacement for a name this module no longer publishes: nil when the name is not a
-- WhatsApp connector's tool, and the `mcp_whatsapp_<verb>` to use when it is (`lua/core/whatsapp.lua`
-- owns the mapping, so the two cannot disagree).
function M.whatsapp_replacement(name)
 if type(name)~='string' or name:sub(1,4)~='mcp_' then return nil end
 local store=load_store()
 for id,row in pairs(store.servers)do if M.whatsapp_family(id) and row.probe then
  for _,tool in ipairs(row.probe.tools or {})do if M.namespace(id,tool.name)==name then
   local ok,replacement=pcall(function() return dofile('lua/core/whatsapp.lua').renamed(name) end)
   return ok and replacement or nil
  end end
 end end
end
function M.is_read(name)local id,row,tool=M.resolve_tool(name);return id~=nil and row.definition.tools[tool.name]=='read' end
-- What one tool call may change in the registry.
--
-- A call is evidence about the connector; it is never a reason to reverse the operator's decision. Until
-- 10/11 the call below did the opposite: an answer of `mcp_tool_schemas_changed` set `enabled=false` and
-- threw the cached probe away, so a connector the operator had enabled came back DISABLED with its tools
-- gone from the catalogue and nothing to re-enable it but a manual probe - measured on this node after a
-- deploy, where a cached probe that no longer matched the running runtime was reported exactly that way.
-- The refusal itself is safe and unchanged: `mcp_tool_schemas_changed` is answered before dispatch
-- (`tool_call_issued=false`), so nothing is issued against a catalogue nobody approved. What changes is the
-- side effect: the enable decision stays, the cached probe stays (its tools are still the approved ones),
-- and the staleness is recorded so `/mcp` and the inventory can say "re-probe" instead of "disabled".
-- A later passing call proves the catalogue matches again, and a probe or an enable clears the note.
function M.record_call(entry,answer)
 if type(entry)~='table' then return entry end
 answer=answer or {}
 entry.last_call={at=host.now(),ok=answer.ok,error=answer.error,outcome=answer.outcome,operation_id=answer.operation_id}
 if answer.error=='mcp_tool_schemas_changed' or answer.error=='mcp_catalogue_changing' then
  entry.probe_stale={at=host.now(),error=answer.error,operation_id=answer.operation_id}
 elseif answer.ok==true then
  entry.probe_stale=nil
 end
 return entry
end
function M.call(name,args,ctx)
 local id,row,tool=M.resolve_tool(name);if not id then return fail('mcp_tool_not_approved') end
 -- Defence in depth: enable already refuses an unapproved vault connector, so a row that reaches here was
 -- approved by an operator - unless the registry was written before this gate existed. Then it refuses.
 local unapproved=vault_gate(row,ctx,id);if unapproved then return unapproved end
 local options={action='call',server=row.definition,tool=tool.name,schema_hash=row.probe.schema_hash}
 -- The approval the kernel re-checks (docs/VAULT.md): the STORED digest, never one recomputed here, so an
 -- edit between this check and the launch is still caught by the bytes on disk.
 if M.names_vault(row.definition) then options.vault_approval=row.vault_approval end
 if row.definition.tools[tool.name]=='read' then
  options.persistent_read=true;options.read_tools={}
  for allowed,effect in pairs(row.definition.tools)do if effect=='read' then options.read_tools[#options.read_tools+1]=allowed end end
  table.sort(options.read_tools)
 end
 if ctx and ctx.tool_arguments_json then options.arguments_json=ctx.tool_arguments_json elseif next(args or {})then options.arguments=args end
 local answer=M.invoke(options,ctx)
 local current,raw=load_store();local same=current.servers[id]
 if same and same.revision==row.revision then
  local recorded=mutate(raw,function(value)
   local entry=M.record_call(value.servers[id],answer)
   return {ok=true,probe_stale=entry.probe_stale}
  end)
  if not recorded.ok then answer.registry_observation_error=recorded.error end
  if recorded.ok and recorded.probe_stale then answer.probe_stale=recorded.probe_stale end
 end
 return M.project(answer)
end
-- Catalogue/transport evidence stays exact on disk, outside ordinary model replies.
function M.project(answer)
 local out={ok=answer.ok,error=answer.error,phase=answer.phase,rpc_error=answer.rpc_error,outcome=answer.outcome,tool_call_issued=answer.tool_call_issued,evidence=answer.evidence,
  session_mode=answer.session_mode,reused=answer.reused,unsupported_content_types=answer.unsupported_content_types,content_delivery=answer.content_delivery,registry_observation_error=answer.registry_observation_error,
  reconciled=answer.reconciled,probe_stale=answer.probe_stale}
 if answer.result_json then out.result=json.raw(answer.result_json) elseif answer.result then out.result=answer.result end
 if not answer.evidence and not answer.result_json and not answer.result then out.detail=answer end
 return out
end
-- The WhatsApp facade (M.whatsapp) is gone with the Node bridge it spawned (10/11), and so is the
-- operator route that briefly replaced its send (retired 14/11, `lua/core/whatsapp.lua` M.RETIRED):
-- sends go through the one surface (`mcp_whatsapp_send`, gated by /approve) and reads through the
-- native index or the wa-whatsapp component. There is no MCP server in this process for WhatsApp.
return M
