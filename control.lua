-- WePlay: Choo-Choo Taxi
-- A personal shuttle train that rides the Space Exploration space elevator.

local util = require("__core__.lualib.util")

local SEARCH_RANGE = 16
local GUI_NAME = "wp-cct-picker"
local SHORTCUT = "wp-choo-choo-taxi"

local RAIL_TYPES = {
  "straight-rail",
  "curved-rail-a",
  "curved-rail-b",
  "half-diagonal-rail",
  "elevated-straight-rail",
  "elevated-curved-rail-a",
  "elevated-curved-rail-b",
  "elevated-half-diagonal-rail",
  "legacy-straight-rail",
  "legacy-curved-rail",
}

-- True while this mod is rewriting a schedule, so the brief manual-mode flip is ignored.
local busy = false

---------------------------------------------------------------------------
-- Storage
--
-- storage.taxis[player_index] = {
--   loco          LuaEntity   the taxi's locomotive (replaced after an elevator ride)
--   train_id      uint        id of the LuaTrain the locomotive belongs to
--   state         "idle" | "pickup" | "transport"
--   target        { surface_index, rail = LuaEntity?, station = string? }
--   in_elevator   bool        true while SE is moving the train between surfaces
--   elevator_ids  { [train_id] = true }  ids the train had when it entered the elevator
-- }
-- storage.owner[train_id] = player_index
---------------------------------------------------------------------------

local function init_storage()
  storage.taxis = storage.taxis or {}
  storage.owner = storage.owner or {}
  -- storage.depots[player_index][surface_index] = station name
  storage.depots = storage.depots or {}
end

local function get_depot(player_index, surface_index)
  local d = storage.depots[player_index]
  return d and d[surface_index]
end

local function msg(player, text)
  if player and player.valid then
    player.print(text)
  end
end

local function flying(player, text)
  if player and player.valid then
    player.create_local_flying_text({ text = text, position = player.position })
  end
end

local function honk(player)
  if not (player and player.valid) then return end
  if not player.mod_settings["wp-cct-honk"].value then return end
  local path = "utility/new_objective"
  if helpers.is_valid_sound_path(path) then
    player.play_sound({ path = path })
  end
end

local function surface_label(surface)
  local name = surface.name
  return (name:gsub("^%l", string.upper))
end

local function train_label(train)
  local loco = train and train.valid and (train.front_stock or train.back_stock)
  return loco and loco.valid and loco.backer_name or "?"
end

---------------------------------------------------------------------------
-- Taxi bookkeeping
---------------------------------------------------------------------------

---@param train LuaTrain
---@return LuaSurface
local function train_surface(train)
  local stock = train.front_stock or train.back_stock or train.carriages[1]
  return stock.surface
end

---@param train LuaTrain
---@return LuaEntity?
local function pick_loco(train)
  local locos = train.locomotives
  return locos.front_movers[1] or locos.back_movers[1]
end

local function bind(player_index, data, train)
  if data.train_id then
    storage.owner[data.train_id] = nil
  end
  data.train_id = train.id
  local loco = data.loco
  if not (loco and loco.valid and loco.train == train) then
    data.loco = pick_loco(train)
  end
  storage.owner[train.id] = player_index
end

local function forget(player_index)
  local data = storage.taxis[player_index]
  if not data then return end
  if data.train_id then storage.owner[data.train_id] = nil end
  for id in pairs(data.elevator_ids or {}) do
    if storage.owner[id] == player_index then storage.owner[id] = nil end
  end
  storage.taxis[player_index] = nil
end

--- Returns the taxi data and its LuaTrain (train is nil while in the elevator or if gone).
local function get_taxi(player)
  local data = storage.taxis[player.index]
  if not data then return nil, nil end
  local loco = data.loco
  if loco and loco.valid and loco.train and loco.train.valid then
    local train = loco.train
    if train.id ~= data.train_id then bind(player.index, data, train) end
    return data, train
  end
  return data, nil
end

local function set_idle(data)
  data.state = "idle"
  data.target = nil
end

---------------------------------------------------------------------------
-- Space Exploration: space elevator helpers
---------------------------------------------------------------------------

local function se_active()
  return remote.interfaces["space-exploration"] ~= nil
end

local function is_elevator_stop(stop)
  if stop.name:find("elevator", 1, true) then return true end
  local backer = stop.backer_name or ""
  return backer:find("se-space-elevator", 1, true) ~= nil
