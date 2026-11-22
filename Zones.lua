-- Which quests belong where: those a giver in the area starts, and those the quest log files under the area.
-- QuestieDB says who starts each quest (NPCs, objects and items) and where they are;
-- this indexes that by area, in the background, the first time a zone view asks. Then, for an area, it builds
-- a model (chains, single quests, the objects and items that start quests, and the quest givers) and works out
-- each quest's status for you, including "missed".
local ADDON, ns = ...
local Core, Data = ns.Core, ns.Data
local Zones = {}
ns.Zones = Zones

Zones.state = "idle" -- idle | building | ready | error
Zones.progress = 0
Zones.error = nil

local MAX_DROPPERS = 40
local starts = {}    -- [area] = { { q = questId, kind = "npc"|"object"|"item", g = giverId }, ... }
local areaCache = {} -- ["npc:123"] = { [area] = true }
local models, infos = {}, {}
local listCache
local waiting, worker, driver = {}, nil, nil

local function addAreas(set, spawns)
  if type(spawns) ~= "table" then return end
  for area, pts in pairs(spawns) do
    if type(area) == "number" and area > 0 and type(pts) == "table" then set[area] = true end
  end
end

-- The areas a quest giver stands in; an item is where the things that drop it stand.
local function giverAreas(kind, id)
  local key = kind .. ":" .. id
  local hit = areaCache[key]
  if hit then return hit end
  local set = {}
  if kind == "npc" then
    addAreas(set, NpcDB and NpcDB.spawns and NpcDB.spawns(id))
  elseif kind == "object" then
    addAreas(set, ObjectDB and ObjectDB.spawns and ObjectDB.spawns(id))
  else
    for i, n in ipairs((ItemDB and ItemDB.npcDrops and ItemDB.npcDrops(id)) or {}) do
      if i > MAX_DROPPERS then break end
      addAreas(set, NpcDB and NpcDB.spawns and NpcDB.spawns(n))
    end
    for i, o in ipairs((ItemDB and ItemDB.objectDrops and ItemDB.objectDrops(id)) or {}) do
      if i > MAX_DROPPERS then break end
      addAreas(set, ObjectDB and ObjectDB.spawns and ObjectDB.spawns(o))
    end
  end
  areaCache[key] = set
  return set
end

local KINDS = { "npc", "object", "item" } -- the order of QuestieDB's startedBy lists

