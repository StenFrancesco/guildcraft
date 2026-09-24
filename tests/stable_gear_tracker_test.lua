local T = require("tests.testlib")

local function loadModules()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/Constants.lua", GGM)
    T.loadAddonFile("GuildGearMemory/GearSnapshot.lua", GGM)
    T.loadAddonFile("GuildGearMemory/Storage.lua", GGM)
    T.loadAddonFile("GuildGearMemory/StableGearTracker.lua", GGM)
    return GGM
end

local function makeIdentity()
    return {
        key = "Alice-Silvermoon",
        name = "Alice",
        realm = "Silvermoon",
        guid = "Player-1234-ABCDEF",
    }
end

local function makeEnvironment(GGM)
    local slotIDs = {}
    local slotKeysByID = {}
    local itemIDs = {}
    local itemLinks = {}
    local timers = {}
    local now = 1700000000

    for index, slot in ipairs(GGM.TRACKED_SLOTS) do
        slotIDs[slot.inventoryName] = index
        slotKeysByID[slot.key] = index
        itemIDs[index] = 4000 + index
        itemLinks[index] = "|Hitem:" .. tostring(4000 + index) .. "|h[Shared " .. slot.key .. "]|h"
    end

    local api = {
        GetInventorySlotInfo = function(inventoryName)
            return slotIDs[inventoryName]
        end,
        GetInventoryItemID = function(_, slotID)
            return itemIDs[slotID]
        end,
        GetInventoryItemLink = function(_, slotID)
            return itemLinks[slotID]
        end,
        GetServerTime = function()
            return now
        end,
        C_Timer = {},
    }

    api.C_Timer.NewTimer = function(delay, callback)
        local timer = {
            delay = delay,
            cancelled = false,
        }

        function timer:Cancel()
            self.cancelled = true
        end

        function timer:Fire()
            if not self.cancelled then
                callback(self)
            end
        end

        table.insert(timers, timer)
        return timer
    end

    local snapshot = {
        complete = true,
        capturedAt = now,
        slots = {},
    }

    for _, slot in ipairs(GGM.TRACKED_SLOTS) do
        local slotID = slotKeysByID[slot.key]
        snapshot.slots[slot.key] = {
            inventorySlotID = slotID,
            itemID = itemIDs[slotID],
            itemLink = itemLinks[slotID],
        }
    end

    local db = assert(GGM.InitializeDatabase(nil))
    assert(GGM.SaveCompleteCharacterRecord(db, makeIdentity(), snapshot))

    local function setSlot(slotKey, itemID, itemLink)
        local slotID = slotKeysByID[slotKey]
        itemIDs[slotID] = itemID
        itemLinks[slotID] = itemLink
    end

    local function setTime(value)
        now = value
    end

    return api, db, timers, slotKeysByID, setSlot, setTime
end

