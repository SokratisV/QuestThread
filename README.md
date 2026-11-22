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

## Opening the chain
- **Quest log:** every quest in the list has a small round chain-link button next to its tracking checkbox
  (or next to its "(Dungeon)" tag). In a quest's detail view the button sits beside the Back button
  (Shift-drag to move it).
- **Minimap:** a chain button on the minimap opens and closes the window (on the quest open in your log, if
  there is one). Drag it to move it around the minimap. Right-click it and choose "Hide minimap button" to turn it off
  (the chat then tells you how to get it back); `/qthread minimap` hides or shows it.
- **Map:** hover a Questie quest icon on the world map or minimap and **Ctrl+click** it. This works for
  quests you haven't picked up yet.
- **Search:** `/qthread` opens the window; type part of a quest name, an ID or a quest link in its box (or
  `/qthread defias`). One match opens it; several show a list to pick from. `/qthread` on its own opens the
  quest that is open in your log.

- **Talking to someone:** the quest dialogue (accept, progress and reward steps) gets the chain button and the
  quest's ID in its top-right corner. The ID is green for a finished quest, **and for a repeatable quest you
  have completed at least once**, violet while it is in your log, orange otherwise. A repeatable quest has no
  lasting "completed" flag in the game, so this counts the turn-ins QuestThread sees from now on, plus the game's
  flag (dailies and weeklies) and Questie's My Journey history if you have Questie. If the QuestID addon is also
  loaded, QuestThread adds only the chain button next to its text and turns that text green for such a quest.

While the window is open it follows whichever quest you open in the quest log. Escape closes it.

## What the window shows
- The chain as numbered steps (quests on a branch share a step number), each with its level and a status icon:
  a green check (done), a blue "?" (in your log), a gold "!" (available now) or a red lock (locked). Locked quests say what they need on a second line, and your own quest is highlighted and marked "You are here".
- Under each step, in blue, **where it happens**: the zones where its kill targets, objects and item drops
  are found (or where it is handed in, if it has no such objective). The tooltip spells it out per objective,
  for example "Kill Mosshoof Courser, Dustwallow Marsh" or "Collect Soothing Spices (from Jarl, ...)".
- **Hover a step** for its objective, what locks it (a level or the quests you still need), and who starts
  and ends it with the zone and coordinates.
- **Click "You are here"** (under the quest you opened) to open your quest log with that quest selected. It works for
  quests that are in your log; out of combat only.
- **Places are links.** The blue line under a quest lists its zones, and each zone name is clickable: it opens the
  world map on that area (the same line sits in the objectives popup under "Where"). When the optional
  **DungeonJournal** addon is installed and lists the quest, the line starts with an amber "Dungeon: <name>" that
  opens the journal on that quest's page in its dungeon. Without the journal there is simply no dungeon link.
- Clickable text ("You are here", zone names, the dungeon) is **underlined** like a link, and the line lights up
  white while the mouse is over it.
- **Right-click a step** to open the map and set a waypoint where its objectives are: the middle of the crowd
  of spawns in its main zone for a kill, a collected item (where it drops) or an object. A step with no known
  objective goes to its quest giver. **Shift+right-click** goes to where the quest is handed in and
  **Alt+right-click** to where it starts. Uses TomTom if you have it, otherwise the game's own waypoint.
- A **repeatable** quest is tagged "Repeatable" after its ID. Once you have completed it at least once the ID turns
  green and the tag reads "Repeatable · done" (with "2x" and so on for the turn-ins QuestThread has seen). The
  gold "!" stays, since it can be taken again.
- Every quest shows its **ID** (grey, after the name). **Hover a quest and press Ctrl+C** (in the chain or in a
  list of results) and a small box appears with its **Wowhead link** already selected; the copy closes it, and so
  does Escape. This works like Wowhead Quick Link and is only listening while the mouse is on a quest and you are
  out of combat, so it never takes your movement keys.
