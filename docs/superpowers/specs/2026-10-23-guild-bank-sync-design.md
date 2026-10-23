# Guild Bank Snapshot Synchronization Design

**Status:** Approved design; written specification pending user review

**Date:** 23 October 2026
**Scope:** Guild bank snapshot synchronization for participating addon users

## Goal

Share saved guild-bank tab snapshots between online users of The Guild Book, both automatically and through an explicit **Sync bank** action. Keep the bank browser useful offline by retaining validated last-known snapshots.

## Diagnosis of issue #112

The issue report says that opening the guild bank did not make its information appear in the addon. The repository stores bank snapshots locally and has no guild-bank network protocol, so another addon user's snapshot could not reach the reporter. That is a confirmed feature gap, not a failed transfer.

There is a separate local-capture path: The Guild Book Bank reads the currently viewed guild tab from normal bank events and stores it in `TheGuildBookBankDB`; the main browser reads that local database. The issue contains no client version, permissions, or reproduction details, so this design does not claim that synchronization alone explains a blank local snapshot. Capture failures must continue to leave the previous valid snapshot intact and report unavailable or incomplete state instead of showing an unseen tab as empty.

## User-approved behavior

- Synchronization is automatic and can also be started manually.
- Automatic work begins only after the local client has opened the guild bank and established which tabs are currently viewable.
- The manual **Sync bank** action runs the same bounded comparison and transfer for the current guild-bank session. It is unavailable when there is no active session with viewability information.
- Only online, compatible addon users can participate. Offline users catch up when they are online and have established their own current guild-bank access context.
- Data remains a last-known snapshot. Sync status must not imply that a bank is currently unchanged or that every guild member has compared data.

## Synchronization design

Add a new versioned `GC_BANK1` protocol. The Guild Book Bank remains the authority for capture, validation, and its SavedVariables; it exposes narrow validated operations for eligible local reads and remote tab merges through its existing `DysbankMemoryAPI`. The Guild Book owns protocol registration, message handling, ChatThrottleLib transport, peer selection, and the Bank-page action/status. Bank synchronization does not depend on The Guild Book gear. Keep existing SavedVariables keys and shapes readable, and leave the gear and profession protocols unchanged.

Use `GUILD` only for compact discovery and per-tab manifests. Each bank-open session has an ephemeral runtime token. A manifest identifies the guild and session token, lists the tabs the sender can currently view, and gives each tab either its complete cached observation time and content digest or an explicit no-complete-snapshot marker. It contains no slot contents. On bank close, send one compact session-end notice when the guild channel is usable; expire peer session tokens after a bounded lifetime in case the notice is lost. Use direct `WHISPER` messages for per-tab requests and complete snapshot responses. A request and response are bound to the exact requester and responder session tokens plus a bounded request ID. Accept a response only while the local session is still active and the responder token is still live in the recent manifest cache. Route messages through the existing ChatThrottleLib and bounded framing/reassembly pattern. Process only a bounded peer window per run, compare peers sequentially, rotate unfinished peers into later automatic work, and coalesce duplicate requests for the same peer and tab.

For each peer comparison, request only a complete tab snapshot whose validated observation is newer than the local one, or that the local client does not have. A tab with a newer local observation is not requested. Equal timestamps retain the local record to prevent peers from overwriting one another with same-second observations. The selected peer sends only the requested tab; it does not send its entire bank database. A manual request uses the same comparison rules and status reporting as automatic work.

Each complete response carries the exact guild identity, tab ID, tab metadata, observation time, and the complete slot set. Validate sender, guild, tab range, slot count, every slot field, payload/frame limits, and active viewability before writing anything. A malformed, truncated, incomplete, unavailable, or unsupported response never replaces a saved tab. Persist each accepted tab through the existing bank database boundary and notify the main browser so an open Bank page refreshes.

## Permission and session boundaries

