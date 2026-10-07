# Character armory journal — proposed design

## Direction

Match the supplied Professions reference and the existing ArtisanJournal implementation in this worktree. Use warm parchment, dark brown serif text, antique gold accents, thin ornamental rules, and painted artwork that fades into the page.

The recommended approach is an armory journal. A minimal reskin would retain the crowded portrait card; a full illustrated character sheet would compete with real equipment icons. The armory journal balances artwork with readable saved equipment.

## Layout

- Preserve the shared window and Library navigation.
- Use one cohesive left library column: Character Library heading, My Characters/Guild controls, parchment search field, count, and framed character rows styled like the profession buttons.
- Put the selected name and realm in a generous detail header, with a decorative armory illustration on its right. Keep capture date and record status readable below the heading, clear of the illustration.
- Keep equipment in two balanced columns, with existing item icons and hover tooltips. Use fine separators and consistent label spacing rather than large nested panel borders.
- Replace the tall black saved-appearance card with a compact antique portrait medallion on parchment. Retain the saved race portrait, race/gender labels, and honest portrait caption; the art must not imply a reconstructed character appearance.
- Put the three weapon slots in a dedicated row below the portrait, with room for labels and Empty/No data text. Keep the footer separate from the weapons.
- Preserve clear no-selection, no-results, unavailable, and incomplete states.

## Assets and implementation boundary

Reuse the existing journal window, parchment, and button assets. Add a decorative armory vignette with equipment, a shield, and a travel ledger, plus faint sepia equipment sketches if needed. Generated artwork contains no text or fake game data. Export textures in the existing addon format and retain editable source images.

Work in PR39-Test, where the illustrated Professions source and assets live. Changes affect presentation only: no new data sources, inspection, synchronization, requests, timers, or gameplay actions. Cached records remain explicitly last-known; completeness does not imply freshness.

## Validation

Run the existing addon test suite. Render a preview using the worktree's existing UI preview tools and inspect text contrast, long names, empty slots, weapon clearance, search/list spacing, and both tab layouts. In-game rendering remains a separate verification step if the game is unavailable.

## Approval

Approved by the user on 2026-10-05.
