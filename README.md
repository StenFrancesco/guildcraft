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

Recipe storage uses full character GUIDs. For example, `professionRecipeIndex[164][41234]` contains:

```lua
{
    name = "Copper Bracers",
    crafters = { "Player-1303-01234567", "Player-1303-89ABCDEF" },
}
```

`professionCharacters` is also keyed by GUID. Recipe index version 4 automatically migrates valid version 3 numeric IDs on load, then removes the old GUID-to-local-ID map and ID counter. Ambiguous or damaged mappings leave the saved data intact and report an unavailable index instead of guessing recipe ownership. WoW persists the migrated format on normal logout or UI reload.

Run the regression suite with Lua 5.1 using `lua tests/run.lua`. In this workspace, the local Lua 5.1 runtime can be used with `./tools/lua/lua.exe tests/run.lua`.

The Professions tab shares complete last-known recipe snapshots with guild
members using the same protocol version. A first profession selection can start
a comparison, and a meaningful local snapshot save can announce that change.
Login, roster readiness, and elapsed time alone create no profession traffic.
The **Sync profession** button starts a bounded operation that checks up to four
eligible guild peers one at a time, with the existing 60-second cooldown. A
status reports how many peer caches matched or were compared; it does not claim
agreement across the guild. If more than four peers are eligible, a later manual
request rotates to another bounded candidate window. Unavailable peers, a
reached limit, or incomplete evidence leave the status at **Catch-up needed**.
Legacy login and background hashes are cached as hints, while legacy periodic
queries receive no response.

GUILD carries compact hashes and responder-selection notices. Only one selected
pair exchanges manifests and missing/newer character records through
WHISPER. Each manifest contains character GUID, original capture timestamp and
recipe content hash. Profession ID is in the exchange header. New observations
use WoW server time.
The newest complete observation wins. When the recipes match, a small freshness
message updates the observation metadata without transferring the recipes again.
Receiving data preserves its original timestamp. Data received during a
comparison is not rebroadcast to wake other guild members.
Known recipes retain their local labels. Unfamiliar shared recipes use the
sender's label when available, otherwise an explicit recipe ID. Recipe requests
include a bounded hint about labels already in the recipient's catalog, so the
sender can omit redundant names and icons. This hint can occasionally suppress
an unfamiliar label; the UI then shows the recipe ID. It never determines which
recipes belong to a character or whether a snapshot is complete.

Each exchange transfers at most four character-profession records and uses
bounded chunks, queues and timeouts. Records are requested sequentially in each
direction; larger caches may remain incomplete and require another explicit
request after the cooldown. The recipient acknowledges a record only after
validating the complete transfer. Partial or failed transfers preserve the
previous cache. Visible catalog refreshes are batched during receive bursts;
records are saved and acknowledged as soon as they validate. ChatThrottleLib
defers throttled submissions using its shared traffic queue; terminal send
failures cancel the remaining transport work.

Queued whisper frames check recipient availability before submitting each frame
to ChatThrottleLib. Confirmed
offline recipients cancel the current work while preserving cached records.
Recent valid protocol messages can provide temporary presence evidence when the
guild roster is stale. Unknown presence without that evidence stops the transfer.

Whisper records reach only their selected recipient. Equal-time conflicts retain
existing data and require a fresh observation. Shared information remains
last-known/cached, including offline crafters; a peer match does not prove their
current recipes. Profession sync is independent of the gear companion.

This version uses protocol P3 and prefix GC_PROF3; all participating copies must
use this version. The renamed addons use new SavedVariables globals without
migrating the old data. Profession traffic remains within supported in-game
addon communication and respects
unavailable APIs, combat restrictions and throttling.

ChatThrottleLib version 29 is embedded, unchanged, under `Libs/ChatThrottleLib`
in both The Guild Book and The Guild Book gear. The first loaded copy
initializes the shared library; the second reuses it. No fourth addon folder is needed. Gear and
profession frames use BULK priority and retain their existing pacing and queue
limits. A frame counts as submitted only when the library calls back successfully;
this does not guarantee delivery to the recipient. Missing library support disables
synchronization rather than falling back to unthrottled sends.

Cancellation stops frames still held by the addon and ignores late completion
callbacks. ChatThrottleLib has no public cancellation API, so the single frame
already handed to it by a transport may still be sent after cancellation. The
addon does not modify the library's queues or start the remaining cancelled frames.

To create a local install ZIP containing all three addon folders, run
`python ui-concepts/package-bank-polish.py` (requires Pillow). The output is
`ui-concepts/The-Guild-Book-Addons.zip`.
