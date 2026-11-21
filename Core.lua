-- Pure logic, no WoW API: the chain graph, XP scaling and reference parsing.
-- Kept separate so it can be tested offline (tests/run.py).
local _, ns = ...
ns = ns or {}
local Core = {}
ns.Core = Core

local floor = math.floor
local MAX_COMPONENT = 80

function Core.NewIndex()
  return {
    known = {},      -- [questId] = true for every quest in the database
    prevs = {},      -- [questId] = { [prerequisiteId] = true }
    nexts = {},      -- [questId] = { [followUpId] = true }
    breadcrumb = {}, -- [questId] = true when it only leads into another quest
    bcs = {},        -- [questId] = { breadcrumb ids that lead to it }
    rewards = {},    -- [questId] = { itemId, ... }
  }
end

local function add(map, key, value)
  local set = map[key]
  if not set then set = {}; map[key] = set end
  set[value] = true
end

-- f: { pre, preS, child, next, bcFor, bcs } straight from QuestieDB (any may be nil).
function Core.AddQuest(idx, id, f)
  idx.known[id] = true
  local function edge(a, b) add(idx.nexts, a, b); add(idx.prevs, b, a) end
  if f.pre then for _, p in ipairs(f.pre) do if p > 0 then edge(p, id) end end end
  if f.preS then for _, p in ipairs(f.preS) do if p > 0 then edge(p, id) end end end
  if f.child then for _, c in ipairs(f.child) do if c > 0 then edge(id, c) end end end
  if f.next and f.next > 0 then edge(id, f.next) end
  if f.bcFor and f.bcFor > 0 then idx.breadcrumb[id] = true end
  if f.bcs and #f.bcs > 0 then idx.bcs[id] = f.bcs end
end

