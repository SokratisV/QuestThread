-- QuestieDB access: builds the chain and reward indexes in the background, then answers
-- per-quest lookups. QuestieDB is only read, never copied.
local ADDON, ns = ...
local Core = ns.Core
local Data = {}
ns.Data = Data

Data.index = Core.NewIndex()
Data.state = "idle" -- idle | building | ready | error
Data.progress = 0   -- 0..1 while building
Data.error = nil

local waiting = {}  -- callbacks to run when the index is ready
local worker, driver

local function questFields(id)
  return {
    pre = QuestDB.preQuestGroup(id),
    preS = QuestDB.preQuestSingle(id),
    child = QuestDB.childQuests(id),
    next = QuestDB.nextQuestInChain(id),
    bcFor = QuestDB.breadcrumbForQuestId(id),
    bcs = QuestDB.breadcrumbs(id),
  }
end

local function build()
  local idx = Data.index
  local qids = QuestDB.GetAllIds()
  local nq = #qids
  for i = 1, nq do
    Core.AddQuest(idx, qids[i], questFields(qids[i]))
    if i % 40 == 0 then Data.progress = 0.25 * i / nq; coroutine.yield() end
  end
  local iids = ItemDB.GetAllIds()
  local ni = #iids
  for i = 1, ni do
    local quests = ItemDB.questRewards(iids[i])
    if quests then Core.AddItemRewards(idx, iids[i], quests) end
    if i % 150 == 0 then Data.progress = 0.25 + 0.75 * i / ni; coroutine.yield() end
  end
  Core.FinishRewards(idx)
end

local function finish(ok, err)
  driver:SetScript("OnUpdate", nil)
  if ok then Data.state, Data.progress = "ready", 1 else Data.state, Data.error = "error", tostring(err) end
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
      if debugprofilestop() - start > 6 then return end -- ~6 ms of work per frame
    elseif spins >= 4 then
      return
    end
  end
end

