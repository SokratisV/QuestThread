"""Offline tests for QuestThread, on a real Lua 5.1 runtime (lupa.lua51), not the game.

  node tests/dump-questiedb.js <AddOns> <data.json>      (once, reads the installed QuestieDB)
  python -I tests/run.py <data.json> [--mutate]

--mutate edits Core.lua in memory (breaks the XP scaling and the chain walk); the tests must then FAIL.
Covers Core on synthetic graphs, Core on the real Defias Brotherhood chain, and a UI smoke run with
stub frames (catches nil errors in this addon's own code, not WoW API semantics).
"""
import json
import re
import os
import struct
import sys

from lupa.lua51 import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
data_path = sys.argv[1]
mutate = "--mutate" in sys.argv

with open(data_path, encoding="utf-8") as f:
    raw = json.load(f)

lua = LuaRuntime(unpack_returned_tuples=True)
failures = []


def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + (("  " + str(detail)) if detail and not cond else ""))
    if not cond:
        failures.append(name)


def source(name):
    text = open(os.path.join(ROOT, name), encoding="utf-8").read()
    if mutate and name == "Core.lua":
        text = text.replace("if mult < 1 then mult = 1 elseif mult > 10 then mult = 10 end", "")
        text = text.replace("if head <= #queue", "if false")  # never reached; chain walk unchanged below
        text = text.replace("local MAX_COMPONENT = 80", "local MAX_COMPONENT = 3")
    return text


loader = lua.eval("function(src, name, ns) return assert(loadstring(src, name))('QuestThread', ns) end")
ns = lua.table()
for fn in ("Core.lua",):
    loader(source(fn), fn, ns)
Core = ns.Core

# ---- Core: synthetic graphs ----
def chain_of(edges, start, extra=None):
    idx = Core.NewIndex()
    ids = set()
    for a, b in edges:
        ids.update((a, b))
    for i in sorted(ids):
        pre = [a for a, b in edges if b == i]
        Core.AddQuest(idx, i, lua.table_from({"pre": lua.table_from(pre)}) if pre else lua.table())
    info = lua.eval("function(id) return {name='Q'..id} end")
    return Core.Chain(idx, start, info)

c = chain_of([(1, 2), (2, 3), (3, 4)], 3)
check("linear chain: 4 parts", c.parts == 4 and c.quests == 4, (c.parts, c.quests))
check("linear chain: current is step 3", c.currentLayer == 3, c.currentLayer)
c = chain_of([(1, 2), (1, 3), (2, 4), (3, 4)], 4)
check("diamond: 3 steps, 4 quests, middle step has 2 branches", c.parts == 3 and c.quests == 4 and len(c.layers[2]) == 2)
c = chain_of([(1, 2), (2, 1)], 1)
check("cycle does not hang and keeps both quests", c.quests == 2)
check("unknown quest returns nil", chain_of([(1, 2)], 99) is None)
big = [(i, i + 1) for i in range(1, 200)]
c = chain_of(big, 100)
check("huge component is truncated", c.truncated and c.quests == 80, (c.truncated, c.quests))

# breadcrumb is excluded from the chain and listed separately
idx = Core.NewIndex()
Core.AddQuest(idx, 10, lua.table_from({"bcs": lua.table_from([11])}))
Core.AddQuest(idx, 11, lua.table_from({"bcFor": 10, "child": lua.table_from([10])}))
c = Core.Chain(idx, 10, lua.eval("function(id) return {} end"))
check("breadcrumb excluded, reported", c.quests == 1 and len(c.breadcrumbs) == 1 and c.breadcrumbs[1].id == 11)

# XP scaling: equal level = base (rounded), far below the quest = floor at 10%, far above = full
check("xp equal level", Core.ScaledXp(1350, 18, 18) == 1350, Core.ScaledXp(1350, 18, 18))
check("xp far above quest level scales down to 10% (rounded)", Core.ScaledXp(1350, 18, 50) == 140, Core.ScaledXp(1350, 18, 50))
check("xp quest 5 levels above you capped at 100%", Core.ScaledXp(1000, 25, 20) == 1000, Core.ScaledXp(1000, 25, 20))
check("xp missing data is 0", Core.ScaledXp(None, None, 10) == 0)
check("parse id / link / name",
      Core.ParseRef("325") == 325 and Core.ParseRef("|cffffff00|Hquest:55:30|h[Morbent Fel]|h|r") == 55
      and Core.ParseRef("wowhead.com/forever/quest=7") == 7 and Core.ParseRef("Morbent Fel")[0] is None)

# ---- Core on the real data: the Defias Brotherhood chain ----
quests = {int(k): v for k, v in raw["quests"].items()}
idx = Core.NewIndex()
for qid, q in quests.items():
    f = {}
    for key in ("pre", "preS", "child", "bcs"):
        if q.get(key):
            f[key] = lua.table_from(q[key])
    if q.get("next"):
        f["next"] = q["next"]
    if q.get("bcFor"):
        f["bcFor"] = q["bcFor"]
    Core.AddQuest(idx, qid, lua.table_from(f))
for item, qs in raw["itemQuests"].items():
    Core.AddItemRewards(idx, int(item), lua.table_from(qs))
Core.FinishRewards(idx)
xp = {int(k): v for k, v in raw["xp"].items()}


def info(qid):
    q = quests.get(qid, {})
    row = xp.get(qid)
    t = {"name": q.get("name")}
    if row:
        t["xpLevel"], t["xpBase"] = row
    return lua.table_from(t)


lua_info = lua.eval("function(f) return function(id) return f(id) end end")(info)
c = Core.Chain(idx, 65, lua_info)
check("Defias chain: 7 steps, 8 quests", c.parts == 7 and c.quests == 8, (c.parts, c.quests))
total = 0
for layer in c.layers.values():
    for e in layer.values():
        total += Core.ScaledXp(e.xpBase, e.xpLevel, None)
check("Defias chain: total XP at quest level is 9940", total == 9940, total)
last = c.layers[7]
check("Defias part 7 has its 3 reward items", any(list(e["items"].values()) == [2041, 2042, 6087] for e in last.values()))
check("starting from the last quest reaches the same chain", Core.Chain(idx, 166, lua_info).quests == 8)

# ---- UI smoke run with stubs ----
env = lua.eval("""
function(quests, items)
  local sets = {}
  local function stub()
    local o = { _text = "", _shown = false, _scripts = {} }
    sets[#sets + 1] = o
    local m = {}
    function m.SetText(s, t) s._text = t end
    function m.GetText(s) return s._text end
    function m.Show(s) local was = s._shown; s._shown = true; if not was and s._scripts.OnShow then s._scripts.OnShow(s) end end
    function m.Hide(s) s._shown = false end
    function m.SetShown(s, v) s._shown = v and true or false end
    function m.EnableMouse(s, v) s._mouse = v end
    function m.IsShown(s) return s._shown end
    function m.IsVisible(s) return true end
    function m.SetScript(s, k, fn) s._scripts[k] = fn end
    function m.HookScript(s, k, fn) s._scripts["hook" .. k] = fn end
    function m.GetScript(s, k) return s._scripts[k] end
    function m.GetFrameLevel(s) return s._lvl or 1 end
    function m.SetFrameLevel(s, l) s._lvl = l end
    function m.SetHeight(s, h) s._h = h end
    function m.SetWidth(s, w) s._w2 = w end
    function m.SetSize(s, w, h) s._size = { w, h } end
    function m.EnableKeyboard(s, v) s._kb = v end
    function m.ClearFocus(s) s._cleared = (s._cleared or 0) + 1 end
    function m.SetPropagateKeyboardInput(s, v) s._prop = v end
    function m.SetTextColor(s, r, g, b) s._color = { r, g, b } end
    function m.GetStringWidth(s) return 80 end
    function m.RegisterEvent(s, e) s._events = s._events or {}; s._events[e] = true end
    function m.SetParent(s, p) s._parent = p end
    function m.SetFocus(s) s._focused = true end
    function m.HighlightText(s) s._hl = true end
    function m.SetTexCoord(s, a, b, c, d) s._tc = { a, b, c, d } end
    function m.SetTexture(s, tx) s._tex = tx end
    function m.SetVertexColor(s, r, g, b, a) s._vc = { r, g, b, a } end
    function m.SetPoint(s, p, rel, a, x, y)
      s._pt = { p, rel, a, x, y }
      s._pts = s._pts or {}
      s._pts[#s._pts + 1] = s._pt
    end
    function m.ClearAllPoints(s) s._pts = {} end
    function m.GetWidth() return 400 end
    function m.GetHeight() return 300 end
    function m.GetVerticalScroll() return 0 end
    function m.GetPoint() return "CENTER", nil, "CENTER", 0, 0 end
    function m.CreateTexture() return stub() end
    function m.CreateLine() return stub() end
    function m.SetThickness(s, v) s._thick = v end
    function m.GetFont(s) return "Fonts\Test.ttf", 12, "" end
    function m.SetFont(s, file, size, flags) s._font = { file, size, flags } end
    function m.SetStartPoint(s, p, rel, x, y) s._start = { x, y } end
    function m.SetEndPoint(s, p, rel, x, y) s._end = { x, y } end
    function m.SetColorTexture(s, r, g, b, a) s._vc = { r, g, b, a } end
    function m.SetScale(s, v) s._scale = v end
    function m.SetHorizontalScroll(s, v) s._hs = v end
    function m.GetHorizontalScroll(s) return s._hs or 0 end
    function m.CreateFontString() return stub() end
    local mt = { __index = function(t, k) if m[k] then return m[k] end; if type(k) == "string" and k:match("^%u") then return function() end end end }
    return setmetatable(o, mt)
  end
  _G.CreateFrame = function(_, name) local f = stub(); f._name = name; return f end
  _G.stubs = sets
  _G.newStub = stub
  _G.testRows = {}
  _G.makeRow = function(id)
    local r = stub(); r.questID = id; r.GetObjectType = function() return "Button" end
    testRows[#testRows + 1] = r; return r
  end
  -- a row that has been laid out: 0..400 wide, a title at the left and (optionally) a "(Dungeon)" tag
  _G.makeLaidOutRow = function(id, tagLeft)
    local r = makeRow(id)
    r.GetLeft = function() return 0 end
    r.GetRight = function() return 400 end
    r.GetTop = function() return 0 end
    local function fs(text, left)
      local t = stub()
      t.GetObjectType = function() return "FontString" end
      t.GetText = function() return text end
      t.GetLeft = function() return left end
      t.GetTop = function() return -4 end
      t._shown = true
      return t
    end
    local title, tag = fs("[2] [31] Songblade Search", 20), tagLeft and fs("(Dungeon)", tagLeft) or nil
    r.GetRegions = function() return title, tag end
    r.GetChildren = function() end
    return r
  end
  _G.QuestScrollFrame = { ScrollBox = { ForEachFrame = function(self, fn) for _, r in ipairs(testRows) do fn(r) end end } }
  _G.UIParent = stub()
  _G.Minimap = stub()
  Minimap._mark = "minimap"
  Minimap.GetWidth = function() return 140 end
  Minimap.GetHeight = function() return 140 end
  Minimap.GetCenter = function() return 500, 500 end
  Minimap.GetEffectiveScale = function() return 1 end
  _G.testCursor, _G.testShape = { 500, 500 }, nil
  _G.GetCursorPosition = function() return testCursor[1], testCursor[2] end
  _G.GetMinimapShape = function() return testShape end
  _G.tipLines = {}
  _G.GameTooltip = stub()
  GameTooltip.AddLine = function(_, text) tipLines[#tipLines + 1] = text end
  _G.waypointCalls = {}
  _G.C_Map = {
    GetMapInfo = function() return { name = "Elwynn Forest" } end,
    GetAreaInfo = function(a) return ({ [1] = "Dun Morogh", [3] = "Badlands" })[a] end,
    OpenWorldMap = function(m) waypointCalls.opened = m end,
    CanSetUserWaypointOnMap = function() return true end,
    SetUserWaypoint = function(point) waypointCalls.point = point end,
  }
  _G.UiMapPoint = { CreateFromCoordinates = function(m, x, y) return { uiMapID = m, x = x, y = y } end }
  _G.C_SuperTrack = { SetSuperTrackedUserWaypoint = function(v) waypointCalls.track = v end }
  _G.NpcDB = {
    name = function(id) return id == 1000 and "Test Giver" or nil end,
    spawns = function(id) if id == 1000 then return { [12] = { { 42.5, 61.0 } }, [1] = { { 10, 10 } } } end end,
  }
  _G.ObjectDB = { name = function() return nil end, spawns = function() return nil end }
  _G.QuestMapFrame = stub()
  QuestMapFrame.DetailsFrame = stub()
  _G.testDetail = nil
  _G.QuestMapFrame_GetDetailQuestID = function() return _G.testDetail end
  _G.QuestMapFrame_ShowQuestDetails = function() end
  _G.hooks = {}
  _G.hooksecurefunc = function(a, b, c)
    if type(a) == "table" then
      local orig = a[b]
      a[b] = function(...) local r = orig(...); c(...); return r end
    else
      hooks[a] = b
    end
  end
  _G.C_Timer = { After = function(_, fn) fn() end }
  _G.testQid = 0
  _G.GetQuestID = function() return testQid end
  _G.QuestFrameDetailPanel = stub()
  _G.testShift, _G.testAlt = false, false
  _G.IsShiftKeyDown = function() return testShift end
  _G.testCtrl, _G.testMouse, _G.testFocus = false, false, nil
  _G.IsControlKeyDown = function() return testCtrl end
  _G.testCombat = false
  _G.InCombatLockdown = function() return testCombat end
  _G.IsAltKeyDown = function() return testAlt end
  _G.IsMouseButtonDown = function() return testMouse end
  _G.testFoci = nil
  _G.GetMouseFoci = function() return testFoci or { testFocus } end
  _G.makeIcon = function(name, data) local f = stub(); f._name = name; f.GetName = function() return name end; f.data = data; return f end
  _G.UnitLevel = function() return 20 end
  _G.GetMaxPlayerLevel = function() return 60 end
  _G.debugprofilestop = function() return os.clock() * 1000 end
  _G.testClientXp = {}
  _G.GetQuestLogRewardXP = function(id) local v = testClientXp[id]; if v then return v + 100, v end end
  _G.C_QuestLog = {
    IsQuestFlaggedCompleted = function(id) return id == 65 end,
    IsOnQuest = function(id) return id == 502 end,
    GetLogIndexForQuestID = function(id) return testClientXp[id] and 1 or nil end,
    GetNumQuestLogEntries = function() return 1 end,
    GetInfo = function(i) return { questID = 166, isHeader = false } end,
  }
  _G.C_Item = { GetItemIconByID = function(id) return 100 end }
  _G.C_Reputation = nil
  _G.GetFactionInfoByID = function(id) return "Faction" .. id end
  _G.SlashCmdList = {}
  _G.UISpecialFrames = {}
  _G.QuestThreadDB = nil
  _G.printed = {}
  _G.print = function(...) printed[#printed + 1] = table.concat({ ... }, " ") end
  local function ent(tab, field)
    return function(id) local q = tab[id]; return q and q[field] or nil end
  end
  _G.QuestDB = {
    GetAllIds = function() local l = {}; for id in pairs(quests) do l[#l + 1] = id end; table.sort(l); return l end,
    preQuestGroup = ent(quests, "pre"), preQuestSingle = ent(quests, "preS"), childQuests = ent(quests, "child"),
    nextQuestInChain = ent(quests, "next"), breadcrumbForQuestId = ent(quests, "bcFor"), breadcrumbs = ent(quests, "bcs"),
    name = ent(quests, "name"), reputationReward = ent(quests, "rep"),
    questLevel = function(id) return 30 end,
    specialFlags = function(id) if id == 500 or id == 504 or id == 166 then return 1 end return 0 end,
    requiredLevel = ent(quests, "reqLevel"),
    objectivesText = function(id) if id == 166 then return { "Kill things." } end end,
    startedBy = function(id) return { { 1000 } } end,
    finishedBy = function(id) return { { 1000 } } end,
    zoneOrSort = function(id) return 12 end,
    objectives = function(id) if id == 166 then return { { { 1000, "Giver text" } }, nil, { { 777, "Thing text" } } } end end,
    IdsByName = function(n) local l = {}; for id, q in pairs(quests) do if q.name == n then l[#l + 1] = id end end; table.sort(l); return l end,
  }
  _G.ItemDB = {
    GetAllIds = function() local l = {}; for id in pairs(items) do l[#l + 1] = id end; table.sort(l); return l end,
    questRewards = function(id) return items[id] end,
    name = function(id) return id == 777 and "Odd Thing" or nil end,
    npcDrops = function(id) if id == 777 then return { 1000 } end end,
  }
  _G.LibQuestieDB = { RequireContract = function() return true end, Support = { Get = function() return nil end } }
end
""")


def to_lua_quests():
    t = {}
    for qid, q in quests.items():
        row = {}
        for k, v in q.items():
            row[k] = lua.table_from(v, recursive=True) if isinstance(v, list) else v
        t[qid] = lua.table_from(row)
    return lua.table_from(t)


env(to_lua_quests(), lua.table_from({int(k): lua.table_from(v) for k, v in raw["itemQuests"].items()}))
xp_lua = lua.table_from({int(k): lua.table_from(v) for k, v in raw["xp"].items()})
lua.globals().LibQuestieDB.Support.Get = lua.eval("function(t) return function(name) if name == 'QuestXP' then return { db = t } end; if name == 'ZoneDB' then return { private = { areaIdToUiMapId = 'return { [12] = 1429, [1537] = 1455 }', areaIdToUiMapIdOverride = 'return { [0] = 0, [1537] = 0, [16] = 1447 }', uiMapIdToAreaId = { [1429] = 12 } } } end end end")(xp_lua)
ns2 = lua.table()
for fn in ("Core.lua", "Data.lua", "Zones.lua", "UI.lua", "QuestFrame.lua", "MapPanel.lua", "MinimapButton.lua", "Main.lua"):
    loader(source(fn), fn, ns2)

G = lua.globals()
real_zones_ensure = ns2.Zones.Ensure
ns2.Zones.Ensure = lua.eval("function() end")
G.SlashCmdList["QUESTTHREAD"]("166")
# drive the background build
drivers = [f for f in G.stubs.values() if f._scripts["OnUpdate"] is not None]
frames = 0
while ns2.Data.state == "building" and frames < 5000:
    for f in list(G.stubs.values()):
        fn = f._scripts["OnUpdate"]
        if fn is not None:
            fn(f, 0.016)
    frames += 1
check("index finishes building", ns2.Data.state == "ready", (ns2.Data.state, ns2.Data.error))
texts = [f._text for f in G.stubs.values() if f._text]
check("window title is the quest name", any(t == "The Defias Brotherhood" for t in texts))
win0 = next(f for f in G.stubs.values() if f._name == "QuestThreadFrame")
check("the brand row has the chain-link badge and the name, and a version field", win0.brand._text == "QuestThread" and "Chain.tga" in win0.logo._tex and win0.version is not None)
check("the group tabs have their full names", win0.tabCrumbs.text._text == "Breadcrumbs" and win0.tabGiver.text._text == "By giver" and win0.tabType.text._text == "By type")
check("every text in the window is one step (2 points) bigger than its game font", win0.brand._font is not None and win0.brand._font[2] == 14 and win0.tabZone.text._font[2] == 14 and win0.hint._font[2] == 14 and win0.box._font[2] == 14, (win0.brand._font, win0.hint._font))
check("the views are labelled Chains, Zones and My Log", win0.tabChain.text._text == "Chains" and win0.tabZone.text._text == "Zones" and win0.tabLog.text._text == "My Log")
check("the graph view says how to scroll sideways and zoom", "Ctrl+scroll: zoom" in win0.gzoom.hint._text and "Alt+scroll: sideways" in win0.gzoom.hint._text and win0.gzoom.hint is not None, win0.gzoom.hint._text)
check("stats line shows 8 quests", any("8 quests" in t for t in texts), [t for t in texts if "quests" in t])
G.SlashCmdList["QUESTTHREAD"]("Morbent Fel")
check("slash with a name resolves", any(t.startswith("Quest 55") or t == "Morbent Fel" for t in [f._text for f in G.stubs.values()]))
G.SlashCmdList["QUESTTHREAD"]("nonexistent quest name")
check("unknown name shows a message", any("No quest named" in f._text for f in G.stubs.values()))

# ---- current-position marker, layout, exact XP ----
G.testClientXp[166] = 2600
for f in G.stubs.values():
    f._text = ""
G.SlashCmdList["QUESTTHREAD"]("166")
all_texts = [f._text for f in G.stubs.values()]
check("current quest is marked 'You are here'", sum("You are here" in t for t in all_texts) == 1, sum("You are here" in t for t in all_texts))
check("a quest in the log shows the client's exact XP, others are estimates",
      "2,600 XP" in all_texts and any(t.startswith("~") and t.endswith(" XP") for t in all_texts))
check("stats line says the XP is for your level", any("at level 20" in t for t in all_texts))
rows = [f for f in G.stubs.values() if f._shown and f._h and f._pt and f.link is None and f._scripts["OnClick"] is not None and f._pt[5] is not None and f._pt[5] <= 0]
rows.sort(key=lambda f: -f._pt[5])
ok = True
for a, b in zip(rows, rows[1:]):
    if b._pt[5] > a._pt[5] - a._h + 0.001:  # next row must start at or below the end of the previous
        ok = False
check("rows do not overlap each other", ok and len(rows) >= 9, len(rows))
check("item summary row is tall enough for its icon line", rows[0]._h >= 55, rows[0]._h)
G.SlashCmdList["QUESTTHREAD"]("xpcheck")
check("xpcheck: table and client agree for the test quest", any("1 of 1" in p for p in G.printed.values()), list(G.printed.values())[-2:])
G.testClientXp[166] = 2700
G.SlashCmdList["QUESTTHREAD"]("xpcheck")
check("xpcheck reports a mismatch", any("table 2600, client 2700" in p for p in G.printed.values()))
G.testClientXp[166] = None

# ---- quest log button ----
def frame_named(name):
    for f in G.stubs.values():
        if f._name == name:
            return f

for f in G.stubs.values():
    fn = f._scripts["OnEvent"]
    if fn is not None:
        fn(f, "PLAYER_LOGIN")
check("quest log hook is a secure post-hook", G.hooks["QuestMapFrame_ShowQuestDetails"] is not None)
win = frame_named("QuestThreadFrame")
win._shown = False
G.SlashCmdList["QUESTTHREAD"]("166")
check("(setup) the window is open on a quest", win._shown and any(f._text == "The Defias Brotherhood" for f in G.stubs.values()))
G.hooks["QuestMapFrame_ShowQuestDetails"](55)
check("window follows the quest log while open", any(f._text == "Morbent Fel" for f in G.stubs.values()))
win._shown = False
G.hooks["QuestMapFrame_ShowQuestDetails"](166)
check("follow hook does not open a closed window", not win._shown)
G.testDetail = None

# ---- minimap button ----
import math


def near(a, b, tol=0.01):
    return a is not None and abs(a - b) <= tol


x, y = Core.MinimapOffset(0, 140, 140, "ROUND")
check("minimap offset: round, angle 0 is straight right, 5 px outside the edge", near(x, 75) and near(y, 0), (x, y))
x, y = Core.MinimapOffset(math.pi / 2, 140, 140, None)
check("minimap offset: no shape means round; pi/2 is straight up", near(x, 0) and near(y, 75), (x, y))
x, y = Core.MinimapOffset(math.pi / 4, 140, 140, "ROUND")
check("minimap offset: round keeps the diagonal on the circle", near(x, 75 * math.cos(math.pi / 4)) and near(y, x), (x, y))
x, y = Core.MinimapOffset(math.pi / 4, 140, 140, "SQUARE")
check("minimap offset: a square minimap pushes the diagonal out to the corner", near(x, 67.9, 0.1) and near(y, x), (x, y))
x, y = Core.MinimapOffset(0, 140, 140, "SQUARE")
check("minimap offset: square, straight right is clamped to the edge", near(x, 75) and near(y, 0), (x, y))
x, y = Core.MinimapOffset(math.radians(225), 140, 140, "CORNER-BOTTOMLEFT")
check("minimap offset: CORNER-BOTTOMLEFT is round only in the lower left",
      near(x, 75 * math.cos(math.radians(225))) and near(y, x), (x, y))
