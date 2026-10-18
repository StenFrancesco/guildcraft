# Bank memory

## Installation

Copy both complete folders into the Retail addon directory:

```text
World of Warcraft/_retail_/Interface/AddOns/
    GuildGearMemory/GuildGearMemory.toc
    DysbankMemory/DysbankMemory.toc
```

Enable both addons on characters whose banks you want to save. The folders contain multiple files; placing two individual files directly in Interface is not an addon installation. Guild Gear Memory can still be used without the companion, but Bank explains that DysbankMemory is needed for capture.

DysbankMemory stores account-wide `DysbankMemoryDB` SavedVariables. Blizzard writes SavedVariables to disk on normal logout or UI reload. Guild Gear Memory reads the already-loaded Lua table inside the game; there is no external file reader, service, executable, or network synchronization.

## Using the view

Open Guild Gear Memory and select Bank. Guild Bank is always first and resolves to the current character's guild. Character entries combine characters already known to Guild Gear Memory with characters observed by DysbankMemory. A guild character's entry does not imply that you can remotely read their personal bank.

Visit a banker on each of your characters to save that character's available personal bank. Open a guild bank and normally view the guild tabs you want to remember. The companion observes the normal data-ready events; it does not request or select other tabs itself. Different guilds and characters keep separate records. Warband/account banks are outside this feature.

Select an entry and saved tab to see item slots and stack counts. Hover saved items for their saved item-link tooltips. Snapshots always remain last-known/cached, even when recently captured. Tab timestamps describe when each tab was observed; guild tabs viewed at different times do not form one simultaneous complete snapshot.

No data means there is no usable saved observation. Incomplete or unavailable means a tab could not be observed reliably; previous valid contents are retained when possible. Unobserved tabs are not presented as empty. Capturing stops while a bank is closed or its APIs are unavailable/restricted. Opening the journal never requests bank data or creates guild traffic.

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

No bank queries, guild addon messages, polling, item movement, protected-action hooks, secret reconstruction, or external game-state acquisition are added. API failures preserve last-known data and expose uncertainty. Any future acquisition change must repeat the supplied AGENTS.md policy review.

## Manual Retail validation

Automated fixtures verify the Lua behavior; a live Retail client check is still required:

1. Enable both addons, open Bank before visiting a banker, and confirm explicit No data/companion states.
2. Visit a personal bank, inspect saved purchased tabs, empty slots, item links and stack counts. Move an item manually and verify the next normal update changes the saved view.
3. Close the bank and verify journal browsing makes no bank requests. Reload the UI and verify saved content and timestamps persist.
4. Repeat on a second character and verify each character retains their own personal bank snapshot.
5. Open the guild bank and view one tab. Verify other tabs remain unobserved/incomplete. View another tab normally and verify its independent timestamp and items.
6. Test a character without guild-bank tab permissions and confirm unavailable tabs are never shown as empty/current.
7. Switch characters belonging to different guilds and verify the fixed Guild Bank entry selects only the current guild's record.
8. Exercise bank availability/combat restrictions where the client permits it; confirm unavailable data leaves older valid snapshots intact and capture resumes only through allowed events.
9. Disable DysbankMemory and verify gear/professions still load and Bank displays installation guidance.

## Offline layout previews

Run `python ui-concepts/render-bank-preview.py` for a personal-bank fixture. Use `--state=unavailable` for an unobserved guild tab or `--state=missing` for companion installation guidance. The preview executes the actual addon Lua UI against synthetic data and the existing journal test controls; it never connects to or reads a running game. Set `GGM_LUA` to the Lua executable when it is not on PATH. Native game icons and scrollbars are represented by placeholders.
