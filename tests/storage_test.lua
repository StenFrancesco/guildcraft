local T = require("tests.testlib")

local function loadModules()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/Constants.lua", GGM)
    T.loadAddonFile("GuildGearMemory/GearData.lua", GGM)
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
            inventorySlotID = slot.inventorySlotID,
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

T.test("database initialization creates schema six on first run", function()
    local GGM = loadModules()

    local db, err = GGM.InitializeDatabase(nil)

    T.assertNil(err)
    T.assertEqual(db.schemaVersion, 6)
    T.assertEqual(type(db.characters), "table")
    T.assertEqual(type(db.localCharacters), "table")
    T.assertNil(next(db.localCharacters))
    T.assertEqual(type(db.professions), "table")
    T.assertEqual(db.professionRecipeIndexVersion, 3)
end)

T.test("schema four is rejected without mutating the old database", function()
    local GGM = loadModules()
    local existing = {
        schemaVersion = 4,
        characters = {},
        localCharacters = {},
        professions = {
            ["Alice-Silvermoon"] = {
                identity = {
                    key = "Alice-Silvermoon",
                    name = "Alice",
                    realm = "Silvermoon",
                    guid = "Player-1-A",
                },
                snapshots = {
                    [164] = {
                        professionID = 164,
                        professionName = "Blacksmithing",
                        capturedAt = 1,
                        source = GGM.PROFESSION_SOURCE_PLAYER,
                        status = GGM.PROFESSION_CACHE_STATUS,
                        recipes = { { recipeID = 100, name = "Copper Bracers" } },
                    },
                },
            },
        },
    }
    local oldRecipes = existing.professions["Alice-Silvermoon"].snapshots[164].recipes

    local db, err = GGM.InitializeDatabase(existing)

    T.assertNil(db)
    T.assertEqual(err, "unsupported-schema-version:4")
    T.assertEqual(existing.schemaVersion, 4)
    T.assertTrue(existing.professions["Alice-Silvermoon"].snapshots[164].recipes == oldRecipes)
end)

T.test("schema five is rejected without mutating the old database", function()
    local GGM = loadModules()
    local existing = assert(GGM.InitializeDatabase(nil))
    existing.schemaVersion = 5
    existing.marker = { keep = true }
    local oldMarker = existing.marker

    local db, err = GGM.InitializeDatabase(existing)

    T.assertNil(db)
    T.assertEqual(err, "unsupported-schema-version:5")
    T.assertEqual(existing.schemaVersion, 5)
    T.assertTrue(existing.marker == oldMarker)
end)

T.test("schema one through four are rejected without automatic migration", function()
    local GGM = loadModules()
    for _, schemaVersion in ipairs({ 1, 2, 3, 4 }) do
        local existing = { schemaVersion = schemaVersion, marker = { keep = true } }
        local oldMarker = existing.marker

        local db, err = GGM.InitializeDatabase(existing)

        T.assertNil(db)
        T.assertEqual(err, "unsupported-schema-version:" .. tostring(schemaVersion))
        T.assertEqual(existing.schemaVersion, schemaVersion)
        T.assertTrue(existing.marker == oldMarker)
    end
end)

T.test("schema five rejects version two profession crafter sets without mutation", function()
    local GGM = loadModules()
    local identity = {
        key = "Alice-Silvermoon",
        name = "Alice",
        realm = "Silvermoon",
        guid = "Player-1-A",
    }
    local oldIndex = {
        [164] = {
            [100] = {
                name = "Copper Bracers",
                crafters = { [1] = true },
            },
        },
    }
    local existing = {
        schemaVersion = GGM.SCHEMA_VERSION,
        characters = {},
        localCharacters = {},
        professions = {
            [identity.key] = {
                identity = identity,
                snapshots = {},
            },
        },
        nextLocalCharacterID = 2,
        professionCharacters = {
            [1] = {
                guid = identity.guid,
                key = identity.key,
                active = false,
            },
        },
        localCharacterIDByGUID = {
            [identity.guid] = 1,
        },
        professionRecipeIndex = oldIndex,
        professionRecipeIndexVersion = 2,
        professionIndexRepairCandidates = {},
        professionIndexRepairNeeded = false,
    }

    local db, err = GGM.InitializeDatabase(existing)

    T.assertNil(db)
    T.assertEqual(err, "profession-index-invalid")
    T.assertTrue(existing.professionRecipeIndex == oldIndex)
    T.assertEqual(existing.professionRecipeIndexVersion, 2)
    T.assertEqual(existing.professionRecipeIndex[164][100].crafters[1], true)
end)

T.test("schema five initialization rejects missing required tables without synthesizing them", function()
    local GGM = loadModules()
    local existing = {
        schemaVersion = GGM.SCHEMA_VERSION,
        characters = {},
        localCharacters = {},
        professions = {},
    }

    local db, err = GGM.InitializeDatabase(existing)

    T.assertNil(db)
    T.assertEqual(err, "profession-index-invalid")
    T.assertNil(existing.professionRecipeIndex)
end)

