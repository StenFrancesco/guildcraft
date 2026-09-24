# Profession Recipe Samples Design

## Goal

Add a small, real recipe sample to the existing Professions page so the UI has a useful foundation for a later recipe directory. The first milestone contains about ten sample recipes for each profession currently selectable in the page.

## Scope

Included:

- Keep the existing six selectable professions: Alchemy, Blacksmithing, Enchanting, Engineering, Leatherworking, and Tailoring.
- Show a recipe list in the right-hand pane when a profession is selected.
- Include approximately ten verified recipes for each selectable profession.
- Mark the list as a sample so it cannot be mistaken for a complete game catalog.
- Keep recipe data in a visible, bundled Lua catalog that can later be replaced or extended by a complete catalog.
- Allow selecting a recipe row for basic local UI feedback, without implying that the addon can identify recipe owners.

Excluded from this milestone:

- Guild recipe ownership, member search, profession scans, or data sharing.
- Addon messages, crafting requests, request inboxes, or notifications.
- Automatic recipe enumeration, external game data acquisition, or a claim that the sample is exhaustive.
- Changes to gear tracking, persistence, or existing guild synchronization.

## User experience

The current profession buttons remain on the left. The right pane shows the selected profession name, a visible “Sample recipes” label, and a scrollable list of its sample recipes. Selecting another profession replaces the rows with that profession’s sample. Selecting a recipe highlights the row and displays its name in a simple detail area. The detail area must not show invented recipe properties or guild-member availability.

If a profession has no validated sample data, show a clear empty state rather than fabricated recipes. The UI must not imply that recipes absent from this list are unavailable in game.

## Catalog data

Add a dedicated, readable Lua catalog module. Each recipe entry should use a stable identifier validated for the target client, its profession key, and a display name verified in that client. Optional icon data may be included only when verified. Catalog entries are display data, not evidence that any particular character has learned a recipe.

Keep the initial catalog limited to roughly ten entries per currently selectable profession. Do not add a large unreviewed dump or dynamically downloaded data. Record the target client version/build used to validate the entries in the catalog comments or adjacent developer documentation. If a recipe cannot be verified for WoW: Forever, leave it out until it can be checked.

## Code boundaries

- Add a focused catalog module and load it from `GuildGearMemory.toc` before the profession UI module that consumes it.
- Update the existing Professions page in `SnapshotTestUI.lua` to render catalog entries and handle local selection.
- Keep the catalog independent from SavedVariables and the gear record schema.
- Preserve the current profession selector and all other tabs.

## Safety and data claims

This milestone reads no character or guild recipe state and sends no network messages. It makes no ownership, freshness, completeness, or guild-coverage claims. Recipe names and identifiers must be checked against the target client before being presented as real samples. No protected game state, external process, or alternate data-acquisition path is part of the design.

If implementing the catalog requires a client API or acquisition method whose availability or policy status is uncertain, stop that portion and mark it `POLICY_REVIEW_REQUIRED` under the project guardrails.

## Verification

- Confirm all six existing professions render their own sample list and selection state.
- Confirm catalog entries display only for their associated profession.
- Confirm empty or unavailable catalog data produces an explicit empty state.
- Confirm the interface labels the list as a sample and never describes an unlisted recipe as unavailable.
- Confirm no gear storage or synchronization behavior changes.
- Validate the sample names and identifiers in the target WoW: Forever client before treating them as verified data.