T.test("a changed slot becomes pending without changing shared state", function()
    local GGM = loadModules()
    local api, db, timers, slotIDs, setSlot = makeEnvironment(GGM)
    local tracker = assert(GGM.CreateStableGearTracker(api, db, "Alice-Silvermoon", 300))

    setSlot("HEAD", 9001, "|Hitem:9001|h[Candidate Head]|h")
    local state, err = GGM.HandlePlayerEquipmentChanged(tracker, slotIDs.HEAD)

    T.assertNil(err)
    T.assertEqual(state, "pending")
    T.assertNotNil(tracker.pendingBySlot.HEAD)
    T.assertEqual(#timers, 1)
    T.assertEqual(timers[1].delay, 300)

    local record = assert(GGM.GetCompleteCharacterRecord(db, "Alice-Silvermoon"))
    T.assertEqual(record.gear.slots.HEAD.itemID, 4001)
end)

T.test("a repeated event for the same pending item does not restart its timer", function()
    local GGM = loadModules()
    local api, db, timers, slotIDs, setSlot = makeEnvironment(GGM)
    local tracker = assert(GGM.CreateStableGearTracker(api, db, "Alice-Silvermoon", 300))

    setSlot("HEAD", 9001, "|Hitem:9001|h[Candidate Head]|h")
    assert(GGM.HandlePlayerEquipmentChanged(tracker, slotIDs.HEAD))
    assert(GGM.HandlePlayerEquipmentChanged(tracker, slotIDs.HEAD))

    T.assertEqual(#timers, 1)
    T.assertFalse(timers[1].cancelled)
end)

T.test("reverting to shared gear cancels and removes pending state", function()
    local GGM = loadModules()
    local api, db, timers, slotIDs, setSlot = makeEnvironment(GGM)
    local tracker = assert(GGM.CreateStableGearTracker(api, db, "Alice-Silvermoon", 300))

    setSlot("HEAD", 9001, "|Hitem:9001|h[Candidate Head]|h")
    assert(GGM.HandlePlayerEquipmentChanged(tracker, slotIDs.HEAD))

    setSlot("HEAD", 4001, "|Hitem:4001|h[Shared HEAD]|h")
    local state, err = GGM.HandlePlayerEquipmentChanged(tracker, slotIDs.HEAD)

    T.assertNil(err)
    T.assertEqual(state, "shared")
    T.assertNil(tracker.pendingBySlot.HEAD)
    T.assertTrue(timers[1].cancelled)

    timers[1]:Fire()
    local record = assert(GGM.GetCompleteCharacterRecord(db, "Alice-Silvermoon"))
    T.assertEqual(record.gear.slots.HEAD.itemID, 4001)
end)

T.test("changing a pending slot to another new item restarts only that slot", function()
    local GGM = loadModules()
    local api, db, timers, slotIDs, setSlot, setTime = makeEnvironment(GGM)
    local tracker = assert(GGM.CreateStableGearTracker(api, db, "Alice-Silvermoon", 300))

    setSlot("HEAD", 9001, "|Hitem:9001|h[First Candidate]|h")
    assert(GGM.HandlePlayerEquipmentChanged(tracker, slotIDs.HEAD))

    setSlot("HEAD", 9002, "|Hitem:9002|h[Second Candidate]|h")
    assert(GGM.HandlePlayerEquipmentChanged(tracker, slotIDs.HEAD))

    T.assertEqual(#timers, 2)
    T.assertTrue(timers[1].cancelled)
    T.assertFalse(timers[2].cancelled)

    setTime(1700000300)
    timers[2]:Fire()

    local record = assert(GGM.GetCompleteCharacterRecord(db, "Alice-Silvermoon"))
    T.assertEqual(record.gear.slots.HEAD.itemID, 9002)
    T.assertEqual(record.gear.capturedAt, 1700000300)
    T.assertNil(tracker.pendingBySlot.HEAD)
end)

T.test("different slots keep independent pending timers", function()
    local GGM = loadModules()
    local api, db, timers, slotIDs, setSlot, setTime = makeEnvironment(GGM)
    local tracker = assert(GGM.CreateStableGearTracker(api, db, "Alice-Silvermoon", 300))

    setSlot("HEAD", 9001, "|Hitem:9001|h[Candidate Head]|h")
    assert(GGM.HandlePlayerEquipmentChanged(tracker, slotIDs.HEAD))

    setSlot("NECK", 9002, "|Hitem:9002|h[Candidate Neck]|h")
    assert(GGM.HandlePlayerEquipmentChanged(tracker, slotIDs.NECK))

    T.assertEqual(#timers, 2)
    T.assertNotNil(tracker.pendingBySlot.HEAD)
    T.assertNotNil(tracker.pendingBySlot.NECK)

    setTime(1700000300)
    timers[1]:Fire()

    local afterHead = assert(GGM.GetCompleteCharacterRecord(db, "Alice-Silvermoon"))
    T.assertEqual(afterHead.gear.slots.HEAD.itemID, 9001)
    T.assertEqual(afterHead.gear.slots.NECK.itemID, 4002)
    T.assertNil(tracker.pendingBySlot.HEAD)
    T.assertNotNil(tracker.pendingBySlot.NECK)

    setTime(1700000310)
    timers[2]:Fire()

    local afterNeck = assert(GGM.GetCompleteCharacterRecord(db, "Alice-Silvermoon"))
    T.assertEqual(afterNeck.gear.slots.NECK.itemID, 9002)
    T.assertNil(tracker.pendingBySlot.NECK)
end)

T.test("timer expiry re-reads current gear and never confirms a stale candidate", function()
    local GGM = loadModules()
    local api, db, timers, slotIDs, setSlot = makeEnvironment(GGM)
    local tracker = assert(GGM.CreateStableGearTracker(api, db, "Alice-Silvermoon", 300))

    setSlot("HEAD", 9001, "|Hitem:9001|h[First Candidate]|h")
    assert(GGM.HandlePlayerEquipmentChanged(tracker, slotIDs.HEAD))

    setSlot("HEAD", 9002, "|Hitem:9002|h[Changed Without Event]|h")
    timers[1]:Fire()

    local record = assert(GGM.GetCompleteCharacterRecord(db, "Alice-Silvermoon"))
    T.assertEqual(record.gear.slots.HEAD.itemID, 4001)
    T.assertEqual(#timers, 2)
    T.assertNotNil(tracker.pendingBySlot.HEAD)
    T.assertEqual(tracker.pendingBySlot.HEAD.slot.itemID, 9002)
end)

T.test("tracker creation rejects a persisted slot id that disagrees with the current runtime slot id", function()
    local GGM = loadModules()
    local api, db = makeEnvironment(GGM)
    db.characters["Alice-Silvermoon"].gear.slots.HEAD.inventorySlotID = 999

    local tracker, err = GGM.CreateStableGearTracker(api, db, "Alice-Silvermoon", 300)

    T.assertNil(tracker)
    T.assertEqual(err, "snapshot-slot-id-mismatch:HEAD")
end)

T.test("timer creation returning nil fails closed without publishing pending state", function()
    local GGM = loadModules()
    local api, db, _, slotIDs, setSlot = makeEnvironment(GGM)
    api.C_Timer.NewTimer = function()
        return nil
    end

    local tracker = assert(GGM.CreateStableGearTracker(api, db, "Alice-Silvermoon", 300))
    setSlot("HEAD", 9001, "|Hitem:9001|h[Candidate Head]|h")

    local state, err = GGM.HandlePlayerEquipmentChanged(tracker, slotIDs.HEAD)

    T.assertNil(state)
    T.assertEqual(err, "timer-create-failed")
    T.assertEqual(tracker.lastError, "timer-create-failed")
    T.assertNil(tracker.pendingBySlot.HEAD)

    local record = assert(GGM.GetCompleteCharacterRecord(db, "Alice-Silvermoon"))
    T.assertEqual(record.gear.slots.HEAD.itemID, 4001)
end)

T.test("timer creation throwing fails closed without publishing pending state", function()
    local GGM = loadModules()
    local api, db, _, slotIDs, setSlot = makeEnvironment(GGM)
    api.C_Timer.NewTimer = function()
        error("timer unavailable")
    end

    local tracker = assert(GGM.CreateStableGearTracker(api, db, "Alice-Silvermoon", 300))
    setSlot("HEAD", 9001, "|Hitem:9001|h[Candidate Head]|h")

    local state, err = GGM.HandlePlayerEquipmentChanged(tracker, slotIDs.HEAD)

    T.assertNil(state)
    T.assertEqual(err, "timer-create-failed")
    T.assertEqual(tracker.lastError, "timer-create-failed")
    T.assertNil(tracker.pendingBySlot.HEAD)

    local record = assert(GGM.GetCompleteCharacterRecord(db, "Alice-Silvermoon"))
    T.assertEqual(record.gear.slots.HEAD.itemID, 4001)
end)

T.test("timer creation returning a non-cancelable handle fails closed", function()
    local GGM = loadModules()
    local api, db, _, slotIDs, setSlot = makeEnvironment(GGM)
    api.C_Timer.NewTimer = function()
        return {}
    end

    local tracker = assert(GGM.CreateStableGearTracker(api, db, "Alice-Silvermoon", 300))
    setSlot("HEAD", 9001, "|Hitem:9001|h[Candidate Head]|h")

    local state, err = GGM.HandlePlayerEquipmentChanged(tracker, slotIDs.HEAD)

    T.assertNil(state)
    T.assertEqual(err, "timer-handle-invalid")
    T.assertEqual(tracker.lastError, "timer-handle-invalid")
    T.assertNil(tracker.pendingBySlot.HEAD)

    local record = assert(GGM.GetCompleteCharacterRecord(db, "Alice-Silvermoon"))
    T.assertEqual(record.gear.slots.HEAD.itemID, 4001)
end)

T.test("an untracked equipment slot is ignored", function()
    local GGM = loadModules()
    local api, db, timers = makeEnvironment(GGM)
    local tracker = assert(GGM.CreateStableGearTracker(api, db, "Alice-Silvermoon", 300))

    local state, err = GGM.HandlePlayerEquipmentChanged(tracker, 999)

    T.assertNil(err)
    T.assertEqual(state, "ignored")
    T.assertEqual(#timers, 0)
end)

T.test("confirmed slot callback fires once after sequence and slot are persisted", function()
    local GGM = loadModules()
    local api, db, timers, slotIDs, setSlot, setTime = makeEnvironment(GGM)
    local calls = {}

    local tracker = assert(GGM.CreateStableGearTracker(
        api,
        db,
        "Alice-Silvermoon",
        300,
        function(characterKey, slotKey, slotValue, confirmedAt, confirmedSequence)
            local record = assert(GGM.GetCompleteCharacterRecord(db, characterKey))
            table.insert(calls, {
                characterKey = characterKey,
                slotKey = slotKey,
                itemID = slotValue.itemID,
                confirmedAt = confirmedAt,
                confirmedSequence = confirmedSequence,
                persistedSequence = record.confirmedSequence,
                persistedItemID = record.gear.slots[slotKey].itemID,
            })
        end
    ))

    setSlot("HEAD", 9200, "|Hitem:9200|h[Confirmed]|h")
    assert(GGM.HandlePlayerEquipmentChanged(tracker, slotIDs.HEAD))
    setTime(1700000300)
    timers[1]:Fire()

    T.assertEqual(#calls, 1)
    T.assertEqual(calls[1].characterKey, "Alice-Silvermoon")
    T.assertEqual(calls[1].slotKey, "HEAD")
    T.assertEqual(calls[1].itemID, 9200)
    T.assertEqual(calls[1].confirmedAt, 1700000300)
    T.assertEqual(calls[1].confirmedSequence, 1)
    T.assertEqual(calls[1].persistedSequence, 1)
    T.assertEqual(calls[1].persistedItemID, 9200)
end)

T.test("confirmation callback is not fired when persistence fails", function()
    local GGM = loadModules()
    local api, db, timers, slotIDs, setSlot = makeEnvironment(GGM)
    local callCount = 0
    local tracker = assert(GGM.CreateStableGearTracker(api, db, "Alice-Silvermoon", 300, function()
        callCount = callCount + 1
    end))

    setSlot("HEAD", 9300, "|Hitem:9300|h[Candidate]|h")
    assert(GGM.HandlePlayerEquipmentChanged(tracker, slotIDs.HEAD))
    db.characters["Alice-Silvermoon"].complete = false
    timers[1]:Fire()

    T.assertEqual(callCount, 0)
end)

T.test("confirmation callback failure never rolls back a persisted confirmation", function()
    local GGM = loadModules()
    local api, db, timers, slotIDs, setSlot, setTime = makeEnvironment(GGM)
    local tracker = assert(GGM.CreateStableGearTracker(api, db, "Alice-Silvermoon", 300, function()
        error("sync callback exploded")
    end))

    setSlot("HEAD", 9400, "|Hitem:9400|h[Confirmed]|h")
    assert(GGM.HandlePlayerEquipmentChanged(tracker, slotIDs.HEAD))
    setTime(1700000300)
    timers[1]:Fire()

    local record = assert(GGM.GetCompleteCharacterRecord(db, "Alice-Silvermoon"))
    T.assertEqual(record.gear.slots.HEAD.itemID, 9400)
    T.assertEqual(record.confirmedSequence, 1)
    T.assertNotNil(tracker.lastConfirmationCallbackError)
end)
