-- The chain window. Built from plain frames and textures (no Blizzard templates, no writes
-- to Blizzard globals, no StaticPopup).
local ADDON, ns = ...
local Core, Data = ns.Core, ns.Data
local UI = {}
ns.UI = UI

local WIDTH, HEIGHT = 470, 580
local CONTENT_W = WIDTH - 48
local ICON = 22
local FLAT = "Interface\\Buttons\\WHITE8X8"
-- Step status icons: four 32x32 cells in one sheet (tools/make-status-icons.py).
local STATUS_TEX = "Interface\\AddOns\\QuestThread\\Status.tga"
local STATUS_CELL = { done = 0, log = 1, available = 2, locked = 3 }

-- Look and colours follow FlareUI's windows: a dark panel, a thin bronze edge (FlareUI's own
-- Thin.tga border, MIT-licensed, copied here), Blizzard-yellow titles, and Blizzard's grey dropdown
-- face for buttons. The bronze values are FlareUI's.
local THIN = "Interface\\AddOns\\QuestThread\\Thin.tga"
local BRONZE, BRONZE_HOVER, BRONZE_LIT, BRONZE_MUTED = { 0.55, 0.42, 0.24 }, { 0.98, 0.74, 0.36 }, { 1, 0.86, 0.46 }, { 0.61, 0.48, 0.29 }
local FACE = "common-dropdown-c-button"

-- A frame (made with "BackdropTemplate") with the thin bronze edge, optionally with a fill.
local function Boxed(f, fill)
  f:SetBackdrop({ bgFile = fill and FLAT or nil, edgeFile = THIN, edgeSize = 8,
    insets = { left = 4, right = 4, top = 4, bottom = 4 } })
  f:SetBackdropBorderColor(BRONZE[1], BRONZE[2], BRONZE[3], 1)
end

local frame, content, scroll
local rows, iconPool = {}, {}
local current, showRemaining, notice, results, backTo
local Render -- defined below; the row click handlers need it

local function Say(msg) print("|cffffd100QuestThread:|r " .. msg) end

local function DB()
  QuestThreadDB = QuestThreadDB or {}
  return QuestThreadDB
end

local function Num(n)
  local s = tostring(math.floor(n + 0.5))
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (out:gsub("^,", ""))
end

local function Solid(parent, layer, r, g, b, a)
  local t = parent:CreateTexture(nil, layer)
  t:SetTexture(FLAT)
  t:SetVertexColor(r, g, b, a or 1)
  return t
end

local function Text(parent, font, justify)
  local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
  fs:SetJustifyH(justify or "LEFT")
  fs:SetWordWrap(false)
  return fs
end

local function Button(parent, label, w, h)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(w, h)
  local hasFace = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(FACE) and true or false
  b.face = b:CreateTexture(nil, "BACKGROUND", nil, 2)
  if hasFace then
    b.face:SetPoint("TOPLEFT", -7, 7); b.face:SetPoint("BOTTOMRIGHT", 7, -7) -- the art reaches 7 px past the button
  else
    b.face:SetAllPoints(); b.face:SetTexture(FLAT)
  end
  b.text = Text(b, "GameFontNormalSmall", "CENTER")
  b.text:SetAllPoints()
  b.text:SetText(label)
  local over, down
  local function Paint()
    if hasFace then
      b.face:SetAtlas(over and down and (FACE .. "-pressedhover-1") or down and (FACE .. "-pressed-1") or over and (FACE .. "-hover-1") or FACE)
    else
      local v = (over or down) and 0.26 or 0.16
      b.face:SetVertexColor(v, v + 0.03, v + 0.08)
    end
    if over then b.text:SetTextColor(1, 1, 1) else b.text:SetTextColor(1, 0.82, 0) end
  end
  b:SetScript("OnEnter", function() over = true; Paint() end)
  b:SetScript("OnLeave", function() over = nil; Paint() end)
  b:SetScript("OnMouseDown", function() down = true; Paint() end)
  b:SetScript("OnMouseUp", function() down = nil; Paint() end)
  Paint()
  return b
end

-- ---- reward icons ----
local function ItemIcon(id)
  local icon = C_Item and C_Item.GetItemIconByID and id and C_Item.GetItemIconByID(id)
  return icon or 134400
end

