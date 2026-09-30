local T = require("tests.testlib")

local function loadModules()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/Constants.lua", GGM)
    T.loadAddonFile("GuildGearMemory/GearSnapshot.lua", GGM)
    T.loadAddonFile("GuildGearMemory/ProfessionSnapshot.lua", GGM)
    T.loadAddonFile("GuildGearMemory/ProfessionIndex.lua", GGM)
    T.loadAddonFile("GuildGearMemory/Storage.lua", GGM)
    return GGM
end

local function makeSnapshot(GGM)
    local slots = {}
    for index, slot in ipairs(GGM.TRACKED_SLOTS) do
        slots[slot.key] = {
            inventorySlotID = index,
            itemID = 2000 + index,
            itemLink = "|Hitem:" .. tostring(2000 + index) .. "|h[Test]|h",
        }
    end

    return {
        complete = true,
        capturedAt = 1700000000,
        slots = slots,
    }
end

local function makeIdentity()
    return {
        key = "Alice-Silvermoon",
        name = "Alice",
        realm = "Silvermoon",
        guid = "Player-1234-ABCDEF",
    }
end

T.test("database initialization creates schema four on first run", function()
    local GGM = loadModules()

    local db, err = GGM.InitializeDatabase(nil)

    T.assertNil(err)
    T.assertEqual(db.schemaVersion, 4)
    T.assertEqual(type(db.characters), "table")
    T.assertEqual(type(db.localCharacters), "table")
    T.assertNil(next(db.localCharacters))
    T.assertEqual(type(db.professions), "table")
end)

T.test("database initialization backfills local ownership for supported existing schemas", function()
    local GGM = loadModules()
    for _, schemaVersion in ipairs({ 1, 2 }) do
        local existing = { schemaVersion = schemaVersion, characters = {} }

        local db, err = GGM.InitializeDatabase(existing)

        T.assertNil(err)
        T.assertTrue(db == existing)
        T.assertEqual(type(db.localCharacters), "table")
        T.assertNil(next(db.localCharacters))
    end
end)

T.test("database initialization rejects invalid existing local ownership metadata", function()
    local GGM = loadModules()
    local existing = { schemaVersion = 2, characters = {}, localCharacters = false }

    local db, err = GGM.InitializeDatabase(existing)

    T.assertNil(db)
    T.assertEqual(err, "database-local-characters-invalid")
    T.assertFalse(existing.localCharacters == nil)
end)

T.test("database initialization rejects schema 2 without characters before upgrading", function()
    local GGM = loadModules()
    local existing = {
        schemaVersion = 2,
        localCharacters = {},
        professions = {},
    }

    local db, err = GGM.InitializeDatabase(existing)

    T.assertNil(db)
    T.assertEqual(err, "database-characters-invalid")
    T.assertEqual(existing.schemaVersion, 2)
end)

T.test("local ownership marks and queries only valid marked keys", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))

    T.assertFalse(GGM.IsLocalCharacter(db, "Alice-Silvermoon"))
    T.assertTrue(GGM.MarkLocalCharacter(db, "Alice-Silvermoon"))
    T.assertTrue(GGM.IsLocalCharacter(db, "Alice-Silvermoon"))
    T.assertFalse(GGM.IsLocalCharacter(db, "Bob-Silvermoon"))
    for _, key in ipairs({ "", 42, false, {} }) do
        local ok = GGM.MarkLocalCharacter(db, key)
        T.assertFalse(ok)
        T.assertNil(db.localCharacters[key])
    end
end)

T.test("received complete records do not become locally owned", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))

    assert(GGM.SaveReceivedCompleteCharacterRecord(db, makeIdentity(), makeSnapshot(GGM), 0))

    T.assertFalse(GGM.IsLocalCharacter(db, "Alice-Silvermoon"))
    T.assertNil(db.localCharacters["Alice-Silvermoon"])
end)

T.test("complete records copy valid model identity fields and old identities remain readable", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = makeIdentity()
    identity.raceID, identity.sex, identity.displayID = 1, 3, 12345
    local snapshot = makeSnapshot(GGM)

    assert(GGM.SaveCompleteCharacterRecord(db, identity, snapshot, 6))
    local record = assert(GGM.GetCompleteCharacterRecord(db, identity.key))
    T.assertEqual(record.identity.raceID, 1)
    T.assertEqual(record.identity.sex, 3)
    T.assertEqual(record.identity.displayID, 12345)

    local oldIdentity = makeIdentity()
    local oldKey = "Bob-Silvermoon"
    oldIdentity.key, oldIdentity.name = oldKey, "Bob"
    assert(GGM.SaveCompleteCharacterRecord(db, oldIdentity, makeSnapshot(GGM), 2))
    local oldRecord = assert(GGM.GetCompleteCharacterRecord(db, oldKey))
    T.assertNil(oldRecord.identity.raceID)
    T.assertNil(oldRecord.identity.sex)
    T.assertNil(oldRecord.identity.displayID)
    T.assertEqual(oldRecord.gear.slots.HEAD.itemID, 2001)
end)

