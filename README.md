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
        The Guild Book.toc
    The Guild Book gear/
        The Guild Book gear.toc
    The Guild Book Bank/
        The Guild Book Bank.toc
```

Enable the three addons in the game's AddOns list, then open the browser with `/ggm`. The addon databases are stored separately under `WTF/Account/<account>/SavedVariables` when you log out or reload; the addon folders do not go there.

If The Guild Book gear has an unsupported database, gear capture and synchronization are unavailable; profession and bank features remain usable. `/ggm status` reports storage errors. Lua API identifiers and the gear message protocol keep their existing names and formats.

## Data and synchronization

- Profession, gear, and bank information is saved locally and may represent an offline character's last-known state.
- Profession sharing uses protocol P3 (`GC_PROF3`). Participating clients need compatible versions.
- Profession comparisons are bounded and request/event driven. The **Sync profession** action checks up to four eligible peers sequentially and uses a 60-second cooldown. A peer match does not mean every guild member has been checked.
- Login queues one automatic profession sync pass after the guild roster is ready, with a 27-second discovery window. Manual discovery retains its two-second window; there is no periodic background polling. Gear and profession messages use the embedded ChatThrottleLib; no separate library addon folder is needed.
- The renamed addons use the SavedVariables globals shown above. Existing SavedVariables are not migrated to the new names, and this branch starts a fresh gear cache. Back up SavedVariables with the game closed if you need to keep existing data.

## Profession synchronization details

The Professions tab shares complete last-known recipe snapshots with guild
members using the same protocol version. A first profession selection can start
a comparison, and a meaningful local snapshot save can announce that change.
On login, after guild roster readiness, one automatic pass discovers a responder
for each supported profession and exchanges missing or newer cached snapshots.
Login discovery collects replies for 27 seconds; ordinary discovery keeps its
two-second window. Roster refreshes and idle time do not start another pass.
The **Sync profession** button starts a bounded operation that checks up to four
eligible guild peers one at a time, with the existing 60-second cooldown. A
status reports how many peer caches matched or were compared; it does not claim
agreement across the guild. If more than four peers are eligible, a later manual
request rotates to another bounded candidate window. Unavailable peers, a
reached limit, or incomplete evidence leave the status at **Catch-up needed**.
When comparisons start simultaneously, a manual request takes precedence over
an automatic comparison; ties use the normalized character name and realm.
The other initiator yields before peer selection so it can answer the winning
request. An interrupted manual operation remains **Catch-up needed** until a
later comparison completes. Exchanges already transferring records finish first.
If no peer answers within the response window, `/ggm status` reports
`profession-sync-no-responder`. The command also reports profession registration,
roster readiness, and send errors on each client.
Login and background hash announcements are cached as hints. Login comparison
queries are accepted; periodic background queries receive no response. All
participants must run a version that accepts login comparisons to auto-sync.

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
