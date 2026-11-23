-- The chain window. Built from plain frames and textures (no Blizzard templates, no writes
-- to Blizzard globals, no StaticPopup).
local ADDON, ns = ...
local Core, Data = ns.Core, ns.Data
local Zones -- ns.Zones, looked up when first used (it loads after Data)
local UI = {}
ns.UI = UI

-- The window: a column WIDTH wide (header, search, list), and, while a quest's details are open, a pane PANE_W wide
-- on its right (the window grows to hold it).
local WIDTH, HEIGHT, PANE_W = 500, 640, 290
local CONTENT_W = WIDTH - 48
local TOGGLE_W = 192 -- the By type | By giver | Breadcrumbs tabs
local VIEW_W = 126 -- the List | Graph tabs of the chain view
local colW = WIDTH -- the column's width right now: WIDTH, wider in the graph view (see SetColumn)
local TOP_BODY = 164 -- where the list's well starts, under the header, search row and quest summary
local ICON = 22
local FLAT = "Interface\\Buttons\\WHITE8X8"
-- Step status icons: four 32x32 cells in one sheet (tools/make-status-icons.py).
local STATUS_TEX = "Interface\\AddOns\\QuestThread\\Status.tga"
-- Status.tga is eight 32-px cells side by side (five drawn). "again" is the green "!" of a repeatable quest you have
-- already completed once and can take again.
local STATUS_CELLS = 8
local STATUS_CELL = { done = 0, log = 1, available = 2, locked = 3, again = 4 }

-- The cell for a quest's status: the gold "!" of an available quest turns green for a repeatable done at least once.
local function StatusCell(status, id)
  if status == "available" and id and Data.RepeatableDone(id) then return STATUS_CELL.again end
  return STATUS_CELL[status]
end

local function SetCell(tex, cell)
  tex:SetTexCoord(cell / STATUS_CELLS, (cell + 1) / STATUS_CELLS, 0, 1)
end

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
local gscroll, gcontent, gcanvas -- the chain's graph view: a scroll frame, its content (sized by the zoom) and the canvas
local gnodes, glines, gedges = {}, {}, {} -- its quest boxes, line segments, and the edges (with their segments)
local graphZoom -- nil = fit the chain in the view
local MarkGraphSelection -- (set below) lights the box of the quest whose details are open
local rows, iconPool = {}, {}
local current, notice, results, backTo
local zoneMode, zonePick, zoneNotice, lastZoneShown -- the Zones tab
local wantHere -- the window was just opened: the Zones tab should show the area you are standing in
local zoneIndex -- the Zones tab shows the list of all zones (instead of one zone)
local logMode, logFilter, logPending, lastLogMode -- the My Log tab: your own quest log (and the text it is filtered by)
local indexJob -- the list's progress numbers being worked out a few zones per frame
local collapsed = {} -- [area:giver] or [area:section:name] = true for a giver / section folded shut
local PLUS_ICON, MINUS_ICON = "Interface\\Buttons\\UI-PlusButton-Up", "Interface\\Buttons\\UI-MinusButton-Up"
local Render -- defined below; the row click handlers need it

local function Say(msg) print("|cffffd100QuestThread:|r " .. msg) end

local function DB()
  QuestThreadDB = QuestThreadDB or {}
  return QuestThreadDB
end

-- What the Zones tab remembers: the area, the filter chip and whether it groups by giver.
local function ZS()
  DB().zone = DB().zone or {}
  local z = DB().zone
  if z.filter == nil then z.filter = "available" end
  return z
end

local function Num(n)
  local s = tostring(math.floor(n + 0.5))
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (out:gsub("^,", ""))
end

-- A quest level coloured the way the game colours it for your level; Core.Difficulty decides.
local function DifficultyKey(qLevel)
  local level = UnitLevel and UnitLevel("player") or 0
  local green = GetQuestGreenRange and GetQuestGreenRange() or 8
  return Core.Difficulty(qLevel, level, green)
end

-- "[52] " in its difficulty colour, or "" when the level is unknown.
local function LevelTag(qLevel)
  if type(qLevel) ~= "number" or qLevel <= 0 then return "" end
  local key = DifficultyKey(qLevel)
  local hex = key and Core.DIFFICULTY[key][4] or "|cff9d9d9d"
  return hex .. "[" .. qLevel .. "]|r "
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
    if over then b.text:SetTextColor(1, 1, 1)
    elseif b.dim then b.text:SetTextColor(0.62, 0.54, 0.38)
    else b.text:SetTextColor(1, 0.82, 0) end
  end
  b.paint = Paint
  b:SetScript("OnEnter", function() over = true; Paint() end)
  b:SetScript("OnLeave", function() over = nil; Paint() end)
  b:SetScript("OnMouseDown", function() down = true; Paint() end)
  b:SetScript("OnMouseUp", function() down = nil; Paint() end)
  Paint()
  return b
end

-- A tab or chip is lit (underlined, on a soft gold plate, in bright text) or dim.
local function Lit(b, on)
  on = on and true or false
  b.under:SetShown(on)
  if b.plate then b.plate:SetShown(on) end
  b.dim = not on
  b.paint()
end

-- ---- reward icons ----
local function ItemIcon(id)
  local icon = C_Item and C_Item.GetItemIconByID and id and C_Item.GetItemIconByID(id)
  return icon or 134400
end

-- The bread icon (Tough Hunk of Bread, item 4540) marks a breadcrumb quest. It goes into text as an
-- inline texture; "" when the client has no icon for it (the "Breadcrumb" word still says it).
local CRUMB_ITEM = 4540
local function CrumbIcon()
  local icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(CRUMB_ITEM)
  if not icon and GetItemIcon then icon = GetItemIcon(CRUMB_ITEM) end
  return icon and ("|T" .. icon .. ":14:14:0:-1|t ") or ""
end

-- The icon in front of a quest's name when it is a breadcrumb, else "".
local function Crumb(id)
  return Data.IsBreadcrumb(id) and CrumbIcon() or ""
end

-- How wide the words "You are here" are, for the click area over them.
local hereWidth
local function HereWidth()
  if not hereWidth then
    local m = UIParent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    m:SetText("You are here")
    local w = m:GetStringWidth()
    m:SetText("")
    hereWidth = (type(w) == "number" and w > 0 and w or 70) + 2
  end
  return hereWidth
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
  missed = { "Missed", 0.85, 0.65, 0.3 },
}

local KIND_VERB = { kill = "Kill", object = "Use", item = "Collect", explore = "Go to" }

local function ZoneList(areas, max)
  local names = {}
  for i = 1, math.min(max, #areas) do names[#names + 1] = Data.ZoneName(areas[i]) end
  if #areas > max then names[#names + 1] = "+" .. (#areas - max) end
  return table.concat(names, ", ")
end

local function ShowQuestTip(row)
  local e = row.entry
  if not e then
    -- A row of the search / pick list: just the name, the id and the link shortcut.
    if row.questId then
      GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
      GameTooltip:AddLine(Crumb(row.questId) .. (Data.Name(row.questId) or ("Quest " .. row.questId)), 1, 0.82, 0)
      if Data.IsBreadcrumb(row.questId) then GameTooltip:AddLine("Breadcrumb quest (optional)", 0.88, 0.65, 0.29) end
      GameTooltip:AddLine("Quest #" .. row.questId, 0.8, 0.8, 0.8)
      if IsShiftKeyDown and IsShiftKeyDown() then GameTooltip:AddLine("Ctrl+C: copy the Wowhead link", 0.6, 0.6, 0.6) end
      GameTooltip:Show()
    end
    return
  end
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:AddLine(Crumb(e.id) .. e.name, 1, 0.82, 0)
  local leadsTo = e.leadsTo or (Data.IsBreadcrumb(e.id) and Data.BreadcrumbTarget(e.id)) or nil
  if leadsTo then
    GameTooltip:AddLine("Breadcrumb quest: optional, leads into " .. (Data.Name(leadsTo) or ("quest " .. leadsTo)), 0.88, 0.65, 0.29)
  elseif Data.IsBreadcrumb(e.id) then
    GameTooltip:AddLine("Breadcrumb quest (optional)", 0.88, 0.65, 0.29)
  end
  local lv = e.level and e.level > 0 and ("Level " .. e.level) or nil
  if e.reqLevel and e.reqLevel > 0 then lv = (lv and (lv .. " - ") or "") .. "requires level " .. e.reqLevel end
  if lv then
    local key = DifficultyKey(e.level)
    local c = key and Core.DIFFICULTY[key]
    GameTooltip:AddLine(lv, c and c[1] or 0.8, c and c[2] or 0.8, c and c[3] or 0.8)
  end
  local st = STATUS_TEXT[e.status]
  if st then GameTooltip:AddLine(st[1], st[2], st[3], st[4]) end
  local rep = Data.RepeatInfo(e.id)
  if rep then
    if rep.done then
      GameTooltip:AddLine("Repeatable, completed " .. (rep.count > 1 and (rep.count .. " times") or (rep.count == 1 and "once" or "at least once")), 0.44, 0.88, 0.44)
    else
      GameTooltip:AddLine("Repeatable", 0.6, 0.63, 0.66)
    end
  end
  for _, line in ipairs(e.unmet or {}) do GameTooltip:AddLine(line, 1, 0.5, 0.5, true) end
  if e.grey then GameTooltip:AddLine(e.grey .. " (grey to you)", 0.62, 0.6, 0.55, true) end
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
  -- The shortcuts show only while Shift is held (the hover watcher below redraws the tip when Shift goes down or up).
  if IsShiftKeyDown and IsShiftKeyDown() then
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Left-click: open this quest's chain", 0.6, 0.6, 0.6, true)
    GameTooltip:AddLine("Ctrl+C: copy the Wowhead link", 0.6, 0.6, 0.6, true)
    GameTooltip:AddLine("Right-click: waypoint to where the objectives are", 0.6, 0.6, 0.6, true)
    GameTooltip:AddLine("Shift+Right-click: to where it is handed in", 0.6, 0.6, 0.6, true)
    GameTooltip:AddLine("Alt+Right-click: to where it starts", 0.6, 0.6, 0.6, true)
  end
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

-- ---- Wowhead link: hover a quest and press Ctrl+C ----
-- Like Wowhead Quick Link: a small box with the link already selected, closed by the copy itself.
-- The window never listens for keys. A separate frame does, and only while the mouse is over a quest
-- and you are out of combat, passing every key but Ctrl+C straight on (SetPropagateKeyboardInput
-- is blocked in combat, and a frame that kept listening there would swallow WASD).
local hoverRow, linkFrame, keys

local function InCombat() return InCombatLockdown and InCombatLockdown() end

local function HideLink()
  if linkFrame then linkFrame:Hide() end
end

local function ShowLink(id)
  if not linkFrame then
    local f = CreateFrame("Frame", "QuestThreadLinkFrame", UIParent, "BackdropTemplate")
    f:SetSize(404, 76)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    Boxed(f, true)
    f:SetBackdropColor(0.05, 0.05, 0.05, 0.97)
    f.title = Text(f, "GameFontNormal")
    f.title:SetPoint("TOPLEFT", 14, -10); f.title:SetWidth(376)
    f.hint = Text(f, "GameFontHighlightSmall")
    f.hint:SetPoint("TOPLEFT", 14, -28); f.hint:SetWidth(376)
    f.hint:SetText("Wowhead link. Ctrl+C to copy, Esc to close.")
    local box = CreateFrame("EditBox", nil, f, "BackdropTemplate")
    box:SetSize(376, 24)
    box:SetPoint("TOPLEFT", 14, -44)
    box:SetAutoFocus(false)
    box:SetFontObject("ChatFontNormal")
    box:SetTextInsets(8, 8, 0, 0)
    Boxed(box, true)
    box:SetBackdropColor(0, 0, 0, 0.5)
    local function Close() f:Hide() end
    box:SetScript("OnEscapePressed", Close)
    box:SetScript("OnEnterPressed", Close)
    box:SetScript("OnEditFocusLost", Close)
    -- Read-only: any typing puts the link back and selects it again.
    box:SetScript("OnTextChanged", function(self, byUser)
      if byUser and self:GetText() ~= f.url then self:SetText(f.url or ""); self:HighlightText() end
    end)
    -- The copy has happened by the time Ctrl+C is released, so the box can go.
    box:SetScript("OnKeyUp", function(_, key)
      if (key == "C" and IsControlKeyDown()) or ((key == "LCTRL" or key == "RCTRL") and IsKeyDown and IsKeyDown("C")) then Close() end
    end)
    f.box = box
    f:SetScript("OnHide", function() box:ClearFocus() end)
    f:RegisterEvent("PLAYER_REGEN_DISABLED")
    f:SetScript("OnEvent", Close)
    if UISpecialFrames then table.insert(UISpecialFrames, "QuestThreadLinkFrame") end
    f:Hide()
    linkFrame = f
  end
  local f = linkFrame
  f.url = Core.QuestUrl(id)
  f.title:SetText((Data.Name(id) or ("Quest " .. id)) .. "  |cff808080#" .. id .. "|r")
  f:ClearAllPoints()
  if frame and frame:IsShown() then f:SetPoint("BOTTOM", frame, "TOP", 0, 4) else f:SetPoint("CENTER", UIParent, "CENTER", 0, 200) end
  f.box:SetText(f.url)
  f:Show()
  f:Raise()
  f.box:SetFocus()
  f.box:HighlightText()
end

local function ListenForKeys(on)
  if on and not InCombat() then
    if not keys then
      keys = CreateFrame("Frame", "QuestThreadKeys", UIParent)
      keys:SetSize(1, 1)
      keys:SetPoint("CENTER")
      keys:SetScript("OnKeyDown", function(self, key)
        if InCombat() then self:EnableKeyboard(false); return end
        local row = hoverRow
        if key == "C" and IsControlKeyDown() and row and row:IsShown() and row.questId then
          self:SetPropagateKeyboardInput(false)
          ShowLink(row.questId)
        else
          self:SetPropagateKeyboardInput(true)
        end
      end)
      keys:RegisterEvent("PLAYER_REGEN_DISABLED")
      keys:RegisterEvent("PLAYER_REGEN_ENABLED")
      keys:SetScript("OnEvent", function(self, event)
        if event == "PLAYER_REGEN_DISABLED" then self:EnableKeyboard(false)
        elseif hoverRow and hoverRow:IsShown() then self:EnableKeyboard(true) end
      end)
    end
    keys:EnableKeyboard(true)
  elseif keys then
    keys:EnableKeyboard(false)
  end
end

local function Hover(row)
  hoverRow = row
  ListenForKeys(row.questId ~= nil)
end

local function Unhover(row)
  if hoverRow == row then hoverRow = nil; ListenForKeys(false) end
end

-- Pressing or letting go of Shift while the mouse rests on a quest redraws its tooltip (the shortcut lines are
-- Shift-only). It leaves alone a tooltip that is not the row's own (a link's, or "You are here").
local modWatch = CreateFrame("Frame")
modWatch:RegisterEvent("MODIFIER_STATE_CHANGED")
modWatch:SetScript("OnEvent", function(_, _, key)
  if key ~= "LSHIFT" and key ~= "RSHIFT" then return end
  local row = hoverRow
  if not (row and row.questId and row:IsShown() and GameTooltip:GetOwner() == row) then return end
  if row.here and row.here:IsShown() and row.here:IsMouseOver() then return end
  ShowQuestTip(row)
end)

