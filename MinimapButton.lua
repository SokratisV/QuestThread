-- A button on the minimap that opens and closes the chain window. Drag it to move it around the minimap
-- (the spot is remembered); /qthread minimap hides or shows it. It is its own frame under the Minimap:
-- no script is added to the minimap itself.
local ADDON, ns = ...
local Core = ns.Core
local MB = {}
ns.MinimapButton = MB

local DEFAULT_ANGLE = math.rad(215) -- lower left, where there is usually room
local button, menu

local function Settings()
  QuestThreadDB = QuestThreadDB or {}
  QuestThreadDB.minimap = QuestThreadDB.minimap or {}
  return QuestThreadDB.minimap
end

local function Place()
  if not button then return end
  local shape = GetMinimapShape and GetMinimapShape() or "ROUND"
  local x, y = Core.MinimapOffset(Settings().angle or DEFAULT_ANGLE, Minimap:GetWidth(), Minimap:GetHeight(), shape)
  button:ClearAllPoints()
  button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- While dragging, the button follows the cursor's direction from the minimap's centre.
local function FollowCursor()
  local mx, my = Minimap:GetCenter()
  local cx, cy = GetCursorPosition()
  local scale = Minimap:GetEffectiveScale()
  if not (mx and my and cx and cy and scale and scale > 0) then return end
  Settings().angle = math.atan2(cy / scale - my, cx / scale - mx)
  Place()
end

local function Tooltip(self)
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:SetText("QuestThread")
  GameTooltip:AddLine("Left-click: open or close the chain window", 1, 1, 1)
  GameTooltip:AddLine("Drag: move this button around the minimap", 0.7, 0.7, 0.7)
  GameTooltip:AddLine("Right-click: hide this button", 0.7, 0.7, 0.7)
  GameTooltip:Show()
end

local SHOW_AGAIN = "Minimap button hidden. Type /qthread minimap to show it again."

local function HideMenu()
  if menu then menu:Hide() end
end

-- A one-item menu of our own (no Blizzard dropdown, so nothing of the game's is touched). It closes on a
-- click anywhere else, on Escape, and when the button is dragged.
local function BuildMenu()
  menu = CreateFrame("Frame", "QuestThreadMinimapMenu", UIParent)
  menu:SetSize(170, 26)
  menu:SetFrameStrata("DIALOG")
  menu:SetClampedToScreen(true)
  menu.bg = menu:CreateTexture(nil, "BACKGROUND")
  menu.bg:SetAllPoints()
  menu.bg:SetColorTexture(0.05, 0.05, 0.07, 0.95)
  menu.item = CreateFrame("Button", nil, menu)
  menu.item:SetAllPoints()
  menu.item:SetHighlightTexture("Interface\QuestFrame\UI-QuestTitleHighlight")
  menu.item.text = menu.item:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  menu.item.text:SetPoint("LEFT", 10, 0)
  menu.item.text:SetText("Hide minimap button")
  menu.item:SetScript("OnClick", function()
    HideMenu()
    MB.Hide()
  end)
  menu:SetScript("OnUpdate", function(self)
    local down = IsMouseButtonDown("LeftButton") or IsMouseButtonDown("RightButton")
    if down and not self:IsMouseOver() and not (button and button:IsMouseOver()) then self:Hide() end
  end)
  menu:Hide()
  if UISpecialFrames then table.insert(UISpecialFrames, "QuestThreadMinimapMenu") end
end

local function ToggleMenu()
  if not menu then BuildMenu() end
  if menu:IsShown() then return menu:Hide() end
  menu:ClearAllPoints()
  menu:SetPoint("TOPRIGHT", button, "BOTTOMRIGHT", 0, -2)
  GameTooltip:Hide()
  menu:Show()
end

-- `onClick` is what a left click does (Main.lua knows which quest is open in the quest log).
function MB.Init(onClick)
  if button or not Minimap then return end
  button = ns.MakeChainButton(Minimap, 31, 31, "QuestThreadMinimapButton")
  button:SetFrameStrata("MEDIUM")
  button:SetFrameLevel(Minimap:GetFrameLevel() + 8)
  button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  button:RegisterForDrag("LeftButton")
  button:SetScript("OnClick", function(_, mouse)
    if mouse == "RightButton" then ToggleMenu() else HideMenu(); onClick() end
  end)
  button:SetScript("OnEnter", Tooltip)
  button:SetScript("OnLeave", function() GameTooltip:Hide() end)
  button:SetScript("OnDragStart", function(self)
    HideMenu()
    GameTooltip:Hide()
    self:SetScript("OnUpdate", FollowCursor)
  end)
  button:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
    FollowCursor()
  end)
  Place()
  button:SetShown(not Settings().hide)
end

-- Hide from the button's own menu: say how to get it back.
function MB.Hide()
  Settings().hide = true
  if button then button:Hide() end
  print("|cffffd100QuestThread:|r " .. SHOW_AGAIN)
end

function MB.IsHidden()
  return Settings().hide and true or false
end

-- Hides or shows the button; returns true when it is now shown.
function MB.Toggle()
  local s = Settings()
  s.hide = not s.hide
  if button then button:SetShown(not s.hide) end
  HideMenu()
  return not s.hide
end

-- Back to the default spot, and shown.
function MB.Reset()
  local s = Settings()
  s.angle, s.hide = nil, nil
  if button then Place(); button:Show() end
end
