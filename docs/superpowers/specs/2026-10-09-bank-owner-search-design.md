# Bank Item Search Design

## Goal

Let users find which saved character or guild bank contains an item by searching its name.

## Design

- Add a local item-name search field to the Bank Library above its saved-entry list.
- Search every locally cached character and current-guild bank snapshot using the display name already stored in each saved item link. Match case-insensitively and filter the left list to owners with at least one matching saved item.
- Keep the current owner selected when it still has a match; otherwise select the first matching owner. With no matching items, clear the detail selection and show a clear empty result state.
- Select the first matching tab for a newly selected owner. Highlight every matching item slot in the visible tab; if the user selects another tab, highlight matches there too.
- Keep the query while the bank page refreshes. Clearing the query restores all saved entries and removes item highlights.
- Search reads cached saved snapshots only. It does not read bank APIs, modify SavedVariables, or send network traffic.

## Acceptance criteria

- A partial item-name query filters the bank entry list to owners whose cached item links contain a matching display name.
- An empty query shows every existing entry, including Guild Bank, and removes all item highlights.
- No matching query shows a no-results state and no stale selected-bank details.
- Search selects a matching tab and visibly highlights matching slots while preserving an owner selection that still has a match.
- Refreshing the local cache keeps the query and recomputes matching owners and slots without mutating cached bank records.

## Verification

Review the focused diff and Bank page layout. Search must use only saved item-link display names and must not introduce bank API reads, SavedVariables writes, or network traffic.
