# The Guild Book

The Guild Book is a World of Warcraft addon suite for browsing saved guild profession, gear, and bank information. Shared information is last-known data from participating addon users; cached snapshots do not prove a character's current in-game state.

## Addons

| Folder | SavedVariables | Purpose |
| --- | --- | --- |
| `The Guild Book` | `TheGuildBookDB` | Main addon and `/ggm` browser. Stores professions, the recipe index, and profession character metadata. |
| `The Guild Book gear` | `TheGuildBookGearDB` | Captures and synchronizes gear, and owns the gear backend used by the main addon's browser. |
| `The Guild Book Bank` | `TheGuildBookBankDB` | Stores last-known personal and guild bank snapshots. |

Install matching versions of all three folders. `The Guild Book gear` runs gear capture and synchronization independently, but the main addon uses it to show the gear browser. The profession and bank features remain available if the gear companion is missing or disabled.

## Installation

Copy all three addon folders into the World of Warcraft `Interface/AddOns` directory. Each folder should directly contain its matching `.toc` file:

```text
Interface/AddOns/
    The Guild Book/
    The Guild Book gear/
    The Guild Book Bank/
```

Enable the three addons in the game's AddOns list, then open the browser with `/ggm`. The addon databases are stored separately under `WTF/Account/<account>/SavedVariables` when you log out or reload; the addon folders do not go there.

## Data and synchronization

- Profession, gear, and bank information is saved locally and may represent an offline character's last-known state.
- Profession sharing uses protocol P3 (`GC_PROF3`). Participating clients need compatible versions.
- Profession comparisons are bounded and request/event driven. The **Sync profession** action checks up to four eligible peers sequentially and uses a 60-second cooldown. A peer match does not mean every guild member has been checked.
- Login, roster readiness, and elapsed time alone do not trigger profession traffic. Gear and profession messages use the embedded ChatThrottleLib; no separate library addon folder is needed.
- The renamed addons use the SavedVariables globals shown above. Existing SavedVariables are not migrated to the new names, and this branch starts a fresh gear cache. Back up SavedVariables with the game closed if you need to keep existing data.

## Development

Run the regression suite with Lua 5.1:

```bash
lua tests/run.lua
```

In this workspace, the bundled runtime can be used with `./tools/lua/lua.exe tests/run.lua`.

## Open pull requests

Status checked 14 October 2026. GitHub currently marks all three open PRs as drafts, so none is marked ready for merge.

- [#52 Synchronize guild profession caches through bounded whispers](https://github.com/StenFrancesco/guildcraft/pull/52) — Draft; GitHub reports it as mergeable. Live in-game delivery and throttling checks are still outstanding.
- [#51 Store recipe crafters by GUID instead of local IDs](https://github.com/StenFrancesco/guildcraft/pull/51) — Draft; depends on #50 and is based on its rename branch. Retarget it after #50 is integrated.
- [#50 Rename Guild Gear Memory addons to The Guild Book](https://github.com/StenFrancesco/guildcraft/pull/50) — Draft; GitHub currently reports a merge conflict. Its description reports static checks only; tests and packaging were not run.
