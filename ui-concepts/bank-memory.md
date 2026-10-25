# Bank memory

## Installation

Copy both complete folders into the Retail addon directory:

```text
World of Warcraft/_retail_/Interface/AddOns/
    The Guild Book/The Guild Book.toc
    The Guild Book Bank/The Guild Book Bank.toc
```

Enable both addons on characters whose banks you want to save. The folders contain multiple files; placing two individual files directly in Interface is not an addon installation. The Guild Book can still be used without the companion, but Bank explains that The Guild Book Bank is needed for capture.

The Guild Book Bank stores account-wide `TheGuildBookBankDB` SavedVariables. Blizzard writes SavedVariables to disk on normal logout or UI reload. The Guild Book reads the already-loaded Lua table inside the game; there is no external file reader or service. Guild-bank snapshots can synchronize between compatible online addon clients using throttled in-game addon messages. Sync starts when a guild bank is opened or when entering a major city. City sync reads only complete snapshots already saved locally and does not reopen the bank or query bank APIs.

## Using the view

Open The Guild Book and select Bank. Guild Bank is always first and resolves to the current character's guild. Character entries combine characters already known to The Guild Book with characters observed by The Guild Book Bank. A guild character's entry does not imply that you can remotely read their personal bank.

Visit a banker on each of your characters to save that character's available personal bank. Open a guild bank and normally view the guild tabs you want to remember. The companion observes the normal data-ready events; it does not request or select other tabs itself. Automatic sync starts when a guild-bank session establishes the tabs this client can currently view, and when entering a major city it can compare and exchange previously saved complete snapshots with compatible online clients. City sync does not query bank APIs. Clients exchange bounded, timestamp-only manifest pages and session-end notices over GUILD, then send needed complete tab snapshots directly over WHISPER. The responder checks the current roster and sends contents only to a requester of the same guild rank. Live-bank sessions additionally restrict transfers to currently viewable tabs. City sessions read from the local saved cache. Closing the guild bank cancels its queued and pending sync work. One frame already submitted to ChatThrottleLib may still arrive, but stale session or request data is rejected. Different guilds and characters keep separate records. Warband/account banks are outside this feature.

On the Bank page, **Sync bank** is shown only for the Guild Bank entry. It requires an active access-known guild-bank session with viewable tabs. Repeated clicks coalesce into the active or queued manual run. Automatic bank-open and city-entry syncs exchange timestamp-only manifests and, when needed, direct throttled tab snapshots. Only complete remote snapshots with a strictly newer capture timestamp replace the saved tab; equal timestamps retain the local snapshot. Missing or unsupported companion, unavailable access, no compatible responder, and timeout states are shown in the Bank page. Saved data remains last-known and available offline; the exchange preserves the existing SavedVariables format.

Select an entry and saved tab to see item slots and stack counts. Hover saved items for their saved item-link tooltips. Snapshots always remain last-known/cached, even when recently captured. Tab timestamps describe when each tab was observed; guild tabs viewed at different times do not form one simultaneous complete snapshot.

No data means there is no usable saved observation. Incomplete or unavailable means a tab could not be observed reliably; previous valid contents are retained when possible. Unobserved tabs are not presented as empty. Capturing stops while a bank is closed or its APIs are unavailable/restricted. Opening or browsing the journal alone does not read bank data. Guild traffic starts from an access-known guild-bank session, entering a major city with complete saved guild snapshots, or the **Sync bank** action for an active bank session.

## Policy and API review

Reviewed on 2026-10-09 against these official Blizzard sources:

