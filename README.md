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
- **Map:** hover a Questie quest icon on the world map or minimap and **Ctrl+click** it. This works for
  quests you haven't picked up yet.
- **Search:** `/qthread` opens the window; type part of a quest name, an ID or a quest link in its box (or
  `/qthread defias`). One match opens it; several show a list to pick from. `/qthread` on its own opens the
  quest that is open in your log.

While the window is open it follows whichever quest you open in the quest log. Escape closes it.

## What the window shows
- The chain as numbered steps (quests on a branch share a step number), each with its level and a status icon:
  a green check (done), a blue "?" (in your log), a gold "!" (available now) or a red lock (locked). Locked quests say what they need on a second line, and your own quest is highlighted and marked "You are here".
- Under each step, in blue, **where it happens**: the zones where its kill targets, objects and item drops
  are found (or where it is handed in, if it has no such objective). The tooltip spells it out per objective,
  for example "Kill Mosshoof Courser, Dustwallow Marsh" or "Collect Soothing Spices (from Jarl, ...)".
- **Hover a step** for its objective, what locks it (a level or the quests you still need), and who starts
  and ends it with the zone and coordinates.
- **Right-click a step** to open the map and set a waypoint where its objectives are: the middle of the crowd
  of spawns in its main zone for a kill, a collected item (where it drops) or an object. A step with no known
  objective goes to its quest giver. **Shift+right-click** goes to where the quest is handed in and
  **Alt+right-click** to where it starts. Uses TomTom if you have it, otherwise the game's own waypoint.
- XP per quest and for the chain, reputation totals, and every reward item (hover for its tooltip).
- **Show remaining** totals only what you haven't finished.
- Breadcrumb quests that can also lead into the chain are listed separately.

## Commands
- `/qthread` (or `/questthread`): open or close the window
- `/qthread <part of a name | ID | quest link>`: look a quest up
- `/qthread scale 1.2`: window size (0.6 to 1.6)
- `/qthread reset`: window back to the middle of the screen, normal size, and the quest-log button to its place
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
