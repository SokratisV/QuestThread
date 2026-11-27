local ADDON, ns = ...
local Data, UI = ns.Data, ns.UI

local function Say(msg) print("|cffffd100QuestThread:|r " .. msg) end

local function DB()
  QuestThreadDB = QuestThreadDB or {}
  return QuestThreadDB
end

-- Looks like a stock WoW minimap button: round gold ring, dark disc, chain icon, round glow on hover.
-- (Blizzard's own textures; sizes follow the standard 31-px minimap button, scaled to w.)
local function MakeChainButton(parent, w, h, name)
  local s = w / 31
  local b = CreateFrame("Button", name, parent)
  b:SetSize(w, h)
  b.bg = b:CreateTexture(nil, "BACKGROUND")
  b.bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  b.bg:SetSize(20 * s, 20 * s)
  b.bg:SetPoint("TOPLEFT", 7 * s, -5 * s)
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetTexture("Interface\\AddOns\\QuestThread\\Chain.tga")
  b.icon:SetSize(17 * s, 17 * s)
  b.icon:SetPoint("TOPLEFT", 7 * s + 1.5 * s, -5 * s - 1.5 * s)
  b.border = b:CreateTexture(nil, "OVERLAY")
  b.border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  b.border:SetSize(53 * s, 53 * s)
  b.border:SetPoint("TOPLEFT")
  b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  local x, y = 7 * s + 1.5 * s, -5 * s - 1.5 * s
  b:SetScript("OnMouseDown", function(self) self.icon:SetPoint("TOPLEFT", x + s, y - s) end)
  b:SetScript("OnMouseUp", function(self) self.icon:SetPoint("TOPLEFT", x, y) end)
  return b
end

ns.MakeChainButton = MakeChainButton -- the quest dialogue (QuestFrame.lua) uses the same button

local function Tip(b, text)
  b:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText(text)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- ---- a Chain button next to every quest in the quest log list ----
-- The rows are Blizzard's; a button is added as a child of each (no script is added to any
-- Blizzard frame). Rows are recycled, so a light check a few times a second keeps every visible
-- row's button pointed at the quest the row currently shows.
local rowButtons = setmetatable({}, { __mode = "k" })

local function ForEachRow(fn)
  if not QuestScrollFrame then return end
  local box = QuestScrollFrame.ScrollBox
  if box and box.ForEachFrame then
    box:ForEachFrame(fn)
  elseif QuestScrollFrame.Contents and QuestScrollFrame.Contents.GetChildren then
    for _, child in ipairs({ QuestScrollFrame.Contents:GetChildren() }) do fn(child) end
  end
end

local function RowQuestID(row)
  local q = row.questID
  if type(q) == "number" and q > 0 and row.GetObjectType and row:GetObjectType() == "Button" then return q end
  return nil
end

