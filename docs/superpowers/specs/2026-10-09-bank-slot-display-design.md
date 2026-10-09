# Bank Slot Display Design

## Goal

Make cached bank contents easier to scan by using a true empty-slot appearance for observed empty slots and reducing the space each item occupies.

## Current behavior and cause

`BankView.lua` marks observed empty slots with `empty = true` and distinguishes unobserved slots with `observed = false`. `BankUI.lua` currently falls back to the question-mark icon whenever a slot has no item icon, so known-empty slots look unknown. The bank grid is also fixed at eight columns with 68-pixel buttons and wide spacing.

## Design

- Render a dedicated empty-slot graphic when a slot is known to be empty.
- Keep the question-mark icon for slots that were not observed and for occupied items whose icon is unavailable.
- Reduce bank item buttons to approximately 40 by 40 pixels and fit 13 columns with tighter spacing. Keep item counts visible; remove redundant `Empty` captions because the empty-slot graphic conveys that state.
- Preserve the existing item click selection, item tooltip, selected styling, and scrolling behavior.
- Do not change snapshot acquisition, storage, or synchronization.

## Acceptance criteria

- An observed empty slot displays the empty-slot graphic instead of a question mark.
- Unobserved slots remain visibly unknown.
- Occupied slots keep their item icon and stack count.
- The grid shows 13 slots across in the existing bank pane and more rows in the same viewport.
- Existing selection and tooltip behavior remains intact.

## Verification

Review the renderer change and its resulting diff. No tests are planned for this presentation-only adjustment.
