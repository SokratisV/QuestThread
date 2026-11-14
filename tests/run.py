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
    function m.SetPoint(s, p, rel, a, x, y) s._pt = { p, rel, a, x, y } end
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
  _G.hooksecurefunc = function(name, fn) hooks[name] = fn end
  _G.IsShiftKeyDown = function() return false end
  _G.testCtrl, _G.testMouse, _G.testFocus = false, false, nil
  _G.IsControlKeyDown = function() return testCtrl end
  _G.IsAltKeyDown = function() return false end
  _G.IsMouseButtonDown = function() return testMouse end
  _G.GetMouseFoci = function() return { testFocus } end
  _G.makeIcon = function(name, data) local f = stub(); f._name = name; f.GetName = function() return name end; f.data = data; return f end
  _G.UnitLevel = function() return 20 end
  _G.GetMaxPlayerLevel = function() return 60 end
  _G.debugprofilestop = function() return os.clock() * 1000 end
  _G.testClientXp = {}
  _G.GetQuestLogRewardXP = function(id) local v = testClientXp[id]; if v then return v + 100, v end end
  _G.C_QuestLog = {
    IsQuestFlaggedCompleted = function(id) return id == 65 end,
    GetLogIndexForQuestID = function(id) return testClientXp[id] and 1 or nil end,
    GetNumQuestLogEntries = function() return 1 end,
    GetInfo = function(i) return { questID = 166, isHeader = false } end,
  }
  _G.C_Item = { GetItemIconByID = function(id) return 100 end }
  _G.C_Reputation = nil
  _G.GetFactionInfoByID = function(id) return "Faction" .. id end
  _G.SlashCmdList = {}
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
    requiredLevel = ent(quests, "reqLevel"),
    objectivesText = function(id) if id == 166 then return { "Kill things." } end end,
    startedBy = function(id) return { { 1000 } } end,
    finishedBy = function(id) return { { 1000 } } end,
    zoneOrSort = function(id) return 12 end,
    IdsByName = function(n) local l = {}; for id, q in pairs(quests) do if q.name == n then l[#l + 1] = id end end; table.sort(l); return l end,
  }
  _G.ItemDB = {
    GetAllIds = function() local l = {}; for id in pairs(items) do l[#l + 1] = id end; table.sort(l); return l end,
    questRewards = function(id) return items[id] end,
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
for fn in ("Core.lua", "Data.lua", "UI.lua", "Main.lua"):
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
check("current quest is marked YOU ARE HERE", sum("YOU ARE HERE" in t for t in all_texts) == 1, sum("YOU ARE HERE" in t for t in all_texts))
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
tags = [f._text for f in G.stubs.values() if f._text and ("locked" in f._text or "available" in f._text)]
check("rows show locked / available tags", len(tags) >= 2, tags[:3])
check("rows show the quest level", any("[30]" in (f._text or "") for f in G.stubs.values()))
G.tipLines = lua.table()
entry_row._scripts["OnEnter"](entry_row)
tip = list(G.tipLines.values())
check("hover tooltip shows objective and start / end givers", any("Kill things." in s for s in tip) and any(s.startswith("Starts: Test Giver") for s in tip) and any(s.startswith("Ends: Test Giver") for s in tip), tip)
check("tooltip place text names the zone and coordinates", any("Elwynn Forest (42, 61)" in s or "Elwynn Forest (43, 61)" in s for s in tip), tip)
entry_row._scripts["OnClick"](entry_row, "RightButton")
pt = G.waypointCalls.point
check("right-click sets a waypoint at the giver on the right map", pt is not None and pt.uiMapID == 1429 and abs(pt.x - 0.425) < 1e-9 and abs(pt.y - 0.61) < 1e-9, pt)
check("the map is opened on that zone and the waypoint is tracked", G.waypointCalls.opened == 1429 and G.waypointCalls.track is True)
check("a waypoint message is printed", any("Waypoint set to Test Giver" in s for s in G.printed.values()))
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
