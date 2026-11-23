-- A panel beside the world map: the quests that start in the zone the map is showing, by chain, single quest and
-- object or item. It follows the map as you move between zones; a click opens the quest in QuestThread's window.
-- The panel is our own frame under WorldMapFrame; nothing of Blizzard's is changed.
local ADDON, ns = ...
local Core, Data = ns.Core, ns.Data
local MP = {}
ns.MapPanel = MP

local PANEL_W, ROW_H = 300, 22
local STATUS_TEX = "Interface\\AddOns\\QuestThread\\Status.tga"
local STATUS_COLOR = { done = "|cffa8c8ac", log = "|cff8fc4ff", available = "|cffffffff", locked = "|cffb4b4b4", missed = "|cff9a9488" }
local STATUS_TEXT = {
  done = { "Completed", 0.4, 0.8, 0.4 }, log = { "In your quest log", 0.56, 0.77, 1 },
  available = { "Available now", 0.4, 1, 0.4 }, locked = { "Locked", 1, 0.4, 0.4 }, missed = { "Missed", 0.85, 0.65, 0.3 },
}
local CHIPS = { { "available", "Available" }, { "log", "In log" }, { "missed", "Missed" }, { "done", "Done" }, { "all", "All" } }
local BRONZE_LIT = { 1, 0.86, 0.46 }

local W -- ns.UI.Widgets, looked up when first needed (UI.lua loads before this file, but not before PLAYER_LOGIN)
local panel, button
local rows = {}
local lastMap, dirty, acc = nil, true, 0

local function DB()
  QuestThreadDB = QuestThreadDB or {}
  return QuestThreadDB
end

local function Filter()
  DB().zone = DB().zone or {}
  return DB().zone.filter or "available"
end

local function PlacePanel()
  panel:ClearAllPoints()
  local right, uiRight = WorldMapFrame:GetRight(), UIParent:GetRight()
  local s, us = WorldMapFrame:GetEffectiveScale(), UIParent:GetEffectiveScale()
  local beside = not (right and uiRight and s and us) or (right * s + (PANEL_W + 4) * s <= uiRight * us)
  local h = WorldMapFrame:GetHeight()
  h = (type(h) == "number" and h > 0) and h or 500
  if beside then
    panel:SetPoint("TOPLEFT", WorldMapFrame, "TOPRIGHT", 4, 0)
    panel:SetHeight(h)
  else -- a maximized map has no room beside it: sit inside it, on the right
    panel:SetPoint("TOPRIGHT", WorldMapFrame, "TOPRIGHT", -8, -70)
    panel:SetHeight(math.max(250, h - 90))
  end
end

local function GetRow(i)
  local r = rows[i]
  if r then return r end
  r = CreateFrame("Button", nil, panel.content)
  r:SetSize(PANEL_W - 16, ROW_H)
  r.hl = W.Solid(r, "BACKGROUND", 0.98, 0.74, 0.36, 0.2)
  r.hl:SetAllPoints(); r.hl:Hide()
  r.icon = r:CreateTexture(nil, "ARTWORK")
  r.icon:SetTexture(STATUS_TEX)
  r.icon:SetSize(14, 14)
  r.icon:SetPoint("LEFT", 2, 0)
  r.text = W.Text(r, "GameFontHighlightSmall")
  r.text:SetPoint("LEFT", 20, 0); r.text:SetWidth(PANEL_W - 16 - 20 - 78)
  r.right = W.Text(r, "GameFontNormalSmall", "RIGHT")
  r.right:SetPoint("RIGHT", -2, 0); r.right:SetWidth(76)
  r:RegisterForClicks("LeftButtonUp")
  r:SetScript("OnEnter", function(self)
    self.hl:Show()
    local e = self.entry
    if not e then return end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine(e.name, 1, 0.82, 0)
    local st = STATUS_TEXT[e.status]
    if st then GameTooltip:AddLine(st[1], st[2], st[3], st[4]) end
    for _, line in ipairs(e.unmet or {}) do GameTooltip:AddLine(line, 1, 0.5, 0.5, true) end
    if e.grey then GameTooltip:AddLine(e.grey .. " (grey to you)", 0.62, 0.6, 0.55, true) end
    if type(e.objective) == "table" and #e.objective > 0 then
      GameTooltip:AddLine(" ")
      for _, line in ipairs(e.objective) do GameTooltip:AddLine(line, 1, 1, 1, true) end
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click: open it in QuestThread", 0.6, 0.6, 0.6)
    GameTooltip:Show()
  end)
  r:SetScript("OnLeave", function(self) self.hl:Hide(); GameTooltip:Hide() end)
  r:SetScript("OnClick", function(self)
    if self.questId then ns.UI.Open(self.questId, false, true) end
  end)
  rows[i] = r
  return r
end