-- Default place: just left of the tracking checkbox (button's right edge 34 px inside the row).
-- Some rows carry a "(Dungeon)" / "(Group)" tag text there, so the row is looked at (read-only):
-- any visible text or frame in the right half of the title line pushes the button further left,
-- to sit just before it.
local DEFAULT_INSET, GAP = 34, 4

local function RightLimit(row, b)
  local rl, rr, rt = row:GetLeft(), row:GetRight(), row:GetTop()
  if not (rl and rr and rt) then return nil end -- not laid out yet
  local limit, mid = rr - DEFAULT_INSET, (rl + rr) / 2
  local function consider(el)
    if el == b or not el.IsShown or not el:IsShown() then return end
    local left, top = el:GetLeft(), el:GetTop()
    if not (left and top) or left < mid or math.abs(rt - top) > 24 then return end
    if el.GetObjectType and el:GetObjectType() == "FontString" then
      local text = el.GetText and el:GetText()
      if not text or text == "" then return end
    end
    if left - GAP < limit then limit = left - GAP end
  end
  for _, region in ipairs({ row:GetRegions() }) do
    if region.GetObjectType and region:GetObjectType() == "FontString" then consider(region) end
  end
  for _, child in ipairs({ row:GetChildren() }) do consider(child) end
  return rr - limit, rr - rl
end

local function PlaceRowButton(row, b, q)
  local inset, width = RightLimit(row, b)
  if not inset then return end
  local key = q .. ":" .. math.floor(width)
  if b.placedFor == key then return end
  b.placedFor = key
  b:ClearAllPoints()
  b:SetPoint("TOPRIGHT", row, "TOPRIGHT", -inset, -3)
end

local function UpdateRow(row)
  local q = RowQuestID(row)
  local b = rowButtons[row]
  if not q then
    if b then b:Hide() end
    return
  end
  if not b then
    b = MakeChainButton(row, 22, 22)
    b:SetFrameLevel(row:GetFrameLevel() + 5)
    b:SetPoint("TOPRIGHT", row, "TOPRIGHT", -DEFAULT_INSET, -3)
    Tip(b, "Show this quest's whole chain")
    b:SetScript("OnClick", function(self) if self.questID then UI.Open(self.questID) end end)
    rowButtons[row] = b
  end
  b.questID = q
  PlaceRowButton(row, b, q)
  b:Show()
end

local driver, acc = nil, 0
local function Tick(_, dt)
  acc = acc + dt
  if acc < 0.15 then return end
  acc = 0
  if not (QuestMapFrame and QuestMapFrame:IsVisible()) then return end
  ForEachRow(UpdateRow)
end

local hooked = false
local function HookQuestLog()
  if hooked or not QuestMapFrame then return end
  hooked = true
  driver = CreateFrame("Frame")
  driver:SetScript("OnUpdate", Tick)
  -- Follow the quest log: opening another quest while the chain window is up updates it.
  if hooksecurefunc and QuestMapFrame_ShowQuestDetails then
    hooksecurefunc("QuestMapFrame_ShowQuestDetails", function(questID)
      if UI.IsShown() and questID and questID ~= 0 then UI.Open(questID) end
    end)
  end
end

-- ---- Ctrl+click a Questie quest icon (world map or minimap) ----
-- Questie's icons are its own frames (QuestieFrame<N>); nothing is hooked on them. While Ctrl is held
-- a tiny per-frame check sees a fresh left click and, if the mouse is over a Questie quest icon,
-- opens that quest's chain. (Questie itself only uses Ctrl+click for a TomTom waypoint.)
local function MouseFoci()
  if GetMouseFoci then return GetMouseFoci() or {} end
  local f = GetMouseFocus and GetMouseFocus()
  return f and { f } or {}
end

local function QuestieIconQuest(frame)
  if type(frame) ~= "table" or not frame.GetName then return nil end
  local name = frame:GetName()
  if type(name) ~= "string" or not name:find("^QuestieFrame%d+$") then return nil end
  local data = frame.data
  if type(data) == "table" and data.QuestData and type(data.Id) == "number" then return data.Id end
  return nil
end

-- Questie lists every quest around an icon in its hover tooltip and keeps that list on GameTooltip
-- (npcAndObjectOrder: giver -> quest, with each quest's questId). Read it, never change it.
local function TooltipQuests(icons, add)
  local tip = GameTooltip
  if not tip or not tip.IsShown or not tip:IsShown() then return end
  local owner = tip._owner
  local hovered = false
  for _, f in ipairs(icons) do if f == owner then hovered = true end end
  if not hovered then return end
  for _, quests in pairs(tip.npcAndObjectOrder or {}) do
    for _, q in pairs(quests) do
      if type(q) == "table" and type(q.questId) == "number" then add(q.questId) end
    end
  end
  for id in pairs(tip.questOrder or {}) do
    if type(id) == "number" then add(id) end
  end
end

local iconWatcher, wasDown = nil, false
local function StartIconWatch()
  if iconWatcher then return end
  iconWatcher = CreateFrame("Frame")
  iconWatcher:SetScript("OnUpdate", function()
    local down = IsControlKeyDown() and not IsShiftKeyDown() and not IsAltKeyDown() and IsMouseButtonDown("LeftButton")
    if down and not wasDown then
      -- Every Questie icon under the cursor: stacked icons mean several quests share the spot.
      local ok, ids = pcall(function()
        local list, seen = {}, {}
        local function add(id)
          if not seen[id] then seen[id] = true; list[#list + 1] = id end
        end
        local foci, icons = MouseFoci(), {}
        for _, f in ipairs(foci) do
          local id = QuestieIconQuest(f)
          if id then icons[#icons + 1] = f; add(id) end
        end
        if #icons > 0 then TooltipQuests(icons, add) end
        return list
      end)
      if ok and #ids > 0 then UI.OpenIds(ids) end
    end
    wasDown = down and true or false
  end)
end

-- What a click on the minimap button does: close the window if it is up; otherwise open it on the Zones tab,
-- on the area you are standing in.
local function ToggleWindow()
  UI.Toggle()
end

-- ---- slash command ----
SLASH_QUESTTHREAD1 = "/qthread"
SLASH_QUESTTHREAD2 = "/questthread"
SLASH_QUESTTHREAD3 = "/qt"
SlashCmdList["QUESTTHREAD"] = function(msg)
  msg = (msg or ""):match("^%s*(.-)%s*$")
  if msg == "log" then
    UI.ShowLog()
  elseif msg == "minimap" then
    Say(ns.MinimapButton.Toggle() and "Minimap button shown." or "Minimap button hidden. Type /qthread minimap to show it again.")
  elseif msg == "reset" then
    UI.Reset()
    DB().button, DB().mapButton = nil, nil -- (old settings: those buttons are gone)
    ns.MinimapButton.Reset()
    Say("Window and minimap button put back (centre of the screen, normal size).")
  elseif msg:match("^scale") then
    local v = tonumber(msg:match("^scale%s+([%d%.]+)"))
    if v then Say(("Window scale set to %.2f."):format(UI.SetScale(v))) else Say("Usage: /qthread scale 1.2 (from 0.6 to 1.6)") end
  elseif msg == "map" then
    if not ns.MapPanel.Toggle() then Say("The map panel is hidden (or the map isn't available). Type /qthread map to show it again.") end
  elseif msg == "zone" or msg == "zones" or msg:match("^zones?%s") then
    UI.OpenZoneText(msg:match("^zones?%s+(.*)$") or "")
  elseif msg == "xpcheck" then
    local r = Data.XpCheck()
    if r.compared == 0 then
      Say("No quest in your log has both a table entry and a client XP figure to compare.")
    else
      Say(("XP check: %d of %d quests in your log match the client."):format(r.matched, r.compared))
      for i = 1, math.min(#r.lines, 15) do print("  " .. r.lines[i]) end
    end
  elseif msg == "" then
    UI.Toggle()
  else
    UI.OpenText(msg)
  end
end

-- ---- the Back key (Key Bindings > QuestThread; Bindings.xml runs QuestThread_Back) ----
-- An optional key that goes Back from anywhere; it does nothing while the window is closed. (Mouse button 4 goes
-- Back over the window without any binding: see the window's code in UI.lua.)
_G.BINDING_NAME_QUESTTHREAD_BACK = "QuestThread: Back"
function _G.QuestThread_Back()
  if UI.IsShown() then UI.Back() end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("ADDON_LOADED")
ev:SetScript("OnEvent", function(_, event, name)
  if event == "PLAYER_LOGIN" then
    local ok, why = true, nil
    if LibQuestieDB and LibQuestieDB.RequireContract then ok, why = LibQuestieDB.RequireContract(4) end
    if not ok then Say(why or "QuestieDB is incompatible.") return end
    StartIconWatch()
    ns.QuestFrame.Init()
    ns.MinimapButton.Init(ToggleWindow)
    ns.MapPanel.Init()
  end
  if event == "ADDON_LOADED" and name ~= "Blizzard_WorldMap" and name ~= "Blizzard_QuestMap" then return end
  if event ~= "ADDON_LOADED" or name == "Blizzard_WorldMap" then ns.MapPanel.Init() end
  HookQuestLog()
end)