x, y = Core.MinimapOffset(math.pi / 4, 140, 140, "CORNER-BOTTOMLEFT")
check("minimap offset: ...and square in the other three quadrants", near(x, 67.9, 0.1) and near(y, x), (x, y))
x, y = Core.MinimapOffset(math.pi / 2, 200, 100, "ROUND")
check("minimap offset: a non-square minimap scales each axis", near(x, 0) and near(y, 55), (x, y))

mb = frame_named("QuestThreadMinimapButton")
check("minimap button is created at login", mb is not None and mb._shown is True)
check("minimap button: default spot is on the ring, lower left",
      mb._pt[1] == "CENTER" and mb._pt[2]._mark == "minimap" and near(mb._pt[4], 75 * math.cos(math.radians(215))) and near(mb._pt[5], 75 * math.sin(math.radians(215))), mb._pt)
check("minimap button: placed above the minimap's own level", mb._lvl is not None and mb._lvl > 1, mb._lvl)
win._shown = False
G.testDetail = None
mb._scripts["OnClick"](mb)
check("minimap button opens the window", win._shown)
mb._scripts["OnClick"](mb)
check("minimap button closes the window again", not win._shown)
G.testDetail = 166
mb._scripts["OnClick"](mb)
check("minimap button opens the Zones tab, even with a quest open in the log", win._shown and ns2.UI.IsZoneMode())
mb._scripts["OnClick"](mb)
check("minimap button closes the window even with a quest open in the log", not win._shown)
G.SlashCmdList["QUESTTHREAD"]("")
check("/qthread on its own opens the Zones tab too", win._shown and ns2.UI.IsZoneMode())
G.SlashCmdList["QUESTTHREAD"]("")
check("... and closes it again", not win._shown)
G.testDetail = None
win._shown = False
ns2.UI.ShowChains()
win._shown = False
G.GameTooltip.AddLine = lua.eval("function(_, text) tipLines[#tipLines + 1] = text end")
G.tipLines = lua.table()
mb._scripts["OnEnter"](mb)
check("minimap button tooltip explains the click and the drag", any("Left-click" in t for t in G.tipLines.values()) and any("Drag" in t for t in G.tipLines.values()), list(G.tipLines.values()))
# dragging: the button follows the cursor's direction from the minimap's centre, and the spot is saved
mb._scripts["OnDragStart"](mb)
check("dragging starts following the cursor", mb._scripts["OnUpdate"] is not None)
G.testCursor = lua.table_from([500, 600])
mb._scripts["OnUpdate"](mb, 0.016)
check("drag: cursor straight above puts the button at the top", near(mb._pt[4], 0, 0.1) and near(mb._pt[5], 75, 0.1), mb._pt)
G.testCursor = lua.table_from([400, 500])
mb._scripts["OnDragStop"](mb)
check("drag stop: the button is where the cursor was, and stops following",
      mb._scripts["OnUpdate"] is None and near(mb._pt[4], -75, 0.1) and near(mb._pt[5], 0, 0.1), mb._pt)
check("the spot is saved", near(G.QuestThreadDB.minimap.angle, math.pi, 0.001) or near(abs(G.QuestThreadDB.minimap.angle), math.pi, 0.001), G.QuestThreadDB.minimap.angle)
G.testShape = "SQUARE"
G.testCursor = lua.table_from([600, 600])
mb._scripts["OnDragStart"](mb)
mb._scripts["OnUpdate"](mb, 0.016)
mb._scripts["OnDragStop"](mb)
check("a square minimap puts the diagonal at its corner", near(mb._pt[4], 67.9, 0.1) and near(mb._pt[5], 67.9, 0.1), mb._pt)
G.testShape = None
# right-click menu on the minimap button
check("tooltip mentions the right-click", any("Right-click" in t for t in G.tipLines.values()), list(G.tipLines.values()))
check("no menu until it is asked for", frame_named("QuestThreadMinimapMenu") is None)
mb._scripts["OnClick"](mb, "RightButton")
menu = frame_named("QuestThreadMinimapMenu")
check("right-click opens a menu under the button", menu is not None and menu._shown is True and menu._pt[1] == "TOPRIGHT")
check("the menu is closable with Escape", "QuestThreadMinimapMenu" in list(G.UISpecialFrames.values()))
check("right-click does not open the chain window", not win._shown)
mb._scripts["OnClick"](mb, "RightButton")
check("right-click again closes the menu", menu._shown is False)
mb._scripts["OnClick"](mb, "RightButton")
G.testMouse = True
menu._scripts["OnUpdate"](menu, 0.016)
check("a click elsewhere closes the menu", menu._shown is False)
mb._scripts["OnClick"](mb, "RightButton")
menu.IsMouseOver = lua.eval("function() return true end")
menu._scripts["OnUpdate"](menu, 0.016)
check("a click on the menu itself leaves it for its own handler", menu._shown is True)
menu.IsMouseOver = None
G.testMouse = False
mb._scripts["OnDragStart"](mb)
check("dragging the button closes the menu", menu._shown is False)
mb._scripts["OnDragStop"](mb)
mb._scripts["OnClick"](mb, "RightButton")
mb._scripts["OnClick"](mb, "LeftButton")
check("a left click closes the menu and opens the window", menu._shown is False and win._shown)
win._shown = False
mb._scripts["OnClick"](mb, "RightButton")
G.printed = lua.table()
menu.item._scripts["OnClick"](menu.item)
check("the menu item hides the button and remembers it", mb._shown is False and menu._shown is False and G.QuestThreadDB.minimap.hide is True)
check("hiding says how to show it again", any("/qthread minimap" in p and "show it again" in p for p in G.printed.values()), list(G.printed.values()))
G.SlashCmdList["QUESTTHREAD"]("minimap")
check("the slash command brings it back after hiding from the menu", mb._shown is True and not G.QuestThreadDB.minimap.hide)

# hide / show / reset
G.SlashCmdList["QUESTTHREAD"]("minimap")
check("/qthread minimap hides the button and remembers it", mb._shown is False and G.QuestThreadDB.minimap.hide is True)
G.SlashCmdList["QUESTTHREAD"]("minimap")
check("/qthread minimap shows it again", mb._shown is True and not G.QuestThreadDB.minimap.hide)
G.SlashCmdList["QUESTTHREAD"]("minimap")
G.SlashCmdList["QUESTTHREAD"]("reset")
check("/qthread reset brings the button back to its default spot, shown",
      mb._shown is True and G.QuestThreadDB.minimap.angle is None and not G.QuestThreadDB.minimap.hide
      and near(mb._pt[4], 75 * math.cos(math.radians(215))), (mb._shown, mb._pt))
win._shown = False


def tick():
    for f in list(G.stubs.values()):
        fn = f._scripts["OnUpdate"]
        if fn is not None:
            fn(f, 1.0)


def clickers():
    return [f for f in G.stubs.values() if f._scripts["OnClick"] is not None]


tick()
n_before = len(clickers())
G.testDetail = 166
tick()
check("no extra chain button floats over the quest log when a quest's detail view is open", len(clickers()) == n_before, (n_before, len(clickers())))
G.testDetail = None
before = len(clickers())
row_a, row_b, header = G.makeRow(166), G.makeRow(55), G.makeRow(None)
tick()
new = clickers()[before:]
check("a Chain button is added to each quest row, not to headers", len(new) == 2, len(new))
tick()
check("rows are not given duplicate buttons", len(clickers()) == before + 2)
win._shown = False
new[1]._scripts["OnClick"](new[1])
check("row button opens that quest's chain", win._shown and any(f._text == "Morbent Fel" for f in G.stubs.values()))
row_b.questID = 214  # the row is recycled for another quest
tick()
new[1]._scripts["OnClick"](new[1])
check("a recycled row's button follows its new quest", any(f._text == "Red Silk Bandanas" for f in G.stubs.values()))
row_a.questID = None
tick()
check("a row that stops showing a quest hides its button", new[0]._shown is False)

# ---- requirements and status (pure logic) ----
def lt(py):
    return lua.table_from(py, recursive=True)


def unmet(info, done_ids, level):
    done = lua.eval("function(set) return function(id) return set[id] == true end end")(lua.table_from({i: True for i in done_ids}))
    names = lua.eval("function(id) return 'Q' .. id end")
    return list(Core.Unmet(lt(info), done, level, names).values())


check("level requirement is reported", unmet({"reqLevel": 30}, [], 20) == ["Level 30"])
check("no unmet requirement when level is enough", unmet({"reqLevel": 30}, [], 30) == [])
check("a prerequisite group needs all of its quests", unmet({"pre": [1, 2]}, [1], 60) == ["Finish: Q2"])
check("alternative prerequisites need just one", unmet({"preS": [1, 2]}, [2], 60) == [])
check("alternative prerequisites listed when none is done", unmet({"preS": [1, 2]}, [], 60) == ["Finish one of: Q1, Q2"])
status = lambda **kw: Core.StatusOf(lt(kw.get("info", {})), kw.get("done", False), kw.get("log", False), lambda i: False, 60, lambda i: "Q")[0]
check("status order: done, then log, then locked, then available",
      status(done=True, log=True) == "done" and status(log=True) == "log"
      and status(info={"pre": [9]}) == "locked" and status() == "available")

# ---- partial-name search ----
ids = lt([1, 2, 3, 4])
names = {1: "The Defias Brotherhood", 2: "Defias", 3: "Red Silk Bandanas", 4: "Defias Gunpowder"}
hits, total = Core.Search(ids, lua.eval("function(t) return function(id) return t[id] end end")(lua.table_from(names)), "defias", 2)
check("search matches substrings case-insensitively, exact name first, then shorter names",
      total == 3 and [h["id"] for h in hits.values()] == [2, 4], (total, [h["id"] for h in hits.values()]))
check("search caps its results", len(list(hits.values())) == 2)
check("search with nothing typed finds nothing", len(list(Core.Search(ids, lua.eval("function() return 'x' end"), "  ", 5).values())) == 0)

# ---- spawn choice ----
spawns = lt({12: [[42.5, 61.0]], 1: [[10, 10]]})
a, x, y = Core.PickSpawn(spawns, 12)
check("a giver's spawn in the quest's own zone is preferred", (a, x, y) == (12, 42.5, 61.0), (a, x, y))
check("without a preferred zone the lowest area id wins", Core.PickSpawn(spawns, None)[0] == 1)
check("no spawns means no location", Core.PickSpawn(None, 12) is None)

# ---- in-window: status tags, tooltip, waypoint, search, scale ----
G.SlashCmdList["QUESTTHREAD"]("166")
entry_row = next((f for f in G.stubs.values() if f.questId == 166 and f.entry is not None), None)
check("a quest row carries its entry and status", entry_row is not None and entry_row.entry.status is not None)
CELL = {"done": 0, "log": 1, "available": 2, "locked": 3}
CELLW = 1.0 / 8  # Status.tga: eight 32-px cells, five drawn
with_entry = [f for f in G.stubs.values() if f.entry is not None and f._shown]
bad = [(f.entry.status, f.status._tc[1] if f.status._tc is not None else None) for f in with_entry
       if f.status._tc is None or abs(f.status._tc[1] - CELL[f.entry.status] * CELLW) > 1e-9]
check("each row's status icon is the cell for its status", len(with_entry) >= 8 and not bad, bad[:3])
check("the sheet cells are an eighth wide", all(abs(f.status._tc[2] - f.status._tc[1] - CELLW) < 1e-9 for f in with_entry))
sheet = open(os.path.join(ROOT, "Status.tga"), "rb").read()
sw, sh, sdepth = struct.unpack("<HHB", sheet[12:17])
check("Status.tga is 256x32, 32-bit, uncompressed, with the fifth (green !) and sixth (badge) cells drawn and the seventh empty",
      (sw, sh, sdepth) == (256, 32, 32) and sheet[2] == 2 and len(sheet) == 18 + 256 * 32 * 4
      and max(sheet[18 + 3 + 4 * (y * 256 + x)] for y in range(32) for x in range(128, 160)) == 255
      and max(sheet[18 + 3 + 4 * (y * 256 + x)] for y in range(32) for x in range(160, 192)) == 255
      and max(sheet[18 + 3 + 4 * (y * 256 + x)] for y in range(32) for x in range(192, 224)) == 0, (sw, sh, sdepth))
locked_rows = [f for f in with_entry if f.entry.status == "locked"]
check("locked rows say what they need on a second line", locked_rows and all(f.sub._text.find("Needs:") >= 0 and f.sub._shown for f in locked_rows), len(locked_rows))
plain = [f for f in with_entry if f.entry.status != "locked" and f.entry.id != 166]
check("other rows have no second line", all(not f.sub._shown for f in plain))
import math
check("row height follows its second line and reward icons",
      all(abs(f._h - (30 + (14 if f.sub._shown else 0) + (14 if f.where._shown else 0) + (math.ceil(len(f.entry["items"]) / 14) * 25 if len(f.entry["items"]) else 0))) < 0.001 for f in with_entry))
check("rows no longer print status words in the name", not any(w in (f.name._text or "") for f in with_entry for w in ("done", "locked", "in log", "available")))
check("rows show the quest level", any("[30]" in (f._text or "") for f in G.stubs.values()))
G.tipLines = lua.table()
entry_row._scripts["OnEnter"](entry_row)
tip = list(G.tipLines.values())
check("hover tooltip shows objective and start / end givers", any("Kill things." in s for s in tip) and any(s.startswith("Starts: Test Giver") for s in tip) and any(s.startswith("Ends: Test Giver") for s in tip), tip)
check("tooltip place text names the zone and coordinates", any("Elwynn Forest (42, 61)" in s or "Elwynn Forest (43, 61)" in s for s in tip), tip)
entry_row._scripts["OnClick"](entry_row, "RightButton")
pt = G.waypointCalls.point
check("right-click sets a waypoint at the objective on the right map", pt is not None and pt.uiMapID == 1429 and abs(pt.x - 0.425) < 1e-9 and abs(pt.y - 0.61) < 1e-9, pt)
check("the map is opened on that zone and the waypoint is tracked", G.waypointCalls.opened == 1429 and G.waypointCalls.track is True)
check("the waypoint message names the objective", any("Waypoint set to Kill Test Giver, Elwynn Forest" in s for s in G.printed.values()), list(G.printed.values())[-2:])
G.testShift = True
entry_row._scripts["OnClick"](entry_row, "RightButton")
G.testShift = False
check("Shift+right-click goes to where the quest is handed in", list(G.printed.values())[-1].startswith("|cffffd100QuestThread:|r Waypoint set to Test Giver") or "Waypoint set to Test Giver" in list(G.printed.values())[-1], list(G.printed.values())[-1])
G.testAlt = True
entry_row._scripts["OnClick"](entry_row, "RightButton")
G.testAlt = False
check("Alt+right-click goes to where the quest starts", "Waypoint set to Test Giver" in list(G.printed.values())[-1], list(G.printed.values())[-1])
G.SlashCmdList["QUESTTHREAD"]("defias")
result_rows = [f for f in G.stubs.values() if f._shown and f.questId and f.entry is None and f.name is not None and "#" in (f.name._text or "")]
check("a partial name shows a result list", len(result_rows) >= 2, [f.name._text for f in result_rows][:3])
picked = result_rows[0].questId
for f in G.stubs.values():
    f._text = ""
result_rows[0]._scripts["OnClick"](result_rows[0], "LeftButton")
want = quests[picked]["name"]
check("clicking a result opens that quest's chain", any(f._text == want for f in G.stubs.values()), want)
G.SlashCmdList["QUESTTHREAD"]("scale 1.3")
check("scale is saved", abs(G.QuestThreadDB.scale - 1.3) < 1e-9, G.QuestThreadDB.scale)
G.SlashCmdList["QUESTTHREAD"]("scale 9")
check("scale is clamped", abs(G.QuestThreadDB.scale - 1.6) < 1e-9, G.QuestThreadDB.scale)
G.SlashCmdList["QUESTTHREAD"]("reset")
check("reset forgets position and scale", G.QuestThreadDB.scale is None and G.QuestThreadDB.pos is None)

# ---- keyboard: the window must not eat movement keys ----
kwin = frame_named("QuestThreadFrame")
kwin._shown = True
check("the window never takes keyboard input, so it cannot swallow WASD in combat", kwin._kb is not True and kwin._scripts["OnKeyDown"] is None and kwin._scripts["OnKeyUp"] is None)
check("Escape closes it through the game's special-frame list", "QuestThreadFrame" in list(G.UISpecialFrames.values()))
cleared = kwin.box._cleared or 0
kwin._scripts["OnMouseDown"](kwin, "LeftButton")
check("clicking the window takes focus off the search box", (kwin.box._cleared or 0) == cleared + 1)
cleared = kwin.box._cleared or 0
kwin._scripts["OnEvent"](kwin, "PLAYER_REGEN_DISABLED")
check("the search box lets go of the keyboard when combat starts", (kwin.box._cleared or 0) == cleared + 1)

# ---- quest ids and the Wowhead link (Ctrl+C while hovering) ----
check("the Wowhead link is a plain forever quest link", Core.QuestUrl(166) == "https://www.wowhead.com/forever/quest=166", Core.QuestUrl(166))
G.SlashCmdList["QUESTTHREAD"]("166")
id_rows = [f for f in G.stubs.values() if f._shown and f.entry is not None]
check("every chain row shows its quest id next to the name", len(id_rows) >= 8 and all(("#%d" % f.entry.id) in f.name._text for f in id_rows), [f.name._text for f in id_rows][:2])
hrow = next(f for f in id_rows if f.entry.id == 166)
G.tipLines = lua.table()
hrow._scripts["OnEnter"](hrow)
check("the tooltip has no shortcut lines until Shift is held", not any(w in s for s in G.tipLines.values() for w in ("Ctrl+C", "Left-click", "Right-click")), list(G.tipLines.values())[-3:])
G.testShift = True
G.tipLines = lua.table()
hrow._scripts["OnEnter"](hrow)
check("... held Shift adds the shortcuts", any("Ctrl+C" in s for s in G.tipLines.values()) and any("Shift+Right-click" in s for s in G.tipLines.values()), list(G.tipLines.values())[-3:])
check("no tooltip line uses the middle dot, which the tooltip font draws as a square", not any("·" in s for s in G.tipLines.values()), list(G.tipLines.values()))
old_req = G.QuestDB.requiredLevel
G.QuestDB.requiredLevel = lua.eval("function(id) return 40 end")
G.SlashCmdList["QUESTTHREAD"]("166")
hrow2 = next(f for f in G.stubs.values() if f._shown and f.entry is not None and f.entry.id == 166)
G.tipLines = lua.table()
hrow2._scripts["OnEnter"](hrow2)
lvline = [s for s in G.tipLines.values() if "requires level" in s]
check("the level line joins the level and the requirement with a plain dash (not a middle dot)", lvline == ["Level 30 - requires level 40"], lvline)
G.QuestDB.requiredLevel = old_req
G.SlashCmdList["QUESTTHREAD"]("166")
hrow = next(f for f in G.stubs.values() if f._shown and f.entry is not None and f.entry.id == 166)
G.testShift = False
G.ownerRow = None
G.GameTooltip.GetOwner = lua.eval("function() return ownerRow end")
watch = next(f for f in G.stubs.values() if f._events is not None and f._events["MODIFIER_STATE_CHANGED"])
G.tipLines = lua.table()
watch._scripts["OnEvent"](watch, "MODIFIER_STATE_CHANGED", "LSHIFT", 1)
check("pressing Shift redraws nothing when the tooltip is not the quest's", len(G.tipLines) == 0)
hrow._scripts["OnEnter"](hrow)
G.ownerRow = hrow
G.testShift = True
G.tipLines = lua.table()
watch._scripts["OnEvent"](watch, "MODIFIER_STATE_CHANGED", "LSHIFT", 1)
check("pressing Shift over a quest redraws its tooltip with the shortcuts", any("Shift+Right-click" in s for s in G.tipLines.values()), list(G.tipLines.values()))
G.testShift = False
G.tipLines = lua.table()
watch._scripts["OnEvent"](watch, "MODIFIER_STATE_CHANGED", "LSHIFT", 0)
check("letting go redraws it without them", len(G.tipLines) >= 1 and not any("Right-click" in s for s in G.tipLines.values()), list(G.tipLines.values()))
G.tipLines = lua.table()
watch._scripts["OnEvent"](watch, "MODIFIER_STATE_CHANGED", "LCTRL", 1)
check("other modifier keys do not redraw it", len(G.tipLines) == 0)
G.GameTooltip.GetOwner = None
keys = frame_named("QuestThreadKeys")
check("hovering a quest turns the key listener on", keys is not None and keys._kb is True)
check("the window itself still takes no keyboard input", kwin._kb is not True)
G.testCtrl = True
keys._scripts["OnKeyDown"](keys, "C")
G.testCtrl = False
link = frame_named("QuestThreadLinkFrame")
check("Ctrl+C on a hovered quest opens the link box with the link selected",
      link is not None and link._shown and link.box._text == "https://www.wowhead.com/forever/quest=166" and link.box._focused and link.box._hl,
      link.box._text if link else None)
check("Ctrl+C is not passed on to the game", keys._prop is False)
check("the link box names the quest and its id", "#166" in link.title._text, link.title._text)
check("the link box can be closed with Escape", "QuestThreadLinkFrame" in list(G.UISpecialFrames.values()) and link.box._scripts["OnEscapePressed"] is not None)
keys._scripts["OnKeyDown"](keys, "W")
check("other keys go straight on to the game", keys._prop is True)
G.testCtrl = True
keys._scripts["OnKeyDown"](keys, "V")
G.testCtrl = False
check("Ctrl with another key goes straight on too", keys._prop is True)
link.box._text = "typed"
link.box._scripts["OnTextChanged"](link.box, True)
check("typing in the link box puts the link back", link.box._text == "https://www.wowhead.com/forever/quest=166", link.box._text)
G.testCtrl = True
link.box._scripts["OnKeyUp"](link.box, "C")
G.testCtrl = False
check("the link box closes once the copy is done", not link._shown)
# combat: the listener must be off, and a box that is open goes away
keys._scripts["OnEvent"](keys, "PLAYER_REGEN_DISABLED")
check("combat turns the key listener off", keys._kb is False)
G.testCtrl = True
keys._scripts["OnKeyDown"](keys, "C")
G.testCtrl = False
link._shown = True
link._scripts["OnEvent"](link, "PLAYER_REGEN_DISABLED")
check("an open link box closes when combat starts", not link._shown)
hrow._scripts["OnLeave"](hrow)
G.testCombat = True
hrow._scripts["OnEnter"](hrow)
check("hovering a quest in combat does not turn the listener on", keys._kb is False)
G.testCombat = False
keys._scripts["OnEvent"](keys, "PLAYER_REGEN_ENABLED")
check("the listener comes back after combat while the mouse is still on the quest", keys._kb is True)
hrow._scripts["OnLeave"](hrow)
check("moving off the quest turns the listener off", keys._kb is False)
G.testCtrl = True
keys._scripts["OnKeyDown"](keys, "C")
G.testCtrl = False
check("Ctrl+C with no quest hovered does nothing", not link._shown)
hrow._scripts["OnEnter"](hrow)
kwin._scripts["OnHide"](kwin)
check("closing the window turns the listener off", keys._kb is False)
# rows of the pick list work too
G.SlashCmdList["QUESTTHREAD"]("defias")
hits = [f for f in G.stubs.values() if f._shown and f.questId and f.entry is None and "#" in (f.name._text or "")]
G.tipLines = lua.table()
hits[0]._scripts["OnEnter"](hits[0])
check("a pick-list row has a tooltip with its id, and the shortcut only with Shift", any("Quest #%d" % hits[0].questId in s for s in G.tipLines.values()) and not any("Ctrl+C" in s for s in G.tipLines.values()), list(G.tipLines.values()))
G.testShift = True
G.tipLines = lua.table()
hits[0]._scripts["OnEnter"](hits[0])
check("... Shift adds it", any("Ctrl+C" in s for s in G.tipLines.values()), list(G.tipLines.values()))
G.testShift = False
G.testCtrl = True
keys._scripts["OnKeyDown"](keys, "C")
G.testCtrl = False
check("Ctrl+C on a pick-list row copies that quest's link", link._shown and link.box._text.endswith("quest=%d" % hits[0].questId), link.box._text)
hits[0]._scripts["OnLeave"](hits[0])
link._shown = False