end

---@return LuaEntity?
local function find_elevator_stop(surface)
  for _, stop in pairs(surface.find_entities_filtered({ type = "train-stop" })) do
    if is_elevator_stop(stop) then return stop end
  end
  return nil
end

local function se_zone(surface_index)
  if not se_active() then return nil end
  local ok, zone = pcall(remote.call, "space-exploration", "get_zone_from_surface_index",
    { surface_index = surface_index })
  if ok and type(zone) == "table" then return zone end
  return nil
end

--- Is there an SE elevator link between these two surfaces (planet <-> its orbit)?
local function surfaces_linked(a, b)
  if a == b then return false end
  local za, zb = se_zone(a.index), se_zone(b.index)
  if za and zb and za.index and zb.index then
    if za.orbit_index == zb.index or zb.orbit_index == za.index then return true end
    if za.type == "orbit" and za.parent_index == zb.index then return true end
    if zb.type == "orbit" and zb.parent_index == za.index then return true end
    return false
  end
  -- Fallback: SE names orbits "<Planet> Orbit".
  local na, nb = a.name:lower(), b.name:lower()
  return na .. " orbit" == nb or nb .. " orbit" == na
end

--- The elevator stop on `from` that leads to `to`, if both ends exist.
---@return LuaEntity?
local function elevator_between(from, to)
  if not se_active() then return nil end
  if not surfaces_linked(from, to) then return nil end
  local here = find_elevator_stop(from)
  if here and find_elevator_stop(to) then return here end
  return nil
end

---------------------------------------------------------------------------
-- Scheduling
---------------------------------------------------------------------------

local function rail_record(rail)
  return {
    rail = rail,
    temporary = true,
    wait_conditions = { { type = "time", compare_type = "and", ticks = 60 } },
  }
end

local function station_record(name)
  return {
    station = name,
    wait_conditions = { { type = "time", compare_type = "and", ticks = 60 } },
  }
end

local function elevator_record(stop)
  return { station = stop.backer_name }
end

---@param train LuaTrain
local function set_records(train, records)
  busy = true
  local interrupts = train.get_schedule().get_interrupts()
  train.manual_mode = true
  train.schedule = { current = 1, records = records }
  train.get_schedule().set_interrupts(interrupts)
  train.manual_mode = false
  busy = false
end

local function target_record(target)
  if target.rail then
    if not target.rail.valid then return nil end
    return rail_record(target.rail)
  end
  return station_record(target.station)
end

--- Start (or continue) driving the taxi toward data.target.
---@return boolean ok, string? problem
local function drive(data, train)
  local target = data.target
  local dest_surface = game.get_surface(target.surface_index)
  if not dest_surface then return false, "no-surface" end

  if train_surface(train).index == target.surface_index then
    local rec = target_record(target)
    if not rec then return false, "target-gone" end
    set_records(train, { rec })
    return true
  end

  local stop = elevator_between(train_surface(train), dest_surface)
  if not stop then return false, "no-elevator" end
  local records = { elevator_record(stop) }
  -- Station names carry across surfaces, so add it now; a rail gets added after the ride.
  if target.station then table.insert(records, station_record(target.station)) end
  set_records(train, records)
  return true, "elevator"
end

---------------------------------------------------------------------------
-- Finding things near the player
---------------------------------------------------------------------------

local function nearest(entities, position)
  local best, best_d
  for _, e in pairs(entities) do
    local d = util.distance(position, e.position)
    if not best_d or d < best_d then best, best_d = e, d end
  end
  return best
end