T.test("half-present or invalid model identity pairs are omitted without changing gear", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = makeIdentity()
    identity.raceID, identity.sex, identity.displayID = 1, nil, 12345
    local snapshot = makeSnapshot(GGM)
    assert(GGM.SaveCompleteCharacterRecord(db, identity, snapshot, 9))
    local record = assert(GGM.GetCompleteCharacterRecord(db, identity.key))
    T.assertNil(record.identity.raceID)
    T.assertNil(record.identity.sex)
    T.assertNil(record.identity.displayID)
    T.assertEqual(record.gear.capturedAt, snapshot.capturedAt)
    T.assertEqual(record.gear.slots.HEAD.itemID, snapshot.slots.HEAD.itemID)
    T.assertEqual(record.confirmedSequence, 9)

    identity.raceID, identity.sex = -1, 4
    assert(GGM.SaveCompleteCharacterRecord(db, identity, snapshot, 10))
    record = assert(GGM.GetCompleteCharacterRecord(db, identity.key))
    T.assertNil(record.identity.raceID)
    T.assertNil(record.identity.sex)
    T.assertNil(record.identity.displayID)
    T.assertEqual(record.gear.slots.HEAD.itemID, snapshot.slots.HEAD.itemID)

    local receivedDB = assert(GGM.InitializeDatabase(nil))
    identity.raceID, identity.sex, identity.displayID = 1, nil, 12345
    assert(GGM.SaveReceivedCompleteCharacterRecord(receivedDB, identity, snapshot, 11))
    local received = assert(GGM.GetCompleteCharacterRecord(receivedDB, identity.key))
    T.assertNil(received.identity.raceID)
    T.assertNil(received.identity.sex)
    T.assertNil(received.identity.displayID)
    T.assertEqual(received.gear.slots.HEAD.itemID, snapshot.slots.HEAD.itemID)
end)

T.test("local model identity update changes metadata only", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = makeIdentity()
    assert(GGM.SaveCompleteCharacterRecord(db, identity, makeSnapshot(GGM), 12))
    local before = assert(GGM.GetCompleteCharacterRecord(db, identity.key))
    local capturedAt = before.gear.capturedAt
    local slots = {}
    for key, value in pairs(before.gear.slots) do slots[key] = value end
    local updatedIdentity = makeIdentity()
    updatedIdentity.raceID, updatedIdentity.sex, updatedIdentity.displayID = 2, 2, 54321

    local ok, err = GGM.UpdateLocalCharacterModelIdentity(db, updatedIdentity)

    T.assertTrue(ok)
    T.assertNil(err)
    local after = assert(GGM.GetCompleteCharacterRecord(db, identity.key))
    T.assertEqual(after.identity.raceID, 2)
    T.assertEqual(after.identity.sex, 2)
    T.assertEqual(after.identity.displayID, 54321)
    T.assertEqual(after.gear.capturedAt, capturedAt)
    T.assertEqual(after.confirmedSequence, 12)
    T.assertTrue(after.complete)
    T.assertTrue(after.gear.complete)
    for key, value in pairs(slots) do T.assertTrue(after.gear.slots[key] == value) end
end)

T.test("local model identity refresh preserves valid last-known metadata conservatively", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = makeIdentity()
    identity.raceID, identity.sex, identity.displayID = 1, 3, 12345
    local snapshot = makeSnapshot(GGM)
    assert(GGM.SaveCompleteCharacterRecord(db, identity, snapshot, 12))

    local unavailable = makeIdentity()
    assert(GGM.UpdateLocalCharacterModelIdentity(db, unavailable))
    local record = assert(GGM.GetCompleteCharacterRecord(db, identity.key))
    T.assertEqual(record.identity.raceID, 1)
    T.assertEqual(record.identity.sex, 3)
    T.assertEqual(record.identity.displayID, 12345)

    local samePairWithoutDisplay = makeIdentity()
    samePairWithoutDisplay.raceID, samePairWithoutDisplay.sex = 1, 3
    assert(GGM.UpdateLocalCharacterModelIdentity(db, samePairWithoutDisplay))
    record = assert(GGM.GetCompleteCharacterRecord(db, identity.key))
    T.assertEqual(record.identity.displayID, 12345)

    local changedPairWithoutDisplay = makeIdentity()
    changedPairWithoutDisplay.raceID, changedPairWithoutDisplay.sex = 2, 2
    assert(GGM.UpdateLocalCharacterModelIdentity(db, changedPairWithoutDisplay))
    record = assert(GGM.GetCompleteCharacterRecord(db, identity.key))
    T.assertEqual(record.identity.raceID, 2)
    T.assertEqual(record.identity.sex, 2)
    T.assertNil(record.identity.displayID)
    T.assertEqual(record.gear.capturedAt, snapshot.capturedAt)
    T.assertEqual(record.confirmedSequence, 12)
    T.assertEqual(record.gear.slots.HEAD.itemID, snapshot.slots.HEAD.itemID)
end)