# ---- the quest dialogue: chain button, quest id, green for a repeatable done once ----
check("flags: bit 1 means repeatable", Core.IsRepeatable(1) and Core.IsRepeatable(3) and not Core.IsRepeatable(2) and not Core.IsRepeatable(0) and not Core.IsRepeatable(None))
D = ns2.Data


def lp(f):
    return list(list(f._pts.values())[-1].values())  # [point, relativeTo, relativePoint, x, y]


check("a repeatable quest is told apart from a normal one", D.IsRepeatable(500) and not D.IsRepeatable(501))
check("a repeatable quest never done is not done", not D.RepeatableDone(500) and D.QuestState(500) == "new")
D.RecordTurnIn(501)
check("turn-ins of normal quests are not remembered", not (G.QuestThreadDB.turnedIn and G.QuestThreadDB.turnedIn[501]))
check("a quest flagged completed is done", D.QuestState(65) == "done")
check("a quest in your log is in the log state", D.QuestState(502) == "log")
G.testQid = 500
G.QuestFrameDetailPanel._shown = True
QF = ns2.QuestFrame
QF.Update()
idfs = next((f for f in G.stubs.values() if f._text == "Quest ID: 500"), None)
idfs._mark = "id"
G.QuestFrameDetailPanel._mark = "panel"
chain_btn = next((f for f in G.stubs.values() if f.questID == 500 and f._scripts["OnClick"] is not None), None)
check("the quest dialogue shows the quest id and a chain button", idfs is not None and chain_btn is not None)
check("the id is shown in the top right corner of the panel", idfs._shown and lp(idfs)[0] == "TOPRIGHT" and lp(idfs)[3] == -20 and lp(idfs)[4] == -35, lp(idfs))
check("the chain button sits just left of the id", lp(chain_btn)[0] == "RIGHT" and lp(chain_btn)[1]._mark == "id", lp(chain_btn)[0])
check("an undone repeatable quest is orange", list(idfs._color.values()) == [1, 0.5, 0], idfs._color)
qf_events = next(f for f in G.stubs.values() if f._events is not None and f._events["QUEST_TURNED_IN"])
qf_events._scripts["OnEvent"](qf_events, "QUEST_TURNED_IN", 500)
check("a turn-in of a repeatable quest is remembered", G.QuestThreadDB.turnedIn[500] == 1)
check("a repeatable quest done once counts as done", D.RepeatableDone(500) and D.QuestState(500) == "done")
QF.Update()
check("the id turns green for a repeatable quest done at least once", list(idfs._color.values()) == [0, 1, 0], idfs._color)
G.testQid = 504
QF.Update()
check("another repeatable quest never done stays orange", list(next(f for f in G.stubs.values() if f._text == "Quest ID: 504")._color.values()) == [1, 0.5, 0])
G.Questie = lua.eval("{ db = { char = { journey = { { Event = 'Quest', SubType = 'Complete', Quest = 504 } } } } }")
check("Questie's journey also proves a repeatable quest was done", D.RepeatableDone(504))
G.Questie = None
G.testQid = 502
QF.Update()
check("a quest in your log is violet", list(next(f for f in G.stubs.values() if f._text == "Quest ID: 502")._color.values()) == [0.8, 0, 1])
G.testQid = 65
QF.Update()
check("a completed normal quest is green", list(next(f for f in G.stubs.values() if f._text == "Quest ID: 65")._color.values()) == [0, 1, 0])
G.testQid = 500
QF.Update()
chain_btn._scripts["OnClick"](chain_btn)
check("the chain button opens the quest's chain window", kwin._shown)
kwin._shown = False
qf_events._scripts["OnEvent"](qf_events, "QUEST_FINISHED")
check("the id and button go away when the dialogue closes", not next(f for f in G.stubs.values() if f._parent is not None and f._parent._mark == "panel")._shown)

# with the QuestID addon loaded: only the button is added, and its text is made green for a done repeatable
fake_text = G.newStub()
fake_text.GetObjectType = lua.eval("function() return 'FontString' end")
fake_text._text = "Quest ID: 500"
G.QuestFrameDetailPanel.GetRegions = lua.eval("function() return nil end")
G.QuestID = lua.eval("{ QuestFrame = { Update = function() end, UpdateColor = function() end } }")
G.QuestFrameDetailPanel.GetRegions = lua.eval("function(txt) return function() return txt end end")(fake_text)
QF.ready = None
QF.Init()
G.testQid = 500
G.QuestFrameDetailPanel._shown = True
QF.Update()
check("with QuestID loaded this addon draws no id text of its own", not idfs._shown)
check("with QuestID loaded the button stays left of its text", lp(chain_btn)[0] == "TOPRIGHT" and abs(lp(chain_btn)[3] - (-20 - 80 - 6)) < 1e-9, lp(chain_btn))
G.QuestID.QuestFrame.Update(G.QuestID.QuestFrame)
check("QuestID's text is made green for a repeatable quest done once", list(fake_text._color.values()) == [0, 1, 0], fake_text._color)
fake_text._color = None
G.testQid = 504
fake_text._text = "Quest ID: 504"
G.QuestID.QuestFrame.UpdateColor(G.QuestID.QuestFrame)
check("QuestID's text is left alone for a repeatable never done", fake_text._color is None)
G.QuestID = None
G.testQid = 0

# ---- repeatable quests in the chain window ----
def popup_text():
    p = popup()
    parts = [x._text for x in p.textRows.values() if x._shown]
    for b in p.itemRows.values():
        if b._shown:
            parts.append(b.name._text)
            if b.detail._shown:
                parts.append(b.detail._text)
    return chr(10).join(parts)

def chain_row(qid):
    return next(f for f in G.stubs.values() if f._shown and f.entry is not None and f.entry.id == qid)


G.SlashCmdList["QUESTTHREAD"]("166")
r166 = chain_row(166)
check("a repeatable quest never done is tagged Repeatable, with a grey id", "Repeatable" in r166.name._text and "|cff808080#166" in r166.name._text and "done" not in r166.name._text, r166.name._text)
other = next(f for f in G.stubs.values() if f._shown and f.entry is not None and f.entry.id != 166)
check("a normal quest gets no Repeatable tag", "Repeatable" not in other.name._text, other.name._text)
G.tipLines = lua.table()
r166._scripts["OnEnter"](r166)
check("the tooltip says it is repeatable", "Repeatable" in list(G.tipLines.values()), list(G.tipLines.values())[:5])
prev_done = G.C_QuestLog.IsQuestFlaggedCompleted
G.C_QuestLog.IsQuestFlaggedCompleted = lua.eval("function(id) return id ~= 166 end")  # every step before it is done, so it is available
G.SlashCmdList["QUESTTHREAD"]("166")
r166 = chain_row(166)
check("a repeatable quest never done has the gold available cell", r166.entry.status == "available" and abs(r166.status._tc[1] - 2 * CELLW) < 1e-9, (r166.entry.status, r166.status._tc))
D.RecordTurnIn(166)
D.RecordTurnIn(166)
G.SlashCmdList["QUESTTHREAD"]("166")
r166 = chain_row(166)
check("... and once it is done at least once, the green ! cell", r166.entry.status == "available" and abs(r166.status._tc[1] - 4 * CELLW) < 1e-9 and abs(r166.status._tc[2] - 5 * CELLW) < 1e-9, (r166.entry.status, r166.status._tc))
G.C_QuestLog.IsQuestFlaggedCompleted = prev_done
G.SlashCmdList["QUESTTHREAD"]("166")
r166 = chain_row(166)
other_row = next(f for f in G.stubs.values() if f._shown and f.entry is not None and f.entry.id != 166 and f.entry.status == "available")
check("a normal available quest keeps the gold cell", abs(other_row.status._tc[1] - 2 * CELLW) < 1e-9, other_row.status._tc)
check("a repeatable quest done twice says so and its id is green", "Repeatable · done 2x" in r166.name._text and "|cff4fe04f#166" in r166.name._text, r166.name._text)
G.tipLines = lua.table()
r166._scripts["OnEnter"](r166)
check("the tooltip says how often it was completed", "Repeatable, completed 2 times" in list(G.tipLines.values()), list(G.tipLines.values())[:5])
G.QuestThreadDB.turnedIn[166] = None
G.Questie = lua.eval("{ db = { char = { journey = { { Event = 'Quest', SubType = 'Complete', Quest = 166 } } } } }")
G.SlashCmdList["QUESTTHREAD"]("166")
r166 = chain_row(166)
check("done according to Questie's journey only: no count", "Repeatable · done" in r166.name._text and "x" not in r166.name._text.split("done")[1].split("|")[0], r166.name._text)
G.Questie = None
G.QuestThreadDB.turnedIn = None

# ---- who you are: the professions you have learned ----
G.GetProfessions = lua.eval("function() return 1, 2, nil, 4 end")
G.GetProfessionInfo = lua.eval("function(i) return 'P' .. i, 0, 100, 300, 0, 0, ({[1]=171,[2]=164,[4]=185})[i] end")
who1 = D.Who()
check("Who reads the learned professions from GetProfessions (the skill line is its 7th value)", who1.hasSkill(171) is True and who1.hasSkill(185) is True and who1.hasSkill(333) is False)
G.GetProfessionInfo = lua.eval("function(i) return 'P' .. i, 0, 100, 300, 0, 0, ({[1]=171,[2]=333,[4]=185})[i] end")
who2 = D.Who()
check("Who's key changes when the learned professions do", who1.key != who2.key and who2.hasSkill(333) is True and who2.hasSkill(164) is False, (who1.key, who2.key))
G.GetProfessions = None
G.GetProfessionInfo = None
who3 = D.Who()
check("without GetProfessions nothing is ruled out", who3.hasSkill(171) is None and who3.hasSkill(333) is None)
G.C_SkillInfo = lua.eval("{ GetSkillLineInfoByID = function(id) if id == 171 then return { rank = 50 } end return { rank = 0 } end }")
who4 = D.Who()
check("a skill line with rank counts as learned even then, and the rest stays unknown", who4.hasSkill(171) is True and who4.hasSkill(333) is None)
G.C_SkillInfo = None

# ---- a chain with optional side quests, in the window ----
real_b = Core.Chain(idx, 96077, lua_info)
real_b_cols = Core.GraphLayout(real_b.layers, idx.prevs).cols
G.UIParent.GetWidth = lua.eval("function() return 1920 end")
G.UIParent.GetEffectiveScale = lua.eval("function() return 1 end")
frame_named("QuestThreadFrame").GetEffectiveScale = lua.eval("function() return 1 end")
G.SlashCmdList["QUESTTHREAD"]("96077")
opt_ids = sorted(e.id for layer in real_b.layers.values() for e in layer.values() if e.optional)
main_ids = sorted(e.id for layer in real_b.layers.values() for e in layer.values() if not e.optional)
check("(setup) Belle's Ring has main and optional quests", len(opt_ids) > 0 and len(main_ids) > 0, (len(opt_ids), len(main_ids)))
orows = [chain_row(i) for i in opt_ids]
mrows = [chain_row(i) for i in main_ids]
check("an optional side quest hangs to the right on a rail, with a dimmer band, an Optional tag and a letter",
      all(r.rail._shown and r.stub._shown and r.badge._shown and "Optional" in r.tag._text and r.status._pt[2] == 56 and r.name._pt[2] == 78 and r.num._text.endswith("|r") for r in orows),
      [(r.entry.id, r.status._pt[2], r.tag._text) for r in orows][:3])
check("a main quest has its number, no rail, no Optional tag, and the normal indent",
      all(not r.rail._shown and not r.stub._shown and not r.badge._shown and "Optional" not in r.tag._text and r.status._pt[2] == 24 and r.num._text == r.entry.label for r in mrows),
      [(r.entry.id, r.num._text) for r in mrows][:3])
# the rail runs through a group of side quests and ends at the last one's elbow
order_b = [e.id for layer in real_b.layers.values() for e in layer.values()]
opt_set = set(opt_ids)
rail_bad = []
for k, qid in enumerate(order_b):
    if qid not in opt_set:
        continue
    r = chain_row(qid)
    goes_on = k + 1 < len(order_b) and order_b[k + 1] in opt_set
    has_bottom = any(p[1] == "BOTTOMLEFT" for p in r.rail._pts.values())
    if goes_on != has_bottom or (not goes_on and r.rail._h != 15):
        rail_bad.append((qid, goes_on, has_bottom, r.rail._h))
check("the rail runs on while the group of side quests continues, and stops at its last quest's elbow", not rail_bad, rail_bad[:3])
check("the letter sits in a round badge at the elbow", all(r.badge._tc is not None and abs(r.badge._tc[1] - 5 / 8) < 1e-9 and r.num._pt[2] == 34 for r in orows), [(r.badge._tc, r.num._pt) for r in orows][:1])
check("main quests are numbered 1, 2, 3 without gaps", [r.num._text for r in sorted(mrows, key=lambda r: -r._pt[5])] == [str(n) for n in range(1, len(main_ids) + 1)])
check("the header says how many are main and how many optional", ("(%d main, %d optional)" % (len(main_ids), len(opt_ids))) in frame_named("QuestThreadFrame").stats._text, frame_named("QuestThreadFrame").stats._text)
needs = [r for r in orows + mrows if any("Finish" in u for u in r.entry.unmet.values())]
check("a prerequisite is named with its number, so equal names can be told apart", len(needs) > 0 and all(re.search(r"\([0-9a-z]+\)", " ".join(r.entry.unmet.values())) for r in needs), [list(r.entry.unmet.values()) for r in needs][:2])
G.SlashCmdList["QUESTTHREAD"]("")

# ---- the chain as a graph ----
gwin = frame_named("QuestThreadFrame")
G.QuestThreadDB.chainView = "graph"
G.SlashCmdList["QUESTTHREAD"]("96077")
check("the chain view has a List | Graph toggle, Graph lit", gwin.viewToggle._shown and gwin.tabGraph.plate._shown and not gwin.tabList.plate._shown)
check("the search box makes room for it", gwin.box._w2 > 0 and gwin.box._w2 == gwin._w2 - 310 - 28 - 137 - 8, (gwin.box._w2, gwin._w2))
check("the graph replaces the list: the canvas is shown, the zoom buttons too", gwin.gscroll._shown and gwin.gzoom._shown and not gwin.scroll._shown)
# the window grows to fit the chain, up to half the screen
gneed = 2 * 18 + real_b_cols * 176 + (real_b_cols - 1) * 56 + 32
check("on a 1920-wide screen the window (column and pane) grows towards the chain but stops at half the screen (960)", gwin._w2 == min(gneed + 310, 960) == 960, (gwin._w2, gneed))
gnodes_ = [f for f in G.stubs.values() if f._shown and f.cur is not None and f.meta is not None and f.questId is not None]
check("a box for every quest of the chain", sorted(f.questId for f in gnodes_) == sorted(main_ids + opt_ids), (len(gnodes_), len(main_ids) + len(opt_ids)))
glayout = Core.GraphLayout(real_b.layers, idx.prevs)
bad = [(f.questId, f._pt[4], f._pt[5]) for f in gnodes_ if f._pt[4] != 18 + glayout.nodes[f.questId].col * 232 or f._pt[5] != -(18 + glayout.nodes[f.questId].row * 74)]
check("each box sits in its column and row", not bad, bad[:3])
glines_ = [f for f in G.stubs.values() if f._shown and f._start is not None and f._end is not None]
check("every line is straight along an axis, and there are lines for every edge", len(glines_) >= len(glayout.edges) and all(f._start[1] == f._end[1] or f._start[2] == f._end[2] for f in glines_), (len(glines_), len(glayout.edges)))
opt_nodes = [f for f in gnodes_ if f.entry.optional]
check("optional quests are lettered and dimmer, main ones numbered", all("|cff8a7d68" in f.num._text for f in opt_nodes) and all(f.num._text == "|cffffd100%s|r" % f.entry.label for f in gnodes_ if not f.entry.optional))
gn = gnodes_[0]
G.tipLines = lua.table()
gn._scripts["OnEnter"](gn)
touching = [f for f in glines_ if f._vc is not None and f._vc[1] == 1 and f._vc[2] == 0.86]
check("hovering a box lights its lines gold and shows its tooltip", len(touching) > 0 and len(list(G.tipLines.values())) > 0, (len(touching), len(list(G.tipLines.values()))))
gn._scripts["OnLeave"](gn)
check("leaving puts the lines' colours back", not any(f._vc is not None and f._vc[1] == 1 and f._vc[2] == 0.86 for f in glines_))
gn._scripts["OnClick"](gn, "LeftButton")
gpop = frame_named("QuestThreadObjectives")
check("clicking a box fills the details pane", gpop is not None and gpop._shown and not gpop.empty and gpop.title._text.find(gn.entry.name) >= 0)
check("the selected box has a bright ring and no other box does", gn.sel._shown and not any(f.sel._shown for f in gnodes_ if f is not gn), [f.questId for f in gnodes_ if f.sel._shown])
sel_lines = [f for f in glines_ if f._vc is not None and f._vc[1] == 1 and f._vc[2] == 0.86]
check("the selected box's lines stay lit gold, and a little thicker", len(sel_lines) > 0 and all(f._thick == 3 for f in sel_lines) and any(f._thick == 2 for f in glines_ if f not in sel_lines), len(sel_lines))
gn2 = next(f for f in gnodes_ if f is not gn)
gn2._scripts["OnClick"](gn2, "LeftButton")
check("selecting another box moves the ring", gn2.sel._shown and not gn.sel._shown)
gn2._scripts["OnClick"](gn2, "LeftButton")
check("clicking the selected box again empties the pane (it keeps its width)", gpop.empty and gpop.hint._shown and gpop._shown, gpop.empty)
check("... which takes the ring and the lit lines away", not any(f.sel._shown for f in gnodes_) and not any(f._vc is not None and f._vc[1] == 1 and f._vc[2] == 0.86 for f in glines_))
zin = gwin.gzoom.inn
z0 = gwin.gcanvas._scale
zin._scripts["OnClick"](zin)
check("the zoom button zooms in", gwin.gcanvas._scale > z0, (z0, gwin.gcanvas._scale))
gwin.gzoom.fit._scripts["OnClick"](gwin.gzoom.fit)
check("Fit goes back to fitting the chain in the view", 0.4 <= gwin.gcanvas._scale <= 1.0 and gwin.gcanvas._scale == z0, (z0, gwin.gcanvas._scale))
# the wheel: Alt sideways, Ctrl zoom, plain up and down
gwin.gcontent.GetWidth = lua.eval("function() return 3000 end")
gwin.gcontent.GetHeight = lua.eval("function() return 3000 end")
gwin.gscroll.SetVerticalScroll = lua.eval("function(s, v) _G.vsCalled = v end")
G.vsCalled = None
gwin.gscroll._hs = 0
G.testAlt = True
gwin.gscroll._scripts["OnMouseWheel"](gwin.gscroll, -1)
check("Alt+scroll moves the graph sideways", gwin.gscroll._hs == 60 and G.vsCalled == 0, (gwin.gscroll._hs, G.vsCalled))
G.testAlt = False
gwin.gscroll._hs = 0
gwin.gscroll._scripts["OnMouseWheel"](gwin.gscroll, -1)
check("plain scroll moves it up and down", gwin.gscroll._hs == 0 and G.vsCalled == 60, (gwin.gscroll._hs, G.vsCalled))
G.testCtrl = True
zc = gwin.gcanvas._scale
gwin.gscroll._scripts["OnMouseWheel"](gwin.gscroll, 1)
check("Ctrl+scroll zooms", gwin.gcanvas._scale != zc, (zc, gwin.gcanvas._scale))
G.testCtrl = False
gwin.gzoom.fit._scripts["OnClick"](gwin.gzoom.fit)
# on a 3840-wide screen it can show the whole chain, and on a small one it stays at its normal width
G.UIParent.GetWidth = lua.eval("function() return 3840 end")
gwin.tabGraph._scripts["OnClick"](gwin.tabGraph)
check("on a 3840-wide screen the window grows to the chain's full width", gwin._w2 == gneed + 310, (gwin._w2, gneed))
G.UIParent.GetWidth = lua.eval("function() return 800 end")
gwin.tabGraph._scripts["OnClick"](gwin.tabGraph)
check("on a small screen it never goes under its normal width", gwin._w2 == 850, gwin._w2)
G.UIParent.GetWidth = lua.eval("function() return 1920 end")
gwin.tabList._scripts["OnClick"](gwin.tabList)
check("the List tab goes back to the normal width", gwin._w2 == 850, gwin._w2)
# Across | Down: the chain drawn top to bottom
gwin.tabGraph._scripts["OnClick"](gwin.tabGraph)
check("the graph starts Across (Across lit, Down not)", gwin.gzoom.across.plate._shown and not gwin.gzoom.down.plate._shown and G.QuestThreadDB.graphDir is None, G.QuestThreadDB.graphDir)
across_pts = {f.questId: (f._pt[4], f._pt[5]) for f in G.stubs.values() if f._shown and f.cur is not None and f.meta is not None and f.questId is not None}
gwin.gzoom.down._scripts["OnClick"](gwin.gzoom.down)
check("Down is lit, Across not, and the choice is remembered", gwin.gzoom.down.plate._shown and not gwin.gzoom.across.plate._shown and G.QuestThreadDB.graphDir == "down")
dnodes = [f for f in G.stubs.values() if f._shown and f.cur is not None and f.meta is not None and f.questId is not None]
check("Down still has a box for every quest", sorted(f.questId for f in dnodes) == sorted(main_ids + opt_ids), len(dnodes))
bad = [(f.questId, f._pt[4], f._pt[5]) for f in dnodes if f._pt[4] != 18 + glayout.nodes[f.questId].row * 194 or f._pt[5] != -(18 + glayout.nodes[f.questId].col * 112)]
check("each box sits in its step's row and its slot's column", not bad, bad[:3])
dn = {f.questId: f for f in dnodes}
check("a step runs down the page: a quest sits below its prerequisites", all(dn[ed["from"]]._pt[5] > dn[ed["to"]]._pt[5] for ed in glayout.edges.values()), None)
dlines = [f for f in G.stubs.values() if f._shown and f._start is not None and f._end is not None]
check("every line is straight along an axis in Down too", len(dlines) >= len(glayout.edges) and all(f._start[1] == f._end[1] or f._start[2] == f._end[2] for f in dlines), (len(dlines), len(glayout.edges)))
missing = []
for ed in glayout.edges.values():
    a, b = dn[ed["from"]], dn[ed["to"]]
    ax, ay = a._pt[4] + 88, a._pt[5] - 60   # bottom middle of the prerequisite (y is negative: downward)
    bx, by = b._pt[4] + 88, b._pt[5]        # top middle of the quest it unlocks
    leaves = any(f._start[1] == ax and f._start[2] == ay for f in dlines)
    enters = any(f._end[1] == bx and f._end[2] == by for f in dlines)
    if not (leaves and enters):
        missing.append((ed["from"], ed["to"], leaves, enters))
check("every line leaves the bottom of one box and enters the top of the next", not missing, missing[:3])
check("Down is as wide as its widest step needs, never past half the screen", gwin._w2 >= 850 and gwin._w2 <= 960, gwin._w2)
gwin.gzoom.across._scripts["OnClick"](gwin.gzoom.across)
back_pts = {f.questId: (f._pt[4], f._pt[5]) for f in G.stubs.values() if f._shown and f.cur is not None and f.meta is not None and f.questId is not None}
check("Across brings the first layout back", back_pts == across_pts and G.QuestThreadDB.graphDir == "across", G.QuestThreadDB.graphDir)
gwin.tabList._scripts["OnClick"](gwin.tabList)
check("the List tab goes back to the list (and the choice is remembered)", gwin.scroll._shown and not gwin.gscroll._shown and not gwin.gzoom._shown and G.QuestThreadDB.chainView == "list" and gwin.tabList.plate._shown)
check("the list is shown again: a row per quest", all(chain_row(i) is not None for i in main_ids + opt_ids))
G.SlashCmdList["QUESTTHREAD"]("")