- [UI Add-On Development Policy](https://us.forums.blizzard.com/en/wow/t/ui-add-on-development-policy/24534): visible addon source, no fees/ads/in-game donation requests, and no negative realm/player impact including excessive chat use.
- [Blizzard EULA](https://www.blizzard.com/en-us/legal/bfbbb648-bcc6-4b78-a5c7-e2fe20c135df/blizzard-end-user-license-agreement): no bots, hacks, unauthorized data mining, protocol interception or unauthorized connections. The EULA URL in the supplied guardrails could not be retrieved; this official legal page was available for review.
- [Combat Philosophy and Addon Disarmament in Midnight](https://news.blizzard.com/en-us/article/24246290/combat-philosophy-and-addon-disarmament-in-midnight): intentionally restricted information must stay restricted. Capture skips secret values and fails closed when the safety checks cannot be established.

API contracts were checked in Blizzard-authored generated documentation and UI code hosted in a source mirror. These files describe the exposed API surface; the mirror and community addon implementations are not policy authorization:

- [BankDocumentation.lua](https://github.com/tomrus88/BlizzardInterfaceCode/blob/master/Interface/AddOns/Blizzard_APIDocumentationGenerated/BankDocumentation.lua): `CanUseBank`, personal purchased tab metadata, and bank open/close/tab events.
- [ContainerDocumentation.lua](https://github.com/tomrus88/BlizzardInterfaceCode/blob/master/Interface/AddOns/Blizzard_APIDocumentationGenerated/ContainerDocumentation.lua): container slot counts and item fields.
- [GuildBankDocumentation.lua](https://github.com/tomrus88/BlizzardInterfaceCode/blob/master/Interface/AddOns/Blizzard_APIDocumentationGenerated/GuildBankDocumentation.lua): guild open/close and contents update events; these readiness events carry no tab identifier.
- [BankFrame.lua](https://github.com/tomrus88/BlizzardInterfaceCode/blob/master/Interface/AddOns/Blizzard_UIPanels_Game/Mainline/BankFrame.lua) and [Blizzard_GuildBankUI.lua](https://github.com/tomrus88/BlizzardInterfaceCode/blob/master/Interface/AddOns/Blizzard_GuildBankUI/Blizzard_GuildBankUI.lua): Blizzard's normal item-reading paths for available containers/current guild tabs.

Bank data capture remains limited to the normal UI's currently viewable bank containers and tabs; the addon does not request or select tabs, poll bank APIs, move items, use protected-action hooks, reconstruct secret values, or acquire external game state. City sync reads only saved complete snapshots and does not read bank APIs. Before returning contents, a responder checks the requester's current guild rank; a live-bank session also checks current tab viewability, while city sync may forward a previously saved snapshot. Guild-bank synchronization uses bounded, throttled addon messages between compatible online clients. API failures preserve last-known data and expose uncertainty. Any future acquisition change must repeat the supplied AGENTS.md policy review.

## Manual Retail validation

The city-cache trigger and timestamp-only protocol still need live two-client validation in Retail:

1. Enable both addons, open Bank before visiting a banker, and confirm explicit No data/companion states.
2. Visit a personal bank, inspect saved purchased tabs, empty slots, item links and stack counts. Move an item manually and verify the next normal update changes the saved view.
3. Close the bank and verify journal browsing makes no bank requests. Reload the UI and verify saved content and timestamps persist.
4. Repeat on a second character and verify each character retains their own personal bank snapshot.
5. Open the guild bank and view one tab. Verify other tabs remain unobserved/incomplete. View another tab normally and verify its independent timestamp and items.
6. Test a character without guild-bank tab permissions and confirm unavailable tabs are never shown as empty/current.
7. Switch characters belonging to different guilds and verify the fixed Guild Bank entry selects only the current guild's record.
8. Exercise bank availability/combat restrictions where the client permits it; confirm unavailable data leaves older valid snapshots intact and capture resumes only through allowed events.
9. Disable The Guild Book Bank and verify gear/professions still load and Bank displays installation guidance.
10. With two compatible clients in the same guild, open the guild bank and view the same two tabs on both. Capture complete snapshots for both tabs on Client A, then capture both on Client B later so B's snapshots are newer. Confirm A is actively syncing the first tab; while its request is in flight, click **Sync bank** repeatedly. Verify the first transfer finishes, repeated clicks coalesce, and the queued manual comparison then requests and merges the remaining newer tab. Separately arrange equal capture times with differing contents and confirm the local snapshot is retained.
11. With the bank closed, enter a major city on both clients. Confirm they exchange timestamps for complete saved tabs, transfer only tabs with a newer remote timestamp, and keep local data on equal timestamps. Confirm no bank API reads or tab selections occur.
12. Click **Sync bank** repeatedly during an active transfer and confirm clicks coalesce. Close the bank or change guild during queued work; confirm local queued work stops and any late frame cannot apply a stale response. Confirm city-cache requests are limited to same-rank characters.

## Offline layout previews

Run `python ui-concepts/render-bank-preview.py` for a personal-bank fixture. Use `--state=unavailable` for an unobserved guild tab or `--state=missing` for companion installation guidance. The preview executes the actual addon Lua UI against synthetic data and the existing journal test controls; it never connects to or reads a running game. Set `GGM_LUA` to the Lua executable when it is not on PATH. Native game icons and scrollbars are represented by placeholders.