-- ---- clickable places: a dungeon opens the Dungeon Journal, a zone opens the map on that area ----
-- The "where" line of a quest as segments, or nil when nothing is known. A segment is
-- { text, color, sep (shown after it), link = { kind = "dungeon", id, name } | { kind = "zone", area } }.
local function WhereSegments(e)
  local segs = {}
  local dungeon = Data.DungeonOf(e.id)
  if dungeon then
    segs[#segs + 1] = { text = "Dungeon: " .. dungeon, color = "|cffe0a64a", rgb = { 0.88, 0.65, 0.29 }, sep = "  ·  ",
      link = { kind = "dungeon", id = e.id, name = dungeon } }
  end
  local w = Data.Where(e.id)
  -- With a Dungeon Journal link, the dungeon's own area is left out of the zone links: it is the same place (the
  -- journal link is the better way in), and the game often has no such map to open anyway. It is the area named
  -- like the dungeon ("Zul'Farrak"), or one whose name holds it or is held by it ("Scarlet Monastery").
  local zones = w.zones
  if dungeon then
    zones = {}
    local dn = dungeon:lower()
    for _, area in ipairs(w.zones) do
      local an = Data.ZoneName(area):lower()
      local same = an == dn or (#an >= 5 and dn:find(an, 1, true) ~= nil) or (#dn >= 5 and an:find(dn, 1, true) ~= nil)
      if not same then zones[#zones + 1] = area end
    end
  end
  if #zones > 0 then
    for i, area in ipairs(zones) do
      segs[#segs + 1] = { text = Data.ZoneName(area), link = { kind = "zone", area = area }, sep = i < #zones and ", " or nil }
    end
    if w.extra > 0 then segs[#segs].sep = " +" .. w.extra end
  elseif dungeon and #w.zones > 0 then
    segs[1].sep = nil -- only the dungeon is left
  else
    local g = Data.Givers(e.id, "end")[1]
    local place = g and Data.Locate(g, e.id)
    if place then
      segs[#segs + 1] = { text = "Hand in: " .. Data.ZoneName(place.area, place.uiMap), link = { kind = "zone", area = place.area } }
    end
  end
  if #segs == 0 then return nil end
  return segs
end

local LINK_RGB = { 0.56, 0.71, 0.78 } -- the blue of a zone link (|cff8fb4c8)

local measureFS
local function TextWidth(text)
  if text == "" then return 0 end
  if not measureFS then measureFS = UIParent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall") end
  measureFS:SetText(text)
  local w = measureFS:GetStringWidth()
  measureFS:SetText("")
  return type(w) == "number" and w or 0
end

local function HintFor(link)
  if link.kind == "dungeon" then return "Click: open this quest in the Dungeon Journal (" .. link.name .. ")" end
  return "Click: open the map on " .. Data.ZoneName(link.area) .. " - Ctrl+click: the quests that start there"
end

local function Activate(link)
  if link.kind == "zone" and IsControlKeyDown and IsControlKeyDown() then return UI.ShowZones(link.area) end
  local ok, msg
  if link.kind == "dungeon" then ok, msg = Data.OpenInJournal(link.id) else ok, msg = Data.OpenMapAt(link.area) end
  if not ok and msg then Say(msg) end
end

-- An owner (a row, or a popup line) keeps its link buttons in owner.links; owner.linkParent is the frame they
-- sit on (the owner itself for a row) and owner.hoverRow the row whose Ctrl+C stays live while over a link.
local function NewLink(owner)
  local b = CreateFrame("Button", nil, owner.linkParent or owner)
  b:SetHeight(12)
  -- Clickable text is underlined, the way a hyperlink is (a font cannot underline, so it is a thin line).
  b.line = Solid(b, "OVERLAY", 0.56, 0.71, 0.78, 0.9)
  b.line:SetPoint("BOTTOMLEFT", 0, 1); b.line:SetPoint("BOTTOMRIGHT", 0, 1); b.line:SetHeight(1)
  b:SetScript("OnEnter", function(self)
    self.line:SetVertexColor(1, 1, 1, 1)
    self.fs:SetText(self.build(self.segIndex)) -- lit up
    if owner.hoverRow then Hover(owner.hoverRow) end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(HintFor(self.link), 0.56, 0.77, 1, true)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function(self)
    local c = self.rgb or LINK_RGB
    self.line:SetVertexColor(c[1], c[2], c[3], 0.9)
    self.fs:SetText(self.build())
    if owner.hoverRow then Unhover(owner.hoverRow) end
    GameTooltip:Hide()
  end)
  b:SetScript("OnClick", function(self)
    if frame and frame.box then frame.box:ClearFocus() end
    Activate(self.link)
  end)
  owner.links[#owner.links + 1] = b
  return b
end

local function HideLinks(owner)
  for _, b in ipairs(owner.links or {}) do b:Hide() end
end

-- Shows the segments as one line in `fs` and lays a button over each one that has a link (no wider than maxW).
local function PlaceSegments(fs, owner, segs, maxW)
  owner.links = owner.links or {}
  HideLinks(owner)
  local function build(hot)
    local parts = {}
    for i, s in ipairs(segs) do
      parts[#parts + 1] = (hot == i and "|cffffffff" or (s.color or "|cff8fb4c8")) .. s.text .. "|r" .. (s.sep or "")
    end
    return table.concat(parts)
  end
  fs:SetText(build()); fs:Show()
  local before, n = "", 0
  for i, s in ipairs(segs) do
    local x = TextWidth(before)
    if s.link and x < maxW then
      n = n + 1
      local b = owner.links[n] or NewLink(owner)
      b.link, b.segIndex, b.fs, b.build = s.link, i, fs, build
      b.rgb = s.rgb or LINK_RGB
      b.line:SetVertexColor(b.rgb[1], b.rgb[2], b.rgb[3], 0.9)
      b:ClearAllPoints(); b:SetPoint("TOPLEFT", fs, "TOPLEFT", x, 0)
      b:SetSize(math.min(TextWidth(s.text), maxW - x), 12)
      b:Show()
    end
    before = before .. s.text .. (s.sep or "")
  end
end

-- ---- rows ----
local function GetRow(i)
  local row = rows[i]
  if row then return row end
  row = CreateFrame("Button", nil, content)
  row:SetWidth(CONTENT_W)
  row.hover = Solid(row, "BACKGROUND", 0.13, 0.095, 0.055, 0.85) -- FlareUI's hover plate
  row.hover:SetAllPoints()
  row.hover:Hide()
  row.hl = Solid(row, "BACKGROUND", BRONZE_HOVER[1], BRONZE_HOVER[2], BRONZE_HOVER[3], 0.22)
  row.hl:SetAllPoints()
  row.bar = Solid(row, "ARTWORK", BRONZE_LIT[1], BRONZE_LIT[2], BRONZE_LIT[3], 1)
  row.bar:SetPoint("TOPLEFT"); row.bar:SetPoint("BOTTOMLEFT"); row.bar:SetWidth(4)
  row.line = Solid(row, "BORDER", BRONZE_MUTED[1], BRONZE_MUTED[2], BRONZE_MUTED[3], 0.3)
  row.line:SetPoint("TOPLEFT"); row.line:SetPoint("TOPRIGHT"); row.line:SetHeight(1)
  row.num = Text(row, "GameFontNormalSmall", "RIGHT")
  row.num:SetPoint("TOPLEFT", 2, -6); row.num:SetWidth(18)
  -- an optional side quest of a chain: a rail down the left that runs through the side quests of a group, an elbow from
  -- it to a round badge with the quest's letter
  row.rail = Solid(row, "ARTWORK", BRONZE_MUTED[1], BRONZE_MUTED[2], BRONZE_MUTED[3], 0.85)
  row.rail:SetPoint("TOPLEFT", 22, 0); row.rail:SetWidth(2)
  row.rail:Hide()
  row.stub = Solid(row, "ARTWORK", BRONZE_MUTED[1], BRONZE_MUTED[2], BRONZE_MUTED[3], 0.85)
  row.stub:SetPoint("TOPLEFT", 22, -14); row.stub:SetSize(12, 2)
  row.stub:Hide()
  row.badge = row:CreateTexture(nil, "ARTWORK")
  row.badge:SetTexture(STATUS_TEX)
  row.badge:SetSize(18, 18)
  row.badge:SetPoint("TOPLEFT", 34, -5)
  row.badge:SetTexCoord(5 / STATUS_CELLS, 6 / STATUS_CELLS, 0, 1)
  row.badge:Hide()
  -- a zone row in the list of zones: a thin progress bar at its right
  row.meter = Solid(row, "ARTWORK", BRONZE_MUTED[1], BRONZE_MUTED[2], BRONZE_MUTED[3], 0.3)
  row.meter:SetSize(90, 6)
  row.meter:SetPoint("RIGHT", row, "RIGHT", -10, 0)
  row.meter:Hide()
  row.meterFill = Solid(row, "OVERLAY", 0.85, 0.65, 0.15, 1)
  row.meterFill:SetPoint("LEFT", row.meter, "LEFT", 0, 0)
  row.meterFill:SetHeight(6)
  row.meterFill:Hide()
  -- a section header's fold icon: minus while it is open, plus while it is folded shut
  row.fold = row:CreateTexture(nil, "ARTWORK")
  row.fold:SetSize(14, 14)
  row.fold:SetPoint("TOPLEFT", 8, -6)
  row.fold:Hide()
  row.status = row:CreateTexture(nil, "ARTWORK")
  row.status:SetTexture(STATUS_TEX)
  row.status:SetSize(16, 16)
  row.status:SetPoint("TOPLEFT", 24, -5)
  row.status:Hide()
  row.name = Text(row, "GameFontHighlight")
  row.name:SetPoint("TOPLEFT", 46, -5); row.name:SetWidth(CONTENT_W - 46 - 84)
  row.sub = Text(row, "GameFontNormalSmall")
  row.sub:SetPoint("TOPLEFT", 46, -21); row.sub:SetWidth(CONTENT_W - 46 - 8)
  row.sub:Hide()
  row.where = Text(row, "GameFontNormalSmall")
  row.where:SetPoint("TOPLEFT", 46, -21); row.where:SetWidth(CONTENT_W - 46 - 8)
  row.where:Hide()
  -- "You are here" is a button laid over the text: it opens the quest log on this quest.
  row.hoverRow = row
  row.here = CreateFrame("Button", nil, row)
  row.here:SetPoint("TOPLEFT", 46, -21)
  row.here:SetHeight(12)
  row.here:Hide()
  row.here.line = Solid(row.here, "OVERLAY", 1, 0.82, 0, 0.9)
  row.here.line:SetPoint("BOTTOMLEFT", 0, 1); row.here.line:SetPoint("BOTTOMRIGHT", 0, 1); row.here.line:SetHeight(1)
  row.here:SetScript("OnEnter", function()
    row.here.line:SetVertexColor(1, 1, 1, 1)
    if row.subHot then row.sub:SetText(row.subHot) end
    Hover(row); ShowQuestTip(row)
    GameTooltip:AddLine("Click \"You are here\": show this quest in your quest log", 0.56, 0.77, 1, true)
    GameTooltip:Show()
  end)
  row.here:SetScript("OnLeave", function()
    row.here.line:SetVertexColor(1, 0.82, 0, 0.9)
    if row.subNormal then row.sub:SetText(row.subNormal) end
    Unhover(row); GameTooltip:Hide()
  end)
  row.here:SetScript("OnClick", function()
    if not row.questId then return end
    if frame and frame.box then frame.box:ClearFocus() end
    local ok, msg = Data.OpenInQuestLog(row.questId)
    if not ok and msg then Say(msg) end
  end)
  -- Zones tab: a chain-link icon at the right of a row whose quest is part of a chain. It opens that chain.
  row.chain = CreateFrame("Button", nil, row)
  row.chain:SetSize(18, 18)
  row.chain:SetPoint("RIGHT", row, "RIGHT", -6, 0)
  row.chain.tex = row.chain:CreateTexture(nil, "ARTWORK")
  row.chain.tex:SetTexture("Interface\\AddOns\\QuestThread\\Chain.tga")
  row.chain.tex:SetAllPoints()
  row.chain.tex:SetVertexColor(0.85, 0.75, 0.55, 0.85)
  row.chain:Hide()
  row.chain:SetScript("OnEnter", function(self)
    self.tex:SetVertexColor(1, 1, 1, 1)
    row.hover:Show()
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Open this quest's chain", 1, 0.82, 0)
    GameTooltip:Show()
  end)
  row.chain:SetScript("OnLeave", function(self)
    self.tex:SetVertexColor(0.85, 0.75, 0.55, 0.85)
    row.hover:Hide()
    GameTooltip:Hide()
  end)
  row.chain:SetScript("OnClick", function()
    if row.questId then UI.Open(row.questId, false, true) end
  end)
  row.xp = Text(row, "GameFontNormalSmall", "RIGHT")
  row.xp:SetPoint("TOPRIGHT", -2, -6); row.xp:SetWidth(104)
  -- The "Breadcrumb" tag has its own slot at the right edge, so the icon, level and name sit exactly where
  -- they do on any other row.
  row.tag = Text(row, "GameFontNormalSmall", "RIGHT")
  row.tag:SetPoint("TOPRIGHT", -2, -6); row.tag:SetWidth(72)
  row.tag:Hide()
  row.rep = Text(row, "GameFontDisableSmall")
  row.rep:SetWidth(CONTENT_W - 40)
  row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  row:SetScript("OnClick", function(self, button)
    if self.onClick then return self.onClick(self, button) end
    if not self.questId then return end
    if frame and frame.box then frame.box:ClearFocus() end
    if button == "RightButton" and self.entry then
      local mode = (IsShiftKeyDown and IsShiftKeyDown() and "end") or (IsAltKeyDown and IsAltKeyDown() and "start") or nil
      WaypointFor(self, mode)
    elseif not current and results then
      -- Picked from a list: remember it so Back returns there.
      local saved = { results = results, notice = notice }
      UI.Open(self.questId, false, true)
      backTo = saved
      Render()
    else
      UI.Open(self.questId, true, true) -- inside a chain the list (if any) stays one Back away
    end
  end)
  row:SetScript("OnEnter", function(self)
    if self.questId or self.onClick then self.hover:Show() end
    Hover(self); ShowQuestTip(self)
  end)
  row:SetScript("OnLeave", function(self) self.hover:Hide(); Unhover(self); GameTooltip:Hide() end)
  rows[i] = row
  return row
end

local function SumReputation(entries)
  local totals, order = {}, {}
  for _, e in ipairs(entries) do
    for _, pair in ipairs(e.rep) do
      local f, v = type(pair) == "table" and pair[1], type(pair) == "table" and pair[2]
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

-- The slim bronze scroll bar: drag the thumb, click the track to jump there, or use the mouse wheel. It is a frame
-- of its own, so a click on it never reaches the window behind (which would start moving the window).
local function UpdateThumb()
  if not (frame and frame.bar and scroll and content) then return end
  local th, top = Core.Thumb(content:GetHeight(), scroll:GetHeight(), scroll:GetVerticalScroll())
  if not th then frame.bar:Hide(); return end
  frame.thumb:SetHeight(th)
  frame.thumb:ClearAllPoints()
  frame.thumb:SetPoint("TOP", frame.bar, "TOP", 0, -top)
  frame.bar:Show()
end

local function PlaceRow(n, y, h)
  local row = GetRow(n)
  row:ClearAllPoints()
  row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
  row:SetHeight(h)
  row:Show()
  row.hl:Hide(); row.bar:Hide(); row.hover:Hide()
  row.questId, row.entry = nil, nil
  row.rep:Hide(); row.rep:SetWordWrap(false); row.rep:SetWidth(CONTENT_W - 40)
  row.xp:SetText(""); row.num:SetText(""); row.name:SetText("")
  row.here:Hide(); row.subNormal, row.subHot = nil, nil; HideLinks(row)
  row.onClick = nil; row.status:SetDesaturated(false)
  row.tag:SetText(""); row.tag:Hide(); row.tag:ClearAllPoints(); row.tag:SetPoint("TOPRIGHT", -2, -6)
  row.status:Hide(); row.sub:SetText(""); row.sub:Hide(); row.where:SetText(""); row.where:Hide()
  row.chain:Hide(); row.fold:Hide(); row.meter:Hide(); row.meterFill:Hide(); row.rail:Hide(); row.stub:Hide(); row.badge:Hide()
  row.num:ClearAllPoints(); row.num:SetPoint("TOPLEFT", 2, -6); row.num:SetWidth(18); row.num:SetJustifyH("RIGHT")
  row.here:ClearAllPoints(); row.here:SetPoint("TOPLEFT", 46, -21)
  -- Rows are reused: the summary and result rows move the name, and a lead-in row indents everything.
  row.name:ClearAllPoints(); row.name:SetPoint("TOPLEFT", 46, -5); row.name:SetWidth(CONTENT_W - 46 - 84)
  row.status:ClearAllPoints(); row.status:SetPoint("TOPLEFT", 24, -5)
  row.sub:ClearAllPoints(); row.sub:SetPoint("TOPLEFT", 46, -21)
  row.where:ClearAllPoints(); row.where:SetPoint("TOPLEFT", 46, -21)
  row.bar:SetVertexColor(BRONZE_LIT[1], BRONZE_LIT[2], BRONZE_LIT[3], 1)
  return row
end

-- The thin bar under the title: how much of what is shown is done (green), in your log (blue) and available (gold).
-- No arguments hides it.
local function SetProgress(done, log, avail, total)
  if not (frame and frame.prog) then return end
  local segs = { { frame.progDone, done }, { frame.progLog, log }, { frame.progAvail, avail } }
  if not total or total <= 0 then
    frame.prog:Hide()
    for _, s in ipairs(segs) do s[1]:Hide() end
    return
  end
  frame.prog:Show()
  local w, x = colW - 28, 0
  for _, s in ipairs(segs) do
    local px = math.floor(w * (s[2] or 0) / total + 0.5)
    if px > 0 then
      s[1]:ClearAllPoints(); s[1]:SetPoint("TOPLEFT", frame, "TOPLEFT", 14 + x, -152); s[1]:SetSize(px, 4); s[1]:Show()
      x = x + px
    else
      s[1]:Hide()
    end
  end
end

-- ---- the objectives popup, beside the window ----
-- Opens when you click a quest and follows the quest you clicked. QuestieDB says which creatures, objects
-- and items a quest needs and where they are, but not how many: the counts come from your quest log
-- (Data.LiveObjectives), so they show once the quest is in it.
local POP_W = PANE_W - 8
local popup, popupFor

local function Head(text) return "|cffffd100" .. text .. "|r" end

-- The popup is a column of pieces: blocks of text, and one hoverable row per item to collect (its icon,
-- name and where it drops; hovering shows the item's own game tooltip).
local function ObjectivePieces(id)
  local pieces, buf = {}, {}
  local function add(s) buf[#buf + 1] = s end
  local function flush()
    if #buf > 0 then pieces[#pieces + 1] = { text = table.concat(buf, "\n") }; buf = {} end
  end
  local info = Data.Info(id)
  if type(info.objective) == "table" and #info.objective > 0 then
    add(Head("What to do"))
    for _, line in ipairs(info.objective) do add("|cffffffff" .. line .. "|r") end
    add(" ")
  end
  local places = WhereSegments({ id = id })
  if places then
    add(Head("Where"))
    flush()
    local dungeonLine, zoneLine = {}, {}
    for _, s in ipairs(places) do
      local copy = { text = s.text, color = s.color, link = s.link, sep = s.link.kind == "zone" and s.sep or nil }
      local line = s.link.kind == "dungeon" and dungeonLine or zoneLine
      line[#line + 1] = copy
    end
    if #dungeonLine > 0 then pieces[#pieces + 1] = { links = dungeonLine } end
    if #zoneLine > 0 then pieces[#pieces + 1] = { links = zoneLine } end
    add(" ")
  end
  local live = Data.LiveObjectives(id)
  if #live > 0 then
    add(Head("Your progress"))
    for _, o in ipairs(live) do add((o.done and "|cff66e066" or "|cffffffff") .. o.text .. "|r") end
    add(" ")
  end
  local where = Data.Where(id)
  if #where.objs > 0 then
    add(Head("Targets"))
    for i, o in ipairs(where.objs) do
      if i > 8 then add("|cff9aa0a8…and " .. (#where.objs - 8) .. " more|r"); break end
      local detail = {}
      if o.kind == "item" and #o.from > 0 then
        detail[#detail + 1] = "from " .. table.concat(o.from, ", ") .. (o.sources > #o.from and " and others" or "")
      end
      if #o.areas > 0 then detail[#detail + 1] = ZoneList(o.areas, 3) end
      local detailText = #detail > 0 and ("|cff8fb4c8" .. table.concat(detail, " · ") .. "|r") or nil
      local line = "|cffffffff" .. KIND_VERB[o.kind] .. " " .. o.name .. "|r"
      if o.kind == "item" and o.id then
        flush()
        pieces[#pieces + 1] = { item = o.id, name = line, detail = detailText }
      else
        add(line)
        if detailText then add("   " .. detailText) end
      end
    end
    if #live == 0 then add("|cff9aa0a8How many you need shows here once the quest is in your quest log.|r") end
    add(" ")
  end
  -- Rewards: XP (the client's exact figure when the quest is in your log), reputation, and the items.
  local level = UnitLevel and UnitLevel("player") or 0
  local exact = Data.ClientXp(id)
  local maxed = GetMaxPlayerLevel and level >= GetMaxPlayerLevel()
  local xp = exact or (maxed and 0 or Core.ScaledXp(info.xpBase, info.xpLevel, level))
  local rewardItems = Data.index.rewards[id] or {}
  local reps = {}
  for _, pair in ipairs(info.rep or {}) do
    if type(pair) == "table" and pair[1] and pair[2] then reps[#reps + 1] = "|cffffffff" .. Data.FactionName(pair[1]) .. " " .. (pair[2] >= 0 and "+" or "") .. pair[2] .. "|r" end
  end
  if xp > 0 or #reps > 0 or #rewardItems > 0 then
    add(Head("Rewards"))
    if xp > 0 then add("|cffffffff" .. (exact and "" or "~") .. Num(xp) .. " XP|r") end
    for _, line in ipairs(reps) do add(line) end
    flush()
    for _, itemId in ipairs(rewardItems) do
      pieces[#pieces + 1] = { item = itemId, name = (Data.ItemColor(itemId) or "|cffffffff") .. Data.ItemName(itemId) .. "|r" }
    end
    add(" ")
  end
  for _, which in ipairs({ "start", "end" }) do
    local g = Data.Givers(id, which)[1]
    if g then
      local place = Data.Locate(g, id)
      add(Head(which == "start" and "Starts" or "Hand in") .. "  |cffffffff" .. g.name .. "|r" ..
        (place and ("\n   |cff8fb4c8" .. Data.PlaceText(place) .. "|r") or ""))
    end
  end
  while buf[#buf] == " " do buf[#buf] = nil end
  flush()
  if #pieces == 0 then pieces[1] = { text = "|cff9aa0a8QuestieDB has no objective details for this quest.|r" } end
  return pieces
end

-- The window is WIDTH wide, plus PANE_W while the details pane is open. If that would run off the right edge of the
-- screen, the window slides left by what hangs over.
local function FitWidth()
  if not frame then return end
  local open = popup and popup:IsShown()
  frame:SetWidth(colW + (open and PANE_W or 0))
  if popup then
    popup:ClearAllPoints()
    popup:SetPoint("TOPLEFT", frame, "TOPLEFT", colW - 2, -58)
    popup:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, 10)
  end
  local right, uiRight = frame:GetRight(), UIParent:GetRight()
  local s, us = frame:GetEffectiveScale(), UIParent:GetEffectiveScale()
  local left, top = frame:GetLeft(), frame:GetTop()
  if type(right) == "number" and type(uiRight) == "number" and s and us and type(left) == "number" and type(top) == "number" then
    local over = (right * s - uiRight * us) / s
    if over > 0 then
      frame:ClearAllPoints()
      frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left - over, top)
    end
  end
end

-- The column (header, search, list or graph) is WIDTH wide, or wider for the graph view. Everything that depends on its
-- width follows.
local function SetColumn(w)
  if not frame then return end
  colW = w
  frame.well:SetWidth(w - 20)
  frame.prog:SetWidth(w - 28)
  frame.title:SetWidth(w - 28); frame.sub:SetWidth(w - 28); frame.stats:SetWidth(w - 28)
  frame.toggle:ClearAllPoints(); frame.toggle:SetPoint("TOPLEFT", frame, "TOPLEFT", w - 14 - TOGGLE_W, -60)
  frame.viewToggle:ClearAllPoints(); frame.viewToggle:SetPoint("TOPLEFT", frame, "TOPLEFT", w - 14 - VIEW_W, -60)
  FitWidth()
end

-- Half the screen's width, in the window's own units (the graph view never grows beyond it).
local function HalfScreen()
  local uw, us = UIParent:GetWidth(), UIParent:GetEffectiveScale()
  local fs = frame and frame:GetEffectiveScale()
  if type(uw) == "number" and type(us) == "number" and type(fs) == "number" and fs > 0 then return uw * us / 2 / fs end
  return 960
end

-- The pane's scroll position, drawn as a slim thumb on its right edge (the wheel scrolls it).
local function PaneThumb()
  if not (popup and popup.scroll and popup.thumb) then return end
  local th, top = Core.Thumb(popup.body:GetHeight(), popup.scroll:GetHeight(), popup.scroll:GetVerticalScroll())
  if not th then popup.thumb:Hide(); return end
  popup.thumb:SetHeight(th)
  popup.thumb:ClearAllPoints()
  popup.thumb:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -7, -54 - top)
  popup.thumb:Show()
end

local function BuildPopup()
  popup = CreateFrame("Frame", "QuestThreadObjectives", frame, "BackdropTemplate")
  popup:SetPoint("TOPLEFT", frame, "TOPLEFT", WIDTH - 2, -58)
  popup:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, 10)
  popup:EnableMouse(true)
  Boxed(popup, true)
  popup:SetBackdropColor(0.02, 0.015, 0.01, 0.55)
  popup.title = Text(popup, "GameFontNormalLarge")
  popup.title:SetPoint("TOPLEFT", 14, -12); popup.title:SetWidth(POP_W - 100)
  popup.sub = Text(popup, "GameFontHighlightSmall")
  popup.sub:SetPoint("TOPLEFT", 14, -32); popup.sub:SetWidth(POP_W - 28)
  local rule = Solid(popup, "BORDER", BRONZE_MUTED[1], BRONZE_MUTED[2], BRONZE_MUTED[3], 0.6)
  rule:SetPoint("TOPLEFT", 14, -50); rule:SetPoint("TOPRIGHT", -14, -50); rule:SetHeight(1)
  popup.textRows, popup.itemRows, popup.linkRows = {}, {}, {}
  -- the details scroll inside the pane
  popup.scroll = CreateFrame("ScrollFrame", nil, popup)
  popup.scroll:SetPoint("TOPLEFT", 8, -54); popup.scroll:SetPoint("BOTTOMRIGHT", -14, 8)
  popup.body = CreateFrame("Frame", nil, popup.scroll)
  popup.body:SetSize(POP_W - 26, 1)
  popup.scroll:SetScrollChild(popup.body)
  popup.scroll:EnableMouseWheel(true)
  popup.scroll:SetScript("OnMouseWheel", function(self, delta)
    local max = math.max(0, popup.body:GetHeight() - self:GetHeight())
    self:SetVerticalScroll(math.min(max, math.max(0, self:GetVerticalScroll() - delta * 40)))
  end)
  popup.scroll:SetScript("OnVerticalScroll", PaneThumb)
  popup.thumb = Solid(popup, "OVERLAY", BRONZE[1], BRONZE[2], BRONZE[3], 0.9)
  popup.thumb:SetWidth(4)
  popup.thumb:Hide()
  local close = Button(popup, "X", 24, 24)
  close:SetPoint("TOPRIGHT", -10, -10)
  close:SetScript("OnClick", function() popupFor = nil; popup:Hide(); FitWidth(); if MarkGraphSelection then MarkGraphSelection() end end)
  popup.close = close
  popup:Hide()
end

local function TextPiece(i)
  local fs = popup.textRows[i]
  if not fs then
    fs = Text(popup.body, "GameFontHighlightSmall")
    fs:SetWordWrap(true)
    fs:SetJustifyV("TOP")
    fs:SetWidth(POP_W - 30)
    popup.textRows[i] = fs
  end
  return fs
end

-- One item to collect: its icon, its line, and the item's own tooltip on hover.
local function ItemPiece(i)
  local b = popup.itemRows[i]
  if b then return b end
  local w = POP_W - 30
  b = CreateFrame("Button", nil, popup.body)
  b:SetWidth(w)
  b.hl = Solid(b, "BACKGROUND", BRONZE_HOVER[1], BRONZE_HOVER[2], BRONZE_HOVER[3], 0.22)
  b.hl:SetAllPoints(); b.hl:Hide()
  b.rim = Solid(b, "BORDER", BRONZE[1], BRONZE[2], BRONZE[3], 1)
  b.rim:SetSize(ICON, ICON); b.rim:SetPoint("TOPLEFT", 0, 0)
  b.tex = b:CreateTexture(nil, "ARTWORK")
  b.tex:SetSize(ICON - 2, ICON - 2); b.tex:SetPoint("TOPLEFT", 1, -1)
  b.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  b.name = Text(b, "GameFontHighlightSmall")
  b.name:SetPoint("TOPLEFT", ICON + 6, -1); b.name:SetWidth(w - ICON - 6)
  b.detail = Text(b, "GameFontHighlightSmall")
  b.detail:SetWordWrap(true)
  b.detail:SetPoint("TOPLEFT", ICON + 6, -15); b.detail:SetWidth(w - ICON - 6)
  b:SetScript("OnEnter", function(self)
    self.hl:Show()
    if not self.itemId then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink("item:" .. self.itemId)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function(self) self.hl:Hide(); GameTooltip:Hide() end)
  popup.itemRows[i] = b
  return b
end

-- One line of clickable places in the popup.
local function LinkPiece(i)
  local r = popup.linkRows[i]
  if not r then
    r = { linkParent = popup.body, links = {} }
    r.fs = Text(popup.body, "GameFontNormalSmall")
    r.fs:SetWidth(POP_W - 30)
    popup.linkRows[i] = r
  end
  return r
end

local function TextHeight(fs, text)
  local h = fs:GetStringHeight()
  if type(h) == "number" and h > 0 then return h end
  return (select(2, text:gsub("\n", "\n")) + 1) * 12 -- no measurement available
end

-- Stack the pieces down the pane (it scrolls when they are taller than it).
local function LayoutPopup(pieces)
  for _, fs in ipairs(popup.textRows) do fs:Hide() end
  for _, b in ipairs(popup.itemRows) do b:Hide() end
  for _, r in ipairs(popup.linkRows) do r.fs:Hide(); HideLinks(r) end
  local y, nt, ni, nl = 4, 0, 0, 0
  for _, p in ipairs(pieces) do
    if p.links then
      nl = nl + 1
      local r = LinkPiece(nl)
      r.fs:ClearAllPoints(); r.fs:SetPoint("TOPLEFT", popup.body, "TOPLEFT", 4, -y)
      PlaceSegments(r.fs, r, p.links, POP_W - 30)
      y = y + 16
    elseif p.item then
      ni = ni + 1
      local b = ItemPiece(ni)
      b.itemId = p.item
      b.hl:Hide()
      b.tex:SetTexture(C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(p.item) or 134400)
      b.name:SetText(p.name)
      b.detail:SetText(p.detail or ""); b.detail:SetShown(p.detail ~= nil)
      local h = math.max(ICON, 15 + (p.detail and TextHeight(b.detail, p.detail) or 0))
      b:ClearAllPoints(); b:SetPoint("TOPLEFT", popup.body, "TOPLEFT", 4, -y)
      b:SetHeight(h); b:Show()
      y = y + h + 4
    else
      nt = nt + 1
      local fs = TextPiece(nt)
      fs:SetText(p.text)
      fs:ClearAllPoints(); fs:SetPoint("TOPLEFT", popup.body, "TOPLEFT", 4, -y)
      fs:Show()
      y = y + TextHeight(fs, p.text) + 4
    end
  end
  popup.body:SetHeight(y + 10)
  popup.scroll:SetVerticalScroll(0)
  PaneThumb()
end

local function ShowObjectives(id)
  if not popup then BuildPopup() end
  local name = Data.Name(id) or ("Quest " .. id)
  popup.title:SetText(Crumb(id) .. "|cffffd100" .. name .. "|r")
  local bits = {}
  local lv = QuestDB.questLevel and QuestDB.questLevel(id)
  if lv and lv > 0 then
    local key = DifficultyKey(lv)
    bits[#bits + 1] = (key and Core.DIFFICULTY[key][4] or "|cffcccccc") .. "Level " .. lv .. "|r"
  end
  local base = Data.Status(id) -- the same test the rows use for "in your log"
  local state = (base == "done" or Data.RepeatableDone(id)) and "done" or base == "log" and "log" or "new"
  bits[#bits + 1] = state == "done" and "|cff66cc66Completed|r" or state == "log" and "|cff8fc4ffIn your quest log|r" or "|cffcccccc#" .. id .. "|r"
  if Data.IsBreadcrumb(id) then
    local to = Data.BreadcrumbTarget(id)
    bits[#bits + 1] = "|cffe0a64aBreadcrumb" .. (to and (" to " .. (Data.Name(to) or ("quest " .. to))) or "") .. "|r"
  end
  popup.sub:SetText(table.concat(bits, " · "))
  LayoutPopup(ObjectivePieces(id))
  popup:Show()
  FitWidth()
  PaneThumb()
  if MarkGraphSelection then MarkGraphSelection() end
end

-- ---- the Zones tab ----
local zoneBar
-- The Zones tab's "By type | By giver | Crumbs" set: the active one is lit and underlined, like Chains | Zones.
-- Crumbs lists only the breadcrumb quests.
local function SyncGroupTabs()
  if not (frame and frame.tabType) then return end
  local crumbs = ZS().crumbs and true or false
  local giver = (not crumbs) and ZS().byGiver and true or false
  local plain = (not crumbs) and not giver
  Lit(frame.tabType, plain)
  Lit(frame.tabGiver, giver)
  Lit(frame.tabCrumbs, crumbs)
end

local CHIPS = { { "available", "Available" }, { "log", "In log" }, { "missed", "Missed" }, { "done", "Done" }, { "all", "All" } }
local STATUS_COLOR = { done = "|cffa8c8ac", log = "|cff8fc4ff", available = "|cffffffff", locked = "|cffb4b4b4", missed = "|cff9a9488" }

-- The filter chips above the list; made once, shown only on the Zones tab.
local function GetZoneBar()
  if zoneBar then return zoneBar end
  zoneBar = CreateFrame("Frame", nil, content)
  zoneBar:SetSize(CONTENT_W, 26)
  zoneBar:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
  zoneBar.chips = {}
  local w = CONTENT_W / #CHIPS
  for i, c in ipairs(CHIPS) do
    local b = Button(zoneBar, c[2], w - 6, 22)
    b:SetPoint("TOPLEFT", (i - 1) * w + 3, -2)
    b.key, b.label = c[1], c[2]
    b.under = Solid(b, "OVERLAY", BRONZE_LIT[1], BRONZE_LIT[2], BRONZE_LIT[3], 1)
    b.under:SetPoint("BOTTOMLEFT", 6, -2); b.under:SetPoint("BOTTOMRIGHT", -6, -2); b.under:SetHeight(2)
    b.plate = Solid(b, "ARTWORK", BRONZE_HOVER[1], BRONZE_HOVER[2], BRONZE_HOVER[3], 0.14)
    b.plate:SetAllPoints(); b.plate:Hide()
    b:SetScript("OnClick", function(self)
      ZS().filter = self.key
      if frame and frame.box then frame.box:ClearFocus() end
      Render()
    end)
    zoneBar.chips[i] = b
  end
  return zoneBar
end

-- A left click on a zone row shows the objectives popup (its Chain button opens the chain); right-click is the waypoint.
local function ZoneRowClick(self, button)
  if frame and frame.box then frame.box:ClearFocus() end
  if button == "RightButton" and self.entry then
    local mode = (IsShiftKeyDown and IsShiftKeyDown() and "end") or (IsAltKeyDown and IsAltKeyDown() and "start") or nil
    WaypointFor(self, mode)
  elseif self.questId then
    popupFor = self.questId
    ShowObjectives(self.questId)
  end
end

-- ---- a chain as a graph: columns for the steps, boxes for the quests, lines for what unlocks what ----
local GN_W, GN_H, GN_GX, GN_GY, GN_PAD = 156, 54, 56, 14, 18
local GZ_MIN, GZ_MAX = 0.4, 1.5
local GN_BORDER = {
  done = { 0.35, 0.7, 0.42 }, log = { 0.35, 0.58, 0.95 }, available = { 0.92, 0.72, 0.28 },
  locked = { 0.62, 0.32, 0.32 }, missed = { 0.5, 0.5, 0.45 },
}

-- The lines touching the box under the mouse, or the box whose details are open, are lit gold (and a little thicker).
local function PaintEdges()
  local sel = popupFor
  for _, ed in ipairs(gedges) do
    local lit = ed.hot or (sel ~= nil and (ed.from == sel or ed.to == sel))
    local c = lit and { 1, 0.86, 0.46, 1 } or ed.color
    for _, l in ipairs(ed.lines) do
      l:SetColorTexture(c[1], c[2], c[3], c[4])
      l:SetThickness(lit and 3 or 2)
    end
  end
end

local function GetGraphNode(i)
  local n = gnodes[i]
  if n then return n end
  n = CreateFrame("Button", nil, gcanvas, "BackdropTemplate")
  n:SetSize(GN_W, GN_H)
  Boxed(n, true)
  n:SetBackdropColor(0.07, 0.055, 0.04, 0.96)
  n.hover = Solid(n, "BACKGROUND", BRONZE_HOVER[1], BRONZE_HOVER[2], BRONZE_HOVER[3], 0.16)
  n.hover:SetAllPoints(); n.hover:Hide()
  n.cur = Solid(n, "BACKGROUND", BRONZE_LIT[1], BRONZE_LIT[2], BRONZE_LIT[3], 0.14)
  n.cur:SetAllPoints(); n.cur:Hide()
  -- the selected box (its details are open): a bright ring round it
  n.sel = CreateFrame("Frame", nil, n, "BackdropTemplate")
  n.sel:SetPoint("TOPLEFT", -4, 4); n.sel:SetPoint("BOTTOMRIGHT", 4, -4)
  n.sel:SetFrameLevel(math.max(0, n:GetFrameLevel() - 1))
  Boxed(n.sel, false)
  n.sel:SetBackdropBorderColor(BRONZE_LIT[1], BRONZE_LIT[2], BRONZE_LIT[3], 1)
  n.sel:Hide()
  n.status = n:CreateTexture(nil, "ARTWORK")
  n.status:SetTexture(STATUS_TEX)
  n.status:SetSize(16, 16)
  n.status:SetPoint("TOPLEFT", 7, -7)
  n.name = Text(n, "GameFontHighlightSmall")
  n.name:SetWordWrap(true)
  n.name:SetJustifyV("TOP")
  n.name:SetPoint("TOPLEFT", 28, -6); n.name:SetSize(GN_W - 28 - 24, 26)
  n.num = Text(n, "GameFontNormalSmall", "RIGHT")
  n.num:SetPoint("TOPRIGHT", -7, -7); n.num:SetWidth(20)
  n.meta = Text(n, "GameFontNormalSmall")
  n.meta:SetPoint("BOTTOMLEFT", 7, 6); n.meta:SetWidth(GN_W - 14 - 62)
  n.xp = Text(n, "GameFontNormalSmall", "RIGHT")
  n.xp:SetPoint("BOTTOMRIGHT", -7, 6); n.xp:SetWidth(62)
  n:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  n.edges = {}
  local function Edges(on)
    for _, ed in ipairs(gedges) do
      if ed.from == n.questId or ed.to == n.questId then ed.hot = on or nil end
    end
    PaintEdges()
  end
  n:SetScript("OnEnter", function(self)
    self.hover:Show()
    Edges(true)
    Hover(self); ShowQuestTip(self)
  end)
  n:SetScript("OnLeave", function(self)
    self.hover:Hide()
    Edges(false)
    Unhover(self); GameTooltip:Hide()
  end)
  n:SetScript("OnClick", function(self, button)
    if frame and frame.box then frame.box:ClearFocus() end
    if button == "RightButton" and self.entry then
      local mode = (IsShiftKeyDown and IsShiftKeyDown() and "end") or (IsAltKeyDown and IsAltKeyDown() and "start") or nil
      WaypointFor(self, mode)
    elseif self.questId then
      popupFor = self.questId
      ShowObjectives(self.questId)
    end
  end)
  gnodes[i] = n
  return n
end

local gviewW -- the graph view's visible width (the column's, less the margins), known before the client has laid it out
local function GraphScrollTo(h, v)
  local maxH = math.max(0, gcontent:GetWidth() - (gviewW or gscroll:GetWidth()))
  local maxV = math.max(0, gcontent:GetHeight() - gscroll:GetHeight())
  gscroll:SetHorizontalScroll(math.min(maxH, math.max(0, h)))
  gscroll:SetVerticalScroll(math.min(maxV, math.max(0, v)))
end

MarkGraphSelection = function()
  local sel = popupFor
  for _, n in ipairs(gnodes) do n.sel:SetShown(sel ~= nil and n.questId == sel and n:IsShown() and true or false) end
  PaintEdges()
end

-- Draws the chain. `all` are the chain's entries with their status, xp and label (see Render).
local function RenderGraph(chain, all)
  local layout = Core.GraphLayout(chain.layers, Data.index.prevs)
  local W = 2 * GN_PAD + layout.cols * GN_W + math.max(0, layout.cols - 1) * GN_GX
  local H = 2 * GN_PAD + layout.rows * GN_H + math.max(0, layout.rows - 1) * GN_GY
  local function colX(c) return GN_PAD + c * (GN_W + GN_GX) end
  local function rowY(r) return GN_PAD + r * (GN_H + GN_GY) end
  scroll:Hide(); frame.bar:Hide()
  gscroll:Show(); frame.gzoom:Show()
  content:SetHeight(1)
  -- the window grows to fit the chain at full size, but never past half the screen
  SetColumn(math.max(WIDTH, math.min(W + 32, HalfScreen())))
  frame.box:SetWidth(colW - 28 - VIEW_W - 8)
  gviewW = colW - 32

  -- the boxes
  local i, byId = 0, {}
  for _, e in ipairs(all) do
    local node = layout.nodes[e.id]
    i = i + 1
    local n = GetGraphNode(i)
    byId[e.id] = n
    n.questId, n.entry = e.id, e
    n:ClearAllPoints(); n:SetPoint("TOPLEFT", gcanvas, "TOPLEFT", colX(node.col), -rowY(node.row))
    local b = GN_BORDER[e.status] or GN_BORDER.locked
    local dim = e.optional and 0.7 or 1
    n:SetBackdropBorderColor(b[1] * dim, b[2] * dim, b[3] * dim, 1)
    n:SetAlpha(e.optional and 0.85 or 1)
    n.cur:SetShown(e.id == current)
    n.hover:Hide()
    local cell = StatusCell(e.status, e.id)
    if cell then SetCell(n.status, cell); n.status:Show() else n.status:Hide() end
    local color = e.id == current and "|cffffd100" or (e.status == "done" and "|cffa8c8ac" or (e.status == "locked" and "|cffb4b4b4" or "|cffffffff"))
    if e.optional and e.id ~= current and e.status ~= "done" then color = e.status == "locked" and "|cff9c968c" or "|cffc8c0ae" end
    n.name:SetText(Crumb(e.id) .. color .. e.name .. "|r")
    n.num:SetText(e.optional and ("|cff8a7d68" .. e.label .. "|r") or ("|cffffd100" .. e.label .. "|r"))
    n.meta:SetText(LevelTag(e.level) .. (e.optional and "|cffe0a64aoptional|r" or ""))
    n.xp:SetText(e.xp > 0 and ("|cffe8c34a" .. (e.xpExact and "" or "~") .. Num(e.xp) .. "|r") or "")
    n:Show()
  end
  for k = i + 1, #gnodes do gnodes[k]:Hide() end

  -- the lines: out of a quest into the corridor on its right, along to the corridor before the quest it unlocks (the
  -- run between corridors keeps to the gap above that quest's row, never over a box), and in from its left
  local segs = 0
  gedges = {}
  local function lane(r) return ((r % 5) - 2) * 3 end
  for _, ed in ipairs(layout.edges) do
    local a, b = layout.nodes[ed.from], layout.nodes[ed.to]
    local toE = layout.nodes[ed.to].entry
    local done = layout.nodes[ed.from].entry.status == "done"
    local color = done and { 0.4, 0.72, 0.45, 0.9 } or (toE.optional and { 0.5, 0.42, 0.3, 0.6 } or { 0.62, 0.5, 0.32, 0.85 })
    local edge = { from = ed.from, to = ed.to, color = color, lines = {} }
    local function seg(x1, y1, x2, y2)
      if x1 == x2 and y1 == y2 then return end
      segs = segs + 1
      local l = glines[segs]
      if not l then l = gcanvas:CreateLine(nil, "BACKGROUND"); glines[segs] = l end
      l:SetThickness(2)
      l:SetColorTexture(color[1], color[2], color[3], color[4])
      l:SetStartPoint("TOPLEFT", gcanvas, x1, -y1)
      l:SetEndPoint("TOPLEFT", gcanvas, x2, -y2)
      l:Show()
      edge.lines[#edge.lines + 1] = l
    end
    local ax, ay = colX(a.col) + GN_W, rowY(a.row) + GN_H / 2
    local bx, by = colX(b.col), rowY(b.row) + GN_H / 2
    if b.col == a.col + 1 then
      local gx = ax + GN_GX / 2 + lane(a.row)
      seg(ax, ay, gx, ay); seg(gx, ay, gx, by); seg(gx, by, bx, by)
    else
      local gx1, gx2 = ax + GN_GX / 2 + lane(a.row), bx - GN_GX / 2 + lane(b.row)
      local gy = rowY(b.row) - GN_GY / 2
      seg(ax, ay, gx1, ay); seg(gx1, ay, gx1, gy); seg(gx1, gy, gx2, gy); seg(gx2, gy, gx2, by); seg(gx2, by, bx, by)
    end
    gedges[#gedges + 1] = edge
  end
  for k = segs + 1, #glines do glines[k]:Hide() end

  -- zoom: fit the chain in the view unless you have zoomed yourself
  local vw, vh = gviewW, gscroll:GetHeight()
  local zoom = graphZoom
  if not zoom then zoom = math.min(1, (vw or W) / W, (vh or H) / H) end
  zoom = math.min(GZ_MAX, math.max(GZ_MIN, zoom))
  frame.gzoom.value = zoom
  gcanvas:SetSize(W, H)
  gcanvas:SetScale(zoom)
  gcontent:SetSize(W * zoom, H * zoom)
  -- bring your own quest into view
  local cur = current and layout.nodes[current]
  local function centre()
    if cur then
      GraphScrollTo((colX(cur.col) + GN_W / 2) * zoom - (vw or 0) / 2, (rowY(cur.row) + GN_H / 2) * zoom - (vh or 0) / 2)
    else
      GraphScrollTo(0, 0)
    end
  end
  centre()
  if C_Timer and C_Timer.After then C_Timer.After(0, centre) end
  MarkGraphSelection()
  if popupFor then ShowObjectives(popupFor) end
end

-- ---- the My Log tab: your own quest log, by the game's own zone headers ----
local function RenderLog()
  frame.back:Hide()
  frame.toggle:Hide()
  frame.title:SetText("My quest log")
  local groups, total, ready = Data.QuestLog()
  local filter = logFilter and logFilter:lower() or ""
  frame.sub:SetText(("%d quests in your log"):format(total))
  frame.stats:SetText(("%d ready to turn in · %d in progress"):format(ready, total - ready))
  SetProgress(ready, total - ready, 0, total)

  local y, n = 0, 0
  local function nextRow(h)
    n = n + 1
    local row = PlaceRow(n, y, h)
    y = y + h
    row.tag:ClearAllPoints(); row.tag:SetPoint("TOPRIGHT", -28, -6)
    row.xp:ClearAllPoints(); row.xp:SetPoint("TOPRIGHT", -28, -6)
    return row
  end
  local shown = 0
  for _, g in ipairs(groups) do
    local list = {}
    for _, q in ipairs(g.quests) do
      local title = q.title or Data.Name(q.id) or ("Quest " .. q.id)
      if filter == "" or title:lower():find(filter, 1, true) then list[#list + 1] = q end
    end
    if #list > 0 or (g.collapsed and filter == "") then
      local fk = "log:" .. g.name
      local open = not collapsed[fk]
      local head = nextRow(26)
      head.hl:SetVertexColor(BRONZE[1], BRONZE[2], BRONZE[3], 0.16); head.hl:Show()
      head.fold:SetTexture(open and MINUS_ICON or PLUS_ICON); head.fold:Show()
      head.name:ClearAllPoints(); head.name:SetPoint("TOPLEFT", 28, -6); head.name:SetWidth(CONTENT_W - 150)
      head.name:SetText("|cffffd100" .. g.name .. "|r")
      local readyHere = 0
      for _, q in ipairs(list) do if q.ready then readyHere = readyHere + 1 end end
      head.xp:SetText("|cff9aa0a8" .. #list .. (readyHere > 0 and (" · |cff66cc66" .. readyHere .. " ready|r") or "") .. "|r")
      head.onClick = function() collapsed[fk] = open or nil; Render() end
      if #list == 0 then
        local note = nextRow(24)
        note.name:ClearAllPoints(); note.name:SetPoint("TOPLEFT", 28, -5); note.name:SetWidth(CONTENT_W - 40)
        note.name:SetText("|cff9aa0a8Folded shut in the game's quest log: open it there to list these.|r")
      elseif open then
        for _, q in ipairs(list) do
          local info = Data.Info(q.id)
          local name = q.title or info.name or ("Quest " .. q.id)
          local entry = { id = q.id, name = name, level = q.level or info.level, reqLevel = info.reqLevel, objective = info.objective, status = "log" }
          local sub
          if q.ready then
            sub = "|cff66cc66Ready to turn in|r"
          else
            local live, left, more = Data.LiveObjectives(q.id), nil, 0
            for _, o in ipairs(live) do
              if not o.done then
                if left then more = more + 1 else left = o.text end
              end
            end
            if left then sub = "|cff9aa0a8" .. left .. (more > 0 and ("  +" .. more .. " more") or "") .. "|r" end
          end
          local row = nextRow(sub and 40 or 28)
          row.questId, row.entry, row.onClick = q.id, entry, ZoneRowClick
          SetCell(row.status, q.ready and STATUS_CELL.done or STATUS_CELL.log)
          row.status:ClearAllPoints(); row.status:SetPoint("TOPLEFT", 24, -5); row.status:Show()
          row.name:ClearAllPoints(); row.name:SetPoint("TOPLEFT", 46, -5); row.name:SetWidth(CONTENT_W - 46 - 110)
          row.name:SetText(LevelTag(entry.level) .. (q.ready and "|cffa8c8ac" or "|cffffffff") .. name .. "|r  |cff808080#" .. q.id .. "|r")
          local xp = Data.ClientXp(q.id)
          if xp then row.xp:SetText("|cffe8c34a" .. Num(xp) .. " XP|r") end
          if Data.index.prevs[q.id] or Data.index.nexts[q.id] then row.chain:Show() end
          if sub then row.sub:ClearAllPoints(); row.sub:SetPoint("TOPLEFT", 46, -21); row.sub:SetText(sub); row.sub:Show() end
        end
      end
      shown = shown + #list
    end
  end
  if shown == 0 and n == 0 then
    local row = nextRow(30)
    row.name:ClearAllPoints(); row.name:SetPoint("TOPLEFT", 8, -8); row.name:SetWidth(CONTENT_W - 10)
    row.name:SetText("|cff9aa0a8" .. (filter ~= "" and "No quest in your log matches that." or "Your quest log is empty.") .. "|r")
  end
  content:SetHeight(math.max(y, 1))
  scroll:SetVerticalScroll(0)
  UpdateThumb()
  if popupFor then ShowObjectives(popupFor) end
end

-- ---- the Zones tab's list of all zones, by continent, with how far you are in each ----
local METER_W = 90

-- One zone row's numbers: "done / total" and the bar (green when every quest there is done).
local function FillZoneRow(row, p)
  if not p then
    row.xp:SetText("|cff808080…|r")
    row.meter:Show(); row.meterFill:Hide()
    return
  end
  local complete = p.total > 0 and p.done >= p.total
  local color = complete and "|cff66cc66" or (p.done == 0 and "|cff9a9488" or "|cffffffff")
  row.xp:SetText(color .. p.done .. " / " .. p.total .. "|r")
  row.meter:Show()
  local w = p.total > 0 and math.floor(METER_W * p.done / p.total + 0.5) or 0
  if p.done > 0 then w = math.max(1, w) end -- a little done always shows
  if w > 0 then
    row.meterFill:SetWidth(w)
    if complete then row.meterFill:SetVertexColor(0.2, 0.58, 0.3, 1) else row.meterFill:SetVertexColor(0.85, 0.65, 0.15, 1) end
    row.meterFill:Show()
  else
    row.meterFill:Hide()
  end
end

-- Works the zones' numbers out a few at a time (each one builds that zone's list), filling the rows as they come.
local indexDriver
local function IndexStep()
  local job = indexJob
  if not job then
    if indexDriver then indexDriver:SetScript("OnUpdate", nil) end
    return
  end
  local t0 = debugprofilestop and debugprofilestop() or nil
  local count = 0
  while job.pos <= #job.queue do
    local z = job.queue[job.pos]
    job.pos = job.pos + 1
    local p = Zones.Progress(z.area)
    FillZoneRow(job.rows[z.area], p)
    local g = job.groupOf[z.area]
    g.done, g.total, g.n = g.done + p.done, g.total + p.total, g.n + 1
    job.done, job.total = job.done + p.done, job.total + p.total
    if g.n == #g.zones then g.row.xp:SetText("|cff9aa0a8" .. g.done .. " / " .. g.total .. "|r") end
    count = count + 1
    if t0 then
      if debugprofilestop() - t0 > 8 then break end
    elseif count >= 3 then
      break
    end
  end
  if job.pos > #job.queue then
    frame.stats:SetText(("%d of %d quests done"):format(job.done, job.total))
    indexJob = nil
    if indexDriver then indexDriver:SetScript("OnUpdate", nil) end
  else
    frame.stats:SetText(("Counting… %d of %d zones"):format(job.pos - 1, #job.queue))
  end
  SetProgress(job.done, 0, 0, job.total)
end

local function RenderZoneIndex()
  local list = Zones.List()
  local groups, order, groupOf = {}, {}, {}
  for _, z in ipairs(list) do
    local name = Data.ContinentOf(z.area) or "Other"
    local g = groups[name]
    if not g then
      g = { name = name, zones = {}, done = 0, total = 0, n = 0 }
      groups[name] = g
      order[#order + 1] = g
    end
    g.zones[#g.zones + 1] = z
    groupOf[z.area] = g
  end
  table.sort(order, function(a, b)
    if (a.name == "Other") ~= (b.name == "Other") then return b.name == "Other" end
    return a.name < b.name
  end)
  local here = Zones.CurrentArea()
  frame.title:SetText("Zones")
  frame.sub:SetText(("%d zones with quests"):format(#list) .. (here and (" · you are in " .. Data.ZoneName(here)) or ""))
  frame.stats:SetText("")
  SetProgress()

  local y, n = 0, 0
  local function nextRow(h)
    n = n + 1
    local row = PlaceRow(n, y, h)
    y = y + h
    row.tag:ClearAllPoints(); row.tag:SetPoint("TOPRIGHT", -8, -6)
    row.xp:ClearAllPoints(); row.xp:SetPoint("TOPRIGHT", -8, -6)
    return row
  end
  local jobRows, queue = {}, {}
  for _, g in ipairs(order) do
    local fk = "continent:" .. g.name
    local open = not collapsed[fk]
    local head = nextRow(28)
    g.row = head
    head.hl:SetVertexColor(BRONZE[1], BRONZE[2], BRONZE[3], 0.16); head.hl:Show()
    head.fold:SetTexture(open and MINUS_ICON or PLUS_ICON); head.fold:Show()
    head.name:ClearAllPoints(); head.name:SetPoint("TOPLEFT", 28, -7); head.name:SetWidth(CONTENT_W - 150)
    head.name:SetText("|cffffd100" .. g.name .. "|r")
    head.xp:SetText("|cff9aa0a8" .. #g.zones .. " zones|r")
    head.onClick = function() collapsed[fk] = open or nil; Render() end
    for _, z in ipairs(g.zones) do
      queue[#queue + 1] = z
      if open then
        local row = nextRow(26)
        jobRows[z.area] = row
        row.name:ClearAllPoints(); row.name:SetPoint("TOPLEFT", 30, -6); row.name:SetWidth(CONTENT_W - 30 - 190)
        row.name:SetText((z.area == here and "|cffffd100" or "|cffffffff") .. z.name .. "|r" .. (z.area == here and "  |cff9a9488you are here|r" or ""))
        row.xp:ClearAllPoints(); row.xp:SetPoint("TOPRIGHT", -108, -7); row.xp:SetWidth(70)
        row.onClick = function()
          ZS().area = z.area
          zoneIndex, zonePick, zoneNotice, popupFor = false, nil, nil, nil
          Render()
        end
        FillZoneRow(row, nil)
      end
    end
  end
  -- folded continents still count (their header's numbers), but have no rows to fill
  local noop = setmetatable({}, { __index = function() return function() end end })
  local dummy = { xp = noop, meter = noop, meterFill = noop }
  for _, z in ipairs(queue) do jobRows[z.area] = jobRows[z.area] or dummy end
  Zones.ResetProgress()
  indexJob = { queue = queue, pos = 1, rows = jobRows, groupOf = groupOf, done = 0, total = 0 }
  indexDriver = indexDriver or CreateFrame("Frame")
  indexDriver:SetScript("OnUpdate", IndexStep)

  content:SetHeight(math.max(y, 1))
  if lastZoneShown ~= "index" then scroll:SetVerticalScroll(0); lastZoneShown = "index" end
  UpdateThumb()
end

local function RenderZone()
  Zones = Zones or ns.Zones
  frame.back:SetShown(not zoneIndex)
  frame.back.text:SetText("All zones")
  frame.back:SetWidth(76)
  frame.toggle:Show()
  SyncGroupTabs()
  if Data.state == "error" or Zones.state == "error" then
    frame.title:SetText("Zones")
    frame.sub:SetText("|cffff6060" .. tostring(Data.error or Zones.error) .. "|r")
    frame.stats:SetText("")
    content:SetHeight(1)
    return
  end
  if Zones.state ~= "ready" then
    if Zones.state == "idle" then Zones.Ensure(Render) end
    local p = Data.state == "building" and Data.progress * 0.5 or 0.5 + 0.5 * Zones.progress
    frame.title:SetText("Zones")
    frame.sub:SetText(("Reading QuestieDB… %d%%"):format(math.floor(p * 100)))
    frame.stats:SetText("")
    content:SetHeight(1)
    return
  end

  local y, n = 0, 0
  local function nextRow(h)
    n = n + 1
    local row = PlaceRow(n, y, h)
    y = y + h
    -- the right-hand text (count, tag) leaves room for a row's chain-link icon
    row.tag:ClearAllPoints(); row.tag:SetPoint("TOPRIGHT", -28, -6)
    row.xp:ClearAllPoints(); row.xp:SetPoint("TOPRIGHT", -28, -6)
    return row
  end
  -- A section header: a soft bronze band, the title in gold, the count at the right.
  -- fold: nil for a plain header, true / false for a collapsible one that is open / folded shut (with its icon)
  local function header(text, count, color, fold)
    local row = nextRow(26)
    row.hl:SetVertexColor(BRONZE[1], BRONZE[2], BRONZE[3], 0.16); row.hl:Show()
    if fold ~= nil then row.fold:SetTexture(fold and MINUS_ICON or PLUS_ICON); row.fold:Show() end
    row.name:ClearAllPoints(); row.name:SetPoint("TOPLEFT", fold ~= nil and 28 or 8, -6); row.name:SetWidth(CONTENT_W - 150)
    row.name:SetText((color or "|cffffd100") .. text .. "|r")
    if count then row.xp:SetText("|cff9aa0a8" .. count .. "|r") end
    return row
  end
  local function finish(area)
    content:SetHeight(math.max(y, 1))
    if lastZoneShown ~= area then scroll:SetVerticalScroll(0); lastZoneShown = area end
    UpdateThumb()
    if popupFor then ShowObjectives(popupFor) end
  end

  if wantHere then -- the window was just opened: the area you are in, not the list
    wantHere = false
    local here = Zones.CurrentArea()
    if here then ZS().area = here; zoneIndex = false else zoneIndex = true end
  end
  if zoneIndex and not zonePick then return RenderZoneIndex() end

  if zonePick then
    frame.title:SetText("Zones")
    frame.sub:SetText(zoneNotice or "Pick a zone.")
    frame.stats:SetText("")
    for _, z in ipairs(zonePick) do
      local row = header(z.name .. "  |cff808080" .. z.count .. " quests|r")
      row.onClick = function() ZS().area = z.area; zonePick, zoneNotice, popupFor = nil, nil, nil; Render() end
    end
    return finish(nil)
  end

  local area = ZS().area
  if not area then
    area = Zones.CurrentArea()
    if not area then local l = Zones.List(); area = l[1] and l[1].area end
    ZS().area = area
  end
  if not area then
    frame.title:SetText("Zones")
    frame.sub:SetText("QuestieDB lists no zones with quests.")
    frame.stats:SetText("")
    content:SetHeight(1)
    return
  end
  if not Zones.HasArea(area) then
    frame.title:SetText(Data.ZoneName(area))
    frame.sub:SetText("No quests start in this zone.")
    frame.stats:SetText("")
    content:SetHeight(1)
    return
  end

  local model = Zones.Model(area)
  local ev = Zones.Evaluate(model)
  local t = ev.totals
  local filter = ZS().filter
  frame.title:SetText(model.name)
  frame.sub:SetText(zoneNotice or ("%d quests in this zone"):format(t.quests))
  frame.stats:SetText(("%d available · %d in your log · %d missed · %d done"):format(t.available, t.log, t.missed, t.done))
  SetProgress(t.done, t.log, t.available, t.quests)
  local bar = GetZoneBar()
  bar:Show()
  for _, b in ipairs(bar.chips) do
    b.text:SetText(b.label)
    Lit(b, b.key == filter)
  end
  y = 30

  local function statusIcon(row, status, indent, id)
    local dim = status == "missed"
    local cell = StatusCell(dim and "locked" or status, id)
    if cell then
      SetCell(row.status, cell)
      row.status:ClearAllPoints(); row.status:SetPoint("TOPLEFT", 24 + indent, -5)
      row.status:SetDesaturated(dim)
      row.status:Show()
    end
  end
  local function entryFor(id, name, status, detail, greyNote)
    local info = Zones.InfoOf(id)
    return { id = id, name = name or info.name or ("Quest " .. id), level = info.level, reqLevel = info.reqLevel,
      objective = info.objective, status = status, unmet = detail, grey = greyNote }, info
  end
  local function questRow(id, indent)
    local s = ev.quest[id]
    local entry, info = entryFor(id, nil, s.status, s.detail, s.greyNote)
    local sub
    if s.status == "missed" then
      sub = "|cffd9a04a" .. (s.detail[1] or "Missed") .. "|r"
    elseif s.greyNote then
      sub = "|cff9a9488" .. s.greyNote .. "|r"
    elseif s.status == "locked" and #s.detail > 0 then
      sub = "|cffff8a8aNeeds: " .. table.concat(s.detail, " · ") .. "|r"
    end
    if ZS().crumbs and (not sub or s.greyNote) and Data.IsBreadcrumb(id) then
      local to = Data.BreadcrumbTarget(id)
      if to then sub = "|cff8fb4c8Leads into " .. (Data.Name(to) or ("quest " .. to)) .. "|r" end
    end
    local row = nextRow(sub and 40 or 28)
    row.questId, row.entry, row.onClick = id, entry, ZoneRowClick
    statusIcon(row, s.status, indent, id)
    if model.chainOf[id] then row.chain:Show() end
    row.name:ClearAllPoints(); row.name:SetPoint("TOPLEFT", 46 + indent, -5); row.name:SetWidth(CONTENT_W - 46 - indent - 110)
    row.name:SetText(Crumb(id) .. LevelTag(info.level) .. STATUS_COLOR[s.status] .. entry.name .. "|r  |cff808080#" .. id .. "|r")
    if s.status == "missed" then row.tag:SetText("|cffd9a04aMissed|r"); row.tag:Show() end
    if s.greyNote then row.tag:SetText("|cff9a9488Grey|r"); row.tag:Show() end
    if sub then row.sub:ClearAllPoints(); row.sub:SetPoint("TOPLEFT", 46 + indent, -21); row.sub:SetText(sub); row.sub:Show() end
    return row
  end
  local function chainRow(c)
    local ce = ev.chain[c]
    local s = ev.quest[c.entry]
    local entry, info = entryFor(c.entry, c.name, s.status, s.detail, s.greyNote)
    local row = nextRow(40)
    row.questId, row.entry, row.onClick = c.entry, entry, ZoneRowClick
    statusIcon(row, ce.status, 0)
    row.name:ClearAllPoints(); row.name:SetPoint("TOPLEFT", 46, -5); row.name:SetWidth(CONTENT_W - 46 - 130)
    row.name:SetText(LevelTag(c.minLevel or info.level) .. STATUS_COLOR[ce.status] .. c.name .. "|r  |cff808080#" .. c.entry .. "|r")
    row.chain:Show()
    local bits = { ce.counts.done .. " of " .. #c.ids .. " done" }
    if ce.counts.log > 0 then bits[#bits + 1] = "|cff8fc4ff" .. ce.counts.log .. " in your log|r" end
    if ce.counts.missed > 0 then bits[#bits + 1] = "|cffd9a04a" .. ce.counts.missed .. " missed|r" end
    if ce.counts.grey > 0 then bits[#bits + 1] = "|cff9a9488" .. ce.counts.grey .. " grey|r" end
    row.sub:ClearAllPoints(); row.sub:SetPoint("TOPLEFT", 46, -21)
    row.sub:SetText("|cff9aa0a8" .. table.concat(bits, " · ") .. "|r"); row.sub:Show()
    if ce.status == "missed" then
      row.tag:ClearAllPoints(); row.tag:SetPoint("TOPRIGHT", -28, -21)
      row.tag:SetText("|cffd9a04aMissed|r"); row.tag:Show()
    end
    return row
  end
  local function visible(list)
    local out = {}
    for _, id in ipairs(list) do
      if Zones.Matches(filter, ev.quest[id].status) then out[#out + 1] = id end
    end
    return out
  end

  -- A collapsible section: its header folds the rows under it away, and back. Returns whether it is open.
  local function section(text, count, key)
    local fk = area .. ":section:" .. key
    local open = not collapsed[fk]
    local row = header(text, count, nil, open)
    row.onClick = function() collapsed[fk] = open or nil; Render() end
    return open
  end

  local shown = 0
  if ZS().crumbs then
    -- only the breadcrumb quests (optional lead-ins to a longer quest), by level
    local list = visible(model.quests)
    local crumbs = {}
    for _, id in ipairs(list) do
      if Data.IsBreadcrumb(id) then crumbs[#crumbs + 1] = id end
    end
    table.sort(crumbs, function(a, b)
      local ia, ib = Zones.InfoOf(a), Zones.InfoOf(b)
      local la, lb = ia.level or 0, ib.level or 0
      if la ~= lb then return la < lb end
      if (ia.name or "") ~= (ib.name or "") then return (ia.name or "") < (ib.name or "") end
      return a < b
    end)
    if #crumbs > 0 and section("Breadcrumbs", #crumbs, "crumbs") then
      for _, id in ipairs(crumbs) do questRow(id, 0) end
    end
    shown = #crumbs
  elseif not ZS().byGiver then
    local chains, singles, groups, objTotal = {}, visible(model.singles), {}, 0
    for _, c in ipairs(model.chains) do
      if Zones.ChainMatches(filter, ev.chain[c]) then chains[#chains + 1] = c end
    end
    for _, g in ipairs(model.objGroups) do
      local qs = visible(g.quests)
      if #qs > 0 then groups[#groups + 1] = { g = g, qs = qs }; objTotal = objTotal + #qs end
    end
    if #chains > 0 and section("Chains", #chains, "chains") then
      for _, c in ipairs(chains) do chainRow(c) end
    end
    if #singles > 0 and section("Single quests", #singles, "singles") then
      for _, id in ipairs(singles) do questRow(id, 0) end
    end
    if #groups > 0 and section("Start from objects and items", objTotal, "objects") then
      for _, e in ipairs(groups) do
        header(e.g.name .. "  (" .. e.g.kind .. ")", nil, "|cffe0a64a")
        for _, id in ipairs(e.qs) do questRow(id, 14) end
      end
    end
    shown = #chains + #singles + objTotal
  else
    for _, g in ipairs(model.givers) do
      local qs = visible(g.quests)
      if #qs > 0 then
        local key = area .. ":" .. g.kind .. ":" .. g.id
        local open = not collapsed[key]
        local done = 0
        for _, id in ipairs(g.quests) do if ev.quest[id].status == "done" then done = done + 1 end end
        local row = header(g.name .. (g.kind ~= "npc" and ("  |cff9a9488(" .. g.kind .. ")|r") or ""), #g.quests .. " quests · " .. done .. " done", nil, open)
        row.onClick = function() collapsed[key] = open or nil; Render() end
        if open then
          for _, id in ipairs(qs) do
            questRow(id, 14)
          end
        end
        shown = shown + #qs
      end
    end
  end
  if shown == 0 then
    local row = nextRow(30)
    row.name:ClearAllPoints(); row.name:SetPoint("TOPLEFT", 4, -8); row.name:SetWidth(CONTENT_W - 10)
    row.name:SetText("|cff9aa0a8Nothing here with this filter. Try All.|r")
  end
  finish(area)
end

function Render()
  if not frame then return end
  frame.back:SetShown(current ~= nil and backTo ~= nil)
  frame.back.text:SetText("Back")
  frame.back:SetWidth(52)
  indexJob = nil
  SetProgress()
  -- the list is the default body; the graph view swaps it for the canvas
  scroll:Show()
  gscroll:Hide(); frame.gzoom:Hide()
  for _, nd in ipairs(gnodes) do nd:Hide() end
  for _, ln in ipairs(glines) do ln:Hide() end
  frame.viewToggle:Hide()
  SetColumn(WIDTH)
  if not zoneMode then frame.box:SetWidth(WIDTH - 28) end
  if popup then popup:Hide(); FitWidth() end -- shown again at the end of a full chain render
  for _, row in ipairs(rows) do row:Hide(); row.here:Hide(); HideLinks(row); ReleaseIcons(row) end
  if zoneBar then zoneBar:Hide() end
  if zoneMode then return RenderZone() end
  frame.toggle:Hide() -- the toggle holds the Zones tab's By type | By giver | Crumbs tabs
  if logMode then return RenderLog() end

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
      row.name:SetText(Crumb(hit.id) .. LevelTag(lv) .. hit.name .. "  |cff808080#" .. hit.id .. "|r")
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

  local chain = Core.Chain(Data.index, current, Data.Info, Data.Who())
  if not chain then
    frame.title:SetText("Quest " .. current)
    frame.sub:SetText("That quest is not in QuestieDB.")
    frame.stats:SetText("")
    content:SetHeight(1)
    return
  end

  local level = UnitLevel and UnitLevel("player") or 0
  -- a prerequisite is named with its number in the chain ("Blight No More (1)"), so equal names can be told apart
  local labelOf, continues, prevE = {}, {}, nil
  for _, layer in ipairs(chain.layers) do
    for _, e in ipairs(layer) do
      labelOf[e.id] = e.label
      if prevE and prevE.optional and e.optional then continues[prevE.id] = true end -- the next row is a side quest too
      prevE = e
    end
  end
  local function nameOf(id)
    local n = Data.Name(id) or ("Quest " .. id)
    local l = labelOf[id]
    return l and (n .. " (" .. l .. ")") or n
  end
  local maxed = GetMaxPlayerLevel and level >= GetMaxPlayerLevel()
  local all = {}
  local totalXp = 0
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
    end
  end
  for _, e in ipairs(all) do
    for _, id in ipairs(e.items) do
      if not itemSeen[id] then itemSeen[id] = true; itemList[#itemList + 1] = id end
    end
  end
  table.sort(itemList)

  local nDone, nLog, nOpen = 0, 0, 0
  for _, e in ipairs(all) do
    if e.status == "done" then nDone = nDone + 1 elseif e.status == "log" then nLog = nLog + 1 elseif e.status == "available" then nOpen = nOpen + 1 end
  end
  SetProgress(nDone, nLog, nOpen, #all)
  local startName = Data.Name(current) or ("Quest " .. current)
  frame.title:SetText(startName)
  local part = chain.currentLayer > 0 and chain.parts > 0 and (" · step " .. chain.currentLayer .. " of " .. chain.parts) or ""
  frame.sub:SetText(("Quest %d%s%s"):format(current, part, chain.truncated and " · chain is large, showing the nearest quests" or ""))
  frame.stats:SetText(("Whole chain: %d quests%s · %s · %d reward items"):format(
    #all, chain.optionalCount > 0 and (" (" .. chain.mainCount .. " main, " .. chain.optionalCount .. " optional)") or "",
    maxed and "no XP at max level" or ("~" .. Num(totalXp) .. " XP at level " .. level), #itemList))

  -- List | Graph
  local graphView = DB().chainView == "graph"
  frame.viewToggle:Show()
  frame.box:SetWidth(colW - 28 - VIEW_W - 8)
  Lit(frame.tabList, not graphView)
  Lit(frame.tabGraph, graphView)
  if graphView then return RenderGraph(chain, all) end

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
  summary.name:SetText("Item rewards across the chain")
  summary.name:SetWidth(CONTENT_W - 10)
  summary.name:ClearAllPoints(); summary.name:SetPoint("TOPLEFT", 4, -5)
  local repText = SumReputation(all)
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
      -- Lead-ins: optional quests that start this one earlier, so they come first. They are not counted in the totals above.
      for _, c in ipairs(e.crumbs or {}) do
        local base = Data.Status(c.id)
        c.status, c.unmet = Core.StatusOf(c, base == "done", base == "log", Data.IsDone, level, nameOf)
        local over = (e.status == "done" or e.status == "log") and c.status ~= "done" and c.status ~= "log"
        local cSub
        if over then
          cSub = "|cff9aa0a8No longer needed: you already have the quest it leads into|r"
        elseif #c.unmet > 0 then
          cSub = "|cffff8a8aNeeds: " .. table.concat(c.unmet, " · ") .. "|r"
        else
          cSub = "|cff9aa0a8Optional: leads into step " .. li .. "|r"
        end
        local cWhere = WhereSegments(c)
        local crow = nextRow(28 + 12 + (cWhere and 12 or 0))
        crow.questId, crow.entry = c.id, c
        crow.num:SetText("»")
        local cell = StatusCell(c.status, c.id)
        if cell then
          SetCell(crow.status, cell)
          crow.status:ClearAllPoints(); crow.status:SetPoint("TOPLEFT", 38, -5)
          crow.status:Show()
        end
        crow.name:ClearAllPoints(); crow.name:SetPoint("TOPLEFT", 60, -5); crow.name:SetWidth(CONTENT_W - 60 - 84)
        local cLvl = LevelTag(c.level)
        local cColor = (over or c.status == "done") and "|cff8a9a8c" or (c.status == "locked" and "|cffb4b4b4" or "|cffffffff")
        crow.tag:SetText("|cffe0a64aBreadcrumb|r"); crow.tag:Show()
        crow.name:SetText(Crumb(c.id) .. cLvl .. cColor .. c.name .. "|r  |cff808080#" .. c.id .. "|r")
        crow.sub:ClearAllPoints(); crow.sub:SetPoint("TOPLEFT", 60, -21)
        crow.sub:SetText(cSub); crow.sub:Show()
        if cWhere then
          crow.where:ClearAllPoints(); crow.where:SetPoint("TOPLEFT", 60, -33)
          PlaceSegments(crow.where, crow, cWhere, CONTENT_W - 60 - 8)
        end
        crow.bar:SetVertexColor(0.88, 0.65, 0.29, 0.8); crow.bar:Show()
      end
      local hasItems = #e.items > 0
      local rowLines = math.max(1, math.ceil(#e.items / 14))
      local isCurrent = e.id == current
      local ind = e.optional and 32 or 0 -- an optional side quest hangs to the right, off its rail
      if isCurrent then currentY = y end
      -- A second line only for your quest and for locked quests; the icon carries the rest.
      local sub = {}
      if isCurrent then sub[#sub + 1] = "|cffffd100You are here|r" end
      if #(e.unmet or {}) > 0 then sub[#sub + 1] = "|cffff8a8aNeeds: " .. table.concat(e.unmet, " · ") .. "|r" end
      local subH = #sub > 0 and 12 or 0
      -- Where it happens: the zones of its kills, objects and drops (or where it is handed in).
      local whereSegs = WhereSegments(e)
      local whereH = whereSegs and 12 or 0
      local row = nextRow(28 + subH + whereH + (hasItems and rowLines * (ICON + 3) or 0))
      row.questId = e.id
      row.entry = e
      row.num:SetText(e.optional and ("|cffe0a64a" .. e.label .. "|r") or e.label)
      if e.optional then
        -- the rail runs on to the next row while the group continues, and ends at its elbow on the group's last quest
        row.rail:ClearAllPoints(); row.rail:SetPoint("TOPLEFT", 22, 0)
        if continues[e.id] then row.rail:SetPoint("BOTTOMLEFT", 22, 0) else row.rail:SetHeight(15) end
        row.rail:Show(); row.stub:Show(); row.badge:Show()
        row.num:ClearAllPoints(); row.num:SetPoint("TOPLEFT", 34, -9); row.num:SetWidth(18); row.num:SetJustifyH("CENTER")
        row.name:ClearAllPoints(); row.name:SetPoint("TOPLEFT", 46 + ind, -5); row.name:SetWidth(CONTENT_W - 46 - ind - 84)
      end
      local cell = StatusCell(e.status, e.id)
      if cell then
        SetCell(row.status, cell)
        row.status:ClearAllPoints(); row.status:SetPoint("TOPLEFT", 24 + ind, -5)
        row.status:Show()
      end
      local color = isCurrent and "|cffffd100" or (e.status == "done" and "|cffa8c8ac" or (e.status == "locked" and "|cffb4b4b4" or "|cffffffff"))
      if e.optional and not isCurrent and e.status ~= "done" then color = e.status == "locked" and "|cff9c968c" or "|cffc8c0ae" end
      local lvl = LevelTag(e.level)
      -- A repeatable quest: its ID is green once done, and a tag says it repeats (and how often you did it).
      local idColor, tag = "|cff808080", ""
      local rep = Data.RepeatInfo(e.id)
      if rep then
        if rep.done then
          idColor = "|cff4fe04f"
          tag = "  |cff7be07bRepeatable · done" .. (rep.count > 0 and (" " .. rep.count .. "x") or "") .. "|r"
        else
          tag = "  |cff9aa0a8Repeatable|r"
        end
      end
      row.name:SetText(Crumb(e.id) .. lvl .. color .. e.name .. "|r  " .. idColor .. "#" .. e.id .. "|r" .. tag)
      if #sub > 0 then
        row.sub:ClearAllPoints(); row.sub:SetPoint("TOPLEFT", 46 + ind, -21)
        row.sub:SetText(table.concat(sub, "  ·  ")); row.sub:Show()
      end
      if isCurrent then
        row.subNormal = table.concat(sub, "  ·  ")
        sub[1] = "|cffffffffYou are here|r" -- the lit-up version, while the mouse is over it
        row.subHot = table.concat(sub, "  ·  ")
        row.here:ClearAllPoints(); row.here:SetPoint("TOPLEFT", 46 + ind, -21)
        row.here:SetWidth(HereWidth()); row.here:Show()
      end
      if whereSegs then
        row.where:ClearAllPoints(); row.where:SetPoint("TOPLEFT", 46 + ind, -(21 + subH))
        PlaceSegments(row.where, row, whereSegs, CONTENT_W - 46 - ind - 8)
      end
      if e.xp > 0 then
        row.xp:SetText((e.xpExact and "" or "~") .. Num(e.xp) .. " XP")
      end
      -- A breadcrumb opened as a step of its own (normally they hang above the quest they lead into).
      if Data.IsBreadcrumb(e.id) then
        row.tag:SetText("|cffe0a64aBreadcrumb|r")
        if e.xp > 0 then row.tag:ClearAllPoints(); row.tag:SetPoint("TOPRIGHT", -2, -21) end -- under the XP
        row.tag:Show()
      elseif e.optional then
        row.tag:SetText("|cffe0a64aOptional|r")
        if e.xp > 0 then row.tag:ClearAllPoints(); row.tag:SetPoint("TOPRIGHT", -2, -21) end -- under the XP
        row.tag:Show()
      end
      if isCurrent then
        row.hl:SetVertexColor(BRONZE_HOVER[1], BRONZE_HOVER[2], BRONZE_HOVER[3], 0.22); row.hl:Show(); row.bar:Show()
      end
      if hasItems then PlaceIcons(row, e.items, 46 + ind, -(24 + subH + whereH), 14) end
    end
  end
  content:SetHeight(math.max(y, 1))
  if popupFor then ShowObjectives(popupFor) end

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
    if Data.state == "building" or (zoneMode and Zones.state == "building") then
      Render()
    else
      self:SetScript("OnUpdate", nil)
    end
  end)
end

-- Centered on the screen, anchored by its top-left corner (so the window grows to the right when the pane opens).
local function PlaceDefault(f)
  f:ClearAllPoints()
  local uw, uh = UIParent:GetWidth(), UIParent:GetHeight()
  if type(uw) == "number" and type(uh) == "number" and uw > 0 and uh > 0 then
    local s = f:GetScale()
    s = (type(s) == "number" and s > 0) and s or 1
    f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", math.max(0, (uw / s - WIDTH) / 2), (uh / s + HEIGHT) / 2)
  else
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  end
end

-- A window saved (or left) on another anchor is re-anchored by its top-left corner once it can be measured.
local function Normalize(f)
  local p = f:GetPoint()
  if p == "TOPLEFT" then return end
  local l, t = f:GetLeft(), f:GetTop()
  if type(l) == "number" and type(t) == "number" then
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l, t)
  end
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
    local l, t = self:GetLeft(), self:GetTop()
    if type(l) == "number" and type(t) == "number" then
      self:ClearAllPoints()
      self:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l, t)
      DB().pos = { "TOPLEFT", "BOTTOMLEFT", l, t }
    else
      local p, _, rp, x, y = self:GetPoint()
      DB().pos = { p, rp, x, y }
    end
  end)
  f:SetScale(DB().scale or 1)
  local pos = DB().pos
  if pos then f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4]) else PlaceDefault(f) end

  Boxed(f, true)
  f:SetBackdropColor(0.055, 0.045, 0.035, 0.96) -- FlareUI's warm dark, not neutral grey
  -- a warm band behind the brand row
  f.wash = Solid(f, "BACKGROUND", 0.55, 0.42, 0.24, 0.1)
  f.wash:SetPoint("TOPLEFT", 4, -4); f.wash:SetPoint("TOPRIGHT", -4, -4); f.wash:SetHeight(46)

  -- brand row: the chain-link badge, the name and version, and at the right the two views and Close
  f.logo = f:CreateTexture(nil, "ARTWORK")
  f.logo:SetTexture("Interface\\AddOns\\QuestThread\\Chain.tga")
  f.logo:SetSize(34, 34)
  f.logo:SetPoint("TOPLEFT", 12, -9)
  f.brand = Text(f, "GameFontNormalLarge")
  f.brand:SetPoint("TOPLEFT", 52, -14)
  f.brand:SetText("QuestThread")
  f.version = Text(f, "GameFontDisableSmall")
  f.version:SetPoint("LEFT", f.brand, "RIGHT", 6, -1)
  do
    local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local ok, v = pcall(function() return get and get(ADDON, "Version") end)
    f.version:SetText(ok and type(v) == "string" and v or "")
  end
  local rule = Solid(f, "BORDER", BRONZE_MUTED[1], BRONZE_MUTED[2], BRONZE_MUTED[3], 0.6)
  rule:SetPoint("TOPLEFT", 4, -50); rule:SetPoint("TOPRIGHT", -4, -50); rule:SetHeight(1)

  -- the quest or zone being shown: its name, a line about it, the numbers, and a progress bar
  f.title = Text(f, "GameFontNormalLarge")
  f.title:SetPoint("TOPLEFT", 14, -94); f.title:SetWidth(WIDTH - 28)
  f.sub = Text(f, "GameFontHighlightSmall")
  f.sub:SetPoint("TOPLEFT", 14, -116); f.sub:SetWidth(WIDTH - 28)
  f.sub:SetTextColor(0.78, 0.74, 0.66) -- softer than the white of the row names
  f.stats = Text(f, "GameFontNormalSmall")
  f.stats:SetPoint("TOPLEFT", 14, -132); f.stats:SetWidth(WIDTH - 28)
  f.prog = Solid(f, "ARTWORK", BRONZE_MUTED[1], BRONZE_MUTED[2], BRONZE_MUTED[3], 0.28)
  f.prog:SetPoint("TOPLEFT", 14, -152); f.prog:SetSize(WIDTH - 28, 4)
  f.prog:Hide()
  f.progDone = Solid(f, "OVERLAY", 0.2, 0.58, 0.3, 1)
  f.progLog = Solid(f, "OVERLAY", 0.25, 0.55, 0.9, 1)
  f.progAvail = Solid(f, "OVERLAY", 0.85, 0.65, 0.15, 1)
  f.progDone:Hide(); f.progLog:Hide(); f.progAvail:Hide()

  local close = Button(f, "X", 24, 24)
  close:SetPoint("TOPRIGHT", -12, -13)
  close:SetScript("OnClick", function() f:Hide() end)

  -- Chains | Zones: the window's two views (and the shape of the By type | By giver | Breadcrumbs tabs below).
  local function Tab(label, anchor, dx, parent, w)
    local b = Button(parent or f, label, w or 58, 24)
    if anchor then b:SetPoint("LEFT", anchor, "RIGHT", dx, 0) end
    b.under = Solid(b, "OVERLAY", BRONZE_LIT[1], BRONZE_LIT[2], BRONZE_LIT[3], 1)
    b.under:SetPoint("BOTTOMLEFT", 6, -2); b.under:SetPoint("BOTTOMRIGHT", -6, -2); b.under:SetHeight(2)
    b.plate = Solid(b, "ARTWORK", BRONZE_HOVER[1], BRONZE_HOVER[2], BRONZE_HOVER[3], 0.14)
    b.plate:SetAllPoints(); b.plate:Hide()
    return b
  end
  f.tabLog = Tab("My Log", nil, 0, nil, 62)
  f.tabLog:SetPoint("RIGHT", close, "LEFT", -8, 0)
  f.tabZone = Tab("Zones", nil, 0, nil, 54)
  f.tabZone:SetPoint("RIGHT", f.tabLog, "LEFT", -4, 0)
  f.tabChain = Tab("Chains", nil, 0, nil, 58)
  f.tabChain:SetPoint("RIGHT", f.tabZone, "LEFT", -4, 0)
  f.tabChain:SetScript("OnClick", function() UI.ShowChains() end)
  f.tabZone:SetScript("OnClick", function() UI.ShowZones() end)
  f.tabLog:SetScript("OnClick", function() UI.ShowLog() end)

  local back = Button(f, "Back", 52, 24)
  back:SetPoint("RIGHT", f.tabChain, "LEFT", -8, 0)
  back:SetScript("OnClick", function()
    if zoneMode then -- in a zone: back to the list of zones
      zoneIndex, zonePick, zoneNotice, popupFor = true, nil, nil, nil
      Render()
      return
    end
    if not backTo then return end
    current, results, notice = nil, backTo.results, backTo.notice
    backTo = nil
    Render()
  end)
  back:Hide()
  f.back = back

  local box = CreateFrame("EditBox", nil, f, "BackdropTemplate")
  box:SetSize(WIDTH - 28, 26)
  box:SetPoint("TOPLEFT", 14, -60)
  box:SetAutoFocus(false)
  box:SetFontObject("ChatFontNormal")
  box:SetTextInsets(28, 8, 0, 0)
  local mag = box:CreateTexture(nil, "OVERLAY")
  mag:SetTexture("Interface\\Common\\UI-Searchbox-Icon")
  mag:SetSize(14, 14)
  mag:SetPoint("LEFT", 9, -1)
  mag:SetVertexColor(0.8, 0.7, 0.5, 0.9)
  Boxed(box, true)
  box:SetBackdropColor(0, 0, 0, 0.5)
  box:SetScript("OnEscapePressed", function(self) if f.hideSuggest then f.hideSuggest() end; self:ClearFocus() end)
  box:SetScript("OnEnterPressed", function(self)
    local s = f.suggest
    if zoneMode and s and s:IsShown() and s.sel and s.list then -- a suggestion is highlighted: that one
      local z = s.list[s.sel]
      self:SetText(z.name)
      self:ClearFocus()
      f.hideSuggest()
      return UI.OpenZoneText(z.name)
    end
    if f.hideSuggest then f.hideSuggest() end
    self:ClearFocus()
    if logMode then return end -- (the log is filtered as you type)
    if zoneMode then UI.OpenZoneText(self:GetText()) else UI.OpenText(self:GetText()) end
  end)
  f.box = box

  local hint = Text(box, "GameFontDisableSmall")
  hint:SetPoint("LEFT", 28, 0)
  hint:SetText("Quest ID, link or name")
  f.hint = hint

  -- Zone name autocomplete (Zones tab): a list under the box. Arrows move in it, Tab completes, Enter picks.
  local SUGGEST_ROW = 20
  local suggest = CreateFrame("Frame", nil, f, "BackdropTemplate")
  suggest:SetFrameLevel(f:GetFrameLevel() + 50)
  suggest:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 0, -2)
  Boxed(suggest, true)
  suggest:SetBackdropColor(0.05, 0.05, 0.05, 0.98)
  suggest.rows = {}
  suggest:Hide()
  f.suggest = suggest
  local function HideSuggest() suggest:Hide(); suggest.sel, suggest.list = nil, nil end
  f.hideSuggest = HideSuggest
  local function Highlight()
    for i, r in ipairs(suggest.rows) do r.hl:SetShown(i == suggest.sel) end
  end
  local function PickZone(z)
    box:SetText(z.name)
    box:ClearFocus()
    HideSuggest()
    UI.OpenZoneText(z.name)
  end
  local function UpdateSuggest()
    local Z = Zones or ns.Zones
    local text = box:GetText()
    local list = (zoneMode and text ~= "" and Z and Z.state == "ready") and Z.Suggest(text, 8) or {}
    if #list == 0 then return HideSuggest() end
    suggest.list, suggest.sel = list, nil
    for i, z in ipairs(list) do
      local r = suggest.rows[i]
      if not r then
        r = CreateFrame("Button", nil, suggest)
        r:SetHeight(SUGGEST_ROW)
        r:SetPoint("TOPLEFT", 4, -4 - (i - 1) * SUGGEST_ROW)
        r:SetPoint("TOPRIGHT", -4, -4 - (i - 1) * SUGGEST_ROW)
        r.hl = Solid(r, "BACKGROUND", BRONZE_HOVER[1], BRONZE_HOVER[2], BRONZE_HOVER[3], 0.3)
        r.hl:SetAllPoints(); r.hl:Hide()
        r.text = Text(r, "GameFontHighlightSmall")
        r.text:SetPoint("LEFT", 6, 0); r.text:SetWidth(170)
        r.index = i
        r:SetScript("OnClick", function(self) PickZone(self.zone) end)
        r:SetScript("OnEnter", function(self) suggest.sel = self.index; Highlight() end)
        suggest.rows[i] = r
      end
      r.zone = z
      r.text:SetText(z.name .. "  |cff808080" .. z.count .. "|r")
      r:Show()
    end
    for i = #list + 1, #suggest.rows do suggest.rows[i]:Hide() end
    suggest:SetSize(190, 8 + #list * SUGGEST_ROW)
    suggest:Show()
    Highlight()
  end
  box:SetScript("OnTextChanged", function(self, userInput)
    hint:SetShown(self:GetText() == "")
    if logMode then
      HideSuggest()
      if userInput then logFilter = self:GetText(); Render() end
    elseif not zoneMode then HideSuggest() elseif userInput then UpdateSuggest() end
  end)
  box:SetScript("OnArrowPressed", function(_, key)
    if not (suggest:IsShown() and suggest.list) then return end
    local n = #suggest.list
    if key == "DOWN" then suggest.sel = ((suggest.sel or 0) % n) + 1
    elseif key == "UP" then suggest.sel = ((suggest.sel or 1) - 2) % n + 1 end
    Highlight()
  end)
  box:SetScript("OnTabPressed", function(self)
    if not (suggest:IsShown() and suggest.list) then return end
    local z = suggest.list[suggest.sel or 1]
    self:SetText(z.name)
    self:SetCursorPosition(#z.name)
    UpdateSuggest()
  end)
  box:SetScript("OnEditFocusLost", function(self)
    -- a click on a suggestion has finished by then; anything else closes the list
    if C_Timer and C_Timer.After then C_Timer.After(0.2, function() if not self:HasFocus() then HideSuggest() end end) else HideSuggest() end
  end)

  -- By type | By giver | Breadcrumbs: how the Zones tab lists its quests (only shown there), right of the search box.
  local toggle = CreateFrame("Frame", nil, f)
  toggle:SetSize(TOGGLE_W, 26)
  toggle:SetPoint("TOPLEFT", f, "TOPLEFT", WIDTH - 14 - TOGGLE_W, -60)
  f.toggle = toggle
  f.tabType = Tab("By type", nil, 0, toggle, 50)
  f.tabType:SetPoint("LEFT", toggle, "LEFT", 0, 0)
  f.tabGiver = Tab("By giver", f.tabType, 3, toggle, 56)
  f.tabCrumbs = Tab("Breadcrumbs", f.tabGiver, 3, toggle, 80)

  -- List | Graph: how the chain is drawn (only shown with a chain), right of the search box
  local views = CreateFrame("Frame", nil, f)
  views:SetSize(VIEW_W, 26)
  views:SetPoint("TOPLEFT", f, "TOPLEFT", WIDTH - 14 - VIEW_W, -60)
  views:Hide()
  f.viewToggle = views
  f.tabList = Tab("List", nil, 0, views, 60)
  f.tabList:SetPoint("LEFT", views, "LEFT", 0, 0)
  f.tabGraph = Tab("Graph", f.tabList, 3, views, 63)
  f.tabList:SetScript("OnClick", function() DB().chainView = "list"; Render() end)
  f.tabGraph:SetScript("OnClick", function() DB().chainView = "graph"; Render() end)
  f.tabType:SetScript("OnClick", function()
    if zoneMode then ZS().byGiver = false; ZS().crumbs = false; Render() end
  end)
  f.tabGiver:SetScript("OnClick", function()
    if zoneMode then ZS().byGiver = true; ZS().crumbs = false; Render() end
  end)
  f.tabCrumbs:SetScript("OnClick", function()
    if zoneMode then ZS().crumbs = true; Render() end
  end)

  local well = CreateFrame("Frame", nil, f, "BackdropTemplate")
  well:SetPoint("TOPLEFT", 10, -TOP_BODY)
  well:SetPoint("BOTTOMLEFT", 10, 10)
  well:SetWidth(WIDTH - 20)
  f.well = well
  Boxed(well, true)
  well:SetBackdropColor(0.02, 0.015, 0.01, 0.5)
  scroll = CreateFrame("ScrollFrame", nil, f)
  scroll:SetPoint("TOPLEFT", well, "TOPLEFT", 8, -8)
  scroll:SetPoint("BOTTOMRIGHT", well, "BOTTOMRIGHT", -20, 8)
  scroll:SetScript("OnVerticalScroll", UpdateThumb)

  -- the graph view of a chain: drag to pan, Ctrl+wheel to zoom, Shift+wheel sideways, wheel up and down
  gscroll = CreateFrame("ScrollFrame", nil, f)
  gscroll:SetPoint("TOPLEFT", well, "TOPLEFT", 6, -6)
  gscroll:SetPoint("BOTTOMRIGHT", well, "BOTTOMRIGHT", -6, 6)
  gscroll:EnableMouse(true)
  gscroll:EnableMouseWheel(true)
  gcontent = CreateFrame("Frame", nil, gscroll)
  gcontent:SetSize(1, 1)
  gscroll:SetScrollChild(gcontent)
  gcanvas = CreateFrame("Frame", nil, gcontent)
  gcanvas:SetPoint("TOPLEFT", gcontent, "TOPLEFT", 0, 0)
  gcanvas:SetSize(1, 1)
  gscroll:Hide()
  local function SetZoom(z)
    graphZoom = math.min(GZ_MAX, math.max(GZ_MIN, z))
    Render()
  end
  gscroll:SetScript("OnMouseWheel", function(self, delta)
    if IsControlKeyDown and IsControlKeyDown() then
      SetZoom((graphZoom or f.gzoom.value or 1) * (delta > 0 and 1.15 or 1 / 1.15))
    elseif (IsAltKeyDown and IsAltKeyDown()) or (IsShiftKeyDown and IsShiftKeyDown()) then
      GraphScrollTo(self:GetHorizontalScroll() - delta * 60, self:GetVerticalScroll())
    else
      GraphScrollTo(self:GetHorizontalScroll(), self:GetVerticalScroll() - delta * 60)
    end
  end)
  local pan -- { x, y, h, v } where the drag began
  local function Panning(self)
    if IsMouseButtonDown and not IsMouseButtonDown("LeftButton") then
      pan = nil
      self:SetScript("OnUpdate", nil)
      return
    end
    local x, y = GetCursorPosition()
    local s = self:GetEffectiveScale()
    GraphScrollTo(pan.h - (x - pan.x) / s, pan.v + (y - pan.y) / s)
  end
  gscroll:SetScript("OnMouseDown", function(self, button)
    if button ~= "LeftButton" then return end
    if f.box then f.box:ClearFocus() end
    local x, y = GetCursorPosition()
    pan = { x = x, y = y, h = self:GetHorizontalScroll(), v = self:GetVerticalScroll() }
    self:SetScript("OnUpdate", Panning)
  end)
  gscroll:SetScript("OnMouseUp", function(self) pan = nil; self:SetScript("OnUpdate", nil) end)
  -- zoom buttons, bottom left of the well
  local gz = CreateFrame("Frame", nil, f)
  gz:SetSize(440, 22)
  gz:SetPoint("BOTTOMLEFT", well, "BOTTOMLEFT", 10, 8)
  gz:SetFrameLevel(f:GetFrameLevel() + 20)
  gz.out = Button(gz, "-", 24, 22)
  gz.out:SetPoint("LEFT", 0, 0)
  gz.out:SetScript("OnClick", function() SetZoom((graphZoom or gz.value or 1) / 1.15) end)
  gz.inn = Button(gz, "+", 24, 22)
  gz.inn:SetPoint("LEFT", gz.out, "RIGHT", 4, 0)
  gz.inn:SetScript("OnClick", function() SetZoom((graphZoom or gz.value or 1) * 1.15) end)
  gz.fit = Button(gz, "Fit", 40, 22)
  gz.fit:SetPoint("LEFT", gz.inn, "RIGHT", 4, 0)
  gz.fit:SetScript("OnClick", function() graphZoom = nil; Render() end)
  gz.hint = Text(gz, "GameFontDisableSmall")
  gz.hint:SetPoint("LEFT", gz.fit, "RIGHT", 12, 0)
  gz.hint:SetWidth(330)
  gz.hint:SetText("Drag: pan   ·   Ctrl+scroll: zoom in / out   ·   Alt+scroll: sideways")
  gz:Hide()
  f.gzoom = gz
  f.gscroll, f.gcanvas, f.gcontent = gscroll, gcanvas, gcontent
  content = CreateFrame("Frame", nil, scroll)
  content:SetSize(CONTENT_W, 1)
  scroll:SetScrollChild(content)
  f.scroll, f.content = scroll, content
  local function ScrollTo(v)
    local max = math.max(0, content:GetHeight() - scroll:GetHeight())
    scroll:SetVerticalScroll(math.min(max, math.max(0, v)))
  end
  local function Wheel(_, delta) ScrollTo(scroll:GetVerticalScroll() - delta * 48) end
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", Wheel)

  -- the scroll bar: a track you can click, and a thumb you can drag
  local bar = CreateFrame("Frame", nil, f)
  bar:SetWidth(12)
  bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 4, 0)
  bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 4, 0)
  bar:EnableMouse(true)
  bar:EnableMouseWheel(true)
  bar:SetScript("OnMouseWheel", Wheel)
  f.bar = bar
  f.track = Solid(bar, "BACKGROUND", BRONZE_MUTED[1], BRONZE_MUTED[2], BRONZE_MUTED[3], 0.25)
  f.track:SetWidth(4)
  f.track:SetPoint("TOP"); f.track:SetPoint("BOTTOM")
  local thumb = CreateFrame("Button", nil, bar)
  thumb:SetWidth(12)
  thumb:EnableMouse(true)
  thumb.tex = Solid(thumb, "OVERLAY", BRONZE[1], BRONZE[2], BRONZE[3], 1)
  thumb.tex:SetWidth(6)
  thumb.tex:SetPoint("TOP"); thumb.tex:SetPoint("BOTTOM")
  f.thumb = thumb
  bar:Hide()

  local grab, over -- where in the thumb it was taken (px from its top); whether the mouse is over it
  local function PaintThumb()
    local c = grab and BRONZE_LIT or over and BRONZE_HOVER or BRONZE
    thumb.tex:SetVertexColor(c[1], c[2], c[3], 1)
  end
  local function CursorBelowTop() -- px from the top of the bar to the mouse
    local _, y = GetCursorPosition()
    return bar:GetTop() - y / bar:GetEffectiveScale()
  end
  local function Release()
    grab = nil
    bar:SetScript("OnUpdate", nil)
    PaintThumb()
  end
  local function Follow()
    if IsMouseButtonDown and not IsMouseButtonDown("LeftButton") then return Release() end -- let go outside the window
    ScrollTo(Core.ScrollForThumb(CursorBelowTop() - grab, thumb:GetHeight(), content:GetHeight(), scroll:GetHeight()))
  end
  local function Grab(at)
    grab = at
    bar:SetScript("OnUpdate", Follow)
    PaintThumb()
  end
  f.releaseBar = Release
  thumb:SetScript("OnEnter", function() over = true; PaintThumb() end)
  thumb:SetScript("OnLeave", function() over = nil; PaintThumb() end)
  thumb:SetScript("OnMouseDown", function(_, button)
    if button ~= "LeftButton" then return end
    Grab(CursorBelowTop() - (bar:GetTop() - thumb:GetTop()))
  end)
  thumb:SetScript("OnMouseUp", Release)
  -- a click on the empty track puts the thumb under the mouse, and carries on as a drag
  bar:SetScript("OnMouseDown", function(_, button)
    if button ~= "LeftButton" then return end
    Grab(thumb:GetHeight() / 2)
    Follow()
  end)
  bar:SetScript("OnMouseUp", Release)

  -- Escape closes the window the way Blizzard's own windows close. The window never takes keyboard
  -- input itself: SetPropagateKeyboardInput is blocked in combat, so a window that listens for keys
  -- can swallow WASD there.
  if UISpecialFrames then table.insert(UISpecialFrames, "QuestThreadFrame") end
  -- Typing focus (the search box) also swallows WASD, so let go of it when combat starts.
  f:RegisterEvent("PLAYER_REGEN_DISABLED")
  f:RegisterEvent("QUEST_LOG_UPDATE")
  f:SetScript("OnEvent", function(_, event)
    if event == "QUEST_LOG_UPDATE" then
      -- My Log follows your quest log (it fires a lot: take it again shortly, once)
      if logMode and f:IsShown() and not logPending then
        logPending = true
        local function again() logPending = false; if logMode and f:IsShown() then Render() end end
        if C_Timer and C_Timer.After then C_Timer.After(0.3, again) else again() end
      end
      return
    end
    box:ClearFocus()
  end)
  -- A click anywhere else takes the typing focus off the search box, or WASD would type into it.
  f:SetScript("OnMouseDown", function() box:ClearFocus() end)
  -- Closing the window ends any hover, so the key listener and the link box go with it.
  f:SetScript("OnHide", function() hoverRow = nil; ListenForKeys(false); HideLink(); f.hideSuggest(); f.releaseBar() end)
  -- Every time the window opens the search box starts empty (what you typed last time is not what you want now).
  f:SetScript("OnShow", function()
    Normalize(f)
    box:SetText("")
    logFilter = nil
    hint:SetShown(true)
    box:ClearFocus()
  end)
  f:Hide()
  frame = f
  return f
end

-- The tabs, the box's hint and the toggle follow the mode.
local function SetModeControls()
  if not frame then return end
  frame.hideSuggest()
  Lit(frame.tabChain, not zoneMode and not logMode)
  Lit(frame.tabZone, zoneMode)
  Lit(frame.tabLog, logMode)
  frame.box:SetWidth(zoneMode and (WIDTH - 28 - TOGGLE_W - 8) or (WIDTH - 28))
  frame.hint:SetText(zoneMode and "Zone name" or (logMode and "Filter your quest log" or "Quest ID, link or name"))
  if (lastLogMode or false) ~= (logMode or false) then -- the box holds the filter in My Log, something else elsewhere
    frame.box:SetText(""); logFilter = nil
  end
  lastLogMode = logMode
  frame.toggle:SetShown(zoneMode and true or false)
  SyncGroupTabs()
end

-- showObjectives: a click on a quest, which also opens the objectives popup for it.
function UI.Open(questId, keepBack, showObjectives)
  Create()
  local fresh = not frame:IsShown()
  if questId then zoneMode, logMode = false, false end
  SetModeControls()
  current = questId and tonumber(questId) or current
  popupFor = showObjectives and current or nil
  notice, results = nil, nil
  if not keepBack then backTo = nil end
  if fresh and zoneMode then wantHere, zonePick, zoneNotice = true, nil, nil end -- the Zones tab opens on your own area
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
  current, results, notice, backTo, popupFor = nil, hits, ("%d quests share that icon."):format(#ids), nil, nil
  zoneMode, logMode = false, false
  SetModeControls()
  frame:Show()
  frame:Raise()
  Data.Ensure(Render)
  if Data.state == "building" then WatchBuild() end
  Render()
end

function UI.OpenText(text)
  Create()
  local id, msg, hits = Data.Resolve(text)
  backTo, popupFor = nil, nil
  zoneMode, logMode = false, false
  SetModeControls()
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

-- The Chains tab.
function UI.ShowChains()
  Create()
  zoneMode, logMode, zonePick, popupFor = false, false, nil, nil
  SetModeControls()
  Render()
end

-- The Zones tab, on an area (or the one you left it on, or the one you stand in).
function UI.ShowZones(area)
  Create()
  Zones = Zones or ns.Zones
  local fresh = not frame:IsShown()
  zoneMode, logMode, zonePick, zoneNotice, popupFor = true, false, nil, nil, nil
  if area then
    ZS().area, zoneIndex = area, false
  elseif fresh then
    wantHere = true -- the area you are in
  else
    zoneIndex = true -- a click on the Zones tab: the list of all zones
  end
  SetModeControls()
  frame:Show()
  frame:Raise()
  Zones.Ensure(Render)
  if Data.state == "building" or Zones.state == "building" then WatchBuild() end
  Render()
end

-- Typed into the box on the Zones tab: nothing = the zone you stand in; one match opens it; several make a list.
function UI.OpenZoneText(text)
  Create()
  Zones = Zones or ns.Zones
  text = tostring(text or ""):match("^%s*(.-)%s*$")
  zoneMode, logMode, zoneIndex, popupFor = true, false, false, nil
  SetModeControls()
  frame:Show()
  frame:Raise()
  local function apply()
    zonePick, zoneNotice = nil, nil
    if text == "" then
      local a = Zones.CurrentArea()
      if a then ZS().area = a else zoneNotice = "Could not tell which zone you are in." end
    else
      local hits = Zones.Find(text)
      if #hits == 0 then
        zoneNotice = 'No zone named "' .. text .. '".'
      elseif #hits == 1 or hits[1].name:lower() == text:lower() then
        ZS().area = hits[1].area
      else
        zonePick, zoneNotice = hits, ('%d zones match "%s".'):format(#hits, text)
      end
    end
    Render()
  end
  Zones.Ensure(apply)
  if Data.state == "building" or Zones.state == "building" then WatchBuild() end
  Render()
end

-- The My Log tab: your own quest log.
function UI.ShowLog()
  Create()
  zoneMode, logMode, zonePick, popupFor = false, true, nil, nil
  SetModeControls()
  frame:Show()
  frame:Raise()
  Data.Ensure(Render)
  if Data.state == "building" then WatchBuild() end
  Render()
end

function UI.IsLogMode() return logMode and true or false end

function UI.IsZoneMode() return zoneMode and true or false end

-- Window size: 0.6 to 1.6, remembered. Returns the value used.
function UI.SetScale(v)
  v = math.min(1.6, math.max(0.6, tonumber(v) or 1))
  DB().scale = v
  if frame then frame:SetScale(v); FitWidth() end
  return v
end

-- Back to the middle of the screen at normal size.
function UI.Reset()
  DB().pos, DB().scale = nil, nil
  if frame then
    frame:SetScale(1)
    PlaceDefault(frame)
    FitWidth()
  end
end

function UI.IsShown()
  return frame ~= nil and frame:IsShown()
end

-- The look-and-feel helpers, for the panel beside the map (MapPanel.lua).
UI.Widgets = { Button = Button, Boxed = Boxed, Solid = Solid, Text = Text, LevelTag = LevelTag, Crumb = Crumb,
  StatusCell = StatusCell, SetCell = SetCell }

-- Closes the window if it is up; otherwise opens it on the Zones tab, on the area you are standing in.
function UI.Toggle()
  Create()
  if frame:IsShown() then frame:Hide() else UI.ShowZones() end
end
