"""Offline tests for QuestThread, on a real Lua 5.1 runtime (lupa.lua51), not the game.

  node tests/dump-questiedb.js <AddOns> <data.json>      (once, reads the installed QuestieDB)
  python -I tests/run.py <data.json> [--mutate]

--mutate edits Core.lua in memory (breaks the XP scaling and the chain walk); the tests must then FAIL.
Covers Core on synthetic graphs, Core on the real Defias Brotherhood chain, and a UI smoke run with
stub frames (catches nil errors in this addon's own code, not WoW API semantics).
"""
import json
import os
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
    function m.Show(s) s._shown = true end
    function m.Hide(s) s._shown = false end
    function m.SetShown(s, v) s._shown = v and true or false end
    function m.IsShown(s) return s._shown end
    function m.IsVisible(s) return true end
    function m.SetScript(s, k, fn) s._scripts[k] = fn end
    function m.HookScript(s, k, fn) s._scripts["hook" .. k] = fn end
    function m.GetScript(s, k) return s._scripts[k] end
    function m.GetFrameLevel(s) return s._lvl or 1 end
    function m.SetFrameLevel(s, l) s._lvl = l end
    function m.SetHeight(s, h) s._h = h end
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
lua.globals().LibQuestieDB.Support.Get = lua.eval("function(t) return function(name) if name == 'QuestXP' then return { db = t } end; if name == 'ZoneDB' then return { private = { areaIdToUiMapId = { [12] = 1429 } } } end end end")(xp_lua)
ns2 = lua.table()
for fn in ("Core.lua", "Data.lua", "UI.lua", "QuestFrame.lua", "Main.lua"):
    loader(source(fn), fn, ns2)

G = lua.globals()
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
rows = [f for f in G.stubs.values() if f._shown and f._h and f._pt and f._scripts["OnClick"] is not None and f._pt[5] is not None and f._pt[5] <= 0]
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
button = next((f for f in G.stubs.values() if f._scripts["OnClick"] is not None and f._scripts["OnDragStart"] is not None), None)
check("quest log button is created", button is not None)
check("quest log hook is a secure post-hook", G.hooks["QuestMapFrame_ShowQuestDetails"] is not None)
win = frame_named("QuestThreadFrame")
win._shown = False
G.testDetail = 166
button._scripts["OnClick"](button)
check("button opens the window on the open quest", win._shown and any(f._text == "The Defias Brotherhood" for f in G.stubs.values()))
G.hooks["QuestMapFrame_ShowQuestDetails"](55)
check("window follows the quest log while open", any(f._text == "Morbent Fel" for f in G.stubs.values()))
win._shown = False
G.hooks["QuestMapFrame_ShowQuestDetails"](166)
check("follow hook does not open a closed window", not win._shown)
G.testDetail = None


def tick():
    for f in list(G.stubs.values()):
        fn = f._scripts["OnUpdate"]
        if fn is not None:
            fn(f, 1.0)


def clickers():
    return [f for f in G.stubs.values() if f._scripts["OnClick"] is not None]


tick()
check("detail-view button is hidden in the list view", button._shown is False)
G.testDetail = 166
tick()
check("detail-view button shows in a quest's detail view", button._shown is True)
G.QuestMapFrame.DetailsFrame.BackButton = False  # stubs invent uppercase fields; make "no Back button" explicit
G.QuestMapFrame.DetailsFrame.BackFrame = False
tick()
check("detail button falls back to the corner with no Back button", button._pt[1] == "TOPRIGHT", [button._pt[i] for i in (1,3,4,5)])
back = G.newStub(); back._tag = "back"
G.QuestMapFrame.DetailsFrame.BackButton = back
tick()
check("detail button sits beside the Back button", button._pt[1] == "LEFT" and button._pt[2]._tag == "back" and button._pt[3] == "RIGHT", button._pt)
G.QuestMapFrame.DetailsFrame._lvl = 50  # the panel gets a high level; the button must follow it
tick()
check("detail-view button is drawn above the details panel", button._lvl is not None and button._lvl > 50, (button._lvl,))
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
with_entry = [f for f in G.stubs.values() if f.entry is not None and f._shown]
bad = [(f.entry.status, f.status._tc[1] if f.status._tc is not None else None) for f in with_entry
       if f.status._tc is None or abs(f.status._tc[1] - CELL[f.entry.status] * 0.25) > 1e-9]
check("each row's status icon is the cell for its status", len(with_entry) >= 8 and not bad, bad[:3])
check("the sheet cells are a quarter wide", all(abs(f.status._tc[2] - f.status._tc[1] - 0.25) < 1e-9 for f in with_entry))
locked_rows = [f for f in with_entry if f.entry.status == "locked"]
check("locked rows say what they need on a second line", locked_rows and all(f.sub._text.find("Needs:") >= 0 and f.sub._shown for f in locked_rows), len(locked_rows))
plain = [f for f in with_entry if f.entry.status != "locked" and f.entry.id != 166]
check("other rows have no second line", all(not f.sub._shown for f in plain))
import math
check("row height follows its second line and reward icons",
      all(abs(f._h - (28 + (12 if f.sub._shown else 0) + (12 if f.where._shown else 0) + (math.ceil(len(f.entry["items"]) / 14) * 25 if len(f.entry["items"]) else 0))) < 0.001 for f in with_entry))
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
check("the tooltip mentions the Ctrl+C shortcut", any("Ctrl+C" in s for s in G.tipLines.values()), list(G.tipLines.values())[-2:])
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
check("a pick-list row has a tooltip with its id and the shortcut", any("Quest #%d" % hits[0].questId in s for s in G.tipLines.values()) and any("Ctrl+C" in s for s in G.tipLines.values()), list(G.tipLines.values()))
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
D.RecordTurnIn(166)
D.RecordTurnIn(166)
G.SlashCmdList["QUESTTHREAD"]("166")
r166 = chain_row(166)
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
for fn in ("Main.lua", "UI.lua"):
    text = open(os.path.join(ROOT, fn), encoding="utf-8").read()
    for name in sorted(set(re.findall(r'Interface\\\\AddOns\\\\QuestThread\\\\([A-Za-z0-9_.]+)', text))):
        check("%s: addon texture %s exists" % (fn, name), os.path.isfile(os.path.join(ROOT, name)))

print()
if mutate:
    print("mutation run: %d tests failed (expected > 0)" % len(failures))
    sys.exit(0 if failures else 1)
print("%d failed" % len(failures))
sys.exit(1 if failures else 0)
