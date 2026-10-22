# Minimap Options Implementation Plan

> **For agentic workers:** Use executing-plans to implement this plan task-by-task.

**Goal:** Add the approved minimap launcher and simple options window.

**Architecture:** MinimapLauncher.lua owns preferences, launcher, menu, and options.
Main.lua initializes it after the saved database is ready. SnapshotTestUI.lua routes
/ggm options to it. The existing browser remains responsible for opening its UI.

**Tech Stack:** WoW frame APIs, Lua 5.1, existing Lua test runner.

## Global Constraints

- Base: b78a47a5bc2d42c3c9ba8bbc0719f13d83b63e93.
- Preserve saved data and wire compatibility; add only optional UI preferences.
- No external dependencies, protected gameplay actions, or polling outside drag.
- Keep work local and create a feature commit.

### Task 1: Launcher and options

Files: create The Guild Book/MinimapLauncher.lua and tests/minimap_launcher_test.lua;
modify The Guild Book/Main.lua, The Guild Book/SnapshotTestUI.lua,
The Guild Book/The Guild Book.toc, tests/run.lua, README.md.

Interfaces: InitializeMinimapLauncher(api, db) returns the reused button or nil;
ShowGuildBookOptions(api, db) returns the reused options frame or nil.

- [x] Write behavioral tests using a frame API fixture for persisted settings,
  clicks, options controls, dragging, locking, reset, frame reuse, and absent APIs.
- [x] Run the new suite with Lua 5.1; confirm missing feature failures.
- [x] Implement preference normalization and the shared-frame launcher/menu/options.
  Store uiSettings.minimap = { hide = false, locked = false, angle = 225 } by default.
  Clamp through finite-number validation and modulo 360. Use radians internally.
- [x] Add manifest load before Main.lua, initialize after database startup, and
  route /ggm options before normal browser command handling.
- [x] Document interactions and recovery command in README.md.
- [x] Run all tests, inspect the complete diff, request independent review,
  resolve findings, and commit only the feature files.

Validation: 826 passed, 0 failed using Lua 5.1. Independent review found no
additional actionable issues. In-game visual/input smoke testing is outstanding.