T.test("schema five catalog corruption fails closed without clearing authoritative data", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A" }
    local capture = {
        complete = true,
        professionID = 164,
        professionName = "Blacksmithing",
        capturedAt = 1,
        source = GGM.PROFESSION_SOURCE_PLAYER,
        status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 100, name = "Copper Bracers" } },
    }
    assert(GGM.SaveProfessionSnapshot(db, identity, capture))
    local catalog = db.professionRecipeIndex
    local entry = catalog[164][100]
    entry.crafters = false

    local initialized, err = GGM.InitializeDatabase(db)

    T.assertNil(initialized)
    T.assertEqual(err, "profession-index-invalid")
    T.assertTrue(db.professionRecipeIndex == catalog)
    T.assertTrue(db.professionRecipeIndex[164][100] == entry)
    T.assertFalse(entry.crafters == nil)
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
    T.assertEqual(oldRecord.gear.slots[1], "item:2001")
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
    T.assertEqual(record.gear.slots[1], "item:2001")
    T.assertEqual(record.confirmedSequence, 9)

    identity.raceID, identity.sex = -1, 4
    assert(GGM.SaveCompleteCharacterRecord(db, identity, snapshot, 10))
    record = assert(GGM.GetCompleteCharacterRecord(db, identity.key))
    T.assertNil(record.identity.raceID)
    T.assertNil(record.identity.sex)
    T.assertNil(record.identity.displayID)
    T.assertEqual(record.gear.slots[1], "item:2001")

    local receivedDB = assert(GGM.InitializeDatabase(nil))
    identity.raceID, identity.sex, identity.displayID = 1, nil, 12345
    assert(GGM.SaveReceivedCompleteCharacterRecord(receivedDB, identity, snapshot, 11))
    local received = assert(GGM.GetCompleteCharacterRecord(receivedDB, identity.key))
    T.assertNil(received.identity.raceID)
    T.assertNil(received.identity.sex)
    T.assertNil(received.identity.displayID)
    T.assertEqual(received.gear.slots[1], "item:2001")
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
    T.assertEqual(record.gear.slots[1], "item:2001")
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
    local existing = assert(GGM.InitializeDatabase(nil))

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
    T.assertEqual(record.gear.slots[1], "item:2001")
    T.assertNil(record.gear.slots.HEAD)
end)

T.test("saving a complete snapshot persists only compact numeric gear slots", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local snapshot = makeSnapshot(GGM)
    snapshot.slots.OFF_HAND = { inventorySlotID = 17, itemID = false, itemLink = false }
    snapshot.slots.RANGED = { unavailable = true }

    assert(GGM.SaveCompleteCharacterRecord(db, makeIdentity(), snapshot, 4))

    local record = assert(GGM.GetCompleteCharacterRecord(db, "Alice-Silvermoon"))
    T.assertEqual(record.gear.slots[1], "item:2001")
    T.assertNil(record.gear.slots[17])
    T.assertTrue(record.gear.unavailableSlots[18])
    T.assertNil(record.gear.slots.HEAD)
    T.assertEqual(record.confirmedSequence, 4)
end)

T.test("schema six saves the exact compact numeric gear shape", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local snapshot = makeSnapshot(GGM)
    local headItemString = "item:153787::::::::19:105::105:1:13572:2:9:19:28:2852:::::"
    local mainHandItemString = "item:153792::::::::19:105::105:1:13572:2:9:19:28:2852:::::"

    snapshot.capturedAt = 1790846723
    for _, trackedSlot in ipairs(GGM.TRACKED_SLOTS) do
        snapshot.slots[trackedSlot.key] = {
            inventorySlotID = trackedSlot.inventorySlotID,
            itemID = false,
            itemLink = false,
        }
    end
    snapshot.slots.HEAD = {
        inventorySlotID = 1,
        itemID = 153787,
        itemLink = "|H" .. headItemString .. "|h[Head]|h",
    }
    snapshot.slots.MAIN_HAND = {
        inventorySlotID = 16,
        itemID = 153792,
        itemLink = "|H" .. mainHandItemString .. "|h[Main hand]|h",
    }
    snapshot.slots.RANGED = { unavailable = true }

    assert(GGM.SaveCompleteCharacterRecord(db, makeIdentity(), snapshot))

    local record = assert(GGM.GetCompleteCharacterRecord(db, "Alice-Silvermoon"))
    local gear = record.gear
    T.assertEqual(db.schemaVersion, 6)
    T.assertEqual(gear.complete, true)
    T.assertEqual(gear.capturedAt, 1790846723)
    T.assertEqual(gear.slots[1], headItemString)
    T.assertEqual(gear.slots[16], mainHandItemString)
    T.assertEqual(gear.unavailableSlots[18], true)
    T.assertEqual(type(gear.slots), "table")
    T.assertEqual(type(gear.unavailableSlots), "table")
    T.assertNil(gear.slots.HEAD)
    T.assertNil(gear.slots[18])
    T.assertNil(gear.unavailableSlots[1])
    T.assertNil(gear.unavailableSlots[16])
    local slotCount, unavailableCount = 0, 0
    for slotID in pairs(gear.slots) do
        slotCount = slotCount + 1
        T.assertTrue(slotID == 1 or slotID == 16)
    end
    for slotID in pairs(gear.unavailableSlots) do
        unavailableCount = unavailableCount + 1
        T.assertEqual(slotID, 18)
    end
    T.assertEqual(slotCount, 2)
    T.assertEqual(unavailableCount, 1)
end)

