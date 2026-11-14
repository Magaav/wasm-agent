-- What a refusal tells the model: the code, the real cause, the offending input, the fix.
--
-- MEASURED, 13/11, on node `work`. A code-mode call with no argument failed with
-- `json_contract_invalid:json_number_invalid` (json_contract.lua:44) - three modules from its cause,
-- the component loop handing the parser the text `undefined` - and the model spent about five calls
-- finding it. Then `notes_write` called as `{content="..."}` answered `notes_text_required` and
-- nothing else: the accepted name (`text`) appeared nowhere in the answer, and the model guessed
-- three times. A third case, `schema_extra:arguments.foo`, named the extra argument and not one name
-- the tool does take.
--
-- THE CONTRACT, applied ONCE - here - at the boundary every refusal crosses: `tools.dispatch`,
-- both code-mode loops (`native_run` and `component_run` in lua/core/codemode.lua) and the seam's
-- refusal rendering. No site copies these sentences; a site that knows something extra passes it in
-- and this module renders it.
--
--   error    the stable code a test or a client already matches. NEVER renamed here.
--   message  one sentence naming the real cause AND the module that refused it, so the model does not
--            chase the layer that noticed the problem.
--   input    the offending value or argument text, bounded to MAX_INPUT characters, redacted.
--   fix      what to change, naming something that exists: the accepted argument names from the
--            tool's own schema, the range, the allowed actions, an example, the peers online.
--
-- TWO TIERS, because this node has 493 refusal codes and inventing a cause for one of them would be
-- the same lie in a nicer place: a code listed in CODES is described from its own site (read the
-- comment there); everything else is described by the shape of its name - `*_required` is a missing
-- argument, `*_must_be_*` states the rule it broke - which asserts nothing the code does not already
-- say. `M.tier(code)` answers which one a code got, and scripts/test-refusal-contract.lua prints both
-- counts, so promoting a code is a visible change and never a silent one.
local contract=dofile('lua/core/json_contract.lua')
local M={}

M.MAX_INPUT=80
M.MAX_MESSAGE=300
M.MAX_FIX=300

-- Origin of a code: which module raises it. Generated from the source by scripts/gen-refusal-codes.lua
-- and checked for staleness by the gate test, so a message can say where the refusal came from without
-- every site repeating it. The map is a hint by construction: a code raised in two modules names the
-- first, and the hint never changes the code.
local ORIGIN={}
do
 local ok,map=pcall(dofile,'lua/core/refusal_codes.lua')
 if ok and type(map)=='table' then ORIGIN=map end
end
M.ORIGIN=ORIGIN

-- A refusal is read by a model, so every value in it is one line: newlines and tabs collapse, a long
-- value is cut at MAX_INPUT with an ellipsis, and credentials the node knows (or a token shaped like
-- one) never travel - a model that needs a file's contents reads the file, not its refusal.
local function redacted(text)
 local redact=package.loaded['refusal_redact']
 if not redact then
  local ok,module=pcall(dofile,'lua/core/redact.lua')
  redact=ok and module or nil
  package.loaded['refusal_redact']=redact
 end
 if redact and redact.text then
  local ok,clean=pcall(redact.text,text)
  if ok and type(clean)=='string' then return clean end
 end
 return text
end

local function one_line(value)
 local text=tostring(value==nil and '' or value):gsub('[%c]+',' ')
 return (text:gsub('^%s+',''):gsub('%s+$',''))
end

local function bounded(value,limit)
 local text=redacted(one_line(value))
 limit=limit or M.MAX_INPUT
 if #text>limit then return text:sub(1,limit-3)..'...' end
 return text
end
M.bounded=bounded

-- `unknown_node:box` -> code `unknown_node`, detail `box`. A refusal whose whole `error` is a sentence
-- (`retired: batch in code mode - ...`) splits the same way, and its code keeps the sentence's first
-- word: the code is never rewritten, only read.
local function split(code)
 local text=tostring(code or '')
 local head,detail=text:match('^([^:%s]+)%s*:%s*(.*)$')
 if head then
  if detail=='' then detail=nil end
  return head,detail
 end
 return text,nil
end
M.split=split

-- `wake_at_must_be_unix_epoch_seconds` reads as the rule it is. Codes are lower case words joined by
-- underscores, so the words are already a sentence: no table needed to say what the rule broke.
local function words(code)
 return (tostring(code or ''):gsub('_',' '))
end
M.words=words

local function fill(template,vars)
 return (template:gsub('{([%w_]+)}',function(key)
  local value=vars[key]
  if value==nil then return '' end
  return tostring(value)
 end))
end

