# Guild Gear Memory

Install and enable all three sibling folders in your WoW `Interface/AddOns` folder:

```text
Interface/AddOns/
    GuildGearMemory/
    DysbankMemory/
    DysgearMemory/
```

Each folder must directly contain its matching `.toc` file. GuildGearMemory
remains the main addon and provides the `/ggm` browser.

| Folder | Saved global | Contents |
| --- | --- | --- |
| GuildGearMemory | GuildGearMemoryDB | Professions, recipe index, and profession character metadata |
| DysbankMemory | DysbankMemoryDB | Last-known personal and guild bank snapshots |
| DysgearMemory | DysgearMemoryDB | Gear capture, stable changes, last-known gear, ownership, and guild synchronization |

DysgearMemory owns the gear backend and runs capture and synchronization even
when GuildGearMemory is disabled. GuildGearMemory reads its versioned backend
interface to show the same gear browser and `/ggm` commands. Install matching
versions of both folders; the earlier persistence-only companion is unsupported.
The saved gear format and guild message protocol remain unchanged by this split.

WoW writes these to separate files under
`WTF/Account/<account>/SavedVariables` when you log out or reload. The three
addon folders belong in `Interface/AddOns`, not in `SavedVariables`.

This branch starts a fresh gear cache. Old gear in GuildGearMemoryDB is not
migrated; its legacy gear fields are removed after profession storage validates.
Your character's gear is captured again at login through the existing addon API
path. Profession and bank data stay in their respective databases. Offline
characters remain unavailable until a permitted observation or explicit cached
snapshot request supplies their gear.

If DysgearMemory is missing, disabled, or has an unsupported database, gear
capture and synchronization are unavailable; profession and bank features remain
usable. `/ggm status` reports storage errors. Back up SavedVariables with WoW
closed before manually resetting any database.

The Professions tab shares complete last-known recipe snapshots with guild
members using the same protocol version. It compares profession hashes after
login and guild roster readiness, when snapshots change, when a profession is
first selected, and through randomized background checks every 5–7 minutes.
Matching hashes heard recently suppress redundant background announcements.
The **Sync profession** button compares the selected profession again, subject
to a 60-second cooldown. Nearby updates coalesce into paced notices.

GUILD carries compact hashes and responder-selection notices. Only one selected
pair exchanges manifests and missing/newer character records through
WHISPER. Each manifest contains character GUID, original capture timestamp and
recipe content hash. Profession ID is in the exchange header. New observations
use WoW server time.
The newest complete observation wins. When the recipes match, a small freshness
message updates the observation metadata without transferring the recipes again.
Receiving or forwarding data preserves its original timestamp.
Known recipes retain their local labels. Unfamiliar shared recipes use the
sender's label when available, otherwise an explicit recipe ID. Recipe requests
include a bounded hint about labels already in the recipient's catalog, so the
sender can omit redundant names and icons. This hint can occasionally suppress
an unfamiliar label; the UI then shows the recipe ID. It never determines which
recipes belong to a character or whether a snapshot is complete.

Exchanges transfer at most four character-profession records and use bounded
chunks, queues and timeouts. Records are requested sequentially in each direction;
large transfers can defer remaining records to the next exchange. The recipient
acknowledges a record only after validating the complete transfer. Partial or
failed transfers preserve the previous cache. Visible catalog refreshes are batched
during receive bursts; records are saved and acknowledged as soon as they validate.
Deferred comparisons and background checks gradually catch up larger caches;
the old eight-record login ceiling is removed. ChatThrottleLib defers throttled
submissions using its shared traffic queue; terminal send failures cancel the
remaining transport work.

Queued whisper frames check recipient availability before submitting each frame
to ChatThrottleLib. Confirmed
offline recipients cancel the current work while preserving cached records.
Recent valid protocol messages can provide temporary presence evidence when the
guild roster is stale. Unknown presence without that evidence stops the transfer.

Whisper records reach only their selected recipient. Other missing clients take
their own deferred turn; up-to-date records are not downloaded again. Equal-time
conflicts retain existing data and require a fresh observation. Shared information
remains last-known/cached, including offline crafters; agreement does not prove
their current recipes. Profession sync is independent of the gear companion.

This version uses protocol P3 and prefix GC_PROF3; all participating copies must
use this version. Existing SavedVariables do not need migration. On 2026-10-13
the user retired the older AGENTS.md synchronization restrictions and approved
this bounded background design. All traffic remains within supported in-game addon communication and
respects unavailable APIs, combat restrictions and throttling.

ChatThrottleLib version 29 is embedded, unchanged, under `Libs/ChatThrottleLib`
in both GuildGearMemory and DysgearMemory. The first loaded copy initializes the
shared library; the second reuses it. No fourth addon folder is needed. Gear and
profession frames use BULK priority and retain their existing pacing and queue
limits. A frame counts as submitted only when the library calls back successfully;
this does not guarantee delivery to the recipient. Missing library support disables
synchronization rather than falling back to unthrottled sends.

Cancellation stops frames still held by the addon and ignores late completion
callbacks. ChatThrottleLib has no public cancellation API, so the single frame
already handed to it by a transport may still be sent after cancellation. The
addon does not modify the library's queues or start the remaining cancelled frames.

Run the regression suite with Lua 5.1 using `lua tests/run.lua`. In this
workspace, the local Lua 5.1 runtime can be used with
`./tools/lua/lua.exe tests/run.lua`.

To create a local install ZIP containing all three addon folders, run
`python ui-concepts/package-bank-polish.py` (requires Pillow). The output is
`ui-concepts/GuildGearMemory-ThreeFolders.zip`.
