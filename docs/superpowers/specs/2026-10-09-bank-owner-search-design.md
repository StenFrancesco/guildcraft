# Bank Owner Search Design

## Goal

Let users quickly find a saved bank entry by the character or guild that owns it.

## Design

- Add a local search field to the Bank Library above its saved-entry list.
- Filter the existing bank entries as the query changes, matching character names, guild names, entry labels, and realms without regard to case.
- Keep the current selection when it remains in the filtered list; otherwise select the first matching entry. With no matches, clear the detail selection and show a clear empty result state.
- Keep the query while the bank page refreshes. Clearing the query restores all saved entries.
- Search only the bank owner list. Item slots and saved snapshots remain unchanged; searching does not read bank APIs, modify SavedVariables, or send network traffic.

## Acceptance criteria

- A partial character, guild, or realm query filters the bank entry list case-insensitively.
- An empty query shows every existing entry, including Guild Bank.
- No matching query shows a no-results state and no stale selected-bank details.
- Search preserves a still-matching selection and does not mutate cached bank records.

## Verification

Use the existing Lua 5.1 test harness to verify filtering, selection, refresh behavior, empty results, and no mutation. Review the Bank page layout and run the full suite.
