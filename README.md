# QuestChain

See a quest's **whole chain** (how many parts, which step you're on), the **total XP**, the **reputation**
and every **item reward**, without leaving the game. All data is read live from the **QuestieDB** addon;
nothing is copied or downloaded.

Built for **WoW Forever** (client interface 16001).

## Requirements
- [QuestieDB](https://www.curseforge.com/wow/addons/questiedb) (the database Questie uses; the CurseForge
  app installs it for you if you install QuestieDB or Questie). Questie itself is optional, but needed for
  the map-icon shortcut below.

## Opening the chain
- **Quest log:** every quest in the list has a small round chain-link button next to its tracking checkbox
  (or next to its "(Dungeon)" tag). In a quest's detail view the button sits beside the Back button
  (Shift-drag to move it; `/qchain resetbutton` puts it back).
- **Map:** hover a Questie quest icon on the world map or minimap and **Ctrl+click** it. This works for
  quests you haven't picked up yet.
- **Slash command:** `/qchain` (on the quest open in your log), `/qchain 325`, `/qchain <quest link>`
  or `/qchain The Defias Brotherhood` (exact name). The window's search box takes the same things.

While the window is open it follows whichever quest you open in the quest log. Escape closes it.

## What the window shows
- The chain as numbered steps (quests on a branch share a step number), with **YOU ARE HERE** marking your
  quest, plus done / in-log status.
- XP per quest and for the chain, reputation totals, and every reward item (hover for its tooltip).
- **Show remaining** totals only what you haven't finished.
- Breadcrumb quests that can also lead into the chain are listed separately.

## How XP is worked out
- Quests in your log: the client's own figure (shown plain).
- Every other quest: QuestieDB's `{quest level, base XP}`, scaled to your current level with the vanilla
  rule (full XP up to 5 levels below the quest, 20% less per level below that, never under 10%), then
  rounded. Shown with a `~` because it is an estimate: it assumes you stay at your current level and ignores
  rested XP, buffs and bonuses. At max level estimates are 0.
- `/qchain xpcheck` compares the estimate with the client for every quest in your log and lists mismatches.

## Limits
- QuestieDB has no money rewards, item counts, or which rewards are choose-one; the window lists reward
  items without that distinction. Only about 2,000 of 5,900 quests have item links in QuestieDB.
- Chains are capped at 80 quests (the nearest ones are shown when a chain is larger).
- No script is added to any Blizzard frame, and no StaticPopup is used.

## Developing
    node tests/dump-questiedb.js "<AddOns folder>" data.json
    python -I tests/run.py data.json            # all pass
    python -I tests/run.py data.json --mutate   # must report failures (proves the tests can fail)
Needs `lupa` (`lupa.lua51`, real Lua 5.1). The tests cover the chain/XP logic and a stub-frame run of the
UI; they do not exercise the real WoW API. `tools/make-chain-icon.py` redraws `Chain.tga`; `tools/make-logo.py` redraws `logo.png` (the CurseForge avatar).

## License & credits
MIT, see `LICENSE`. Data: QuestieDB. `Thin.tga` (window border) and the window's look are from
[FlareUI](https://www.curseforge.com/wow/addons/flareui) by Malkkav (MIT).