-- questIds: the quests that reward itemId (QuestieDB's ItemDB.questRewards).
function Core.AddItemRewards(idx, itemId, questIds)
  for _, q in ipairs(questIds) do
    local list = idx.rewards[q]
    if not list then list = {}; idx.rewards[q] = list end
    list[#list + 1] = itemId
  end
end

function Core.FinishRewards(idx)
  for _, list in pairs(idx.rewards) do table.sort(list) end
end

-- XP at a given character level, using Questie's (cmangos-derived) scaling.
-- qLevel and base are the two numbers in Questie's XP table row {level, xp}.
function Core.ScaledXp(base, qLevel, charLevel)
  if not base or not qLevel or qLevel <= 0 or base <= 0 then return 0 end
  charLevel = charLevel or qLevel
  local mult = 2 * (qLevel - charLevel) + 20
  if mult < 1 then mult = 1 elseif mult > 10 then mult = 10 end
  local x = base * mult / 10
  if x <= 100 then x = 5 * floor((x + 2) / 5)
  elseif x <= 500 then x = 10 * floor((x + 5) / 10)
  elseif x <= 1000 then x = 25 * floor((x + 12) / 25)
  else x = 50 * floor((x + 25) / 50) end
  return floor(x)
end

local function sortedKeys(set)
  local keys = {}
  for k in pairs(set) do keys[#keys + 1] = k end
  table.sort(keys)
  return keys
end

-- The quest's chain: every quest connected to it through prerequisites and follow-ups
-- (breadcrumbs excluded), grouped into steps. Quests in the same step are alternatives or
-- parallel branches. info(id) -> { name, xpLevel, xpBase, rep } supplies per-quest details.
function Core.Chain(idx, startId, info)
  if not idx.known[startId] then return nil end
  local known = idx.known
  local seen = { [startId] = true }
  local count = 1
  local queue, head = { startId }, 1
  local truncated = false
  while head <= #queue do
    local id = queue[head]; head = head + 1
    for _, map in ipairs({ idx.prevs, idx.nexts }) do
      local set = map[id]
      if set then
        for _, o in ipairs(sortedKeys(set)) do
          if known[o] and not seen[o] and not idx.breadcrumb[o] then
            if count >= MAX_COMPONENT then
              truncated = true
            else
              seen[o] = true; count = count + 1; queue[#queue + 1] = o
            end
          end
        end
      end
    end
  end

  local depth = {}
  local function depthOf(id, stack)
    local d = depth[id]
    if d then return d end
    if stack[id] then return 0 end -- cycle guard
    stack[id] = true
    d = 0
    local set = idx.prevs[id]
    if set then
      for p in pairs(set) do
        if seen[p] then
          local v = depthOf(p, stack) + 1
          if v > d then d = v end
        end
      end
    end
    stack[id] = nil
    depth[id] = d
    return d
  end
  local byDepth, maxDepth = {}, 0
  for id in pairs(seen) do
    local d = depthOf(id, {})
    byDepth[d] = byDepth[d] or {}
    table.insert(byDepth[d], id)
    if d > maxDepth then maxDepth = d end
  end

  local layers, total, current = {}, 0, 0
  for d = 0, maxDepth do
    local ids = byDepth[d]
    if ids then
      table.sort(ids)
      local layer = {}
      for _, id in ipairs(ids) do
        local i = info(id) or {}
        layer[#layer + 1] = {
          id = id,
          name = i.name or ("Quest " .. id),
          xpLevel = i.xpLevel,
          xpBase = i.xpBase,
          rep = i.rep or {},
          items = idx.rewards[id] or {},
          level = i.level, reqLevel = i.reqLevel, pre = i.pre, preS = i.preS, objective = i.objective,
        }
        total = total + 1
        if id == startId then current = #layers + 1 end
      end
      layers[#layers + 1] = layer
    end
  end

  -- Breadcrumbs: optional quests that hand you a chain quest earlier. One that is itself part of the shown
  -- chain (you opened it) is not repeated. Each lands on the entry it leads into as `crumbs` (by id).
  local breadcrumbs, crumbsOf = {}, {}
  for _, id in ipairs(sortedKeys(seen)) do
    local own = {}
    for _, b in ipairs(idx.bcs[id] or {}) do
      if known[b] and not seen[b] then own[#own + 1] = b end
    end
    table.sort(own)
    for _, b in ipairs(own) do
      local i = info(b) or {}
      breadcrumbs[#breadcrumbs + 1] = { id = b, leadsTo = id }
      crumbsOf[id] = crumbsOf[id] or {}
      table.insert(crumbsOf[id], {
        id = b, leadsTo = id, name = i.name or ("Quest " .. b), level = i.level, reqLevel = i.reqLevel,
        pre = i.pre, preS = i.preS, objective = i.objective, rep = i.rep or {}, items = {},
      })
    end
  end
  for _, layer in ipairs(layers) do
    for _, e in ipairs(layer) do e.crumbs = crumbsOf[e.id] or {} end
  end

  return {
    startId = startId, layers = layers, parts = #layers, quests = total,
    currentLayer = current, breadcrumbs = breadcrumbs, truncated = truncated,
  }
end

-- What still stands between the player and a quest: a list of short texts (empty = nothing).
-- info: { reqLevel, pre = {all must be done}, preS = {at least one must be done} }.
-- isDone(id) -> boolean; nameOf(id) -> string.
function Core.Unmet(info, isDone, level, nameOf)
  local out = {}
  if info.reqLevel and info.reqLevel > 0 and level and level < info.reqLevel then
    out[#out + 1] = "Level " .. info.reqLevel
  end
  if info.pre then
    local missing = {}
    for _, p in ipairs(info.pre) do
      if p > 0 and not isDone(p) then missing[#missing + 1] = nameOf(p) end
    end
    if #missing > 0 then out[#out + 1] = "Finish: " .. table.concat(missing, ", ") end
  end
  if info.preS then
    local names, any = {}, false
    for _, p in ipairs(info.preS) do
      if p > 0 then
        if isDone(p) then any = true end
        names[#names + 1] = nameOf(p)
      end
    end
    if not any and #names > 0 then out[#out + 1] = "Finish one of: " .. table.concat(names, ", ") end
  end
  return out
end

-- "done" | "log" | "locked" | "available", plus the unmet list for locked quests.
function Core.StatusOf(info, done, inLog, isDone, level, nameOf)
  if done then return "done", {} end
  if inLog then return "log", {} end
  local unmet = Core.Unmet(info, isDone, level, nameOf)
  if #unmet > 0 then return "locked", unmet end
  return "available", {}
end

-- Case-insensitive substring search over quest names: ids is a list, nameOf(id) -> string or nil.
-- Exact matches first, then shorter names, then by id. At most `limit` results.
function Core.Search(ids, nameOf, text, limit)
  text = tostring(text or ""):lower():match("^%s*(.-)%s*$")
  if text == "" then return {} end
  local hits = {}
  for _, id in ipairs(ids) do
    local name = nameOf(id)
    if name then
      local lower = name:lower()
      if lower:find(text, 1, true) then hits[#hits + 1] = { id = id, name = name, exact = lower == text } end
    end
  end
  table.sort(hits, function(a, b)
    if a.exact ~= b.exact then return a.exact end
    if #a.name ~= #b.name then return #a.name < #b.name end
    return a.id < b.id
  end)
  local out = {}
  for i = 1, math.min(limit or 30, #hits) do out[i] = hits[i] end
  return out, #hits
end

-- Picks where to send the player: the first spawn, preferring the quest's own zone.
-- spawns: { [areaId] = { {x, y}, ... } }. Returns areaId, x, y or nil.
function Core.PickSpawn(spawns, preferredArea)
  if type(spawns) ~= "table" then return nil end
  local function first(area)
    local list = spawns[area]
    local p = list and list[1]
    if p and p[1] and p[2] and p[1] >= 0 and p[2] >= 0 then return area, p[1], p[2] end
  end
  if preferredArea then
    local a, x, y = first(preferredArea)
    if a then return a, x, y end
  end
  local areas = {}
  for area in pairs(spawns) do areas[#areas + 1] = area end
  table.sort(areas)
  for _, area in ipairs(areas) do
    local a, x, y = first(area)
    if a then return a, x, y end
  end
  return nil
end

-- Accepts a number, a quest link, "quest=123"/"quest:123" text, or a bare id.
-- Returns id, or nil and the remaining text when it looks like a name.
function Core.ParseRef(text)
  if type(text) == "number" then return text end
  text = tostring(text or ""):match("^%s*(.-)%s*$")
  if text == "" then return nil end
  local id = text:match("|Hquest:(%d+)") or text:match("quest[=:/](%d+)")
  if id then return tonumber(id) end
  if text:match("^%d+$") then return tonumber(text) end
  return nil, text
end

-- ---- where a quest's objectives happen ----
-- Spawn tables are { [areaId] = { {x, y}, ... } }; an area's weight is how many spawn points it has.
-- `spots`, when given, also collects the points themselves: { [area] = { {x, y}, ... } }.
local function AddSpawns(areas, spawns, spots)
  if type(spawns) ~= "table" then return end
  for area, pts in pairs(spawns) do
    if type(area) == "number" and area > 0 and type(pts) == "table" then
      areas[area] = (areas[area] or 0) + math.max(1, #pts)
      if spots then
        local list = spots[area]
        if not list then list = {}; spots[area] = list end
        for _, p in ipairs(pts) do list[#list + 1] = p end
      end
    end
  end
end

-- { [area] = weight } -> area ids, most spawn points first.
local function SortedAreas(areas)
  local list = {}
  for area, w in pairs(areas) do list[#list + 1] = { area = area, w = w } end
  table.sort(list, function(a, b) if a.w ~= b.w then return a.w > b.w end return a.area < b.area end)
  local out = {}
  for i, a in ipairs(list) do out[i] = a.area end
  return out
end

local function Weight(spawns)
  local mine = {}
  AddSpawns(mine, spawns)
  local w = 0
  for _, v in pairs(mine) do w = w + v end
  return w
end

local MAX_DROPPERS = 40

-- raw: QuestDB.objectives(id) = { creatures, objects, items, reputation, killCredit, spell }.
-- trigger: QuestDB.triggerEnd(id) = { text, spawnList } (an "explore" objective), or nil.
-- L: { npcName, npcSpawns, objName, objSpawns, itemName, npcDrops, objDrops } lookups by id.
-- Returns a list of { kind = "kill"|"object"|"item"|"explore", name, areas = {area ids}, from = {dropper names} }.
function Core.Objectives(raw, trigger, L)
  local out = {}
  if type(raw) == "table" then
    for _, c in ipairs(raw[1] or {}) do
      local areas, spots = {}, {}
      AddSpawns(areas, L.npcSpawns(c[1]), spots)
      out[#out + 1] = { kind = "kill", id = c[1], name = L.npcName(c[1]) or c[2] or ("NPC " .. tostring(c[1])), areas = SortedAreas(areas), spots = spots }
    end
    for _, c in ipairs(raw[5] or {}) do
      local areas, spots = {}, {}
      for _, npc in ipairs(c[1] or {}) do AddSpawns(areas, L.npcSpawns(npc), spots) end
      out[#out + 1] = { kind = "kill", id = c[2], name = L.npcName(c[2]) or c[3] or ("NPC " .. tostring(c[2])), areas = SortedAreas(areas), spots = spots }
    end
    for _, c in ipairs(raw[2] or {}) do
      local areas, spots = {}, {}
      AddSpawns(areas, L.objSpawns(c[1]), spots)
      out[#out + 1] = { kind = "object", id = c[1], name = L.objName(c[1]) or c[2] or ("Object " .. tostring(c[1])), areas = SortedAreas(areas), spots = spots }
    end
    for _, c in ipairs(raw[3] or {}) do
      local areas, droppers, spots = {}, {}, {}
      for i, npc in ipairs(L.npcDrops(c[1]) or {}) do
        if i > MAX_DROPPERS then break end
        local sp = L.npcSpawns(npc)
        AddSpawns(areas, sp, spots)
        droppers[#droppers + 1] = { name = L.npcName(npc), w = Weight(sp) }
      end
      for i, obj in ipairs(L.objDrops(c[1]) or {}) do
        if i > MAX_DROPPERS then break end
        local sp = L.objSpawns(obj)
        AddSpawns(areas, sp, spots)
        droppers[#droppers + 1] = { name = L.objName(obj), w = Weight(sp) }
      end
      table.sort(droppers, function(a, b) return a.w > b.w end)
      local from = {}
      for _, d in ipairs(droppers) do
        if d.name and #from < 3 then from[#from + 1] = d.name end
      end
      out[#out + 1] = { kind = "item", id = c[1], name = L.itemName(c[1]) or c[2] or ("Item " .. tostring(c[1])), areas = SortedAreas(areas), spots = spots, from = from, sources = #droppers }
    end
  end
  if type(trigger) == "table" and type(trigger[2]) == "table" then
    local areas, spots = {}, {}
    AddSpawns(areas, trigger[2], spots)
    out[#out + 1] = { kind = "explore", name = trigger[1] or "Explore", areas = SortedAreas(areas), spots = spots }
  end
  return out
end

-- The areas across several objectives: an area scores 3, 2, 1 for being an objective's first, second
-- or third area, and the highest scores come first. Returns at most `limit` areas and how many there are in all.
function Core.TopAreas(objs, limit)
  local score, first, n = {}, {}, 0
  for _, o in ipairs(objs) do
    for rank, area in ipairs(o.areas) do
      if rank <= 3 then
        score[area] = (score[area] or 0) + (4 - rank)
        if not first[area] then n = n + 1; first[area] = n end
      end
    end
  end
  local list = {}
  for area in pairs(score) do list[#list + 1] = area end
  table.sort(list, function(a, b) if score[a] ~= score[b] then return score[a] > score[b] end return first[a] < first[b] end)
  local out = {}
  for i = 1, math.min(limit or 3, #list) do out[i] = list[i] end
  return out, #list
end

-- Where to send the player for a quest's objectives: the best-ranked area that `canUse(area)` accepts,
-- and in it the point of the first objective there that is closest to the middle of that objective's points
-- (so the mark lands inside the crowd of spawns, not at an edge). Returns area, x, y, objective, or nil.
function Core.BestSpot(objs, canUse)
  local areas = Core.TopAreas(objs, 99)
  for _, area in ipairs(areas) do
    if not canUse or canUse(area) then
      for _, o in ipairs(objs) do
        local pts = o.spots and o.spots[area]
        if pts then
          local sx, sy, n = 0, 0, 0
          for _, p in ipairs(pts) do
            if p[1] and p[2] then sx = sx + p[1]; sy = sy + p[2]; n = n + 1 end
          end
          if n > 0 then
            local cx, cy = sx / n, sy / n
            local best, bd
            for _, p in ipairs(pts) do
              if p[1] and p[2] then
                local d = (p[1] - cx) ^ 2 + (p[2] - cy) ^ 2
                if not bd or d < bd then best, bd = p, d end
              end
            end
            return area, best[1], best[2], o
          end
        end
      end
    end
  end
  return nil
end

-- QuestieDB's `specialFlags` bitmask: bit 1 = repeatable.
function Core.IsRepeatable(flags)
  return type(flags) == "number" and math.floor(flags) % 2 == 1
end

-- The Wowhead page of a quest on WoW Forever (a plain link to copy; nothing is fetched from the site).
function Core.QuestUrl(id)
  return ("https://www.wowhead.com/forever/quest=%d"):format(id)
end

-- Where a minimap button sits on a ring around the minimap, `angle` radians from the minimap's centre
-- (0 = right, pi/2 = up). Offsets from the centre, for a minimap `w` x `h`. Round minimaps use a
-- circle; square and cornered ones (as GetMinimapShape reports) keep the button on the edge, the same
-- rule the usual minimap-button libraries use. A quadrant is true when the minimap is round there.
local ROUND = { true, true, true, true } -- quadrants: 1 = lower right, 2 = lower left, 3 = upper right, 4 = upper left
local SHAPES = {
  ROUND = ROUND,
  SQUARE = { false, false, false, false },
  ["CORNER-TOPLEFT"] = { false, false, false, true },
  ["CORNER-TOPRIGHT"] = { false, false, true, false },
  ["CORNER-BOTTOMLEFT"] = { false, true, false, false },
  ["CORNER-BOTTOMRIGHT"] = { true, false, false, false },
  ["SIDE-LEFT"] = { false, true, false, true },
  ["SIDE-RIGHT"] = { true, false, true, false },
  ["SIDE-TOP"] = { false, false, true, true },
  ["SIDE-BOTTOM"] = { true, true, false, false },
  ["TRICORNER-TOPLEFT"] = { false, true, true, true },
  ["TRICORNER-TOPRIGHT"] = { true, false, true, true },
  ["TRICORNER-BOTTOMLEFT"] = { true, true, false, true },
  ["TRICORNER-BOTTOMRIGHT"] = { true, true, true, false },
}

function Core.MinimapOffset(angle, w, h, shape)
  local x, y = math.cos(angle), math.sin(angle)
  local q = 1
  if x < 0 then q = q + 1 end
  if y > 0 then q = q + 2 end
  local round = (SHAPES[shape] or ROUND)[q]
  local hw, hh = w / 2 + 5, h / 2 + 5
  if round then return x * hw, y * hh end
  local dw, dh = math.sqrt(2 * hw * hw) - 10, math.sqrt(2 * hh * hh) - 10
  return math.max(-hw, math.min(x * dw, hw)), math.max(-hh, math.min(y * dh, hh))
end

return Core
