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

-- Look and colours follow FlareUI's windows: a dark panel, a thin bronze edge (FlareUI's own
-- Thin.tga border, MIT-licensed, copied here), Blizzard-yellow titles, and Blizzard's grey dropdown
-- face for buttons. The bronze values are FlareUI's.
local THIN = "Interface\\AddOns\\QuestChain\\Thin.tga"
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
local current, showRemaining, notice

local function DB()
  QuestChainDB = QuestChainDB or {}
  return QuestChainDB
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
    GameTooltip:Show()
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
  row.num:SetPoint("TOPLEFT", 0, -5); row.num:SetWidth(22)
  row.name = Text(row, "GameFontHighlight")
  row.name:SetPoint("TOPLEFT", 28, -5); row.name:SetWidth(CONTENT_W - 28 - 110)
  row.xp = Text(row, "GameFontNormalSmall", "RIGHT")
  row.xp:SetPoint("TOPRIGHT", -2, -6); row.xp:SetWidth(104)
  row.rep = Text(row, "GameFontDisableSmall")
  row.rep:SetWidth(CONTENT_W - 40)
  row:SetScript("OnClick", function(self) if self.questId then UI.Open(self.questId) end end)
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

local function Render()
  if not frame then return end
  for _, row in ipairs(rows) do row:Hide(); ReleaseIcons(row) end

  if Data.state == "building" then
    frame.title:SetText("QuestChain")
    frame.sub:SetText(("Reading QuestieDB… %d%%"):format(math.floor(Data.progress * 100)))
    frame.stats:SetText("")
    content:SetHeight(1)
    return
  elseif Data.state == "error" then
    frame.sub:SetText("|cffff6060" .. tostring(Data.error) .. "|r")
    frame.stats:SetText("")
    return
  end
  if not current then
    frame.title:SetText("QuestChain")
    frame.sub:SetText(notice or "Enter a quest ID, link or exact name above, or open a quest in the quest log.")
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
  local maxed = GetMaxPlayerLevel and level >= GetMaxPlayerLevel()
  local all, left = {}, {}
  local totalXp, leftXp = 0, 0
  local itemSeen, itemList = {}, {}
  for _, layer in ipairs(chain.layers) do
    for _, e in ipairs(layer) do
      local exact = Data.ClientXp(e.id)
      e.xpExact = exact ~= nil
      e.xp = exact or (maxed and 0 or Core.ScaledXp(e.xpBase, e.xpLevel, level))
      e.status = Data.Status(e.id)
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
    local row = GetRow(n)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
    row:SetHeight(h)
    row:Show()
    row.hl:Hide(); row.bar:Hide()
    row.questId = nil
    row.rep:Hide(); row.rep:SetWordWrap(false); row.rep:SetWidth(CONTENT_W - 40)
    row.xp:SetText(""); row.num:SetText("")
    y = y + h
    return row
  end

  -- Summary row: every distinct reward item.
  local iconLines = math.max(1, math.ceil(#itemList / 16))
  local summary = nextRow(#itemList == 0 and 42 or (22 + iconLines * (ICON + 3) + 8))
  summary.name:SetText("Item rewards across " .. (showRemaining and "the rest of the chain" or "the chain"))
  summary.name:SetWidth(CONTENT_W - 10)
  summary.name:SetPoint("TOPLEFT", 4, -5)
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
      local row = nextRow(hasItems and (28 + rowLines * (ICON + 3)) or 28)
      row.questId = e.id
      row.name:SetWidth(CONTENT_W - 28 - 110)
      row.name:ClearAllPoints(); row.name:SetPoint("TOPLEFT", 28, -5)
      row.num:SetText(qi == 1 and tostring(li) or "·")
      local color = e.status == "done" and "|cff66cc66" or (isCurrent and "|cffffd100" or "|cffffffff")
      local tag = e.status == "done" and "  |cff66cc66done|r" or (e.status == "log" and "  |cff8fc4ff in log|r" or "")
      if isCurrent then tag = tag .. "  |cffffd100<< YOU ARE HERE|r" end
      row.name:SetText(color .. e.name .. "|r" .. tag)
      if e.xp > 0 then
        row.xp:SetText((e.xpExact and "" or "~") .. Num(e.xp) .. " XP")
      end
      if isCurrent then
        row.hl:SetVertexColor(BRONZE_HOVER[1], BRONZE_HOVER[2], BRONZE_HOVER[3], 0.22); row.hl:Show(); row.bar:Show()
      end
      if hasItems then PlaceIcons(row, e.items, 28, -24, 14) end
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
  local f = CreateFrame("Frame", "QuestChainFrame", UIParent, "BackdropTemplate")
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
  local pos = DB().pos
  if pos then f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4]) else f:SetPoint("CENTER", UIParent, "CENTER", 0, 0) end

  Boxed(f, true)
  f:SetBackdropColor(0.05, 0.05, 0.05, 0.95)

  f.title = Text(f, "GameFontNormalLarge")
  f.title:SetPoint("TOPLEFT", 14, -12); f.title:SetWidth(WIDTH - 60)
  f.sub = Text(f, "GameFontHighlightSmall")
  f.sub:SetPoint("TOPLEFT", 14, -34); f.sub:SetWidth(WIDTH - 28)
  f.stats = Text(f, "GameFontNormalSmall")
  f.stats:SetPoint("TOPLEFT", 14, -52); f.stats:SetWidth(WIDTH - 28)

  local rule = Solid(f, "BORDER", BRONZE_MUTED[1], BRONZE_MUTED[2], BRONZE_MUTED[3], 0.6)
  rule:SetPoint("TOPLEFT", 14, -70); rule:SetPoint("TOPRIGHT", -14, -70); rule:SetHeight(1)

  local close = Button(f, "X", 22, 22)
  close:SetPoint("TOPRIGHT", -16, -14)
  close:SetScript("OnClick", function() f:Hide() end)

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
  hint:SetText("Quest ID, link or exact name")
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

  -- Escape closes the window. Keys the window does not use are passed straight on.
  f:EnableKeyboard(true)
  f:SetScript("OnKeyDown", function(self, key)
    if key == "ESCAPE" then
      self:SetPropagateKeyboardInput(false)
      self:Hide()
    else
      self:SetPropagateKeyboardInput(true)
    end
  end)
  f:Hide()
  frame = f
  return f
end

function UI.Open(questId)
  Create()
  current = questId and tonumber(questId) or current
  notice = nil
  frame:Show()
  frame:Raise()
  Data.Ensure(Render)
  if Data.state == "building" then WatchBuild() end
  Render()
end

function UI.OpenText(text)
  Create()
  local id, msg = Data.Resolve(text)
  if not id then
    current, notice = nil, msg or "Enter a quest ID, link or exact name."
  else
    current, notice = id, nil
    if msg then print("|cffffd100QuestChain:|r " .. msg) end
  end
  frame:Show()
  frame:Raise()
  Data.Ensure(Render)
  if Data.state == "building" then WatchBuild() end
  Render()
end

function UI.IsShown()
  return frame ~= nil and frame:IsShown()
end

function UI.Toggle()
  Create()
  if frame:IsShown() then frame:Hide() else UI.Open() end
end
