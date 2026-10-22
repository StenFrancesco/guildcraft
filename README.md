# The Guild Book

The Guild Book is a World of Warcraft addon suite for browsing saved guild profession, gear, and bank information. Shared information is last-known data from participating addon users; cached snapshots do not prove a character's current in-game state.

## Addons

| Folder | SavedVariables | Purpose |
| --- | --- | --- |
| `The Guild Book` | `TheGuildBookDB` | Main addon and `/ggm` browser. Stores professions, the recipe index, and profession character metadata. |
| `The Guild Book gear` | `TheGuildBookGearDB` | Captures and synchronizes gear, and owns the gear backend used by the main addon's browser. |
| `The Guild Book Bank` | `TheGuildBookBankDB` | Stores last-known carried inventory, personal bank and guild bank snapshots. |

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

The browser initially opens Professions after login or reload. The left navigation
is ordered Professions, Characters, then Bank. Closing and reopening the browser
within the same session preserves the last selected tab.
The profession filters are ordered Own, then All. Own is selected by default,
including when reopening the browser, and lists the current character's captured
professions. All shows the full profession list. When Own has captured entries,
the browser selects a listed profession instead of an unowned default.

The Characters page shows the selected character's Classic class icon in the
portrait frame. It uses built-in game artwork and saves an optional `classToken`
with the character's identity. The class is captured on login and inspection,
shared with complete gear snapshots between updated clients, and retained for
offline display. Older records can also gain it from cached character or guild
roster information when selected. If the class cannot be determined, the frame
shows a question mark. Race and gender labels remain below the icon.

The Characters footer keeps the equipment helper text on the left and the
Last Captured label with its date/time on the right, with separate space for each.

If The Guild Book gear has an unsupported database, gear capture and synchronization are unavailable; profession and bank features remain usable. `/ggm status` reports storage errors. Lua API identifiers and the gear message protocol keep their existing names and formats.

## Data and synchronization

The Bank companion also saves each character's backpack and equipped bags,
including the reagent bag on clients that support it. Capture runs on login,
entering the world and after bag updates, without opening a bank or changing the
UI. Log into each character to refresh its last-known inventory; offline
characters retain their previous snapshot. WoW writes the SavedVariables file
when you log out or reload.

Carried items are stored in
`TheGuildBookBankDB.characters["Name-Realm"].inventory.bags[bagID].slots[slotID]`.
Bag 0 is the backpack. Each item stores `itemID`, `count`, and the available
`itemLink` and `icon`; empty slots have no item entry. Each bag records `numSlots`,
`capturedAt` and `status`, and `inventory` has its own `capturedAt` and `status`.
Unequipped bags have zero slots. Failed or protected reads preserve the previous
snapshot and mark its inventory status `incomplete`; combat-blocked captures retry
after combat. Before the first successful capture, `inventory` can be absent.
Existing bank records and schema version 1 remain compatible. Inventory is saved
locally and is not added to the bank browser or synchronization messages.

- Profession, gear, and bank information is saved locally and may represent an offline character's last-known state.
- Profession browsing and sharing support Alchemy, Blacksmithing, Cooking, Enchanting, Engineering, First Aid, Fishing, Leatherworking, and Tailoring. First Aid is mainly relevant to the legacy client. Profession sharing uses protocol P5 (`GC_PROF5`); participating clients need compatible versions.
- Profession comparisons are bounded and request/event driven. The **Sync profession** action checks up to four eligible peers sequentially and uses a 60-second cooldown. A peer match does not mean every guild member has been checked.
- Login schedules bounded gear and recipe synchronization after a random zero-to-five-minute delay; only unfinished work receives bounded city retries. Gear and profession messages use the embedded ChatThrottleLib; no separate library addon folder is needed.
- Leaving a guild or switching guilds cancels work for the previous guild. Once current membership and roster state are confirmed, a fresh bounded synchronization run is scheduled for the new guild.
- The renamed addons use the SavedVariables globals shown above. Existing SavedVariables are not migrated to the new names, and this branch starts a fresh gear cache. Back up SavedVariables with the game closed if you need to keep existing data.

## Gear synchronization

Inspecting a guild member automatically saves their equipment after the inspection
finishes and refreshes the Characters page. The member does not need the addon.
Incomplete or cancelled inspections leave existing saved gear intact.