local function build()
  local qids = QuestDB.GetAllIds()
  local n = #qids
  for i = 1, n do
    local id = qids[i]
    local t = QuestDB.startedBy and QuestDB.startedBy(id)
    if type(t) == "table" then
      -- The zone the game's quest log files the quest under. A quest you hold shows under that zone's header, so
      -- the zone view lists it there too, even when its giver stands elsewhere or has no known spawn.
      local zone = QuestDB.zoneOrSort and QuestDB.zoneOrSort(id)
      if type(zone) ~= "number" or zone <= 0 then zone = nil end
      for ki, kind in ipairs(KINDS) do
        for _, g in ipairs(t[ki] or {}) do
          local areas = giverAreas(kind, g)
          for area in pairs(areas) do
            local list = starts[area]
            if not list then list = {}; starts[area] = list end
            list[#list + 1] = { q = id, kind = kind, g = g }
          end
          if zone and not areas[zone] then
            local list = starts[zone]
            if not list then list = {}; starts[zone] = list end
            list[#list + 1] = { q = id, kind = kind, g = g }
          end
        end
      end
    end
    if i % 25 == 0 then Zones.progress = i / n; coroutine.yield() end
  end
end

local function finish(ok, err)
  if driver then driver:SetScript("OnUpdate", nil) end
  if ok then Zones.state, Zones.progress = "ready", 1 else Zones.state, Zones.error = "error", tostring(err) end
  local list = waiting
  waiting = {}
  for _, fn in ipairs(list) do fn() end
end

local function step()
  local start = debugprofilestop and debugprofilestop() or 0
  local spins = 0
  while true do
    local ok, err = coroutine.resume(worker)
    if not ok then return finish(false, err) end
    if coroutine.status(worker) == "dead" then return finish(true) end
    spins = spins + 1
    if debugprofilestop then
      if debugprofilestop() - start > 6 then return end
    elseif spins >= 4 then
      return
    end
  end
end

-- Runs callback now if the zone index is built, otherwise after it is (it needs the chain index first).
function Zones.Ensure(callback)
  if Zones.state == "ready" or Zones.state == "error" then callback(); return end
  waiting[#waiting + 1] = callback
  if Zones.state == "idle" then
    Zones.state = "building"
    Data.Ensure(function()
      if Data.state ~= "ready" then return finish(false, Data.error or "The quest index could not be built.") end
      worker = coroutine.create(build)
      driver = driver or CreateFrame("Frame")
      driver:SetScript("OnUpdate", step)
    end)
  end
end

-- ---- what is known about quests and areas ----
local function infoOf(id)
  local i = infos[id]
  if not i then i = Data.Info(id); infos[id] = i end
  return i
end
Zones.InfoOf = infoOf

local function nameOf(id) return Data.Name(id) or ("Quest " .. id) end

local function giverName(kind, id)
  if kind == "npc" then return (NpcDB and NpcDB.name(id)) or ("NPC " .. id) end
  if kind == "object" then return (ObjectDB and ObjectDB.name(id)) or ("Object " .. id) end
  return Data.ItemName(id)
end

local playerIds = Data.PlayerIds

local function byLevelThenName(a, b)
  local ia, ib = infoOf(a), infoOf(b)
  local la, lb = ia.level or 0, ib.level or 0
  if la ~= lb then return la < lb end
  if (ia.name or "") ~= (ib.name or "") then return (ia.name or "") < (ib.name or "") end
  return a < b
end

-- Every area with quests starting in it: { { area, name, count }, ... } by name.
function Zones.List()
  if listCache then return listCache end
  local out = {}
  for area, list in pairs(starts) do
    local name = Data.ZoneName(area)
    if not name:match("^Zone %d+$") then
      local seen, n = {}, 0
      for _, e in ipairs(list) do
        if not seen[e.q] then seen[e.q] = true; n = n + 1 end
      end
      out[#out + 1] = { area = area, name = name, count = n }
    end
  end
  table.sort(out, function(a, b) if a.name ~= b.name then return a.name < b.name end return a.area < b.area end)
  if Zones.state == "ready" then listCache = out end
  return out
end

-- Areas whose name has the text in it (an exact name first).
function Zones.Find(text)
  text = tostring(text or ""):lower():match("^%s*(.-)%s*$")
  local hits = {}
  for _, z in ipairs(Zones.List()) do
    local lower = z.name:lower()
    if text == "" or lower:find(text, 1, true) then hits[#hits + 1] = { z = z, exact = lower == text } end
  end
  table.sort(hits, function(a, b) if a.exact ~= b.exact then return a.exact end return a.z.name < b.z.name end)
  local out = {}
  for i, h in ipairs(hits) do out[i] = h.z end
  return out
end

-- Zone names to offer while typing: those that start with the text first, then those with a word that starts
-- with it, then those that have it anywhere. At most `limit`.
function Zones.Suggest(text, limit, zones)
  text = tostring(text or ""):lower():match("^%s*(.-)%s*$")
  if text == "" then return {} end
  local prefix, word, inside = {}, {}, {}
  for _, z in ipairs(zones or Zones.List()) do
    local l = z.name:lower()
    if l:sub(1, #text) == text then
      prefix[#prefix + 1] = z
    elseif l:find(" " .. text, 1, true) or l:find("-" .. text, 1, true) then
      word[#word + 1] = z
    elseif l:find(text, 1, true) then
      inside[#inside + 1] = z
    end
  end
  local out = {}
  for _, group in ipairs({ prefix, word, inside }) do
    for _, z in ipairs(group) do
      if #out >= (limit or 8) then return out end
      out[#out + 1] = z
    end
  end
  return out
end

-- The area to show for a map: its own, or its nearest parent's that has quests.
function Zones.AreaForMap(uiMap)
  for _ = 1, 5 do
    if type(uiMap) ~= "number" or uiMap <= 0 then return nil end
    local a = Data.AreaOfUiMap(uiMap)
    if a and starts[a] then return a end
    local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(uiMap)
    uiMap = info and info.parentMapID
  end
  return nil
end

function Zones.CurrentArea()
  local m = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
  return m and Zones.AreaForMap(m) or nil
end

function Zones.HasArea(area) return starts[area] ~= nil end

-- Forgets the built models (for a change of character, or the tests).
function Zones.Reset()
  models, infos, listCache = {}, {}, nil
end

-- ---- the model of one area ----
-- { area, name, quests = {ids that start here and you can take}, chains = { { ids, here, entry, parts, minLevel,
--   maxLevel, name } }, singles = {ids started by an NPC here}, objGroups = { { kind, id, name, quests } } (the
--   rest: started by an object or an item), givers = { { kind, id, name, quests } }, chainOf = { [id] = chain } }
-- Quests meant for other races or classes are left out.
function Zones.Model(area)
  local hit = models[area]
  if hit then return hit end
  local idx = Data.index
  local raceId, classId = playerIds()
  local ok, here, hereList, npcHere = {}, {}, {}, {}
  local givers, gorder = {}, {}
  for _, e in ipairs(starts[area] or {}) do
    local q = e.q
    if ok[q] == nil then
      ok[q] = Core.Eligible(QuestDB.requiredRaces and QuestDB.requiredRaces(q), QuestDB.requiredClasses and QuestDB.requiredClasses(q), raceId, classId) and true or false
    end
    if ok[q] then
      if not here[q] then here[q] = true; hereList[#hereList + 1] = q end
      if e.kind == "npc" then npcHere[q] = true end
      local key = e.kind .. ":" .. e.g
      local g = givers[key]
      if not g then
        g = { kind = e.kind, id = e.g, name = giverName(e.kind, e.g), quests = {}, set = {} }
        givers[key] = g
        gorder[#gorder + 1] = g
      end
      if not g.set[q] then g.set[q] = true; g.quests[#g.quests + 1] = q end
    end
  end
  table.sort(hereList)

  local seen, chains, singles, others, chainOf = {}, {}, {}, {}, {}
  for _, q in ipairs(hereList) do
    if not seen[q] then
      local chain = (not idx.breadcrumb[q]) and Core.Chain(idx, q, infoOf, { race = raceId, class = classId }) or nil
      if chain and chain.quests >= 2 then
        local c = { ids = {}, here = {}, parts = chain.parts, truncated = chain.truncated }
        for _, layer in ipairs(chain.layers) do
          for _, e in ipairs(layer) do
            c.ids[#c.ids + 1] = e.id
            if e.level and e.level > 0 then
              c.minLevel = math.min(c.minLevel or e.level, e.level)
              c.maxLevel = math.max(c.maxLevel or e.level, e.level)
            end
            if here[e.id] then
              seen[e.id] = true
              c.here[#c.here + 1] = e.id
              chainOf[e.id] = c
              if not c.entry then c.entry = e.id end
            end
          end
        end
        c.name = infoOf(c.entry).name or ("Quest " .. c.entry)
        chains[#chains + 1] = c
      else
        seen[q] = true
        if npcHere[q] then singles[#singles + 1] = q else others[#others + 1] = q end
      end
    end
  end
  table.sort(chains, function(a, b) return byLevelThenName(a.entry, b.entry) end)
  table.sort(singles, byLevelThenName)
  local otherSet = {}
  for _, q in ipairs(others) do otherSet[q] = true end
  local objGroups = {}
  for _, g in ipairs(gorder) do
    table.sort(g.quests, byLevelThenName)
    g.set = nil
    if g.kind ~= "npc" then
      local qs = {}
      for _, q in ipairs(g.quests) do if otherSet[q] then qs[#qs + 1] = q end end
      if #qs > 0 then objGroups[#objGroups + 1] = { kind = g.kind, id = g.id, name = g.name, quests = qs } end
    end
  end
  table.sort(objGroups, function(a, b) return a.name < b.name end)
  table.sort(gorder, function(a, b) if a.name ~= b.name then return a.name < b.name end return a.id < b.id end)

  hit = { area = area, name = Data.ZoneName(area), quests = hereList, chains = chains, singles = singles,
    objGroups = objGroups, givers = gorder, chainOf = chainOf }
  models[area] = hit
  return hit
end

-- ---- statuses for you ----
local function missedContext(level)
  local green = GetQuestGreenRange and GetQuestGreenRange() or 8
  return {
    isDone = Data.IsDone,
    inLog = function(id) return Data.Status(id) == "log" end,
    nexts = Data.index.nexts,
    info = infoOf,
    exclusive = function(id) return QuestDB.exclusiveTo and QuestDB.exclusiveTo(id) or nil end,
    nameOf = nameOf,
    level = level,
    greenRange = green,
  }
end

-- How every quest of a model stands for you: { quest = { [id] = { status, detail = {texts} } },
-- chain = { [chain] = { status, counts } }, totals = { quests, done, log, available, locked, missed } }.
-- status is "done" | "log" | "available" | "locked" | "missed" (lost for good). A quest you have outleveled is still
-- "available" (you can take it), with greyNote saying so; counts.grey in a chain counts those.
function Zones.Evaluate(model)
  local level = UnitLevel and UnitLevel("player") or 0
  local ctx = missedContext(level)
  local quest = {}
  local function stat(id)
    local s = quest[id]
    if s then return s end
    local base = Data.Status(id)
    local status, unmet = Core.StatusOf(infoOf(id), base == "done", base == "log", Data.IsDone, level, nameOf)
    local detail, greyNote = unmet, nil
    if status == "available" or status == "locked" then
      local reason, kind = Core.MissedReason(id, ctx)
      if reason and kind == "grey" then
        if status == "available" then greyNote = reason end
      elseif reason then
        status, detail = "missed", { reason }
      end
    end
    s = { status = status, detail = detail, greyNote = greyNote }
    quest[id] = s
    return s
  end
  local totals = { quests = #model.quests, done = 0, log = 0, available = 0, locked = 0, missed = 0 }
  for _, id in ipairs(model.quests) do
    local s = stat(id)
    totals[s.status] = totals[s.status] + 1
  end
  local chain = {}
  for _, c in ipairs(model.chains) do
    local counts = { done = 0, log = 0, available = 0, locked = 0, missed = 0, grey = 0 }
    for _, id in ipairs(c.ids) do
      local s = stat(id)
      counts[s.status] = counts[s.status] + 1
      if s.greyNote then counts.grey = counts.grey + 1 end
    end
    local status
    if counts.done == #c.ids then status = "done"
    elseif counts.log > 0 then status = "log"
    elseif counts.available > 0 then status = "available"
    elseif counts.missed > 0 then status = "missed"
    else status = "locked" end
    chain[c] = { status = status, counts = counts }
  end
  return { quest = quest, chain = chain, totals = totals }
end

-- Does a row with this status show under the chosen filter? Chains match when any of their quests do.
function Zones.Matches(filter, status)
  return filter == "all" or filter == nil or status == filter
end

function Zones.ChainMatches(filter, ev)
  if filter == "all" or filter == nil then return true end
  if filter == "done" then return ev.status == "done" end
  return (ev.counts[filter] or 0) > 0
end
