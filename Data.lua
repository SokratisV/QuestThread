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
  }
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

-- "done", "log", or nil.
function Data.Status(id)
  if C_QuestLog then
    if C_QuestLog.IsQuestFlaggedCompleted and C_QuestLog.IsQuestFlaggedCompleted(id) then return "done" end
    if C_QuestLog.GetLogIndexForQuestID and C_QuestLog.GetLogIndexForQuestID(id) then return "log" end
  end
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
  return nil, 'No quest named "' .. name .. '" (names must match exactly; an ID or quest link also works).'
end