# ---- My Log: your own quest log ----
def tbl(d):
    return lua.table_from({k: (tbl(v) if isinstance(v, dict) else v) for k, v in d.items()})
log_entries = {
    1: {"title": "Elwynn Forest", "isHeader": True, "isCollapsed": False},
    2: {"title": "The Defias Brotherhood", "questID": 166, "level": 20, "isHeader": False},
    3: {"title": "Morbent Fel", "questID": 55, "level": 11, "isHeader": False},
    4: {"title": "Westfall", "isHeader": True, "isCollapsed": False},
    5: {"title": "A Farm Chore", "questID": 5, "level": 12, "isHeader": False},
    6: {"title": "Duskwood", "isHeader": True, "isCollapsed": True},
}
G.logInfo = tbl(log_entries)
old_log = {k: G.C_QuestLog[k] for k in ("GetNumQuestLogEntries", "GetInfo", "GetLogIndexForQuestID")}
G.C_QuestLog.GetNumQuestLogEntries = lua.eval("function() return 6 end")
G.C_QuestLog.GetInfo = lua.eval("function(i) return logInfo[i] end")
G.C_QuestLog.IsComplete = lua.eval("function(id) return id == 55 end")
G.C_QuestLog.GetLogIndexForQuestID = lua.eval("function(id) return 1 end")
G.C_QuestLog.GetQuestObjectives = lua.eval("function(id) if id == 166 then return { { text = 'Giver slain: 3/8', finished = false }, { text = 'Odd Thing: 0/2', finished = false } } end end")
lwin = frame_named("QuestThreadFrame")
G.SlashCmdList["QUESTTHREAD"]("log")
def log_rows():
    rs = [f for f in G.stubs.values() if f._shown and f.name is not None and f.tag is not None and f._pt is not None and f.status is not None]
    return sorted(rs, key=lambda f: -f._pt[5])
lr = log_rows()
check("/qthread log opens My Log, its tab lit", ns2.UI.IsLogMode() and lwin.tabLog.plate._shown and not lwin.tabChain.plate._shown and not lwin.tabZone.plate._shown, lwin.title._text)
check("My Log is headed 'My quest log' and says how many are ready", lwin.title._text == "My quest log" and "3 quests in your log" in lwin.sub._text and "1 ready to turn in" in lwin.stats._text and "2 in progress" in lwin.stats._text, (lwin.sub._text, lwin.stats._text))
check("the search box now filters the log", lwin.hint._text == "Filter your quest log")
lheads = [r.name._text for r in lr if r.fold._shown]
check("the game's own zone headers come first, in the game's order, a folded one with its note", lheads == ["|cffffd100Elwynn Forest|r", "|cffffd100Westfall|r", "|cffffd100Duskwood|r"] and any("Folded shut" in r.name._text for r in lr), lheads)
lq = {r.questId: r for r in lr if r.entry is not None}
check("a row per quest in the log", sorted(lq) == [5, 55, 166])
check("a quest ready to turn in says so, with the done icon", "Ready to turn in" in lq[55].sub._text and abs(lq[55].status._tc[1] - 0) < 1e-9, (lq[55].sub._text, lq[55].status._tc))
check("a quest in progress shows its first unfinished objective and how many more", "Giver slain: 3/8" in lq[166].sub._text and "+1 more" in lq[166].sub._text and abs(lq[166].status._tc[1] - 1 / 8) < 1e-9, lq[166].sub._text)
check("a quest that is part of a chain has the chain-link icon", lq[166].chain._shown, lq[166].chain._shown)
check("each quest says where you hand it in, as in the Chains view", all(r.where._shown and r.where._text.find("Hand in: ") >= 0 for r in lq.values()), [r.where._text for r in lq.values()])
check("the hand-in place is a link to that zone's map", any(b._shown and b.link.kind == "zone" for b in lq[166].links.values()), [(b.link.kind if b.link else None) for b in lq[166].links.values()])
lq[166]._scripts["OnClick"](lq[166], "LeftButton")
lpop = frame_named("QuestThreadObjectives")
check("clicking a quest fills its details, staying in My Log", lpop is not None and lpop._shown and not lpop.empty and ns2.UI.IsLogMode())
lq[166]._scripts["OnClick"](lq[166], "LeftButton")
for part in list(lpop.itemRows.values()) + list(lpop.textRows.values()):  # (the stubs do not hide a hidden frame's children)
    part._shown = False
# filter
lwin.box.SetText(lwin.box, "morbent")
lwin.box._scripts["OnTextChanged"](lwin.box, True)
lr = log_rows()
check("typing filters the log by name and drops the headers with nothing left", [r.questId for r in lr if r.entry is not None] == [55] and [r.name._text for r in lr if r.fold._shown] == ["|cffffd100Elwynn Forest|r"], [r.name._text for r in lr])
lwin.box.SetText(lwin.box, "zzz")
lwin.box._scripts["OnTextChanged"](lwin.box, True)
check("a filter matching nothing says so", any("No quest in your log matches" in r.name._text for r in log_rows()))
lwin.box.SetText(lwin.box, "")
lwin.box._scripts["OnTextChanged"](lwin.box, True)
# fold a header
lh = next(r for r in log_rows() if r.fold._shown and "Elwynn Forest" in r.name._text)
lh._scripts["OnClick"](lh, "LeftButton")
check("a zone header folds its quests away", not any(r.questId in (166, 55) for r in log_rows() if r.entry is not None) and any(r.questId == 5 for r in log_rows() if r.entry is not None))
lh = next(r for r in log_rows() if r.fold._shown and "Elwynn Forest" in r.name._text)
lh._scripts["OnClick"](lh, "LeftButton")
# the log changing
G.C_QuestLog.GetNumQuestLogEntries = lua.eval("function() return 3 end")
lwin._scripts["OnEvent"](lwin, "QUEST_LOG_UPDATE")
check("My Log follows the quest log (QUEST_LOG_UPDATE)", "2 quests in your log" in lwin.sub._text, lwin.sub._text)
G.C_QuestLog.GetNumQuestLogEntries = lua.eval("function() return 0 end")
lwin._scripts["OnEvent"](lwin, "QUEST_LOG_UPDATE")
check("an empty quest log says so", any("Your quest log is empty" in r.name._text for r in log_rows()), [r.name._text for r in log_rows()])
# leaving and coming back clears the filter
lwin.box.SetText(lwin.box, "abc")
lwin.box._scripts["OnTextChanged"](lwin.box, True)
lwin.tabChain._scripts["OnClick"](lwin.tabChain)
check("another tab: not in My Log any more, and the box is empty", not ns2.UI.IsLogMode() and lwin.box._text == "")
lwin.tabLog._scripts["OnClick"](lwin.tabLog)
check("the My Log tab opens it again", ns2.UI.IsLogMode() and lwin.hint._text == "Filter your quest log")
G.C_QuestLog.GetNumQuestLogEntries = old_log["GetNumQuestLogEntries"]
G.C_QuestLog.GetInfo = old_log["GetInfo"]
G.C_QuestLog.GetLogIndexForQuestID = old_log["GetLogIndexForQuestID"]
G.C_QuestLog.IsComplete = None
G.C_QuestLog.GetQuestObjectives = None
lwin.tabChain._scripts["OnClick"](lwin.tabChain)
G.SlashCmdList["QUESTTHREAD"]("")

# ---- where a quest's objectives happen ----
def lookups():
    return lua.eval("""
      {
        npcName = function(n) return ({ [1] = "Boar", [2] = "Wolf", [3] = "Bandit" })[n] end,
        npcSpawns = function(n) return ({ [1] = { [10] = { {1,1}, {2,2}, {3,3} }, [20] = { {1,1} } }, [2] = { [20] = { {1,1}, {2,2} } },
                                          [3] = { [30] = { {1,1} } } })[n] end,
        objName = function(o) return ({ [9] = "Chest" })[o] end,
        objSpawns = function(o) return ({ [9] = { [40] = { {1,1} } } })[o] end,
        itemName = function(i) return ({ [5] = "Fang" })[i] end,
        npcDrops = function(i) if i == 5 then return { 1, 2 } end end,
        objDrops = function(i) return nil end,
      }""")


raw = lua.eval("{ { { 1, 'x' } }, { { 9, 'y' } }, { { 5, 'z' } } }")
trigger = lua.eval("{ 'Reach the camp', { [50] = { {1,1} } } }")
got = list(Core.Objectives(raw, trigger, lookups()).values())
check("objectives: a kill lists the zones its spawns are in, most spawn points first", got[0]["kind"] == "kill" and got[0]["name"] == "Boar" and list(got[0]["areas"].values()) == [10, 20], (got[0]["name"], list(got[0]["areas"].values())))
check("objectives: an object lists its zone", got[1]["kind"] == "object" and list(got[1]["areas"].values()) == [40])
check("objectives: an item lists the zones and names of what drops it", got[2]["kind"] == "item" and got[2]["name"] == "Fang" and list(got[2]["areas"].values()) == [10, 20] and list(got[2]["from"].values()) == ["Boar", "Wolf"], (list(got[2]["areas"].values()), list(got[2]["from"].values())))
check("objectives: an explore trigger lists its zone", got[3]["kind"] == "explore" and got[3]["name"] == "Reach the camp" and list(got[3]["areas"].values()) == [50])
credit = list(Core.Objectives(lua.eval("{ nil, nil, nil, nil, { { { 1, 3 }, 3, 'Bandits' } } }"), None, lookups()).values())
check("objectives: a kill-credit objective covers every npc that counts", len(credit) == 1 and credit[0]["name"] == "Bandit" and sorted(credit[0]["areas"].values()) == [10, 20, 30], credit)
check("objectives: nothing recorded gives an empty list", len(list(Core.Objectives(None, None, lookups()).values())) == 0)
top, total = Core.TopAreas(Core.Objectives(raw, trigger, lookups()), 3)
check("top areas: the zones shared by several objectives come first, and the rest are counted", list(top.values()) == [10, 20, 40] and total == 4, (list(top.values()), total))

boar = Core.Objectives(lua.eval("{ { { 1, 'x' } } }"), None, lookups())
a, x, y, o = Core.BestSpot(boar, None)
check("best spot: the point nearest the middle of the biggest crowd", (a, x, y) == (10, 2, 2) and o["name"] == "Boar", (a, x, y))
a2, x2, y2, _ = Core.BestSpot(boar, lua.eval("function(area) return area ~= 10 end"))
check("best spot skips areas that cannot be shown on a map", (a2, x2, y2) == (20, 1, 1), (a2, x2, y2))
check("best spot with no objectives is nil", Core.BestSpot(lua.table(), None) is None)

G.SlashCmdList["QUESTTHREAD"]("166")
wrows = [f for f in G.stubs.values() if f._shown and f.entry is not None and f.entry.id == 166]
check("a chain row shows the zones of its objectives", wrows and wrows[0].where._shown and "Elwynn Forest" in wrows[0].where._text, wrows[0].where._text if wrows else None)
other = [f for f in G.stubs.values() if f._shown and f.entry is not None and f.entry.id != 166]
check("a quest with no objectives shows where it is handed in", other and all(f.where._shown and f.where._text.find("Hand in: ") >= 0 for f in other), [f.where._text for f in other][:2])
G.tipLines = lua.table()
wrows[0]._scripts["OnEnter"](wrows[0])
tip = list(G.tipLines.values())
check("the tooltip lists each objective with its zones", any(l.startswith("Kill Test Giver") and "Elwynn Forest" in l for l in tip), tip)
check("the tooltip says what drops a collected item", any(l.startswith("Collect Odd Thing (from Test Giver") for l in tip), tip)

check("zone names come from the area itself", ns2.Data.ZoneName(1) == "Dun Morogh" and ns2.Data.ZoneName(3) == "Badlands", (ns2.Data.ZoneName(1), ns2.Data.ZoneName(3)))
check("an area the game has no name for falls back to its map's name", ns2.Data.ZoneName(12) == "Elwynn Forest")
check("an area with no name anywhere shows its id", ns2.Data.ZoneName(51) == "Zone 51")
# ---- reused rows keep the right layout; Back returns to the list ----
G.SlashCmdList["QUESTTHREAD"]("defias")          # result rows move each row's name
G.SlashCmdList["QUESTTHREAD"]("166")             # ...then a chain reuses those rows
chain_rows = [f for f in G.stubs.values() if f._shown and f.entry is not None]
bad = [(len(f.name._pts), f.name._pts[1][2]) for f in chain_rows if len(f.name._pts) != 1 or f.name._pts[1][2] != 46]
check("chain rows put the quest name back after a search list reused them", len(chain_rows) >= 8 and not bad, bad[:3])
kwin = G.QuestThreadFrame if False else next(f for f in G.stubs.values() if f._name == "QuestThreadFrame")
loose = [f.name._text for f in G.stubs.values() if f._shown and f.entry is None and f.questId is None and f.name is not None and f.name._text
         and not f.name._text.startswith("Item rewards")]
check("rows without a quest (reputation, breadcrumbs) carry no old name text", not loose, loose[:3])
check("no Back button when the chain was not picked from a list", kwin.back._shown is False)
G.SlashCmdList["QUESTTHREAD"]("defias")
pick = [f for f in G.stubs.values() if f._shown and f.questId and f.entry is None and f.name is not None and "#" in (f.name._text or "")][0]
pick._scripts["OnClick"](pick, "LeftButton")
check("picking from a list shows a Back button", kwin.back._shown is True)
G.SlashCmdList["QUESTTHREAD"]("")
kwin.back._scripts["OnClick"](kwin.back)
back_rows = [f for f in G.stubs.values() if f._shown and f.questId and f.entry is None and f.name is not None and "#" in (f.name._text or "")]
check("Back returns to the same list", len(back_rows) >= 2 and kwin.back._shown is False, len(back_rows))
pick = back_rows[0]
pick._scripts["OnClick"](pick, "LeftButton")
chain_row = next(f for f in G.stubs.values() if f._shown and f.entry is not None and f.questId != pick.questId)
chain_row._scripts["OnClick"](chain_row, "LeftButton")
check("Back is still there after moving around inside the chain", kwin.back._shown is True)
G.SlashCmdList["QUESTTHREAD"]("166")
check("opening a quest another way clears Back", kwin.back._shown is False)

# ---- Ctrl+click on a reward item opens the dressing room ----
G.dressed = lua.table()
G.DressUpItemLink = lua.eval("function(link) dressed[#dressed + 1] = link; return true end")
G.SlashCmdList["QUESTTHREAD"]("166")
item_btns = [f for f in G.stubs.values() if f.itemId is not None and f._shown]
check("reward icons exist to click", len(item_btns) > 0)
if item_btns:
    b = item_btns[0]
    G.testCtrl = False
    b._scripts["OnClick"](b, "LeftButton")
    check("a plain click on a reward item does nothing", len(list(G.dressed.values())) == 0)
    G.testCtrl = True
    b._scripts["OnClick"](b, "LeftButton")
    G.testCtrl = False
    got = list(G.dressed.values())
    check("Ctrl+click on a reward item opens the dressing room on it", got == ["item:%d" % b.itemId], got)
G.DressUpItemLink = None

# ---- Ctrl+click on a Questie quest icon ----
def ctrl_click(focus, ctrl=True, hold_ticks=1):
    win._shown = False
    G.testCtrl, G.testFocus, G.testMouse = ctrl, focus, True
    for _ in range(hold_ticks):
        tick()
    G.testMouse, G.testCtrl = False, False
    tick()
    return win._shown


quest_icon = G.makeIcon("QuestieFrame12", lua.table_from({"Id": 55, "QuestData": lua.table_from({"Id": 55})}))
check("Ctrl+click on a Questie quest icon opens that quest's chain", ctrl_click(quest_icon) and any(f._text == "Morbent Fel" for f in G.stubs.values()))
check("plain click on the icon does nothing", not ctrl_click(quest_icon, ctrl=False))
check("Ctrl+click on a non-quest Questie icon does nothing", not ctrl_click(G.makeIcon("QuestieFrame13", lua.table_from({"Id": 55}))))
check("Ctrl+click on some other frame does nothing", not ctrl_click(G.makeIcon("SomeOtherFrame", lua.table_from({"Id": 55, "QuestData": lua.table_from({"Id": 55})}))))
check("Ctrl+click on empty space does nothing", not ctrl_click(None))
# stacked icons: every quest behind the cursor is offered
G.testFoci = lua.table_from([G.makeIcon("QuestieFrame20", lua.table_from({"Id": 55, "QuestData": lua.table_from({"Id": 55})})),
                             G.makeIcon("QuestieFrame21", lua.table_from({"Id": 166, "QuestData": lua.table_from({"Id": 166})})),
                             G.makeIcon("QuestieFrame22", lua.table_from({"Id": 55, "QuestData": lua.table_from({"Id": 55})}))])
for f in G.stubs.values():
    f._text = ""
opened = ctrl_click(None)
rows_shown = [f for f in G.stubs.values() if f._shown and f.questId and f.entry is None and f.name is not None and "#" in (f.name._text or "")]
shown_ids = sorted(f.questId for f in rows_shown)
check("Ctrl+click on stacked icons lists each quest once to pick from", opened and shown_ids == [55, 166], shown_ids)
check("the list says how many quests share the icon", any("2 quests share that icon" in (f._text or "") for f in G.stubs.values()))
G.testFoci = None
# one icon whose Questie tooltip lists several quests
single = G.makeIcon("QuestieFrame30", lua.table_from({"Id": 55, "QuestData": lua.table_from({"Id": 55})}))
G.GameTooltip.IsShown = lua.eval("function() return true end")
G.GameTooltip._owner = single
G.GameTooltip.npcAndObjectOrder = lua.table_from({"Giver": lua.table_from({"a": lua.table_from({"questId": 166}), "b": lua.table_from({"questId": 55}), "c": lua.table_from({"title": "no id"})})})
G.GameTooltip.questOrder = lua.table_from({55: lua.table_from([])})
for f in G.stubs.values():
    f._text = ""
opened = ctrl_click(single)
rows_shown = [f for f in G.stubs.values() if f._shown and f.questId and f.entry is None and f.name is not None and "#" in (f.name._text or "")]
check("Ctrl+click on one icon lists every quest in Questie's tooltip", opened and sorted(f.questId for f in rows_shown) == [55, 166], sorted(f.questId for f in rows_shown))
G.GameTooltip._owner = G.makeIcon("QuestieFrame31", lua.table_from({"Id": 99}))
opened = ctrl_click(single)
check("a tooltip owned by another icon is ignored", opened and not [f for f in G.stubs.values() if f._shown and f.entry is None and f.questId == 166 and "#" in ((f.name._text if f.name is not None else "") or "")])
G.GameTooltip.IsShown = lua.eval("function() return false end")
G.GameTooltip.npcAndObjectOrder = None
G.GameTooltip.questOrder = None
G.testCtrl, G.testFocus, G.testMouse = True, quest_icon, True
tick(); win._shown = False; tick()
check("holding the click down opens it once, not every frame", not win._shown)
G.testMouse, G.testCtrl = False, False
tick()

# ---- the button keeps clear of the row's "(Dungeon)" tag ----
row_t, row_p = G.makeLaidOutRow(166, 300), G.makeLaidOutRow(55, None)
before = len(clickers())
tick()
new2 = clickers()[before:]
check("two laid-out rows each get a button", len(new2) == 2, len(new2))
check("a row with a (Dungeon) tag: the button sits left of the tag", new2[0]._pt[4] == -(400 - (300 - 4)), new2[0]._pt)
check("a row without a tag: the button keeps its default place (the row's title is ignored)", new2[1]._pt[4] == -34, new2[1]._pt)

# ---- lead-in (breadcrumb) quests ----
cidx = Core.NewIndex()
Core.AddQuest(cidx, 10, lua.table_from({"bcs": lua.table_from([11, 12])}))
Core.AddQuest(cidx, 11, lua.table_from({"bcFor": 10, "next": 10}))
Core.AddQuest(cidx, 12, lua.table_from({"bcFor": 10, "next": 10}))
cinfo = lua.eval("function(id) return {name='Q'..id, level=id} end")
cc = Core.Chain(cidx, 10, cinfo)
entry10 = list(cc.layers[1].values())[0]
check("a chain entry carries its lead-in quests, sorted, with their details",
      [c.id for c in entry10.crumbs.values()] == [11, 12] and entry10.crumbs[1].name == "Q11" and entry10.crumbs[1].leadsTo == 10 and entry10.crumbs[1].level == 11,
      [c.id for c in entry10.crumbs.values()])
check("the lead-ins are not part of the chain's steps or count", cc.quests == 1 and cc.parts == 1)
check("opened from a lead-in itself, the chain contains it and does not repeat it", Core.Chain(cidx, 11, cinfo).quests == 2
      and all(len(list(e.crumbs.values())) == 1 and list(e.crumbs.values())[0].id == 12 for e in Core.Chain(cidx, 11, cinfo).layers[2].values()))
# the main line and the optional side quests of a chain: 1 -> 2 -> 4 is the main line, 3 hangs off 1 and leads nowhere
oidx = Core.NewIndex()
Core.AddQuest(oidx, 1, lua.table_from({}))
Core.AddQuest(oidx, 2, lua.table_from({"pre": lua.table_from([1])}))
Core.AddQuest(oidx, 3, lua.table_from({"pre": lua.table_from([1])}))
Core.AddQuest(oidx, 4, lua.table_from({"pre": lua.table_from([2])}))
oc = Core.Chain(oidx, 1, cinfo)
olab = {e.id: (e.label, e.optional) for layer in oc.layers.values() for e in layer.values()}
check("the main line is numbered 1, 2, 3 and a side quest is lettered after the quest it follows",
      olab == {1: ("1", False), 2: ("2", False), 3: ("a", True), 4: ("3", False)}, olab)
check("the chain counts its main and optional quests", oc.mainCount == 3 and oc.optionalCount == 1 and oc.quests == 4)
Core.AddQuest(oidx, 5, lua.table_from({"pre": lua.table_from([1])}))
oc2 = Core.Chain(oidx, 1, cinfo)
olab2 = {e.id: e.label for layer in oc2.layers.values() for e in layer.values()}
check("several side quests in a row are a, b, and the letters start again after the next main quest", olab2[3] == "a" and olab2[5] == "b" and olab2[4] == "3", olab2)
# the graph layout: columns are the steps, main quests first in a column, optional ones below
gl = Core.GraphLayout(oc2.layers, oidx.prevs)
gpos = {i: (n.col, n.row) for i, n in ((k, gl.nodes[k]) for k in (1, 2, 3, 4, 5))}
check("graph: a column per step, main quests on top and the side quests under them", gpos == {1: (0, 0), 2: (1, 0), 3: (1, 1), 5: (1, 2), 4: (2, 0)} and gl.cols == 3 and gl.rows == 3, gpos)
check("graph: an edge from each prerequisite to the quest it unlocks", [(e["from"], e.to) for e in gl.edges.values()] == [(1, 2), (1, 3), (1, 5), (2, 4)], [(e["from"], e.to) for e in gl.edges.values()])
gidx = Core.NewIndex()
Core.AddQuest(gidx, 10, lua.table_from({}))
Core.AddQuest(gidx, 11, lua.table_from({"pre": lua.table_from([10])}))  # a side quest with the smaller id
Core.AddQuest(gidx, 12, lua.table_from({"pre": lua.table_from([10])}))
Core.AddQuest(gidx, 13, lua.table_from({"pre": lua.table_from([12])}))
gl2 = Core.GraphLayout(Core.Chain(gidx, 10, cinfo).layers, gidx.prevs)
check("graph: the main quest is above the optional one in its column even when its id is higher", gl2.nodes[12].row == 0 and gl2.nodes[11].row == 1, (gl2.nodes[12].row, gl2.nodes[11].row))
# WoW Forever's Skyborne races: ids 95 / 96 sit at mask bits 32 / 33, not at bit id - 1
sky = 77 + 2 ** 32  # the four Alliance races of the old world plus Skyborne Alliance
check("Skyborne Alliance (95) can take a quest whose mask has bit 32, Skyborne Horde (96) cannot",
      Core.Eligible(sky, 0, 95, 1) is True and Core.Eligible(sky, 0, 96, 1) is False)
