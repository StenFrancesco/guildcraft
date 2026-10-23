# Bank memory

## Installation

Copy both complete folders into the Retail addon directory:

```text
World of Warcraft/_retail_/Interface/AddOns/
    The Guild Book/The Guild Book.toc
    The Guild Book Bank/The Guild Book Bank.toc
```

Enable both addons on characters whose banks you want to save. The folders contain multiple files; placing two individual files directly in Interface is not an addon installation. The Guild Book can still be used without the companion, but Bank explains that The Guild Book Bank is needed for capture.

The Guild Book Bank stores account-wide `TheGuildBookBankDB` SavedVariables. Blizzard writes SavedVariables to disk on normal logout or UI reload. The Guild Book reads the already-loaded Lua table inside the game; there is no external file reader or service. Guild-bank snapshots can synchronize between compatible online addon clients using throttled in-game addon messages; cached manifests alone do not authorize a transfer, and the responder must have live access to the requested tab.

## Using the view

Open The Guild Book and select Bank. Guild Bank is always first and resolves to the current character's guild. Character entries combine characters already known to The Guild Book with characters observed by The Guild Book Bank. A guild character's entry does not imply that you can remotely read their personal bank.

Visit a banker on each of your characters to save that character's available personal bank. Open a guild bank and normally view the guild tabs you want to remember. The companion observes the normal data-ready events; it does not request or select other tabs itself. Automatic guild-bank synchronization begins only after opening a guild bank establishes the tabs this client can currently view. Clients exchange bounded manifest pages and session-end notices over GUILD, then send needed complete tab snapshots directly over WHISPER. A client requests only tabs it can currently view. A peer manifest can be cached for up to 300 seconds, so the responding client rechecks its active guild-bank session and current tab viewability before returning contents; without live access, it sends no contents. Closing the guild bank cancels queued and pending local sync work. One frame already submitted to ChatThrottleLib may still arrive, but stale session or request data is rejected. Different guilds and characters keep separate records. Warband/account banks are outside this feature.

On the Bank page, **Sync bank** is shown only for the Guild Bank entry. It requires an active access-known guild-bank session with viewable tabs. Repeated clicks coalesce into the active or queued manual run. Compatible online clients exchange bounded manifest pages and session-end notices over GUILD, then direct, throttled tab snapshots over WHISPER. Only complete remote snapshots newer than the saved tab are merged; equal capture times keep the local snapshot. Missing or unsupported companion, unavailable access, no compatible responder, and timeout states are shown in the Bank page. Saved data remains last-known and available offline; the exchange preserves the existing SavedVariables format.

Select an entry and saved tab to see item slots and stack counts. Hover saved items for their saved item-link tooltips. Snapshots always remain last-known/cached, even when recently captured. Tab timestamps describe when each tab was observed; guild tabs viewed at different times do not form one simultaneous complete snapshot.

No data means there is no usable saved observation. Incomplete or unavailable means a tab could not be observed reliably; previous valid contents are retained when possible. Unobserved tabs are not presented as empty. Capturing stops while a bank is closed or its APIs are unavailable/restricted. Opening or browsing the journal alone does not read bank data or start guild traffic; synchronization starts from an access-known guild-bank session or the **Sync bank** action for that session.

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

Bank data reads remain limited to the normal UI's currently viewable bank containers and tabs; the addon does not request tabs the local client cannot currently view, poll, move items, use protected-action hooks, reconstruct secret values, or acquire external game state. A responder checks its current guild-bank session and tab viewability before returning snapshot contents, even when the request was prompted by a recently cached manifest. Guild-bank synchronization uses bounded, throttled addon messages only between compatible online clients after current tab viewability is established. API failures preserve last-known data and expose uncertainty. Any future acquisition change must repeat the supplied AGENTS.md policy review.

## Manual Retail validation

Automated fixtures cover existing capture, view, and bank-memory behavior; the new peer-sync protocol has no automated fixture and still needs live two-client validation in Retail:

1. Enable both addons, open Bank before visiting a banker, and confirm explicit No data/companion states.
2. Visit a personal bank, inspect saved purchased tabs, empty slots, item links and stack counts. Move an item manually and verify the next normal update changes the saved view.
3. Close the bank and verify journal browsing makes no bank requests. Reload the UI and verify saved content and timestamps persist.
4. Repeat on a second character and verify each character retains their own personal bank snapshot.
5. Open the guild bank and view one tab. Verify other tabs remain unobserved/incomplete. View another tab normally and verify its independent timestamp and items.
6. Test a character without guild-bank tab permissions and confirm unavailable tabs are never shown as empty/current.
7. Switch characters belonging to different guilds and verify the fixed Guild Bank entry selects only the current guild's record.
8. Exercise bank availability/combat restrictions where the client permits it; confirm unavailable data leaves older valid snapshots intact and capture resumes only through allowed events.
9. Disable The Guild Book Bank and verify gear/professions still load and Bank displays installation guidance.
10. With two compatible clients in the same guild, open the guild bank and view the same tab on both. Capture a complete snapshot on Client A, then capture the same tab on Client B later so B's complete snapshot is newer. Confirm automatic manifest comparison. To verify a manual request/merge, keep A's snapshot older than B's and click **Sync bank** on A before an automatic comparison consumes the newer snapshot; verify B's contents are requested and merged. Separately arrange equal capture times with differing contents and confirm the local snapshot is retained.
11. Click **Sync bank** repeatedly during an active transfer and confirm clicks coalesce. Close the bank or change guild during queued work; confirm local queued work stops and any late frame cannot apply a stale response.

## Offline layout previews

Run `python ui-concepts/render-bank-preview.py` for a personal-bank fixture. Use `--state=unavailable` for an unobserved guild tab or `--state=missing` for companion installation guidance. The preview executes the actual addon Lua UI against synthetic data and the existing journal test controls; it never connects to or reads a running game. Set `GGM_LUA` to the Lua executable when it is not on PATH. Native game icons and scrollbars are represented by placeholders.