Inspection snapshots and owner snapshots use the same gear cache and can be
shared through **Sync gear**. Each slot retains the server time when it was
observed, including empty slots, so delayed updates and older cached snapshots
cannot overwrite newer observations. Receiving or forwarding a snapshot keeps
its original times. Conflicting network observations within the same server
second retain the saved slot; a direct inspection can replace it.

Gear sharing uses protocol 6. Updated clients may send an optional class-identity
companion message before a complete gear snapshot and an optional compact
readiness hint. The existing protocol-6 request, update, and snapshot messages
are unchanged, so older peers retain manual and incremental sync but cannot
discover a fresh character through the new hint. Class metadata is accepted
only with the selected responder's valid snapshot for a pending request; missing
class metadata never clears a known class. Existing gear caches remain readable.
Update all three addon folders together.

At login, the gear addon tries to capture and persist the local character's
complete gear after delays of 1, 2, 4, 8, 16 and 30 seconds when an item link is
temporarily unavailable. Once a complete cache and stable tracker are available,
it sends a small readiness hint after a short delay when guild membership is
usable. A peer with missing, incomplete or older gear then requests a complete
snapshot through the existing paced sync path; the hint itself never contains
gear. If all startup attempts fail, a later valid request for this character can
retry capture, at most once every five seconds. Cached and shared equipment
remains last-known data, not proof of the character's current state.

On the Characters page, select a saved character and click **Sync gear** to
request the freshest complete snapshot available from responding online guild
addon users. The character can be offline if another participant has their
snapshot cached. The panel keeps its saved equipment visible while waiting and
shows completion, failure, or timeout feedback. A successful manual refresh has
a 60-second cooldown, matching the cache responders. `/ggm request Name-Realm`
uses the same request path.

A valid owner gear update automatically requests a complete baseline when the
character is missing or a missed update leaves a sequence gap. Requests coalesce
per character, and repeated failed repairs back off. A newer confirmed baseline
can be repaired during the normal cooldown after a short backoff. A complete observation taken after a missed update can repair the baseline even
when the observer does not know the owner’s update number. Older observations
cannot replace newer saved slots.
Committed changes refresh the visible character panel; opening the browser or
selecting a character does not send gear requests. Gear synchronization requires
guild membership and compatible participating copies of The Guild Book gear.

## Profession synchronization details

The Professions tab shares complete last-known recipe snapshots with guild
members using the same protocol version. A first profession selection can start
a comparison, and a meaningful local snapshot save can announce that change.
Gear and recipes synchronize automatically after a random login delay of zero
to five minutes. Neither requires opening the character browser. The
**Sync profession** button starts immediately when the sync slot is available.
If a comparison or the existing 60-second cooldown is in progress, the click is
retained and the status shows that it is queued. Repeated clicks for the same
profession share one request; clicking a different profession replaces the queued
choice. Automatic work yields after its current transfer so the button request
can run next, and unfinished automatic work remains eligible for city recovery.
Queued requests are bounded and are cancelled when guild synchronization resets.
Each manual operation checks up to four
eligible guild peers one at a time, with the existing 60-second cooldown. A
status reports how many peer caches matched or were compared; it does not claim
agreement across the guild. If more than four peers are eligible, unfinished
automatic work resumes with another bounded candidate window. Manual requests
also rotate the window. Unavailable peers, a
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
queries are accepted; periodic background queries receive no response. Automatic
catch-up uses the bounded peer comparisons described above.

GUILD carries compact hashes and responder-selection notices. Only one selected
pair exchanges manifests and differing character records through
WHISPER. Each manifest contains character GUID, original capture timestamp and
recipe content hash. Profession ID is in the exchange header. New observations
use WoW server time.
Validated learned recipe IDs are merged as a union for each character and
profession, including knowledge from older and equal-time records. A newer
empty remote snapshot cannot erase learned recipes. Locally owned captures keep
their ownership protection. When the recipes match, a small freshness
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
direction. An operation continues through paced batches, with at most eight
comparisons and four peers per profession; each manifest window contains at most
128 characters. Per-peer cursors retain unfinished batches. The recipient acknowledges a record only after
validating the complete transfer. Partial or failed transfers preserve the
previous cache. Visible catalog refreshes are batched during receive bursts;
records are saved and acknowledged as soon as they validate. ChatThrottleLib
defers throttled submissions using its shared traffic queue; terminal send
failures cancel the remaining transport work while retaining automatic catch-up
state. Busy responders keep eligible requests in bounded, deduplicated queues
of at most 16 entries, expiring within 30 seconds. Superseded requests are dropped.

