# Inspection snapshots and gear freshness

Approved in chat on 2026-10-20. Completed guild-member inspections save complete gear into the regular character cache and refresh the browser. Inspected gear is an authoritative observation just like owner gear. Never manufacture an owner sequence number for an inspection.

Observation timestamps determine slot freshness, including empty/unavailable slots. Preserve original observation times through storage and network relays. Retain sequence tracking independently to detect missing owner updates. A complete observation newer than missed updates supplies a usable baseline. A later single-slot observation must not make unchanged slots look newly observed.

Hook existing NotifyInspect/ClearInspectPlayer calls without generating new inspect requests. Match the completion GUID and unit, verify guild membership, reject incomplete/secret/unreadable data and unit changes, and bound retries. Inspection failures leave saved gear intact.

Upgrade the gear wire protocol so elections advertise both latest slot observation and complete-observation freshness and responses carry per-slot times. Peers need matching versions. Existing storage remains readable using capturedAt as the legacy fallback for per-slot timestamps. Equal-second conflicting network observations retain the current slot; direct complete inspection can replace it. Never replace newer slots with older full snapshots, even when other slots in that full snapshot are useful.

Verification covers inspection success and cancellation, guild identity, incomplete reads, empty slots, late updates, relay timestamp preservation, mixed-age snapshots, sequence repair, responder election, protocol validation, and the existing full Lua 5.1 suite. Commit only after verification and independent review.

Identity boundaries accept unique whitespace/case realm aliases while preserving existing saved keys and matching GUIDs. Responder elections prioritize the latest actual observation; the separately advertised oldest slot time proves whether a complete baseline covers a missed update. Explicit per-slot metadata must have capturedAt equal to its maximum timestamp.
