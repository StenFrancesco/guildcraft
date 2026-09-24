local T = require("tests.testlib")

local function loadModules()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/Constants.lua", GGM)
    T.loadAddonFile("GuildGearMemory/GearSnapshot.lua", GGM)
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

T.test("database initialization creates the Phase 1 schema on first run", function()
    local GGM = loadModules()

    local db, err = GGM.InitializeDatabase(nil)

    T.assertNil(err)
    T.assertEqual(db.schemaVersion, 1)
    T.assertEqual(type(db.characters), "table")
end)

T.test("database initialization reuses a valid existing SavedVariables table", function()
    local GGM = loadModules()
    local existing = {
        schemaVersion = 1,
        characters = {},
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

    T.assertEqual(db.schemaVersion, 1)
    T.assertEqual(db.characters[identity.key].confirmedSequence, 0)
    local record = assert(GGM.GetCompleteCharacterRecord(db, identity.key))
    T.assertEqual(GGM.GetConfirmedSequence(record), 0)
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

T.test("received slot update rejects a non-contiguous forward sequence without mutation", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local identity = makeIdentity()
    assert(GGM.SaveCompleteCharacterRecord(db, identity, makeSnapshot(GGM), 4))

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
    local record = assert(GGM.GetCompleteCharacterRecord(db, identity.key))
    T.assertEqual(record.gear.slots.HEAD.itemID, 2001)
    T.assertEqual(record.confirmedSequence, 4)
    T.assertEqual(record.gear.capturedAt, 1700000000)
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
