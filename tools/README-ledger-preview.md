# Aged ledger development preview

Run `tools/lua/lua.exe tools/preview_ledger.lua` from the repository root to export the real window construction using the existing test fixtures. Then run `render_ledger_preview.py` with Python and Pillow to generate `tools/ledger-preview.png`.

This is a layout and artwork preview, not a World of Warcraft screenshot. It uses the addon's real Lua anchors and bundled TGA textures. Game icons are placeholders; fonts and native template rendering are approximated. No game process, screen, network, or SavedVariables are read.

Before release, check the Character and Professions chapters, recipe details, native and fallback crafter menus, long names, missing data, and scrolling in the supported clients at the player's UI scale. Confirm the parchment and leather load correctly and all labels remain readable.