-- Lays the list out: items are { head = text, count } | { id } | { chain = c }.
local function Layout(items, ev, model)
  local Zones = ns.Zones
  local y = 0
  for i, item in ipairs(items) do
    local r = GetRow(i)
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", panel.content, "TOPLEFT", 0, -y)
    r.questId, r.entry = nil, nil
    r.text:SetText(""); r.right:SetText("")
    r.icon:Hide(); r.icon:SetDesaturated(false)
    r.text:ClearAllPoints(); r.text:SetPoint("LEFT", 20, 0)
    if item.head then
      r.text:ClearAllPoints(); r.text:SetPoint("LEFT", 2, 0)
      r.text:SetText((item.color or "|cffffd100") .. item.head .. "|r")
      if item.count then r.right:SetText("|cff9aa0a8" .. item.count .. "|r") end
    else
      local id, status, name, level, right, indent
      if item.chain then
        local c = item.chain
        id, status, name, right = c.entry, ev.chain[c].status, c.name, c.parts .. " steps"
        level = c.minLevel or Zones.InfoOf(c.entry).level
      else
        local s = ev.quest[item.id]
        id, status, level = item.id, s.status, Zones.InfoOf(item.id).level
        name = Zones.InfoOf(item.id).name or ("Quest " .. item.id)
        if status == "missed" then right = "|cffd9a04aMissed|r" elseif ev.quest[item.id].greyNote then right = "|cff9a9488Grey|r" end
      end
      indent = item.indent or 0
      local info = Zones.InfoOf(id)
      local s = ev.quest[id]
      r.questId = id
      r.entry = { id = id, name = name, level = level, status = item.chain and ev.chain[item.chain].status or status,
        unmet = s.detail, grey = s.greyNote, objective = info.objective }
      local dim = status == "missed"
      local cell = W.StatusCell(dim and "locked" or status, (not item.chain) and id or nil)
      if cell then
        W.SetCell(r.icon, cell)
        r.icon:ClearAllPoints(); r.icon:SetPoint("LEFT", 2 + indent, 0)
        r.icon:SetDesaturated(dim)
        r.icon:Show()
      end
      r.text:ClearAllPoints(); r.text:SetPoint("LEFT", 20 + indent, 0)
      r.text:SetText(W.Crumb(id) .. W.LevelTag(level) .. STATUS_COLOR[status] .. name .. "|r")
      if right then r.right:SetText(item.chain and ("|cff8fb4c8" .. right .. "|r") or right) end
    end
    r:Show()
    y = y + ROW_H
  end
  for i = #items + 1, #rows do rows[i]:Hide() end
  panel.content:SetHeight(math.max(y, 1))
end

local function Message(title, sub)
  panel.title:SetText(title)
  panel.sub:SetText(sub)
  for _, r in ipairs(rows) do r:Hide() end
  panel.content:SetHeight(1)
  for _, b in ipairs(panel.chips) do b.under:Hide() end
end