Treat viewability as per-client, per-tab, and session-scoped. Derive it only from the normal guild-bank API while the bank is open. Advertise and serve a tab only if the sender can currently view it; request and accept a tab only if the receiver can currently view it. Clear the viewability session on bank close, guild change, or loss of usable bank state, and cancel related pending work. Never probe hidden tabs, switch the selected tab, request inaccessible tab data, or infer access from another character's cache. A previously saved snapshot remains last-known data under the existing browser semantics.

These checks make compliant clients share only tabs each endpoint has established it can view in its current session. Addon messages are not an authentication boundary, so the protocol must not claim to cryptographically prove another client's in-game rank or view permissions.

## Capture and user interface

Keep local capture on the existing normal bank events and use its existing complete-snapshot validation. Only complete, current-session snapshots may be advertised or sent. A peer's transfer must not be treated as a new local observation, rebroadcast as a fresh capture, or assigned a new capture time.

Add **Sync bank** to the Bank page when the bank synchronization API is available. Show a clear state for waiting/comparing, transfer progress, completion, no reachable compatible peers, missing companion, no active access-known bank session, and errors. Keep saved tabs visible while sync runs. The action sends no request when disabled, and repeated clicks coalesce into the active manual run.

## Compatibility and failure handling

- Keep the existing `TheGuildBookBankDB` SavedVariables global and schema compatible; additive optional metadata is permitted only if old records remain valid without migration.
- Older clients ignore `GC_BANK1`; no existing protocol is reinterpreted.
- Bound manifest size, pending requests, active assemblies, queued frames, peer comparisons, and transfer lifetime. Use the existing 255-byte addon-message limit and throttle library; do not add polling, retry loops that increase traffic, or GUILD broadcasts of contents.
- Reject mismatched guilds, stale session identifiers, wrong senders, malformed or oversized frames, expired requests, and transfers that continue after bank close or guild change.
- Send failures, unavailable APIs, combat restrictions, missing companion APIs, and timeout leave last-known snapshots untouched and expose a recoverable status.

## Policy boundaries

Use only Blizzard's supported addon-message and guild-bank APIs. The design adds no external network, file access, data mining, bank interaction, item movement, automated protected action, secret-value reconstruction, or hidden-tab access. Discovery must be bounded and transfers throttled to avoid excessive guild chat traffic. Recheck the current UI Add-On Development Policy and exposed API contracts before implementation.

## Acceptance criteria

1. Opening and normally viewing a permitted guild tab still captures it locally; a complete saved tab remains visible offline.
2. Two compatible online clients with the same guild and active viewability for a tab can discover different observations and transfer the newer complete tab by WHISPER.
3. Automatic synchronization starts from an access-known bank session, uses bounded sequential comparisons, and does not transfer slot data over GUILD.
4. **Sync bank** starts the same bounded process manually, coalesces repeated clicks, and reports completion, no responder, or failure without clearing saved data.
5. Neither endpoint serves or accepts a tab outside its active-session viewable set; closing the bank or changing guild cancels its pending work.
6. Incomplete, malformed, stale, wrong-guild, wrong-peer, or oversized transfers cannot replace saved snapshots; equal-time observations do not flap.
7. Existing bank records load unchanged, and existing gear and profession synchronization continue to use their current protocols.
8. The Bank page refreshes after an accepted snapshot and distinguishes unavailable data from an empty complete tab.

## Documentation updates

Update `README.md` and `ui-concepts/bank-memory.md` to describe guild-bank synchronization, the access-known session requirement, the manual action, compatible-client requirement, and last-known snapshot semantics. Update troubleshooting guidance for `/ggm status` only if the implementation adds bank diagnostics to that command.

## References

- [Issue #112](https://github.com/StenFrancesco/guildcraft/issues/112)
- [UI Add-On Development Policy](https://us.forums.blizzard.com/en/wow/t/ui-add-on-development-policy/24534)
- [Guild Management and Security](https://us.forums.blizzard.com/en/wow/t/spotlight-on-guild-management-and-security/18813)
- [GuildBankDocumentation.lua API mirror](https://github.com/tomrus88/BlizzardInterfaceCode/blob/master/Interface/AddOns/Blizzard_APIDocumentationGenerated/GuildBankDocumentation.lua)
