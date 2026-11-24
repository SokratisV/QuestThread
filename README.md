# QuestThread

See a quest's **whole chain** (how many parts, which step you're on, what's available and what's locked),
the **total XP**, the **reputation** and every **item reward**, without leaving the game. Hover a step for
its objective and where it starts and ends, and right-click to set a waypoint. All data is read live from
the **QuestieDB** addon; nothing is copied or downloaded.

Built for **WoW Forever** (client interface 16001).

## Requirements
- [QuestieDB](https://www.curseforge.com/wow/addons/questiedb) (the database Questie uses; the CurseForge
  app installs it for you if you install QuestieDB or Questie). Questie itself is optional, but needed for
  the map-icon shortcut below.

Every text in the window is one step bigger than the game's own font it is made from.

## Opening the chain
- **Quest log:** every quest in the list has a small round chain-link button next to its tracking checkbox
  (or next to its "(Dungeon)" tag).
- **Minimap:** a chain button on the minimap opens and closes the window (on the Zones tab, on the area you are
  standing in). Drag it to move it around the minimap. Right-click it and choose "Hide minimap button" to turn it off
  (the chat then tells you how to get it back); `/qthread minimap` hides or shows it.
- **Map:** hover a Questie quest icon on the world map or minimap and **Ctrl+click** it. This works for
  quests you haven't picked up yet.
- **Search:** `/qthread` (or `/qt`) opens the window on the Zones tab, on the area you are standing in; type part of
  a quest name, an ID or a quest link in its box (or `/qthread defias`). One match opens it; several show a list to
  pick from.

- **Talking to someone:** the quest dialogue (accept, progress and reward steps) gets the chain button and the
  quest's ID in its top-right corner. The ID is green for a finished quest, **and for a repeatable quest you
  have completed at least once**, violet while it is in your log, orange otherwise. A repeatable quest has no
  lasting "completed" flag in the game, so this counts the turn-ins QuestThread sees from now on, plus the game's
  flag (dailies and weeklies) and Questie's My Journey history if you have Questie. If the QuestID addon is also
  loaded, QuestThread adds only the chain button next to its text and turns that text green for such a quest.

While the window is open it follows whichever quest you open in the quest log. Escape closes it. Every time the
window opens, the search box starts empty, and the Zones tab opens on the area you are standing in (not the one you
left it on).

The window follows FlareUI's look: a header with the chain-link badge, the name and version and the two views as pill
tabs, the search box with its magnifier, the quest or zone you are looking at with a thin progress bar under it
(green done, blue in your log, gold available), bronze section bands, and filter chips lit on a gold plate.

## What the window shows
- The chain's quests numbered 1, 2, 3 in order, each with its level and a status icon. The **main line** is what the
  chain's last quest needs; every other quest is an **optional side quest**: it hangs to the right off a rail with an
  elbow into a round badge holding its letter (a, b...), tagged "Optional", and dimmer, after the main quest it
  follows; the rail runs through a group of side quests and ends at the last one. A locked quest names what it needs
  with that number ("Finish one of: Blight No More (1), Blight No More (3)"), and the header says how many are main
  and how many optional. Each quest shows its level and a status icon:
  a green check (done), a blue "?" (in your log), a gold "!" (available now) or a red lock (locked). Locked quests say what they need on a second line, and the quest you opened is highlighted. "You are here" marks the quest you have in your quest log, wherever you click in the chain.
- Under each step, in blue, **where it happens**: the zones where its kill targets, objects and item drops
  are found (or where it is handed in, if it has no such objective). The tooltip spells it out per objective,
  for example "Kill Mosshoof Courser, Dustwallow Marsh" or "Collect Soothing Spices (from Jarl, ...)".
- **Hover a step** for its objective, what locks it (a level or the quests you still need), and who starts
  and ends it with the zone and coordinates.
- **Click "You are here"** (under the quest that is in your quest log) to open your quest log with that quest
  selected; out of combat only. A chain with nothing in your log has none.
- **Places are links.** The blue line under a quest lists its zones, and each zone name is clickable: it opens the
  world map on that area (the same line sits in the objectives popup under "Where"). When the optional
  **DungeonJournal** addon is installed and lists the quest, the line starts with an amber "Dungeon: <name>" that
  opens the journal on that quest's page in its dungeon (and the dungeon's own area is then not repeated as a zone
  link). Without the journal there is simply no dungeon link. A zone the game has no map for (a dungeon's own map,
  often) says so when clicked instead of opening the map.
- Clickable text ("You are here", zone names, the dungeon) is **underlined** like a link, and the line lights up
  white while the mouse is over it.