T.test("received complete baseline still replaces model metadata from its identity", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = makeIdentity()
    identity.raceID, identity.sex, identity.displayID = 1, 3, 12345
    assert(GGM.SaveCompleteCharacterRecord(db, identity, makeSnapshot(GGM), 4))

    local receivedIdentity = makeIdentity()
    local replacement = makeSnapshot(GGM)
    replacement.capturedAt = 1700000100
    assert(GGM.SaveReceivedCompleteCharacterRecord(db, receivedIdentity, replacement, 5))

    local record = assert(GGM.GetCompleteCharacterRecord(db, identity.key))
    T.assertNil(record.identity.raceID)
    T.assertNil(record.identity.sex)
    T.assertNil(record.identity.displayID)
end)

T.test("database initialization reuses a valid existing SavedVariables table", function()
    local GGM = loadModules()
    local existing = {
        schemaVersion = 3,
        characters = {},
        professions = {},
    }

    local db, err = GGM.InitializeDatabase(existing)

    T.assertNil(err)
    T.assertTrue(db == existing)
end)

T.test("database initialization rejects an unsupported schema version", function()
    local GGM = loadModules()
    local existing = {
        schemaVersion = 99,
        characters = {},
    }

    local db, err = GGM.InitializeDatabase(existing)

    T.assertNil(db)
    T.assertEqual(err, "unsupported-schema-version:99")
end)

T.test("saving rejects a database with an unsupported schema version", function()
    local GGM = loadModules()
    local db = {
        schemaVersion = 99,
        characters = {},
    }

    local ok, err = GGM.SaveCompleteCharacterRecord(db, makeIdentity(), makeSnapshot(GGM))

    T.assertFalse(ok)
    T.assertEqual(err, "unsupported-schema-version:99")
    T.assertNil(db.characters["Alice-Silvermoon"])
end)

T.test("reading rejects a database with an unsupported schema version", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = makeIdentity()
    assert(GGM.SaveCompleteCharacterRecord(db, identity, makeSnapshot(GGM)))
    db.schemaVersion = 99

    local record, err = GGM.GetCompleteCharacterRecord(db, identity.key)

    T.assertNil(record)
    T.assertEqual(err, "unsupported-schema-version:99")
end)

T.test("saving a complete snapshot creates a usable character record", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = makeIdentity()
    local snapshot = makeSnapshot(GGM)

    local ok, err = GGM.SaveCompleteCharacterRecord(db, identity, snapshot)

    T.assertTrue(ok)
    T.assertNil(err)

    local record = GGM.GetCompleteCharacterRecord(db, identity.key)
    T.assertNotNil(record)
    T.assertTrue(record.complete)
    T.assertEqual(record.identity.key, "Alice-Silvermoon")
    T.assertEqual(record.gear.capturedAt, 1700000000)
end)

T.test("saving a snapshot stores a defensive copy", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = makeIdentity()
    local snapshot = makeSnapshot(GGM)

    assert(GGM.SaveCompleteCharacterRecord(db, identity, snapshot))
    snapshot.capturedAt = 1800000000
    snapshot.slots.HEAD.itemID = 9999

    local record = assert(GGM.GetCompleteCharacterRecord(db, identity.key))

    T.assertEqual(record.gear.capturedAt, 1700000000)
    T.assertEqual(record.gear.slots.HEAD.itemID, 2001)
end)

T.test("an incomplete snapshot is never saved over a complete record", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = makeIdentity()
    local original = makeSnapshot(GGM)
    assert(GGM.SaveCompleteCharacterRecord(db, identity, original))

    local broken = makeSnapshot(GGM)
    broken.slots.HEAD = nil

    local ok, err = GGM.SaveCompleteCharacterRecord(db, identity, broken)

    T.assertFalse(ok)
    T.assertEqual(err, "snapshot-slot-missing:HEAD")
    T.assertEqual(db.characters[identity.key].gear.capturedAt, 1700000000)
    T.assertNotNil(db.characters[identity.key].gear.slots.HEAD)
end)

T.test("reading a malformed saved record returns no usable data", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    db.characters["Alice-Silvermoon"] = {
        complete = true,
        identity = makeIdentity(),
        gear = {
            complete = true,
            capturedAt = 1700000000,
            slots = {},
        },
    }

    local record, err = GGM.GetCompleteCharacterRecord(db, "Alice-Silvermoon")

    T.assertNil(record)
    T.assertEqual(err, "snapshot-slot-missing:HEAD")
end)

T.test("confirmed slot update changes only the selected shared slot", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = makeIdentity()
    assert(GGM.SaveCompleteCharacterRecord(db, identity, makeSnapshot(GGM)))

    local changedHead = {
        inventorySlotID = 1,
        itemID = 9999,
        itemLink = "|Hitem:9999|h[Confirmed Head]|h",
    }

    local ok, err = GGM.UpdateConfirmedCharacterSlot(
        db,
        identity.key,
        "HEAD",
        changedHead,
        1700000300
    )

    T.assertTrue(ok)
    T.assertNil(err)

    local record = assert(GGM.GetCompleteCharacterRecord(db, identity.key))
    T.assertEqual(record.gear.slots.HEAD.itemID, 9999)
    T.assertEqual(record.gear.slots.NECK.itemID, 2002)
    T.assertEqual(record.gear.capturedAt, 1700000300)
end)

