-- remember with an id corrects a stored fact in place: one row, one id, and the search index
-- follows the new text. The old path was forget + remember, which held both versions for one call
-- and kept the superseded text if the second call never happened. No model, no network.
local memory=dofile('lua/core/memory.lua');memory.setup()
local tools=dofile('lua/core/tools.lua')
local checks=0;local function check(value,label)assert(value,label);checks=checks+1 end
host.http=function()error('no network allowed')end;host.http_stream=host.http

local function row(id)
  for _,item in ipairs(memory.memories('global',200))do if item.id==id then return item end end
end
local function live()
  local count=0
  for _,item in ipairs(memory.memories('global',200))do count=count+1 end
  return count
end
local function found_ids(text)
  local ids={}
  for _,item in ipairs(memory.recall(text))do ids[item.id]=true end
  return ids
end

local original='The ZETAFORMER release gate runs on Tuesdays'
local id=memory.remember(original,'global',{'process'})
check(found_ids('ZETAFORMER')[id]==true,'the original text is findable before the correction')
local rows_before=live()

-- One tool call: same id, new content and tags.
local replaced=tools.dispatch(memory,'remember',
  {content='The ZETANEWER release gate runs on Thursdays',tags={'process','release'},id=id},'master',{})
check(replaced.ok==true and replaced.id==id and replaced.replaced==true,'remember(id) replaces in place')
local stored=row(id)
check(stored~=nil,'the entry keeps its id')
check(stored.content:find('ZETANEWER',1,true)~=nil,'the row carries the new text')
check(#stored.tags==2 and stored.tags[2]=='release','the row carries the new tags')
check(live()==rows_before,'the replace adds no row')
check(found_ids('ZETANEWER')[id]==true,'the new text is findable')
check(#memory.recall('ZETANEWER')==1,'the new text is one row, not a duplicate index entry')
check(found_ids('ZETAFORMER')[id]==nil,'the old text is no longer findable')
check(#memory.recall('ZETAFORMER')==0,'the old text matches nothing at all')

-- Replacing with identical content and tags is a no-op: no write, no new version, no journal row.
local head=memory.journal_head()
local again=tools.dispatch(memory,'remember',
  {content='The ZETANEWER release gate runs on Thursdays',tags={'process','release'},id=id},'master',{})
check(again.id==id and again.replaced==true,'an identical replace still answers with the same id')
check(memory.journal_head()==head,'an identical replace writes no journal row')
check(live()==rows_before,'an identical replace adds no row')
check(row(id).updated_at==stored.updated_at,'an identical replace does not churn updated_at')

-- An unknown or stale id refuses by name instead of silently inserting a second fact.
local unknown=tools.dispatch(memory,'remember',{content='orphan',id='00000000-0000-4000-8000-000000000000'},'master',{})
check(unknown.error=='memory_not_found','an unknown id refuses with the named error')
check(unknown.ok==nil,'an unknown id is not reported as stored')
check(live()==rows_before,'an unknown id inserts nothing')
local missing,named=memory.remember('orphan','global',{},'00000000-0000-4000-8000-000000000000')
check(missing==nil and named=='memory_not_found','the Lua API refuses the same way')
local raised=select(2,pcall(memory.remember,'orphan','global',{},''))
check(tostring(raised):find('memory_id_required',1,true)~=nil,'an empty id is a named error, not an insert')

-- A guest may not replace a master's entry, and the fence is the scope, not the id alone.
local guarded=tools.dispatch(memory,'remember',{content='guest overwrite',id=id},'guest',{user_id='guest'})
check(guarded.error=='memory_not_found','a guest cannot replace a fact outside its own scope')
check(row(id).content:find('ZETANEWER',1,true)~=nil,'the master entry is untouched')
check(#memory.recall('guest overwrite')==0,'nothing was stored for the refused guest call')

-- Without an id the old contract is unchanged: content dedupe, then a new row.
local dedupe_a=memory.remember('The ZETADUPLICATE fact is stored once','global',{})
local dedupe_b=memory.remember('The ZETADUPLICATE fact is stored once','global',{})
check(dedupe_a==dedupe_b,'an identical fact without an id still dedupes')
local fresh=memory.remember('The ZETAINSERTED fact is new','global',{})
check(fresh~=id and row(fresh)~=nil,'a new fact still inserts')

-- forget still works, and a forgotten id is stale rather than replaceable.
check(memory.forget(id)==true,'forget removes the entry')
check(row(id)==nil,'the forgotten entry is gone')
check(#memory.recall('ZETANEWER')==0,'a forgotten entry is not findable')
local stale=tools.dispatch(memory,'remember',{content='resurrected',id=id},'master',{})
check(stale.error=='memory_not_found','a stale id refuses instead of resurrecting the entry')

-- The journal is what a replica, or a resumed peer, applies - so a correction has to survive replay.
-- Re-delivering the older insert must not resurrect the text it was corrected away from, and the
-- search row must always agree with the row it indexes: the row and the index were written
-- separately here, and an `INSERT OR IGNORE` replay left the row on the new text while the index
-- took the old one, so a search for the superseded word still matched the corrected row.
local function entries_for(memory_id)
  local out={}
  for _,entry in ipairs(memory.journal_since(0,200))do if entry.payload.id==memory_id then out[#out+1]=entry end end
  return out
end
local id2=memory.remember('The ZETAJOURNAL gate runs on ZETAFRIDAYS','global',{'process'})
local rows_after_journal=live()
local older=entries_for(id2)[1]
check(older~=nil,'the insert is journaled for that id')
check(#memory.recall('ZETAFRIDAYS')==1,'the original word is findable before the correction')
check(memory.remember('The ZETAJOURNAL gate now runs on ZETAMONDAYS','global',{'process'},id2)==id2,'the correction replaces in place')
check(#memory.recall('ZETAJOURNAL')==1,'one row answers for the corrected fact')
check(#memory.recall('ZETAFRIDAYS')==0,'the superseded word matches nothing before replay')
check(#memory.recall('ZETAMONDAYS')==1,'the corrected word is the one that matches')
check(memory.apply_entry(older)==true,'replaying the older entry is accepted')
check(row(id2).content:find('ZETAMONDAYS',1,true)~=nil,'replay does not roll the stored row back')
check(#memory.recall('ZETAFRIDAYS')==0,'replay does not put the superseded word back in the index')
check(#memory.recall('ZETAMONDAYS')==1,'replay leaves the corrected word matching once')
check(memory.apply_entry(older)==true,'a second replay is still accepted')
check(#memory.recall('ZETAFRIDAYS')==0 and #memory.recall('ZETAMONDAYS')==1,'a second replay changes nothing')
-- The other half of the same rule, which is the replica's own case: a peer that missed the local
-- correction has the old text in the row, and the newer entry has to *overwrite* it. The insert
-- replayed with an equal stamp applies in delivery order (the journal's own order) and rolls the
-- row back, which is what gives the correction something newer to win against.
local newer=entries_for(id2)[2]
check(newer~=nil and #entries_for(id2)==2,'the correction is its own journal entry')
local rewound={kind=older.kind,op=older.op,payload={}}
for key,value in pairs(older.payload)do rewound.payload[key]=value end
rewound.payload.updated_at=row(id2).updated_at
check(memory.apply_entry(rewound)==true,'an equal-stamped entry is accepted')
check(row(id2).content:find('ZETAFRIDAYS',1,true)~=nil,'an equal stamp applies in delivery order')
check(#memory.recall('ZETAFRIDAYS')==1 and #memory.recall('ZETAMONDAYS')==0,'the index follows the row it indexes')
check(memory.apply_entry(newer)==true,'the newer correction replays over the older text')
check(row(id2).content:find('ZETAMONDAYS',1,true)~=nil,'the newer entry overwrites the stale text')check(#memory.recall('ZETAFRIDAYS')==0 and #memory.recall('ZETAMONDAYS')==1,'the index follows the correction')
check(live()==rows_after_journal,'no replay path inserted a second row')

print('memory replace ok ('..checks..' checks)')