T.test("malformed compact gear cannot replace a previously saved character record", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = makeIdentity()
    assert(GGM.SaveCompleteCharacterRecord(db, identity, makeSnapshot(GGM), 4))
    local previousRecord = db.characters[identity.key]
    local malformed = makeSnapshot(GGM)
    malformed.slots.HEAD.itemLink = "|Hitem:2001:" .. string.rep("1:", GGM.GEAR_MAX_ITEM_STRING_BYTES) .. "1|h[Oversized]|h"

    local saved, err = GGM.SaveCompleteCharacterRecord(db, identity, malformed, 5)

    T.assertFalse(saved)
    T.assertNotNil(err)
    T.assertTrue(db.characters[identity.key] == previousRecord)
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
    T.assertEqual(record.gear.slots[1], "item:2001")
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
    T.assertEqual(db.characters[identity.key].gear.slots[1], "item:2001")
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
            slots = { [1] = "invalid" },
            unavailableSlots = {},
        },
    }

    local record, err = GGM.GetCompleteCharacterRecord(db, "Alice-Silvermoon")

    T.assertNil(record)
    T.assertEqual(err, "item-string-invalid:HEAD")
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
    T.assertEqual(record.gear.slots[1], "item:9999")
    T.assertEqual(record.gear.slots[2], "item:2002")
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
    T.assertEqual(record.gear.slots[1], "item:9999")
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
    T.assertEqual(record.gear.slots[1], "item:2001")
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
    T.assertEqual(db.characters[identity.key].gear.slots[1], "item:2001")
end)

T.test("new complete records persist confirmed sequence zero", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = makeIdentity()

    assert(GGM.SaveCompleteCharacterRecord(db, identity, makeSnapshot(GGM)))

    T.assertEqual(db.schemaVersion, 6)
    T.assertEqual(db.characters[identity.key].confirmedSequence, 0)
    local record = assert(GGM.GetCompleteCharacterRecord(db, identity.key))
    T.assertEqual(GGM.GetConfirmedSequence(record), 0)
end)

T.test("new schema six database initializes profession storage", function()
    local GGM = loadModules()
    local db, err = GGM.InitializeDatabase(nil)

    T.assertNil(err)
    T.assertEqual(db.schemaVersion, 6)
    T.assertNotNil(db.professions)
end)

T.test("saving a profession capture stores metadata only and catalogs recipes", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = {
        key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A",
    }
    local capture = {
        complete = true,
        professionID = 164,
        professionName = "Blacksmithing",
        capturedAt = 1700004000,
        source = GGM.PROFESSION_SOURCE_PLAYER,
        status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 100, name = "Copper Bracers" } },
    }

    assert(GGM.SaveProfessionSnapshot(db, identity, capture))

    local saved = db.professions[identity.key].snapshots[164]
    T.assertTrue(saved.complete)
    T.assertNil(saved.recipes)
    T.assertEqual(saved.professionID, 164)
    T.assertEqual(saved.professionName, "Blacksmithing")
    T.assertEqual(saved.capturedAt, 1700004000)
    T.assertEqual(saved.source, GGM.PROFESSION_SOURCE_PLAYER)
    T.assertEqual(saved.status, GGM.PROFESSION_CACHE_STATUS)

    local localID = db.localCharacterIDByGUID[identity.guid]
    local recipe = db.professionRecipeIndex[164][100]
    T.assertEqual(recipe.name, "Copper Bracers")
    T.assertEqual(#recipe.crafters, 1)
    T.assertEqual(recipe.crafters[1], localID)
end)

T.test("invalid profession refresh preserves membership and last complete metadata", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = {
        key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A",
    }
    local complete = {
        complete = true,
        professionID = 164,
        professionName = "Blacksmithing",
        capturedAt = 10,
        source = GGM.PROFESSION_SOURCE_PLAYER,
        status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 100, name = "Copper Bracers" } },
    }
    assert(GGM.SaveProfessionSnapshot(db, identity, complete))
    local localID = db.localCharacterIDByGUID[identity.guid]

    local incomplete = {
        complete = false,
        professionID = 164,
        professionName = "Blacksmithing",
        capturedAt = 20,
        source = GGM.PROFESSION_SOURCE_PLAYER,
        status = GGM.PROFESSION_CACHE_STATUS,
        recipes = {},
    }

    local saved, err = GGM.SaveProfessionSnapshot(db, identity, incomplete)

    T.assertFalse(saved)
    T.assertEqual(err, "profession-snapshot-incomplete")
    T.assertEqual(db.professions[identity.key].snapshots[164].capturedAt, 10)
    local recipe = db.professionRecipeIndex[164][100]
    T.assertEqual(#recipe.crafters, 1)
    T.assertEqual(recipe.crafters[1], localID)
end)