- XP per quest and for the chain, reputation totals, and every reward item (hover for its tooltip).
- **Breadcrumb quests:** an optional quest that hands you a chain quest earlier appears as an indented
  "Breadcrumb" row right above the quest it leads into, with its own status icon, zone and ID (Ctrl+C, click and
  tooltip work as on any row). It says "No longer needed" once you already have or finished the quest it leads
  into, and is not counted in the step numbers, XP or reward totals. Only what QuestieDB lists as a breadcrumb
  is shown. Every breadcrumb quest carries a small **bread icon** before its name (in the chain, in lists of
  results, in tooltips and in the objectives popup).
- **Objectives popup:** **left-click a quest** and a panel opens beside the window (on the other side when
  there is no room) with what to do: the quest's objective text, each creature to kill, object to use or item to
  collect with where it is (and what drops the item; an item shows its icon, and **hovering it shows the item's own game tooltip**), the quest's **rewards** (XP, reputation, and every reward item with its icon and the same hover tooltip), and where the quest starts and is handed in. When the quest
  is in your quest log it also shows **your progress with the game's own counts** ("Boar slain: 3/8"): QuestieDB
  says what to kill and collect but not how many, so the numbers can only come from the quest log. The panel
  follows the quest you click, closes with its X, and does not open when you open a quest some other way.

## Zones (version 1.1)
The **Zones** tab, next to **Chains** under the title, lists every quest that **starts** in a zone, whatever
chain it belongs to. A quest also counts for the zone your quest log files it under, so a quest you hold always
shows under its own zone's **In log** chip, even when its giver stands in another zone or has no known spawn. Pick a zone by typing its name, or open it from a zone link (**Ctrl+click** a blue zone
name) or with `/qthread zone <name>`; with no name it shows the zone you are standing in.
- **Filter chips:** **Available**, **In log**, **Missed**, **Done**, **All**, each with its count.
- **Missed** means a quest you can no longer do (or have outgrown), and the row says why: you already did a later
  step of its chain ("Skipped"), a quest it excludes is done or in your log, you are over its level cap, or it
  is grey to you ("Outleveled"). Quests meant for another race, class or faction are left out of the list.
- **By type** (the default) shows chains (one row each, with its steps, level range and how much is done),
  then single quests, then **the objects and items that start quests** (a poster, a dropped note) with the quest
  each one starts. **By giver** (the second tab at the right, lit when active like Chains and Zones) shows one fold-out header per NPC, object or item,
  with the quests it gives.
- Click a row for the objectives popup; its **Chain** button opens the chain. Right-click is the waypoint, as
  everywhere.
- **Map panel:** the QuestThread button on the world map (Shift-drag to move it) or `/qthread map` opens the same
  list in a panel beside the map, for the zone the map is showing, and it follows the map as you move between
  zones. A click opens the quest in QuestThread's window. The filter is shared with the Zones tab.

Every quest level in the window is coloured the way the game colours it for you: red (5 or more levels above
you), orange (3-4 above), yellow (within 2), green (still worth XP) and grey (trivial).

## Commands
- `/qthread` (or `/qt`, or `/questthread`): open or close the window
- `/qthread <part of a name | ID | quest link>`: look a quest up
- `/qthread zone [name]`: the Zones tab, on that zone (no name: the zone you are in)
- `/qthread map`: show or hide the panel beside the world map
- `/qthread scale 1.2`: window size (0.6 to 1.6)
- `/qthread minimap`: hide or show the minimap button
- `/qthread reset`: window back to the middle of the screen, normal size, and the buttons (quest log, minimap) to their places
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
- "Locked" is worked out from the level and prerequisite quests QuestieDB lists; race, class, profession and
  reputation requirements are not checked.
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
MIT, see `LICENSE`. Data: QuestieDB. `Thin.tga` (window border) and the window's look are from
[FlareUI](https://www.curseforge.com/wow/addons/flareui) by Malkkav (MIT).
