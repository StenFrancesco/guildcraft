# Escape Closes the Guild Gear Browser

**Status:** Approved design
**Date:** 28 September 2026
**Issue:** [#14 Browser window does not close when pressing Escape](https://github.com/StenFrancesco/guildcraft/issues/14)

## Goal

Pressing Escape while the Guild Gear Memory browser is open closes the browser, following standard World of Warcraft UI behavior.

## Design

Register the browser's existing named frame, `GuildGearMemoryBrowserFrame`, in the Blizzard `UISpecialFrames` list when creating the frame. WoW's normal Escape handling will then close the frame. Registration must be idempotent so recreating the UI cannot add duplicate entries.

No custom key handling is needed. The search box retains its existing behavior, and the browser continues to open and close through the existing slash command and close control.

## Scope and policy

This is local UI behavior only. It reads no game state, sends no addon messages, performs no gameplay action, and does not bypass protected or combat restrictions.

## Acceptance

- The browser frame is listed in `UISpecialFrames` once.
- Escape closes the open browser.
- The frame can be reopened normally after Escape closes it.