T.test("saving profession data creates a profession-only character entry", function()
    local GGM = loadModules()
    local db = GGM.InitializeDatabase(nil)
    local identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A" }
    local snapshot = {
        complete = true,
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
    T.assertTrue(db.professions[identity.key].snapshots[164].complete)
    T.assertNil(db.professions[identity.key].snapshots[164].recipes)
    T.assertEqual(db.professionRecipeIndex[164][100].name, "Copper Bracers")
    T.assertNil(db.professions[identity.key].snapshots[164].skillLevel)
    T.assertNil(db.professions[identity.key].snapshots[164].maxSkillLevel)
end)

T.test("re-saving the same profession replaces that profession snapshot predictably", function()
    local GGM = loadModules()
    local db = GGM.InitializeDatabase(nil)
    local identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A" }
    local first = {
        complete = true,
        professionID = 164, professionName = "Blacksmithing",
        capturedAt = 1700004000, source = GGM.PROFESSION_SOURCE_GUILD_LINK,
        status = GGM.PROFESSION_CACHE_STATUS, recipes = { { recipeID = 100, name = "Copper Bracers" } },
    }
    local second = {
        complete = true,
        professionID = 164, professionName = "Blacksmithing",
        capturedAt = 1700005000, source = GGM.PROFESSION_SOURCE_GUILD_LINK,
        status = GGM.PROFESSION_CACHE_STATUS, recipes = { { recipeID = 300, name = "Iron Buckle" } },
    }

    T.assertTrue(GGM.SaveProfessionSnapshot(db, identity, first))
    T.assertTrue(GGM.SaveProfessionSnapshot(db, identity, second))

    local record = GGM.GetProfessionRecord(db, identity.key)
    T.assertEqual(record.snapshots[164].capturedAt, 1700005000)
    T.assertNil(record.snapshots[164].recipes)
    local localID = db.localCharacterIDByGUID[identity.guid]
    T.assertNil(db.professionRecipeIndex[164][100])
    local recipe = db.professionRecipeIndex[164][300]
    T.assertEqual(recipe.name, "Iron Buckle")
    T.assertEqual(#recipe.crafters, 1)
    T.assertEqual(recipe.crafters[1], localID)
end)

T.test("saving a second profession preserves the first profession", function()
    local GGM = loadModules()
    local db = GGM.InitializeDatabase(nil)
    local identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A" }

    local function snapshot(id, name)
        return {
            complete = true,
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
    local identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A" }

    local saved, err = GGM.SaveProfessionSnapshot(db, identity, { professionID = 164 })

    T.assertFalse(saved)
    T.assertNotNil(err)
    T.assertNil(db.professions[identity.key])
end)

T.test("invalid replacement cannot overwrite an existing profession snapshot", function()
    local GGM = loadModules()
    local db = GGM.InitializeDatabase(nil)
    local identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A" }
    local valid = {
        complete = true,
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

T.test("saving a profession snapshot updates only that profession membership", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = {
        key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A",
    }
    local blacksmithing = {
        complete = true,
        professionID = 164, professionName = "Blacksmithing", capturedAt = 1700000000,
        source = GGM.PROFESSION_SOURCE_PLAYER, status = GGM.PROFESSION_CACHE_STATUS,
        recipes = {
            { recipeID = 100, name = "Copper Bracers" },
            { recipeID = 200, name = "Iron Buckle" },
        },
    }
    local alchemy = {
        complete = true,
        professionID = 171, professionName = "Alchemy", capturedAt = 1700000001,
        source = GGM.PROFESSION_SOURCE_PLAYER, status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 300, name = "Potion" } },
    }

    assert(GGM.SaveProfessionSnapshot(db, identity, blacksmithing))
    local localID = db.localCharacterIDByGUID[identity.guid]
    T.assertFalse(db.professionCharacters[localID].active)
    T.assertNotNil(db.professionRecipeIndex[164])
    assert(GGM.SetProfessionCharacterActive(db, localID, true))
    assert(GGM.SaveProfessionSnapshot(db, identity, alchemy))

    local replacement = {
        complete = true,
        professionID = 164, professionName = "Blacksmithing", capturedAt = 1700000010,
        source = GGM.PROFESSION_SOURCE_PLAYER, status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 400, name = "Steel Belt" } },
    }
    assert(GGM.SaveProfessionSnapshot(db, identity, replacement))

    T.assertNil(db.professionRecipeIndex[164][100])
    T.assertNil(db.professionRecipeIndex[164][200])
    local blacksmithingRecipe = db.professionRecipeIndex[164][400]
    T.assertEqual(#blacksmithingRecipe.crafters, 1)
    T.assertEqual(blacksmithingRecipe.crafters[1], localID)
    local alchemyRecipe = db.professionRecipeIndex[171][300]
    T.assertEqual(#alchemyRecipe.crafters, 1)
    T.assertEqual(alchemyRecipe.crafters[1], localID)
end)

T.test("two characters may share one profession recipe bucket", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local snapshot = {
        complete = true,
        professionID = 171, professionName = "Alchemy", capturedAt = 1700000000,
        source = GGM.PROFESSION_SOURCE_GUILD_LINK, status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 300, name = "Potion" } },
    }
    local alice = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A" }
    local bob = { key = "Bob-Silvermoon", name = "Bob", realm = "Silvermoon", guid = "Player-1-B" }
    assert(GGM.SaveProfessionSnapshot(db, alice, snapshot, { guildMembershipVerified = true }))
    assert(GGM.SaveProfessionSnapshot(db, bob, snapshot, { guildMembershipVerified = true }))

    local recipe = db.professionRecipeIndex[171][300]
    local aliceID = db.localCharacterIDByGUID[alice.guid]
    local bobID = db.localCharacterIDByGUID[bob.guid]
    T.assertEqual(recipe.name, "Potion")
    T.assertEqual(#recipe.crafters, 2)
    T.assertEqual(recipe.crafters[1], aliceID)
    T.assertEqual(recipe.crafters[2], bobID)
end)

T.test("two complete snapshots share one catalog recipe and store no duplicate recipe arrays", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local capture = {
        complete = true,
        professionID = 171,
        professionName = "Alchemy",
        capturedAt = 1,
        source = GGM.PROFESSION_SOURCE_PLAYER,
        status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 2330, name = "Minor Healing Potion" } },
    }
    local alice = {
        key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A",
    }
    local bob = {
        key = "Bob-Silvermoon", name = "Bob", realm = "Silvermoon", guid = "Player-1-B",
    }

    assert(GGM.SaveProfessionSnapshot(db, alice, capture))
    capture.capturedAt = 2
    assert(GGM.SaveProfessionSnapshot(db, bob, capture))

    local recipe = db.professionRecipeIndex[171][2330]
    local aliceID = db.localCharacterIDByGUID[alice.guid]
    local bobID = db.localCharacterIDByGUID[bob.guid]

    T.assertEqual(recipe.name, "Minor Healing Potion")
    T.assertEqual(#recipe.crafters, 2)
    T.assertEqual(recipe.crafters[1], aliceID)
    T.assertEqual(recipe.crafters[2], bobID)
    T.assertNil(db.professions[alice.key].snapshots[171].recipes)
    T.assertNil(db.professions[bob.key].snapshots[171].recipes)
end)

T.test("a local-player save cannot reactivate a departed profession character", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = {
        key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A",
    }
    local snapshot = {
        complete = true,
        professionID = 164, professionName = "Blacksmithing", capturedAt = 1,
        source = GGM.PROFESSION_SOURCE_PLAYER, status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 100, name = "Copper Bracers" } },
    }
    assert(GGM.SaveProfessionSnapshot(db, identity, snapshot, { guildMembershipVerified = true }))
    local localID = db.localCharacterIDByGUID[identity.guid]
    assert(GGM.SetProfessionCharacterActive(db, localID, false))
    snapshot.capturedAt = 2
    assert(GGM.SaveProfessionSnapshot(db, identity, snapshot))

    T.assertFalse(db.professionCharacters[localID].active)
    local recipe = db.professionRecipeIndex[164][100]
    T.assertEqual(#recipe.crafters, 1)
    T.assertEqual(recipe.crafters[1], localID)
    T.assertNotNil(db.professions[identity.key].snapshots[164])
end)