-- Runs callback now if the index is built, otherwise after it is (building starts on first call).
function Data.Ensure(callback)
  if Data.state == "ready" or Data.state == "error" then callback(); return end
  waiting[#waiting + 1] = callback
  if Data.state == "idle" then
    if not (QuestDB and ItemDB and QuestDB.GetAllIds and ItemDB.GetAllIds) then
      Data.state, Data.error = "error", "QuestieDB is not loaded."
      return finish(false, Data.error)
    end
    Data.state = "building"
    worker = coroutine.create(build)
    driver = driver or CreateFrame("Frame")
    driver:SetScript("OnUpdate", step)
  end
end

-- Base XP row {questLevel, xp} from Questie's table, or nil.
local xpTable
local function xpRow(id)
  if xpTable == nil then
    local s = LibQuestieDB and LibQuestieDB.Support and LibQuestieDB.Support.Get("QuestXP")
    xpTable = (type(s) == "table" and type(s.db) == "table") and s.db or false
  end
  return xpTable and xpTable[id] or nil
end

function Data.Info(id)
  local row = xpRow(id)
  return {
    name = QuestDB.name(id),
    xpLevel = row and row[1],
    xpBase = row and row[2],
    rep = QuestDB.reputationReward(id),
    level = QuestDB.questLevel(id),
    reqLevel = QuestDB.requiredLevel(id),
    pre = QuestDB.preQuestGroup(id),
    preS = QuestDB.preQuestSingle(id),
    objective = QuestDB.objectivesText(id),
    maxLevel = QuestDB.requiredMaxLevel and QuestDB.requiredMaxLevel(id) or nil,
    raceMask = QuestDB.requiredRaces and QuestDB.requiredRaces(id) or nil,
    classMask = QuestDB.requiredClasses and QuestDB.requiredClasses(id) or nil,
    skill = QuestDB.requiredSkill and QuestDB.requiredSkill(id) or nil,
    ranks = QuestDB.requiredRanks and QuestDB.requiredRanks(id) or nil,
  }
end

-- The professions you have learned, by skill line id: set (true each), decisive. decisive is false when the client
-- could not list them (then only the ones it positively reported are in the set, and nothing is ruled out).
local function readSkills()
  local have, decisive = {}, false
  local function number(v)
    if type(v) ~= "number" or (issecretvalue and issecretvalue(v)) then return nil end
    return v
  end
  -- GetProfessions lists every learned profession (primary and secondary) whatever the skill panel has folded away
  if type(GetProfessions) == "function" and type(GetProfessionInfo) == "function" then
    local okP, p1, p2, p3, p4, p5, p6 = pcall(GetProfessions)
    if okP then
      decisive = true
      for _, index in pairs({ p1, p2, p3, p4, p5, p6 }) do
        local ok, _, _, _, _, _, _, line = pcall(GetProfessionInfo, index)
        line = ok and number(line) or nil
        if line then have[line] = true end
      end
    end
  end
  local info = C_SkillInfo
  if info and info.GetSkillLineInfoByID then
    for id in pairs(Core.PROFESSIONS) do
      local ok, r = pcall(info.GetSkillLineInfoByID, id)
      if ok and type(r) == "table" and (number(r.rank) or 0) > 0 then have[id] = true end
    end
  end
  return have, decisive
end

-- WoW Forever's own race mask bits, when QuestieDB publishes them (it does: the Skyborne races are not at id - 1).
local function adoptRaceMasks()
  local enum = LibQuestieDB and LibQuestieDB.Enum
  local t = enum and enum.raceMaskById
  if type(t) == "table" then
    for id, bit in pairs(t) do if type(id) == "number" and type(bit) == "number" then Core.raceMaskById[id] = bit end end
  end
end
-- Who you are, for leaving out what is not for you: { race, class, hasSkill(id), key } (see Core.Allowed). `key`
-- changes when your learned professions do, so cached lists know when to be rebuilt.
function Data.Who()
  local race = UnitRace and select(3, UnitRace("player")) or nil
  local class = UnitClass and select(3, UnitClass("player")) or nil
  adoptRaceMasks()
  local have, decisive = readSkills()
  local ids = {}
  for id in pairs(have) do ids[#ids + 1] = id end
  table.sort(ids)
  return {
    race = race, class = class, key = (decisive and "d" or "u") .. table.concat(ids, ","),
    hasSkill = function(id)
      if have[id] then return true end
      if decisive then return false end
      return nil
    end,
  }
end


function Data.IsDone(id)
  return C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted and C_QuestLog.IsQuestFlaggedCompleted(id) and true or false
end

function Data.IsRepeatable(id)
  local ok, flags = pcall(function() return QuestDB and QuestDB.specialFlags and QuestDB.specialFlags(id) end)
  return ok and Core.IsRepeatable(flags) or false
end

-- Does Questie's My Journey log a completion of this quest? (Questie is optional.)
local function JourneyHas(id)
  local j = Questie and Questie.db and Questie.db.char and Questie.db.char.journey
  if type(j) ~= "table" then return false end
  for _, e in pairs(j) do
    if type(e) == "table" and e.Event == "Quest" and e.SubType == "Complete" and tonumber(e.Quest) == id then return true end
  end
  return false
end

-- A repeatable quest is never flagged completed for good, so "done at least once" comes from three places:
-- turn-ins QuestThread has seen itself, the game's flag (dailies and weeklies while it lasts), and Questie's journey.
function Data.RepeatableDone(id)
  if not Data.IsRepeatable(id) then return false end
  local seen = QuestThreadDB and QuestThreadDB.turnedIn
  if seen and seen[id] then return true end
  return Data.IsDone(id) or JourneyHas(id)
end

-- nil for a normal quest; for a repeatable one { done = completed at least once, count = turn-ins seen by
-- QuestThread (0 when it only knows it was done, e.g. from Questie's journey) }.
function Data.RepeatInfo(id)
  if not Data.IsRepeatable(id) then return nil end
  local seen = QuestThreadDB and QuestThreadDB.turnedIn
  return { done = Data.RepeatableDone(id), count = seen and seen[id] or 0 }
end

-- Called on QUEST_TURNED_IN; only repeatable quests are remembered.
function Data.RecordTurnIn(id)
  if type(id) ~= "number" or not Data.IsRepeatable(id) then return end
  QuestThreadDB = QuestThreadDB or {}
  QuestThreadDB.turnedIn = QuestThreadDB.turnedIn or {}
  QuestThreadDB.turnedIn[id] = (QuestThreadDB.turnedIn[id] or 0) + 1
end

-- "done" (completed, or a repeatable completed at least once), "log" (in your quest log) or "new".
function Data.QuestState(id)
  if Data.IsDone(id) or Data.RepeatableDone(id) then return "done" end
  if C_QuestLog and C_QuestLog.IsOnQuest and C_QuestLog.IsOnQuest(id) then return "log" end
  return "new"
end

-- Who starts ("start") or ends ("end") a quest: { { kind = "npc"|"object", id, name }, ... }.
function Data.Givers(id, which)
  local t = (which == "end") and QuestDB.finishedBy(id) or QuestDB.startedBy(id)
  local out = {}
  if type(t) ~= "table" then return out end
  for i, kind in ipairs({ "npc", "object" }) do
    local db = kind == "npc" and NpcDB or ObjectDB
    for _, gid in ipairs(t[i] or {}) do
      out[#out + 1] = { kind = kind, id = gid, name = (db and db.name(gid)) or (kind .. " " .. gid) }
    end
  end
  return out
end

-- QuestieDB's zone tables (area id -> map id), or false when it has none.
-- QuestieDB publishes these tables as text chunks ("return { [12] = 1429, ... }"), not as tables, so they are
-- decoded once here. A table is used as it is (some builds may decode them already).
local function decodeTable(v)
  if type(v) == "table" then return v end
  if type(v) ~= "string" then return nil end
  local chunk = loadstring and loadstring(v)
  if not chunk then return nil end
  local ok, t = pcall(chunk)
  return (ok and type(t) == "table") and t or nil
end

local zones
local function zoneTables()
  if zones == nil then
    local z = LibQuestieDB and LibQuestieDB.Support and LibQuestieDB.Support.Get("ZoneDB")
    local p = type(z) == "table" and z.private or nil
    if type(p) == "table" then
      zones = {
        areaToMap = decodeTable(p.areaIdToUiMapId) or {},
        areaToMapOverride = decodeTable(p.areaIdToUiMapIdOverride) or {},
        mapToArea = decodeTable(p.uiMapIdToAreaId) or {},
        mapToAreaOverride = decodeTable(p.uiMapIdToAreaIdOverride) or {},
      }
    else
      zones = false
    end
  end
  return zones
end

-- The map to show for an area, or nil. QuestieDB's override table wins, and an override of 0 means "no map".
function Data.UiMap(area)
  local z = zoneTables()
  if not z then return nil end
  local m = z.areaToMapOverride[area]
  if m == nil then m = z.areaToMap[area] end
  if type(m) ~= "number" or m <= 0 then return nil end
  return m
end

-- The area a map belongs to (the reverse of UiMap), or nil.
function Data.AreaOfUiMap(uiMap)
  local z = zoneTables()
  if not z or type(uiMap) ~= "number" then return nil end
  local a = z.mapToAreaOverride[uiMap]
  if a == nil then a = z.mapToArea[uiMap] end
  if type(a) ~= "number" or a <= 0 then return nil end
  return a
end

-- The continent an area lies on ("Eastern Kingdoms", "Kalimdor"...), from its map's parents, or nil when it has no map
-- or the game does not say.
local continentCache = {}
function Data.ContinentOf(area)
  local hit = continentCache[area]
  if hit ~= nil then return hit or nil end
  local name = false
  local m = Data.UiMap(area)
  local continent = (Enum and Enum.UIMapType and Enum.UIMapType.Continent) or 2
  for _ = 1, 8 do
    if type(m) ~= "number" or m <= 0 or not (C_Map and C_Map.GetMapInfo) then break end
    local ok, info = pcall(C_Map.GetMapInfo, m)
    if not ok or type(info) ~= "table" then break end
    if info.mapType == continent then
      if type(info.name) == "string" and info.name ~= "" then name = info.name end
      break
    end
    m = info.parentMapID
  end
  if name then continentCache[area] = name end -- (names may load later: only a found one is remembered)
  return name or nil
end

-- The area's own name first (works for any area id), then the name of the map it belongs to.
local zoneNames = {}
function Data.ZoneName(area, uiMap)
  local hit = zoneNames[area]
  if hit then return hit end
  local name = C_Map and C_Map.GetAreaInfo and C_Map.GetAreaInfo(area)
  if type(name) ~= "string" or name == "" then
    uiMap = uiMap or Data.UiMap(area)
    local info = uiMap and C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(uiMap)
    name = info and info.name
  end
  if type(name) ~= "string" or name == "" then return "Zone " .. tostring(area) end -- not cached: names may load later
  zoneNames[area] = name
  return name
end

-- Where a quest giver stands: { area, x, y, uiMap } (x, y in 0-100), or nil when no spawn is known.
function Data.Locate(giver, questId)
  local db = giver.kind == "npc" and NpcDB or ObjectDB
  local spawns = db and db.spawns and db.spawns(giver.id)
  local zone = QuestDB.zoneOrSort and QuestDB.zoneOrSort(questId)
  if type(zone) ~= "number" or zone <= 0 then zone = nil end
  local area, x, y = Core.PickSpawn(spawns, zone)
  if not area then return nil end
  return { area = area, x = x, y = y, uiMap = Data.UiMap(area) }
end

function Data.PlaceText(place)
  return ("%s (%.0f, %.0f)"):format(Data.ZoneName(place.area, place.uiMap), place.x, place.y)
end

-- Does the game have this map? A dungeon's own map often does not exist on this client, and opening a map that is
-- not there makes Blizzard's world map code throw. (True when the client cannot say.)
function Data.MapExists(m)
  if type(m) ~= "number" then return false end
  if not (C_Map and C_Map.GetMapInfo) then return true end
  local ok, info = pcall(C_Map.GetMapInfo, m)
  return ok and info ~= nil
end

-- Opens the map on the place and sets a waypoint (TomTom if installed, else the game's own).
-- Returns true, or false and a message.
local function setWaypoint(place, title)
  if not (place and place.uiMap) then return false, "No map location is known for that." end
  local m, x, y = place.uiMap, place.x / 100, place.y / 100
  if not Data.MapExists(m) then return false, "The game has no map for " .. Data.ZoneName(place.area, m) .. "." end
  if C_Map and C_Map.OpenWorldMap then pcall(C_Map.OpenWorldMap, m) end
  if TomTom and TomTom.AddWaypoint then
    TomTom:AddWaypoint(m, x, y, { title = title, world = true, minimap = true })
    return true
  end
  if C_Map and C_Map.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates then
    if C_Map.CanSetUserWaypointOnMap and not C_Map.CanSetUserWaypointOnMap(m) then
      return false, "A waypoint can't be placed on that map."
    end
    C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(m, x, y))
    if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then C_SuperTrack.SetSuperTrackedUserWaypoint(true) end
    return true
  end
  return false, "Waypoints are not available on this client."
end

function Data.Waypoint(place, title)
  local ok, a, b = pcall(setWaypoint, place, title)
  if not ok then return false, tostring(a) end
  return a, b
end

-- Partial-name search over every quest: hits (best first, capped) and the total hit count.
-- Where a quest's objectives happen: { objs = Core.Objectives(...), zones = {area ids}, extra = n more areas }.
-- Cached, since a chain asks for every quest on each redraw.
local whereCache = {}
function Data.Where(id)
  local hit = whereCache[id]
  if hit then return hit end
  local lookups = {
    npcName = function(n) return NpcDB and NpcDB.name(n) end,
    npcSpawns = function(n) return NpcDB and NpcDB.spawns and NpcDB.spawns(n) end,
    objName = function(o) return ObjectDB and ObjectDB.name(o) end,
    objSpawns = function(o) return ObjectDB and ObjectDB.spawns and ObjectDB.spawns(o) end,
    itemName = function(i) return ItemDB and ItemDB.name and ItemDB.name(i) end,
    npcDrops = function(i) return ItemDB and ItemDB.npcDrops and ItemDB.npcDrops(i) end,
    objDrops = function(i) return ItemDB and ItemDB.objectDrops and ItemDB.objectDrops(i) end,
  }
  local ok, objs = pcall(function()
    return Core.Objectives(QuestDB.objectives and QuestDB.objectives(id), QuestDB.triggerEnd and QuestDB.triggerEnd(id), lookups)
  end)
  if not ok then objs = {} end
  local zones, total = Core.TopAreas(objs, 3)
  hit = { objs = objs, zones = zones, extra = total - #zones }
  whereCache[id] = hit
  return hit
end

-- Where a quest's objectives are, as a place for a waypoint: { area, x, y, uiMap, objective }, or nil.
function Data.ObjectivePlace(id)
  local w = Data.Where(id)
  local area, x, y, obj = Core.BestSpot(w.objs, function(a) return Data.UiMap(a) ~= nil end)
  if not area then return nil end
  return { area = area, x = x, y = y, uiMap = Data.UiMap(area), objective = obj }
end

function Data.Search(text)
  return Core.Search(QuestDB.GetAllIds(), QuestDB.name, text, 40)
end

function Data.Name(id) return QuestDB and QuestDB.name(id) end

-- The client's own XP figure for a quest in your log (exact, before bonuses), or nil.
function Data.ClientXp(id)
  if not GetQuestLogRewardXP then return nil end
  if not (C_QuestLog and C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(id)) then return nil end
  local ok, total, base = pcall(GetQuestLogRewardXP, id)
  if not ok then return nil end
  local xp = base or total
  if type(xp) ~= "number" or xp <= 0 then return nil end
  return xp
end

-- Compares the table-and-formula estimate with the client's figure for every quest in your log.
-- Returns { compared = n, matched = m, lines = { "name (id): table X, client Y", ... } }.
function Data.XpCheck()
  local out = { compared = 0, matched = 0, lines = {} }
  if not (C_QuestLog and C_QuestLog.GetNumQuestLogEntries and C_QuestLog.GetInfo) then return out end
  local level = UnitLevel and UnitLevel("player") or 0
  for i = 1, C_QuestLog.GetNumQuestLogEntries() do
    local info = C_QuestLog.GetInfo(i)
    if info and not info.isHeader and info.questID then
      local client = Data.ClientXp(info.questID)
      local i2 = Data.Info(info.questID)
      if client and i2.xpBase then
        local mine = Core.ScaledXp(i2.xpBase, i2.xpLevel, level)
        out.compared = out.compared + 1
        if mine == client then
          out.matched = out.matched + 1
        else
          out.lines[#out.lines + 1] = ("%s (%d): table %d, client %d"):format(i2.name or "?", info.questID, mine, client)
        end
      end
    end
  end
  return out
end

-- ---- the Dungeon Journal (the optional ForeverDungeonJournal addon) ----
local journalDB, dungeonOf

function Data.HasJournal()
  local fdj = _G.ForeverDungeonJournal_NS
  return type(fdj) == "table" and type(fdj.DB) == "table" and type(fdj.OpenQuestPage) == "function"
end

-- The dungeon (by the journal's own name for it) a quest is done in, or nil. The journal's quest lists decide;
-- a quest listed under several dungeons goes to the first by name.
function Data.DungeonOf(id)
  if not Data.HasJournal() then return nil end
  local db = _G.ForeverDungeonJournal_NS.DB
  if journalDB ~= db then
    journalDB, dungeonOf = db, {}
    local names = {}
    for name, d in pairs(db) do
      if type(name) == "string" and type(d) == "table" then names[#names + 1] = name end
    end
    table.sort(names)
    for _, name in ipairs(names) do
      for _, q in ipairs(db[name].quests or {}) do
        if type(q) == "table" and type(q.id) == "number" and dungeonOf[q.id] == nil then dungeonOf[q.id] = name end
      end
    end
  end
  return dungeonOf[id]
end

-- Opens the journal on the quest's page in its dungeon. Returns true, or false and a message.
-- The journal's OpenQuestPage only picks the page; the window itself has to be shown first (its own callers,
-- the quest tracker and the map markers, do the same).
function Data.OpenInJournal(id)
  local name = Data.DungeonOf(id)
  if not name then return false, "That quest isn't in the Dungeon Journal." end
  local fdj = _G.ForeverDungeonJournal_NS
  local ok, err = pcall(function()
    local window = _G.ForeverDungeonJournalFrame
    if window and not window:IsShown() then
      if fdj.ToggleJournal then fdj.ToggleJournal() else window:Show() end
    end
    if fdj.IsDungeonLocked and fdj.IsDungeonLocked(name) then
      error("that dungeon is still locked in the journal")
    end
    fdj.OpenQuestPage(name, id)
  end)
  if not ok then return false, "Couldn't open the Dungeon Journal: " .. tostring(err) end
  return true
end

-- Opens the world map on an area. Returns true, or false and a message.
function Data.OpenMapAt(area)
  local m = Data.UiMap(area)
  if not (m and C_Map and C_Map.OpenWorldMap) then return false, "No map is known for " .. Data.ZoneName(area) .. "." end
  if not Data.MapExists(m) then return false, "The game has no map for " .. Data.ZoneName(area) .. "." end
  local ok, err = pcall(C_Map.OpenWorldMap, m)
  if not ok then return false, "Couldn't open the map: " .. tostring(err) end
  return true
end

-- Opens the quest log on a quest in your log, with it selected. Returns true, or false and a message.
-- Blizzard's own function does the work (the one the game's quest tracker uses); there are fallbacks for clients
-- that name it differently.
function Data.OpenInQuestLog(id)
  if InCombatLockdown and InCombatLockdown() then return false, "The quest log can't be opened in combat." end
  local index = C_QuestLog and C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(id)
  if not index then return false, "That quest isn't in your quest log." end
  local ok, err = pcall(function()
    if QuestMapFrame_OpenToQuestDetails then
      QuestMapFrame_OpenToQuestDetails(id)
    elseif QuestMapFrame_ShowQuestDetails then
      if ToggleQuestLog and not (QuestMapFrame and QuestMapFrame:IsVisible()) then ToggleQuestLog() end
      QuestMapFrame_ShowQuestDetails(id)
    elseif SelectQuestLogEntry and QuestLogFrame and ShowUIPanel then
      SelectQuestLogEntry(index)
      ShowUIPanel(QuestLogFrame)
    else
      error("no quest log function on this client")
    end
  end)
  if not ok then return false, "Couldn't open the quest log: " .. tostring(err) end
  return true
end

-- "done", "log", or nil.
function Data.Status(id)
  if C_QuestLog then
    if C_QuestLog.IsQuestFlaggedCompleted and C_QuestLog.IsQuestFlaggedCompleted(id) then return "done" end
    if C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(id) then return "log" end
  end
  return nil
end

-- Is this quest only a breadcrumb (it exists to lead into another quest)?
function Data.IsBreadcrumb(id)
  local idx = Data.index
  return (idx and idx.breadcrumb and idx.breadcrumb[id]) and true or false
end

-- The quest a breadcrumb leads into, or nil.
function Data.BreadcrumbTarget(id)
  local ok, t = pcall(function() return QuestDB.breadcrumbForQuestId and QuestDB.breadcrumbForQuestId(id) end)
  if ok and type(t) == "number" and t > 0 then return t end
  return nil
end

-- The quest log's own objective lines for a quest that is in your log ("Boar slain: 3/8"):
-- { { text, done }, ... }. QuestieDB lists what to kill and collect but not how many, so the counts
-- can only come from here.
function Data.LiveObjectives(id)
  local out = {}
  if not (C_QuestLog and C_QuestLog.GetQuestObjectives and C_QuestLog.GetLogIndexForQuestID) then return out end
  if not C_QuestLog.GetLogIndexForQuestID(id) then return out end
  local ok, list = pcall(C_QuestLog.GetQuestObjectives, id)
  if not ok or type(list) ~= "table" then return out end
  for _, o in ipairs(list) do
    if type(o) == "table" and type(o.text) == "string" and o.text ~= "" then
      out[#out + 1] = { text = o.text, done = o.finished and true or false }
    end
  end
  return out
end

-- A reward item's name: the client's, once it has the item cached, else QuestieDB's.
function Data.ItemName(id)
  local n = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)
  if type(n) == "string" and n ~= "" then return n end
  n = ItemDB and ItemDB.name and ItemDB.name(id)
  if type(n) == "string" and n ~= "" then return n end
  return "Item " .. id
end

-- The colour code of an item's quality ("|cff1eff00"), or nil when the client does not say.
function Data.ItemColor(id)
  local q = C_Item and C_Item.GetItemQualityByID and C_Item.GetItemQualityByID(id)
  local c = q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
  local hex = c and c.hex
  if type(hex) == "string" and hex:sub(1, 2) == "|c" then return hex end
  return nil
end

function Data.FactionName(id)
  if C_Reputation and C_Reputation.GetFactionDataByID then
    local d = C_Reputation.GetFactionDataByID(id)
    if d and d.name then return d.name end
  end
  if GetFactionInfoByID then
    local n = GetFactionInfoByID(id)
    if n then return n end
  end
  return "Faction " .. id
end

-- Resolve text to a quest id. Returns id, or nil and a message.
function Data.Resolve(text)
  local id, name = Core.ParseRef(text)
  if id then return id end
  if not name then return nil end
  local ids = QuestDB.IdsByName and QuestDB.IdsByName(name)
  if ids and ids[1] then return ids[1], (#ids > 1) and (#ids .. " quests share that name; showing the first.") or nil end
  local hits, total = Data.Search(name)
  if total == 1 then return hits[1].id, nil end
  if total > 1 then return nil, ('%d quests match "%s".'):format(total, name), hits, total end
  return nil, 'No quest named "' .. name .. '" (an ID or quest link also works).'
end