--- A rail near the player for the taxi to stop on (prefers a train stop's rail).
---@return LuaEntity?
local function find_pickup_rail(player)
  local surface, pos = player.physical_surface, player.physical_position
  local stops = surface.find_entities_filtered({
    type = "train-stop", force = player.force, position = pos, radius = SEARCH_RANGE,
  })
  local usable = {}
  for _, s in pairs(stops) do
    if not is_elevator_stop(s) and s.connected_rail then table.insert(usable, s) end
  end
  local stop = nearest(usable, pos)
  if stop then return stop.connected_rail end

  local rails = surface.find_entities_filtered({
    type = RAIL_TYPES, force = player.force, position = pos, radius = SEARCH_RANGE,
    to_be_deconstructed = false,
  })
  return nearest(rails, pos)
end

---------------------------------------------------------------------------
-- Destination picker GUI
---------------------------------------------------------------------------

local function close_picker(player)
  local frame = player.gui.screen[GUI_NAME]
  if frame then frame.destroy() end
end

--- { {surface=LuaSurface, via_elevator=bool, names={...}}, ... }
local function destination_groups(player, train)
  local groups = {}
  local function collect(surface, via)
    local seen, names = {}, {}
    for _, s in pairs(surface.find_entities_filtered({ type = "train-stop", force = player.force })) do
      local n = s.backer_name
      if not is_elevator_stop(s) and n and not seen[n] then
        seen[n] = true
        table.insert(names, n)
      end
    end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    if #names > 0 then
      table.insert(groups, { surface = surface, via_elevator = via, names = names })
    end
  end

  collect(train_surface(train), false)
  if se_active() and find_elevator_stop(train_surface(train)) then
    for _, other in pairs(game.surfaces) do
      if other ~= train_surface(train) and elevator_between(train_surface(train), other) then
        collect(other, true)
      end
    end
  end
  return groups
end

local function fill_picker(player)
  local frame = player.gui.screen[GUI_NAME]
  if not frame then return end
  local _, train = get_taxi(player)
  if not train then close_picker(player) return end

  local list = frame.inner.list
  list.clear()
  local filter = frame.inner.search.text:lower()

  local any = false
  for _, group in pairs(destination_groups(player, train)) do
    local shown = {}
    for _, name in pairs(group.names) do
      if filter == "" or name:lower():find(filter, 1, true) then table.insert(shown, name) end
    end
    if #shown > 0 then
      any = true
      local caption = { "", "[font=default-bold]", surface_label(group.surface), "[/font]" }
      if group.via_elevator then
        caption = { "", caption, "  ", { "wp-cct.via-elevator" } }
      end
      local header = list.add({ type = "label", caption = caption })
      header.style.top_margin = 6
      local depot = get_depot(player.index, group.surface.index)
      for _, name in pairs(shown) do
        local row = list.add({ type = "flow", direction = "horizontal" })
        row.style.vertical_align = "center"
        local b = row.add({
          type = "button",
          caption = name == depot and { "", "[img=item/train-stop] ", name } or name,
          tags = { wp_cct_dest = true, surface_index = group.surface.index, station = name },
        })
        b.style.horizontally_stretchable = true
        b.style.horizontal_align = "left"
        row.add({
          type = "sprite-button",
          sprite = "item/train-stop",
          style = "tool_button",
          toggled = name == depot,
          tooltip = name == depot and { "wp-cct.unset-depot-tooltip", surface_label(group.surface) }
            or { "wp-cct.set-depot-tooltip", surface_label(group.surface) },
          tags = { wp_cct_depot = true, surface_index = group.surface.index, station = name },
        })
      end
    end
  end
  if not any then
    list.add({ type = "label", caption = { "wp-cct.no-stations" } })
  end
end

local function open_picker(player)
  close_picker(player)
  local frame = player.gui.screen.add({ type = "frame", name = GUI_NAME, direction = "vertical" })

  local bar = frame.add({ type = "flow", direction = "horizontal" })
  bar.drag_target = frame
  bar.add({ type = "sprite", sprite = "wp-choo-choo-taxi-icon", resize_to_sprite = false,
    ignored_by_interaction = true }).style.size = 24
  bar.add({ type = "label", caption = { "wp-cct.title" }, style = "frame_title", ignored_by_interaction = true })
  local drag = bar.add({ type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true })
  drag.style.horizontally_stretchable = true
  drag.style.height = 24
  bar.add({ type = "sprite-button", name = "wp-cct-close", sprite = "utility/close",
    style = "frame_action_button" })

  local inner = frame.add({ type = "frame", name = "inner", direction = "vertical",
    style = "inside_shallow_frame_with_padding" })
  local search = inner.add({ type = "textfield", name = "search" })
  search.style.horizontally_stretchable = true
  search.tooltip = { "wp-cct.search-tooltip" }
  local list = inner.add({ type = "scroll-pane", name = "list", direction = "vertical" })
  list.style.maximal_height = 420
  list.style.minimal_width = 300

  frame.force_auto_center()
  player.opened = frame
  fill_picker(player)
  search.focus()
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

local function register(player, loco)
  local train = loco.train
  if not train then return end
  local old = storage.taxis[player.index]
  if old and old.loco == loco then
    msg(player, { "wp-cct.already", loco.backer_name })
    return
  end
  for pid, data in pairs(storage.taxis) do
    if pid ~= player.index and data.loco == loco then
      msg(player, { "wp-cct.taken" })
      return
    end
  end
  forget(player.index)

  if train.group and train.group ~= "" then
    pcall(function() train.group = "" end)
    msg(player, { "wp-cct.left-group" })
  end

  local data = { loco = loco, state = "idle", elevator_ids = {} }
  storage.taxis[player.index] = data
  bind(player.index, data, train)
  player.opened = nil
  msg(player, { "wp-cct.registered", loco.backer_name })
  flying(player, { "wp-cct.registered-short" })
  honk(player)
end

--- Send an idle, empty taxi to its depot on the surface it's on.
---@return boolean sent
local function send_to_depot(player, data, train, quiet)
  local surface = train_surface(train)
  local depot_surface = surface
  local depot = get_depot(player.index, surface.index)
  if not depot then
    -- No depot here? Use the one on the other end of the space elevator.
    for surface_index, name in pairs(storage.depots[player.index] or {}) do
      local other = game.get_surface(surface_index)
      if other and elevator_between(surface, other) then
        depot, depot_surface = name, other
        break
      end
    end
  end
  if not depot then
    if not quiet then msg(player, { "wp-cct.no-depot", surface_label(surface) }) end
    return false
  end
  if train.station and train.station.valid and train.station.backer_name == depot then
    if not quiet then msg(player, { "wp-cct.already-at-depot" }) end
    return false
  end
  if #train.passengers > 0 then return false end
  data.state = "depot"
  data.target = { surface_index = depot_surface.index, station = depot }
  local ok, how = drive(data, train)
  if not ok then
    set_idle(data)
    msg(player, { "wp-cct.cant-go", depot })
    return false
  end
  if how == "elevator" then
    msg(player, { "wp-cct.going-home-elevator", depot, surface_label(depot_surface) })
  else
    msg(player, { "wp-cct.going-home", depot })
  end
  return true
end

local function call_taxi(player)
  local data, train = get_taxi(player)
  if not data then
    msg(player, { "wp-cct.no-taxi" })
    return
  end
  if not train then
    if data.in_elevator then
      msg(player, { "wp-cct.in-elevator" })
    else
      forget(player.index)
      msg(player, { "wp-cct.gone" })
    end
    return
  end

  local loco = data.loco
  if train_surface(train).index == player.physical_surface_index
    and util.distance(loco.position, player.physical_position) <= SEARCH_RANGE then
    -- Standing next to it? The button sends it home instead.
    if #train.passengers == 0 then
      send_to_depot(player, data, train, false)
    else
      msg(player, { "wp-cct.right-here" })
    end
    return
  end
  for _, p in pairs(train.passengers) do
    if p ~= player then
      msg(player, { "wp-cct.occupied", p.name })
      return
    end
  end

  local rail = find_pickup_rail(player)
  if not rail then
    msg(player, { "wp-cct.no-rail" })
    return
  end

  data.state = "pickup"
  data.target = { surface_index = rail.surface_index, rail = rail }
  local ok, how = drive(data, train)
  if not ok then
    set_idle(data)
    if how == "no-elevator" then
      msg(player, { "wp-cct.no-elevator", surface_label(train_surface(train)) })
    else
      msg(player, { "wp-cct.no-rail" })
    end
    return
  end

  if how == "elevator" then
    msg(player, { "wp-cct.coming-elevator", surface_label(train_surface(train)) })
  else
    msg(player, { "wp-cct.coming", math.floor(util.distance(loco.position, player.physical_position)) })
  end
  flying(player, { "wp-cct.coming-short" })
end

local function go_to(player, surface_index, station)
  local data, train = get_taxi(player)
  if not (data and train) then return end
  if not (player.vehicle and player.vehicle.train == train) then return end

  data.state = "transport"
  data.target = { surface_index = surface_index, station = station }
  local ok, how = drive(data, train)
  if not ok then
    set_idle(data)
    msg(player, { "wp-cct.cant-go", station })
    return
  end
  close_picker(player)
  if how == "elevator" then
    msg(player, { "wp-cct.going-elevator", station, surface_label(game.get_surface(surface_index)) })
  else
    msg(player, { "wp-cct.going", station })
  end
end

local function riding_own_taxi(player)
  local _, train = get_taxi(player)
  return train and player.vehicle and player.vehicle.valid and player.vehicle.train == train
end

local function on_shortcut_or_key(player)
  -- Looking at a locomotive? Make it the taxi.
  if player.opened_gui_type == defines.gui_type.entity then
    local opened = player.opened
    if opened and opened.valid and opened.type == "locomotive" then
      register(player, opened)
      return
    end
  end
  if riding_own_taxi(player) then
    if player.gui.screen[GUI_NAME] then close_picker(player) else open_picker(player) end
    return
  end
  call_taxi(player)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

script.on_event(defines.events.on_lua_shortcut, function(event)
  if event.prototype_name ~= SHORTCUT then return end
  local player = game.get_player(event.player_index)
  if player then on_shortcut_or_key(player) end
end)

script.on_event("wp-choo-choo-taxi", function(event)
  local player = game.get_player(event.player_index)
  if player then on_shortcut_or_key(player) end
end)

script.on_event(defines.events.on_train_created, function(event)
  for _, old in pairs({ event.old_train_id_1, event.old_train_id_2 }) do
    local pid = storage.owner[old]
    local data = pid and storage.taxis[pid]
    if data and not data.in_elevator then
      local loco = data.loco
      if (loco and loco.valid and loco.train == event.train)
        or (not (loco and loco.valid) and pick_loco(event.train)) then
        bind(pid, data, event.train)
      end
    end
  end
end)

local function arrived(player, data, train)
  busy = true
  train.manual_mode = true
  busy = false
  local kind = data.state
  set_idle(data)
  if kind == "pickup" then
    msg(player, { "wp-cct.arrived", train_label(train) })
    flying(player, { "wp-cct.arrived-short" })
  elseif kind == "depot" then
    return -- quietly parked
  else
    msg(player, { "wp-cct.dropped-off" })
  end
  honk(player)
end

script.on_event(defines.events.on_train_changed_state, function(event)
  if busy then return end
  local train = event.train
  local pid = storage.owner[train.id]
  local data = pid and storage.taxis[pid]
  if not data or data.state == "idle" or data.in_elevator then return end
  local player = game.get_player(pid)
  local target = data.target
  if not target then set_idle(data) return end

  local state = train.state
  if state == defines.train_state.wait_station then
    if train_surface(train).index ~= target.surface_index then return end
    if target.station then
      if train.station and train.station.backer_name == target.station then
        arrived(player, data, train)
      end
    else
      local sched = train.schedule
      local rec = sched and sched.records[sched.current]
      if rec and rec.rail then arrived(player, data, train) end
    end
  elseif state == defines.train_state.no_path or state == defines.train_state.path_lost then
    busy = true
    train.manual_mode = true
    busy = false
    set_idle(data)
    msg(player, { "wp-cct.lost", train_label(train) })
  elseif state == defines.train_state.manual_control then
    -- Player (or another mod) took over: stop managing it.
    if event.old_state ~= defines.train_state.manual_control then set_idle(data) end
  end
end)

script.on_event(defines.events.on_player_driving_changed_state, function(event)
  local player = game.get_player(event.player_index)
  if not player then return end
  if riding_own_taxi(player) then
    if player.mod_settings["wp-cct-open-on-enter"].value then open_picker(player) end
    return
  end
  close_picker(player)

  -- Stepped out of the taxi after the ride? Send it back to the depot.
  local entity = event.entity
  if not (entity and entity.valid and entity.train) then return end
  local data, train = get_taxi(player)
  if not (data and train and entity.train == train) then return end
  if data.state ~= "idle" then return end
  if not player.mod_settings["wp-cct-auto-depot"].value then return end
  send_to_depot(player, data, train, true)
end)

script.on_event(defines.events.on_gui_click, function(event)
  local element = event.element
  if not (element and element.valid) then return end
  local player = game.get_player(event.player_index)
  if not player then return end
  if element.name == "wp-cct-close" then
    close_picker(player)
    return
  end
  local tags = element.tags
  if tags and tags.wp_cct_dest then
    go_to(player, tags.surface_index, tags.station)
  elseif tags and tags.wp_cct_depot then
    storage.depots[player.index] = storage.depots[player.index] or {}
    local depots = storage.depots[player.index]
    local surface = game.get_surface(tags.surface_index)
    local label = surface and surface_label(surface) or "?"
    if depots[tags.surface_index] == tags.station then
      depots[tags.surface_index] = nil
      msg(player, { "wp-cct.depot-cleared", label })
    else
      depots[tags.surface_index] = tags.station
      msg(player, { "wp-cct.depot-set", tags.station, label })
    end
    fill_picker(player)
  end
end)

script.on_event(defines.events.on_gui_text_changed, function(event)
  if event.element.name == "search" and event.element.parent
    and event.element.parent.parent and event.element.parent.parent.name == GUI_NAME then
    fill_picker(game.get_player(event.player_index))
  end
end)

-- Pressing Enter in the search box goes to the first match.
script.on_event(defines.events.on_gui_confirmed, function(event)
  local el = event.element
  if not (el.name == "search" and el.parent and el.parent.parent and el.parent.parent.name == GUI_NAME) then
    return
  end
  local player = game.get_player(event.player_index)
  for _, row in pairs(el.parent.list.children) do
    for _, child in pairs(row.children) do
      local tags = child.tags
      if tags and tags.wp_cct_dest then
        go_to(player, tags.surface_index, tags.station)
        return
      end
    end
  end
end)

script.on_event(defines.events.on_gui_closed, function(event)
  if event.element and event.element.valid and event.element.name == GUI_NAME then
    close_picker(game.get_player(event.player_index))
  end
end)

---------------------------------------------------------------------------
-- Space Exploration elevator events
---------------------------------------------------------------------------

local function find_taxi_for_old_train(old_id)
  if old_id then
    local pid = storage.owner[old_id]
    if pid and storage.taxis[pid] then return pid, storage.taxis[pid] end
    for p, data in pairs(storage.taxis) do
      if data.elevator_ids and data.elevator_ids[old_id] then return p, data end
    end
  end
  -- Fallback: exactly one taxi is mid-elevator and has lost its locomotive.
  local found_pid, found
  for p, data in pairs(storage.taxis) do
    if data.in_elevator and not (data.loco and data.loco.valid) then
      if found then return nil end
      found_pid, found = p, data
    end
  end
  return found_pid, found
end

local function on_teleport_started(event)
  local id = (event.train and event.train.valid and event.train.id) or event.old_train_id_1
  local pid = id and storage.owner[id]
  local data = pid and storage.taxis[pid]
  if not data then return end
  data.in_elevator = true
  data.elevator_ids = data.elevator_ids or {}
  data.elevator_ids[id] = true
  storage.owner[id] = pid
end

local function on_teleport_finished(event)
  local train = event.train
  if not (train and train.valid) then return end
  local old_id = event.old_train_id_1 or event.old_train_id
  local pid, data = find_taxi_for_old_train(old_id)
  if not data then return end

  for id in pairs(data.elevator_ids or {}) do
    if storage.owner[id] == pid then storage.owner[id] = nil end
  end
  data.elevator_ids = {}
  data.in_elevator = false
  data.loco = nil
  bind(pid, data, train)

  local player = game.get_player(pid)
  if not data.loco then
    -- The locomotive got left behind ("stranded"); can't drive this one.
    msg(player, { "wp-cct.stranded" })
    forget(pid)
    return
  end

  if data.state ~= "idle" and data.target then
    local ok = drive(data, train)
    if not ok then
      train.manual_mode = true
      set_idle(data)
      msg(player, { "wp-cct.lost", train_label(train) })
    end
  end
end

local function register_se_events()
  local iface = remote.interfaces["space-exploration"]
  if not iface then return end
  if iface.get_on_train_teleport_started_event then
    script.on_event(remote.call("space-exploration", "get_on_train_teleport_started_event"), on_teleport_started)
  end
  if iface.get_on_train_teleport_finished_event then
    script.on_event(remote.call("space-exploration", "get_on_train_teleport_finished_event"), on_teleport_finished)
  end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

script.on_init(function()
  init_storage()
  register_se_events()
end)

script.on_load(function()
  register_se_events()
end)

script.on_configuration_changed(function()
  init_storage()
  for pid, data in pairs(storage.taxis) do
    if not (data.loco and data.loco.valid) and not data.in_elevator then forget(pid) end
  end
end)

commands.add_command("choo-choo-release", { "wp-cct.release-help" }, function(cmd)
  local player = game.get_player(cmd.player_index)
  if not player then return end
  if storage.taxis[player.index] then
    forget(player.index)
    msg(player, { "wp-cct.released" })
  else
    msg(player, { "wp-cct.no-taxi" })
  end
end)