T.test("profession save requires a GUID and legacy guidless records stay readable", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local snapshot = {
        complete = true,
        professionID = 164, professionName = "Blacksmithing", capturedAt = 1700000000,
        source = GGM.PROFESSION_SOURCE_GUILD_LINK, status = GGM.PROFESSION_CACHE_STATUS,
        recipes = {},
    }
    local legacyIdentity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon" }
    local saved, err = GGM.SaveProfessionSnapshot(db, legacyIdentity, snapshot)
    T.assertFalse(saved)
    T.assertEqual(err, "profession-identity-guid-invalid")

    db.professions[legacyIdentity.key] = {
        identity = legacyIdentity,
        snapshots = { [164] = {
            complete = true,
            professionID = 164,
            professionName = "Blacksmithing",
            capturedAt = 1700000000,
            source = GGM.PROFESSION_SOURCE_GUILD_LINK,
            status = GGM.PROFESSION_CACHE_STATUS,
        } },
    }
    local record = assert(GGM.GetProfessionRecord(db, legacyIdentity.key))
    T.assertNotNil(record.snapshots[164])
    T.assertNil(db.localCharacterIDByGUID[legacyIdentity.guid])
end)

T.test("verified same-GUID rename moves the canonical profession record and preserves other professions", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local oldIdentity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A" }
    local first = {
        complete = true,
        professionID = 164, professionName = "Blacksmithing", capturedAt = 1,
        source = GGM.PROFESSION_SOURCE_PLAYER, status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 100, name = "Copper Bracers" } },
    }
    local second = {
        complete = true,
        professionID = 171, professionName = "Alchemy", capturedAt = 2,
        source = GGM.PROFESSION_SOURCE_PLAYER, status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 300, name = "Potion" } },
    }
    assert(GGM.SaveProfessionSnapshot(db, oldIdentity, first, { guildMembershipVerified = true }))
    assert(GGM.SaveProfessionSnapshot(db, oldIdentity, second))

    local renamed = { key = "Alicia-Silvermoon", name = "Alicia", realm = "Silvermoon", guid = "Player-1-A" }
    first.capturedAt = 3
    assert(GGM.SaveProfessionSnapshot(db, renamed, first, { guildMembershipVerified = true }))

    T.assertNil(db.professions[oldIdentity.key])
    T.assertNotNil(db.professions[renamed.key].snapshots[164])
    T.assertNotNil(db.professions[renamed.key].snapshots[171])
