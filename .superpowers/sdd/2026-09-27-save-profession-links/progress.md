# SDD ledger — plan: C:\Projects\WoWF AI Projects\WoWF profession addon\guildcraft\docs\superpowers\plans\2026-09-27-save-profession-links.md

Setup: isolated worktree `codex/save-profession-links` at `6be046c`; plan file is outside the worktree and remains read-only.
Pre-flight: Task 1 produces Constants/ProfessionSnapshot APIs consumed by Tasks 2 and 4; Task 2 produces profession storage APIs consumed by Task 4; Task 3 produces provenance APIs consumed by Task 4; Task 4 produces the controller APIs consumed by Task 5; Task 5 wires the modules and test runner consumed by Tasks 6–7. No conflicting interfaces found in the plan.
Ruling: Lua test execution is unavailable in this environment — preserve the plan's tests and perform static inspection; cost if wrong: runtime defects can only be caught later in a Lua-capable environment.
Task 1: Ruling: the required `lua tests/profession_snapshot_test.lua` and constants test could not execute because no Lua interpreter is installed; static diff validation is the available substitute, with runtime compatibility still requiring a Lua-capable environment.