- **Right-click a step** to open the map and set a waypoint where its objectives are: the middle of the crowd
  of spawns in its main zone for a kill, a collected item (where it drops) or an object. A step with no known
  objective goes to its quest giver. **Shift+right-click** goes to where the quest is handed in and
  **Alt+right-click** to where it starts. Uses TomTom if you have it, otherwise the game's own waypoint.
- A **repeatable** quest is tagged "Repeatable" after its ID. Once you have completed it at least once the ID turns
  green and the tag reads "Repeatable · done" (with "2x" and so on for the turn-ins QuestThread has seen). Its
  status icon turns from the gold "!" to a **green "!"**: you have done it, and it can be taken again.
- Every quest shows its **ID** (grey, after the name). **Hover a quest and press Ctrl+C** (in the chain or in a
  list of results) and a small box appears with its **Wowhead link** already selected; the copy closes it, and so
  does Escape. This works like Wowhead Quick Link and is only listening while the mouse is on a quest and you are
  out of combat, so it never takes your movement keys.
- XP per quest and for the chain, reputation totals, and every reward item (hover for its tooltip).
- **Breadcrumb quests:** an optional quest that hands you a chain quest earlier appears as an indented
  "Breadcrumb" row right above the quest it leads into, with its own status icon, zone and ID (Ctrl+C, click and
  tooltip work as on any row). It says "No longer needed" once you already have or finished the quest it leads
  into, and is not counted in the step numbers, XP or reward totals. Only what QuestieDB lists as a breadcrumb
  is shown, and one meant for another race, class or faction is left out (the two factions often have their own lead-in to the same quest). Every breadcrumb quest carries a small **bread icon** before its name (in the chain, in lists of
  results, in tooltips and in the objectives popup).
- **Details pane:** the pane on the right of the window is always there (so the window never changes size) and says
  "Select a quest..." until you **left-click a quest**; then it fills with what to do: the quest's objective text, each creature to kill, object to use or item to
  collect with where it is (and what drops the item; an item shows its icon, and **hovering it shows the item's own game tooltip**), the quest's **rewards** (XP, reputation, and every reward item with its icon and the same hover tooltip), and where the quest starts and is handed in. When the quest
  is in your quest log it also shows **your progress with the game's own counts** ("Boar slain: 3/8"): QuestieDB
  says what to kill and collect but not how many, so the numbers can only come from the quest log. The pane
  follows the quest you click; click the selected quest again to empty it. It starts empty when you open a quest some
  other way. (The window slides left if it would run off the screen.)

- **List | Graph** (the two tabs right of the search box): the Graph view draws the chain as **columns** (one per step)
  of boxes joined by **lines** from each quest to what it unlocks, main quests on top and optional ones under them.
  Hover a box to light its lines and see its tooltip; click for the details pane; right-click for the waypoint, as in
  the list. The box whose details are open gets a bright ring, and its lines stay lit. **Drag** to pan, **Ctrl+scroll**
  (or the - and + buttons) to zoom, **Alt+scroll** to scroll sideways (a hint under the graph says so), **Fit** to fit
  the whole chain. The window grows wider to fit the chain, but never past half the screen's width; it opens fitted,
  centred on your quest.

## My Log
The **My Log** tab (right of **Zones**, or `/qthread log`) is a quick view of your own quest log: your quests under
the game's own zone headers, each with its level, the XP it gives, and either "Ready to turn in" or its first
unfinished objective with the game's own count ("Boar slain: 3/8  +1 more"). The title line says how many are ready
and how many are in progress, with a bar. Click a quest for the details pane, right-click for the waypoint, or use
the chain-link icon (for a quest that is part of a chain) to open its chain. A zone header folds shut like the other
sections. Type in the search box to filter the log by name. The list follows your quest log as it changes. A header
you have folded shut in the game's own quest log hides its quests from the game's list, so it shows with a note
instead.

## Zones (version 1.1)
Clicking the **Zones** tab shows the **list of all zones**, split by continent (each continent folds shut), with how
far you are in each: "done / total" quests that start there, and a thin bar (green once every quest is done). Your
own zone is marked "you are here". Click a zone to open it; the **All zones** button in the zone view (or another
click on the Zones tab) goes back to the list. The window itself opens on the zone you are standing in, not on
the list. The numbers are worked out a few zones at a time, so they fill in over a moment.

Inside a zone, the tab lists every quest that **starts** in it, whatever chain it belongs to. A quest also counts for the zone your quest log files it under, so a quest you hold always
shows under its own zone's **In log** chip, even when its giver stands in another zone or has no known spawn. Pick a zone by typing its name, or open it from a zone link (**Ctrl+click** a blue zone
name) or with `/qthread zone <name>`; with no name it shows the zone you are standing in.
- **Filter chips:** **Available**, **In log**, **Missed**, **Done**, **All** (the counts are in the line under the
  zone's name). The sections of the list (**Chains**, **Single quests**, the object and item starters, **Breadcrumbs**,
  and each giver in By giver) fold shut when you click their header (plus icon), and open again (minus icon).