end)

T.test("verified same-GUID rename merges disjoint profession records", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local oldIdentity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A" }
    local first = {
        complete = true,
        professionID = 164, professionName = "Blacksmithing", capturedAt = 1,
        source = GGM.PROFESSION_SOURCE_PLAYER, status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 100, name = "Copper Bracers" } },
    }
    local second = {
        complete = true,
        professionID = 171, professionName = "Alchemy", capturedAt = 2,
        source = GGM.PROFESSION_SOURCE_PLAYER, status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 300, name = "Potion" } },
    }
    assert(GGM.SaveProfessionSnapshot(db, oldIdentity, first, { guildMembershipVerified = true }))
    local localID = db.localCharacterIDByGUID[oldIdentity.guid]
    assert(GGM.ReconcileProfessionRecipeMembership(db, localID, second))
    db.professions["Alicia-Silvermoon"] = {
        identity = { key = "Alicia-Silvermoon", name = "Alicia", realm = "Silvermoon", guid = oldIdentity.guid },
        snapshots = { [171] = {
            complete = true,
            professionID = 171,
            professionName = "Alchemy",
            capturedAt = 2,
            source = GGM.PROFESSION_SOURCE_PLAYER,
            status = GGM.PROFESSION_CACHE_STATUS,
        } },
    }
    local renamed = { key = "Alicia-Silvermoon", name = "Alicia", realm = "Silvermoon", guid = oldIdentity.guid }
    first.capturedAt = 3
    assert(GGM.SaveProfessionSnapshot(db, renamed, first, { guildMembershipVerified = true }))

    T.assertNil(db.professions[oldIdentity.key])
    T.assertNotNil(db.professions[renamed.key].snapshots[164])
    T.assertNotNil(db.professions[renamed.key].snapshots[171])
    local recipe = db.professionRecipeIndex[171][300]
    local localID = db.localCharacterIDByGUID[oldIdentity.guid]
    T.assertEqual(#recipe.crafters, 1)
    T.assertEqual(recipe.crafters[1], localID)
end)

T.test("same-GUID rename with overlapping profession snapshots fails without mutation", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local oldIdentity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A" }
    local snapshot = {
        complete = true,
        professionID = 164, professionName = "Blacksmithing", capturedAt = 1,
        source = GGM.PROFESSION_SOURCE_PLAYER, status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 100, name = "Copper Bracers" } },
    }
    assert(GGM.SaveProfessionSnapshot(db, oldIdentity, snapshot))
    local renamed = { key = "Alicia-Silvermoon", name = "Alicia", realm = "Silvermoon", guid = oldIdentity.guid }
    db.professions[renamed.key] = { identity = renamed, snapshots = { [164] = {
        complete = true,
        professionID = 164,
        professionName = "Blacksmithing",
        capturedAt = 1,
        source = GGM.PROFESSION_SOURCE_PLAYER,
        status = GGM.PROFESSION_CACHE_STATUS,
    } } }

    local ok, err = GGM.SaveProfessionSnapshot(db, renamed, snapshot)
    T.assertFalse(ok)
    T.assertEqual(err, "profession-rename-profession-conflict")
    T.assertTrue(db.professionIndexRepairNeeded)
    T.assertNotNil(db.professions[oldIdentity.key])
    T.assertNotNil(db.professions[renamed.key])
    T.assertEqual(db.professionCharacters[db.localCharacterIDByGUID[oldIdentity.guid]].key, oldIdentity.key)
    T.assertEqual(db.professions[oldIdentity.key].snapshots[164].capturedAt, 1)
end)