check("... and the ordinary races still follow the mask", Core.Eligible(sky, 0, 1, 1) is True and Core.Eligible(sky, 0, 2, 1) is False and Core.Eligible(2 ** 21, 0, 22, 1) is True and Core.Eligible(2 ** 21, 0, 1, 1) is False)
check("a race the addon does not know is never filtered out by race", Core.Eligible(77, 0, 500, 1) is True and Core.Eligible(77, 0, None, 1) is True and Core.Eligible(0, 0, 95, 1) is True)
check("the Horde Skyborne is not Alliance-only's", Core.Eligible(2 ** 33, 0, 96, 1) is True and Core.Eligible(2 ** 33, 0, 95, 1) is False)
mk_who = lua.eval("function(set, decisive) return { race = 1, class = 1, hasSkill = function(id) if set[id] then return true end if decisive then return false end return nil end } end")
alch = lua.table_from({171: True})
def allowed(info, set_=None, decisive=True):
    return Core.Allowed(lua.table_from(info), mk_who(lua.table_from(set_ or {}), decisive))
skill171 = {"skill": lua.table_from([171, 150])}
check("a profession quest is for you only with the profession learned", allowed(skill171, {171: True}) is True and allowed(skill171, {}) is False)
check("... and when the client cannot say which you have, it stays", allowed(skill171, {}, False) is True)
check("a skill that is not a profession (riding) never hides a quest", allowed({"skill": lua.table_from([762, 75])}, {}) is True)
rk = {"ranks": lua.table_from([lua.table_from([171, 1]), lua.table_from([164, 1])])}
check("with several professions listed, one of them is enough", allowed(rk, {164: True}) is True and allowed(rk, {171: True}) is True and allowed(rk, {}) is False)
check("no who: everyone", Core.Allowed(lua.table_from(skill171), None) is True)
check("race and profession both have to fit", allowed({"raceMask": 2, "skill": lua.table_from([171, 1])}, {171: True}) is False)
pidx = Core.NewIndex()
Core.AddQuest(pidx, 30, lua.table_from({}))
Core.AddQuest(pidx, 31, lua.table_from({"pre": lua.table_from([30])}))
Core.AddQuest(pidx, 32, lua.table_from({"pre": lua.table_from([31])}))
pinfo = lua.eval("function(id) return {name='Q'..id, level=id, skill = id == 31 and {171, 100} or nil} end")
def psteps(start, have):
    ch = Core.Chain(pidx, start, pinfo, mk_who(lua.table_from(have), True))
    return sorted(e.id for layer in ch.layers.values() for e in layer.values())
check("a chain step that needs a profession you lack is left out", psteps(30, {}) == [30, 32] and psteps(30, {171: True}) == [30, 31, 32], (psteps(30, {}), psteps(30, {171: True})))
check("... but the quest you opened stays", 31 in psteps(31, {}))
# faction: 11 is Horde-only (mask 178 = Orc/Undead/Tauren/Troll), 12 is Alliance-only (mask 77 = Human/Dwarf/NightElf/Gnome)
fact = lua.eval("function(id) local r = ({[11]=178,[12]=77})[id]; return {name='Q'..id, level=id, raceMask=r} end")
def crumb_ids(race, cls=1):
    ch = Core.Chain(cidx, 10, fact, lua.table_from({"race": race, "class": cls}) if race else None)
    e = list(ch.layers[1].values())[0]
    return [c.id for c in e.crumbs.values()], [b.id for b in ch.breadcrumbs.values()]
check("an Alliance character sees only the Alliance lead-in", crumb_ids(1) == ([12], [12]), crumb_ids(1))
check("a Horde character sees only the Horde lead-in", crumb_ids(2) == ([11], [11]), crumb_ids(2))
# a chain with a faction step: 20 -> 21 (Horde) / 22 (Alliance) -> 23
fidx = Core.NewIndex()
Core.AddQuest(fidx, 20, lua.table_from({}))
Core.AddQuest(fidx, 21, lua.table_from({"pre": lua.table_from([20])}))
Core.AddQuest(fidx, 22, lua.table_from({"pre": lua.table_from([20])}))
Core.AddQuest(fidx, 23, lua.table_from({"preS": lua.table_from([21, 22])}))
finfo = lua.eval("function(id) local r = ({[21]=178,[22]=77})[id]; return {name='Q'..id, level=id, raceMask=r} end")
def step_ids(start, race):
    ch = Core.Chain(fidx, start, finfo, lua.table_from({"race": race, "class": 1}) if race else None)
    return sorted(e.id for layer in ch.layers.values() for e in layer.values()), ch.quests
check("an Alliance character's chain leaves out the Horde step but keeps the rest", step_ids(20, 1) == ([20, 22, 23], 3), step_ids(20, 1))
check("a Horde character's chain leaves out the Alliance step", step_ids(20, 2) == ([20, 21, 23], 3), step_ids(20, 2))
check("with no race known the chain has every step", step_ids(20, None) == ([20, 21, 22, 23], 4), step_ids(20, None))
check("the quest you opened stays even when it is for the other faction", step_ids(21, 1) == ([20, 21, 22, 23], 4), step_ids(21, 1))
check("with no race known both show", crumb_ids(None) == ([11, 12], [11, 12]), crumb_ids(None))
check("an entry with no lead-in has an empty list", len(list(Core.Chain(cidx, 11, cinfo).layers[1][1].crumbs.values())) == 0)
real5 = Core.Chain(idx, 5, lua_info)
e5 = next(e for layer in real5.layers.values() for e in layer.values() if e.id == 5)
check("real data: Jitters' Growling Gut (#5) has Raven Hill (#163) as its lead-in", [c.id for c in e5.crumbs.values()] == [163], [c.id for c in e5.crumbs.values()])

G.SlashCmdList["QUESTTHREAD"]("5")
crows = [f for f in G.stubs.values() if f._shown and f.questId == 163 and f.entry is not None]
check("the lead-in shows as a row in the chain window", len(crows) == 1, len(crows))
# ... but not for the other faction: Raven Hill made Alliance-only, then a Horde character opens the chain
G.QuestDB.requiredRaces = lua.eval("function(id) if id == 163 then return 77 end end")
G.UnitRace = lua.eval("function() return 'Orc', 'Orc', 2 end")
G.SlashCmdList["QUESTTHREAD"]("5")
check("a lead-in meant for the other faction is not drawn in the chain window",
      not [f for f in G.stubs.values() if f._shown and f.questId == 163 and f.entry is not None])
G.UnitRace = lua.eval("function() return 'Human', 'Human', 1 end")
G.SlashCmdList["QUESTTHREAD"]("5")
check("... and is drawn for your own faction", len([f for f in G.stubs.values() if f._shown and f.questId == 163 and f.entry is not None]) == 1)
G.QuestDB.requiredRaces = None
G.UnitRace = None
G.SlashCmdList["QUESTTHREAD"]("5")
crow = crows[0] if crows else None
row5 = next((f for f in G.stubs.values() if f._shown and f.questId == 5 and f.entry is not None and f.entry.leadsTo is None), None)
row93 = next((f for f in G.stubs.values() if f._shown and f.questId == 93 and f.entry is not None), None)
check("the lead-in row sits directly above the quest it leads into",
      crow is not None and row5 is not None and row93 is not None and crow._pt[5] > row5._pt[5] > row93._pt[5], (crow and crow._pt, row5 and row5._pt, row93 and row93._pt))
check("the lead-in row is named, tagged, numbered with its id", crow is not None and "Breadcrumb" in crow.tag._text and crow.tag._shown and "Breadcrumb" not in crow.name._text and "Raven Hill" in crow.name._text and "#163" in crow.name._text, crow and crow.name._text)
check("the lead-in row says which step it leads into", crow is not None and "leads into step 1" in crow.sub._text, crow and crow.sub._text)
check("the lead-in row has a status icon and an indent", crow is not None and crow.status._shown and crow.status._pt[2] == 38 and crow.name._pt[2] == 60, crow and (crow.status._pt, crow.name._pt))
check("the breadcrumb row's tag is at the right edge, top line (no XP there)", crow.tag._pt[1] == "TOPRIGHT" and crow.tag._pt[3] == -6, crow.tag._pt)
stats = [f._text for f in G.stubs.values() if f._text and "quests ·" in f._text]
check("the lead-in is not counted in the chain's quest total", any(("%d quests" % real5.quests) in t for t in stats), stats[:3])
G.tipLines = lua.table()
crow._scripts["OnEnter"](crow)
check("the lead-in's tooltip says what it leads into", any("leads into" in t and "Jitters" in t for t in G.tipLines.values()), list(G.tipLines.values())[:3])
check("the lead-in row carries the bread icon (item 4540's icon, here 100), left of the level",
      crow.name._text.startswith("|T100:") and crow.name._text.index("|T100:") < crow.name._text.index("["), crow.name._text)
row5_name = next(f for f in G.stubs.values() if f._shown and f.questId == 5 and f.entry is not None and f.entry.leadsTo is None).name._text
check("a quest that is not a breadcrumb has no bread icon", "|T" not in row5_name and "Breadcrumb" not in row5_name, row5_name)
keys = frame_named("QuestThreadKeys")
G.testCtrl = True
keys._scripts["OnKeyDown"](keys, "C")
G.testCtrl = False
check("Ctrl+C on a lead-in copies its own Wowhead link", frame_named("QuestThreadLinkFrame").box._text.endswith("quest=163"), frame_named("QuestThreadLinkFrame").box._text)
crow._scripts["OnLeave"](crow)
crow._scripts["OnClick"](crow, "LeftButton")
check("clicking the lead-in opens its own chain", any(f._text == "Raven Hill" for f in G.stubs.values()))
# a chain row reusing a lead-in row gets its normal layout back
G.SlashCmdList["QUESTTHREAD"]("5")
G.SlashCmdList["QUESTTHREAD"]("166")  # a longer chain: rows that held a lead-in now hold chain quests
chain_rows = [f for f in G.stubs.values() if f._shown and f.entry is not None and f.entry.leadsTo is None]
check("chain rows reusing a breadcrumb row show no tag", not any(f.tag._shown for f in chain_rows), [f.tag._text for f in chain_rows if f.tag._shown])
check("chain rows are back at the normal indent after a lead-in used the row", all(f.name._pt[2] == 46 and f.status._pt[2] == 24 for f in chain_rows), [(f.name._pt, f.status._pt) for f in chain_rows][:2])
# when the quest it leads into is already done, the lead-in says it is not needed any more
G.C_QuestLog.IsQuestFlaggedCompleted = lua.eval("function(id) return id == 5 end")
G.SlashCmdList["QUESTTHREAD"]("5")
crow = next(f for f in G.stubs.values() if f._shown and f.questId == 163 and f.entry is not None)
check("a lead-in is marked 'No longer needed' once its quest is done", "No longer needed" in crow.sub._text, crow.sub._text)
G.C_QuestLog.IsQuestFlaggedCompleted = lua.eval("function(id) return id == 65 end")
G.SlashCmdList["QUESTTHREAD"]("5")
check("the old 'Can also be reached through' footer is gone", not any("Can also be reached" in (f._text or "") for f in G.stubs.values() if f._shown))
G.SlashCmdList["QUESTTHREAD"]("")

# ---- bread icon on a breadcrumb opened as a step, in search rows and in the tooltip ----
G.SlashCmdList["QUESTTHREAD"]("163")
step163 = next((f for f in G.stubs.values() if f._shown and f.questId == 163 and f.entry is not None and f.entry.leadsTo is None), None)
check("a breadcrumb opened as a step shows the bread icon and a Breadcrumb tag",
      step163 is not None and "|T100:" in step163.name._text and "Breadcrumb" in step163.tag._text and step163.tag._shown, step163 and step163.name._text)
check("a breadcrumb step's name sits where any row's does, and the word is not in the name",
      step163.name._pt[2] == 46 and step163.status._pt[2] == 24 and "Breadcrumb" not in step163.name._text, (step163.name._pt, step163.status._pt))
check("the tag is at the right edge", step163.tag._pt[1] == "TOPRIGHT" and step163.tag._pt[2] < 0, step163.tag._pt)
G.tipLines = lua.table()
step163._scripts["OnEnter"](step163)
check("on a step row the bread icon is left of the level", step163.name._text.startswith("|T100:") and step163.name._text.index("[") > 0, step163.name._text)
check("its tooltip says it is a breadcrumb quest", any("Breadcrumb quest" in t for t in G.tipLines.values()), list(G.tipLines.values()))
step163._scripts["OnLeave"](step163)
ns2.UI.OpenIds(lua.table_from([163, 5]))
pick = {f.questId: f for f in G.stubs.values() if f._shown and f.entry is None and f.questId in (163, 5) and f.name is not None and "#" in (f.name._text or "")}
check("in a pick list the bread icon is left of the level", pick[163].name._text.startswith("|T100:"), pick[163].name._text)
check("in a pick list only the breadcrumb has the bread icon", "|T100:" in pick[163].name._text and "|T" not in pick[5].name._text, (pick[163].name._text, pick[5].name._text))

# ---- the objectives popup beside the window ----
def popup():
    return frame_named("QuestThreadObjectives")

def chain_row(qid):
    return next(f for f in G.stubs.values() if f._shown and f.questId == qid and f.entry is not None)

G.SlashCmdList["QUESTTHREAD"]("166")
def pane_open():
    return popup() is not None and popup()._shown and not popup().empty

check("opening a chain without clicking a quest leaves the pane empty, with a hint", popup() is not None and popup()._shown and popup().empty and popup().hint._shown and not popup().title._shown)
row166 = chain_row(166)
row166._scripts["OnClick"](row166, "RightButton")
check("a right-click (waypoint) does not fill the pane", not pane_open())
row166._scripts["OnClick"](row166, "LeftButton")
pop = popup()
check("clicking a quest fills the pane", pop is not None and pane_open() and not pop.hint._shown and pop.title._shown)
mainwin = frame_named("QuestThreadFrame")
p1 = pop._pts[1]
check("the details pane sits inside the window, at its right", p1[1] == "TOPLEFT" and G.rawequal(p1[2], mainwin) and p1[3] == "TOPLEFT" and p1[4] == 538 and p1[5] == -58, p1)
check("the window is the column plus the pane wide, filled or not", mainwin._w2 == 850, mainwin._w2)
body = popup_text()
check("the popup shows the quest's objective text", "Kill things." in body, body)
check("the popup lists the creature to kill and the item to collect", "Kill Test Giver" in body and "Collect Odd Thing" in body, body)
items = [b for b in pop.itemRows.values() if b._shown and b.itemId == 777]
check("the item to collect is its own row, with its icon, its line and nothing for the kill",
      len(items) == 1 and items[0].itemId == 777 and items[0].tex._tex == 100 and "Collect Odd Thing" in items[0].name._text
      and "Kill Test Giver" in popup_text() and "Kill Test Giver" not in items[0].name._text, [b.name._text for b in items])
G.tipLines = lua.table()
G.GameTooltip.SetHyperlink = lua.eval("function(s, link) _G.lastLink = link end")
G.lastLink = None
items[0]._scripts["OnEnter"](items[0])
check("hovering the item shows the game's own item tooltip", G.lastLink == "item:777" and G.GameTooltip._shown, G.lastLink)
check("hovering highlights the row; leaving clears it and hides the tooltip",
      items[0].hl._shown and (items[0]._scripts["OnLeave"](items[0]) or True) and not items[0].hl._shown and not G.GameTooltip._shown)
# rewards: XP, and every reward item as a hoverable row
want = sorted(int(k) for k, qs in json.load(open(data_path, encoding="utf-8"))["itemQuests"].items() if 166 in qs)
got = sorted(b.itemId for b in pop.itemRows.values() if b._shown and b.itemId != 777)
check("the popup lists the quest's reward items, one row each", len(want) > 0 and got == want, (want, got))
rb = next(b for b in pop.itemRows.values() if b._shown and b.itemId == want[0])
check("a reward row has its icon and a name", rb.tex._tex == 100 and "Item %d" % want[0] in rb.name._text, rb.name._text)
G.lastLink = None
rb._scripts["OnEnter"](rb); rb._scripts["OnLeave"](rb)
check("hovering a reward item shows its game tooltip", G.lastLink == "item:%d" % want[0], G.lastLink)
check("the popup has a Rewards section with the XP", "Rewards" in popup_text() and "XP" in popup_text(), popup_text())
check("the pane's body is sized to its contents (it scrolls inside the pane)", pop.body._h is not None and pop.body._h > 100 and pop.scroll is not None, pop.body._h)
check("the popup says where they are, and what drops the item", "Elwynn Forest" in body and "from Test Giver" in body, body)
check("the popup says where it starts and where it is handed in", "Starts" in body and "Hand in" in body and "Test Giver" in body, body)
check("out of the log the popup says counts come with the quest log", "once the quest is in your quest log" in body, body)
check("the popup title is the quest name, the line under it has the level", "Giver text" not in pop.title._text and "Level 30" in pop.sub._text, (pop.title._text, pop.sub._text))
# in the quest log: the game's own counts
G.testClientXp[166] = 500
G.C_QuestLog.GetQuestObjectives = lua.eval("function(id) if id == 166 then return { { text = 'Giver slain: 3/8', finished = false }, { text = 'Odd Thing: 8/8', finished = true } } end end")
row166 = chain_row(166)
ns2.UI.Open(166, True, True)  # (clicking the selected quest would let go of it)
body = popup_text()
check("a quest in your log shows its live counts", "Your progress" in body and "Giver slain: 3/8" in body and "Odd Thing: 8/8" in body, body)
check("a finished objective is green, an unfinished one is not", "|cff66e066Odd Thing: 8/8" in body and "|cff66e066Giver slain" not in body, body)
check("with live counts the 'once the quest is in your log' note is gone", "once the quest is in your quest log" not in body, body)
xpline = [l for l in popup_text().split(chr(10)) if l.endswith(" XP|r")]
check("a quest in your log shows the client's exact XP (no ~)", len(xpline) == 1 and "~" not in xpline[0] and "500 XP" in xpline[0], xpline)
check("the popup says the quest is in your log", "In your quest log" in popup().sub._text, popup().sub._text)
G.C_QuestLog.GetQuestObjectives = lua.eval("function(id) error('api blew up') end")
ns2.UI.Open(166, True, True)  # (clicking the selected quest would let go of it)
check("a failing quest-log API does not break the popup", pane_open() and "Kill Test Giver" in popup_text())
G.testClientXp[166] = None
G.C_QuestLog.GetQuestObjectives = lua.eval("function(id) return { { text = 'Giver slain: 3/8', finished = False } } end".replace("False", "false"))
ns2.UI.Open(166, True, True)
check("a quest that is not in your log shows no live counts even if the API answers",
      "Your progress" not in popup_text() and "3/8" not in popup_text(), popup_text())
G.C_QuestLog.GetQuestObjectives = None
# placement: beside the window on the right, flipped to the left when there is no room
for fr in (mainwin, G.UIParent):
    fr.GetEffectiveScale = lua.eval("function() return 1 end")
mainwin.GetRight = lua.eval("function() return 2100 end")
mainwin.GetLeft = lua.eval("function() return 1600 end")
mainwin.GetTop = lua.eval("function() return 900 end")
G.UIParent.GetRight = lua.eval("function() return 1920 end")
mainwin._pt = None
ns2.UI.ShowChains()
mp = mainwin._pt
check("with no room on the right the window slides left by what hangs over", mp is not None and mp[1] == "TOPLEFT" and G.rawequal(mp[2], G.UIParent) and mp[3] == "BOTTOMLEFT" and mp[4] == 1420 and mp[5] == 900, mp)
mainwin.GetRight = lua.eval("function() return 800 end")
mainwin._pt = None
ns2.UI.ShowChains()
check("with room on the right the window stays where it is", mainwin._pt is None, mainwin._pt)
mainwin.GetRight = None
mainwin.GetLeft = None
mainwin.GetTop = None
# a breadcrumb's popup says what it leads into
G.SlashCmdList["QUESTTHREAD"]("163")
b163 = chain_row(163)
b163._scripts["OnClick"](b163, "LeftButton")
check("a breadcrumb's popup carries the bread icon and says what it leads into",
      "|T100:" in popup().title._text and "Breadcrumb to" in popup().sub._text and "Jitters" in popup().sub._text, (popup().title._text, popup().sub._text))
# reputation reward
G.SlashCmdList["QUESTTHREAD"]("2")
r2 = chain_row(2)
r2._scripts["OnClick"](r2, "LeftButton")
check("the popup shows the reputation reward", "Faction81 +100" in popup_text(), popup_text())
# closing, re-opening, and picking from a list
check("(setup) the reputation quest's details are in the pane", pane_open())
r2 = chain_row(2)
r2._scripts["OnClick"](r2, "LeftButton")
check("clicking the selected quest again empties the pane, which keeps its width", popup().empty and popup().hint._shown and popup()._shown and mainwin._w2 == 850, (popup().empty, mainwin._w2))
mainwin.tabChain._scripts["OnClick"](mainwin.tabChain); mainwin.tabChain._scripts["OnClick"](mainwin.tabChain)  # two redraws of the chain
check("the pane stays empty through a redraw", popup().empty)
ns2.UI.OpenIds(lua.table_from([166, 5]))
pick166 = next(f for f in G.stubs.values() if f._shown and f.entry is None and f.questId == 166 and f.name is not None and "#" in (f.name._text or ""))
pick166._scripts["OnClick"](pick166, "LeftButton")
check("clicking a quest in a pick list opens its chain and fills the pane", pane_open() and "Kill Test Giver" in popup_text())
G.SlashCmdList["QUESTTHREAD"]("166")
check("opening a quest by other means empties the pane", popup().empty)
row166 = chain_row(166)
row166._scripts["OnClick"](row166, "LeftButton")
check("(setup) the pane is filled before the window is closed", pane_open())
ns2.UI.Toggle(); ns2.UI.Toggle()  # close the window and open it again
check("a selection does not come back when the window is closed and opened", mainwin._shown and popup().empty)
ns2.UI.ShowChains()

# ---- "You are here" opens the quest log on that quest ----
def last_print():
    return list(G.printed.values())[-1]

def here_buttons():
    return [f.here for f in G.stubs.values() if f.here is not None and f.here._shown]

G.testClientXp[166] = 500  # 166 is the quest in your log
G.SlashCmdList["QUESTTHREAD"]("166")
cur = chain_row(166)
hb = here_buttons()
check("only the quest in your quest log has the clickable 'You are here'", len(hb) == 1 and G.rawequal(hb[0], cur.here), len(hb))
G.SlashCmdList["QUESTTHREAD"]("65")
hb = here_buttons()
check("'You are here' stays on the quest in your log when you open another quest of the chain", len(hb) == 1 and G.rawequal(hb[0], chain_row(166).here) and chain_row(65).sub._text.find("You are here") < 0, len(hb))
G.SlashCmdList["QUESTTHREAD"]("166")
cur = chain_row(166)
G.openedLog = None
G.QuestMapFrame_OpenToQuestDetails = lua.eval("function(id) _G.openedLog = id end")
G.testClientXp[166] = None  # (it has left the log since the window was drawn)
cur.here._scripts["OnClick"](cur.here)
check("clicking it for a quest that is no longer in your log says so and opens nothing", G.openedLog is None and "isn't in your quest log" in last_print(), last_print())
G.testClientXp[166] = 500  # now in the log
cur.here._scripts["OnClick"](cur.here)
check("clicking it opens the quest log on that quest", G.openedLog == 166, G.openedLog)
G.openedLog = None
G.testCombat = True
cur.here._scripts["OnClick"](cur.here)
check("in combat it does not open the log and says why", G.openedLog is None and "combat" in last_print(), last_print())
G.testCombat = False
G.QuestMapFrame_OpenToQuestDetails = lua.eval("function(id) error('map blew up') end")
cur.here._scripts["OnClick"](cur.here)
check("an error in the game's function is reported, not thrown", "Couldn't open the quest log" in last_print(), last_print())
G.QuestMapFrame_OpenToQuestDetails = None
G.shownDetails = None
orig_show = G.QuestMapFrame_ShowQuestDetails
G.QuestMapFrame_ShowQuestDetails = lua.eval("function(id) _G.shownDetails = id end")
cur.here._scripts["OnClick"](cur.here)
check("without OpenToQuestDetails it falls back to showing the details", G.shownDetails == 166, G.shownDetails)
G.QuestMapFrame_ShowQuestDetails = orig_show
lit_before = cur.sub._text
G.tipLines = lua.table()
cur.here._scripts["OnEnter"](cur.here)
check("hovering lights up the words and says what a click does", "|cffffffffYou are here" in cur.sub._text and any("quest log" in t for t in G.tipLines.values()), (cur.sub._text, list(G.tipLines.values())[-2:]))
cur.here._scripts["OnLeave"](cur.here)
check("leaving puts the colour back", cur.sub._text == lit_before and "|cffffd100You are here" in cur.sub._text, cur.sub._text)
G.testClientXp[166] = None
G.testClientXp[5] = 300
G.SlashCmdList["QUESTTHREAD"]("5")
check("another chain: the button belongs to the quest of that chain that is in your log only", len(here_buttons()) == 1 and G.rawequal(here_buttons()[0], chain_row(5).here))
G.testClientXp[5] = None
G.testClientXp[166] = 500
G.SlashCmdList["QUESTTHREAD"]("5")
check("a chain with nothing in your log has no 'You are here' at all", len(here_buttons()) == 0)
G.testClientXp[166] = None
G.SlashCmdList["QUESTTHREAD"]("")

