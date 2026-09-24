# Guild Gear Memory — Guild Gear Browser Design

**Status:** Design approved for spec review
**Date:** 24 September 2026
**Scope:** Replace the local-only snapshot test view with a searchable browser for saved character gear records.

## Purpose

Provide a single window where a player can find a character whose gear Guild Gear Memory has saved and view that saved gear snapshot. The interface is read-only and must clearly identify the character and when the displayed snapshot was captured.

## User experience

The window has two side-by-side areas:

- **Left:** a search field above an alphabetized list of character records saved in the local database. Search matches character name and realm. Each row identifies the character by name and realm.
- **Right:** the selected character's gear snapshot, with the 16 tracked equipment slots arranged around an open center to echo the supplied World of Warcraft paperdoll screenshot. The display uses item slot icons only; it does not show a 3D character model.

The right panel identifies the selected character and shows the snapshot capture time. Selecting another list row changes the displayed local record. Item slots with no equipped item are shown as empty.

The list contains saved character records only. It is not a live guild roster and does not add roster members that have no saved record. Searching and selecting a character read local SavedVariables only. Neither action inspects a character, requests a fresh copy, nor sends addon messages.

## Architecture and data flow

The browser reads `GuildGearMemoryDB.characters` and includes only records that have a complete, valid identity and a complete valid gear snapshot. The list is sorted case-insensitively by character name, with realm as a tie-breaker. Search filters this in-memory view by name or realm; it does not alter stored data.

Selecting a row passes the corresponding validated record to the detail view model. The detail view presents every tracked slot and the stored capture timestamp. Gear display remains read-only and uses existing item data from the saved snapshot.

This work changes the snapshot test window into a local browsing UI. It does not change storage format, gear capture, inspection, or synchronization behavior. The UI does not trigger guild network traffic.

## Empty and invalid data behavior

- If there are no displayable records, show **No saved guild gear**.
- If a search has no matches, show **No characters found** while preserving the search text.
- A valid saved slot whose item value is empty is displayed as empty.
- Do not fabricate or silently fill missing slots. A record or snapshot that fails validation is not shown as a usable character entry.

## Acceptance criteria

1. The browser lists complete, valid character gear records saved in the local database.
2. Character rows show name and realm and are sorted alphabetically by name, then realm.
3. Searching filters by character name and realm without changing saved data.
4. Selecting a row displays that character's matching saved snapshot and capture time.
5. The right panel shows all 16 tracked slots as item icons or explicit empty slots, arranged around an open center; no 3D character model is required.
6. No-record, no-search-match, and invalid-record cases follow the empty and invalid data behavior above.
7. Opening the browser, searching, and selecting a character do not inspect players, request snapshots, or send guild messages.

## Policy and scope boundaries

All displayed gear comes from validated local records created or received through the existing permitted addon mechanisms. The UI must not label a saved snapshot as live gear. The capture timestamp communicates when it was observed; no freshness guarantee is implied. No new data source, network behavior, or gameplay action is introduced.
