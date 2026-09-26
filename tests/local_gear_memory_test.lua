local T = require("tests.testlib")

local function loadModules()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/Constants.lua", GGM)
    T.loadAddonFile("GuildGearMemory/CharacterIdentity.lua", GGM)
    T.loadAddonFile("GuildGearMemory/GearSnapshot.lua", GGM)
    T.loadAddonFile("GuildGearMemory/Storage.lua", GGM)
    T.loadAddonFile("GuildGearMemory/StableGearTracker.lua", GGM)
    T.loadAddonFile("GuildGearMemory/LocalGearMemory.lua", GGM)
    return GGM
end

local function makeApi(GGM)
    local slotIDs = {}
    local itemIDs = {}
    local itemLinks = {}
    local timers = {}

    for index, slot in ipairs(GGM.TRACKED_SLOTS) do
        slotIDs[slot.inventoryName] = index
        itemIDs[index] = 3000 + index
        itemLinks[index] = "|Hitem:" .. tostring(3000 + index) .. "|h[Test]|h"
    end

    return {
        UnitFullName = function()
            return "Alice", "Silvermoon"
        end,
        GetRealmName = function()
            return "Silvermoon"
        end,
        UnitGUID = function()
            return "Player-1234-ABCDEF"
        end,
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
            return 1700000100
        end,
        C_Timer = {
            NewTimer = function(delay, callback)
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
            end,
        },
    }, itemIDs, itemLinks, timers
end

T.test("capture and store writes the local player's complete record", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local api = makeApi(GGM)

    local record, err = GGM.CaptureAndStoreLocalPlayer(api, db)

    T.assertNil(err)
    T.assertNotNil(record)
    T.assertEqual(record.identity.key, "Alice-Silvermoon")
    T.assertTrue(record.complete)
    T.assertEqual(record.gear.capturedAt, 1700000100)
end)

T.test("recapture keeps gear complete when the optional ranged slot is unavailable", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local api = makeApi(GGM)
    local first = assert(GGM.CaptureAndStoreLocalPlayer(api, db))
    T.assertEqual(first.gear.capturedAt, 1700000100)

    local originalSlotInfo = api.GetInventorySlotInfo
    api.GetInventorySlotInfo = function(inventoryName)
        if inventoryName == "RangedSlot" then return nil end
        return originalSlotInfo(inventoryName)
    end
    api.GetServerTime = function()
        return 1700000200
    end

    local record, err = GGM.CaptureAndStoreLocalPlayer(api, db)

    T.assertNil(err)
    T.assertNotNil(record)
    T.assertTrue(record.gear.slots.RANGED.unavailable)
    T.assertEqual(record.gear.capturedAt, 1700000200)

    local preserved = assert(GGM.GetCompleteCharacterRecord(db, "Alice-Silvermoon"))
    T.assertEqual(preserved.gear.capturedAt, 1700000200)
    T.assertTrue(preserved.gear.slots.RANGED.unavailable)
end)

T.test("get local record returns missing when no complete snapshot exists", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local api = makeApi(GGM)

    local record, err = GGM.GetLocalPlayerRecord(api, db)

    T.assertNil(record)
    T.assertEqual(err, "record-missing")
end)