# ---- the zone index and models ----
Z = ns2.Zones
# two quests with no chain at all: one started by an object, one by an item
linked = set()
for qid, q in quests.items():
    for k in ("pre", "preS", "child", "bcs"):
        if q.get(k):
            linked.add(qid)
            linked.update(q[k])
    for k in ("next", "bcFor"):
        if q.get(k):
            linked.add(qid)
            linked.add(q[k])
solo_obj, solo_item, lost = sorted(i for i in quests if i not in linked)[:3]
G.solo = lua.table_from([solo_obj, solo_item])
G.lost = lost
# one quest is filed under Badlands (area 3) by the quest log, though its giver stands in Elwynn and Dun Morogh
G.QuestDB.zoneOrSort = lua.eval("function(id) if id == lost then return 3 end return 12 end")
G.QuestDB.startedBy = lua.eval("function(id) if id == solo[1] then return { {}, { 5000 } } elseif id == solo[2] then return { {}, {}, { 777 } } end return { { 1000 } } end")
G.ObjectDB.name = lua.eval("function(id) return id == 5000 and 'Old Poster' or nil end")
G.ObjectDB.spawns = lua.eval("function(id) if id == 5000 then return { [12] = { { 50, 50 } } } end end")
Z.Ensure = real_zones_ensure
Z.Ensure(lua.eval("function() end"))
for _ in range(500):
    if Z.state == "ready":
        break
    for f in list(G.stubs.values()):
        fn = f._scripts["OnUpdate"]
        if fn is not None:
            try:
                fn(f)
            except Exception:
                pass
check("the zone index builds in the background and becomes ready", Z.state == "ready", Z.state)
check("both areas the giver stands in have quests", Z.HasArea(12) and Z.HasArea(1) and not Z.HasArea(99999))
m12 = Z.Model(12)
all_ids = sorted(int(k) for k in quests)
check("a model lists every quest that starts in the area", sorted(m12.quests.values()) == all_ids, (len(m12.quests), len(all_ids)))
c65 = m12.chainOf[65]
check("a quest in a chain is grouped into it: the Defias chain is 8 quests in 7 steps", c65 is not None and len(c65.ids) == 8 and c65.parts == 7, c65 and (len(c65.ids), c65.parts))
check("a chain row opens on the first quest that starts here", c65.entry == c65.here[1], (c65.entry, c65.here[1]))
check("every chain quest that starts here is in exactly one group", all(m12.chainOf[i] is not None for i in c65.here.values()))
check("a breadcrumb is a single quest, not part of a chain", m12.chainOf[163] is None and 163 in list(m12.singles.values()))
og = {g.name: g for g in m12.objGroups.values()}
check("quests started only by an object or an item are grouped by that giver", sorted(og) == ["Odd Thing", "Old Poster"]
      and og["Old Poster"].kind == "object" and list(og["Old Poster"].quests.values()) == [solo_obj]
      and og["Odd Thing"].kind == "item" and list(og["Odd Thing"].quests.values()) == [solo_item], {k: (g.kind, list(g.quests.values())) for k, g in og.items()})
check("those quests are not also listed as single quests", solo_obj not in m12.singles.values() and solo_item not in m12.singles.values())
gv = {g.name: g for g in m12.givers.values()}
check("every giver is listed with its quests", sorted(gv) == ["Odd Thing", "Old Poster", "Test Giver"] and len(gv["Test Giver"].quests) == len(all_ids) - 2, {k: len(g.quests) for k, g in gv.items()})
check("a quest is listed in the zone the quest log files it under, though its giver stands elsewhere",
      Z.HasArea(3) and list(Z.Model(3).quests.values()) == [lost] and lost in Z.Model(12).quests.values(), (Z.HasArea(3), lost))
check("... and that zone has the quest's giver", [g.name for g in Z.Model(3).givers.values()] == ["Test Giver"])
ev3 = Z.Evaluate(Z.Model(3))
check("... with its status (a quest in your log counts as in log there)", ev3.totals.quests == 1 and (ev3.totals.log + ev3.totals.available + ev3.totals.done + ev3.totals.missed + ev3.totals.locked) == 1)
check("an item that drops from an NPC here starts its quest in each area the NPC stands in", Z.HasArea(1) and any(g.name == "Odd Thing" for g in Z.Model(1).givers.values()))
names = [z.name for z in Z.List().values()]
check("the zone list has names, sorted", names == sorted(names) and "Elwynn Forest" in names and "Dun Morogh" in names, names)
check("a zone can be found by part of its name", [z.name for z in Z.Find("elw").values()] == ["Elwynn Forest"] and len(Z.Find("")) == len(names))
check("a map belongs to the area with that map", Z.AreaForMap(1429) == 12 and Z.AreaForMap(5) is None)
G.C_Map.GetBestMapForUnit = lua.eval("function() return 1429 end")
check("your current area comes from the map you stand in", Z.CurrentArea() == 12)

# who the quests are for
G.UnitRace = lua.eval("function() return 'Human', 'Human', 1 end")
G.QuestDB.requiredRaces = lua.eval("function(id) if id == 2 then return 178 end end")  # a Horde-only quest
Z.Reset()
m12 = Z.Model(12)
check("a quest for another faction is left out of the zone", 2 not in m12.quests.values() and len(m12.quests) == len(all_ids) - 1, len(m12.quests))
# a Skyborne character (race id 95 Alliance / 96 Horde): QuestieDB's mask has them at bits 32 / 33
G.UnitRace = lua.eval("function() return 'Skyborne', 'Skyborne', 95 end")
G.QuestDB.requiredRaces = lua.eval("function(id) if id == 2 then return 4294967373 end end")  # Alliance races + Skyborne Alliance
Z.Reset()
check("a Skyborne Alliance character gets the quests QuestieDB lists for their side", 2 in Z.Model(12).quests.values() and len(Z.Model(12).quests) == len(all_ids))
G.UnitRace = lua.eval("function() return 'Skyborne', 'Skyborne', 96 end")
Z.Reset()
check("... and a Skyborne Horde character does not", 2 not in Z.Model(12).quests.values())
G.QuestDB.requiredRaces = None
# a profession quest is only listed when you have the profession
pq = [i for i in all_ids if i != 2][0]
G.QuestDB.requiredSkill = lua.eval("function(id) if id == %d then return { 171, 150 } end end" % pq)
G.GetProfessions = lua.eval("function() end")
G.GetProfessionInfo = lua.eval("function() end")
Z.Reset()
check("a profession quest is left out of a zone for someone without the profession", pq not in Z.Model(12).quests.values() and len(Z.Model(12).quests) == len(all_ids) - 1, len(Z.Model(12).quests))
G.GetProfessions = lua.eval("function() return 1 end")
G.GetProfessionInfo = lua.eval("function(i) return 'Alchemy', 0, 1, 300, 0, 0, 171 end")
check("... and appears as soon as they learn it, with no reset", pq in Z.Model(12).quests.values() and len(Z.Model(12).quests) == len(all_ids))
G.GetProfessions = None
G.GetProfessionInfo = None
Z.Reset()
check("when the client cannot list professions the quest stays", pq in Z.Model(12).quests.values())
G.QuestDB.requiredSkill = None
G.UnitRace = None
G.QuestDB.requiredRaces = None
Z.Reset()
m12 = Z.Model(12)
c65 = m12.chainOf[65]

# statuses
ev = Z.Evaluate(m12)
check("a finished quest is done; the totals add up", ev.quest[65].status == "done" and ev.totals.quests == len(all_ids)
      and ev.totals.done + ev.totals.log + ev.totals.available + ev.totals.locked + ev.totals.missed == ev.totals.quests, dict(ev.totals))
G.C_QuestLog.IsQuestFlaggedCompleted = lua.eval("function(id) return id == 166 end")  # the last step is done, the earlier ones are not
ev_late = Z.Evaluate(m12)
skipped = [i for i in all_ids if ev_late.quest[i].status == "missed" and (ev_late.quest[i].detail[1] or "").startswith("Skipped")]
check("a step before a finished one is marked missed: skipped", len(skipped) > 0, [(i, ev_late.quest[i].status) for i in c65.ids.values()])
check("a skipped step names the later step", any("Skipped: you already did a later step, " in ev_late.quest[i].detail[1] for i in skipped))
check("the chain with a late step done is a missed chain, not done", ev_late.chain[c65].status != "done" and ev_late.chain[c65].counts.missed > 0)
G.C_QuestLog.IsQuestFlaggedCompleted = lua.eval("function(id) return id == 65 end")
check("the chain with a finished step is not done and has a count", ev.chain[c65].status != "done" and ev.chain[c65].counts.done >= 1, dict(ev.chain[c65].counts))
G.UnitLevel = lua.eval("function() return 60 end")
ev60 = Z.Evaluate(m12)
outl = [i for i in all_ids if (ev60.quest[i].greyNote or "").startswith("Outleveled")]
check("outleveled quests stay available, with a grey note, and are not counted as missed", len(outl) > 0
      and all(ev60.quest[i].status == "available" and len(ev60.quest[i].detail) == 0 for i in outl) and ev60.totals.missed == ev.totals.missed, (dict(ev60.totals), dict(ev.totals)))
check("done quests stay done at any level", ev60.quest[65].status == "done")
check("a chain with outleveled steps is still available, and counts them as grey, not missed", ev60.chain[c65].status == "available" and ev60.chain[c65].counts.missed == 0 and ev60.chain[c65].counts.grey > 0, (ev60.chain[c65].status, dict(ev60.chain[c65].counts)))
check("a locked quest you have outleveled stays locked (you cannot take it yet)", all(ev60.quest[i].status != "locked" or ev60.quest[i].greyNote is None for i in all_ids))
G.UnitLevel = lua.eval("function() return 20 end")
G.C_QuestLog.IsQuestFlaggedCompleted = lua.eval("function(id) return true end")
evall = Z.Evaluate(m12)
check("a chain with every quest done is done", evall.chain[c65].status == "done" and evall.totals.done == len(all_ids), (evall.chain[c65].status, dict(evall.totals)))
G.C_QuestLog.IsQuestFlaggedCompleted = lua.eval("function(id) return id == 65 end")
check("filters: all matches anything; a status matches itself", Z.Matches("all", "missed") and Z.Matches("missed", "missed") and not Z.Matches("done", "missed"))
check("filters: a chain with outleveled steps matches Available and not Missed", Z.ChainMatches("available", ev60.chain[c65]) and not Z.ChainMatches("missed", ev60.chain[c65]))
check("filters: a chain matches when any quest does; done only when all are", Z.ChainMatches("done", ev.chain[c65]) is False and Z.ChainMatches("missed", ev.chain[c65]) == (ev.chain[c65].counts.missed > 0))

# ---- difficulty colours, who can take a quest, and missed quests ----
D = Core.Difficulty
check("difficulty: 5 or more above you is red, 3-4 orange, within 2 either way yellow",
      D(25, 20, 8) == "red" and D(30, 20, 8) == "red" and D(24, 20, 8) == "orange" and D(23, 20, 8) == "orange"
      and D(22, 20, 8) == "yellow" and D(20, 20, 8) == "yellow" and D(18, 20, 8) == "yellow")
check("difficulty: green while it is within the green range below you, then grey",
      D(17, 20, 8) == "green" and D(12, 20, 8) == "green" and D(11, 20, 8) == "grey")
check("difficulty: the green range is the game's, not fixed", D(15, 20, 3) == "grey" and D(17, 20, 3) == "green")
check("difficulty: an unknown level has none", D(None, 20, 8) is None and D(0, 20, 8) is None and D(20, None, 8) is None)
check("difficulty colours: red is red, green is green", Core.DIFFICULTY.red[4] == "|cffff1a1a" and Core.DIFFICULTY.green[4] == "|cff40bf40")
E = Core.Eligible
check("eligible: no mask means anyone", E(None, None, 1, 1) and E(0, 0, 2, 3))
check("eligible: the Alliance mask (77) takes a Human and a Gnome, not an Orc", E(77, None, 1, 1) and E(77, None, 7, 1) and not E(77, None, 2, 1))
check("eligible: the Horde mask (178) takes an Orc, not a Human", E(178, None, 2, 1) and not E(178, None, 1, 1))
check("eligible: a class mask (Hunter = 4) takes a Hunter (3), not a Rogue (4)", E(None, 4, 1, 3) and not E(None, 4, 1, 4))
state_done, state_log, mctx = lua.eval("""function(Core)
  local done, inlog = {}, {}
  local infos = { [1] = { level = 10 }, [2] = { pre = { 1 }, level = 10 }, [3] = { preS = { 1, 4 }, level = 10 }, [4] = { level = 10 },
                  [5] = { level = 10, maxLevel = 15 }, [6] = { level = 10 }, [7] = { level = 3 }, [8] = { level = 10, pre = { 9 } } }
  local nexts = { [1] = { [2] = true, [3] = true }, [4] = { [3] = true }, [9] = { [8] = true } }
  local function ctx(player)
    return { isDone = function(i) return done[i] end, inLog = function(i) return inlog[i] end, nexts = nexts,
      info = function(i) return infos[i] end,
      exclusive = function(i) if i == 6 then return { 7 } end return {} end,
      nameOf = function(i) return 'Q' .. i end, level = player or 10, greenRange = 8 }
  end
  return done, inlog, ctx
end""")(Core)
def MRK(q, c):
    r = Core.MissedReason(q, c)
    return r if isinstance(r, tuple) else (r, None)
def MR(q, c):
    return MRK(q, c)[0]
check("missed: nothing done, nothing missed", MR(1, mctx(10)) is None)
state_done[2] = True
check("missed: a later step that needed it is done", MR(1, mctx(10)) == "Skipped: you already did a later step, Q2", MR(1, mctx(10)))
state_done[2] = None
state_done[3] = True
check("missed: a later step that takes one of several alternatives, none of the others done", (MR(1, mctx(10)) or "").startswith("Skipped"))
state_done[4] = True
check("missed: ... but not once another alternative was the one you did", MR(1, mctx(10)) is None, MR(1, mctx(10)))
state_done[3] = None; state_done[4] = None
state_log[2] = True
check("missed: a later step in your log counts too", (MR(1, mctx(10)) or "").startswith("Skipped"))
state_log[2] = None
check("missed: a later step whose prerequisite is another quest does not make this one missed", MR(9, mctx(10)) is None)
state_done[8] = True
check("missed: ... unless that quest is the prerequisite", (MR(9, mctx(10)) or "").startswith("Skipped"))
state_done[8] = None
state_done[7] = True
check("missed: an exclusive quest is done", MR(6, mctx(10)) == "Excluded by Q7", MR(6, mctx(10)))
check("kinds: excluded is missed", MRK(6, mctx(10))[1] == "missed")
state_done[7] = None
check("missed: over its level cap", "level cap" in (MR(5, mctx(16)) or "") and MR(5, mctx(15)) is None)
check("kinds: over the cap is missed, outleveled is grey", MRK(5, mctx(16))[1] == "missed" and MRK(1, mctx(19))[1] == "grey", (MRK(5, mctx(16)), MRK(1, mctx(19))))
check("missed: outleveled means grey to you", (MR(1, mctx(19)) or "").startswith("Outleveled") and MR(1, mctx(18)) is None, (MR(1, mctx(19)), MR(1, mctx(18))))

# ---- the level in each row has the game's difficulty colour ----
G.SlashCmdList["QUESTTHREAD"]("166")
check("a quest 5 or more levels above you has a red level", "|cffff1a1a[30]|r" in chain_row(166).name._text, chain_row(166).name._text)
G.UnitLevel = lua.eval("function() return 34 end")
G.SlashCmdList["QUESTTHREAD"]("166")
check("a quest a few levels below you has a green level", "|cff40bf40[30]|r" in chain_row(166).name._text, chain_row(166).name._text)
G.UnitLevel = lua.eval("function() return 20 end")
G.SlashCmdList["QUESTTHREAD"]("")

# ---- the area -> map tables QuestieDB publishes as text chunks ----
check("a map is found through a table of text chunks (QuestieDB's form)", ns2.Data.UiMap(12) == 1429, ns2.Data.UiMap(12))
check("an override from a chunk wins and adds areas", ns2.Data.UiMap(16) == 1447)
check("an override of 0 means no map", ns2.Data.UiMap(1537) is None and ns2.Data.UiMap(0) is None)
check("an unknown area has no map", ns2.Data.UiMap(99999) is None)
check("the reverse lookup finds the area of a map", ns2.Data.AreaOfUiMap(1429) == 12 and ns2.Data.AreaOfUiMap(5) is None)

# ---- clickable places: zones open the map, a dungeon opens the Dungeon Journal ----
def shown_links():
    return [f for f in G.stubs.values() if f.link is not None and f._shown]

def where_of(qid):
    return chain_row(qid).where._text

def links_of(qid):
    fs = chain_row(qid).where
    return sorted((b for b in shown_links() if G.rawequal(b.fs, fs)), key=lambda b: b._pt[4])

G.ForeverDungeonJournal_NS = None
G.SlashCmdList["QUESTTHREAD"]("166")
check("without the journal there is no Dungeon: segment", "Dungeon:" not in where_of(166), where_of(166))
zl = links_of(166)
check("each zone of the where line is a link", [b.link.kind for b in zl] == ["zone", "zone"] and [b.link.area for b in zl] == [1, 12], [(b.link.kind, b.link.area) for b in zl])
check("the first link starts at the text's left edge, the next one further right", zl[0]._pt[4] == 0 and zl[1]._pt[4] > 0, [b._pt[4] for b in zl])
check("the links sit on the where line", G.rawequal(zl[0]._pt[2], chain_row(166).where))
G.waypointCalls.opened = None
zl[1]._scripts["OnClick"](zl[1])
check("clicking a zone opens the world map on that area's map", G.waypointCalls.opened == 1429, G.waypointCalls.opened)
G.waypointCalls.opened = None
zl[0]._scripts["OnClick"](zl[0])
check("a zone with no known map says so and opens nothing", G.waypointCalls.opened is None and "No map is known for Dun Morogh" in last_print(), last_print())
G.tipLines = lua.table()
zl[1]._scripts["OnEnter"](zl[1])
check("hovering a zone lights it up and says what a click does", "|cffffffffElwynn Forest" in where_of(166) and any("open the map on Elwynn Forest" in t for t in G.tipLines.values()), (where_of(166), list(G.tipLines.values())))
zl[1]._scripts["OnLeave"](zl[1])
check("leaving puts the colour back", "|cffffffff" not in where_of(166), where_of(166))
# with the journal
G.journalCall = None
G.ForeverDungeonJournal_NS = lua.eval("{ DB = { ['Test Dungeon'] = { quests = { { id = 166 }, { id = 5 } } }, ['Alpha Keep'] = { quests = { { id = 166 } } } }, OpenQuestPage = function(name, id) _G.journalCall = { name, id } end }")
G.SlashCmdList["QUESTTHREAD"]("166")
check("with the journal the quest's dungeon is the first segment", where_of(166).startswith("|cffe0a64aDungeon: Alpha Keep|r"), where_of(166))
dl = links_of(166)
check("the dungeon is a link too, left of the zones", [b.link.kind for b in dl] == ["dungeon", "zone", "zone"] and dl[0]._pt[4] == 0 and dl[1]._pt[4] > 0, [(b.link.kind, b._pt[4]) for b in dl])
dl[0]._scripts["OnClick"](dl[0])
check("clicking the dungeon opens the journal on that quest in its dungeon", G.journalCall is not None and G.journalCall[1] == "Alpha Keep" and G.journalCall[2] == 166, G.journalCall)
check("a quest listed under two dungeons goes to the first by name", ns2.Data.DungeonOf(166) == "Alpha Keep" and ns2.Data.DungeonOf(5) == "Test Dungeon")
G.tipLines = lua.table()
dl[0]._scripts["OnEnter"](dl[0])
check("the dungeon link's tooltip names the dungeon", any("Dungeon Journal (Alpha Keep)" in t for t in G.tipLines.values()), list(G.tipLines.values()))
dl[0]._scripts["OnLeave"](dl[0])
# the journal's window has to be shown first (OpenQuestPage alone only picks the page)
G.journalShown = False
G.ForeverDungeonJournalFrame = lua.eval("{ IsShown = function() return journalShown end, Show = function() journalShown = true end }")
G.journalCall = None
dl[0]._scripts["OnClick"](dl[0])
check("the journal window is shown when it was closed", G.journalShown is True and G.journalCall is not None and G.journalCall[1] == "Alpha Keep", (G.journalShown, G.journalCall))
G.ForeverDungeonJournal_NS.ToggleJournal = lua.eval("function() journalToggled = (journalToggled or 0) + 1; journalShown = not journalShown end")
G.journalShown = False
dl[0]._scripts["OnClick"](dl[0])
check("it uses the journal's own toggle when there is one, once", G.journalToggled == 1 and G.journalShown is True, (G.journalToggled, G.journalShown))
dl[0]._scripts["OnClick"](dl[0])
check("an open journal is left open (not toggled shut)", G.journalToggled == 1 and G.journalShown is True)
G.ForeverDungeonJournal_NS.IsDungeonLocked = lua.eval("function(name) return name == 'Alpha Keep' end")
G.journalCall = None
dl[0]._scripts["OnClick"](dl[0])
check("a locked dungeon is reported, not silently ignored", G.journalCall is None and "still locked" in last_print(), last_print())
G.ForeverDungeonJournal_NS.IsDungeonLocked = None
G.ForeverDungeonJournal_NS.ToggleJournal = None
G.ForeverDungeonJournalFrame = None
G.ForeverDungeonJournal_NS.OpenQuestPage = lua.eval("function() error('journal blew up') end")
dl[0]._scripts["OnClick"](dl[0])
check("an error in the journal is reported, not thrown", "Couldn't open the Dungeon Journal" in last_print(), last_print())
G.ForeverDungeonJournal_NS.OpenQuestPage = lua.eval("function(name, id) _G.journalCall = { name, id } end")
G.SlashCmdList["QUESTTHREAD"]("166")
for mode in (None, "shift", "alt"):
    r = chain_row(166)
    G.testShift, G.testAlt = mode == "shift", mode == "alt"
    try:
        r._scripts["OnClick"](r, "RightButton")
        err = None
    except Exception as e:
        err = e
    check("right-click on a dungeon quest (%s) does not throw" % mode, err is None, err)
