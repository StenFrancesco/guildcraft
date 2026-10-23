# Basic window settings design and implementation plan

Approved in chat on 2026-10-22. Extend the existing options window with:
window size 75-125% (100% default), whole-window opacity 60-100% (100% default),
lock main-window position (off), center main window, reset appearance, and
auto-align recipe details (on). Retain existing minimap controls.

Save optional uiSettings.window preferences in TheGuildBookDB, preserving all
other fields and existing schemas/protocols. Apply appearance immediately and
on reopening both browser and recipe details. Cap actual scale to the screen
while retaining the requested slider value. Reset appearance changes only size
and opacity. Lock applies to the main browser; recipe details remain draggable.
Center stops active main-window dragging and restores the center anchor.
Position itself remains session-only, matching existing behavior.

Recipe details align at each explicit recipe open, preferably right, otherwise
left, and clamp within the screen. Align top edges with an eight-unit gap.
Use an independent UIParent anchor, so neither window follows the other after
opening. Background recipe refreshes must not reposition details. Disabled
auto-alignment leaves the details window's last independent position intact.
Use each frame's effective scale for screen-space coordinates.

Architecture: new WindowSettings.lua owns preferences, appearance, positioning,
and options controls; MinimapLauncher.lua hosts those controls. SnapshotTestUI.lua
applies appearance at browser open and respects the lock in drag handling.
RecipeDetailsUI.lua applies appearance and placement on explicit recipe open.
Manifest loads WindowSettings.lua before both UIs. No synchronization changes.

- [x] Write and run failing tests for preferences, appearance, locking, centering,
  controls, persistence, reset isolation, alignment/fallback/scaling/independence.
- [x] Implement WindowSettings.lua and integrate manifest, options, and UI hooks.
- [x] Run focused tests and full Lua 5.1 suite; fix regressions.
- [x] Update README and independently review the complete change.
- [x] Run final checks and create a local commit. Do not push without a request.

Validation includes the existing browser fixture for real open/drag paths.
In-game rendering and interaction checks remain required on supported clients.

Results: 836 Lua 5.1 tests passed, zero failed. Independent review found no
actionable issues. Packaging verified 81 files, all manifests, and bank artwork.
Visual placement and real input still need in-game checks.
