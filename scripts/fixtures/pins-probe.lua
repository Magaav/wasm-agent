-- Driven by scripts/test-node-pins.sh through the built binary: exercises the pins store the way the
-- product does (set, read back, overdue, released by an awaited commit, clear), so the store, the CLI and the
-- fleet view are tested against the same bytes a node runs.
local pins = dofile('lua/core/pins.lua')
local function say(key, value) print(key .. '=' .. tostring(value)) end
local function trim0(value) return (tostring(value or ''):gsub('^%s+', ''):gsub('%s+$', '')) end

say('path', pins.path())
say('initial_active', pins.active('work') == nil and 'none' or 'pinned')

local held, problem = pins.set({ node = 'work', commit = '1111111111111111111111111111111111111111',
  reason = 'held on the codeact build until it lands', kind = 'rollback', until_ = '2020-01-01',
  await = '2222222222222222222222222222222222222222' })
say('set', held and 'ok' or ('refused:' .. tostring(problem and problem.error)))
say('set_summary', held and held.summary or '')

local active = pins.active('work')
say('active_commit', active and active.commit or 'none')
say('active_reason', active and active.reason or '')
say('active_by_known', active and active.by ~= '' and 'yes' or 'no')
say('active_at_known', active and active.at ~= '' and 'yes' or 'no')
say('active_until', active and active.until_ or 'missing')
say('overdue', tostring(pins.overdue(active)))
say('list_count', #pins.list())
say('overdue_count', #pins.overdue_list())

-- a target that does not contain the awaited commit does not release the pin; one that does, does.
local by_other = pins.released(active, '3333333333333333333333333333333333333333', '')
say('released_by_other', by_other == nil and 'unknown' or tostring(by_other.released))
local by_pinned = pins.released(active, '1111111111111111111111111111111111111111', '')
say('released_by_pinned_commit', tostring(by_pinned and by_pinned.released))

-- a second pin for the same node supersedes the first, and the history is kept
local second = pins.set({ node = 'work', commit = '4444444444444444444444444444444444444444', reason = 'moved again on purpose' })
say('second_supersedes', second and second.supersedes ~= '' and 'yes' or 'no')
say('history_count', #pins.history('work'))
say('active_now', pins.active('work').commit)

local cleared = pins.clear('work', { reason = 'the fix landed' })
say('clear', cleared and 'ok' or 'refused')
say('after_clear_active', pins.active('work') == nil and 'none' or 'still-pinned')
say('clear_reason', cleared and cleared.reason or '')

-- a reason is required: a pin without one is a memory, not a record
local refused, why = pins.set({ node = 'mail', commit = 'x' })
say('no_reason', refused == nil and 'refused' or 'accepted')
say('no_reason_error', why and why.error or '')

-- the fleet view reads the same store
local fleetview = dofile('lua/core/fleetview.lua')
pins.set({ node = 'nextcloud', commit = '5555555555555555555555555555555555555555', reason = 'glibc 2.30 binary', until_ = '2020-01-01' })
local row = fleetview.node({ name = 'this', local_node = true, online = true, pins = pins.list() })
say('fleet_pins', #(row.pins or {}))
say('fleet_overdue', #(row.pins_overdue or {}))
say('fleet_summary_has_reason', (row.pins and row.pins[1] and row.pins[1].reason ~= '') and 'yes' or 'no')
-- A peer does not carry this coordinator's store, so its record says the field is absent - and it does NOT
-- report it in 'missing', which is for a fact that this report tried to read and could not.
local bare = fleetview.node({ name = 'peer', online = false })
local in_missing = false
for _, field in ipairs(bare.missing or {}) do if field == 'pins' then in_missing = true end end
say('fleet_peer_pins_absent', bare.pins_absent == true and 'yes' or 'no')
say('fleet_peer_pins_not_missing', in_missing and 'listed' or 'not-listed')

-- ---- item 6: a pin is found by the name it was written under AND by the node's id ----------------
-- A rollback records the node the operator named ("work"); the node's own store records its name and its
-- node_id. A gate that compared one spelling would miss the pin, so both are asked.
local edge = pins.set({ node = 'edge', node_id = 'aabbccddeeff0011', commit = '7777777777777777777777777777777777777777',
  reason = 'held under a name and an id' })
say('edge_set', edge and 'ok' or 'refused')
say('edge_by_name', tostring(pins.active('edge') ~= nil))
say('edge_by_id', tostring(pins.active('', 'aabbccddeeff0011') ~= nil))
say('edge_by_name_and_id', tostring(pins.active('edge', 'aabbccddeeff0011') ~= nil))
say('edge_by_other_id', tostring(pins.active('another-node', 'ffffffffffffffff') ~= nil))
say('edge_record_carries_id', edge and edge.node_id or 'missing')

-- ---- item 5: a target that CONTAINS the awaited commit releases the pin ------------------------
-- "Release" used to require target == await exactly, so a pin whose awaited fix landed in a descendant never
-- released: the pin blocked its own fix and only --unpin by hand could move the node.
local handle = io.popen('mktemp -d')
local repo = handle and handle:read('*a') or ''
if handle then handle:close() end
repo = (repo:gsub('%s+$', ''))
local function sh(command) local h = io.popen(command .. ' 2>/dev/null'); if not h then return '' end local out = h:read('*a') or ''; h:close(); return (out:gsub('%s+$', '')) end
local function ok_git() return repo ~= '' and sh("cd '" .. repo .. "' && git init -q && git config user.email t@example.com && git config user.name t && printf a > f && git add f && git commit -qm one && git rev-parse HEAD") ~= '' end
if ok_git() then
  local first = sh("git -C '" .. repo .. "' rev-parse HEAD")
  sh("cd '" .. repo .. "' && printf b > g && git add g && git commit -qm two")
  local second = sh("git -C '" .. repo .. "' rev-parse HEAD")
  local held = pins.set({ node = 'edge2', commit = 'unknown', rolled_back_from = first, await = first,
    reason = 'rolled back from that commit', kind = 'rollback' })
  say('contain_repo', 'yes')
  say('contain_pin_await', held and held.await or 'missing')
  say('contain_pin_from', first)
  local by_containment = pins.released(held, second, repo)
  say('released_by_containment', by_containment and tostring(by_containment.released) or 'unknown')
  say('released_by_containment_why', by_containment and tostring(by_containment.why) or '')
  local unrelated = pins.released(held, first, repo)
  say('released_by_the_awaited_commit_itself', unrelated and tostring(unrelated.released) or 'unknown')
  local no_tree = pins.released(held, second, '')
  say('no_tree_is_unknown', no_tree == nil and 'unknown' or tostring(no_tree.released))
  -- the escape hatch is one sentence an operator can act on
  say('escape_mentions_unpin', tostring(pins.escape_hatch('edge')):find('--unpin', 1, true) ~= nil and 'yes' or 'no')

  -- ---- round-3 item 2: a rollback pin has NO default awaited commit ----------------------------
  -- The awaited commit used to default to the one the rollback went BACK FROM - the history that contains the
  -- change being held off - so the next ordinary deploy of main contained it and released the pin on exactly the
  -- move it was written to stop.
  local held_back = pins.set({ node = 'rb', commit = 'unknown', rolled_back_from = first,
    reason = 'rolled back from that commit', kind = 'rollback' })
  say('rollback_has_no_default_await', (held_back and trim0(held_back.await) == '') and 'yes' or 'no')
  say('rollback_keeps_rolled_back_from', held_back and held_back.rolled_back_from or 'missing')
  local by_from = pins.released(held_back, second, repo)
  say('rollback_not_released_by_the_commit_it_went_back_from', by_from and tostring(by_from.released) or 'unknown')
  say('rollback_released_by_its_own_commit', tostring((pins.released(held_back, 'unknown', repo) or {}).released))
  -- round-3 item 6: the way out says what releases THIS pin
  local escape_no_await = tostring(pins.escape_hatch('rb', held_back))
  say('escape_no_await_does_not_promise_a_deploy',
    escape_no_await:find('no ordinary deploy releases it', 1, true) ~= nil and 'yes' or 'no')
  say('escape_no_await_names_unpin', escape_no_await:find('--unpin', 1, true) ~= nil and 'yes' or 'no')
  local escape_with_await = tostring(pins.escape_hatch('edge2', held))
  say('escape_with_await_names_it',
    escape_with_await:find('contains the awaited commit', 1, true) ~= nil and 'yes' or 'no')

  -- ---- round-4 item 7: an await that IS the commit the pin rolled back from is ignored on read ----------
  -- Pins already on live nodes carry it: before round 3 the writer DEFAULTED await to rolled_back_from, so
  -- honouring it releases each pin on the very move it exists to stop. The record below is written the way those
  -- files hold it (raw text, no await_explicit marker) because the writer cannot produce that shape any more.
  local legacy_handle = io.open(pins.path(), 'a')
  if legacy_handle then
    legacy_handle:write('\nschema=wasm-agent-pins/1\nid=1egacy0001\nnode=legacy-node\nkind=rollback\nstate=active\ncommit=unknown\nrolled_back_from=' .. first .. '\nawait=' .. first .. '\nreason=written before the default was removed\n\n')
    legacy_handle:close()
  end
  local legacy_active = pins.active('legacy-node')
  say('legacy_pin_found', legacy_active and 'yes' or 'no')
  say('legacy_await_ignored', (legacy_active and trim0(legacy_active.await) == '') and 'yes' or 'no')
  say('legacy_await_note', legacy_active and trim0(legacy_active.await_ignored) or 'missing')
  say('legacy_not_released_by_containment',
    tostring((pins.released(legacy_active, second, repo) or {}).released))
  say('legacy_summary_says_ignored',
    (pins.summary_line(legacy_active):find('IGNORED', 1, true) ~= nil) and 'yes' or 'no')
  -- ...and the same await NAMED by an operator is kept: the marker is what separates a statement from a default
  local explicit_pin = pins.set({ node = 'explicit-node', commit = 'unknown', rolled_back_from = first,
    await = first, reason = 'the operator named the commit it went back from' })
  local explicit_active = pins.active('explicit-node')
  say('explicit_await_kept', (explicit_active and trim0(explicit_active.await) == first) and 'yes' or 'no')
  say('explicit_marker_written', explicit_pin and trim0(explicit_pin.await_explicit) or 'missing')
  say('explicit_released_by_containment',
    tostring((pins.released(explicit_active, second, repo) or {}).released))
else
  say('contain_repo', 'no git')
end