G.testShift, G.testAlt = False, False
G.SlashCmdList["QUESTTHREAD"]("5")
check("a quest in a dungeon shows it, one outside none", "Dungeon: Test Dungeon" in where_of(5) and ("Dungeon:" not in where_of(93)), (where_of(5), where_of(93)))
check("every shown link sits on a where line that is showing", all(b.fs._shown for b in shown_links()))
# with a Dungeon Journal link the dungeon's own area is not also a zone link (its map is the same place, and often missing)
fdj_keep = G.ForeverDungeonJournal_NS
G.ForeverDungeonJournal_NS = lua.eval("{ DB = { ['Elwynn Forest'] = { quests = { { id = 166 } } } }, OpenQuestPage = function() end }")
G.SlashCmdList["QUESTTHREAD"]("166")
dl = links_of(166)
check("with a journal link, the area named like the dungeon is not also a zone link",
      where_of(166).startswith("|cffe0a64aDungeon: Elwynn Forest|r") and where_of(166).count("Elwynn Forest") == 1
      and [b.link.kind for b in dl] == ["dungeon", "zone"] and [b.link.area for b in dl[1:]] == [1], (where_of(166), [(b.link.kind, b.link.area) for b in dl]))
G.ForeverDungeonJournal_NS = lua.eval("{ DB = { ['Elwynn Forest Depths'] = { quests = { { id = 166 } } } }, OpenQuestPage = function() end }")
G.SlashCmdList["QUESTTHREAD"]("166")
check("... also when the dungeon's name holds the area's name", where_of(166).count("Elwynn Forest") == 1 and "Dun Morogh" in where_of(166), where_of(166))
G.ForeverDungeonJournal_NS = None
G.SlashCmdList["QUESTTHREAD"]("166")
check("without the journal both zones are links as before", [b.link.area for b in links_of(166)] == [1, 12])
# a zone the game has no map for (a dungeon's own map, say) is not opened: Blizzard's world map throws on it
zl = links_of(166)
G.C_Map.GetMapInfo = lua.eval("function() return nil end")
G.waypointCalls.opened = None
zl[1]._scripts["OnClick"](zl[1])
check("a zone whose map the game does not have says so and does not open the map", G.waypointCalls.opened is None and "The game has no map for" in last_print(), (G.waypointCalls.opened, last_print()))
wres = ns2.Data.Waypoint(lua.table_from({"uiMap": 1429, "x": 50, "y": 50, "area": 12}), "test")
check("a waypoint on such a map is refused too, without opening it", wres[0] is False and G.waypointCalls.opened is None, wres)
G.C_Map.GetMapInfo = lua.eval("function() return { name = 'Elwynn Forest' } end")
G.ForeverDungeonJournal_NS = fdj_keep
# the popup has the same links, in a Where section
G.SlashCmdList["QUESTTHREAD"]("166")
r166 = chain_row(166)
ns2.UI.Open(166, True, True)  # (clicking the selected quest would let go of it)
pl = popup().linkRows
check("the popup has a Where section: a dungeon line, then a zone line", "Where" in popup_text() and "Dungeon: Alpha Keep" in pl[1].fs._text and "Elwynn Forest" in pl[2].fs._text, (pl[1].fs._text, pl[2].fs._text))
pdl = [b for b in pl[1].links.values() if b._shown]
pzl = [b for b in pl[2].links.values() if b._shown]
check("the popup's dungeon and zones are links", [b.link.kind for b in pdl] == ["dungeon"] and [b.link.kind for b in pzl] == ["zone", "zone"], ([b.link.kind for b in pdl], [b.link.kind for b in pzl]))
G.journalCall = None
pdl[0]._scripts["OnClick"](pdl[0])
check("the popup's dungeon link opens the journal", G.journalCall is not None and G.journalCall[1] == "Alpha Keep")
G.waypointCalls.opened = None
pzl[1]._scripts["OnClick"](pzl[1])
check("the popup's zone link opens the map", G.waypointCalls.opened == 1429, G.waypointCalls.opened)
# without the journal the popup has the zone line only, and the dungeon line is gone from a re-shown popup
G.ForeverDungeonJournal_NS = None
r166 = chain_row(166)
ns2.UI.Open(166, True, True)  # (clicking the selected quest would let go of it)
check("without the journal the popup shows no dungeon link", not any(b._shown and b.link.kind == "dungeon" for r in popup().linkRows.values() for b in r.links.values()))
G.SlashCmdList["QUESTTHREAD"]("")

# ---- the Zones tab ----
def zone_rows():
    rs = [f for f in G.stubs.values() if f._shown and f.name is not None and f.tag is not None and f._pt is not None and f.status is not None]
    return sorted(rs, key=lambda f: -f._pt[5])

def chips():
    order = ["available", "log", "missed", "done", "all"]
    return sorted((f for f in G.stubs.values() if f.key is not None and f.label is not None), key=lambda f: order.index(f.key))

mainwin = frame_named("QuestThreadFrame")
m12 = Z.Model(12)
entry65 = m12.chainOf[65].entry
G.QuestThreadDB.zone = None
G.SlashCmdList["QUESTTHREAD"]("zone elwynn")
check("/qthread zone <name> opens the Zones tab on that zone", ns2.UI.IsZoneMode() and mainwin.title._text == "Elwynn Forest", mainwin.title._text)
check("the Zones tab is the lit one", mainwin.tabZone.under._shown and not mainwin.tabChain.under._shown)
check("the filter starts on Available, the box asks for a zone", G.QuestThreadDB.zone.filter == "available" and mainwin.hint._text == "Zone name")
check("the views are pill tabs in the header, the lit one on a plate", mainwin.tabZone.plate._shown and not mainwin.tabChain.plate._shown and mainwin.tabZone._size[1] == 58 and mainwin.tabZone._size[2] == 26 and not mainwin.tabLog.plate._shown)
check("the search box leaves room for the three group tabs on the Zones tab", mainwin.box._w2 == 540 - 28 - 220 - 8, mainwin.box._w2)
tz = Z.Model(12)
evz = Z.Evaluate(tz)
check("the progress bar is shown, with available in gold as wide as its share and no blue (nothing in your log)",
      mainwin.prog._shown and mainwin.progAvail._shown and not mainwin.progLog._shown
      and mainwin.progAvail._size[1] == round(512 * evz.totals.available / evz.totals.quests)
      and mainwin.progDone._shown == (round(512 * evz.totals.done / evz.totals.quests) > 0), (mainwin.progAvail._size, dict(evz.totals)))
check("the lit chip is on a plate, the others are not", chips()[0].plate._shown and not chips()[1].plate._shown and not chips()[4].plate._shown)
check("section headers have a band", all(r.hl._shown for r in zone_rows() if r.entry is None))
cs = chips()
check("five filter chips with just their names (no counts), Missed among them, and no Grey chip", [c.key for c in cs] == ["available", "log", "missed", "done", "all"] and [c.text._text for c in cs] == ["Available", "In log", "Missed", "Done", "All"] and cs[0].under._shown and not cs[4].under._shown,
      [(c.key, c.text._text) for c in cs])
rows = zone_rows()
check("the list starts right under the chips", rows[0]._pt[5] == -32, rows[0]._pt)
heads = [r.name._text for r in rows if r.entry is None]
check("by type: sections for chains and single quests", any("Chains" in h for h in heads) and any("Single quests" in h for h in heads), heads)
# the sections fold shut
ch_head = next(r for r in rows if r.entry is None and "Chains" in r.name._text)
n_rows = len([r for r in rows if r.entry is not None])
check("an open section's header has the minus icon", ch_head.fold._shown and ch_head.fold._tex.endswith("UI-MinusButton-Up") and ch_head.name._pt[2] == 28, ch_head.fold._tex)
ch_head._scripts["OnClick"](ch_head, "LeftButton")
rows_f = zone_rows()
ch_head_f = next(r for r in rows_f if r.entry is None and "Chains" in r.name._text)
check("clicking a section header folds it: plus icon, its rows gone, the other sections stay",
      ch_head_f.fold._tex.endswith("UI-PlusButton-Up") and not any(r.questId == entry65 for r in rows_f) and any("Single quests" in r.name._text for r in rows_f if r.entry is None)
      and len([r for r in rows_f if r.entry is not None]) < n_rows)
cs_f = chips()
cs_f[4]._scripts["OnClick"](cs_f[4])
cs_f[0]._scripts["OnClick"](cs_f[0])
check("a folded section stays folded through a redraw", not any(r.questId == entry65 for r in zone_rows()))
ch_head_f = next(r for r in zone_rows() if r.entry is None and "Chains" in r.name._text)
ch_head_f._scripts["OnClick"](ch_head_f, "LeftButton")
rows = zone_rows()
check("... and opens again", any(r.questId == entry65 for r in rows) and len([r for r in rows if r.entry is not None]) == n_rows)
chain_row_z = next((r for r in rows if r.questId == entry65), None)
check("a chain is one row: how much is done under it, a chain-link icon at its right, and no steps/levels text",
      chain_row_z is not None and chain_row_z.xp._text == "" and "of 8 done" in chain_row_z.sub._text and chain_row_z.chain._shown, chain_row_z and (chain_row_z.xp._text, chain_row_z.sub._text))
check("the right-hand text leaves room for the icon", chain_row_z.tag._pt[2] == -28, chain_row_z.tag._pt)
G.tipLines = lua.table()
chain_row_z._scripts["OnEnter"](chain_row_z)
ztip = list(G.tipLines.values())
check("a chain row's tooltip says how the chain stands before the first quest's details", len(ztip) > 2 and ztip[1].startswith("Chain of ") and " done, " in ztip[1] and "first" in ztip[2], ztip[:3])
chain_row_z._scripts["OnLeave"](chain_row_z)
one_z = next((r for r in rows if r.entry is not None and not r.chain._shown), None)
if one_z is not None:
    G.tipLines = lua.table()
    one_z._scripts["OnEnter"](one_z)
    check("a single quest's tooltip has no chain line", not any(str(l).startswith("Chain of ") for l in G.tipLines.values()), list(G.tipLines.values())[:3])
    one_z._scripts["OnLeave"](one_z)
check("quest and chain rows start with the quest's level in its colour", all("|cff" in r.name._text and "[" in r.name._text for r in rows if r.entry is not None))
singles_here = set(m12.singles.values())
check("a single quest that is in no chain has no chain-link icon", all(not r.chain._shown for r in rows if r.questId in singles_here and ns2.Zones.Model(12).chainOf[r.questId] is None))
check("only the single quests the filter allows are listed", len(rows) > 3 and all(r.entry.status == "available" for r in rows if r.questId in singles_here), len(rows))
# opening the window: the search starts empty, and the Zones tab opens on the area you stand in
other_area = [a.area for a in Z.List().values() if a.area != 12][0]
ns2.UI.ShowZones(other_area)
check("(setup) the Zones tab is on another area", mainwin.title._text == ns2.Data.ZoneName(other_area), mainwin.title._text)
mainwin.box.SetText(mainwin.box, "something typed earlier")
ns2.UI.Toggle()
check("(setup) the window is closed", not mainwin._shown)
ns2.UI.Toggle()
check("opening the window clears what was typed in the search box", mainwin.box._text == "" and mainwin.hint._shown, mainwin.box._text)
check("opening the Zones tab shows the area you are standing in, not the one you left it on", mainwin.title._text == "Elwynn Forest", mainwin.title._text)
ns2.UI.Toggle(); ns2.UI.ShowZones(other_area)
check("opening it on a given area keeps that area", mainwin.title._text == ns2.Data.ZoneName(other_area), mainwin.title._text)
ns2.UI.ShowChains(); ns2.UI.ShowZones()
check("a click on the Zones tab while the window is open shows the list of zones (not your area)", mainwin.title._text == "Zones" and ns2.UI.IsZoneMode(), mainwin.title._text)
# Zones is the tab it opens on, even when it was left on Chains, and on the area you are in even when it was left elsewhere
ns2.UI.ShowZones(other_area)
ns2.UI.ShowChains()
ns2.UI.Toggle()
check("(setup) closed with Chains up", not mainwin._shown and not ns2.UI.IsZoneMode())
ns2.UI.Toggle()
check("opening it (minimap button, /qthread) lands on the Zones tab, on your area", ns2.UI.IsZoneMode() and mainwin.title._text == "Elwynn Forest" and mainwin.tabZone.plate._shown, (ns2.UI.IsZoneMode(), mainwin.title._text))
ns2.UI.ShowZones(other_area)
ns2.UI.ShowChains()
G.SlashCmdList["QUESTTHREAD"]("")
G.SlashCmdList["QUESTTHREAD"]("")
check("... and so does /qthread on its own", ns2.UI.IsZoneMode() and mainwin.title._text == "Elwynn Forest", mainwin.title._text)
ns2.UI.ShowZones(12)
# clicking a row: the popup, on the Zones tab
chain_row_z._scripts["OnClick"](chain_row_z, "LeftButton")
check("clicking a zone row fills the details pane and stays on the Zones tab", pane_open() and ns2.UI.IsZoneMode())
check("the pane has no Chain button any more (the row has the icon)", popup().chainBtn is None)
chain_row_z._scripts["OnClick"](chain_row_z, "LeftButton")
check("clicking the selected zone row again empties the pane", popup().empty and popup()._shown)
chain_row_z._scripts["OnClick"](chain_row_z, "LeftButton")
check("... and once more fills it", pane_open())
G.tipLines = lua.table()
chain_row_z.chain._scripts["OnEnter"](chain_row_z.chain)
check("hovering the row's chain icon says what it does", "Open this quest's chain" in list(G.tipLines.values()), list(G.tipLines.values()))
chain_row_z.chain._scripts["OnClick"](chain_row_z.chain)
check("the row's chain icon opens that quest's chain, with its details", not ns2.UI.IsZoneMode() and mainwin.title._text == ns2.Data.Name(entry65) and pane_open(), mainwin.title._text)
# the Zones tab: the list of all zones, by continent, with progress
def pump(n=60):
    for _ in range(n):
        for f in list(G.stubs.values()):
            fn = f._scripts["OnUpdate"]
            if fn is not None:
                try:
                    fn(f, 0.016)
                except Exception:
                    pass

G.C_Map.GetMapInfo = lua.eval("function(m) if m == 1429 then return { name = 'Elwynn Forest', mapType = 3, parentMapID = 1415 } elseif m == 1415 then return { name = 'Eastern Kingdoms', mapType = 2, parentMapID = 947 } end return { name = 'Elwynn Forest' } end")
mainwin.tabZone._scripts["OnClick"](mainwin.tabZone)
irows = zone_rows()
ihead = [r for r in irows if r.fold._shown]
check("the Zones tab lists every zone, split by continent: Eastern Kingdoms first, Other last",
      mainwin.title._text == "Zones" and [r.name._text for r in ihead] == ["|cffffd100Eastern Kingdoms|r", "|cffffd100Other|r"], [r.name._text for r in ihead])
check("the list has no Back button and no chips", not mainwin.back._shown and not any(f._shown and f.key is not None and f.label is not None for f in G.stubs.values()))
elw = next(r for r in irows if "Elwynn Forest" in r.name._text and not r.fold._shown)
check("Elwynn Forest is under Eastern Kingdoms, marked as where you are", ihead[0]._pt[5] > elw._pt[5] > -10 ** 6 and elw._pt[5] > ihead[1]._pt[5] and "you are here" in elw.name._text, (ihead[0]._pt, elw._pt, ihead[1]._pt))
check("the zones' numbers are worked out after the list is up: a placeholder first", "…" in elw.xp._text, elw.xp._text)
pump()
prog = Z.Progress(12)
check("every zone row gets its progress, as 'done / total', with a bar",
      elw.xp._text.endswith("%d / %d|r" % (prog.done, prog.total)) and elw.meter._shown, (elw.xp._text, dict(prog)))
check("a zone with nothing done shows a grey count and no fill", ("|cff9a9488" in elw.xp._text) == (prog.done == 0) and elw.meterFill._shown == (prog.done > 0))
check("the continent header shows its own total", ihead[0].xp._text.endswith("%d / %d|r" % (prog.done, prog.total)), ihead[0].xp._text)
check("the stats line and the bar give the overall progress", "quests done" in mainwin.stats._text and mainwin.prog._shown, mainwin.stats._text)
# a continent folds shut
ihead[0]._scripts["OnClick"](ihead[0], "LeftButton")
check("clicking a continent folds its zones away", not any("Elwynn Forest" in r.name._text for r in zone_rows() if not r.fold._shown))
ihead = [r for r in zone_rows() if r.fold._shown]
ihead[0]._scripts["OnClick"](ihead[0], "LeftButton")
check("... and opens them again", any("Elwynn Forest" in r.name._text for r in zone_rows() if not r.fold._shown))
# a click on a zone opens it, as when it is searched for; the way back is the All zones button
elw = next(r for r in zone_rows() if "Elwynn Forest" in r.name._text and not r.fold._shown)
elw._scripts["OnClick"](elw, "LeftButton")
check("clicking a zone opens it like a search does", mainwin.title._text == "Elwynn Forest" and any(c.key == "available" for c in chips()))
check("the zone view has an All zones button back", mainwin.back._shown and mainwin.back.text._text == "All zones", mainwin.back.text._text)
mainwin.back._scripts["OnClick"](mainwin.back)
check("All zones goes back to the list", mainwin.title._text == "Zones" and not mainwin.back._shown)
ns2.UI.OpenZoneText("elwynn")
check("searching for a zone still opens it (from the list too)", mainwin.title._text == "Elwynn Forest" and mainwin.back._shown)
mainwin.tabZone._scripts["OnClick"](mainwin.tabZone)
check("a click on the Zones tab from a zone goes to the list", mainwin.title._text == "Zones")
G.C_Map.GetMapInfo = lua.eval("function() return { name = 'Elwynn Forest' } end")
ns2.UI.ShowZones(12)
check("(setup) back on Elwynn Forest", mainwin.title._text == "Elwynn Forest")
check("by type is lit at first, by giver dim", mainwin.tabType.under._shown and not mainwin.tabGiver.under._shown and mainwin.tabGiver.text._color[1] < 0.7 and mainwin.tabType.text._color[1] == 1)
mainwin.tabGiver._scripts["OnClick"](mainwin.tabGiver)
check("By giver lights up (underline, bright) and By type dims", mainwin.tabGiver.under._shown and not mainwin.tabType.under._shown and mainwin.tabType.text._color[1] < 0.7 and mainwin.tabGiver.text._color[1] == 1)
rows = zone_rows()
gh = [r for r in rows if r.entry is None]
tg = next((h for h in gh if "Test Giver" in h.name._text), None)
check("by giver: one header per quest giver (NPCs, objects, items), open, with counts", len(gh) == 3 and tg is not None and not tg.name._text.startswith("|cffffd100- ") and tg.fold._shown and tg.fold._tex == "Interface\\Buttons\\UI-MinusButton-Up" and "done" in tg.xp._text, [h.name._text for h in gh])
check("by giver: the giver's quests are listed under the header, a chain quest with the chain-link icon", len([r for r in rows if r.entry is not None]) >= 2 and any(r.chain._shown for r in rows if r.entry is not None))
n_open = len([r for r in rows if r.entry is not None])
tg._scripts["OnClick"](tg, "LeftButton")
rows = zone_rows()
tg = next(r for r in rows if r.entry is None and "Test Giver" in r.name._text)
check("a giver can be folded shut (plus icon)", tg.fold._tex == "Interface\\Buttons\\UI-PlusButton-Up" and len([r for r in rows if r.entry is not None]) < n_open, (tg.fold._tex, n_open))
tg._scripts["OnClick"](tg, "LeftButton")
check("... and opened again", len([r for r in zone_rows() if r.entry is not None]) == n_open)
mainwin.tabGiver._scripts["OnClick"](mainwin.tabGiver)
check("clicking the lit By giver again keeps it", any(r.entry is None and "Test Giver" in r.name._text for r in zone_rows()))
mainwin.tabType._scripts["OnClick"](mainwin.tabType)
check("By type goes back to grouping by type and lights up again", mainwin.tabType.under._shown and not mainwin.tabGiver.under._shown)
check("the tab goes back to grouping by type", any("Chains" in r.name._text for r in zone_rows() if r.entry is None))
# the Crumbs tab: only the breadcrumb quests
cs = chips()
cs[0]._scripts["OnClick"](cs[0])
mainwin.tabCrumbs._scripts["OnClick"](mainwin.tabCrumbs)
crow_all = zone_rows()
crow_q = [r for r in crow_all if r.entry is not None]
crow_h = [r.name._text for r in crow_all if r.entry is None]
check("the Crumbs tab is lit and the other two are not", mainwin.tabCrumbs.under._shown and not mainwin.tabType.under._shown and not mainwin.tabGiver.under._shown)
check("Crumbs lists only breadcrumb quests, under one Breadcrumbs header",
      len(crow_q) > 0 and all(ns2.Data.IsBreadcrumb(r.questId) for r in crow_q) and len(crow_h) == 1 and "Breadcrumbs" in crow_h[0], (len(crow_q), crow_h))
check("... including Raven Hill (#163), which the By type list has as a single quest", any(r.questId == 163 for r in crow_q))
check("a breadcrumb row says what it leads into", any("Leads into" in r.sub._text for r in crow_q), [r.sub._text for r in crow_q][:3])
cs = chips()
cs[-1]._scripts["OnClick"](cs[-1])  # the All filter
n_crumbs = sum(1 for r in zone_rows() if r.entry is not None)
check("the summary counts only the breadcrumbs, as many as the All list shows (not the whole zone)",
      mainwin.sub._text == "%d breadcrumb quests in this zone" % n_crumbs and n_crumbs < 300, (mainwin.sub._text, n_crumbs))
cs[0]._scripts["OnClick"](cs[0])
mainwin.tabType._scripts["OnClick"](mainwin.tabType)
check("By type's summary counts the whole zone", "breadcrumb" not in mainwin.sub._text and mainwin.sub._text.endswith("quests in this zone"), mainwin.sub._text)
mainwin.tabCrumbs._scripts["OnClick"](mainwin.tabCrumbs)
mainwin.tabGiver._scripts["OnClick"](mainwin.tabGiver)
check("By giver leaves Crumbs and lights up itself", mainwin.tabGiver.under._shown and not mainwin.tabCrumbs.under._shown and not G.QuestThreadDB.zone.crumbs and mainwin.tabGiver.under._shown)
mainwin.tabCrumbs._scripts["OnClick"](mainwin.tabCrumbs)
mainwin.tabType._scripts["OnClick"](mainwin.tabType)
check("By type leaves Crumbs and lists chains again", mainwin.tabType.under._shown and not mainwin.tabCrumbs.under._shown and any("Chains" in r.name._text for r in zone_rows() if r.entry is None))
# filters, missed quests
G.UnitLevel = lua.eval("function() return 60 end")
cs = chips()
cs[2]._scripts["OnClick"](cs[2])
check("outleveled quests are not under Missed", not any(r.questId in singles_here for r in zone_rows()) and chips()[2].text._text == "Missed", chips()[2].text._text)
cs = chips()
cs[0]._scripts["OnClick"](cs[0])
rows = zone_rows()
sr = [r for r in rows if r.questId in singles_here]
check("the Available chip lists the outleveled quests, each with its reason in grey and a Grey tag", G.QuestThreadDB.zone.filter == "available" and len(sr) > 0
      and all(r.entry.status == "available" and "Outleveled" in r.sub._text and "|cff9a9488" in r.sub._text for r in sr) and all("Grey" in r.tag._text and "Missed" not in r.tag._text for r in sr), len(sr))
