-- Driven by scripts/test-node-pins.sh through the built binary: exercises the pins store the way the
-- product does (set, read back, overdue, released by an awaited commit, clear), so the store, the CLI and the
-- fleet view are tested against the same bytes a node runs.
local pins = dofile('lua/core/pins.lua')
local function say(key, value) print(key .. '=' .. tostring(value)) end

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
