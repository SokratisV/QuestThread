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
-- who (optional) = { race = raceId, class = classId, hasSkill = fn }: a step or lead-in quest that Core.Allowed says is
-- not for you (another race or class, a profession you lack) is left out, using info's raceMask / classMask / skill
-- / ranks (the two factions often have their own version of a step). The quest
-- you start from always stays, and the others are still walked through, so a chain the other faction's step
-- connects is not cut in two.
function Core.Chain(idx, startId, info, who)
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

  if who then
    for id in pairs(seen) do
      if id ~= startId then
        if not Core.Allowed(info(id) or {}, who) then seen[id] = nil end
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

  -- The chain's main line is what its last step needs (directly or through other quests); every other quest is an
  -- optional side quest. Main quests are labelled 1, 2, 3 in the order shown; an optional one is lettered (a, b...)
  -- after the main quest it follows.
  local required, last = {}, layers[#layers]
  if last then
    local stack = {}
    for _, e in ipairs(last) do required[e.id] = true; stack[#stack + 1] = e.id end
    while #stack > 0 do
      local id = table.remove(stack)
      for p in pairs(idx.prevs[id] or {}) do
        if seen[p] and not required[p] then required[p] = true; stack[#stack + 1] = p end
      end
    end
  end
  local function letters(n) -- 1 = a ... 26 = z, 27 = aa
    local s = ""
    while n > 0 do
      n = n - 1
      s = string.char(97 + n % 26) .. s
      n = floor(n / 26)
    end
    return s
  end
  local mainCount, optionalCount, run = 0, 0, 0
  for _, layer in ipairs(layers) do
    for _, e in ipairs(layer) do
      if not required[e.id] then
        e.optional = true
        optionalCount, run = optionalCount + 1, run + 1
        e.label = letters(run)
      else
        e.optional = false
        mainCount, run = mainCount + 1, 0
        e.label = tostring(mainCount)
      end
    end
  end

  -- Breadcrumbs: optional quests that hand you a chain quest earlier. One that is itself part of the shown
  -- chain (you opened it) is not repeated. Each lands on the entry it leads into as `crumbs` (by id).
  local breadcrumbs, crumbsOf = {}, {}
  for _, id in ipairs(sortedKeys(seen)) do
    local own = {}
    for _, b in ipairs(idx.bcs[id] or {}) do
      local bi = who and info(b) or nil
      local mine = not bi or Core.Allowed(bi, who)
      if known[b] and not seen[b] and mine then own[#own + 1] = b end
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
    mainCount = mainCount, optionalCount = optionalCount,
  }
end

-- Lays a chain out as a graph: one column per step (the layers of Core.Chain), and within a column the main quests
-- first, then the optional ones, each group ordered by where its prerequisites sit (so lines run roughly straight).
-- prevs[id] = { [prerequisiteId] = true }. Returns { nodes = { [id] = { col, row, entry } },
-- edges = { { from, to } ... } (a prerequisite to the quest it unlocks), cols, rows } (columns and rows from 0).
function Core.GraphLayout(layers, prevs)
  local nodes, edges, maxRows = {}, {}, 0
  for c, layer in ipairs(layers) do
    local key = {}
    for _, e in ipairs(layer) do
      local sum, n = 0, 0
      for p in pairs(prevs[e.id] or {}) do
        local pn = nodes[p]
        if pn then sum, n = sum + pn.row, n + 1 end
      end
      key[e.id] = n > 0 and sum / n or 0
    end
    local list = {}
    for _, e in ipairs(layer) do list[#list + 1] = e end
    table.sort(list, function(a, b)
      local oa, ob = a.optional and 1 or 0, b.optional and 1 or 0
      if oa ~= ob then return oa < ob end
      if key[a.id] ~= key[b.id] then return key[a.id] < key[b.id] end
      return a.id < b.id
    end)
    for r, e in ipairs(list) do nodes[e.id] = { col = c - 1, row = r - 1, entry = e } end
    if #list > maxRows then maxRows = #list end
  end
  for _, layer in ipairs(layers) do
    for _, e in ipairs(layer) do
      local ps = {}
      for p in pairs(prevs[e.id] or {}) do if nodes[p] then ps[#ps + 1] = p end end
      table.sort(ps)
      for _, p in ipairs(ps) do edges[#edges + 1] = { from = p, to = e.id } end
    end
  end
  return { nodes = nodes, edges = edges, cols = #layers, rows = maxRows }
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

-- Scroll bar maths. The thumb is as tall as the share of the content that shows (never under minH, never over the
-- bar), and sits `top` px below the bar's top. nil when everything fits and there is nothing to scroll.
function Core.Thumb(contentH, viewH, scroll, minH)
  if not contentH or not viewH or viewH <= 0 or contentH <= viewH + 1 then return nil end
  local th = math.min(viewH, math.max(minH or 24, viewH * viewH / contentH))
  local frac = math.min(1, math.max(0, (scroll or 0) / (contentH - viewH)))
  return th, (viewH - th) * frac
end

-- The scroll offset for a thumb of height th whose top is `top` px below the bar's top (clamped to the bar).
function Core.ScrollForThumb(top, th, contentH, viewH)
  local free = viewH - th
  if free <= 0 or contentH <= viewH then return 0 end
  return math.min(1, math.max(0, top / free)) * (contentH - viewH)
end

-- The game's quest difficulty colour for a quest level, as it shows in the quest log: red 5 or more levels above
-- you, orange 3-4 above, yellow within 2 of you, green below that while it still gives XP, grey when it is trivial.
-- greenRange is how many levels below you a quest stays green (the game's GetQuestGreenRange).
Core.DIFFICULTY = {
  red = { 1, 0.1, 0.1, "|cffff1a1a" }, orange = { 1, 0.5, 0.25, "|cffff8040" }, yellow = { 1, 1, 0, "|cffffff00" },
  green = { 0.25, 0.75, 0.25, "|cff40bf40" }, grey = { 0.5, 0.5, 0.5, "|cff808080" },
}

-- Returns "red" | "orange" | "yellow" | "green" | "grey", or nil when either level is unknown.
function Core.Difficulty(qLevel, level, greenRange)
  if type(qLevel) ~= "number" or qLevel <= 0 or type(level) ~= "number" or level <= 0 then return nil end
  local diff = qLevel - level
  if diff >= 5 then return "red" end
  if diff >= 3 then return "orange" end
  if diff >= -2 then return "yellow" end
  if -diff <= (greenRange or 8) then return "green" end
  return "grey"
end

-- QuestieDB's race and class masks (nil or 0 means anyone). A class has bit (id - 1) set (Warrior 1, Paladin 2 ...).
-- A race does too for the ordinary ids (Human 1, Orc 2, Dwarf 3 ... Worgen 22, Pandaren 24-26), but WoW Forever's two
-- Skyborne races have ids 95 and 96 and sit at bits 32 and 33 (QuestieDB's Enum.raceMaskById; Data copies it in).
Core.raceMaskById = { [95] = 2 ^ 32, [96] = 2 ^ 33 }

-- The mask bit of a race id, or nil for a race this does not know (such a character is never filtered by race).
function Core.RaceBit(raceId)
  if type(raceId) ~= "number" then return nil end
  local bit = Core.raceMaskById[raceId]
  if bit then return bit end
  if raceId >= 1 and raceId <= 32 then return 2 ^ (raceId - 1) end
  return nil
end

local function maskHas(mask, id)
  return floor(mask / 2 ^ (id - 1)) % 2 == 1
end

function Core.Eligible(raceMask, classMask, raceId, classId)
  local bit = Core.RaceBit(raceId)
  if type(raceMask) == "number" and raceMask > 0 and bit and floor(raceMask / bit) % 2 ~= 1 then return false end
  if type(classMask) == "number" and classMask > 0 and classId and not maskHas(classMask, classId) then return false end
  return true
end

-- Skill line ids of the professions (QuestieDB's requiredSkill / requiredRanks use them). Riding is not one.
Core.PROFESSIONS = {
  [129] = true, [164] = true, [165] = true, [171] = true, [182] = true, [185] = true, [186] = true, [197] = true,
  [202] = true, [333] = true, [356] = true, [393] = true, [755] = true, [773] = true, [794] = true,
}

-- Can this character take the quest at all? info = { raceMask, classMask, skill = { skillId, value }, ranks = { { skillId,
-- rank }, ... } }; who = { race, class, hasSkill(skillId) -> true | false | nil (unknown) } (nil: everyone).
-- A quest for another race or class, or one that needs a profession you have not learned, is not for you.
-- Only whether you have the profession counts, not your skill in it.
function Core.Allowed(i, who)
  if not who then return true end
  if not Core.Eligible(i.raceMask, i.classMask, who.race, who.class) then return false end
  local has = who.hasSkill
  if has then
    local s = i.skill
    if type(s) == "table" and Core.PROFESSIONS[s[1]] and has(s[1]) == false then return false end
    local r = i.ranks
    if type(r) == "table" then
      local any, learned = false, false
      for _, p in ipairs(r) do
        local id = type(p) == "table" and p[1] or nil
        if id and Core.PROFESSIONS[id] then
          any = true
          if has(id) ~= false then learned = true end
        end
      end
      if any and not learned then return false end
    end
  end
  return true
end

-- Why a quest you have not done (and are not on) can no longer be done, or nil when it still can. Returns the
-- reason and its kind: "missed" (lost for good: you already did a later step that needed it, a quest it excludes
-- is done or in your log, or you are over its level cap) or "grey" (still takeable, but you have outleveled it,
-- so it is grey to you and worth next to nothing).
-- c: { isDone(id), inLog(id), nexts = { [id] = { [followUp] = true } }, info(id) -> { pre, preS, level, maxLevel },
--      exclusive(id) -> {ids}, nameOf(id), level = your level, greenRange = levels below you that are still green }
function Core.MissedReason(q, c)
  local set = c.nexts[q]
  if set then
    for _, s in ipairs(sortedKeys(set)) do
      if c.isDone(s) or c.inLog(s) then
        local si = c.info(s) or {}
        local needs = false
        for _, p in ipairs(si.pre or {}) do if p == q then needs = true end end
        if not needs and si.preS then
          local member, other = false, false
          for _, p in ipairs(si.preS) do
            if p == q then member = true elseif p > 0 and c.isDone(p) then other = true end
          end
          needs = member and not other
        end
        if needs then return "Skipped: you already did a later step, " .. c.nameOf(s), "missed" end
      end
    end
  end
  for _, x in ipairs(c.exclusive(q) or {}) do
    if x > 0 and (c.isDone(x) or c.inLog(x)) then return "Excluded by " .. c.nameOf(x), "missed" end
  end
  local inf = c.info(q) or {}
  if inf.maxLevel and inf.maxLevel > 0 and c.level and c.level > inf.maxLevel then
    return "Over its level cap (" .. inf.maxLevel .. ")", "missed"
  end
  if inf.level and inf.level > 0 and c.level and c.greenRange and inf.level < c.level - c.greenRange then
    return "Outleveled: quest level " .. inf.level .. ", you are " .. c.level, "grey"
  end
  return nil
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

-- A name cut short (and "..." added) until fits(text) says it fits. fits is given the whole candidate name. A name
-- that fits comes back as it is. Cuts whole UTF-8 characters.
function Core.Shorten(name, fits)
  if fits(name) then return name end
  local n = name
  while #n > 0 do
    local i = #n -- the start of the last character: back over its continuation bytes (128 to 191)
    while i > 1 and n:byte(i) >= 128 and n:byte(i) < 192 do i = i - 1 end
    n = n:sub(1, i - 1)
    if fits(n .. "...") then break end
  end
  return n .. "..."
end

-- The items a chain asks you to collect, each once, in the order the chain first needs them.
-- entries: the chain's quests ({ id, status }); objsOf(id) = Core.Objectives(...) for that quest.
-- Returns a list of { id, name, quests = {quest ids}, from = {dropper names}, done = true when every quest that
-- needs it is already done }. QuestieDB has no counts, so there are none here.
function Core.Needs(entries, objsOf)
  local out, byId = {}, {}
  for _, e in ipairs(entries) do
    for _, o in ipairs(objsOf(e.id) or {}) do
      if o.kind == "item" and o.id then
        local n = byId[o.id]
        if not n then
          n = { id = o.id, name = o.name, quests = {}, from = {}, done = true }
          byId[o.id] = n
          out[#out + 1] = n
        end
        local seen = false
        for _, q in ipairs(n.quests) do if q == e.id then seen = true end end
        if not seen then n.quests[#n.quests + 1] = e.id end
        if e.status ~= "done" then n.done = false end
        for _, who in ipairs(o.from or {}) do
          local have = false
          for _, w in ipairs(n.from) do if w == who then have = true end end
          if not have and #n.from < 3 then n.from[#n.from + 1] = who end
        end
      end
    end
  end
  return out
end

-- Can the item go on the auction house? From the client's item info: bindType (0 none, 1 when picked up,
-- 2 when equipped, 3 when used, 4 quest item). true, false, or nil when unknown. The item's class does not decide it:
-- plenty of items in the "Quest" class (Morrowgrain, say) have no binding and sell at the auction house.
function Core.Tradable(bindType)
  if type(bindType) ~= "number" then return nil end
  if bindType == 1 or bindType == 4 then return false end
  return true
end

-- Copper as "1g 20s 5c" (only the parts that are not zero); "" for nothing.
function Core.Money(copper)
  if type(copper) ~= "number" or copper <= 0 then return "" end
  copper = math.floor(copper + 0.5)
  local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  local parts = {}
  if g > 0 then parts[#parts + 1] = g .. "g" end
  if s > 0 then parts[#parts + 1] = s .. "s" end
  if c > 0 then parts[#parts + 1] = c .. "c" end
  return table.concat(parts, " ")
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