check("... and the header line has no grey count", "grey" not in mainwin.stats._text and " 0 missed · " in mainwin.stats._text, mainwin.stats._text)
G.tipLines = lua.table()
sr[0]._scripts["OnEnter"](sr[0])
check("an outleveled quest's tooltip says Available now and, in grey, that it is outleveled", any("Available now" == t for t in G.tipLines.values()) and any("Outleveled: quest level" in t and "grey to you" in t for t in G.tipLines.values()), list(G.tipLines.values())[-4:])
sr[0]._scripts["OnLeave"](sr[0])
check("an outleveled row has the available icon, not the lock", sr[0].status._shown and sr[0].status._tc is not None and not sr[0].status._desat)
cs[2]._scripts["OnClick"](cs[2])
check("outleveled quests are not under Missed", not any(r.questId in singles_here for r in zone_rows()) and chips()[2].text._text == "Missed", chips()[2].text._text)
cs[3]._scripts["OnClick"](cs[3])
check("the Done chip counts what you finished, and a half-done chain is not listed as done", chips()[3].text._text == "Done" and not any(r.questId == entry65 for r in zone_rows()), chips()[3].text._text)
cs[4]._scripts["OnClick"](cs[4])
all_rows = {r.questId for r in zone_rows()}
check("All lists everything, outleveled quests included", len(all_rows) > 0 and all(r.questId in all_rows for r in sr) and chips()[4].text._text == "All" and len(all_rows) > 0, chips()[4].text._text)
G.UnitLevel = lua.eval("function() return 20 end")
cs[0]._scripts["OnClick"](cs[0])
# the zone picker
G.SlashCmdList["QUESTTHREAD"]("zone o")
rows = zone_rows()
pick = [r for r in rows if r.entry is None and "quests" in r.name._text]
check("several zones match: a list to pick from, with counts", len(pick) == 2 and "zones match" in mainwin.sub._text, (len(pick), mainwin.sub._text))
pick[1]._scripts["OnClick"](pick[1], "LeftButton")
check("picking a zone shows it", mainwin.title._text in ("Elwynn Forest", "Dun Morogh") and any(r.entry is not None for r in zone_rows()))
G.SlashCmdList["QUESTTHREAD"]("zone nowhere")
check("an unknown zone says so", 'No zone named "nowhere"' in mainwin.sub._text, mainwin.sub._text)
G.SlashCmdList["QUESTTHREAD"]("zone")
check("/qthread zone alone shows the zone you stand in", mainwin.title._text == "Elwynn Forest", mainwin.title._text)
# a zone link, with Ctrl, opens that zone's quests
G.SlashCmdList["QUESTTHREAD"]("166")
check("(setup) back on the Chains tab", not ns2.UI.IsZoneMode())
zl = links_of(166)
G.testCtrl = True
G.waypointCalls.opened = None
zl[0]._scripts["OnClick"](zl[0])
G.testCtrl = False
check("Ctrl+click on a zone link shows that zone's quests and does not open the map", ns2.UI.IsZoneMode() and mainwin.title._text == "Dun Morogh" and G.waypointCalls.opened is None, mainwin.title._text)
mainwin.tabChain._scripts["OnClick"](mainwin.tabChain)
check("the Chains tab brings the chain back", not ns2.UI.IsZoneMode() and not mainwin.tabZone.under._shown and mainwin.hint._text == "Quest ID, link or name")
G.SlashCmdList["QUESTTHREAD"]("")

# ---- the panel beside the world map ----
MP = ns2.MapPanel
G.testMapId = 1429
G.WorldMapFrame = G.newStub()
G.WorldMapFrame.GetMapID = lua.eval("function() return _G.testMapId end")
G.QuestThreadDB.mapPanel = None
G.QuestThreadDB.zone.filter = "available"
check("there is no panel before it is opened", not MP.IsShown())
MP.Init()
check("the world map gets no QuestThread button (it floated over other addons' map frames)", frame_named("QuestThreadMapButton") is None)
MP.Toggle()
check("/qthread map opens the panel", MP.IsShown() and G.QuestThreadDB.mapPanel is True)
mpanel = frame_named("QuestThreadMapPanel")
check("the panel sits beside the map, at its top right", mpanel._pt[1] == "TOPLEFT" and G.rawequal(mpanel._pt[2], G.WorldMapFrame) and mpanel._pt[3] == "TOPRIGHT", mpanel._pt)

def panel_rows():
    rs = [f for f in G.stubs.values() if f._shown and f.icon is not None and f.right is not None and f.hl is not None and f._pt is not None]
    return sorted(rs, key=lambda f: -f._pt[5])

check("it shows the zone the map shows", mpanel.title._text == "Elwynn Forest" and "quests in this zone" in mpanel.sub._text, (mpanel.title._text, mpanel.sub._text))
prow = panel_rows()
check("it starts with the Chains section, one row per chain", "Chains" in prow[0].text._text, [r.text._text for r in prow][:3])
chain_p = next((r for r in prow if r.questId == entry65), None)
check("a chain row has its steps on the right", chain_p is not None and "7 steps" in chain_p.right._text, chain_p and chain_p.right._text)
check("rows have the level in its colour and a status icon", chain_p.icon._shown and "|cff" in chain_p.text._text and "[" in chain_p.text._text)
G.tipLines = lua.table()
chain_p._scripts["OnEnter"](chain_p)
check("hovering a row lights it and shows its tooltip", chain_p.hl._shown and any(ns2.Data.Name(entry65) in t for t in G.tipLines.values()), list(G.tipLines.values())[:3])
chain_p._scripts["OnLeave"](chain_p)
chain_p._scripts["OnClick"](chain_p)
check("clicking a row opens the quest in QuestThread's window with its popup", not ns2.UI.IsZoneMode() and mainwin.title._text == ns2.Data.Name(entry65) and pane_open(), mainwin.title._text)
# filters are shared with the Zones tab
G.UnitLevel = lua.eval("function() return 60 end")
mpanel.chips[1]._scripts["OnClick"](mpanel.chips[1])
prow = panel_rows()
sp = [r for r in prow if r.questId in singles_here and r.entry.status == "available"]
check("the panel's Available list has the outleveled quests, marked Grey", len(sp) > 0 and all("Grey" in r.right._text for r in sp), len(sp))
G.tipLines = lua.table()
sp[0]._scripts["OnEnter"](sp[0])
check("... and their tooltip says so in grey", any("Outleveled: quest level" in t and "grey to you" in t for t in G.tipLines.values()), list(G.tipLines.values())[-3:])
sp[0]._scripts["OnLeave"](sp[0])
mpanel.chips[3]._scripts["OnClick"](mpanel.chips[3])
check("the Missed chip sets the filter the Zones tab uses too, and holds no outleveled quest", G.QuestThreadDB.zone.filter == "missed" and mpanel.chips[3].under._shown and not mpanel.chips[1].under._shown
      and not any(r.questId in singles_here for r in panel_rows()))
G.SlashCmdList["QUESTTHREAD"]("zone elwynn")
check("... and the window's Zones tab shows the same filter", G.QuestThreadDB.zone.filter == "missed" and chips()[2].under._shown)
G.UnitLevel = lua.eval("function() return 20 end")
mpanel.chips[1]._scripts["OnClick"](mpanel.chips[1])
# following the map
G.testMapId = 5
mpanel._scripts["OnUpdate"](mpanel, 1)
check("on a map with no quests it says so", mpanel.title._text == "Quests here" and "No quests start on this map" in mpanel.sub._text and not panel_rows(), mpanel.sub._text)
G.testMapId = 1429
mpanel._scripts["OnUpdate"](mpanel, 1)
check("back on the zone's map the list returns", mpanel.title._text == "Elwynn Forest" and len(panel_rows()) > 3)
# the window, the slash command, coming back with the map
mpanel.window._scripts["OnClick"](mpanel.window)
check("Open in window shows this zone on the Zones tab", ns2.UI.IsZoneMode() and mainwin.title._text == "Elwynn Forest")
G.SlashCmdList["QUESTTHREAD"]("map")
check("/qthread map hides the panel (and remembers it)", not MP.IsShown() and G.QuestThreadDB.mapPanel is False)
G.SlashCmdList["QUESTTHREAD"]("map")
check("/qthread map shows it again", MP.IsShown())
MP.HidePanel()
G.QuestThreadDB.mapPanel = True
G.WorldMapFrame._scripts["hookOnShow"](G.WorldMapFrame)
check("a panel left on comes back when the map opens", MP.IsShown())
# no room beside the map: it sits inside it
MP.HidePanel()
for fr in (G.WorldMapFrame, G.UIParent):
    fr.GetEffectiveScale = lua.eval("function() return 1 end")
G.WorldMapFrame.GetRight = lua.eval("function() return 1900 end")
G.UIParent.GetRight = lua.eval("function() return 1920 end")
MP.ShowPanel()
check("with no room beside the map it sits inside it, on the right", mpanel._pt[1] == "TOPRIGHT" and mpanel._pt[3] == "TOPRIGHT", mpanel._pt)
G.WorldMapFrame.GetRight = None
MP.HidePanel()
G.SlashCmdList["QUESTTHREAD"]("")

# ---- zone name autocomplete ----
def sug(text, n=8):
    return [z.name for z in Z.Suggest(text, n).values()]

check("suggestions: a name that starts with the text", sug("el") == ["Elwynn Forest"] and sug("ELW") == ["Elwynn Forest"], sug("el"))
check("suggestions: a name with a word that starts with the text", sug("fo") == ["Elwynn Forest"] and sug("mo") == ["Dun Morogh"], (sug("fo"), sug("mo")))
check("suggestions: the text anywhere in the name, in name order", sug("o") == ["Dun Morogh", "Elwynn Forest"] and sug("ogh") == ["Dun Morogh"], sug("o"))
check("suggestions: nothing for text that matches no zone, or for no text", sug("x") == [] and sug("") == [] and sug("   ") == [])
check("suggestions are capped", len(sug("o", 1)) == 1)
fake = lua.eval("{ { name = 'Weststeppe' }, { name = 'Burning Steppes' }, { name = 'Steppe Reach' }, { name = 'Dun Morogh' } }")
check("suggestions: starts-with first, then a word that starts with it, then anywhere (whatever the list order)",
      [z.name for z in Z.Suggest("steppe", 8, fake).values()] == ["Steppe Reach", "Burning Steppes", "Weststeppe"], [z.name for z in Z.Suggest("steppe", 8, fake).values()])

G.SlashCmdList["QUESTTHREAD"]("zone elwynn")
box, sg = mainwin.box, mainwin.suggest
def type_text(text, user=True):
    box.SetText(box, text)
    box._scripts["OnTextChanged"](box, user)
type_text("el")
check("typing a zone name shows a list under the box", sg._shown and sg.list is not None and len(sg.list) == 1 and sg.rows[1].text._text.startswith("Elwynn Forest"), sg._shown)
check("each suggestion has its quest count", "|cff808080" in sg.rows[1].text._text)
type_text("el", False)
mainwin.box._scripts["OnEscapePressed"](box)
check("Escape closes the list", not sg._shown)
type_text("el", False)
check("text set by the addon itself does not open it", not sg._shown)
type_text("o")
check("several matches: a row each", sg._shown and len(sg.list) == 2 and sg.rows[1]._shown and sg.rows[2]._shown, len(sg.list))
box._scripts["OnArrowPressed"](box, "DOWN")
check("Down highlights the first suggestion", sg.sel == 1 and sg.rows[1].hl._shown and not sg.rows[2].hl._shown)
box._scripts["OnArrowPressed"](box, "DOWN")
box._scripts["OnArrowPressed"](box, "DOWN")
check("Down wraps round", sg.sel == 1)
box._scripts["OnArrowPressed"](box, "UP")
check("Up wraps the other way", sg.sel == 2 and sg.rows[2].hl._shown)
box._scripts["OnArrowPressed"](box, "UP")
box._scripts["OnEnterPressed"](box)
check("Enter takes the highlighted suggestion and shows that zone", box._text == "Dun Morogh" and mainwin.title._text == "Dun Morogh" and not sg._shown, (box._text, mainwin.title._text))
type_text("el")
box._scripts["OnTabPressed"](box)
check("Tab completes the typed text to the first suggestion", box._text == "Elwynn Forest", box._text)
type_text("o")
sg.rows[2]._scripts["OnEnter"](sg.rows[2])
check("hovering a suggestion highlights it", sg.sel == 2 and sg.rows[2].hl._shown)
sg.rows[2]._scripts["OnClick"](sg.rows[2])
check("clicking a suggestion shows that zone", mainwin.title._text == "Elwynn Forest" and box._text == "Elwynn Forest" and not sg._shown, (mainwin.title._text, box._text))
type_text("o")
box._scripts["OnEnterPressed"](box)
check("Enter with nothing highlighted still looks the text up (several zones: a pick list)", "zones match" in mainwin.sub._text and not sg._shown, mainwin.sub._text)
type_text("o")
mainwin.tabChain._scripts["OnClick"](mainwin.tabChain)
check("switching tabs closes the list", not sg._shown)
type_text("el")
check("on the Chains tab typing offers no zones", not sg._shown)
G.SlashCmdList["QUESTTHREAD"]("")

# ---- scroll bar ----
check("thumb maths: nothing to scroll gives no thumb", Core.Thumb(300, 300, 0) is None and Core.Thumb(300.5, 300, 0) is None and Core.Thumb(100, 0, 0) is None)
th, top = Core.Thumb(1000, 300, 0)
check("thumb maths: thumb is the share of content that shows, at the top", abs(th - 90) < 0.01 and top == 0, (th, top))
th, top = Core.Thumb(1000, 300, 700)
check("thumb maths: scrolled to the end it sits at the bottom of the bar", abs(top - (300 - th)) < 0.01, (th, top))
check("thumb maths: never shorter than the minimum", Core.Thumb(100000, 300, 0)[0] == 24)
check("thumb maths: scroll past the end is clamped", abs(Core.Thumb(1000, 300, 99999)[1] - (300 - 90)) < 0.01)
check("scroll for thumb: top and bottom of the bar", Core.ScrollForThumb(0, 90, 1000, 300) == 0 and abs(Core.ScrollForThumb(210, 90, 1000, 300) - 700) < 0.01)
check("scroll for thumb: dragging past either end is clamped", Core.ScrollForThumb(-50, 90, 1000, 300) == 0 and abs(Core.ScrollForThumb(999, 90, 1000, 300) - 700) < 0.01)
check("scroll for thumb: halfway down is halfway through the range", abs(Core.ScrollForThumb(105, 90, 1000, 300) - 350) < 0.01)

G.SlashCmdList["QUESTTHREAD"]("166")
sbar, sthumb, sscroll, scontent = mainwin.bar, mainwin.thumb, mainwin.scroll, mainwin.content
check("the scroll bar takes the mouse itself (a click on it must not start moving the window)", sbar._mouse is True and sthumb._mouse is True, (sbar._mouse, sthumb._mouse))
G.scrollTest = lua.table_from({"down": True, "cursor": 0.0, "v": 0.0})
lua.execute("""
_G.IsMouseButtonDown = function() return scrollTest.down end
_G.GetCursorPosition = function() return 0, scrollTest.cursor end
""")
# geometry: the bar is 300 tall with its top at y=1000 on screen; the content is 1000 tall
sbar.GetTop = lua.eval("function() return 1000 end")
sbar.GetEffectiveScale = lua.eval("function() return 1 end")
sscroll.GetHeight = lua.eval("function() return 300 end")
scontent.GetHeight = lua.eval("function() return 1000 end")
sscroll.GetVerticalScroll = lua.eval("function() return scrollTest.v end")
sscroll.SetVerticalScroll = lua.eval("function(_, v) scrollTest.v = v end")
sthumb.GetHeight = lua.eval("function() return 90 end")
sthumb.GetTop = lua.eval("function() return 1000 end")
sscroll._scripts["OnVerticalScroll"](sscroll)
check("with more content than fits the bar shows, thumb sized to the share", sbar._shown and sthumb._pt[1] == "TOP" and sthumb._h == 90, (sbar._shown, sthumb._h))
# take the thumb 10px below its top, then move the mouse 105 px down
G.scrollTest.cursor = 990.0
sthumb._scripts["OnMouseDown"](sthumb, "LeftButton")
check("holding the thumb follows the mouse each frame", sbar._scripts["OnUpdate"] is not None)
G.scrollTest.cursor = 1000 - 115.0
sbar._scripts["OnUpdate"](sbar, 0.016)
check("dragging the thumb 105 px scrolls half the range", abs(G.scrollTest.v - 350) < 0.01, G.scrollTest.v)
G.scrollTest.cursor = 0.0
sbar._scripts["OnUpdate"](sbar, 0.016)
check("dragging past the bottom stops at the end", abs(G.scrollTest.v - 700) < 0.01, G.scrollTest.v)
sthumb._scripts["OnMouseUp"](sthumb)
check("letting go stops following", sbar._scripts["OnUpdate"] is None)
sthumb._scripts["OnMouseDown"](sthumb, "RightButton")
check("only the left button takes the thumb", sbar._scripts["OnUpdate"] is None)
sthumb._scripts["OnMouseDown"](sthumb, "LeftButton")
G.scrollTest.down = False
sbar._scripts["OnUpdate"](sbar, 0.016)
check("letting go outside the window also stops it", sbar._scripts["OnUpdate"] is None)
G.scrollTest.down = True
G.scrollTest.v = 0.0
G.scrollTest.cursor = 1000 - 105.0 - 45.0
sbar._scripts["OnMouseDown"](sbar, "LeftButton")
check("a click on the track puts the thumb's middle under the mouse and scrolls there", abs(G.scrollTest.v - 350) < 0.01 and sbar._scripts["OnUpdate"] is not None, G.scrollTest.v)
sbar._scripts["OnMouseUp"](sbar)
sbar._scripts["OnMouseWheel"](sbar, -1)
check("the wheel works over the bar too", abs(G.scrollTest.v - 398) < 0.01, G.scrollTest.v)
sthumb._scripts["OnEnter"](sthumb)
check("the thumb lights up under the mouse", abs(sthumb.tex._vc[1] - 0.98) < 0.01)
sthumb._scripts["OnMouseDown"](sthumb, "LeftButton")
check("... and more while held", abs(sthumb.tex._vc[1] - 1) < 0.01)
sthumb._scripts["OnMouseUp"](sthumb); sthumb._scripts["OnLeave"](sthumb)
check("... and back to bronze after", abs(sthumb.tex._vc[1] - 0.55) < 0.01)
scontent.GetHeight = lua.eval("function() return 200 end")
sscroll._scripts["OnVerticalScroll"](sscroll)
check("with nothing to scroll the bar is hidden", not sbar._shown)
sthumb._scripts["OnMouseDown"](sthumb, "LeftButton")
mainwin._scripts["OnHide"](mainwin)
check("hiding the window lets go of the thumb", sbar._scripts["OnUpdate"] is None)
G.SlashCmdList["QUESTTHREAD"]("")

# ---- look: tabs, row hover ----
G.SlashCmdList["QUESTTHREAD"]("zone elwynn")
check("on the Zones tab the Chains tab is dimmer", mainwin.tabChain.dim is True and mainwin.tabZone.dim is False and mainwin.tabChain.text._color[1] < 0.7 and mainwin.tabZone.text._color[1] == 1)
G.SlashCmdList["QUESTTHREAD"]("166")
check("on the Chains tab it is the Zones tab that is dim", mainwin.tabZone.dim is True and mainwin.tabChain.dim is False and mainwin.tabZone.text._color[1] < 0.7)
hrow = chain_row(166)
hrow._scripts["OnEnter"](hrow)
check("a quest row gets a hover plate under the mouse", hrow.hover._shown)
hrow._scripts["OnLeave"](hrow)
check("... gone when the mouse leaves", not hrow.hover._shown)
hrow._scripts["OnEnter"](hrow)
G.SlashCmdList["QUESTTHREAD"]("166")
check("... and a reused row does not keep it", not chain_row(166).hover._shown)
G.SlashCmdList["QUESTTHREAD"]("zone elwynn")
plain = [f for f in G.stubs.values() if f.hover is not None and f._shown and f.questId is None and f.onClick is None and f._scripts["OnEnter"] is not None]
check("there are header rows with nothing to click", len(plain) >= 1)
plain[0]._scripts["OnEnter"](plain[0])
check("a header row gets no hover plate", not plain[0].hover._shown)
G.SlashCmdList["QUESTTHREAD"]("")

# ---- clickable text is underlined ----
G.SlashCmdList["QUESTTHREAD"]("166")
cur = chain_row(166)
check("\"You are here\" has a gold underline under it, white while hovered", cur.here.line is not None and cur.here.line._vc[1] == 1 and cur.here.line._vc[3] == 0, cur.here.line._vc)
cur.here._scripts["OnEnter"](cur.here)
check("... lit white on hover", cur.here.line._vc[3] == 1)
cur.here._scripts["OnLeave"](cur.here)
check("... and gold again after", cur.here.line._vc[3] == 0)
ul = links_of(166)
check("every link has an underline in its own colour (zones blue)", len(ul) >= 1 and all(b.line is not None for b in ul) and abs(ul[0].line._vc[2] - 0.71) < 0.01, ul[0].line._vc)
ul[0]._scripts["OnEnter"](ul[0])
check("a hovered link's underline is white", ul[0].line._vc[1] == 1 and ul[0].line._vc[3] == 1)
ul[0]._scripts["OnLeave"](ul[0])
check("... and back to its colour after", abs(ul[0].line._vc[2] - 0.71) < 0.01)
G.ForeverDungeonJournal_NS = lua.eval("{ DB = { ['Test Dungeon'] = { quests = { { id = 166 } } } }, OpenQuestPage = function() end }")
G.SlashCmdList["QUESTTHREAD"]("166")
dul = links_of(166)
check("a dungeon link is underlined in amber", dul[0].link.kind == "dungeon" and abs(dul[0].line._vc[1] - 0.88) < 0.01 and abs(dul[0].line._vc[3] - 0.29) < 0.01, dul[0].line._vc)
G.ForeverDungeonJournal_NS = None
G.SlashCmdList["QUESTTHREAD"]("")

# ---- /qt ----
check("/qt is a short way to type /qthread", G.SLASH_QUESTTHREAD3 == "/qt" and G.SLASH_QUESTTHREAD1 == "/qthread")

# ---- the chain is always the whole chain ----
G.SlashCmdList["QUESTTHREAD"]("166")
check("the chain tab has no Show remaining button; the stats are for the whole chain", not mainwin.toggle._shown and any(f._text and f._text.startswith("Whole chain: 8 quests") for f in G.stubs.values()), mainwin.toggle._shown)
mainwin.tabZone._scripts["OnClick"](mainwin.tabZone)
check("the two grouping tabs are only on the Zones tab", mainwin.toggle._shown and mainwin.tabType._scripts["OnClick"] is not None and mainwin.tabGiver._scripts["OnClick"] is not None)
mainwin.tabType._scripts["OnClick"](mainwin.tabType)
G.QuestThreadDB.zone.byGiver = True
mainwin.tabChain._scripts["OnClick"](mainwin.tabChain)
mainwin.tabZone._scripts["OnClick"](mainwin.tabZone)
check("the lit tab follows the saved grouping when the Zones tab opens", mainwin.tabGiver.under._shown and not mainwin.tabType.under._shown)
G.QuestThreadDB.zone.byGiver = False
mainwin.tabChain._scripts["OnClick"](mainwin.tabChain)
mainwin.tabZone._scripts["OnClick"](mainwin.tabZone)
mainwin.tabChain._scripts["OnClick"](mainwin.tabChain)
check("and it goes again on the Chains tab", not mainwin.toggle._shown)
G.SlashCmdList["QUESTTHREAD"]("")

# ---- the chain icon file ----
import re
import struct
src = open(os.path.join(ROOT, "Main.lua"), encoding="utf-8").read()
m = re.search(r'Interface\\\\AddOns\\\\QuestThread\\\\([A-Za-z0-9_.]+)', src)  # the Lua source holds doubled backslashes
icon_path = os.path.join(ROOT, m.group(1)) if m else None
check("the icon path in Main.lua points at a file in the addon", bool(icon_path) and os.path.isfile(icon_path), m and m.group(1))
if icon_path and os.path.isfile(icon_path):
    blob = open(icon_path, "rb").read()
    w, h, depth = struct.unpack("<HHB", blob[12:17])
    check("the icon is an uncompressed 32-bit power-of-two TGA of the right size",
          blob[2] == 2 and depth == 32 and w == h and w & (w - 1) == 0 and len(blob) == 18 + w * h * 4, (blob[2], depth, w, h, len(blob)))
    alphas = blob[18 + 3::4]
    check("the icon has transparent corners and opaque ink", alphas[0] == 0 and max(alphas) == 255)

# ---- every texture file the Lua code names exists in the addon ----
for fn in ("Main.lua", "UI.lua", "MapPanel.lua"):
    text = open(os.path.join(ROOT, fn), encoding="utf-8").read()
    for name in sorted(set(re.findall(r'Interface\\\\AddOns\\\\QuestThread\\\\([A-Za-z0-9_.]+)', text))):
        check("%s: addon texture %s exists" % (fn, name), os.path.isfile(os.path.join(ROOT, name)))

print()
if mutate:
    print("mutation run: %d tests failed (expected > 0)" % len(failures))
    sys.exit(0 if failures else 1)
print("%d failed" % len(failures))
sys.exit(1 if failures else 0)
