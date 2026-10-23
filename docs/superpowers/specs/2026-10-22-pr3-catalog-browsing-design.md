# PR3: Cheap catalog and list browsing

## Scope
Implement issue #94 PR3 in the existing test0-01 worktree. Preserve the existing uncommitted PR2 changes and exclude them from the PR3 commit. Preserve SavedVariables, protocol formats, compression, synchronization and existing public synchronous contracts.

## Design
Use fixed-height viewport row pools for recipe and character lists, with two buffered rows on either side. Keep full scroll-child heights so every result remains reachable. Scroll callbacks only rebind visible rows; they do not refilter data or rebuild details. Click handlers read the row's current model. Selection uses recipe IDs and character keys rather than pool positions. Rebinding must clear stale tooltip state and hidden rows' model references.

Reuse catalog models in runtime state keyed by database, profession, roster eligibility and date formatter. Reuse immutable owner descriptors across all recipes in a catalog, formatting each owner's observation date once. Invalidate affected catalog results for recipe content, labels/icons, freshness, identity, ownership, membership, active state, purge, repair and database changes. Keep caches outside SavedVariables and bounded to current revisions. Integrate with existing controlled mutation paths without altering PR2's sync semantics. Retain validation and malformed-data protections.

Precompute normalized recipe and character search/sort labels when models are built. Remove construction of the owner strings that recipe rows hide. Debounce search by 125 ms; cancel or ignore superseded and hidden-view callbacks. Apply searches coherently, preserve valid selection, and clamp scroll when results shrink.

## Alternatives
Pagination changes access and navigation. Incrementally constructing all rows still retains objects proportional to total results. A bounded viewport pool preserves existing browsing behavior and is the selected approach.

## Verification
Add regressions for large recipe/character lists, bounded pools across repeated scrolling/search, last-result access, recycled-row clicks, selection and tooltip behavior. Cover warm model/date reuse and invalidation through supported mutation paths, including freshness, ownership, roster eligibility, rename, repair and database replacement. Record before/after operation counts. Run the complete Lua 5.1 suite and compile all TOC-listed Lua sources. Document in-game visual and frame-time checks as outstanding; standalone tests do not establish an FPS improvement.