T.test("rename never overwrites a different GUID at the destination key", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local snapshot = {
        complete = true,
        professionID = 164, professionName = "Blacksmithing", capturedAt = 1,
        source = GGM.PROFESSION_SOURCE_PLAYER, status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 100, name = "Copper Bracers" } },
    }
    local alice = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1-A" }
    local bob = { key = "Bob-Silvermoon", name = "Bob", realm = "Silvermoon", guid = "Player-1-B" }
    assert(GGM.SaveProfessionSnapshot(db,
        alice, snapshot, { guildMembershipVerified = true }))
    assert(GGM.SaveProfessionSnapshot(db,
        bob, snapshot, { guildMembershipVerified = true }))
    local aliceID, bobID = db.localCharacterIDByGUID[alice.guid], db.localCharacterIDByGUID[bob.guid]
    local aliceRecord, bobRecord = db.professions[alice.key], db.professions[bob.key]
    local characters, reverseMap = db.professionCharacters, db.localCharacterIDByGUID
    local index = db.professionRecipeIndex
    local indexVersion = db.professionRecipeIndexVersion

    local ok, err = GGM.SaveProfessionSnapshot(db, {
        key = "Bob-Silvermoon", name = "Bob", realm = "Silvermoon", guid = "Player-1-A",
    }, snapshot)

    T.assertFalse(ok)
    T.assertEqual(err, "profession-key-collision")
    T.assertTrue(db.professions[alice.key] == aliceRecord)
    T.assertTrue(db.professions[bob.key] == bobRecord)
    T.assertEqual(db.professions[alice.key].identity.guid, alice.guid)
    T.assertEqual(db.professions[bob.key].identity.guid, bob.guid)
    T.assertTrue(db.professionCharacters == characters)
    T.assertTrue(db.localCharacterIDByGUID == reverseMap)
    T.assertEqual(db.localCharacterIDByGUID[alice.guid], aliceID)
    T.assertEqual(db.localCharacterIDByGUID[bob.guid], bobID)
    T.assertEqual(db.professionCharacters[aliceID].key, alice.key)
    T.assertEqual(db.professionCharacters[bobID].key, bob.key)
    T.assertTrue(db.professionRecipeIndex == index)
    T.assertEqual(db.professionRecipeIndexVersion, indexVersion)
    T.assertTrue(db.professionIndexRepairNeeded)
    GGM.professionRosterMembershipCurrent = true
    local results, queryErr = GGM.GetProfessionRecipeCharacters(db, 164, 100)
    T.assertNil(results)
    T.assertEqual(queryErr, "profession-index-repair-needed")
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
    T.assertEqual(db.characters[identity.key].gear.slots[1], "item:9001")

    local second = { inventorySlotID = 1, itemID = 9002, itemLink = "|Hitem:9002|h[Second]|h" }
    local ok2, err2, sequence2 = GGM.UpdateConfirmedCharacterSlot(db, identity.key, "HEAD", second, 1700000600)
    T.assertTrue(ok2)
    T.assertNil(err2)
    T.assertEqual(sequence2, 2)
    T.assertEqual(db.characters[identity.key].gear.slots[1], "item:9002")

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

T.test("confirmed empty update removes the numeric item entry and increments sequence once", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    assert(GGM.SaveCompleteCharacterRecord(db, makeIdentity(), makeSnapshot(GGM), 4))

    local ok, err, sequence = GGM.UpdateConfirmedCharacterSlot(db, "Alice-Silvermoon", "OFF_HAND", {
        inventorySlotID = 17, itemID = false, itemLink = false,
    }, 1700000100)

    T.assertTrue(ok)
    T.assertNil(err)
    T.assertEqual(sequence, 5)
    local record = assert(GGM.GetCompleteCharacterRecord(db, "Alice-Silvermoon"))
    T.assertNil(record.gear.slots[17])
    T.assertNil(record.gear.unavailableSlots[17])
end)

T.test("confirmed unavailable update replaces compact optional slot state", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    assert(GGM.SaveCompleteCharacterRecord(db, makeIdentity(), makeSnapshot(GGM), 4))

    local ok, err, sequence = GGM.UpdateConfirmedCharacterSlot(db, "Alice-Silvermoon", "RANGED", {
        unavailable = true,
    }, 1700000100)

    T.assertTrue(ok)
    T.assertNil(err)
    T.assertEqual(sequence, 5)
    local record = assert(GGM.GetCompleteCharacterRecord(db, "Alice-Silvermoon"))
    T.assertNil(record.gear.slots[18])
    T.assertTrue(record.gear.unavailableSlots[18])
end)

T.test("invalid confirmed slot update leaves compact maps and metadata untouched", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = makeIdentity()
    assert(GGM.SaveCompleteCharacterRecord(db, identity, makeSnapshot(GGM), 4))
    local gear = db.characters[identity.key].gear
    local slots, unavailableSlots = gear.slots, gear.unavailableSlots

    local ok, err = GGM.UpdateConfirmedCharacterSlot(db, identity.key, "HEAD", {
        inventorySlotID = 1, itemID = 9999, itemLink = "not-an-item-link",
    }, 1700000100)

    T.assertFalse(ok)
    T.assertEqual(err, "item-link-invalid:HEAD")
    T.assertTrue(gear.slots == slots)
    T.assertTrue(gear.unavailableSlots == unavailableSlots)
    T.assertEqual(gear.slots[1], "item:2001")
    T.assertEqual(gear.capturedAt, 1700000000)
    T.assertEqual(db.characters[identity.key].confirmedSequence, 4)
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
    T.assertEqual(record.gear.slots[1], "item:9100")
    T.assertEqual(record.gear.capturedAt, 1700000400)
    T.assertEqual(record.confirmedSequence, 1)
    T.assertEqual(record.identity.raceID, 1)
    T.assertEqual(record.identity.sex, 3)
    T.assertEqual(record.identity.displayID, 12345)
end)

