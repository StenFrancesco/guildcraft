local T = require("tests.testlib")

local function loadMainModules()
    local GGM = {}
    for _, file in ipairs({ "Constants", "GearData", "GearSnapshot", "ProfessionSnapshot", "ProfessionIndex", "Storage", "SavedDatabases" }) do
        T.loadAddonFile("GuildGearMemory/" .. file .. ".lua", GGM)
    end
    return GGM
end

local function loadCompanion(saved)
    local handler
    local api = setmetatable({ DysgearMemoryDB = saved }, { __index = _G })
    api._G = api
    api.CreateFrame = function()
        return {
            RegisterEvent = function(_, event) T.assertEqual(event, "ADDON_LOADED") end,
            SetScript = function(_, _, fn) handler = fn end,
        }
    end
    local chunk = assert(loadfile("DysgearMemory/Main.lua"))
    setfenv(chunk, api)
    chunk("DysgearMemory", {})
    handler(nil, "ADDON_LOADED", "OtherAddon")
    T.assertNil(rawget(api, "DysgearMemoryAPI"))
    handler(nil, "ADDON_LOADED", "DysgearMemory")
    return api
end

T.test("gear companion initializes independent storage without equipment or network APIs", function()
    local api = loadCompanion()
    T.assertEqual(api.DysgearMemoryDB.schemaVersion, 7)
    T.assertEqual(type(api.DysgearMemoryDB.characters), "table")
    T.assertEqual(type(api.DysgearMemoryDB.localCharacters), "table")
    T.assertNil(api.DysgearMemoryDB.professions)
    T.assertTrue(api.DysgearMemoryAPI.GetDatabase() == api.DysgearMemoryDB)
    T.assertNil(api.DysgearMemoryError)
end)

T.test("gear companion preserves unsupported and malformed saved databases", function()
    for _, saved in ipairs({ { schemaVersion = 99, sentinel = true }, { schemaVersion = 7, characters = false, localCharacters = {} } }) do
        local api = loadCompanion(saved)
        T.assertTrue(api.DysgearMemoryDB == saved)
        T.assertNil(rawget(api, "DysgearMemoryAPI"))
        T.assertNotNil(api.DysgearMemoryError)
    end
end)

T.test("split storage discards legacy gear while retaining professions and routes future writes", function()
    local GGM = loadMainModules()
    local legacy = assert(GGM.InitializeDatabase(nil))
    legacy.characters.old = { sentinel = true }
    legacy.localCharacters.old = true
    local professions, guids = legacy.professions, legacy.localCharacterGUIDs
    local api = loadCompanion()
    api.GuildGearMemoryDB = legacy
    local runtime, err, saved, gear, gearErr = GGM.InitializeSavedDatabases(api)
    T.assertNil(err)
    T.assertNil(gearErr)
    T.assertTrue(saved == legacy)
    T.assertTrue(gear == api.DysgearMemoryDB)
    T.assertTrue(runtime ~= saved)
    T.assertTrue(runtime.professions == professions)
    T.assertTrue(runtime.localCharacterGUIDs == guids)
    T.assertNil(saved.characters)
    T.assertNil(saved.localCharacters)
    T.assertNil(gear.characters.old)
    T.assertNil(gear.localCharacters.old)
    runtime.characters.new = { confirmedSequence = 12, complete = false }
    runtime.localCharacters.new = true
    runtime.nextLocalCharacterID = 42
    T.assertEqual(gear.characters.new.confirmedSequence, 12)
    T.assertTrue(gear.localCharacters.new)
    T.assertEqual(saved.nextLocalCharacterID, 42)
    T.assertNil(gear.nextLocalCharacterID)
    local reloaded, reloadErr = GGM.InitializeSavedDatabases(api)
    T.assertNil(reloadErr)
    T.assertTrue(reloaded.characters.new == gear.characters.new)
    T.assertEqual(reloaded.characters.new.confirmedSequence, 12)
end)

T.test("missing gear companion leaves professions available without exposing legacy gear", function()
    local GGM = loadMainModules()
    local legacy = assert(GGM.InitializeDatabase(nil))
    legacy.characters.old = { sentinel = true }
    local runtime, err, saved, gear, gearErr = GGM.InitializeSavedDatabases({ GuildGearMemoryDB = legacy })
    T.assertNil(err)
    T.assertEqual(gearErr, "gear-companion-missing")
    T.assertNil(gear)
    T.assertNil(runtime.characters)
    T.assertEqual(type(runtime.professions), "table")
    T.assertNil(saved.characters)
end)

T.test("unavailable gear API preserves gear database and still initializes professions", function()
    local GGM = loadMainModules()
    local api = loadCompanion({ schemaVersion = 99, sentinel = true })
    local runtime, err, saved, gear, gearErr = GGM.InitializeSavedDatabases(api)
    T.assertNil(err)
    T.assertNotNil(saved.professions)
    T.assertNil(gear)
    T.assertNotNil(gearErr)
    T.assertNil(runtime.characters)
    T.assertTrue(api.DysgearMemoryDB.sentinel)
end)