T.test("confirmed slot update stores a defensive slot copy", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = makeIdentity()
    assert(GGM.SaveCompleteCharacterRecord(db, identity, makeSnapshot(GGM)))

    local changedHead = {
        inventorySlotID = 1,
        itemID = 9999,
        itemLink = "|Hitem:9999|h[Confirmed Head]|h",
    }

    assert(GGM.UpdateConfirmedCharacterSlot(db, identity.key, "HEAD", changedHead, 1700000300))
    changedHead.itemID = 123
    changedHead.itemLink = "mutated"

    local record = assert(GGM.GetCompleteCharacterRecord(db, identity.key))
    T.assertEqual(record.gear.slots.HEAD.itemID, 9999)
    T.assertEqual(record.gear.slots.HEAD.itemLink, "|Hitem:9999|h[Confirmed Head]|h")
end)

T.test("confirmed slot update rejects a mismatched inventory slot id without mutation", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = makeIdentity()
    assert(GGM.SaveCompleteCharacterRecord(db, identity, makeSnapshot(GGM)))

    local wrongSlot = {
        inventorySlotID = 2,
        itemID = 9999,
        itemLink = "|Hitem:9999|h[Wrong Slot]|h",
    }

    local ok, err = GGM.UpdateConfirmedCharacterSlot(
        db,
        identity.key,
        "HEAD",
        wrongSlot,
        1700000300
    )

    T.assertFalse(ok)
    T.assertEqual(err, "snapshot-slot-id-mismatch:HEAD")

    local record = assert(GGM.GetCompleteCharacterRecord(db, identity.key))
    T.assertEqual(record.gear.slots.HEAD.itemID, 2001)
    T.assertEqual(record.gear.capturedAt, 1700000000)
end)

T.test("confirmed slot update rejects an unknown slot without mutation", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = makeIdentity()
    assert(GGM.SaveCompleteCharacterRecord(db, identity, makeSnapshot(GGM)))

    local ok, err = GGM.UpdateConfirmedCharacterSlot(
        db,
        identity.key,
        "NOT_A_SLOT",
        { inventorySlotID = 1, itemID = 9999, itemLink = "|Hitem:9999|h[Test]|h" },
        1700000300
    )

    T.assertFalse(ok)
    T.assertEqual(err, "tracked-slot-unknown:NOT_A_SLOT")
    T.assertEqual(db.characters[identity.key].gear.slots.HEAD.itemID, 2001)
end)

T.test("new complete records persist confirmed sequence zero without a schema bump", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = makeIdentity()

    assert(GGM.SaveCompleteCharacterRecord(db, identity, makeSnapshot(GGM)))

    T.assertEqual(db.schemaVersion, 4)
    T.assertEqual(db.characters[identity.key].confirmedSequence, 0)
    local record = assert(GGM.GetCompleteCharacterRecord(db, identity.key))
    T.assertEqual(GGM.GetConfirmedSequence(record), 0)
end)

T.test("schema two migrates to schema four with empty profession storage", function()
    local GGM = loadModules()
    local existing = {
        schemaVersion = 2,
        characters = {},
        localCharacters = {},
    }

    local db, err = GGM.InitializeDatabase(existing)

    T.assertNil(err)
    T.assertTrue(db == existing)
    T.assertEqual(db.schemaVersion, 4)
    T.assertNotNil(db.professions)
    T.assertNil(next(db.professions))
end)

T.test("new schema four database initializes profession storage", function()
    local GGM = loadModules()
    local db, err = GGM.InitializeDatabase(nil)

    T.assertNil(err)
    T.assertEqual(db.schemaVersion, 4)
    T.assertNotNil(db.professions)
end)

T.test("saving profession data creates a profession-only character entry", function()
    local GGM = loadModules()
    local db = GGM.InitializeDatabase(nil)
    local identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon" }
    local snapshot = {
        professionID = 164,
        professionName = "Blacksmithing",
        skillLevel = 75,
        maxSkillLevel = 100,
        capturedAt = 1700004000,
        source = GGM.PROFESSION_SOURCE_GUILD_LINK,
        status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 100, name = "Copper Bracers" } },
    }

    local saved, err = GGM.SaveProfessionSnapshot(db, identity, snapshot)

    T.assertTrue(saved)
    T.assertNil(err)
    T.assertNil(db.characters[identity.key])
    T.assertNotNil(db.professions[identity.key])
    T.assertEqual(db.professions[identity.key].identity.key, identity.key)
    T.assertEqual(db.professions[identity.key].snapshots[164].recipes[1].recipeID, 100)
    T.assertNil(db.professions[identity.key].snapshots[164].skillLevel)
    T.assertNil(db.professions[identity.key].snapshots[164].maxSkillLevel)
end)

