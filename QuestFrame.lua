-- The quest dialogue (the window you get when you talk to someone about a quest): a chain button and
-- the quest's ID. The ID is green once the quest is done, and also for a repeatable quest that you have
-- completed at least once; violet while it is in your log, orange otherwise.
--
-- The QuestID addon draws "Quest ID: N" in the same corner. When it is loaded and showing its text, this
-- addon adds only the chain button beside it (and greens its text for a repeatable you have done).
local ADDON, ns = ...
local Data, UI = ns.Data, ns.UI
local QF = {}
ns.QuestFrame = QF

local COLORS = { done = { 0, 1, 0 }, log = { 0.8, 0, 1 }, new = { 1, 0.5, 0 } }
local PANELS = { "QuestFrameDetailPanel", "QuestFrameProgressPanel", "QuestFrameRewardPanel" }

local holder, chain, idText

-- The visible step of the dialogue, and whether it is one of the two with the extra right margin.
local function ActivePanel()
  for _, name in ipairs(PANELS) do
    local p = _G[name]
    if p and p:IsShown() then return p, name ~= "QuestFrameDetailPanel" end
  end
end

local function CurrentId()
  local id = GetQuestID and GetQuestID()
  if (not id or id == 0) and GetRewardQuestID then id = GetRewardQuestID() end
  if type(id) == "number" and id > 0 then return id end
end

-- Is the QuestID addon drawing its own "Quest ID: N" on the quest dialogue?
local function OtherShowsId()
  return type(_G.QuestID) == "table" and type(QuestID.QuestFrame) == "table"
    and not (QuestIDDB and QuestIDDB.questFrameDisplay == false)
end

local function Create()
  if holder then return end
  holder = CreateFrame("Frame", nil, UIParent)
  holder:SetSize(1, 1)
  idText = holder:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  chain = ns.MakeChainButton(holder, 22, 22)
  chain:SetScript("OnClick", function(self) if self.questID then UI.Open(self.questID) end end)
  chain:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Show this quest's whole chain")
    GameTooltip:Show()
  end)
  chain:SetScript("OnLeave", function() GameTooltip:Hide() end)
  holder:Hide()
end

function QF.Hide()
  if holder then holder:Hide() end
end

function QF.Update()
  local id = CurrentId()
  local panel, narrow = ActivePanel()
  if not id or not panel then return QF.Hide() end
  Create()
  holder:SetParent(panel)
  holder:SetFrameLevel(panel:GetFrameLevel() + 10)
  -- The same corner QuestID uses: 20 px in from the right edge (60 on the two later steps), 35 px down.
  local x = narrow and -60 or -20
  local text = "Quest ID: " .. id
  idText:SetText(text)
  idText:ClearAllPoints()
  idText:SetPoint("TOPRIGHT", panel, "TOPRIGHT", x, -35)
  local c = COLORS[Data.QuestState(id)]
  idText:SetTextColor(c[1], c[2], c[3])
  chain.questID = id
  chain:ClearAllPoints()
  if OtherShowsId() then
    -- Its text sits where ours would: stay to the left of it, by the width of that text.
    idText:Hide()
    chain:SetPoint("TOPRIGHT", panel, "TOPRIGHT", x - idText:GetStringWidth() - 6, -30)
  else
    idText:Show()
    chain:SetPoint("RIGHT", idText, "LEFT", -4, 0)
  end
  holder:Show()
end

-- QuestID colours its text itself and knows nothing of repeatable quests, so after it paints, a repeatable
-- you have completed at least once is made green. Only its text colour is touched.
local function Recolor()
  local id = CurrentId()
  local panel = ActivePanel()
  if not id or not panel or not Data.RepeatableDone(id) then return end
  local g = COLORS.done
  for _, region in ipairs({ panel:GetRegions() }) do
    if region.GetObjectType and region:GetObjectType() == "FontString" then
      local t = region:GetText()
      if type(t) == "string" and t:find("^Quest ID: ") then region:SetTextColor(g[1], g[2], g[3]) end
    end
  end
end

function QF.Init()
  if QF.ready then return end
  QF.ready = true
  local ev = CreateFrame("Frame")
  ev:RegisterEvent("QUEST_DETAIL")
  ev:RegisterEvent("QUEST_PROGRESS")
  ev:RegisterEvent("QUEST_COMPLETE")
  ev:RegisterEvent("QUEST_FINISHED")
  ev:RegisterEvent("QUEST_TURNED_IN")
  ev:SetScript("OnEvent", function(_, event, arg)
    if event == "QUEST_TURNED_IN" then
      Data.RecordTurnIn(arg)
    elseif event == "QUEST_FINISHED" then
      QF.Hide()
    else
      -- The game fills in the quest and shows the panel a moment later.
      C_Timer.After(0, function() pcall(QF.Update) end)
    end
  end)
  if hooksecurefunc and type(_G.QuestID) == "table" and type(QuestID.QuestFrame) == "table" then
    for _, name in ipairs({ "Update", "UpdateColor" }) do
      if type(QuestID.QuestFrame[name]) == "function" then
        hooksecurefunc(QuestID.QuestFrame, name, function() pcall(Recolor) end)
      end
    end
  end
end
