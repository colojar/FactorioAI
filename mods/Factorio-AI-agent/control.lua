-- agent/control.lua -- Minimal bridge for AI orchestration
-- Exposes:
--   remote.call("agent", "ping")
--   remote.call("agent", "snapshot", { radius = 64 })
--   remote.call("agent", "set_interval", { ticks = 600 })
--   remote.call("agent", "screenshot", { res={x=1280,y=720}, zoom=1.0, gui=false })
--   remote.call("agent", "execute", { ops = { ...audited ops... } })
-- Snapshot JSON -> script-output/agent/snapshots/<tick>.json
-- Screenshots   -> script-output/agent/screenshots/<tick>_p<idx>.png


local SNAP_INTERVAL_TICKS = 600 -- 10s at 60 UPS; adjust as needed


local function rect_around(pos, r)
return {{pos.x - r, pos.y - r}, {pos.x + r, pos.y + r}}
end

local function get_player(args)
	if args and args.player_index then
		return game.players[args.player_index]
	end
	return game.connected_players[1]
end

local function ensure_player()
	local p = get_player(nil)
	if not p then
		return nil, { ok = false, err = "no connected player" }
	end
	return p, nil
end


local function make_snapshot(radius)
	local p = get_player(nil)
	if not p then return { ok = false, err = "no connected player" } end
	local surface = p.surface
	local pos = p.position
	local r = radius or 64
	local area = rect_around(pos, r)

	local ents = surface.find_entities_filtered{ area = area }
	local out = {}
	for _, e in pairs(ents) do
		out[#out+1] = {
			name = e.name,
			type = e.type,
			position = e.position,
			direction = e.direction,
			force = e.force and e.force.name or nil
		}
	end

	local data = {
		tick = game.tick,
		player = {
			position = pos,
			surface = surface.name,
			force = p.force.name
		},
		window = { center = pos, radius = r },
		entities = out
	}

	local json = game.table_to_json(data)
	game.write_file("agent/snapshots/" .. game.tick .. ".json", json .. "\n", false)
	return { ok = true, count = #out, tick = game.tick }
end


remote.add_interface("agent", {
ping = function()
local msg = "[agent] pong " .. game.tick
game.print(msg)
return { ok = true, tick = game.tick }
end,
snapshot = function(args)
local r = 64
if args and args.radius and tonumber(args.radius) then r = tonumber(args.radius) end
return make_snapshot(r)
end,
set_interval = function(args)
if args and args.ticks and tonumber(args.ticks) then
SNAP_INTERVAL_TICKS = math.floor(tonumber(args.ticks))
script.on_nth_tick(nil) -- clear any previous
if SNAP_INTERVAL_TICKS > 0 then
script.on_nth_tick(SNAP_INTERVAL_TICKS, function(_) make_snapshot(64) end)
end
game.print("[agent] interval set to " .. SNAP_INTERVAL_TICKS .. " ticks")
return { ok = true, interval = SNAP_INTERVAL_TICKS }
else
return { ok = false, err = "provide {ticks=<number>}" }
end
end,
-- Capture a deterministic screenshot around the player (no GUI by default)
screenshot = function(args)
	local p, err = ensure_player()
	if not p then return err end
	local res = { x = 1280, y = 720 }
	if args and args.res and args.res.x and args.res.y then
		res = { x = math.floor(args.res.x), y = math.floor(args.res.y) }
	end
	local zoom = 1.0
	if args and args.zoom and tonumber(args.zoom) then
		zoom = tonumber(args.zoom)
	end
	local show_gui = (args and args.gui) and true or false
	local path = string.format(
		"agent/screenshots/%d_p%d.png", game.tick, p.index
	)
	game.take_screenshot{
		player = p,
		position = p.position,
		resolution = res,
		zoom = zoom,
		path = path,
		show_gui = show_gui,
		show_entity_info = false,
		anti_alias = true
	}
	return { ok = true, path = path, tick = game.tick }
end,
-- Audited macro executor with safety checks and rollback.
-- Allowed ops:
--   { kind='place_entity', name='transport-belt', position={x=..,y=..}, direction=defines.direction.east, ghost=true }
--   { kind='set_recipe', position={x=..,y=..}, name='iron-gear-wheel' }
--   { kind='deconstruct_area', area={{x1,y1},{x2,y2}} }
execute = function(args)
	local p, err = ensure_player()
	if not p then return err end
	if not args or not args.ops or type(args.ops) ~= 'table' then
		return { ok=false, err='provide { ops=[...] }' }
	end
	local surface = p.surface
	local force = p.force
	local applied = { created = {}, recipes = {}, decon = {} }

	local function rollback()
		for _, e in pairs(applied.created) do
			if e.valid then e.destroy() end
		end
		for _, rec in pairs(applied.recipes) do
			if rec.entity.valid then rec.entity.set_recipe(rec.old) end
		end
		for _, a in pairs(applied.decon) do
			surface.cancel_deconstruction(a.area, force, p)
		end
	end

	local function place_entity(op)
		if not op.name or not op.position then
			return false, 'place_entity requires name and position'
		end
		local pos = op.position
		if op.ghost then
			local can = surface.can_place_entity{
				name = 'entity-ghost', inner_name = op.name, position = pos, force = force
			}
			if not can then return false, 'cannot place ghost' end
			local ent = surface.create_entity{
				name='entity-ghost', inner_name=op.name, position=pos, force=force,
				direction=op.direction
			}
			if ent then applied.created[#applied.created+1] = ent; return true end
			return false, 'create_entity returned nil'
		else
			-- Only allow real placement if can_place says yes
			local can = surface.can_place_entity{
				name = op.name, position = pos, force = force, direction = op.direction
			}
			if not can then return false, 'cannot place entity' end
			local ent = surface.create_entity{
				name=op.name, position=pos, force=force, direction=op.direction, fast_replace=true
			}
			if ent then applied.created[#applied.created+1] = ent; return true end
			return false, 'create_entity returned nil'
		end
	end

	local function set_recipe(op)
		if not op.name or not op.position then
			return false, 'set_recipe requires name and position'
		end
		local area = rect_around(op.position, 0.5)
		local ents = surface.find_entities_filtered{ area=area, force=force, type='assembling-machine' }
		local target = ents and ents[1]
		if not target then return false, 'no assembler at position' end
		local old = target.get_recipe() and target.get_recipe().name or nil
		local ok = target.set_recipe(op.name)
		if not ok then return false, 'set_recipe failed' end
		applied.recipes[#applied.recipes+1] = { entity = target, old = old }
		return true
	end

	local function deconstruct_area(op)
		if not op.area then return false, 'deconstruct_area requires area' end
		local ok = surface.order_deconstruction(op.area, force, p)
		if not ok then return false, 'order_deconstruction failed' end
		applied.decon[#applied.decon+1] = { area = op.area }
		return true
	end

	for i, op in ipairs(args.ops) do
		local kind = op.kind
		local ok2, e2 = false, nil
		if kind == 'place_entity' then ok2, e2 = place_entity(op)
		elseif kind == 'set_recipe' then ok2, e2 = set_recipe(op)
		elseif kind == 'deconstruct_area' then ok2, e2 = deconstruct_area(op)
		else
			rollback()
			return { ok=false, err='unsupported op: '..tostring(kind), index=i }
		end
		if not ok2 then
			rollback()
			return { ok=false, err=e2 or 'op failed', index=i }
		end
	end

	return { ok = true, applied = {
		created = #applied.created,
		recipes = #applied.recipes,
		deconstruct = #applied.decon
	}}
end
})


-- enable periodic snapshots by default
script.on_init(function()
if SNAP_INTERVAL_TICKS > 0 then
script.on_nth_tick(SNAP_INTERVAL_TICKS, function(_) make_snapshot(64) end)
end
end)

script.on_configuration_changed(function(_)
	script.on_nth_tick(nil)
	if SNAP_INTERVAL_TICKS > 0 then
		script.on_nth_tick(SNAP_INTERVAL_TICKS, function(_) make_snapshot(64) end)
	end
end)