T.test("re-saving the same profession replaces that profession snapshot predictably", function()
    local GGM = loadModules()
    local db = GGM.InitializeDatabase(nil)
    local identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon" }
    local first = {
        professionID = 164, professionName = "Blacksmithing",
        capturedAt = 1700004000, source = GGM.PROFESSION_SOURCE_GUILD_LINK,
        status = GGM.PROFESSION_CACHE_STATUS, recipes = { { recipeID = 100, name = "Copper Bracers" } },
    }
    local second = {
        professionID = 164, professionName = "Blacksmithing",
        capturedAt = 1700005000, source = GGM.PROFESSION_SOURCE_GUILD_LINK,
        status = GGM.PROFESSION_CACHE_STATUS, recipes = { { recipeID = 300, name = "Iron Buckle" } },
    }

    T.assertTrue(GGM.SaveProfessionSnapshot(db, identity, first))
    T.assertTrue(GGM.SaveProfessionSnapshot(db, identity, second))

    local record = GGM.GetProfessionRecord(db, identity.key)
    T.assertEqual(record.snapshots[164].capturedAt, 1700005000)
    T.assertEqual(#record.snapshots[164].recipes, 1)
    T.assertEqual(record.snapshots[164].recipes[1].recipeID, 300)
end)

T.test("saving a second profession preserves the first profession", function()
    local GGM = loadModules()
    local db = GGM.InitializeDatabase(nil)
    local identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon" }

    local function snapshot(id, name)
        return {
            professionID = id, professionName = name,
            capturedAt = 1700004000, source = GGM.PROFESSION_SOURCE_GUILD_LINK,
            status = GGM.PROFESSION_CACHE_STATUS, recipes = {},
        }
    end

    T.assertTrue(GGM.SaveProfessionSnapshot(db, identity, snapshot(164, "Blacksmithing")))
    T.assertTrue(GGM.SaveProfessionSnapshot(db, identity, snapshot(171, "Alchemy")))

    local record = GGM.GetProfessionRecord(db, identity.key)
    T.assertNotNil(record.snapshots[164])
    T.assertNotNil(record.snapshots[171])
end)

T.test("invalid profession snapshot writes nothing", function()
    local GGM = loadModules()
    local db = GGM.InitializeDatabase(nil)
    local identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon" }

    local saved, err = GGM.SaveProfessionSnapshot(db, identity, { professionID = 164 })

    T.assertFalse(saved)
    T.assertNotNil(err)
    T.assertNil(db.professions[identity.key])
end)

T.test("invalid replacement cannot overwrite an existing profession snapshot", function()
    local GGM = loadModules()
    local db = GGM.InitializeDatabase(nil)
    local identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon" }
    local valid = {
        professionID = 171, professionName = "Alchemy",
        capturedAt = 1700006000, source = GGM.PROFESSION_SOURCE_GUILD_LINK,
        status = GGM.PROFESSION_CACHE_STATUS, recipes = {},
    }
    T.assertTrue(GGM.SaveProfessionSnapshot(db, identity, valid))

    local saved = GGM.SaveProfessionSnapshot(db, identity, {
        professionID = 171,
        professionName = "Alchemy",
        recipes = false,
    })

    T.assertFalse(saved)
    T.assertEqual(db.professions[identity.key].snapshots[171].capturedAt, 1700006000)
end)

T.test("malformed profession snapshot records fail closed without raising", function()
    local GGM = loadModules()
    local db = GGM.InitializeDatabase(nil)
    local identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon" }
    db.professions[identity.key] = {
        identity = identity,
        snapshots = { [171] = false },
    }

    local callOk, record, err = pcall(GGM.GetProfessionRecord, db, identity.key)

    T.assertTrue(callOk)
    T.assertNil(record)
    T.assertEqual(err, "profession-snapshot-invalid")
end)

T.test("legacy complete records without confirmed sequence remain valid as sequence zero", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = makeIdentity()
    assert(GGM.SaveCompleteCharacterRecord(db, identity, makeSnapshot(GGM)))
    db.characters[identity.key].confirmedSequence = nil

    local record, err = GGM.GetCompleteCharacterRecord(db, identity.key)

    T.assertNil(err)
    T.assertNotNil(record)
    T.assertEqual(GGM.GetConfirmedSequence(record), 0)
    T.assertNil(db.characters[identity.key].confirmedSequence)
end)

T.test("local confirmed slot updates increment and persist sequence exactly once", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = makeIdentity()
    assert(GGM.SaveCompleteCharacterRecord(db, identity, makeSnapshot(GGM)))

    local first = { inventorySlotID = 1, itemID = 9001, itemLink = "|Hitem:9001|h[First]|h" }
    local ok1, err1, sequence1 = GGM.UpdateConfirmedCharacterSlot(db, identity.key, "HEAD", first, 1700000300)
    T.assertTrue(ok1)
    T.assertNil(err1)
    T.assertEqual(sequence1, 1)

    local second = { inventorySlotID = 1, itemID = 9002, itemLink = "|Hitem:9002|h[Second]|h" }
    local ok2, err2, sequence2 = GGM.UpdateConfirmedCharacterSlot(db, identity.key, "HEAD", second, 1700000600)
    T.assertTrue(ok2)
    T.assertNil(err2)
    T.assertEqual(sequence2, 2)

    local record = assert(GGM.GetCompleteCharacterRecord(db, identity.key))
    T.assertEqual(record.confirmedSequence, 2)
end)

T.test("failed local confirmed slot update does not increment sequence", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = makeIdentity()
    assert(GGM.SaveCompleteCharacterRecord(db, identity, makeSnapshot(GGM)))

    local ok, err = GGM.UpdateConfirmedCharacterSlot(
        db,
        identity.key,
        "HEAD",
        { inventorySlotID = 2, itemID = 9001, itemLink = "|Hitem:9001|h[Wrong]|h" },
        1700000300
    )

    T.assertFalse(ok)
    T.assertEqual(err, "snapshot-slot-id-mismatch:HEAD")
    T.assertEqual(db.characters[identity.key].confirmedSequence, 0)
end)

T.test("received slot update requires a complete baseline and stores the transmitted sequence", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = makeIdentity()
    identity.raceID, identity.sex, identity.displayID = 1, 3, 12345
    local changedHead = { inventorySlotID = 1, itemID = 9100, itemLink = "|Hitem:9100|h[Remote]|h" }

    local missingOk, missingErr = GGM.ApplyReceivedCharacterSlot(
        db, identity.key, "HEAD", changedHead, 1700000400, 1
    )
    T.assertFalse(missingOk)
    T.assertEqual(missingErr, "record-missing")

    assert(GGM.SaveCompleteCharacterRecord(db, identity, makeSnapshot(GGM)))
    local ok, err = GGM.ApplyReceivedCharacterSlot(
        db, identity.key, "HEAD", changedHead, 1700000400, 1
    )

    T.assertTrue(ok)
    T.assertNil(err)
    local record = assert(GGM.GetCompleteCharacterRecord(db, identity.key))
    T.assertEqual(record.gear.slots.HEAD.itemID, 9100)
    T.assertEqual(record.gear.capturedAt, 1700000400)
    T.assertEqual(record.confirmedSequence, 1)
    T.assertEqual(record.identity.raceID, 1)
    T.assertEqual(record.identity.sex, 3)
    T.assertEqual(record.identity.displayID, 12345)
end)

T.test("received slot update rejects a sequence regression without mutation", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = makeIdentity()
    assert(GGM.SaveCompleteCharacterRecord(db, identity, makeSnapshot(GGM), 8))

    local ok, err = GGM.ApplyReceivedCharacterSlot(
        db,
        identity.key,
        "HEAD",
        { inventorySlotID = 1, itemID = 9300, itemLink = "|Hitem:9300|h[Older Update]|h" },
        1700000800,
        7
    )

    T.assertFalse(ok)
    T.assertEqual(err, "confirmed-sequence-regression")
    local record = assert(GGM.GetCompleteCharacterRecord(db, identity.key))
    T.assertEqual(record.gear.slots.HEAD.itemID, 2001)
    T.assertEqual(record.confirmedSequence, 8)
    T.assertEqual(record.gear.capturedAt, 1700000000)
end)

T.test("sequence gaps preserve values but require a full baseline before becoming complete", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = makeIdentity()
    local originalSnapshot = makeSnapshot(GGM)
    assert(GGM.SaveCompleteCharacterRecord(db, identity, originalSnapshot, 4))

    local ok, err = GGM.ApplyReceivedCharacterSlot(
        db,
        identity.key,
        "HEAD",
        { inventorySlotID = 1, itemID = 9400, itemLink = "|Hitem:9400|h[Skipped Update]|h" },
        1700000900,
        6
    )

    T.assertFalse(ok)
    T.assertEqual(err, "confirmed-sequence-gap")
    local record = assert(GGM.GetCharacterRecord(db, identity.key))
    T.assertFalse(record.complete)
    T.assertEqual(record.completeness, "incomplete")
    T.assertTrue(record.refreshNeeded)
    T.assertEqual(record.incompleteReason, "sequence-gap")
    T.assertEqual(record.requiredBaselineSequence, 6)
    T.assertFalse(record.gear.complete)
    T.assertEqual(record.gear.slots.HEAD.itemID, 2001)
    T.assertEqual(record.confirmedSequence, 4)
    T.assertEqual(record.gear.capturedAt, 1700000000)

    local advanced, advancedErr = GGM.ApplyReceivedCharacterSlot(
        db,
        identity.key,
        "HEAD",
        { inventorySlotID = 1, itemID = 9408, itemLink = "|Hitem:9408|h[Later Update]|h" },
        1700000902,
        8
    )
    T.assertFalse(advanced)
    T.assertEqual(advancedErr, "confirmed-sequence-gap-advanced")
    local stillStale = assert(GGM.GetCharacterRecord(db, identity.key))
    T.assertEqual(stillStale.requiredBaselineSequence, 8)
    T.assertEqual(stillStale.confirmedSequence, 4)
    for _, trackedSlot in ipairs(GGM.TRACKED_SLOTS) do
        T.assertTrue(GGM.AreGearSlotValuesEqual(stillStale.gear.slots[trackedSlot.key], originalSnapshot.slots[trackedSlot.key]))
    end

    local baseline = makeSnapshot(GGM)
    baseline.capturedAt = 1700001000
    for _, belowRequiredSequence in ipairs({ 6, 7 }) do
        baseline.slots.HEAD.itemID = 3000 + belowRequiredSequence
        baseline.slots.HEAD.itemLink = "|Hitem:" .. (3000 + belowRequiredSequence) .. "|h[Too Old]|h"
        local repairedEarly, earlyErr = GGM.SaveReceivedCompleteCharacterRecord(db, identity, baseline, belowRequiredSequence)
        T.assertFalse(repairedEarly)
        T.assertEqual(earlyErr, "confirmed-sequence-before-required-baseline")
        local stillStale = assert(GGM.GetCharacterRecord(db, identity.key))
        T.assertTrue(stillStale.refreshNeeded)
        T.assertEqual(stillStale.requiredBaselineSequence, 8)
        T.assertEqual(stillStale.confirmedSequence, 4)
        T.assertEqual(stillStale.gear.slots.HEAD.itemID, 2001)
    end
    baseline.slots.HEAD.itemID = 3008
    baseline.slots.HEAD.itemLink = "|Hitem:3008|h[Repair At Required Sequence]|h"
    T.assertTrue(GGM.SaveReceivedCompleteCharacterRecord(db, identity, baseline, 8))
    local repaired = assert(GGM.GetCompleteCharacterRecord(db, identity.key))
    T.assertTrue(repaired.complete)
    T.assertTrue(repaired.gear.complete)
    T.assertNil(repaired.refreshNeeded)
    T.assertNil(repaired.incompleteReason)
    T.assertNil(repaired.requiredBaselineSequence)
end)

T.test("received slot update rejects a mismatched inventory slot id without mutation", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = makeIdentity()
    assert(GGM.SaveCompleteCharacterRecord(db, identity, makeSnapshot(GGM)))

    local ok, err = GGM.ApplyReceivedCharacterSlot(
        db,
        identity.key,
        "HEAD",
        { inventorySlotID = 2, itemID = 9200, itemLink = "|Hitem:9200|h[Wrong Slot]|h" },
        1700000500,
        8
    )

    T.assertFalse(ok)
    T.assertEqual(err, "snapshot-slot-id-mismatch:HEAD")
    local record = assert(GGM.GetCompleteCharacterRecord(db, identity.key))
    T.assertEqual(record.gear.slots.HEAD.itemID, 2001)
    T.assertEqual(record.confirmedSequence, 0)
end)

T.test("received complete snapshot cannot move confirmed sequence backwards", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = makeIdentity()
    local original = makeSnapshot(GGM)
    assert(GGM.SaveCompleteCharacterRecord(db, identity, original, 8))

    local older = makeSnapshot(GGM)
    older.capturedAt = 1700000500
    older.slots.HEAD.itemID = 9999
    older.slots.HEAD.itemLink = "|Hitem:9999|h[Older Response]|h"

    local ok, err = GGM.SaveReceivedCompleteCharacterRecord(db, identity, older, 7)

    T.assertFalse(ok)
    T.assertEqual(err, "confirmed-sequence-regression")
    local record = assert(GGM.GetCompleteCharacterRecord(db, identity.key))
    T.assertEqual(record.confirmedSequence, 8)
    T.assertEqual(record.gear.slots.HEAD.itemID, 2001)
end)

T.test("received complete snapshot may replace at equal or higher sequence", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = makeIdentity()
    assert(GGM.SaveCompleteCharacterRecord(db, identity, makeSnapshot(GGM), 3))

    local replacement = makeSnapshot(GGM)
    replacement.capturedAt = 1700000700
    replacement.slots.HEAD.itemID = 9999
    replacement.slots.HEAD.itemLink = "|Hitem:9999|h[Replacement]|h"

    local ok, err = GGM.SaveReceivedCompleteCharacterRecord(db, identity, replacement, 4)

    T.assertTrue(ok)
    T.assertNil(err)
    local record = assert(GGM.GetCompleteCharacterRecord(db, identity.key))
    T.assertEqual(record.confirmedSequence, 4)
    T.assertEqual(record.gear.slots.HEAD.itemID, 9999)
end)

T.test("newer received baselines replace or clear saved target model identity", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = makeIdentity()
    identity.raceID, identity.sex, identity.displayID = 1, 2, 1111
    assert(GGM.SaveCompleteCharacterRecord(db, identity, makeSnapshot(GGM), 3))

    local replacementIdentity = makeIdentity()
    replacementIdentity.raceID, replacementIdentity.sex, replacementIdentity.displayID = 2, 3, 2222
    local replacement = makeSnapshot(GGM)
    replacement.capturedAt = 1700000700
    T.assertTrue(GGM.SaveReceivedCompleteCharacterRecord(db, replacementIdentity, replacement, 4))
    local updated = assert(GGM.GetCompleteCharacterRecord(db, identity.key))
    T.assertEqual(updated.identity.raceID, 2)
    T.assertEqual(updated.identity.sex, 3)
    T.assertEqual(updated.identity.displayID, 2222)

    local noModelIdentity = makeIdentity()
    replacement.capturedAt = 1700000800
    T.assertTrue(GGM.SaveReceivedCompleteCharacterRecord(db, noModelIdentity, replacement, 5))
    local cleared = assert(GGM.GetCompleteCharacterRecord(db, identity.key))
    T.assertNil(cleared.identity.raceID)
    T.assertNil(cleared.identity.sex)
    T.assertNil(cleared.identity.displayID)
end)

T.test("received complete snapshot rejects invalid identity before touching the database", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local snapshot = makeSnapshot(GGM)

    local callOk, saved, err = pcall(
        GGM.SaveReceivedCompleteCharacterRecord,
        db,
        nil,
        snapshot,
        0
    )

    T.assertTrue(callOk)
    T.assertFalse(saved)
    T.assertEqual(err, "identity-invalid")
    T.assertNil(next(db.characters))
end)

T.test("schema one migration preserves known slots and leaves new slots unknown", function()
    local GGM = loadModules()
    local identity = makeIdentity()
    local slots = {}
    for index, slot in ipairs(GGM.TRACKED_SLOTS) do
        if slot.key ~= "SHIRT" and slot.key ~= "TABARD" and slot.key ~= "RANGED" then
            slots[slot.key] = { inventorySlotID = index, itemID = 2000 + index, itemLink = "|Hitem:" .. tostring(2000 + index) .. "|h[Test]|h" }
        end
    end
    local existing = { schemaVersion = 1, characters = { [identity.key] = {
        complete = true, identity = identity, confirmedSequence = 7,
        gear = { complete = true, capturedAt = 1700000123, slots = slots },
    } } }
    local db, err = GGM.InitializeDatabase(existing)
    T.assertNil(err)
    T.assertEqual(db.schemaVersion, 4)
    local record = assert(GGM.GetCharacterRecord(db, identity.key))
    T.assertFalse(record.complete)
    T.assertEqual(record.completeness, "incomplete")
    T.assertFalse(record.gear.complete)
    T.assertEqual(record.gear.capturedAt, 1700000123)
    T.assertEqual(record.confirmedSequence, 7)
    T.assertEqual(record.gear.slots.HEAD.itemID, 2001)
    T.assertNil(record.gear.slots.SHIRT)
    T.assertNil(record.gear.slots.TABARD)
    T.assertNil(record.gear.slots.RANGED)
    T.assertNil(GGM.GetCompleteCharacterRecord(db, identity.key))
end)

T.test("incomplete records require all 16 legacy slots and allow only new slots to be unknown", function()
    local GGM = loadModules()
    local identity = makeIdentity()
    local slots = {}
    for index, slot in ipairs(GGM.TRACKED_SLOTS) do
        if slot.key ~= "SHIRT" and slot.key ~= "TABARD" and slot.key ~= "RANGED" then
            slots[slot.key] = { inventorySlotID = index, itemID = 3000 + index, itemLink = "|Hitem:" .. tostring(3000 + index) .. "|h[Legacy]|h" }
        end
    end
    local db = { schemaVersion = GGM.SCHEMA_VERSION, characters = {
        [identity.key] = { complete = false, completeness = "incomplete", identity = identity, gear = { complete = false, capturedAt = 1700000123, slots = slots } },
    } }
    local record, err = GGM.GetCharacterRecord(db, identity.key)
    T.assertNil(err)
    T.assertNotNil(record)
    T.assertNil(record.gear.slots.SHIRT)
    T.assertNil(record.gear.slots.TABARD)
    T.assertNil(record.gear.slots.RANGED)

    local legacySlots = record.gear.slots
    record.gear.slots = {}
    local emptySubset, emptySubsetErr = GGM.GetCharacterRecord(db, identity.key)
    T.assertNil(emptySubset)
    T.assertEqual(emptySubsetErr, "snapshot-slot-missing:HEAD")
    record.gear.slots = legacySlots

    record.gear.slots.HEAD = nil
    local missing, missingErr = GGM.GetCharacterRecord(db, identity.key)
    T.assertNil(missing)
    T.assertEqual(missingErr, "snapshot-slot-missing:HEAD")

    record.gear.slots.HEAD = { inventorySlotID = 1, itemID = 3001, itemLink = "|Hitem:3001|h[Legacy]|h" }
    record.gear.slots.NECK.itemID, record.gear.slots.NECK.itemLink = 3002, false
    local invalid, invalidErr = GGM.GetCharacterRecord(db, identity.key)
    T.assertNil(invalid)
    T.assertEqual(invalidErr, "snapshot-slot-value-invalid:NECK")
    record.gear.slots.NECK.itemID, record.gear.slots.NECK.itemLink = 3002, "|Hitem:3002|h[Legacy]|h"
    record.gear.slots.UNTRACKED = { inventorySlotID = 99, itemID = 3000, itemLink = "|Hitem:3000|h[Unknown]|h" }
    local unknown, unknownErr = GGM.GetCharacterRecord(db, identity.key)
    T.assertNil(unknown)
    T.assertEqual(unknownErr, "tracked-slot-unknown:UNTRACKED")
end)