T.test("invalid profession schema remains untouched by split startup", function()
    local GGM = loadMainModules()
    local legacy = { schemaVersion = 99, characters = { old = true } }
    local api = loadCompanion()
    api.GuildGearMemoryDB = legacy
    local runtime, err = GGM.InitializeSavedDatabases(api)
    T.assertNil(runtime)
    T.assertEqual(err, "unsupported-schema-version:99")
    T.assertTrue(legacy.characters.old)
    T.assertNil(next(api.DysgearMemoryDB.characters))
end)

T.test("gear addon manifests load storage companion before main with separate saved globals", function()
    local function read(path)
        local file = assert(io.open(path, "r"))
        local content = file:read("*a")
        file:close()
        return content
    end
    local companion = read("DysgearMemory/DysgearMemory.toc")
    local main = read("GuildGearMemory/GuildGearMemory.toc")
    T.assertTrue(companion:find("## SavedVariables: DysgearMemoryDB", 1, true) ~= nil)
    T.assertTrue(main:find("## OptionalDeps: DysbankMemory, DysgearMemory", 1, true) ~= nil)
    T.assertTrue(main:find("Storage.lua", 1, true) < main:find("SavedDatabases.lua", 1, true))
end)

T.test("real gear storage writes and sequence gaps persist only in the companion", function()
    local GGM = loadMainModules()
    local api = loadCompanion()
    local runtime, err, professions, gear = GGM.InitializeSavedDatabases(api)
    T.assertNil(err)
    api.GuildGearMemoryDB = professions
    local identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1234-ABCDEF" }
    local slots = {}
    for index, slot in ipairs(GGM.TRACKED_SLOTS) do
        slots[slot.key] = {
            inventorySlotID = slot.inventorySlotID,
            itemID = 2000 + index,
            itemLink = "|Hitem:" .. (2000 + index) .. "|h[Test]|h",
        }
    end
    T.assertTrue(GGM.SaveCompleteCharacterRecord(runtime, identity, { complete = true, capturedAt = 1700000000, slots = slots }, 12))
    T.assertTrue(GGM.MarkLocalCharacter(runtime, identity.key))
    local value = { inventorySlotID = GGM.TRACKED_SLOTS[1].inventorySlotID, itemID = 3001, itemLink = "|Hitem:3001|h[Test]|h" }
    local updated, updateErr, sequence = GGM.UpdateConfirmedCharacterSlot(runtime, identity.key, GGM.TRACKED_SLOTS[1].key, value, 1700000001)
    T.assertTrue(updated)
    T.assertNil(updateErr)
    T.assertEqual(sequence, 13)
    GGM.ApplyReceivedCharacterSlot(runtime, identity.key, GGM.TRACKED_SLOTS[1].key, value, 1700000002, 15)
    local record = assert(GGM.GetCharacterRecord(runtime, identity.key))
    T.assertFalse(record.complete)
    T.assertTrue(record.refreshNeeded)
    T.assertEqual(record.requiredBaselineSequence, 15)
    T.assertTrue(gear.characters[identity.key] == record)
    T.assertNil(professions.characters)
    T.assertNil(professions.localCharacters)
    local reloaded = assert(GGM.InitializeSavedDatabases(api))
    T.assertTrue(GGM.GetCharacterRecord(reloaded, identity.key) == record)
    T.assertTrue(GGM.IsLocalCharacter(reloaded, identity.key))
end)

T.test("main startup with missing gear companion still registers professions and records ownership", function()
    local GGM = loadMainModules()
    T.loadAddonFile("GuildGearMemory/CharacterIdentity.lua", GGM)
    T.loadAddonFile("GuildGearMemory/LocalGearMemory.lua", GGM)
    local handler, professionController
    local api = setmetatable({}, { __index = _G })
    api._G = api
    api.CreateFrame = function()
        return { RegisterEvent = function() end, SetScript = function(_, _, fn) handler = fn end }
    end
    api.UnitGUID = function() return "Player-1234-ABCDEF" end
    api.C_Timer = { After = function() error("gear capture must not be scheduled") end }
    GGM.RegisterSnapshotTestSlashCommand = function() end
    GGM.CreateProfessionLinkSaveController = function(_, db) professionController = { db = db }; return professionController end
    GGM.RegisterProfessionLinkSaveController = function() return true end
    GGM.CreateGuildSync = function() error("gear sync must not start") end
    local main = assert(loadfile("GuildGearMemory/Main.lua"))
    setfenv(main, api)
    main("GuildGearMemory", GGM)
    handler(nil, "ADDON_LOADED", "GuildGearMemory")
    T.assertNil(GGM.startupError)
    T.assertEqual(GGM.gearStartupError, "gear-companion-missing")
    T.assertTrue(GGM.professionLinkSave == professionController)
    T.assertTrue(api.GuildGearMemoryDB ~= GGM.db)
    T.assertNil(api.GuildGearMemoryDB.characters)
    handler(nil, "PLAYER_LOGIN")
    T.assertTrue(api.GuildGearMemoryDB.localCharacterGUIDs["Player-1234-ABCDEF"])
    T.assertNil(GGM.gearTracker)
    T.assertNil(GGM.guildSync)
end)