-- The argument names a tool takes, from the tool's own schema: `text (string, required)`. This is the
-- fix for every schema refusal, so it is composed from the schema rather than written per site - and
-- it cannot name an argument the tool does not have.
local function schema_type(schema)
 if type(schema)~='table' then return nil end
 local kinds=schema.type
 if type(kinds)=='table' then kinds=table.concat(kinds,'|') end
 local text=kinds and tostring(kinds) or nil
 if schema.nullable then text=(text or 'any')..'|null' end
 if schema.enum then
  local allowed={}
  for _,value in ipairs(schema.enum) do allowed[#allowed+1]=tostring(value) end
  if #allowed>0 then text=(text or 'one of')..' one of: '..table.concat(allowed,'|') end
 end
 if schema.minimum and schema.maximum then text=(text or 'number')..' '..tostring(schema.minimum)..'..'..tostring(schema.maximum)
 elseif schema.minimum then text=(text or 'number')..' >= '..tostring(schema.minimum)
 elseif schema.maximum then text=(text or 'number')..' <= '..tostring(schema.maximum) end
 if schema.minLength and schema.maxLength then text=(text or 'string')..' '..tostring(schema.minLength)..'..'..tostring(schema.maxLength)..' characters'
 elseif schema.maxLength then text=(text or 'string')..' at most '..tostring(schema.maxLength)..' characters'
 elseif schema.minItems then text=(text or 'array')..' at least '..tostring(schema.minItems)..' item(s)' end
 return text
end
M.schema_type=schema_type

function M.accepted(parameters,limit)
 if type(parameters)~='table' or type(parameters.properties)~='table' then return nil end
 local required={}
 for _,name in ipairs(parameters.required or {}) do required[name]=true end
 local names={}
 for name in pairs(parameters.properties) do names[#names+1]=tostring(name) end
 if #names==0 then return nil end
 table.sort(names)
 local parts={}
 for _,name in ipairs(names) do
  if limit and #parts>=limit then parts[#parts+1]='and '..tostring(#names-#parts)..' more';break end
  local kind=schema_type(parameters.properties[name])
  parts[#parts+1]=name..(kind and (' ('..kind..(required[name] and ', required' or '')..')') or (required[name] and ' (required)' or ''))
 end
 return table.concat(parts,', ')
end

-- One schema entry by the path a `schema_*` code records: `schema_type:arguments.edits[1].old_text`.
local function schema_at(parameters,path)
 if type(parameters)~='table' or type(path)~='string' then return nil end
 local cursor=parameters
 local text=path:gsub('^arguments%??%.?','')
 for token in text:gmatch('[^%.%[%]]+') do
  if type(cursor)~='table' then return nil end
  if cursor.properties and cursor.properties[token] then cursor=cursor.properties[token]
  elseif cursor.items and tonumber(token) then cursor=cursor.items
  else return nil end
 end
 return type(cursor)=='table' and cursor or nil
end
M.schema_at=schema_at

-- What the call actually sent at that path: the kind, so a type refusal says "sent string" instead of
-- leaving the model to re-read its own text. Parsed from the argument text the boundary carries.
local function received_kind(text,path)
 if type(text)~='string' or text=='' or type(path)~='string' then return nil end
 local node=contract.parse(text)
 if not node then return nil end
 local cursor=node
 local bare=path:gsub('^arguments%??%.?','')
 for token in bare:gmatch('[^%.%[%]]+') do
  if type(cursor)~='table' then return nil end
  if cursor.kind=='object' then cursor=cursor.children and cursor.children[token]
  elseif cursor.kind=='array' then cursor=cursor.children and tonumber(token) and cursor.children[tonumber(token)]
  else cursor=nil end
  if not cursor then return nil end
 end
 if type(cursor)~='table' then return nil end
 if cursor.kind=='number' then
  if cursor.value%1==0 then return 'integer' end
  return 'number'
 end
 return cursor.kind
end
M.received_kind=received_kind

-- Codes whose cause is read from their own site. Every entry here was written against the code it
-- describes; a wrong sentence is worse than a generic true one, so an entry exists only where the
-- site says what the refusal means.
local CODES={
 -- the argument contract (lua/core/json_contract.lua) - the loop that handed over the text is named
 -- by `{site}`, because "the parser noticed" is never the cause.
 json_text_required={message='{tool} was called with arguments that are not text at all, so nothing was parsed ({origin}).',
  fix='send the arguments as one JSON object{example_clause}.'},
 json_number_invalid={message='the argument text for {tool} is not valid JSON: a number in it is malformed, so the call was refused before dispatch ({origin}; the text came from {site}).',
  fix='send the arguments as one JSON object with no bare words{example_clause}.'},
 json_value_invalid={message='the argument text for {tool} carries a number JSON cannot represent, so the call was refused before dispatch ({origin}; the text came from {site}).',
  fix='send the value as a JSON string, or a number the platform can hold{example_clause}.'},
 json_trailing_data={message='the argument text for {tool} has data after its closing brace, so it is not one JSON object ({origin}; the text came from {site}).',
  fix='send exactly one JSON object: {example}.'},
 json_string_unterminated={message='the argument text for {tool} has a string that never closes, so no argument was read ({origin}; the text came from {site}).',
  fix='close the quote, or drop the unfinished argument, and send one complete JSON object: {example}.'},
 json_member_required={message='the argument text for {tool} has an object member that does not start with a quoted name ({origin}; the text came from {site}).',
  fix='quote every member name{example_clause}.'},
 json_duplicate_member={message='the argument text for {tool} names the same member twice, so which value wins is ambiguous ({origin}).',
  fix='send each member name once: {example}.'},
 json_colon_required={message='the argument text for {tool} has a member name with no colon after it ({origin}; the text came from {site}).',
  fix='put `:` between each name and its value{example_clause}.'},
 json_separator_required={message='the argument text for {tool} is missing the comma between two members or items ({origin}; the text came from {site}).',
  fix='separate members with `,`: {example}.'},
 json_object_unterminated={message='the argument text for {tool} opens an object that never closes, so the call was refused before dispatch ({origin}; the text came from {site}).',
  fix='close every `{` with `}`, and send the object complete: {example}.'},
 json_array_unterminated={message='the argument text for {tool} opens an array that never closes ({origin}; the text came from {site}).',
  fix='close every `[` with `]`: {example}.'},
 json_depth_exceeded={message='the arguments for {tool} nest deeper than 64 levels, which this node refuses to walk ({origin}).',
  fix='send the same value with fewer levels{example_clause}.'},
 json_utf8_invalid={message='the arguments for {tool} carry a string that is not valid UTF-8 ({origin}).',
  fix='re-encode the text as UTF-8, or replace the characters it cannot hold.'},
 json_contract_invalid={message='the arguments for {tool} are not one valid JSON object, so nothing was dispatched ({origin}; the text came from {site}).',
  fix='send one complete JSON object{example_clause}.'},
 json_materialize_key_collision={message='two argument names for {tool} map to the same name, so one value would silently win ({origin}).',
  fix='rename one of the two arguments and send the call again{example_clause}.'},
 schema_unsupported={message='the schema of {tool} uses a JSON-Schema keyword this node does not implement, so it cannot know what the tool accepts and refused the call rather than guess ({origin}).',
  fix='this is a tool-definition problem, not a call problem: report the keyword named in the code; the tool cannot be called until its schema is one this node validates.'},
 schema_extra={message='{tool} does not take the argument `{input}`; the call carried a name that is not in its schema ({origin}).',
  fix='drop `{input}`; {tool} takes {accepted}'},
 schema_required={message='{tool} needs `{input}` and the call did not carry it ({origin}).',
  fix='send `{input}`: {tool} takes {accepted}'},
 schema_type={message='{tool} takes `{input}` as {expected}, and the call sent {received} ({origin}).',
  fix='send `{input}` as {expected}: {tool} takes {accepted}'},
 schema_enum={message='`{input}` for {tool} is not one of the values it accepts ({origin}).',
  fix='send one of {expected} for `{input}`: {tool} takes {accepted}'},
 schema_range={message='`{input}` for {tool} is outside the range it accepts ({origin}).',
  fix='send `{input}` within {expected}: {tool} takes {accepted}'},
 schema_length={message='`{input}` for {tool} is the wrong length for what it accepts ({origin}).',
  fix='send `{input}` within {expected}: {tool} takes {accepted}'},
 schema_items={message='`{input}` for {tool} carries the wrong number of items ({origin}).',
  fix='send `{input}` within {expected}: {tool} takes {accepted}'},
 schema_anyof={message='the arguments for {tool} match none of the call shapes it accepts, and `{input}` is the first place they part ({origin}).',
  fix='send one of the accepted shapes; {tool} takes {accepted}.'},
 schema_number={message='`{input}` for {tool} is a number the platform cannot hold ({origin}).',
  fix='send `{input}` as a finite number: {tool} takes {accepted}'},

 -- code mode itself
 invalid_tool_arguments_json={message='the arguments sent for {tool} are not one valid JSON object, so nothing ran ({origin}).',
  fix='send {tool} one complete JSON object: {example}.'},
 codemode_source_required={message='the script is empty or not text, so there was nothing to run ({origin}).',
  fix='send `code` as the script body, or a single expression to return.'},
 codemode_target_not_available={message='this target cannot be called from inside a script: it runs outside code mode, or it is not one of the tools this node allows there ({origin}).',
  fix='call it as an ordinary tool call, or ask `searchTools("*")` which tools a script may call - each one answers `callable`.'},
 codemode_global_not_available={message='no script global is named `{input}` ({origin}).',
  fix='the globals a script has are `searchTools`, `results`, `wait`, `cancel`, `pending`, `describeTool`, `showCall`, `capabilities` and `describe`, plus one member per callable tool on `tools`.'},
 codemode_identifier_collision={message='two tool names become the same script identifier, so `tools.{input}` would be ambiguous ({origin}).',
  fix='call the ambiguous target by its exact name through `searchTools("select:<name>")`, or use the other tool of the pair.'},
 tool_definition_changed={message='the definition of {tool} changed after the script started, so the arguments it validated are no longer the ones the tool takes ({origin}).',
  fix='run the script again: the tool is re-read at the start of every script, and the arguments must match its current schema.'},
 tool_search_query_required={message='`searchTools` needs a search text or one of its own forms, and the call passed a value it cannot read as one ({origin}).',
  fix='call `searchTools("text")`, `searchTools("*")` for the listing, `searchTools({names:[...]})` for an exact batch, or `searchTools("select:a,b")`.'},
 invalid_tool_search_limit={message='the `limit` given to `searchTools` is outside the range it accepts ({origin}).',
  fix='send `limit` between 1 and 200 for a listing, or between 1 and 8 for a batch of names.'},
 invalid_tool_search_names={message='`searchTools` was given a batch of names it cannot use: it must be a non-empty array of at most 8 names ({origin}).',
  fix='send `{names:["read","bash"]}` - 1 to 8 exact tool names.'},
 tool_search_arguments_exclusive={message='`searchTools` was given a query and a batch of names at the same time ({origin}).',
  fix='send either `searchTools("text")` or `searchTools({names:[...]})`, never both.'},
 codemode_pending_limit={message='this script already holds the maximum number of open pending calls ({origin}).',
  fix='settle an open call with `wait(op)` or drop it with `cancel(op)` before starting another, or run the calls in series.'},
 invalid_wait_s={message='`wait_s` is not a number of seconds this node accepts ({origin}).',
  fix='send `wait_s` as a non-negative number of seconds, e.g. `{wait_s:120}`.'},
 wait_requires_an_op_or_a_list={message='`wait` was called without an op handle or a list of them ({origin}).',
  fix='call `wait(op)`, or `wait([op1,op2])` with at most 8 handles - a handle is what a call still running answered as `{state:"pending",op}`.'},
 wait_until_must_be_all_or_any={message='`wait` took an `until` value that is neither "all" nor "any" ({origin}).',
  fix='send `until:"all"` or `until:"any"`.'},
 cancel_requires_an_op_or_a_list={message='`cancel` was called without an op handle or a list of them ({origin}).',
  fix='call `cancel(op)`, or `cancel([op1,op2])` with at most 8 handles.'},
 not_cancellable={message='the call named here cannot be cancelled once it has started ({origin}).',
  fix='let it settle and read its result with `wait(op)`; a call that reached the client stays sent.'},
 unknown_op={message='no pending call this script started has that handle ({origin}).',
  fix='use the `op` value a still-running call returned, or ask `pending()` for the open ones.'},
 no_executor={message='the operation behind this handle has no executor on this node, so it can never settle ({origin}).',
  fix='drop the handle: the effect of the call is unknown and it can never be replayed.'},
 finished={message='the call this handle names had already settled when `cancel` reached it ({origin}).',
  fix='read the settled result with `wait(op)`; nothing more is needed.'},
 result_not_retained={message='the call settled but its result was not retained, so it cannot be read again ({origin}).',
  fix='run the call again if the value is needed; the refused call is reported in `calls`.'},
 results_requires_an_object={message='`results()` was called with something other than its own argument object ({origin}).',
  fix='call `results.get(hashOrOp)`, `results.last(4)`, `results.diff(a,b)` or `results.reuse(tool,{max_age_s})`.'},
 results_get_requires_a_sha256_or_op={message='`results.get` was given neither a 64-character sha256 nor an op handle ({origin}).',
  fix='pass the `sha256` from an earlier result reference, or the `op` of a pending call.'},
 results_get_unknown_op={message='`results.get` named an op this script never started ({origin}).',
  fix='ask `pending()` for the open handles, or `results.last(4)` for the settled ones.'},
 results_last_requires_n_1_to_50={message='`results.last` was asked for a count outside the range it keeps ({origin}).',
  fix='send a whole number of results between 1 and 50, or call `results.last()` for the last one.'},
 results_diff_requires_two_sha256={message='`results.diff` needs two result references and got fewer ({origin}).',
  fix='call `results.diff(sha256A,sha256B)` with two hashes from earlier results.'},
 results_reuse_requires_a_tool={message='`results.reuse` was called without a tool name ({origin}).',
  fix='call `results.reuse("read",{max_age_s:600})` - the tool name first.'},
 results_reuse_requires_max_age_s={message='`results.reuse` was called without a positive `max_age_s` ({origin}).',
  fix='send `max_age_s` as a positive number of seconds: how old a repeated result may be.'},

 -- the dispatcher and the tools it reaches
 unknown_tool={message='this node has no tool named `{input}` (or the role does not permit it) ({origin}).',
  fix='ask `searchTools("*")` for the names that exist, or `searchTools("{input}")` for the nearest ones; every entry answers whether it is callable.'},
 retired={message='the batch tool `{tool}` was retired: code mode is the batch ({origin}).',input_from='tool',origin='retired.lua',
  fix='call the single tool once per item inside a script - `Promise.all(items.map(x => tools.<name>(x)))` for reads, a serial loop for effects; the message names the replacement call.'},
 forbidden_for_role={message='the role `{input}` may not call {tool} on this node ({origin}).',
  fix='this is an authority decision, not an argument: a master session can, and `capabilities()` lists what this role may read.'},
 forbidden={message='the caller is not allowed this record: it belongs to another user ({origin}).',
  fix='work with a session or record this caller owns, or ask a master session to do it.'},
 hook_denied={message='a configured hook refused this call before it ran, so nothing happened ({origin}).',
  fix='read `reason` for the hook\'s own words and change the call to satisfy it; the hook file names its rule.'},
 canonical_checkout_protected={message='the canonical checkout is a shared resource and this session does not hold the landing lease ({origin}).',
  fix='work in your own worktree: `git worktree add ../wt-<mission> -b change/<name> origin/main`; edits and git verbs in the canonical tree belong to the landing queue.'},
 session_workspace_unavailable={message='this session has no usable workspace, so a file or shell write has nowhere to land ({origin}).',
  fix='allocate or recover the workspace first (`session_worktree` reports its state), or work inside the node\'s own checkout with a path there.'},
 workspace_managed={message='this session is bound to a managed workspace and the file lives outside it ({origin}).',
  fix='write inside the bound workspace, or ask for the file\'s own workspace session; the binding is the boundary, not a suggestion.'},
 workspace_path_outside_binding={message='the path is outside the workspace this session is bound to ({origin}).',
  fix='use a path inside the bound workspace, or a session bound to the tree you mean.'},
 workspace_cwd_outside_binding={message='the shell `cwd` is outside the workspace this session is bound to ({origin}).',
  fix='set `cwd` inside the bound workspace, or run the command in a session bound to that tree.'},
 workspace_execution_context_unsupported={message='{tool} cannot prove which workspace its effect would land in, so it was refused rather than guessing ({origin}).',
  fix='use a tool that takes an explicit `cwd` or `path` inside the bound workspace.'},
 path_required={message='{tool} needs `path` and the call did not carry it as a non-empty string ({origin}).',
  fix='send a `path`: {tool} takes {accepted}'},
 command_required={message='{tool} needs `command` and the call did not carry it as a non-empty string ({origin}).',
  fix='send the shell command as `command`, e.g. `{"command":"git status --short"}`.'},
 content_required={message='{tool} needs `content` as a string and the call did not carry one ({origin}).',
  fix='send the whole file body as `content` (a string, empty allowed only where the tool says so).'},
 name_required={message='{tool} needs `name` and the call did not carry one ({origin}).',
  fix='{available_sentence}'},
 id_required={message='{tool} needs `id` and the call did not carry one ({origin}).',
  fix='send the identifier the tool asked for as `id`.'},
 session_id_required={message='{tool} needs `session_id` and the call did not carry one ({origin}).',
  fix='send the session id, as `sessions()` lists it.'},
 pattern_required={message='`grep` needs `pattern` and the call did not carry one ({origin}).',
  fix='send the search pattern as `pattern` (a Lua pattern), plus `path` to search there.'},
 node_required={message='`update` needs a node name and the call did not carry one ({origin}).',
  fix='{available_sentence}'},
 session_required={message='{tool} needs a session and the call did not carry one it can find ({origin}).',
  fix='send `session_id` as `sessions()` lists it.'},
 prompt_required={message='{tool} needs `prompt` and the call did not carry one ({origin}).',
  fix='send the task text as `prompt`.'},
 query_required={message='{tool} needs a search text and the call did not carry one ({origin}).',
  fix='send the text to search for as `query`.'},
 text_required={message='{tool} needs `text` and the call did not carry it ({origin}).',
  fix='send {tool} a `text`: {accepted}'},
 reason_required={message='{tool} needs `reason` and the call did not carry one ({origin}).',
  fix='send one line saying why, as `reason`; a wake without a reason cannot be read back later.'},
 old_text_required={message='an edit needs `old_text` - the exact text to replace - and the call did not carry it ({origin}).',
  fix='send `{"old_text":"<exact bytes from the file>","new_text":"<replacement>"}`, or the range form with `selection`.'},
 new_text_required={message='an edit needs `new_text` as a string and the call did not carry one ({origin}).',
  fix='send `new_text` as the replacement, empty string to delete.'},
 path_kind_unavailable={message='the node cannot tell what kind of file this path is, so a text write was refused ({origin}).',
  fix='write to a path the host can stat, or create the parent directory first.'},
 target_not_readable_text={message='the path exists and is not a text file this node can write ({origin}).',
  fix='write a regular text file; a directory, a device or a binary target is refused here.'},
 not_found={message='the path exists nowhere on this node\'s filesystem view ({origin}).',
  fix='read the parent directory first (`ls` or `read_many`) and use the name that is there.'},
 file_changed={message='the file changed on disk after the version this call was based on, so the written value would be stale ({origin}).',
  fix='read the file again, then send the edit with the `version` the read returned.'},
 file_changed_before_write={message='the file changed between the plan and the write, so nothing was applied ({origin}).',
  fix='read the file again and re-issue the edit against the version just read.'},
 stale_selection={message='the selection receipt was taken from an older version of the file ({origin}).',
  fix='read the file again and copy the new `selection` unchanged into the edit.'},
 selection_required={message='an edit in the range form must carry the `selection` receipt `read` returned ({origin}).',
  fix='read the file, then send each edit with its `selection` copied unchanged and `replacement_lines`.'},
 mixed_edit_forms={message='the edit mixes the two forms: `old_text`/`new_text` and `selection`/`replacement_lines` in one call ({origin}).',
  fix='send ONE form: `{"path","old_text","new_text"}` or `{"path","edits":[{"selection","replacement_lines"}]}`.'},
 edits_required_1_to_64={message='`edits` must be a dense array of 1 to 64 edits and the call sent something else ({origin}).',
  fix='send `edits` as an array of 1 to 64 objects, no nils and no holes.'},
 old_text_not_found={message='`old_text` appears nowhere in the file, so nothing could be replaced ({origin}).',
  fix='read the file and copy the exact bytes to replace, whitespace included.'},
 old_text_ambiguous={message='`old_text` appears more than once in the file, so which one to replace is undecidable ({origin}).',
  fix='include enough surrounding text to make the match unique, or use the range form with a `selection` receipt.'},
 overlapping_edits={message='two edits in the same call touch the same bytes ({origin}).',
  fix='merge them into one edit, or drop the overlapping one.'},
 write_failed={message='the write reached the filesystem and did not succeed; its effect is unknown ({origin}).',
  fix='read the path to see what landed before writing again; a replay of an unknown effect is refused by design.'},
 read_range_out_of_bounds={message='the requested line is past the end of the file ({origin}).',
  fix='ask for a `line` between 1 and the file\'s last line (the refusal carries its `version`).'},
 column_out_of_bounds={message='the requested column is past the end of that line ({origin}).',
  fix='ask for a `column` inside the line, or omit it to read from the start.'},
 column_inside_utf8={message='the requested column lands inside a multi-byte character ({origin}).',
  fix='step to a character boundary: read the line as a whole and index characters, not bytes.'},
 offset_inside_utf8={message='the requested byte offset lands inside a multi-byte character ({origin}).',
  fix='step to a character boundary: use a `line`/`column` read instead of a raw offset.'},
 read_envelope_exceeds_budget={message='one read would return more than the node\'s per-call budget ({origin}).',
  fix='read a smaller range: send `line`/`limit`, or a byte `offset` inside the file.'},
 invalid_read_range={message='a read range was given in a shape this node does not accept ({origin}).',
  fix='send `line` and `column` as whole numbers with a positive `limit`, or omit all three.'},
 invalid_extensions={message='`extensions` must be an array of file-extension strings ({origin}).',
  fix='send `extensions` as `["lua","md"]` - strings, no dots, up to 32 of them.'},
 invalid_ignore_case={message='`ignore_case` must be true or false ({origin}).',fix='send `ignore_case` as a JSON boolean.'},
 invalid_search_path={message='`path` must be a string naming a directory to search ({origin}).',fix='send `path` as a string, or omit it to search the workspace.'},
 invalid_search_range={message='a search range is outside what the search accepts ({origin}).',fix='send whole numbers: `before`/`after` between 0 and 50, `limit` between 1 and 1000.'},
 unsupported_search_option={message='`grep` does not take the option `{input}` ({origin}).',fix='drop `{input}`; grep takes `pattern`, `path`, `ignore_case`, `extensions`, `before`, `after` and `limit`.'},
 unsupported_edit_option={message='`edit` does not take the option `{input}` ({origin}).',fix='drop `{input}`; edit takes `path`, `edits`, `old_text`, `new_text`, `version`.'},
 unsupported_selection_field={message='a `selection` receipt carries a field this node does not accept: `{input}` ({origin}).',fix='copy the `selection` from `read` unchanged; do not add or edit its fields.'},
 invalid_selection={message='the `selection` receipt is not one this node can read ({origin}).',fix='copy the `selection` object from `read` unchanged into the edit.'},
 selection_hash_mismatch={message='the selection\'s text does not match the hash in its receipt, so it was edited by hand ({origin}).',fix='copy the `selection` from `read` unchanged: the hash covers the exact bytes.'},
 selection_path_mismatch={message='the selection receipt was taken from another file ({origin}).',fix='use the receipt `read` returned for `path`, or read this file and use its own.'},
 selection_version_required={message='the selection receipt carries no file version, so the edit cannot be checked against the file ({origin}).',fix='read the file again and use the receipt it returns, which carries `version`.'},
 selection_version_mismatch={message='the selection receipt and the `version` argument name different versions of the file ({origin}).',fix='send one version: either the receipt\'s, or none - read the file again if unsure.'},
 native_search_unavailable={message='this build has no native grep, so the search was refused rather than faked ({origin}).',fix='use `bash` with `rg`, or `read_many` for known paths.'},
 timeout={message='the tool ran past its deadline and was stopped; what it changed is unknown ({origin}).',fix='read the effect report before retrying; a narrower command or a longer `timeout_seconds` finishes inside the deadline.'},
 invalid_timeout_seconds={message='`timeout_seconds` is not a number of seconds this node accepts ({origin}).',fix='send `timeout_seconds` as a whole number between 1 and 3600.'},
 command_raised={message='the shell command ran and the host raised while reading its result, so the effect is unknown ({origin}).',fix='read the operation\'s stdout/stderr paths from the result before deciding whether to run it again.'},
 run_cancelled={message='the run was cancelled, so this call was not dispatched ({origin}).',fix='start a new run if the work is still wanted; a cancelled run does not resume.'},
 superseded_by_steering={message='the user\'s steering arrived before this call was dispatched, so the call was dropped ({origin}).',fix='read the steering text in the transcript and act on it; the dropped call changed nothing.'},
 git_audit_forbidden_for_subagent={message='a subagent session may not run the git audit, which decides a merge ({origin}).',fix='the coordinator session runs the audit; a subagent reports its evidence instead.'},
 graph_unavailable={message='this build has no code-graph component, so a graph call was refused ({origin}).',fix='use `read`, `grep` and `bash` instead; `capabilities()` names what this node has.'},
 graph_patch_audit_failed={message='the graph component could not audit the patch, so the write was refused ({origin}).',fix='read `audit` for its own words, fix the patch shape and retry; nothing was written.'},
 graph_patch_review_required={message='the patch touches more than the graph could check, so a review is required before it lands ({origin}).',fix='send the same patch to the reviewer session (or split it) and read the audit list in `audit`.'},
 unknown_graph_action={message='the graph tool has no action `{input}` ({origin}).',fix='{available_sentence}'},
 unknown_action={message='this tool has no action `{input}` ({origin}).',fix='{available_sentence}'},
 unknown_update_action={message='`update` has no action `{input}` ({origin}).',fix='{available_sentence}'},
 unknown_resource_action={message='`resource` has no action `{input}` ({origin}).',fix='{available_sentence}'},
 unknown_session={message='no session on this node has that id ({origin}).',fix='call the tool that lists sessions first, and use an id it returns.'},
 unknown_spell={message='no spell on this node has that name ({origin}).',fix='`searchTools("select:spells")` lists the spells this node has, and the spell names are the ones `wa spells` prints.'},
 unknown_skill={message='no skill has that name ({origin}).',fix='{available_sentence}'},
 unknown_node={message='no peer node this session can reach is named `{input}` ({origin}).',fix='{available_sentence}'},
 unknown_capability={message='no peer capability is named `{input}` ({origin}).',fix='ask the peer for its capabilities (`remote` with capability `sessions` or `health`) and use one it lists.'},
 capability_not_in_profile={message='the capability `{input}` is outside the profile this session runs under ({origin}).',fix='this is an authority decision: a master session can call it, and `capabilities()` shows which are in this profile.'},
 subagent_recursion_forbidden={message='a subagent may not spawn another subagent ({origin}).',fix='do the work in this session, or report back so the coordinator spawns it.'},
 subagent_runtime_error={message='the subagent runtime failed while starting or answering ({origin}).',fix='read `detail` for the runtime\'s own words; nothing was dispatched to it.'},
 not_peer_operator={message='the peer `{input}` does not accept effectful calls from this session ({origin}).',fix='ask its operator to grant this node, or send the call to a peer that does.'},
 remote_effect_outside_codemode={message='a peer call with an effect may only be made from inside a code-mode script ({origin}).',fix='wrap it in a code-mode script: `await tools.remote({node,capability,...})` - a batch stays read-only.'},
 remote_args_object_required={message='`args` must be an object of the capability\'s own parameters, and the call sent a string or another shape ({origin}).',fix='send the parameters flat at the top level: {example}.'},
 remote_node_required={message='`remote` needs `node` and the call did not carry it as a non-empty string ({origin}).',fix='{available_sentence}{example_sentence}'},
 remote_capability_required={message='`remote` needs `capability` and the call did not carry it ({origin}).',fix='name the capability at the top level{example_clause}.'},
 remote_argument_conflict={message='the same argument was given twice with different values, once at the top level and once inside `args`, so which one the peer would use is undecidable ({origin}).',fix='send each parameter once, at the top level: {example}.'},
 remote_calls_1_to_8={message='a peer batch must carry 1 to 8 calls ({origin}).',fix='send `{"node","capability":"batch","calls":[{"capability","...params"},...]}` with at most 8 entries.'},
 remote_calls_or_capability={message='a peer call named both a `capability` and a `calls` batch ({origin}).',fix='send either one capability call, or `capability:"batch"` with `calls` - not both.'},
 remote_calls_entry_invalid={message='a batch entry is not an object naming its own capability ({origin}).',fix='each entry is `{"capability":"read","path":"..."}` - an object with a capability and that capability\'s parameters.'},
 remote_cannot_recurse={message='a peer batch may not contain `remote` or `batch`: one hop only ({origin}).',fix='flatten the calls into this batch, or run the second hop from the peer itself.'},
 remote_image_transport_unsupported={message='an image cannot cross the peer boundary yet, so the call was refused rather than returning a reference to the wrong machine ({origin}).',fix='read the file on the node that holds it, or copy the bytes as text with `bash`.'},
 remote_unreachable={message='the peer did not answer within the call\'s deadline ({origin}).',fix='ask that peer for a health read first, and retry once it answers; nothing was replayed.'},
 remote_answer_unreadable={message='the peer answered something this node cannot read as a result ({origin}).',fix='read the raw answer in `detail`; the peer is on a build whose protocol differs.'},
 parallel_operation_await_failed={message='the parallel batch\'s operation could not be read, so its outcome is unknown ({origin}).',fix='read the operation by id before starting another batch; never replay it.'},
 batch_cursor_invalid={message='the batch cursor is not one this node hands out ({origin}).',fix='use the `cursor` from the batch result verbatim, or ask for `tool_call` with `first` as a whole number.'},
 batch_cursor_not_found={message='no stored batch has that cursor any more: it was consumed or aged out ({origin}).',fix='run the batch again, asking for a larger `limit` so it fits one result.'},
 batch_cursor_store_unreadable={message='the stored batch could not be read back ({origin}).',fix='run the batch again; the stored evidence is gone, the calls themselves are not replayed.'},
 batch_cursor_tool_changed={message='the cursor was issued for another tool\'s batch ({origin}).',fix='continue the batch through the same tool that produced it.'},
 batch_cursor_scope_changed={message='the cursor was issued in another session scope ({origin}).',fix='continue the batch in the session that started it.'},
 batch_item_exceeds_budget={message='one item of the batch is larger than the whole reply budget, so continuing would return nothing ({origin}).',fix='read that item directly with the single tool, using `full_result` as the reference.'},

 -- self-wakes, probes and the loop that reads them
 wake_needs_in_seconds_at_or_on={message='`wake` was called with no schedule at all ({origin}).',
  fix='send exactly one schedule: `{in_seconds:600}`, `{at:<unix epoch>}`, or `{on:["message"]}` for an event wake.'},
 wake_time_and_event_are_exclusive={message='`wake` was given a time and an event at once ({origin}).',
  fix='send one schedule: a time (`in_seconds` or `at`), or `on:[...]`, never both.'},
 wake_in_seconds_and_at_are_exclusive={message='`wake` was given both `in_seconds` and `at` ({origin}).',
  fix='send one of them: `in_seconds` for a delay, or `at` for an absolute Unix epoch time.'},
 wake_event_takes_no_time_arguments={message='an event wake was given a time argument, and a wake is woken by one source only ({origin}).',
  fix='drop `in_seconds`, `at` and `every_seconds` from an event wake; keep `on:[...]` and `reason`.'},
 wake_probe_needs_every_seconds={message='a probe on a time wake has no recheck cadence, so it would run once and never again ({origin}).',
  fix='add `every_seconds` for a time wake (the probe re-runs at that cadence), or use an event wake where the event is the trigger.'},
 wake_every_seconds_too_small={message='`every_seconds` is below the minimum this node allows between two wakes ({origin}).',
  fix='send `every_seconds` at or above `minimum` in this refusal, or drop it for a one-shot wake.'},
 wake_at_is_in_the_past={message='the `at` time has already passed, so the wake could never fire ({origin}).',
  fix='send `at` in the future, or `in_seconds` for a delay from now.'},
 wake_not_for_subagent={message='a subagent session may not schedule a wake ({origin}).',
  fix='the coordinator schedules it, or finish the turn and let the parent keep the loop.'},
 wake_reason_too_long={message='`reason` is longer than the 500 characters a wake label may carry ({origin}).',
  fix='send a shorter `reason`; the full text belongs in `prompt`.'},
 wake_prompt_too_long={message='`prompt` is longer than the 8000 characters a wake may carry ({origin}).',
  fix='send the short version in `prompt` and read the long one from a file when the wake fires.'},
 wake_probe_too_long={message='`probe` is longer than the 20000 characters a probe may carry ({origin}).',
  fix='keep the probe small: it is a read-only script that answers `{changed:...}`.'},
 wake_not_pending={message='that wake is not waiting to fire, so it cannot be changed or re-armed ({origin}).',
  fix='read `wake_list` for the wakes that are pending on this session, and use one of their ids.'},
 self_wake_vetoed={message='a guard refused this wake before it was scheduled ({origin}).',
  fix='read the veto reason in `detail`; a wake needs its session, its clock and its schedule to hold.'},
 selfloop_forbidden_session={message='this session may not run the self-loop ({origin}).',
  fix='the self-loop is the root session\'s own loop; a child reports back instead of scheduling wakes.'},
 sentinel_unreachable={message='the Sentinel did not answer, so the request never reached it ({origin}).',
  fix='ask for its health first; the same request can be queued again once the Sentinel answers.'},
 sentinel_refused={message='the Sentinel refused the request it was given ({origin}).',
  fix='read `detail` for the Sentinel\'s own words and change the request; nothing was started.'},
 needs_sentinel={message='this action can only be done by the Sentinel, and this node is not it ({origin}).',
  fix='queue the request on the Sentinel (`wa-sentinel request <kind>`) so it is done by the node that owns it.'},
 update_coordinator_only={message='only the coordinator that owns the update may run this step ({origin}).',
  fix='send the step to the coordinator session; this node only reports its own state.'},
 release_update_unsupported={message='this node cannot take an update of that kind ({origin}).',
  fix='the update ring the node reports names what it accepts; this node is not on that ring.'},
 release_update_unsupervised={message='an update was requested without anything able to supervise it ({origin}).',
  fix='queue the update through the Sentinel, which supervises and can roll it back.'},
 source_moved={message='the source the work was based on moved since it was read ({origin}).',
  fix='fetch the source again and re-apply the change onto what it now is.'},
 tree_dirty={message='the tree has uncommitted changes, and the gate refuses a dirty tree ({origin}).',
  fix='commit or stash the changes, or point the action at a clean worktree; the gate cannot tell yours from damage.'},
 unsigned_source={message='the source is not signed, so this node will not build or install from it ({origin}).',
  fix='use a signed release, or sign the source with the node\'s release key first.'},
 detached_runtime_tree={message='the runtime tree is not on a branch, so an update has nowhere to land ({origin}).',
  fix='put the runtime tree back on its branch (or let the deploy do it), then run the update again.'},
 park_unknown={message='the node is parked in a state this node does not recognize ({origin}).',
  fix='read the node\'s own `health` for the state it reports before unparking it.'},
 replayed_request={message='this request was already answered once; a replay is refused rather than run twice ({origin}).',
  fix='read the first answer; if its effect is unknown, reconcile it before sending the request again.'},
 request_in_flight={message='the same request is still running, so it was not started a second time ({origin}).',
  fix='wait for the first one to settle (it re-collects on the next read) instead of sending it again.'},
 stale_request={message='the request was overtaken by a newer one for the same target ({origin}).',
  fix='read the newest request\'s state; the older one is not applied.'},
 idempotency_conflict={message='the idempotency key was used before with different content ({origin}).',
  fix='send a new key for a new request, or re-read the first one with the key it was sent with.'},
 idempotency_key_required={message='this request must carry an idempotency key and the call did not ({origin}).',
  fix='send `idempotency_key` as a stable string for this request, so a retry finds the first attempt.'},
 relay_request_timeout={message='the relay did not answer in time ({origin}).',
  fix='read the relay\'s health, then retry once; the request is not replayed automatically.'},
 relay_refused={message='the relay refused the request ({origin}).',
  fix='read the relay\'s own words in `detail`; the relay must authorize this node before it forwards anything.'},
 -- the WhatsApp surface: the account lives on exactly one node, and every refusal says which
 whatsapp_component_absent={message='no node in this fleet runs the WhatsApp component, so there was nowhere to send the call ({origin}).',
  fix='this is a fleet fact, not an argument: point the node at the owner (`WASM_AGENT_WHATSAPP_OWNER`), or enable the component where the account is; this call queued nothing.'},
 whatsapp_account_unreachable={message='the node that holds the WhatsApp account did not answer ({origin}).',
  fix='read `account_lives_on` and `note` for which node it is, and ask that node\'s health before retrying; this call queued no job on this one.'},
 whatsapp_owner_unreachable={message='the node serving the WhatsApp account could not be reached ({origin}).',
  fix='read `owner` and `detail`; the request never reached it, so nothing was sent and nothing is queued here.'},
 whatsapp_send_bad_ids={message='`ids` is not a list of WhatsApp job ids a previous send answered ({origin}).',
  fix='send `ids` as an array of 1 to 20 whole numbers, or drop it and send `chat`+`text` for a new message.'},
 whatsapp_send_bad_id={message='`id` is not a WhatsApp job id ({origin}).',
  fix='send the whole number a previous send answered as its job id, and nothing else with it.'},
 whatsapp_send_id_or_message={message='the call carried both a resume list and a new message ({origin}).',
  fix='send `ids` alone to resume a wait, or `chat`+`text` to send a message - not both in one call.'},
 whatsapp_send_bad_until={message='`until` is neither "all" nor "any" ({origin}).',
  fix='send `until:"all"` (wait for every id) or `until:"any"` (answer as soon as one settles).'},
 whatsapp_send_no_id={message='no WhatsApp job id came back for the message this call sent ({origin}).',
  fix='read the send\'s own answer for the message state; a send without an id cannot be waited on.'},
 whatsapp_send_chat_text_required={message='a WhatsApp send needs a chat and text ({origin}).',
  fix='send `chat` (the number or group id) and `text` (the message body) together.'},
 whatsapp_tool_renamed={message='the tool name used here was renamed in this build ({origin}).',
  fix='use the one WhatsApp tool name this build publishes: `searchTools("whatsapp")` lists the callable ones.'},
 -- the rest of the dispatcher\'s own codes
 cancelled={message='the run was cancelled before this call settled ({origin}).',
  fix='start a new run if the work is still wanted; a cancelled call is not retried automatically.'},
 steps_required_1_to_8={message='the call carried a step list of the wrong shape or size ({origin}).',
  fix='send `steps` as a dense array of 1 to 8 steps, no holes and no nils.'},
 calls_required_1_to_8={message='the call carried a call list of the wrong shape or size ({origin}).',
  fix='send `calls` as a dense array of 1 to 8 entries, each naming its own tool or capability.'},
 tool_call_name_missing={message='a `tool_call` arrived with no tool name in it ({origin}).',
  fix='send `{name:"<tool>",arguments:{...}}`; `searchTools("*")` lists the names.'},
 tool_call_forms_are_exclusive={message='`tool_call` was given two forms of the same call ({origin}).',
  fix='send one form: `{name,arguments}`, or the tool\'s name as the form\'s own field, never both.'},
 skill_forms_are_exclusive={message='`skill` was given both a name and a query ({origin}).',
  fix='send either `name` for one skill\'s full text, or `query` to search - not both.'},
 skill_query_required={message='`skill` was given pagination without a query ({origin}).',
  fix='send `query` with `limit`/`offset`/`snapshot`, or `name` alone for one skill.'},
 skill_catalogue_changed={message='the skill catalogue changed while it was being read ({origin}).',
  fix='ask again: the next read re-reads the catalogue and returns a fresh snapshot.'},
 mcp_tool_not_approved={message='the connector tool named here is not approved for this node ({origin}).',
  fix='the connector\'s own approval record names what is allowed; an unapproved connector tool is never called.'},
 mcp_script_directory_unbound={message='the connector script has no directory this node can run it from ({origin}).',
  fix='bind the connector\'s script directory in this node\'s configuration, then call it again.'},
 mcp_result_settlement_unverified={message='the connector\'s answer could not be settled, so its effect is unknown ({origin}).',
  fix='read the connector\'s own status before replaying the call; an unverified settlement is never replayed.'},
 mesh_disabled={message='the mesh is switched off on this node ({origin}).',
  fix='enable the mesh in the node\'s configuration, or use a direct peer call.'},
 mesh_unavailable={message='this build has no mesh component ({origin}).',
  fix='use `remote` for a direct peer call; `capabilities()` names what this node has.'},
 no_route={message='this node found no route to the target ({origin}).',
  fix='read the rendezvous/relay state and the target\'s online list before routing again.'},
 no_rendezvous={message='no rendezvous is configured on this node, so peers cannot be found ({origin}).',
  fix='set the rendezvous address for this node (or ask the Sentinel to), then retry.'},
 not_remote={message='the target is not remote: this node is the one that holds it ({origin}).',
  fix='call it locally instead of routing it to a peer.'},
 operator_action_unsupported={message='the operator\'s door does not support this action ({origin}).',
  fix='{available_sentence}'},
 orchestration_operator_only={message='only the operator may switch orchestration ({origin}).',
  fix='ask the operator to run `/orchestration`; a session cannot grant itself subagents.'},
 orchestration_mode_not_enabled={message='orchestration is not enabled for this session ({origin}).',
  fix='the operator enables it (`/orchestration`); until then this session works directly.'},
 done_gate_missing={message='this run has no done-gate, so the step that needs one cannot be checked ({origin}).',
  fix='open the gate first (`done_gate` action `request` with the checks this run must pass).'},
 done_gate_checks_required={message='a done-gate needs at least one check and the call carried none ({origin}).',
  fix='send `{action:"request",checks:[{...}]}`: one entry per thing this run must prove.'},
 done_check_not_found={message='no check with that id exists on this gate ({origin}).',
  fix='read the gate (`done_gate` action `status`) and use one of the ids it lists.'},
 done_gate_unknown_action={message='`done_gate` has no such action ({origin}).',
  fix='{available_sentence}'},
 hook_raised={message='a configured hook raised instead of answering ({origin}).',
  fix='read `detail` for the hook\'s own error and fix the hook; the call it was watching is reported with the verdict.'},
 hook_engine_fallback={message='the hook engine could not run and fell back to its own default ({origin}).',
  fix='read `detail`: a fallback verdict is reported, never silent; fix the hook file and run the call again.'},
 internal_error={message='the node hit its own internal error while answering ({origin}).',
  fix='read `detail` for the failing step; nothing was reported as done.'},
 empty_model={message='no model was named for this call, so there was nothing to ask ({origin}).',
  fix='send `model` as the provider\'s model name, or let the session\'s pinned model answer it.'},
 engine_error={message='the engine failed while running this step ({origin}).',
  fix='read `detail` for the engine\'s own words; the step did not complete.'},
 usage={message='the call did not match what this command takes ({origin}).',
  fix='{available_sentence}'},
 wrong_target={message='the request was addressed to another node ({origin}).',
  fix='send it to the node the enrollment names as its target; this one will not act on it.'},
 duplicate_message_id={message='a message with that id already exists in this session ({origin}).',
  fix='send a new id, or read the message that already carries this one.'},
 forbidden_role={message='this role may not do that ({origin}).',
  fix='a master session can; a guest sees only its own memory and the tools it is offered.'},
 forbidden_parent_session={message='that session is not this session\'s parent ({origin}).',
  fix='name the session this one was placed from; a child cannot reach an arbitrary parent.'},
 forbidden_steering_session={message='steering is only accepted for the run it belongs to ({origin}).',
  fix='send the steering to the run that is live now; a settled run takes no steering.'},
 steering_inbox_full={message='the run\'s steering inbox already holds its maximum ({origin}).',
  fix='wait for the run to read what is queued, then send the next line.'},
 steering_text_required_or_too_large={message='the steering text is empty or past the size this node carries ({origin}).',
  fix='send one short line of guidance; long instructions belong in the prompt or a file.'},
 only_read_and_grep_steps={message='a probe may only read: it was given a step that does something else ({origin}).',
  fix='a probe answers `{changed:...}` from reads only; move the effect into the woken turn.'},
 stt_no_answer={message='the speech-to-text step returned no answer ({origin}).',
  fix='read `detail`; the audio was not transcribed, so nothing downstream can use it.'},
 summary_input_exceeds_capacity={message='the text to summarize is larger than this node can carry in one call ({origin}).',
  fix='summarize in parts, or read a smaller range of the file first.'},
 resource_store_invalid_result={message='the resource store answered something this node cannot read ({origin}).',
  fix='read the store\'s own status; nothing was recorded as done.'},
 resource_store_failed={message='the resource store refused the write ({origin}).',
  fix='read `detail` for the store\'s own words; the effect it was recording is unchanged.'},
 key_value_multiline={message='a key/value pair carries a newline ({origin}).',
  fix='keep each value on one line; multi-line text belongs in a file.'},
 key_value_required={message='a key/value pair is missing its key or value ({origin}).',
  fix='send `{name,value}` - both, as strings.'},
 id_must_match_filename={message='the id does not match the file name it lives in ({origin}).',
  fix='name the file after its id (or the id after the file) so the two agree.'},
 installation_reservation_held={message='another installation holds the reservation for this tree ({origin}).',
  fix='let the holder finish, then install again; a second installer in one tree is refused on purpose.'},
 -- codes whose name is the rule and whose next step needs saying once
 selection_eol_ambiguous={message='the file mixes line endings inside the selected range, so the exact bytes are ambiguous ({origin}).',
  fix='select a range that uses one line ending, or normalize the file\'s line endings first.'},
 selection_mixed_line_endings={message='the file mixes line endings, so a line-based edit cannot be applied byte-exactly ({origin}).',
  fix='normalize the file to LF and retry the edit, or use a smaller range with one line ending.'},
 replacement_line_contains_newline={message='a replacement line carries a newline, so it is more than one line ({origin}).',
  fix='send each line as its own array entry; a newline inside one entry is refused.'},
 unsupported_range_edit_field={message='a range edit carries a field this node does not accept: `{input}` ({origin}).',
  fix='drop `{input}`; a range edit takes `selection`, `replacement_lines`, `start_line` and `end_line`.'},
 unsupported_replacement_field={message='a replacement carries a field this node does not accept: `{input}` ({origin}).',
  fix='drop `{input}`; a replacement takes exactly `old_text` and `new_text`.'},
 replacement_lines_must_be_dense_array={message='`replacement_lines` is not a dense array of strings ({origin}).',
  fix='send `replacement_lines` as an array of strings, no nils, at most 2000 entries.'},
 replacement_line_must_be_string={message='a replacement line is not a string ({origin}).',
  fix='send every entry of `replacement_lines` as a string, `""` for an empty line.'},

 -- literals that are prefixes of a runtime code: the scan records the prefix, and the message must
 -- still be true for every code the prefix can complete to.
 wait_accepts_at_most_={message='`wait` was given more op handles than one call accepts ({origin}).',
  fix='wait on at most 8 handles per call; wait for them in two calls, or drop the settled ones with `results.get`.'},
 cancel_accepts_at_most_={message='`cancel` was given more op handles than one call accepts ({origin}).',
  fix='cancel at most 8 handles per call; cancel the rest in a second call.'},
 remote_={message='the peer call was refused by this node before it left ({origin}).',
  fix='read `detail` and the refusal code: a peer call needs `node`, `capability` and that capability own parameters at the top level, e.g. `{"node":"<name>","capability":"bash","command":"ls -la"}`.'},
 remote_http_={message='the peer answered an HTTP status this node cannot use ({origin}).',
  fix='read the status in the code and the peer own health before retrying; a 401 or 403 is an authority problem, not a retry.'},
 exit_={message='the command exited with a status this node reports as a failure ({origin}).',
  fix='read the command own output; a non-zero exit is the command answer, not a node failure.'},
 results_unknown_op={message='`results` has no such form ({origin}).',
  fix='the forms are `results.get(hashOrOp)`, `results.last(n)`, `results.diff(a,b)` and `results.reuse(tool,{max_age_s})`.'},
 remote_error={message='the peer call failed on the far side ({origin}).',
  fix='read the peer own words in `detail`; the call reached it, so check the effect there before sending it again.'},
 -- placement and the orchestration queue (the coordinator\'s own surface)
 placement_queue_full={message='this owner already has the maximum number of queued placements, so the request was dropped ({origin}).',
  fix='wait for a queued task to settle (its state is readable on the task row), or place fewer tasks in one round.'},
 placement_pending={message='the child of this task is still being placed, so it cannot be messaged or read yet ({origin}).',
  fix='read the task state until it is `admitted`, then send the message; a pending placement has no session to reach.'},
 placement_uncertain_reconcile_before_cancelling={message='the delivery to that child was never observed, so cancelling it could leave it running ({origin}).',
  fix='reconcile first (`action:"reconcile"`), which asks the destination what it has; only then cancel.'},
 remote_observation_regression={message='the destination reported a state older than one already observed, so it was not recorded as newer ({origin}).',
  fix='read the task again; a settled or unknown state is never overwritten by a younger one.'},
 remote_observation_superseded={message='a newer observation of the same remote task arrived first, so this one was kept only as evidence ({origin}).',
  fix='read the newest observation; nothing needs re-sending.'},
 dispatch_uncertain={message='the dispatch to the destination raised, so whether the child started is unknown ({origin}).',
  fix='reconcile the task before placing it again; a second placement of the same idempotency key finds the first.'},
 -- the update ring, which the operator reaches through `update`
 wave_source_changed_after_prequeue={message='the source changed between the queue and the run, so the run was held rather than installing another tree ({origin}).',
  fix='queue the deploy again from the source as it is now; the held run installed nothing.'},
 wave_source_changed_after_backup={message='the source changed after the backup was taken, so the restore point does not match the tree ({origin}).',
  fix='take a fresh backup of the source as it is now, then run the deploy again.'},
 wave_prequeue_changed={message='the source changed while the deploy was being prepared for the queue ({origin}).',
  fix='run the deploy again once the source is still; nothing was queued.'},
 wave_installation_obligation_held={message='an installation this node still owes is in flight, so a second one was refused ({origin}).',
  fix='settle the in-flight installation first (`update` reports it in `reservation`), then start the next.'},
 wave_queue_receipt_unverifiable={message='the queue answered something without the deployment its output should name ({origin}).',
  fix='read `stdout` for the queue own words; nothing was deployed, and the request can be sent again.'},
 wave_immutable_request_mismatch={message='the request id already names a different deployment ({origin}).',
  fix='send a new request id for a new deployment, or read the one that id already names.'},
 wave_request_id_invalid={message='the request id is not one this node can accept ({origin}).',
  fix='send a fresh id: one line of letters, digits and dashes.'},
 wave_source_changed={message='the source moved while the deploy read it ({origin}).',
  fix='run the deploy again on a settled source; nothing was installed from the halfway tree.'},
 sentinel_stopped={message='the Sentinel is not running, so the deploy was not queued ({origin}).',
  fix='start the Sentinel (the node-side restore path), then queue the deploy again.'},
 sentinel_unverifiable={message='the Sentinel answered without a verifiable receipt, so the update is not reported as queued ({origin}).',
  fix='read the answer in `detail`; send the request again once the Sentinel answers with its receipt.'},
 rendezvous_scripts_unconfigured={message='this node has no Sentinel script directory configured, so the remote step has nowhere to run ({origin}).',
  fix='set the script directory (`WA_SENTINEL_SCRIPTS`) for this node; nothing was run.'},
 network_role_readback_unconfirmed={message='the rendezvous did not read back the role it just acknowledged ({origin}).',
  fix='read the node own role from the rendezvous (`lookup`) before changing anything else; the local view may be the stale one.'},
 network_role_changed_local_update_failed={message='the rendezvous took the new role and this node could not record it locally ({origin}).',
  fix='read `detail`, then reconcile this node local role with what the rendezvous now reports.'},
 release_update_not_started={message='the release update was not started ({origin}).',
  fix='read `detail` for the step that stopped it; nothing was installed.'},
 release_check_failed={message='the release artifact did not pass its own check ({origin}).',
  fix='read `detail` for which check failed; an artifact that fails its check is never installed.'},
 publish_failed={message='the publish step failed, so the artifact is not announced ({origin}).',
  fix='read `detail`; the built artifact is kept, and publishing again reuses it.'},
 publish_topic_required={message='a publish needs a topic and the call carried none ({origin}).',
  fix='send the topic name with the artifact so subscribers know what changed.'},
 -- the self-wake loop and its own refusals
 self_wake_forbidden={message='this session may not be woken: its authority or its session changed since the wake was set ({origin}).',
  fix='read `wake_list` for the wakes this session still owns; a wake set by a session that no longer holds the run is dropped.'},
 selfloop_unknown_session={message='the self-loop was asked about a session this node does not have ({origin}).',
  fix='read the session id from the wake row (`wake_list`) and use that one.'},
 wake_already_dispatching={message='that wake is already being dispatched, so it was not started twice ({origin}).',
  fix='read the wake state; a dispatch in flight is never repeated, and its outcome appears on the row.'},
 wake_dispatch_no_receipt={message='the wake was dispatched and the dispatcher answered nothing this node can read ({origin}).',
  fix='read the wake row state and the session transcript; the turn may have run, so do not assume it did not.'},
 -- the code-mode presentation and the code graph
 showCall_requires_version_1_and_admitted_call_index={message='`showCall` needs `{version:1, call:<index>}` and the index must name a call this script already admitted ({origin}).',
  fix='send `showCall({version:1,call:1})` - the index is the position in this script calls list, from 1.'},
 showCall_unknown_option={message='`showCall` was given an option it does not take: `{input}` ({origin}).',
  fix='send only `version` and `call`.'},
 run_has_no_graph_lead={message='the patch audit found no graph lead, so it cannot say what the patch reaches ({origin}).',
  fix='retry the audit with a path the graph indexes, or use the `read`-and-`grep` evidence a reviewer can check.'},
 graph_notify_unavailable={message='this build cannot notify the graph, so the change was not announced to it ({origin}).',
  fix='the write itself stands; the graph catches up on its next index, or rebuild from the node\'s own tree.'},
 graph_notification_failed={message='the graph refused the notification it was given ({origin}).',
  fix='read `detail` for the graph own words; the written bytes are unchanged.'},
 -- model selection and federation
 node_model_less={message='this node runs without a model, so it cannot answer a prompt ({origin}).',
  fix='set the node\'s model (or run the step in a session whose model is pinned); nothing was sent anywhere.'},
 model_less_requires_an_explicit_value={message='a node without a model is a decision, and the call did not say which value it wanted ({origin}).',
  fix='send the explicit value (`WASM_AGENT_MODEL_LESS=1` or `0`) so the choice is recorded rather than inferred.'},
 operator_conversation_outside_profile={message='the conversation is not one the operator profile opens ({origin}).',
  fix='use a conversation the profile lists, or ask the operator to add this one.'},
 federation_control_unsupported={message='this build cannot take that federation control ({origin}).',
  fix='read the node own federation state; the control has to come from the node that runs the federation.'},
 -- hooks and the deploy pause
 deploy_refused_by_hook={message='a configured hook refused the deploy before it started ({origin}).',
  fix='read the hook verdict in `detail` and satisfy the hook; nothing was queued.'},
 completion_forbidden={message='the completion cannot be granted: the authority or the parent changed ({origin}).',
  fix='the coordinator session grants it; a completion is never granted on a stale parent.'},
 envelope_store_write={message='the envelope loadout could not be written to this node\'s store ({origin}).',
  fix='read `detail` from the store; the previous loadout is still the one in force.'},
 envelope_loadout_changed={message='the envelope loadout changed between the read and the write, so the write was dropped ({origin}).',
  fix='re-read the loadout and change it once more against the version just read.'},
 audit_step_already_assessed={message='that audit step has already been assessed ({origin}).',
  fix='read the audit record and move to a step that is still open.'},
 bad_request={message='the call did not match what this door takes ({origin}).',
  fix='read `detail` for the field it refused, and send the shape the tool documents.'},
 bad_signature={message='the request signature does not verify, so it was refused before any effect ({origin}).',
  fix='sign with this node key (or ask the sender to); an unsigned or mis-signed request is never queued.'},
 binding_registry_revoke_unconfirmed={message='a binding was revoked locally and the registry did not confirm it ({origin}).',
  fix='read the registry state for that binding before assuming it is gone; the local revoke stands.'},
 batch_stopped_after_authority_drift={message='the batch stopped because the run authority changed under it ({origin}).',
  fix='read what already ran (`results`) and re-issue only the items that did not; the stopped ones have effect none.'},
 batch_target_not_pure_read={message='a batch may only carry reads, and one entry is not one ({origin}).',
  fix='move the effectful call out of the batch and run it on its own.'},
 idempotency_key_retired={message='that idempotency key was retired, so it cannot be reused ({origin}).',
  fix='send a fresh key for a new request; a retired key never names a second effect.'},
 legacy_own_impact_unmeasured={message='the impact of this change on its own tree was not measured, so it was not reported as measured ({origin}).',
  fix='run the audit against the tree the change touches and record what it found.'},
 original_own_tip_integration_comparison_unmeasured={message='the comparison against the branch own tip was not made ({origin}).',
  fix='run the comparison against `origin/main` and the branch tip before reporting an integration result.'},

 codemode_protocol_unknown_step={message='the code-mode loop received a step it does not understand, so it stopped the script ({origin}).',
  fix='report this: a step that is neither a host global, a finished script nor a call is a protocol mismatch between the loop and the sandbox.'},
 done_gate_checks_exist={message='this gate already carries its checks, so a second set was refused ({origin}).',
  fix='read the gate (`done_gate` action `status`) and add or replace a single check instead of the whole set.'},
 done_gate_request_missing={message='no done-gate request exists for this run, so there is nothing to check against ({origin}).',
  fix='open the gate first: `{action:"request",checks:[...]}` with the things this run must prove.'},
 parked={message='the workspace is parked: its work is saved on a branch and the tree is not live ({origin}).',
  fix='unpark the workspace to work in it again; a parked tree is never written through.'},
 released={message='the workspace was already released, so there is nothing left to act on ({origin}).',
  fix='allocate a fresh workspace for new work; a released one is not reused.'},
 releasing={message='the workspace is being released right now, so the call was refused rather than racing it ({origin}).',
  fix='read the workspace status until the release settles, then act on the new state.'},
 -- raised by the host (rust/wa-capabilities/src/plugins.rs) and carried verbatim into the tool result:
 -- a wasm plugin tool is a tool like any other, so its refusals read like the rest.
 plugin_not_found={message='no wasm plugin on this node is named `{input}`, so the call had nowhere to go ({origin}).',
  fix='ask `searchTools("*")` for the tools this node has; a plugin tool appears there only while its component is installed and enabled.'},
 plugin_pin_invalid={message='the plugin\'s pin file does not hold a sha256, so this node will not load it ({origin}).',
  fix='reinstall the plugin through `scripts/build-components.sh` (which writes the pin) rather than editing the pin by hand.'},
 plugin_pin_unreadable={message='the plugin\'s pin file could not be read, so its bytes cannot be verified ({origin}).',
  fix='read `input` for the pin path and its error; repair the component directory, then reinstall the plugin.'},
 plugin_result_too_large={message='the plugin answered more bytes than a tool result may carry ({origin}).',
  fix='ask the plugin for less in one call (a `limit` or a narrower path); the result was refused whole, not truncated.'},
 codemode_sandbox={message='the QuickJS sandbox failed while running this script: {detail} ({origin}).',
  fix='read the detail: it is the sandbox own error. The script did not finish, and the loop reports the calls it never admitted; a sandbox failure is the node state, not an argument to change.'},
}
-- The argument a family's code names: the last word of the code once its own marker is removed, so
-- `done_check_id_required` names `id`, `calls_array_required` names `array`, and `unknown_spell` names
-- the KIND (`spell`) rather than a field. Nothing is invented: the word comes from the code.
local FAMILY_MARKERS={'required','invalid','unsupported','unavailable','failed','changed','unreadable',
 'mismatch','conflict','exclusive','refused','budget','unknown'}
local function family_field(code)
 local text=tostring(code or '')
 local kind=text:match('^unknown_(.+)$')
 if kind then return (kind:gsub('_',' ')) end
 for _,marker in ipairs(FAMILY_MARKERS) do
  local stripped=text:gsub('_'..marker..'$','')
  if stripped~=text then text=stripped break end
 end
 local last=text:match('([%w]+)$')
 return last
end
M.family_field=family_field

-- Codes whose sentence is the same for every site and whose meaning is exactly its name. The templates
-- fill from the refusal: `{field}` is the argument the code names, `{rule}` the words after `_must_be_`,
-- `{accepted}` the tool's own argument list.
local FAMILIES={
 {pattern='^(.+)_accepts_at_most_(.+)$',message='the call carried more items than this accepts: {rule} ({origin}).',
  fix='send fewer: {rule}.'},
 {pattern='^(.+)_takes_an?_(.+)$',message='the call passed an argument of the wrong kind: {rule} ({origin}).',
  fix='send it the way the code says: {rule}.'},
 {pattern='^(.+)_exceeds_(.+)$',message='the call asks for more than this allows: {rule} ({origin}).',
  fix='ask for less: {rule}.'},
 {pattern='^(.+)_contains_(.+)$',message='a value carries something it may not: {rule} ({origin}).',
  fix='remove it: {rule}.'},
 {pattern='^(.+)_needs_(.+)$',message='the call is missing what this step needs: {rule} ({origin}).',
  fix='send what the code names - {rule} - and call again.'},
 {pattern='^(.+)_in_the_past$',message='the time given has already passed, so nothing could fire ({origin}).',
  fix='send a time in the future, or a delay from now.'},
 {pattern='^(.+)_unsupported$',message='this node does not support that: {rule} ({origin}).',
  fix='use what this node supports instead; `capabilities()` names it.'},
 {pattern='^remote_http_(.+)$',message='the peer answered an HTTP status this node cannot use: {detail} ({origin}).',
  fix='read the status and the peer own health before retrying; a 401 or 403 is an authority problem, not a retry.'},
 {pattern='^exit_(.+)$',message='the command exited with a status this node reports as a failure ({origin}).',
  fix='read the command own output: a non-zero exit is the command answer, not the node one.'},
 {pattern='^(.+)_must_be_(.+)$',message='{tool} refused a value that breaks one rule: {rule} ({origin}).',
  fix='send `{field}` so that {rule}.'},
 {pattern='^(.+)_required$',message='{tool} needs `{field}` and the call did not carry it ({origin}).',
  fix='send `{field}`: {tool} takes {accepted}'},
 {pattern='^(.+)_requires_(.+)$',message='{tool} needs what the code names before it will answer: {rule} ({origin}).',
  fix='send what the code names - {rule} - then call again.'},
 {pattern='^unknown_(.+)$',message='no {field} with that name exists on this node ({origin}).',
  fix='{available_sentence}'},
 {pattern='^(.-)_unknown$',message='this node does not recognize that {field} ({origin}).',
  fix='{available_sentence}'},
 {pattern='^invalid_(.+)$',message='{tool} refused a `{field}` value it cannot accept ({origin}).',
  fix='send `{field}` in the shape {tool} documents: {accepted}'},
 {pattern='^unsupported_(.+)$',message='{tool} does not support that {field} ({origin}).',
  fix='drop `{field}`, or send a value {tool} documents: {accepted}'},
 {pattern='^(.+)_invalid$',message='{tool} refused a `{field}` value it cannot accept ({origin}).',
  fix='send `{field}` in the shape {tool} documents: {accepted}'},
 {pattern='^(.+)_unavailable$',message='what the code names is not available on this node: {rule} ({origin}).',
  fix='`capabilities()` lists what this node can do; use what it names there instead.'},
 {pattern='^(.+)_refused$',message='the node refused the step the code names: {rule} ({origin}).',
  fix='read `detail` for the refusing side\'s own words, change the call to satisfy it, and only then retry.'},
 {pattern='^(.+)_failed$',message='the step the code names ran and did not succeed: {rule} ({origin}).',
  fix='read `detail` for the step\'s own words; change what it names before retrying, and check the effect before replaying anything.'},
 {pattern='^(.+)_changed$',message='what the call was based on changed before it could be applied: {rule} ({origin}).',
  fix='read the current state again and re-issue the call against the version just read.'},
 {pattern='^(.+)_unreadable$',message='the node could not read what the code names: {rule} ({origin}).',
  fix='read it directly (one `read` or one `bash` call) to see the raw bytes it could not parse.'},
 {pattern='^(.+)_mismatch$',message='two values the call depends on do not agree: {rule} ({origin}).',
  fix='use ONE source for both: re-read the state and copy its value unchanged.'},
 {pattern='^(.+)_conflict$',message='the call asked for two things that cannot both hold: {rule} ({origin}).',
  fix='send one of them; the code names the pair that conflicts.'},
 {pattern='^(.+)_exclusive$',message='the call carried two mutually exclusive forms: {rule} ({origin}).',
  fix='send one form only; the code names which two it found.'},
 {pattern='^(.+)_too_(.+)$',message='a value is past the limit the node accepts: {rule} ({origin}).',
  fix='send a value that fits: {rule}.'},
 {pattern='^(.+)_budget$',message='the call would spend more than the budget the node allows: {rule} ({origin}).',
  fix='ask for less in this call, or raise the budget where the tool takes one.'},
 {pattern='^(.+)_budget_(.+)$',message='a budget is not satisfied: {rule} ({origin}).',
  fix='change the request so the budget covers it: {rule}.'},
 {pattern='^not_(.+)$',message='the call named something it is not: {rule} ({origin}).',
  fix='read the code and `detail`: the step needs an object of the kind the code names.'},
 {pattern='^no_(.+)$',message='the node found nothing of the kind the code names: {rule} ({origin}).',
  fix='read `detail` for the side that answered, and check the state before retrying.'},
 {pattern='^already_(.+)$',message='the step the code names was already done: {rule} ({origin}).',
  fix='nothing to change: read the current state instead of repeating the call.'},
 {pattern='^(.+)_not_(.+)$',message='a check on what the node applied did not hold: {rule} ({origin}).',
  fix='read `detail`, then re-read the state the check names before retrying.'},
 {pattern='^(.+)_inside_(.+)$',message='the requested position is not on a boundary: {rule} ({origin}).',
  fix='step to a boundary: read whole lines or characters instead of a raw offset.'},
 {pattern='^(.+)_out_of_(.+)$',message='the requested value is outside the range the target has: {rule} ({origin}).',
  fix='ask for a value inside the target\'s range - the refusal carries the current one where it can.'},
 {pattern='^(.+)_(?:list|limit|window|cursor|page)_(.+)$',message='a pagination value is not one this node accepts: {rule} ({origin}).',
  fix='use the cursor or limit the previous answer returned, unchanged.'},
}
M.FAMILIES=FAMILIES
-- The argument-contract codes are RETURNED from lua/core/json_contract.lua (`return 'schema_extra:'..path`),
-- not assigned to an `error` field, so the generated map cannot see them. One rule names their origin for
-- all of them, and the renderer prefixes every origin with the module's own path.
for code,entry in pairs(CODES) do
 if code:match('^schema_') or code:match('^json_') then entry.origin=entry.origin or 'json_contract.lua' end
end
M.CODES=CODES

-- The sentence for "here is what exists", from the refusal's own fields: an `available` list, the
-- allowed actions, the peers online, or the tool's schema. A site that lists what exists gets it
-- quoted back; a site that lists nothing gets a true sentence saying which call names them.
local function available_sentence(fields,ctx)
 if type(fields.available)=='table' and #fields.available>0 then
  local names={}
  for _,value in ipairs(fields.available) do names[#names+1]=tostring(value) end
  return 'what this node has: '..table.concat(names,', ')..'.'
 end
 if type(fields.allowed_actions)=='table' and #fields.allowed_actions>0 then
  local names={}
  for _,value in ipairs(fields.allowed_actions) do names[#names+1]=tostring(value) end
  return 'the actions this tool takes: '..table.concat(names,', ')..'.'
 end
 if type(fields.online_nodes)=='table' and #fields.online_nodes>0 then
  local names={}
  for _,value in ipairs(fields.online_nodes) do names[#names+1]=tostring(value) end
  return 'the peers online now: '..table.concat(names,', ')..'.'
 end
 local accepted=ctx and M.accepted(ctx.parameters)
 if accepted then return ctx.tool and (tostring(ctx.tool)..' takes '..accepted..'.') or ('the accepted arguments are '..accepted..'.') end
 return 'ask the tool that lists them before naming one again: `searchTools("*")` for tools, `capabilities()` for host capabilities.'
end
M.available_sentence=available_sentence

-- The input a refusal quotes. Precedence: what the site recorded as the offending text, then the
-- detail a code carries, then the field the code names (`path`, `option`, `state`, ...), then the whole
-- argument text the boundary holds. Always bounded and redacted.
local BORROWED={'input','detail','got','value','name','option','key','field','path','state','kind','asked','reason','why','action','node','capability','index','line','method'}

local function refused_input(fields,ctx)
 local function usable(text)
  if text==nil then return nil end
  if type(text)=='table' then
   local ok,flat=pcall(function() return dofile('lua/vendor/json.lua').encode(text) end)
   if not ok or type(flat)~='string' then return nil end
   text=flat
  end
  text=one_line(text)
  if text=='' or text=='nil' then return nil end
  return text
 end
 local direct=usable(fields.input)
 if direct then return bounded(direct) end
 for _,name in ipairs(BORROWED) do
  local candidate=usable(fields[name])
  if candidate and #candidate<=200 then return bounded(candidate) end
 end
 if ctx then
  local text=usable(ctx.input) or (type(ctx.args)=='table' and usable(ctx.args))
  if text then return bounded(text) end
 end
 return nil
end
M.refused_input=refused_input

-- `arguments.edits[1].old_text` -> the last name in the path, which is what a model has to change.
local function path_field(path)
 local text=one_line(path or ''):gsub('^arguments%??%.?','')
 local last
 for token in text:gmatch('[^%.%[%]]+') do last=token end
 return last
end

-- Which of the two tiers answered for a code: 'code' (written against its site), 'family' (read from
-- the shape of its name) or nil (nothing knows this code - the gate test fails on that).
function M.tier(code)
 local head=split(code)
 if CODES[head] then return 'code' end
 for _,family in ipairs(FAMILIES) do if head:match(family.pattern) then return 'family' end end
 return nil
end

-- The four fields, built once. `ctx` is the boundary's own knowledge: `tool`, `parameters` (the tool's
-- schema), `args`, `input` (the argument text), `site` (the loop that handed it over), `role`.
function M.build(code,fields,ctx)
 fields=type(fields)=='table' and fields or {}
 ctx=type(ctx)=='table' and ctx or {}
 local head,detail=split(code)
 local found=ORIGIN[head] or ORIGIN[head..':'] or ORIGIN[tostring(code)]
 local origin=ctx.module or (type(CODES[head])=='table' and CODES[head].origin) or 'this node'
 if origin=='this node' and found then
  -- A generated entry is one module or several (`a.lua, b.lua`, when more than one raises the same
  -- code); each is named with its own path, and at most three, so the sentence still says where.
  local named={}
  for part in tostring(found):gmatch('[^,%s]+') do
   if #named<3 then named[#named+1]=part:find('/',1,true) and part or ('lua/core/'..part) end
  end
  if #named>0 then origin=table.concat(named,', ') end
 end
 local input=refused_input(fields,ctx)
 local path=detail or nil
 local field=path_field(path) or path_field(fields.field or fields.option or '')
 local vars={origin=origin,site=ctx.site or 'the call',tool=ctx.tool or fields.tool or 'this tool',
  detail=detail and bounded(detail,M.MAX_MESSAGE) or '',input=input or '',
  field=field or '',rule=words(head),code=head,
  accepted=M.accepted(ctx.parameters) or 'the arguments its own schema lists',
  expected='',received='',example=fields.example or ctx.example or '',
  -- `{example_clause}` is ", e.g. X" and `{example_sentence}` is " Then send: X."; both empty when the
  -- site recorded no example, so a sentence never ends in "e.g. ." or "Then send: .".
  example_clause=((fields.example or ctx.example) and (', e.g. '..tostring(fields.example or ctx.example))) or '',
  example_sentence=((fields.example or ctx.example) and (' Then send: '..tostring(fields.example or ctx.example)..'.')) or '',
  available_sentence=available_sentence(fields,ctx)}
 if fields.input==nil and detail then vars.input=bounded(detail) end
 -- A code with no detail (`{error='unknown_tool'}`) still names a tool in the call itself, so the
 -- sentence says which one instead of quoting nothing.
 if vars.input=='' then vars.input=input or tostring(fields.tool or ctx.tool or '') end
 -- A `schema_*` code records a PATH (`arguments.limit`); what a model has to change is its last name.
 if head:match('^schema_') and vars.field~='' then vars.input=vars.field end
 if path then
  local schema=schema_at(ctx.parameters or fields.parameters,path)
  vars.expected=schema and (schema_type(schema) or 'the type its schema gives') or 'the type its schema gives'
  vars.received=received_kind(ctx.input,path) or received_kind(fields.input,path) or 'another type'
  if vars.field=='' then vars.field=path_field(path) or '' end
 end
 -- The family that describes this code, matched once and used for both halves of the sentence.
 -- A tool that raised answers its own Lua error text, not a code: the text already names where it came
 -- from (`lua/core/x.lua:12: ...`), so it is carried as the cause rather than parsed as a code name.
 if head:find('[/%s]') then
  local raised={error=code,tier='message',input=input or bounded(head),
   message=bounded('{tool} raised instead of answering: '..tostring(code)..' (the raise is the cause).',M.MAX_MESSAGE),
   fix='read the message: it names the line that raised. Fix the call or the file it names, then send it again; '
    .. 'a tool that raised produced no result, so nothing was recorded as done.'}
  return raised
 end
 local specific=CODES[head]
 -- `json_contract_invalid:json_number_invalid`: the inner code carries the real cause, and the outer one
 -- only says "the JSON contract refused". The inner sentence is used, and the outer code is untouched.
 if detail and CODES[detail] then specific=CODES[detail] end
 if specific and specific.input_from=='tool' and (ctx.tool or fields.tool) then
  vars.input=tostring(ctx.tool or fields.tool)
 end
 local family
 for _,candidate in ipairs(FAMILIES) do if head:match(candidate.pattern) then family=candidate break end end
 -- The argument a family names: the last word of the part of the code before its marker, so
 -- `done_check_id_required` says `id` and `calls_array_required` says `array`. Without this a family
 -- would say "needs ``", which is the empty answer this module exists to remove - hence the guard: an
 -- unfilled field falls back to the code itself, never to an empty pair of backticks.
 if vars.field=='' and family then
  local last=family_field(head)
  if last and last~='' then vars.field=last end
 end
 -- `*_must_be_*` and `*_requires_*` state the rule in the code itself, after the marker.
 do
  local prefix,rule=vars.rule:match('^(.-) must be (.+)$')
  if not prefix then prefix,rule=vars.rule:match('^(.-) requires (.+)$') end
  if prefix then
   vars.rule_field=prefix
   vars.rule=rule
   local last=prefix:match('([%w]+)$')
   if last then vars.field=last end
  end
 end
 if vars.field=='' then vars.field=head end
 local message,tier
 if specific then
  tier='code'
  message=fields.message or specific.message
 elseif family then
  tier='family'
  message=fields.message or family.message
 else
  -- A code this module has not been taught: its own words are the rule it broke, and saying so is
  -- true, bounded and still points at the module that raised it. A code whose contract is worth
  -- writing down gets an entry in CODES instead - scripts/test-refusal-contract.lua prints how many
  -- codes are described that way and refuses to let the number fall.
  tier='shape'
  message='{origin} refused {tool}: {rule} ({code}).'
 end
 local fix
 if type(fields.fix)=='string' and fields.fix~='' then fix=fields.fix
 elseif specific then fix=specific.fix
 elseif family then fix=family.fix
 elseif type(fields.note)=='string' and fields.note~='' then fix=fields.note
 else
  fix='clear the condition `{code}` - {rule} - where it lives ({origin}), then send the call again; '
   .. '`detail` carries the node\'s own words when the site recorded them.'
 end
 local rendered_message=fill(message,vars)
 local rendered_fix=fill(fix,vars)
 local out={error=code,message=bounded(rendered_message,M.MAX_MESSAGE),input=input,fix=bounded(rendered_fix,M.MAX_FIX),tier=tier}
 -- A template that lost a value would read as "needs ``" - the exact failure this module answers. The
 -- fallback keeps the sentence honest instead of silently empty.
 if out.message:find('``',1,true) or out.fix:find('``',1,true) then
  out.message=fill('{origin} refused {tool}: {rule} ({code}).',vars)
  out.input=input
  out.fix=bounded(fill('clear the condition `{code}` where it lives ({origin}), then send the call again.',vars),M.MAX_FIX)
  out.tier='shape'
 end
 if out.input==nil or out.input=='' then out.input=bounded(ctx.input or ctx.tool or code) end
 return out

end

-- ADDITIVE AND IDEMPOTENT, on purpose: the caller's table is what a test or a client already reads, and
-- a field the site wrote itself (`input`, `message`) is kept - the site knows more than this module. The
-- code in `error` is never touched, because a client matches on it.
function M.finalize(result,ctx)
 if type(result)~='table' then return result end
 if result.error==nil then
  if result.ok==false and result.message==nil and type(result.detail)=='string' then
   -- a failed result without a code: the node's own sentence travels as the message, never lost
   local filled={}
   for key,value in pairs(result) do filled[key]=value end
   filled.message=bounded(result.detail,M.MAX_MESSAGE)
   filled.fix=result.fix or 'read `detail` for the node\'s own words before retrying.'
   if filled.input==nil then filled.input=bounded((ctx and (ctx.input or ctx.tool)) or 'the call') end
   return filled
  end
  return result
 end
 if result.message~=nil and result.fix~=nil and result.input~=nil then return result end
 local built=M.build(result.error,result,ctx)
 local out={}
 for key,value in pairs(result) do out[key]=value end
 if out.message==nil then out.message=built.message end
 if out.fix==nil then out.fix=built.fix end
 if out.input==nil then out.input=built.input end
 if out.unrecorded==nil and built.unrecorded then out.unrecorded=true end
 if result.tier==nil then out.tier=built.tier end
 return out
end

-- The names a `fix` promises: `${...}`-free backticked tokens. The gate test resolves every one of them
-- against the tree, so a fix cannot name a tool, a file or a command that does not exist.
function M.entities(text)
 local found={}
 for token in tostring(text or ''):gmatch('`([^`]+)`') do found[#found+1]=token end
 return found
end

return M
