# PR1: Stop unnecessary UI refreshes

Approved in chat on 22 October 2026.

Use runtime dirty flags for profession and character data. Hidden or inactive profession events retain dirtiness without constructing a catalog. A visible event burst queues one refresh; opening or entering the dirty page flushes it immediately and consumes the pending work. Clean profession re-entry reuses the rendered catalog. Actual visibility gates rendering, including profession selection while hidden.

Separate opening the browser from refreshing Characters. Committed gear changes invalidate Characters and refresh only that visible page; Bank and Professions are untouched. Rebind selected characters to current saved records. Keep search, recipe/character selection and scroll positions when still valid. Retain the existing Own default on reopening and choose an owned profession if the prior choice is no longer listed.

Do not change SavedVariables, synchronization, protocols, codecs, traffic limits or material loading. The selected test0-01 baseline includes profession compression and gear protocol 6; preserve that baseline. Validate operation counts, latest saved-data rendering, selection state, coalescing, hidden callbacks and no gear requests on opening/selection. Run the full Lua suite and compile every TOC-listed Lua source before a local commit. In-game FPS and material-loading verification are outside this change.
