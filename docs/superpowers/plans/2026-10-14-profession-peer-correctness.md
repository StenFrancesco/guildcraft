# Profession peer correctness implementation plan

> **For agentic workers:** Use subagent-driven-development for implementation and independent review.

**Goal:** A manual profession sync can discover Bob's newer cache after comparing Alice, within a finite budget.

**Architecture:** Existing P3 messages, bounded request-owned candidate list, sequential preferred-peer comparisons; retain original snapshot timestamps and transport guards.

**Tech Stack:** Lua 5.1, existing deterministic guild bus tests.

## Global constraints

- Stay on Improved-struc; write only inside E:\Razz Addon.
- At most four distinct peer comparisons per manual operation; no retry of an unavailable peer; finite operation deadline.
- Preserve existing four-record session limit, cooldowns, secret/combat guards, and locally owned record protection.
- No login broadcasts, no periodic background announcements or polling, and no claim of guild-wide agreement.
- Do not edit unrelated existing workspace changes. Delegated workers must not commit or push. The root agent may append a reviewed commit to PR #52's existing feature branch; no merge, deployment, history rewrite, or deletion.
- Every delegated worker uses gpt-6-luna with xhigh reasoning; no silent substitutions.

## Task 1: Request-driven bounded peer correctness

Files: GuildGearMemory/ProfessionSync.lua, tests/profession_sync_test.lua, tests/main_test.lua (if lifecycle expectations require it), README.md.

- [x] Add an end-to-end failing regression with an offline crafter: Alice and requester have capture 1700000001 and recipes {3,8}, Bob has 1700000002 and {3,8,9}. Only the requester calls manual sync; its final snapshot must equal Bob's original timestamp and membership. Confirmed red before production edits: 60 passed / 1 failed, requester retained 1700000001.
- [x] Also retain the older-Alice variant (1700000000 and {3}) as coverage. Investigation showed an older first peer can sometimes reach Bob through change-triggered notices; equal-first-peer is the proven blind spot.
- [x] Add Alice-matches/requester case, plus bounded many-peer and no idle-traffic tests. Execute `./tools/lua/lua.exe -e 'require("tests.profession_sync_test"); require("tests.testlib").run()'` and confirm the missing-behavior failure before implementation.
- [x] Implement the finite manual-operation candidate list and preferred-peer continuation. Reuse existing request/session/pending structures where safe. Keep retry/cancellation behavior explicit and ensure timestamps, not hash ordering, select records.
- [x] Disable login/background network generation and adapt obsolete automatic-polling tests. Preserve meaningful save-created jobs and explicitly requested repairs.
- [x] Document the request-driven limits and peer-scoped matching status in README.md; remove conflicting policy-exception text.
- [x] Address independent review findings with failing regressions: directed queries must not consume bystander sessions; a busy candidate start must remain uncertain; separately clicked manual requests must rotate past the first four eligible peers; cancellation after an earlier conflict must keep the conflict visible. Preserve meaningful-save backoff and the four-peer/request budget. README must describe aggregate counts accurately.
- [x] Run focused tests, full `./tools/lua/lua.exe tests/run.lua`, parse changed Lua sources, and `git diff --check`; report exact results and any baseline failures. System `lua` is 5.4 and cannot run the addon environment tests correctly; use the workspace Lua 5.1.5 runtime. Final clean export: 598 passed / 0 failed; 64 tracked Lua files parsed.
- [x] Review the task diff independently for spec compliance and correctness before committing only task files. Task review and final integration review pass. Leave unrelated changes untouched. Update the PR only via its existing branch; no merge or deployment.