T.test("received empty and unavailable updates persist compact slot states", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = makeIdentity()
    assert(GGM.SaveCompleteCharacterRecord(db, identity, makeSnapshot(GGM), 4))

    local emptyApplied, emptyErr = GGM.ApplyReceivedCharacterSlot(db, identity.key, "OFF_HAND", {
        inventorySlotID = 17, itemID = false, itemLink = false,
    }, 1700000410, 5)
    T.assertTrue(emptyApplied)
    T.assertNil(emptyErr)
    local rangedApplied, rangedErr = GGM.ApplyReceivedCharacterSlot(db, identity.key, "RANGED", {
        unavailable = true,
    }, 1700000420, 6)
    T.assertTrue(rangedApplied)
    T.assertNil(rangedErr)

    local record = assert(GGM.GetCompleteCharacterRecord(db, identity.key))
    T.assertNil(record.gear.slots[17])
    T.assertNil(record.gear.unavailableSlots[17])
    T.assertNil(record.gear.slots[18])
    T.assertTrue(record.gear.unavailableSlots[18])
    T.assertEqual(record.confirmedSequence, 6)
    T.assertEqual(record.gear.capturedAt, 1700000420)
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
    T.assertEqual(record.gear.slots[1], "item:2001")
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
    T.assertEqual(record.gear.slots[1], "item:2001")
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
        T.assertEqual(stillStale.gear.slots[trackedSlot.inventorySlotID], "item:" .. tostring(originalSnapshot.slots[trackedSlot.key].itemID))
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
        T.assertEqual(stillStale.gear.slots[1], "item:2001")
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

T.test("sequence gap keeps the compact baseline stale until a full repair arrives", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = makeIdentity()
    assert(GGM.SaveCompleteCharacterRecord(db, identity, makeSnapshot(GGM), 5))
    local before = db.characters[identity.key].gear.slots[1]

    local applied, err = GGM.ApplyReceivedCharacterSlot(db, identity.key, "HEAD", {
        inventorySlotID = 1, itemID = 9001, itemLink = "|Hitem:9001:7|h[New]|h",
    }, 1700000200, 8)
    T.assertFalse(applied)
    T.assertEqual(err, "confirmed-sequence-gap")
    local stale = assert(GGM.GetCharacterRecord(db, identity.key))
    T.assertFalse(stale.complete)
    T.assertFalse(stale.gear.complete)
    T.assertEqual(stale.gear.slots[1], before)
    T.assertEqual(stale.requiredBaselineSequence, 8)

    local repair = makeSnapshot(GGM)
    repair.capturedAt = 1700000300
    repair.slots.HEAD.itemID = 9100
    repair.slots.HEAD.itemLink = "|Hitem:9100|h[Repair]|h"
    T.assertTrue(GGM.SaveReceivedCompleteCharacterRecord(db, identity, repair, 8))
    local complete = assert(GGM.GetCompleteCharacterRecord(db, identity.key))
    T.assertTrue(complete.complete)
    T.assertTrue(complete.gear.complete)
    T.assertEqual(complete.gear.slots[1], "item:9100")
    T.assertNil(complete.requiredBaselineSequence)
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
    T.assertEqual(record.gear.slots[1], "item:2001")
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
    T.assertEqual(record.gear.slots[1], "item:2001")
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
    T.assertEqual(record.gear.slots[1], "item:9999")
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

T.test("malformed compact records are rejected", function()
    local GGM = loadModules()
    local identity = makeIdentity()
    local db = { schemaVersion = GGM.SCHEMA_VERSION, characters = {
        [identity.key] = { complete = true, identity = identity, confirmedSequence = 0, gear = {
            complete = true, capturedAt = 1700000123, slots = {}, unavailableSlots = {},
        } },
    } }
    for _, malformed in ipairs({
        { function(gear) gear.slots[999] = "item:3000" end, "tracked-slot-id-unknown:999" },
        { function(gear) gear.slots[1] = "item:2001"; gear.unavailableSlots[1] = true end, "snapshot-slot-state-conflict:HEAD" },
        { function(gear) gear.slots[1] = "not-an-item" end, "item-string-invalid:HEAD" },
    }) do
        local gear = { complete = true, capturedAt = 1700000123, slots = {}, unavailableSlots = {} }
        for _, slot in ipairs(GGM.TRACKED_SLOTS) do
            if slot.key ~= "RANGED" then gear.slots[slot.inventorySlotID] = "item:2001" end
        end
        malformed[1](gear)
        db.characters[identity.key].gear = gear
        local record, err = GGM.GetCharacterRecord(db, identity.key)
        T.assertNil(record)
        T.assertEqual(err, malformed[2])
    end
end)
