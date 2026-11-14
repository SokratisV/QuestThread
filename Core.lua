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

  local breadcrumbs = {}
  for _, id in ipairs(sortedKeys(seen)) do
    for _, b in ipairs(idx.bcs[id] or {}) do
      if known[b] then breadcrumbs[#breadcrumbs + 1] = { id = b, leadsTo = id } end
    end
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

return Core
