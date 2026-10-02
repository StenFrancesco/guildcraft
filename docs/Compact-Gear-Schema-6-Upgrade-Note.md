# Guild Gear Memory schema 6 upgrade note

Schema 6 has no automatic migration from older SavedVariables data. Before launching the schema-6 build, reset the addon's SavedVariables using these steps:

1. Close World of Warcraft.
2. Back up `WTF/Account/<account>/SavedVariables/GuildGearMemory.lua`.
3. Remove that file, or edit it and remove only the `GuildGearMemoryDB` global.
4. Only after the backup and removal are complete, launch the schema-6 build.

Resetting this data clears cached gear, profession snapshots and index data, and local-character metadata. Do not remove other addons' SavedVariables.