local function GetIconButton(parent)
  for _, b in ipairs(iconPool) do
    if not b.inUse then b.inUse = true; b:SetParent(parent); b:Show(); return b end
  end
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(ICON, ICON)
  b.rim = Solid(b, "BACKGROUND", BRONZE[1], BRONZE[2], BRONZE[3], 1)
  b.rim:SetAllPoints()
  b.tex = b:CreateTexture(nil, "ARTWORK")
  b.tex:SetPoint("TOPLEFT", 1, -1); b.tex:SetPoint("BOTTOMRIGHT", -1, 1)
  b.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  b:SetScript("OnEnter", function(self)
    self.rim:SetVertexColor(BRONZE_HOVER[1], BRONZE_HOVER[2], BRONZE_HOVER[3], 1)
    if not self.itemId then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink("item:" .. self.itemId)
    GameTooltip:AddLine("|cff8fc4ffCtrl+click: preview in the dressing room|r")
    GameTooltip:Show()
  end)
  -- Ctrl+click opens the game's dressing room on the item, same as for any item link.
  b:SetScript("OnClick", function(self)
    if not self.itemId or not IsControlKeyDown() then return end
    local dress = DressUpItemLink or DressUpLink
    if dress then pcall(dress, "item:" .. self.itemId) end
  end)
  b:SetScript("OnLeave", function(self)
    self.rim:SetVertexColor(BRONZE[1], BRONZE[2], BRONZE[3], 1)
    GameTooltip:Hide()
  end)
  b.inUse = true
  iconPool[#iconPool + 1] = b
  return b
end

local function ReleaseIcons(row)
  if row.icons then
    for _, b in ipairs(row.icons) do b.inUse = false; b:Hide(); b:ClearAllPoints() end
  end
  row.icons = {}
end

-- Lay icons out left to right, wrapping. Returns the number of lines used.
local function PlaceIcons(row, items, x0, y0, perLine)
  ReleaseIcons(row)
  local lines = 0
  for i, id in ipairs(items) do
    local b = GetIconButton(row)
    b.itemId = id
    b.tex:SetTexture(ItemIcon(id))
    local col, line = (i - 1) % perLine, math.floor((i - 1) / perLine)
    b:ClearAllPoints()
    b:SetPoint("TOPLEFT", row, "TOPLEFT", x0 + col * (ICON + 3), y0 - line * (ICON + 3))
    row.icons[#row.icons + 1] = b
    if line + 1 > lines then lines = line + 1 end
  end
  return lines
end

-- ---- hovering / clicking a quest row ----
local STATUS_TEXT = {
  done = { "Completed", 0.4, 0.8, 0.4 }, log = { "In your quest log", 0.56, 0.77, 1 },
  available = { "Available now", 0.4, 1, 0.4 }, locked = { "Locked", 1, 0.4, 0.4 },
}

local KIND_VERB = { kill = "Kill", object = "Use", item = "Collect", explore = "Go to" }

local function ZoneList(areas, max)
  local names = {}
  for i = 1, math.min(max, #areas) do names[#names + 1] = Data.ZoneName(areas[i]) end
  if #areas > max then names[#names + 1] = "+" .. (#areas - max) end
  return table.concat(names, ", ")
end

-- The blue "where" line of a chain row, or nil when nothing is known.
local function WhereText(e)
  local w = Data.Where(e.id)
  if #w.zones > 0 then
    local names = {}
    for _, area in ipairs(w.zones) do names[#names + 1] = Data.ZoneName(area) end
    return "|cff8fb4c8" .. table.concat(names, ", ") .. (w.extra > 0 and (" +" .. w.extra) or "") .. "|r"
  end
  local g = Data.Givers(e.id, "end")[1]
  local place = g and Data.Locate(g, e.id)
  if place then return "|cff8fb4c8Hand in: " .. Data.ZoneName(place.area, place.uiMap) .. "|r" end
  return nil
end

local function ShowQuestTip(row)
  local e = row.entry
  if not e then return end
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:AddLine(e.name, 1, 0.82, 0)
  local lv = e.level and e.level > 0 and ("Level " .. e.level) or nil
  if e.reqLevel and e.reqLevel > 0 then lv = (lv and (lv .. " · ") or "") .. "requires level " .. e.reqLevel end
  if lv then GameTooltip:AddLine(lv, 0.8, 0.8, 0.8) end
  local st = STATUS_TEXT[e.status]
  if st then GameTooltip:AddLine(st[1], st[2], st[3], st[4]) end
  for _, line in ipairs(e.unmet or {}) do GameTooltip:AddLine(line, 1, 0.5, 0.5, true) end
  if type(e.objective) == "table" and #e.objective > 0 then
    GameTooltip:AddLine(" ")
    for _, line in ipairs(e.objective) do GameTooltip:AddLine(line, 1, 1, 1, true) end
  end
  local where = Data.Where(e.id)
  if #where.objs > 0 then
    GameTooltip:AddLine(" ")
    for i, o in ipairs(where.objs) do
      if i > 6 then GameTooltip:AddLine("…", 0.7, 0.85, 1); break end
      local line = KIND_VERB[o.kind] .. " " .. o.name
      if o.kind == "item" and #o.from > 0 then
        line = line .. " (from " .. table.concat(o.from, ", ") .. (o.sources > #o.from and " and others" or "") .. ")"
      end
      if #o.areas > 0 then line = line .. " — " .. ZoneList(o.areas, 3) end
      GameTooltip:AddLine(line, 0.7, 0.85, 1, true)
    end
  end
  for _, which in ipairs({ "start", "end" }) do
    local givers = Data.Givers(e.id, which)
    for i = 1, math.min(2, #givers) do
      local g = givers[i]
      local place = Data.Locate(g, e.id)
      GameTooltip:AddLine((which == "start" and "Starts: " or "Ends: ") .. g.name .. (place and (" — " .. Data.PlaceText(place)) or ""), 0.9, 0.9, 0.6, true)
    end
  end
  GameTooltip:AddLine(" ")
  GameTooltip:AddLine("Left-click: open this quest's chain", 0.6, 0.6, 0.6)
  GameTooltip:AddLine("Right-click: waypoint to where the objectives are", 0.6, 0.6, 0.6, true)
  GameTooltip:AddLine("Shift+Right-click: to where it is handed in · Alt+Right-click: to where it starts", 0.6, 0.6, 0.6, true)
  GameTooltip:Show()
end


-- mode: nil = where the objectives are (the quest's giver when none is known), "end" = where it is handed in,
-- "start" = where it is picked up.
local function WaypointFor(row, mode)
  local e = row.entry
  if not e then return end
  if not mode then
    local place = Data.ObjectivePlace(e.id)
    if place then
      local o = place.objective
      local title = KIND_VERB[o.kind] .. " " .. o.name
      local ok, msg = Data.Waypoint(place, title)
      if ok then Say(("Waypoint set to %s, %s."):format(title, Data.PlaceText(place))) else Say(msg or "Could not set a waypoint.") end
      return
    end
  end
  local which = (mode == "end" or (not mode and e.status == "log")) and "end" or "start"
  local givers = Data.Givers(e.id, which)
  if #givers == 0 then Say("No " .. which .. " location is known for that quest."); return end
  for _, g in ipairs(givers) do
    local place = Data.Locate(g, e.id)
    if place then
      local ok, msg = Data.Waypoint(place, g.name)
      if ok then Say(("Waypoint set to %s, %s."):format(g.name, Data.PlaceText(place))) else Say(msg or "Could not set a waypoint.") end
      return
    end
  end
  Say("No map location is known for " .. givers[1].name .. ".")
end

-- ---- rows ----
local function GetRow(i)
  local row = rows[i]
  if row then return row end
  row = CreateFrame("Button", nil, content)
  row:SetWidth(CONTENT_W)
  row.hl = Solid(row, "BACKGROUND", BRONZE_HOVER[1], BRONZE_HOVER[2], BRONZE_HOVER[3], 0.22)
  row.hl:SetAllPoints()
  row.bar = Solid(row, "ARTWORK", BRONZE_LIT[1], BRONZE_LIT[2], BRONZE_LIT[3], 1)
  row.bar:SetPoint("TOPLEFT"); row.bar:SetPoint("BOTTOMLEFT"); row.bar:SetWidth(4)
  row.line = Solid(row, "BORDER", BRONZE_MUTED[1], BRONZE_MUTED[2], BRONZE_MUTED[3], 0.3)
  row.line:SetPoint("TOPLEFT"); row.line:SetPoint("TOPRIGHT"); row.line:SetHeight(1)
  row.num = Text(row, "GameFontNormalSmall", "RIGHT")
  row.num:SetPoint("TOPLEFT", 2, -6); row.num:SetWidth(18)
  row.status = row:CreateTexture(nil, "ARTWORK")
  row.status:SetTexture(STATUS_TEX)
  row.status:SetSize(16, 16)
  row.status:SetPoint("TOPLEFT", 24, -5)
  row.status:Hide()
  row.name = Text(row, "GameFontHighlight")
  row.name:SetPoint("TOPLEFT", 46, -5); row.name:SetWidth(CONTENT_W - 46 - 112)
  row.sub = Text(row, "GameFontNormalSmall")
  row.sub:SetPoint("TOPLEFT", 46, -21); row.sub:SetWidth(CONTENT_W - 46 - 8)
  row.sub:Hide()
  row.where = Text(row, "GameFontNormalSmall")
  row.where:SetPoint("TOPLEFT", 46, -21); row.where:SetWidth(CONTENT_W - 46 - 8)
  row.where:Hide()
  row.xp = Text(row, "GameFontNormalSmall", "RIGHT")
  row.xp:SetPoint("TOPRIGHT", -2, -6); row.xp:SetWidth(104)
  row.rep = Text(row, "GameFontDisableSmall")
  row.rep:SetWidth(CONTENT_W - 40)
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row:SetScript("OnClick", function(self, button)
    if not self.questId then return end
    if frame and frame.box then frame.box:ClearFocus() end
    if button == "RightButton" and self.entry then
      local mode = (IsShiftKeyDown and IsShiftKeyDown() and "end") or (IsAltKeyDown and IsAltKeyDown() and "start") or nil
      WaypointFor(self, mode)
    elseif not current and results then
      -- Picked from a list: remember it so Back returns there.
      local saved = { results = results, notice = notice }
      UI.Open(self.questId)
      backTo = saved
      Render()
    else
      UI.Open(self.questId, true) -- inside a chain the list (if any) stays one Back away
    end
  end)
  row:SetScript("OnEnter", ShowQuestTip)
  row:SetScript("OnLeave", function() GameTooltip:Hide() end)
  rows[i] = row
  return row
end

local function SumReputation(entries)
  local totals, order = {}, {}
  for _, e in ipairs(entries) do
    for _, pair in ipairs(e.rep) do
      local f, v = pair[1], pair[2]
      if f and v then
        if not totals[f] then totals[f] = 0; order[#order + 1] = f end
        totals[f] = totals[f] + v
      end
    end
  end
  local parts = {}
  for _, f in ipairs(order) do
    parts[#parts + 1] = Data.FactionName(f) .. " " .. (totals[f] >= 0 and "+" or "") .. totals[f]
  end
  return table.concat(parts, ", ")
end

-- A slim bronze scroll indicator (not draggable; the mouse wheel scrolls).
local function UpdateThumb()
  if not (frame and frame.thumb and scroll and content) then return end
  local ch, vh = content:GetHeight(), scroll:GetHeight()
  if not ch or not vh or vh <= 0 or ch <= vh + 1 then frame.thumb:Hide(); frame.track:Hide(); return end
  local th = math.max(24, vh * vh / ch)
  local frac = math.min(1, math.max(0, scroll:GetVerticalScroll() / (ch - vh)))
  frame.thumb:SetHeight(th)
  frame.thumb:ClearAllPoints()
  frame.thumb:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", 13, -(vh - th) * frac)
  frame.thumb:Show(); frame.track:Show()
end

local function PlaceRow(n, y, h)
  local row = GetRow(n)
  row:ClearAllPoints()
  row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
  row:SetHeight(h)
  row:Show()
  row.hl:Hide(); row.bar:Hide()
  row.questId, row.entry = nil, nil
  row.rep:Hide(); row.rep:SetWordWrap(false); row.rep:SetWidth(CONTENT_W - 40)
  row.xp:SetText(""); row.num:SetText(""); row.name:SetText("")
  row.status:Hide(); row.sub:SetText(""); row.sub:Hide(); row.where:SetText(""); row.where:Hide()
  -- Rows are reused: the summary and result rows move the name, so put it back for a chain row.
  row.name:ClearAllPoints(); row.name:SetPoint("TOPLEFT", 46, -5); row.name:SetWidth(CONTENT_W - 46 - 112)
  return row
end

function Render()
  if not frame then return end
  frame.back:SetShown(current ~= nil and backTo ~= nil)
  for _, row in ipairs(rows) do row:Hide(); ReleaseIcons(row) end

  if Data.state == "building" then
    frame.title:SetText("QuestThread")
    frame.sub:SetText(("Reading QuestieDB… %d%%"):format(math.floor(Data.progress * 100)))
    frame.stats:SetText("")
    content:SetHeight(1)
    return
  elseif Data.state == "error" then
    frame.sub:SetText("|cffff6060" .. tostring(Data.error) .. "|r")
    frame.stats:SetText("")
    return
  end
  if not current and results then
    frame.title:SetText("Search results")
    frame.sub:SetText((notice or "") .. " Click one to see its chain.")
    frame.stats:SetText("")
    local y = 0
    for i, hit in ipairs(results) do
      local row = PlaceRow(i, y, 24)
      row.questId = hit.id
      local lv = QuestDB.questLevel and QuestDB.questLevel(hit.id)
      row.name:ClearAllPoints(); row.name:SetPoint("TOPLEFT", 4, -5); row.name:SetWidth(CONTENT_W - 10)
      row.name:SetText((lv and lv > 0 and ("|cff9d9d9d[" .. lv .. "]|r ") or "") .. hit.name .. "  |cff808080#" .. hit.id .. "|r")
      y = y + 24
    end
    for i = #results + 1, #rows do rows[i]:Hide() end
    content:SetHeight(math.max(y, 1))
    scroll:SetVerticalScroll(0)
    UpdateThumb()
    return
  end
  if not current then
    frame.title:SetText("QuestThread")
    frame.sub:SetText(notice or "Enter a quest ID, link or name above, or open a quest in the quest log.")
    frame.stats:SetText("")
    content:SetHeight(1)
    return
  end

  local chain = Core.Chain(Data.index, current, Data.Info)
  if not chain then
    frame.title:SetText("Quest " .. current)
    frame.sub:SetText("That quest is not in QuestieDB.")
    frame.stats:SetText("")
    content:SetHeight(1)
    return
  end

  local level = UnitLevel and UnitLevel("player") or 0
  local function nameOf(id) return Data.Name(id) or ("Quest " .. id) end
  local maxed = GetMaxPlayerLevel and level >= GetMaxPlayerLevel()
  local all, left = {}, {}
  local totalXp, leftXp = 0, 0
  local itemSeen, itemList = {}, {}
  for _, layer in ipairs(chain.layers) do
    for _, e in ipairs(layer) do
      local exact = Data.ClientXp(e.id)
      e.xpExact = exact ~= nil
      e.xp = exact or (maxed and 0 or Core.ScaledXp(e.xpBase, e.xpLevel, level))
      local base = Data.Status(e.id)
      e.status, e.unmet = Core.StatusOf(e, base == "done", base == "log", Data.IsDone, level, nameOf)
      all[#all + 1] = e
      totalXp = totalXp + e.xp
      if e.status ~= "done" then left[#left + 1] = e; leftXp = leftXp + e.xp end
    end
  end
  local counted = showRemaining and left or all
  for _, e in ipairs(counted) do
    for _, id in ipairs(e.items) do
      if not itemSeen[id] then itemSeen[id] = true; itemList[#itemList + 1] = id end
    end
  end
  table.sort(itemList)

  local startName = Data.Name(current) or ("Quest " .. current)
  frame.title:SetText(startName)
  local part = chain.currentLayer > 0 and chain.parts > 0 and (" · step " .. chain.currentLayer .. " of " .. chain.parts) or ""
  frame.sub:SetText(("Quest %d%s%s"):format(current, part, chain.truncated and " · chain is large, showing the nearest quests" or ""))
  local xpTotal = showRemaining and leftXp or totalXp
  local quests = showRemaining and #left or #all
  frame.stats:SetText(("%s: %d quests · %s%s · %d reward items"):format(
    showRemaining and "Remaining" or "Whole chain", quests,
    maxed and "no XP at max level" or ("~" .. Num(xpTotal) .. " XP at level " .. level),
    "", #itemList))
  frame.toggle.text:SetText(showRemaining and "Show whole chain" or "Show remaining")

  local y, n, currentY = 0, 0, nil
  local function nextRow(h)
    n = n + 1
    local row = PlaceRow(n, y, h)
    y = y + h
    return row
  end

  -- Summary row: every distinct reward item.
  local iconLines = math.max(1, math.ceil(#itemList / 16))
  local summary = nextRow(#itemList == 0 and 42 or (22 + iconLines * (ICON + 3) + 8))
  summary.name:SetText("Item rewards across " .. (showRemaining and "the rest of the chain" or "the chain"))
  summary.name:SetWidth(CONTENT_W - 10)
  summary.name:ClearAllPoints(); summary.name:SetPoint("TOPLEFT", 4, -5)
  local repText = SumReputation(counted)
  if #itemList == 0 then
    summary.rep:SetText("No item rewards recorded in QuestieDB for these quests.")
    summary.rep:ClearAllPoints(); summary.rep:SetPoint("TOPLEFT", 4, -22); summary.rep:Show()
  else
    PlaceIcons(summary, itemList, 4, -22, 16)
  end
  if repText ~= "" then
    local text = "Reputation: " .. repText
    local row = nextRow(10 + math.min(5, math.ceil(#text / 62)) * 13)
    row.rep:SetWidth(CONTENT_W - 8)
    row.rep:SetWordWrap(true)
    row.rep:SetText(text)
    row.rep:ClearAllPoints(); row.rep:SetPoint("TOPLEFT", 4, -5); row.rep:Show()
  end

  for li, layer in ipairs(chain.layers) do
    for qi, e in ipairs(layer) do
      local hasItems = #e.items > 0
      local rowLines = math.max(1, math.ceil(#e.items / 14))
      local isCurrent = e.id == current
      if isCurrent then currentY = y end
      -- A second line only for your quest and for locked quests; the icon carries the rest.
      local sub = {}
      if isCurrent then sub[#sub + 1] = "|cffffd100You are here|r" end
      if #(e.unmet or {}) > 0 then sub[#sub + 1] = "|cffff8a8aNeeds: " .. table.concat(e.unmet, " · ") .. "|r" end
      local subH = #sub > 0 and 12 or 0
      -- Where it happens: the zones of its kills, objects and drops (or where it is handed in).
      local whereText = WhereText(e)
      local whereH = whereText and 12 or 0
      local row = nextRow(28 + subH + whereH + (hasItems and rowLines * (ICON + 3) or 0))
      row.questId = e.id
      row.entry = e
      row.num:SetText(qi == 1 and tostring(li) or "·")
      local cell = STATUS_CELL[e.status]
      if cell then
        row.status:SetTexCoord(cell * 0.25, (cell + 1) * 0.25, 0, 1)
        row.status:Show()
      end
      local color = isCurrent and "|cffffd100" or (e.status == "done" and "|cffa8c8ac" or (e.status == "locked" and "|cffb4b4b4" or "|cffffffff"))
      local lvl = e.level and e.level > 0 and ("|cff9d9d9d[" .. e.level .. "]|r ") or ""
      row.name:SetText(lvl .. color .. e.name .. "|r")
      if #sub > 0 then row.sub:SetText(table.concat(sub, "  ·  ")); row.sub:Show() end
      if whereText then
        row.where:ClearAllPoints(); row.where:SetPoint("TOPLEFT", 46, -(21 + subH))
        row.where:SetText(whereText); row.where:Show()
      end
      if e.xp > 0 then
        row.xp:SetText((e.xpExact and "" or "~") .. Num(e.xp) .. " XP")
      end
      if isCurrent then
        row.hl:SetVertexColor(BRONZE_HOVER[1], BRONZE_HOVER[2], BRONZE_HOVER[3], 0.22); row.hl:Show(); row.bar:Show()
      end
      if hasItems then PlaceIcons(row, e.items, 46, -(24 + subH + whereH), 14) end
    end
  end
  content:SetHeight(math.max(y, 1))

  if #chain.breadcrumbs > 0 then
    local names = {}
    for _, b in ipairs(chain.breadcrumbs) do names[#names + 1] = (Data.Name(b.id) or ("Quest " .. b.id)) .. " (#" .. b.id .. ")" end
    local row = nextRow(36)
    row.rep:SetText("Can also be reached through: " .. table.concat(names, ", "))
    row.rep:SetWidth(CONTENT_W - 10)
    row.rep:SetWordWrap(true)
    row.rep:ClearAllPoints(); row.rep:SetPoint("TOPLEFT", 4, -6); row.rep:Show()
    content:SetHeight(y)
  end
  local target = currentY and math.max(0, currentY - 70) or 0
  local function scrollNow()
    local max = math.max(0, content:GetHeight() - scroll:GetHeight())
    scroll:SetVerticalScroll(math.min(target, max))
  end
  scrollNow()
  UpdateThumb()
  if C_Timer and C_Timer.After then C_Timer.After(0, function() scrollNow(); UpdateThumb() end) end -- again once the scroll range has updated
end

local poller
local function WatchBuild()
  poller = poller or CreateFrame("Frame")
  poller:SetScript("OnUpdate", function(self)
    if Data.state == "building" then
      Render()
    else
      self:SetScript("OnUpdate", nil)
    end
  end)
end

local function Create()
  if frame then return frame end
  local f = CreateFrame("Frame", "QuestThreadFrame", UIParent, "BackdropTemplate")
  f:SetSize(WIDTH, HEIGHT)
  f:SetFrameStrata("FULLSCREEN_DIALOG") -- above a fullscreen world map
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self) self:StartMoving() end)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p, _, rp, x, y = self:GetPoint()
    DB().pos = { p, rp, x, y }
  end)
  f:SetScale(DB().scale or 1)
  local pos = DB().pos
  if pos then f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4]) else f:SetPoint("CENTER", UIParent, "CENTER", 0, 0) end

  Boxed(f, true)
  f:SetBackdropColor(0.05, 0.05, 0.05, 0.95)

  f.title = Text(f, "GameFontNormalLarge")
  f.title:SetPoint("TOPLEFT", 14, -12); f.title:SetWidth(WIDTH - 120)
  f.sub = Text(f, "GameFontHighlightSmall")
  f.sub:SetPoint("TOPLEFT", 14, -34); f.sub:SetWidth(WIDTH - 28)
  f.stats = Text(f, "GameFontNormalSmall")
  f.stats:SetPoint("TOPLEFT", 14, -52); f.stats:SetWidth(WIDTH - 28)

  local rule = Solid(f, "BORDER", BRONZE_MUTED[1], BRONZE_MUTED[2], BRONZE_MUTED[3], 0.6)
  rule:SetPoint("TOPLEFT", 14, -70); rule:SetPoint("TOPRIGHT", -14, -70); rule:SetHeight(1)

  local close = Button(f, "X", 22, 22)
  close:SetPoint("TOPRIGHT", -16, -14)
  close:SetScript("OnClick", function() f:Hide() end)

  local back = Button(f, "Back", 52, 22)
  back:SetPoint("RIGHT", close, "LEFT", -6, 0)
  back:SetScript("OnClick", function()
    if not backTo then return end
    current, results, notice = nil, backTo.results, backTo.notice
    backTo = nil
    Render()
  end)
  back:Hide()
  f.back = back

  local box = CreateFrame("EditBox", nil, f, "BackdropTemplate")
  box:SetSize(WIDTH - 28 - 130, 24)
  box:SetPoint("TOPLEFT", 14, -80)
  box:SetAutoFocus(false)
  box:SetFontObject("ChatFontNormal")
  box:SetTextInsets(8, 8, 0, 0)
  Boxed(box, true)
  box:SetBackdropColor(0, 0, 0, 0.5)
  box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  box:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
    UI.OpenText(self:GetText())
  end)
  f.box = box

  local hint = Text(box, "GameFontDisableSmall")
  hint:SetPoint("LEFT", 8, 0)
  hint:SetText("Quest ID, link or name")
  box:SetScript("OnTextChanged", function(self) hint:SetShown(self:GetText() == "") end)

  local toggle = Button(f, "Show remaining", 104, 22)
  toggle:SetPoint("LEFT", box, "RIGHT", 14, 0)
  toggle:SetScript("OnClick", function() showRemaining = not showRemaining; Render() end)
  f.toggle = toggle

  local well = CreateFrame("Frame", nil, f, "BackdropTemplate")
  well:SetPoint("TOPLEFT", 10, -114)
  well:SetPoint("BOTTOMRIGHT", -10, 10)
  Boxed(well, true)
  well:SetBackdropColor(0, 0, 0, 0.28)
  f.track = Solid(f, "ARTWORK", BRONZE_MUTED[1], BRONZE_MUTED[2], BRONZE_MUTED[3], 0.25)
  f.thumb = Solid(f, "OVERLAY", BRONZE[1], BRONZE[2], BRONZE[3], 1)
  f.track:SetWidth(4); f.thumb:SetWidth(4)

  scroll = CreateFrame("ScrollFrame", nil, f)
  scroll:SetPoint("TOPLEFT", well, "TOPLEFT", 8, -8)
  scroll:SetPoint("BOTTOMRIGHT", well, "BOTTOMRIGHT", -20, 8)
  f.track:SetPoint("TOPRIGHT", scroll, "TOPRIGHT", 13, 0)
  f.track:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 13, 0)
  scroll:SetScript("OnVerticalScroll", UpdateThumb)
  content = CreateFrame("Frame", nil, scroll)
  content:SetSize(CONTENT_W, 1)
  scroll:SetScrollChild(content)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(self, delta)
    local max = math.max(0, content:GetHeight() - self:GetHeight())
    local v = math.min(max, math.max(0, self:GetVerticalScroll() - delta * 48))
    self:SetVerticalScroll(v)
  end)

  -- Escape closes the window the way Blizzard's own windows close. The window never takes keyboard
  -- input itself: SetPropagateKeyboardInput is blocked in combat, so a window that listens for keys
  -- can swallow WASD there.
  if UISpecialFrames then table.insert(UISpecialFrames, "QuestThreadFrame") end
  -- Typing focus (the search box) also swallows WASD, so let go of it when combat starts.
  f:RegisterEvent("PLAYER_REGEN_DISABLED")
  f:SetScript("OnEvent", function() box:ClearFocus() end)
  -- A click anywhere else takes the typing focus off the search box, or WASD would type into it.
  f:SetScript("OnMouseDown", function() box:ClearFocus() end)
  f:Hide()
  frame = f
  return f
end

function UI.Open(questId, keepBack)
  Create()
  current = questId and tonumber(questId) or current
  notice, results = nil, nil
  if not keepBack then backTo = nil end
  frame:Show()
  frame:Raise()
  Data.Ensure(Render)
  if Data.state == "building" then WatchBuild() end
  Render()
end

-- Several quests at once (e.g. all the quests behind one map icon): one opens its chain, more show a pick list.
function UI.OpenIds(ids)
  if #ids <= 1 then return UI.Open(ids[1]) end
  Create()
  local hits = {}
  for _, id in ipairs(ids) do hits[#hits + 1] = { id = id, name = Data.Name(id) or ("Quest " .. id) } end
  table.sort(hits, function(a, b)
    if a.name ~= b.name then return a.name < b.name end
    return a.id < b.id
  end)
  current, results, notice, backTo = nil, hits, ("%d quests share that icon."):format(#ids), nil
  frame:Show()
  frame:Raise()
  Data.Ensure(Render)
  if Data.state == "building" then WatchBuild() end
  Render()
end

function UI.OpenText(text)
  Create()
  local id, msg, hits = Data.Resolve(text)
  backTo = nil
  if not id then
    current, notice, results = nil, msg or "Enter a quest ID, link or name.", hits
  else
    current, notice, results = id, nil, nil
    if msg then print("|cffffd100QuestThread:|r " .. msg) end
  end
  frame:Show()
  frame:Raise()
  Data.Ensure(Render)
  if Data.state == "building" then WatchBuild() end
  Render()
end

-- Window size: 0.6 to 1.6, remembered. Returns the value used.
function UI.SetScale(v)
  v = math.min(1.6, math.max(0.6, tonumber(v) or 1))
  DB().scale = v
  if frame then frame:SetScale(v) end
  return v
end

-- Back to the middle of the screen at normal size.
function UI.Reset()
  DB().pos, DB().scale = nil, nil
  if frame then
    frame:SetScale(1)
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  end
end

function UI.IsShown()
  return frame ~= nil and frame:IsShown()
end

function UI.Toggle()
  Create()
  if frame:IsShown() then frame:Hide() else UI.Open() end
end