- **Missed** means a quest you can no longer take at all, and the row says why: you already did a later
  step of its chain ("Skipped"), a quest it excludes is done or in your log, or you are over its level cap.
- A quest you have **outleveled** (grey to you in the game) is still **Available**, since you can take it, and
  so is part of **All**; its row says "Outleveled: quest level 35, you are 47" in grey and carries a "Grey" tag. It
  is never counted as missed. Quests meant for another race, class or faction, and **profession quests for a profession you have not learned**
  (only whether you have the profession counts, not your skill in it), are left out of the list, and out of a
  chain's steps. WoW Forever's Skyborne races are recognised.
- **By type** (the default) shows chains (one row each, with how much is done),
  then single quests, then **the objects and items that start quests** (a poster, a dropped note) with the quest
  each one starts. **By giver** (the second tab at the right, lit when active like Chains and Zones) shows one fold-out header per NPC, object or item,
  with the quests it gives. **Crumbs** (the third) lists only the **breadcrumb quests** (the optional lead-ins to a
  longer quest) of the zone, by level, each saying what it leads into; the filter chips apply to it too.
- Click a row for the details pane. A quest that is part of a chain has a small **chain-link icon** at the right of its
  row (so does each chain row): click it to open the chain. Right-click is the waypoint, as
  everywhere.
- **Map panel:** `/qthread map` opens the same
  list in a panel beside the map, for the zone the map is showing, and it follows the map as you move between
  zones. A click opens the quest in QuestThread's window. The filter is shared with the Zones tab.

Every quest level in the window is coloured the way the game colours it for you: red (5 or more levels above
you), orange (3-4 above), yellow (within 2), green (still worth XP) and grey (trivial).

## Commands
- `/qthread` (or `/qt`, or `/questthread`): open or close the window
- `/qthread <part of a name | ID | quest link>`: look a quest up
- `/qthread zone [name]`: the Zones tab, on that zone (no name: the zone you are in)
- `/qthread log`: the My Log tab, your own quest log
- `/qthread map`: show or hide the panel beside the world map
- `/qthread scale 1.2`: window size (0.6 to 1.6)
- `/qthread minimap`: hide or show the minimap button
- `/qthread reset`: window back to the middle of the screen, normal size, and the minimap button to its place
- `/qthread xpcheck`: compare the XP estimate with the client for every quest in your log

## How XP is worked out
- Quests in your log: the client's own figure (shown plain).
- Every other quest: QuestieDB's `{quest level, base XP}`, scaled to your current level with the vanilla
  rule (full XP up to 5 levels below the quest, 20% less per level below that, never under 10%), then
  rounded. Shown with a `~` because it is an estimate: it assumes you stay at your current level and ignores
  rested XP, buffs and bonuses. At max level estimates are 0.

## Limits
- QuestieDB has no money rewards, item counts, or which rewards are choose-one; the window lists reward
  items without that distinction (so there is no "best reward for your class"). Only about 2,000 of 5,900
  quests have item links in QuestieDB.
- "Locked" is worked out from the level and prerequisite quests QuestieDB lists; reputation and profession *skill*
  requirements are not checked (a quest for a race, class or profession you do not have is left out of the lists
  instead).
- Waypoints depend on QuestieDB's spawn and zone tables; a few givers have no known location.
- Chains are capped at 80 quests (the nearest ones are shown when a chain is larger).
- No script is added to any Blizzard frame, and no StaticPopup is used.

## Developing
    node tests/dump-questiedb.js "<AddOns folder>" data.json
    python -I tests/run.py data.json            # all pass
    python -I tests/run.py data.json --mutate   # must report failures (proves the tests can fail)
Needs `lupa` (`lupa.lua51`, real Lua 5.1). The tests cover the chain/XP/status logic and a stub-frame run of
the UI; they do not exercise the real WoW API. `tools/make-chain-icon.py` redraws `Chain.tga`;
`tools/make-status-icons.py` redraws `Status.tga`; `tools/make-logo.py` redraws `logo.png` (the CurseForge avatar).

## License & credits
MIT, see `LICENSE`. Data: QuestieDB. The graph view's idea (a chain as columns joined by lines) was inspired by the
Completao!! addon; no code was taken from it. `Thin.tga` (window border) and the window's look are from
[FlareUI](https://www.curseforge.com/wow/addons/flareui) by Malkkav (MIT).
