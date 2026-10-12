# The Guild Book

Install and enable these three sibling addon folders in WoW's `Interface/AddOns` directory:

```text
Interface/AddOns/
    The Guild Book/
        The Guild Book.toc
    The Guild Book Bank/
        The Guild Book Bank.toc
    The Guild Book gear/
        The Guild Book gear.toc
```

Each folder must directly contain its matching `.toc` file. The Guild Book is the main addon and provides the `/ggm` browser. Install matching versions of all three folders.

| Folder | TOC file | SavedVariables global | Contents |
| --- | --- | --- | --- |
| `The Guild Book` | `The Guild Book.toc` | `TheGuildBookDB` | Professions, recipe index, and profession character metadata |
| `The Guild Book Bank` | `The Guild Book Bank.toc` | `TheGuildBookBankDB` | Last-known personal and guild bank snapshots |
| `The Guild Book gear` | `The Guild Book gear.toc` | `TheGuildBookGearDB` | Gear capture, stable changes, last-known gear, ownership, and guild synchronization |

The Guild Book gear addon owns the gear backend and runs capture and synchronization even when The Guild Book is disabled. The main addon reads its versioned backend interface to show the gear browser and `/ggm` commands. The TOCs declare `TheGuildBookDB`, `TheGuildBookBankDB`, and `TheGuildBookGearDB`; Lua API identifiers and the gear message protocol keep their existing names and formats.

WoW writes account-wide SavedVariables under `WTF/Account/<account>/SavedVariables` on normal logout or UI reload. The three addon folders belong in `Interface/AddOns`, not in `SavedVariables`.

If The Guild Book gear is missing, disabled, or has an unsupported database, gear capture and synchronization are unavailable; profession and bank features remain usable. `/ggm status` reports storage errors. Back up SavedVariables with WoW closed before manually resetting any database.

Run the regression suite with Lua 5.1 using `lua tests/run.lua`. In this workspace, the local Lua 5.1 runtime can be used with `./tools/lua/lua.exe tests/run.lua`.

To create a local install ZIP containing all three addon folders, run `python ui-concepts/package-bank-polish.py` (requires Pillow). The output is `ui-concepts/The-Guild-Book-Addons.zip`.