T.test("profession saves and index updates through the runtime view persist in main storage only", function()
    local GGM = loadMainModules()
    local api = loadCompanion()
    local runtime, err, professions, gear = GGM.InitializeSavedDatabases(api)
    T.assertNil(err)
    local identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A" }
    local snapshot = {
        complete = true, professionID = 164, professionName = "Blacksmithing",
        capturedAt = 1700000000, source = GGM.PROFESSION_SOURCE_PLAYER,
        status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 41234, name = "Copper Bracers" } },
    }
    local saved, saveErr = GGM.SaveProfessionSnapshot(runtime, identity, snapshot, { guildMembershipVerified = true })
    T.assertTrue(saved, saveErr)
    T.assertEqual(professions.nextLocalCharacterID, 2)
    T.assertEqual(professions.professionRecipeIndex[164][41234].name, "Copper Bracers")
    T.assertNotNil(professions.professions[identity.key])
    T.assertNil(gear.professions)
    T.assertNil(gear.professionRecipeIndex)
    T.assertNil(gear.characters[identity.key])
    api.GuildGearMemoryDB = professions
    local reloaded = assert(GGM.InitializeSavedDatabases(api))
    local record = assert(GGM.GetProfessionRecord(reloaded, identity.key))
    T.assertEqual(record.snapshots[164].capturedAt, snapshot.capturedAt)
end)

T.test("unsupported and failing gear APIs degrade gracefully without replacing saved gear", function()
    local GGM = loadMainModules()
    for _, companion in ipairs({
        { schemaVersion = 99, GetDatabase = function() error("must not call incompatible API") end },
        { schemaVersion = 1, GetDatabase = function() error("unavailable") end },
        { schemaVersion = 1, GetDatabase = function() return { schemaVersion = 99 } end },
        { schemaVersion = 1, GetDatabase = function() return { schemaVersion = 7, characters = false, localCharacters = {} } end },
    }) do
        local saved = { sentinel = true }
        local runtime, err, professions, gear, gearErr = GGM.InitializeSavedDatabases({ DysgearMemoryAPI = companion, DysgearMemoryDB = saved })
        T.assertNil(err)
        T.assertNotNil(professions.professions)
        T.assertNil(runtime.characters)
        T.assertNil(gear)
        T.assertNotNil(gearErr)
        T.assertTrue(saved.sentinel)
    end
end)

T.test("guild profession reconciliation and departed-member cleanup work without gear storage", function()
    local GGM = loadMainModules()
    local runtime, err, professions = GGM.InitializeSavedDatabases({})
    T.assertNil(err)
    for _, name in ipairs({ "Alice", "Departed" }) do
        local identity = { key = name .. "-Silvermoon", name = name, realm = "Silvermoon", guid = "Player-1-" .. name }
        T.assertTrue(GGM.SaveProfessionSnapshot(runtime, identity, {
            complete = true, professionID = 164, professionName = "Blacksmithing",
            capturedAt = 1700000000, source = GGM.PROFESSION_SOURCE_GUILD_LINK,
            status = GGM.PROFESSION_CACHE_STATUS,
            recipes = { { recipeID = 41234, name = "Copper Bracers" } },
        }, { guildMembershipVerified = true }))
    end
    local rosterAPI = {
        IsInGuild = function() return true end,
        GetNumGuildMembers = function() return 1 end,
        GetGuildRosterInfo = function()
            local row = { [1] = "Alice-Silvermoon", [17] = "Player-1-Alice" }
            return unpack(row, 1, 17)
        end,
    }
    local reconciled, reconcileErr = GGM.ReconcileProfessionGuildRoster(rosterAPI, runtime)
    T.assertTrue(reconciled, reconcileErr)
    T.assertNil(reconcileErr)
    T.assertTrue(GGM.professionRosterMembershipCurrent)
    T.assertNil(professions.professions["Departed-Silvermoon"])
    local catalog = GGM.BuildProfessionRecipeCatalog(runtime, 164, "Blacksmithing", {})
    T.assertEqual(catalog.state, "ready")
    T.assertEqual(#catalog.recipes[1].knownBy, 1)
    T.assertEqual(catalog.recipes[1].knownBy[1].key, "Alice-Silvermoon")
    T.assertNil(runtime.characters)
    T.assertNil(professions.localCharacters)
end)