Only unfinished automatic work retries, in a recognized major city, with at least
20 minutes between attempt starts. A timer checks eligibility when the cooldown
expires, including when the player stays in the city. Outside a city, zone and
resting events can resume eligible work. Inns outside city maps do not qualify;
unavailable or unreadable city APIs leave recovery pending. There are at most
three recovery attempts per login and a one-hour deadline per automatic attempt.
Finished work creates no idle polling or broadcasts. Manual synchronization
remains available after automatic retries are exhausted.

Gear uses the existing snapshot request, responder election and confirmed
sequence rules. Automatic target batches include offline guild characters whose
gear may be cached by online members. A target completes only after a validated
snapshot is received. Unresponsive targets cannot permanently block later roster
entries. Guild changes cancel work belonging to the previous guild.

Queued whisper frames check recipient availability before submitting each frame
to ChatThrottleLib. Confirmed
offline recipients cancel the current work while preserving cached records.
Recent valid protocol messages can provide temporary presence evidence when the
guild roster is stale. Unknown presence without that evidence stops the transfer.

Whisper records reach only their selected recipient. Ownership conflicts retain
existing local data and require a fresh observation. Invalid or oversized unions
preserve the valid saved catalog and leave catch-up work unfinished. Shared information remains
last-known/cached, including offline crafters; a peer match does not prove their
current recipes. Profession sync is independent of the gear companion.

This version uses recipe protocol P5 and prefix GC_PROF5. All participating copies
must update: P4 and earlier clients cannot join P5 exchanges. Gear keeps its existing protocol. This sync update adds no storage migration; the renamed addons on main retain their new SavedVariables globals. Profession
traffic remains within supported in-game addon communication and respects
unavailable APIs, combat restrictions and throttling.

LibStub 2 and LibDeflate 1.0.2-release are embedded in The Guild Book and load
before profession sync. Only complete recipe-record payloads of at least 1 KiB
are candidates for level-1 compression; a `Z1` envelope is used only when its
addon-channel encoded form is smaller. Coordination messages and manifests stay
plain. Records are reassembled and decoded before the existing validation,
union merge, storage and acknowledgement flow. Saved variables do not change.

Compressed envelopes include the original byte length and Adler-32 checksum.
The private decoder stops during inflation at the declared length (at most
65,536 bytes), rather than expanding an oversized record first. It also accepts
at most 128 DEFLATE blocks per record, bounding empty-block processing as well
as output size. Invalid lengths,
encoding, truncated/trailing compressed input, checksums or decoded message kinds
are rejected before storage or acknowledgement. Missing compression dependencies
disable profession synchronization. The embedded LibDeflate source has a clearly
marked private bounded-inflate addition; its shared API remains unchanged, and
an existing shared library is reused for compression. Library provenance and
license details are under `The Guild Book/Libs`.

Compression reduces traffic and transport-frame processing. Compression and
inflation still perform bounded synchronous Lua work once per record; an actual
frame-rate improvement must be verified in game.

ChatThrottleLib version 29 is embedded, unchanged, under `Libs/ChatThrottleLib`
in both The Guild Book and The Guild Book gear. The first loaded copy
initializes the shared library; the second reuses it. No fourth addon folder is needed. Gear and
profession frames use BULK priority and retain their existing queue limits.
After each successful send callback, gear yields to the next update without an
additional fixed delay; ChatThrottleLib controls bandwidth and throttle pacing.
A frame counts as submitted only when the library calls back successfully;
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

- [#52 Synchronize guild profession caches through bounded whispers](https://github.com/StenFrancesco/guildcraft/pull/52) â€” Draft; GitHub reports it as mergeable. Live in-game delivery and throttling checks are still outstanding.
- [#51 Store recipe crafters by GUID instead of local IDs](https://github.com/StenFrancesco/guildcraft/pull/51) â€” Draft; depends on #50 and is based on its rename branch. Retarget it after #50 is integrated.
- [#50 Rename Guild Gear Memory addons to The Guild Book](https://github.com/StenFrancesco/guildcraft/pull/50) â€” Draft; GitHub currently reports a merge conflict. Its description reports static checks only; tests and packaging were not run.
