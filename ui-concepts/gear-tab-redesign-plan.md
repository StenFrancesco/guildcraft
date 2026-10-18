# Gear tab redesign

The user delegated the visual direction and requested all work in this worktree.
Use an illustrated armory journal, matching Professions' parchment, serif type,
painted hero artwork and softly blended page edges. A minimal reskin would leave
the cramped composition; a full character illustration would imply an appearance
the saved data cannot establish. Keep the saved race portrait honest.

- [x] Generate a dedicated armory page background with blank text space and subtle sketches.
- [x] Match the detail page bounds and edge mask to Professions; remove nested borders.
- [x] Align character header, saved timestamp and completeness badge with clear spacing.
- [x] Balance equipment columns around an antique framed portrait; separate weapon slots and footer.
- [x] Render complete, incomplete, empty and long-name states from the live Lua controls.
- [x] Run UI tests, full suite and diff checks; document any starting failures.

Presentation only: no data acquisition, synchronization, timers, network behavior,
or gameplay changes. Completeness remains distinct from freshness. Preserve slot
tooltips, search, selection and missing-data behavior.

Validation: 417 tests pass under Lua 5.1, 72 focused UI tests pass under Lua 5.4,
and the texture exporter verifies the 1024 × 1024 RGBA pixel round-trip and
uncompressed 32-bit TGA header. The full Lua 5.4 suite's pre-existing recipe
presence failure is due to a fixture calling global `unpack`. Four rendered
states were inspected; native WoW icons/portraits are placeholders. In-game
texture/font/native-frame verification remains required in the game client.

Review caught an equipment-row overlap; 34px buttons at 37px pitch now leave a
3px gap. The regression check failed before the fix and passed afterward.

In-game screenshot follow-up: explicitly left-align the realm beneath the name,
and replace the padded achievement-frame artwork with thin edges drawn at the
portrait bounds. Both new regression checks failed before the fixes. Update the
preview's inherited font alignment and texture replacement behavior, refresh all
four preview states, and rebuild the installable ZIP in this worktree.