local function Refresh()
  dirty = false
  local Zones = ns.Zones
  if Data.state == "error" or Zones.state == "error" then
    return Message("Quests here", "|cffff6060" .. tostring(Data.error or Zones.error) .. "|r")
  end
  if Zones.state ~= "ready" then
    local p = Data.state == "building" and Data.progress * 0.5 or 0.5 + 0.5 * Zones.progress
    return Message("Quests here", ("Reading QuestieDB… %d%%"):format(math.floor(p * 100)))
  end
  local area = Zones.AreaForMap(lastMap)
  panel.area = area
  if not area then return Message("Quests here", "No quests start on this map. Open a zone's map.") end

  local model = Zones.Model(area)
  local ev = Zones.Evaluate(model)
  local t = ev.totals
  local filter = Filter()
  panel.title:SetText(model.name)
  panel.sub:SetText(("%d quests in this zone · %d available · %d missed"):format(t.quests, t.available, t.missed))
  for _, b in ipairs(panel.chips) do b.under:SetShown(b.key == filter) end

  local function visible(list)
    local out = {}
    for _, id in ipairs(list) do
      if Zones.Matches(filter, ev.quest[id].status) then out[#out + 1] = id end
    end
    return out
  end
  local items = {}
  local chains = {}
  for _, c in ipairs(model.chains) do
    if Zones.ChainMatches(filter, ev.chain[c]) then chains[#chains + 1] = c end
  end
  if #chains > 0 then
    items[#items + 1] = { head = "Chains", count = #chains }
    for _, c in ipairs(chains) do items[#items + 1] = { chain = c } end
  end
  local singles = visible(model.singles)
  if #singles > 0 then
    items[#items + 1] = { head = "Single quests", count = #singles }
    for _, id in ipairs(singles) do items[#items + 1] = { id = id } end
  end
  local objects = {}
  for _, g in ipairs(model.objGroups) do
    local qs = visible(g.quests)
    if #qs > 0 then objects[#objects + 1] = { g = g, qs = qs } end
  end
  if #objects > 0 then
    local total = 0
    for _, e in ipairs(objects) do total = total + #e.qs end
    items[#items + 1] = { head = "Start from objects and items", count = total }
    for _, e in ipairs(objects) do
      items[#items + 1] = { head = e.g.name .. " (" .. e.g.kind .. ")", color = "|cffe0a64a" }
      for _, id in ipairs(e.qs) do items[#items + 1] = { id = id, indent = 12 } end
    end
  end
  if #items == 0 then items[1] = { head = "Nothing here with this filter. Try All.", color = "|cff9aa0a8" } end
  Layout(items, ev, model)
end

local function Build()
  W = ns.UI.Widgets
  panel = CreateFrame("Frame", "QuestThreadMapPanel", WorldMapFrame, "BackdropTemplate")
  panel:SetWidth(PANEL_W)
  panel:EnableMouse(true)
  panel:SetFrameLevel(WorldMapFrame:GetFrameLevel() + 30)
  W.Boxed(panel, true)
  panel:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
  panel.title = W.Text(panel, "GameFontNormalLarge")
  panel.title:SetPoint("TOPLEFT", 12, -10); panel.title:SetWidth(PANEL_W - 24)
  panel.sub = W.Text(panel, "GameFontHighlightSmall")
  panel.sub:SetPoint("TOPLEFT", 12, -32); panel.sub:SetWidth(PANEL_W - 24)
  panel.chips = {}
  for i, c in ipairs(CHIPS) do
    local b = CreateFrame("Button", nil, panel)
    b:SetSize(54, 20)
    b:SetPoint("TOPLEFT", 10 + (i - 1) * 56, -52)
    b.key = c[1]
    b.text = W.Text(b, "GameFontNormalSmall", "CENTER")
    b.text:SetAllPoints(); b.text:SetText(c[2])
    b.under = W.Solid(b, "OVERLAY", BRONZE_LIT[1], BRONZE_LIT[2], BRONZE_LIT[3], 1)
    b.under:SetPoint("BOTTOMLEFT", 4, 0); b.under:SetPoint("BOTTOMRIGHT", -4, 0); b.under:SetHeight(2)
    b:SetScript("OnClick", function(self)
      DB().zone = DB().zone or {}
      DB().zone.filter = self.key -- the same filter the Zones tab uses
      Refresh()
    end)
    panel.chips[i] = b
  end
  panel.scroll = CreateFrame("ScrollFrame", nil, panel)
  panel.scroll:SetPoint("TOPLEFT", 8, -78)
  panel.scroll:SetPoint("BOTTOMRIGHT", -8, 40)
  panel.content = CreateFrame("Frame", nil, panel.scroll)
  panel.content:SetSize(PANEL_W - 16, 1)
  panel.scroll:SetScrollChild(panel.content)
  panel.scroll:EnableMouseWheel(true)
  panel.scroll:SetScript("OnMouseWheel", function(self, delta)
    local max = math.max(0, panel.content:GetHeight() - self:GetHeight())
    self:SetVerticalScroll(math.min(max, math.max(0, self:GetVerticalScroll() - delta * 44)))
  end)
  panel.window = W.Button(panel, "Open in window", 120, 22)
  panel.window:SetPoint("BOTTOMLEFT", 12, 10)
  panel.window:SetScript("OnClick", function() ns.UI.ShowZones(panel.area) end)

  panel:SetScript("OnShow", function()
    lastMap, dirty = WorldMapFrame:GetMapID(), true
    PlacePanel()
    ns.Zones.Ensure(function() dirty = true end)
  end)
  panel:SetScript("OnUpdate", function(_, dt)
    acc = acc + dt
    if acc < 0.25 then return end
    acc = 0
    local m = WorldMapFrame:GetMapID()
    if m ~= lastMap then lastMap, dirty = m, true; panel.scroll:SetVerticalScroll(0) end
    if ns.Zones.state == "building" then dirty = true end
    if dirty then Refresh() end
  end)
  -- Quests change while the map is open: take it again on the next look.
  panel:RegisterEvent("QUEST_LOG_UPDATE")
  panel:RegisterEvent("QUEST_TURNED_IN")
  panel:SetScript("OnEvent", function() dirty = true end)
  panel:Hide()
end

function MP.ShowPanel()
  if not WorldMapFrame then return false end
  if not panel then Build() end
  DB().mapPanel = true
  panel:Show()
  lastMap = WorldMapFrame:GetMapID()
  PlacePanel()
  ns.Zones.Ensure(function() dirty = true end)
  Refresh()
  return true
end

function MP.HidePanel()
  DB().mapPanel = false
  if panel then panel:Hide() end
end

-- Toggles the panel (opening the map first when it is shut). Returns true when it is now shown.
function MP.Toggle()
  if not WorldMapFrame then return false end
  if panel and panel:IsShown() then MP.HidePanel(); return false end
  if not WorldMapFrame:IsShown() and ToggleWorldMap then pcall(ToggleWorldMap) end
  return MP.ShowPanel()
end

function MP.IsShown() return panel ~= nil and panel:IsShown() end

-- The panel coming back when the map opens (if you left it on). There is no button on the map itself: it floated over
-- other addons' map frames, and /qthread map opens the panel.
local inited
function MP.Init()
  if inited or not WorldMapFrame then return end
  inited = true
  WorldMapFrame:HookScript("OnShow", function()
    if DB().mapPanel then MP.ShowPanel() end
  end)
  if DB().mapPanel and WorldMapFrame:IsShown() then MP.ShowPanel() end
end
