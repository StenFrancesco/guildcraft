# Minimap launcher design

Approved in chat on 2026-10-22.

The Guild Book gets a visible minimap book icon. Left-click opens the existing
browser without changing its selected tab. Right-click opens a small menu with
Options, which opens a simple movable settings window.

Settings: Show minimap icon (default on), Lock icon position (default off), and
Reset icon position (lower-left edge of the minimap). Dragging with the left
mouse button moves the icon around the minimap. Hide, lock, and angle persist in
an optional uiSettings.minimap table in TheGuildBookDB. Existing schemas and
communication protocols stay compatible. /ggm options always reaches settings,
including when the icon is hidden.

Use basic shared frame APIs and built-in book artwork, without external
dependencies or retail-only menu APIs. Frames are reused; drag updates run only
while dragging. Escape closes the menu and settings window. Missing minimap APIs
leave slash commands usable. Do not change synchronization or captured data.

Validation: Lua 5.1 regressions for defaults, persisted and malformed preferences,
click/menu actions, visibility, lock/drag/reset, scaled cursor coordinates,
frame reuse, slash fallback, and startup wiring. Run the full existing suite
and diff checks. Rendering and interaction on supported game clients require
an in-game smoke test.
