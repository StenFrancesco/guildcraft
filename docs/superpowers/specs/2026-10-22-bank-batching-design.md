# Batch local bank updates

Approved in chat on 22 October 2026. Scope: PR 4 of issue #94.

Keep opening captures and public saved data compatible. Queue updates within the open bank session and flush on the next frame. Deduplicate personal container IDs; ambiguous events dominate with one full scan. Guild contents readiness belongs to the tab selected when the event arrives; a later selection must not authorize a read. Refresh metadata once per batch and publish one change notification.

Close, repeated open and controller replacement cancel pending reads. Pending uncaptured contents retain old items and capture times with incomplete status. Combat continues to defer personal capture until regeneration; guild capture still requires fresh readiness after combat. No timers or updates continue when idle. Add no bank synchronization or schema changes.

Verify six occupied 98-slot tabs: three ambiguous update events require 588 reads and one notification; repeated updates to a known container require 98. Verify close/cancel/replacement, secret values, failed reads, unavailable tabs, timestamps and combat. Run full Lua regressions and syntax compilation of TOC-listed Lua files. Preserve existing unrelated checkout edits.