T.test("starting tracking on first run creates a shared baseline with no pending slots", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local api, _, _, timers = makeApi(GGM)

    local tracker, err = GGM.StartLocalPlayerGearTracking(api, db, 5)

    T.assertNil(err)
    T.assertNotNil(tracker)
    T.assertEqual(tracker.stabilityDelaySeconds, 5)
    T.assertEqual(#timers, 0)
    T.assertNil(next(tracker.pendingBySlot))

    local record = assert(GGM.GetCompleteCharacterRecord(db, "Alice-Silvermoon"))
    T.assertEqual(record.gear.capturedAt, 1700000100)
end)

T.test("starting tracking with an existing record preserves shared gear and starts pending differences", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local api, itemIDs, itemLinks, timers = makeApi(GGM)

    assert(GGM.CaptureAndStoreLocalPlayer(api, db))
    local headSlotID = api.GetInventorySlotInfo("HeadSlot")
    itemIDs[headSlotID] = 9999
    itemLinks[headSlotID] = "|Hitem:9999|h[Login Candidate]|h"
    api.GetServerTime = function()
        return 1700000200
    end

    local tracker, err = GGM.StartLocalPlayerGearTracking(api, db, 5)

    T.assertNil(err)
    T.assertNotNil(tracker)
    T.assertNotNil(tracker.pendingBySlot.HEAD)
    T.assertEqual(#timers, 1)
    T.assertEqual(timers[1].delay, 5)

    local beforeConfirm = assert(GGM.GetCompleteCharacterRecord(db, "Alice-Silvermoon"))
    T.assertEqual(beforeConfirm.gear.slots.HEAD.itemID, 3001)
    T.assertEqual(beforeConfirm.gear.capturedAt, 1700000100)

    timers[1]:Fire()

    local afterConfirm = assert(GGM.GetCompleteCharacterRecord(db, "Alice-Silvermoon"))
    T.assertEqual(afterConfirm.gear.slots.HEAD.itemID, 9999)
    T.assertEqual(afterConfirm.gear.capturedAt, 1700000200)
end)

T.test("local tracking threads the confirmation callback into the stable tracker", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local api = makeApi(GGM)
    local callback = function() end

    local tracker, err = GGM.StartLocalPlayerGearTracking(api, db, 5, callback)

    T.assertNil(err)
    T.assertNotNil(tracker)
    T.assertTrue(tracker.onConfirmed == callback)
end)

T.test("starting tracking marks the current character local after tracker creation", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local api = makeApi(GGM)

    local tracker = assert(GGM.StartLocalPlayerGearTracking(api, db, 5))

    T.assertNotNil(tracker)
    T.assertTrue(GGM.IsLocalCharacter(db, "Alice-Silvermoon"))
end)

T.test("tracking startup failures do not mark a character local", function()
    local scenarios = {
        {
            name = "identity failure",
            configure = function(GGM, api)
                api.UnitFullName = function() return nil, "Silvermoon" end
            end,
        },
        {
            name = "initial capture failure",
            configure = function(_, api)
                api.GetInventorySlotInfo = function() return nil end
            end,
        },
        {
            name = "record validation failure",
            configure = function(GGM, api, db)
                assert(GGM.CaptureAndStoreLocalPlayer(api, db))
                GGM.GetCompleteCharacterRecord = function() return nil, "record-invalid" end
            end,
        },
        {
            name = "tracker creation failure",
            configure = function(GGM, api, db)
                assert(GGM.CaptureAndStoreLocalPlayer(api, db))
                GGM.CreateStableGearTracker = function() return nil, "tracker-failed" end
            end,
        },
    }

    for _, scenario in ipairs(scenarios) do
        local GGM = loadModules()
        local db = assert(GGM.InitializeDatabase(nil))
        local api = makeApi(GGM)
        scenario.configure(GGM, api, db)

        local tracker = GGM.StartLocalPlayerGearTracking(api, db, 5)

        T.assertNil(tracker, scenario.name)
        T.assertFalse(GGM.IsLocalCharacter(db, "Alice-Silvermoon"), scenario.name)
    end
end)

T.test("cached guild record is marked local only when current player tracking starts", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local api = makeApi(GGM)
    local identity = assert(GGM.BuildPlayerIdentity(api))
    local snapshot = assert(GGM.CapturePlayerGearSnapshot(api))
    assert(GGM.SaveCompleteCharacterRecord(db, identity, snapshot))

    T.assertFalse(GGM.IsLocalCharacter(db, identity.key))

    local tracker = assert(GGM.StartLocalPlayerGearTracking(api, db, 5))

    T.assertNotNil(tracker)
    T.assertTrue(GGM.IsLocalCharacter(db, identity.key))
end)

T.test("ownership marking failure is returned from tracking startup", function()
    local GGM = loadModules()
    local db = assert(GGM.InitializeDatabase(nil))
    local api = makeApi(GGM)
    GGM.MarkLocalCharacter = function() return nil, "ownership-write-failed" end

    local tracker, err = GGM.StartLocalPlayerGearTracking(api, db, 5)

    T.assertNil(tracker)
    T.assertEqual(err, "ownership-write-failed")
end)
