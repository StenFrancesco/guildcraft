local T = require("tests.testlib")

local function newFixture(options)
    options = options or {}
    local GGM = {}
    T.loadAddonFile("The Guild Book gear/Constants.lua", GGM)
    T.loadAddonFile("The Guild Book gear/GearData.lua", GGM)
    T.loadAddonFile("The Guild Book gear/GearSnapshot.lua", GGM)
    if options.useRealStorage then T.loadAddonFile("The Guild Book gear/Storage.lua", GGM) end
    T.loadAddonFile("The Guild Book gear/InspectGear.lua", GGM)

    local hooks, timers, saves = {}, {}, {}
    local changed = 0
    local targetGUID = options.targetGUID or "Player-1-Target"
    local now = options.now or 123456
    local targetGuildName = options.targetGuildName or "The Guild"
    local targetGuildRealm = options.targetGuildRealm or "Realm"
    local playerRealm = options.playerRealm or "Realm"
    local targetRealm = options.targetRealm or "Realm"
    local inventoryIDs, items = {}, {}
    for _, slot in ipairs(GGM.TRACKED_SLOTS) do
        inventoryIDs[slot.inventoryName] = slot.inventorySlotID
        items[slot.inventorySlotID] = {}
    end
    if options.equipped ~= false then
        local head = GGM.TRACKED_SLOTS[1].inventorySlotID
        items[head] = { id = 12345, link = "|Hitem:12345|h[Helm]|h", texture = 987 }
    end

    local api = {
        hooksecurefunc = function(name, callback) hooks[name] = callback end,
        NotifyInspect = function() end,
        ClearInspectPlayer = function() end,
        C_Timer = {
            After = function(delay, callback)
                timers[#timers + 1] = { delay = delay, callback = callback }
            end,
        },
        IsInGuild = function() return options.inGuild ~= false end,
        UnitIsInMyGuild = function(unit)
            return unit == "target" and options.sameGuild ~= false
        end,
        GetGuildInfo = function(unit)
            if unit == "player" then return "The Guild", nil, nil, options.playerGuildRealm or "Realm" end
            if options.omitTargetGuildRealm then return targetGuildName, nil, nil, nil end
            return targetGuildName, nil, nil, targetGuildRealm
        end,
        UnitGUID = function(unit)
            if unit == "player" then return "Player-1-Owner" end
            if unit == "target" then return targetGUID end
        end,
        UnitFullName = function(unit)
            if unit == "player" then
                if options.omitPlayerUnitRealm then return "Owner", nil end
                return "Owner", playerRealm
            end
            if unit == "target" then return "Target", targetRealm end
        end,
        GetRealmName = function() return options.localRealm or playerRealm end,
        GetInventorySlotInfo = function(name) return inventoryIDs[name] end,
        GetInventoryItemID = function(_, slotID) return items[slotID].id end,
        GetInventoryItemLink = function(_, slotID)
            if options.changeGUIDOnSlot == slotID then targetGUID = "Player-1-Swapped" end
            return items[slotID].link
        end,
        GetInventoryItemTexture = function(_, slotID) return items[slotID].texture end,
        GetServerTime = function() return now end,
        issecretvalue = function(value) return options.secretValue ~= nil and value == options.secretValue end,
    }
    if options.rosterRows then
        api.GetNumGuildMembers = function() return #options.rosterRows end
        api.GetGuildRosterInfo = function(index)
            local row, values = options.rosterRows[index], {}
            values[1], values[17] = row.name, row.guid
            return unpack(values, 1, 17)
        end
    end
    if options.omitUnitGuildCheck then api.UnitIsInMyGuild = nil end
    local db
    if options.useRealStorage then
        db = GGM.InitializeGearDatabase()
    else
        db = { schemaVersion = 7, characters = {}, localCharacters = {} }
        GGM.SaveObservedCharacterRecord = function(actualDB, identity, snapshot)
            saves[#saves + 1] = { db = actualDB, identity = identity, snapshot = snapshot }
            return true, nil
        end
    end
    local state, installErr = GGM.InstallInspectGearCapture(api, db, function() changed = changed + 1 end)
    return {
        GGM = GGM, api = api, db = db, hooks = hooks, timers = timers, saves = saves,
        state = state, installErr = installErr, changed = function() return changed end,
        setTargetGUID = function(guid) targetGUID = guid end,
        setNow = function(value) now = value end,
        setGuild = function(name, realm) targetGuildName, targetGuildRealm = name, realm end,
        items = items,
    }
end

local function beginInspect(fixture, unit)
    fixture.hooks.NotifyInspect(unit or "target")
end

T.test("inspect hooks observe existing requests and save one complete guild gear observation", function()
    local f = newFixture()
    T.assertNotNil(f.state)
    T.assertNil(f.installErr)
    T.assertNotNil(f.hooks.NotifyInspect)
    T.assertNotNil(f.hooks.ClearInspectPlayer)
    T.assertEqual(#f.saves, 0, "installing hooks must not request or clear an inspection")

    beginInspect(f)
    T.assertEqual(#f.saves, 0, "NotifyInspect itself is not a completion event")
    local result = f.GGM.HandleInspectGearReady(f.state, "Player-1-Target")

    T.assertEqual(result, "saved")
    T.assertEqual(#f.saves, 1)
    T.assertEqual(f.saves[1].db, f.db)
    T.assertEqual(f.saves[1].identity.key, "Target-Realm")
    T.assertEqual(f.saves[1].identity.guid, "Player-1-Target")
    T.assertTrue(f.saves[1].snapshot.complete)
    T.assertEqual(f.saves[1].snapshot.capturedAt, 123456)
    T.assertEqual(f.saves[1].snapshot.slots.HEAD.itemID, 12345)
    T.assertEqual(f.saves[1].snapshot.slots.NECK.itemID, false,
        "empty equipment slots must be represented explicitly")
    T.assertEqual(f.changed(), 1)
end)

T.test("inspection writes through real gear storage and rebuilds a sync-ready snapshot", function()
    local f = newFixture({ useRealStorage = true })
    beginInspect(f)
    T.assertEqual(f.GGM.HandleInspectGearReady(f.state, "Player-1-Target"), "saved")

    local record, recordErr = f.GGM.GetCompleteCharacterRecord(f.db, "Target-Realm")
    T.assertNotNil(record, recordErr)
    T.assertEqual(record.identity.guid, "Player-1-Target")
    T.assertEqual(record.gear.capturedAt, 123456)
    T.assertEqual(f.GGM.GetGearSlotObservedAt(record.gear, 1), 123456)

    local runtimeSnapshot, snapshotErr = f.GGM.BuildRuntimeGearSnapshot(f.api, record.gear)
    T.assertNotNil(runtimeSnapshot, snapshotErr)
    T.assertTrue(runtimeSnapshot.complete)
    T.assertEqual(runtimeSnapshot.slotObservedAt[1], 123456)
    T.assertTrue(f.GGM.ValidateCompleteSnapshot(runtimeSnapshot))
    T.assertEqual(f.changed(), 1)
end)

T.test("a delayed inspection cannot replace an owner slot observed after inspection began", function()
    local f = newFixture({ useRealStorage = true, now = 100 })
    local identity = { key = "Target-Realm", name = "Target", realm = "Realm", guid = "Player-1-Target" }
    local baseline = { complete = true, capturedAt = 99, slots = {} }
    for _, slot in ipairs(f.GGM.TRACKED_SLOTS) do
        if slot.key == "HEAD" then
            baseline.slots[slot.key] = {
                inventorySlotID = slot.inventorySlotID,
                itemID = 111,
                itemLink = "|Hitem:111|h[Old]|h",
            }
        else
            baseline.slots[slot.key] = {
                inventorySlotID = slot.inventorySlotID,
                itemID = false,
                itemLink = false,
            }
        end
    end
    T.assertTrue(f.GGM.SaveObservedCharacterRecord(f.db, identity, baseline))

    local head = f.GGM.TRACKED_SLOTS[1].inventorySlotID
    f.items[head] = { id = 6789, link = nil, texture = 555 }
    beginInspect(f)
    T.assertEqual(f.GGM.HandleInspectGearReady(f.state, "Player-1-Target"), "retrying")

    f.setNow(101)
    T.assertTrue(f.GGM.UpdateConfirmedCharacterSlot(f.db, identity.key, "HEAD", {
        inventorySlotID = head,
        itemID = 222,
        itemLink = "|Hitem:222|h[Owner update]|h",
    }, 101))
    f.items[head].link = "|Hitem:6789|h[Inspected]|h"
    f.setNow(102)
    f.timers[1].callback()

    local record = f.GGM.GetCompleteCharacterRecord(f.db, identity.key)
    local storedHead = f.GGM.GetStoredGearSlot(record.gear, "HEAD")
    T.assertEqual(f.GGM.GetGearSlotObservedAt(record.gear, head), 101)
    T.assertEqual(storedHead.itemID, 222)
    T.assertEqual(record.confirmedSequence, 1)
end)

T.test("inspect capture rejects completion for another GUID or a unit that changed", function()
    local f = newFixture()
    beginInspect(f)
    T.assertEqual(f.GGM.HandleInspectGearReady(f.state, "Player-1-Other"), "ignored")
    T.assertEqual(#f.saves, 0)

    f.setTargetGUID("Player-1-Swapped")
    T.assertEqual(f.GGM.HandleInspectGearReady(f.state, "Player-1-Target"), "ignored")
    T.assertEqual(#f.saves, 0)
end)

T.test("inspect capture requires actual current guild membership", function()
    local f = newFixture({ sameGuild = false })
    beginInspect(f)
    local result = f.GGM.HandleInspectGearReady(f.state, "Player-1-Target")
    T.assertEqual(result, "ignored")
    T.assertEqual(#f.saves, 0)

    local fallback = newFixture({ omitUnitGuildCheck = true, targetGuildName = "The Guild", targetGuildRealm = "OtherRealm" })
    beginInspect(fallback)
    T.assertEqual(fallback.GGM.HandleInspectGearReady(fallback.state, "Player-1-Target"), "ignored",
        "matching guild names on different realms are not sufficient")
    T.assertEqual(#fallback.saves, 0)
end)

T.test("inspect capture accepts UnitIsInMyGuild proof for cross-realm guildies", function()
    local f = newFixture({ targetRealm = "Other Realm", omitTargetGuildRealm = true })
    beginInspect(f)
    T.assertEqual(f.GGM.HandleInspectGearReady(f.state, "Player-1-Target"), "saved")
    T.assertEqual(#f.saves, 1)
    T.assertEqual(f.saves[1].identity.key, "Target-Other Realm")
end)

T.test("inspect identity uses the local display spelling for a same-realm compact alias", function()
    local f = newFixture({
        playerRealm = "Twisting Nether",
        targetRealm = "TwistingNether",
        localRealm = "Twisting Nether",
    })
    beginInspect(f)
    T.assertEqual(f.GGM.HandleInspectGearReady(f.state, "Player-1-Target"), "saved")
    T.assertEqual(f.saves[1].identity.key, "Target-Twisting Nether")
    T.assertEqual(f.saves[1].identity.realm, "Twisting Nether")
end)

T.test("inspect identity uses compact UnitFullName realm when it differs in spelling from GetRealmName", function()
    local f = newFixture({
        playerRealm = "MyRealm",
        targetRealm = "MyRealm",
        localRealm = "My Realm",
    })
    beginInspect(f)
    T.assertEqual(f.GGM.HandleInspectGearReady(f.state, "Player-1-Target"), "saved")
    T.assertEqual(f.saves[1].identity.key, "Target-MyRealm")
    T.assertEqual(f.saves[1].identity.realm, "MyRealm")
end)

T.test("inspect identity falls back to GetRealmName when the local unit realm is absent", function()
    local f = newFixture({
        omitPlayerUnitRealm = true,
        targetRealm = "TwistingNether",
        localRealm = "Twisting Nether",
    })
    beginInspect(f)
    T.assertEqual(f.GGM.HandleInspectGearReady(f.state, "Player-1-Target"), "saved")
    T.assertEqual(f.saves[1].identity.key, "Target-Twisting Nether")
    T.assertEqual(f.saves[1].identity.realm, "Twisting Nether")
end)

T.test("inspect capture prefers roster GUID over a matching name when validating guild membership", function()
    local f = newFixture({ omitUnitGuildCheck = true, rosterRows = {
        { name = "Target-Realm", guid = "Player-1-Other" },
    } })
    beginInspect(f)
    T.assertEqual(f.GGM.HandleInspectGearReady(f.state, "Player-1-Target"), "ignored")
    T.assertEqual(#f.saves, 0)

    local unavailable = newFixture({ omitUnitGuildCheck = true })
    unavailable.api.GetNumGuildMembers = function() error("roster is not ready") end
    unavailable.api.GetGuildRosterInfo = function() error("must not read an unavailable roster") end
    beginInspect(unavailable)
    T.assertEqual(unavailable.GGM.HandleInspectGearReady(unavailable.state, "Player-1-Target"), "ignored")
    T.assertEqual(#unavailable.saves, 0,
        "matching guild labels must not replace a failed roster membership check")
end)

T.test("inspect capture retries temporarily unloaded item data and saves after it becomes consistent", function()
    local f = newFixture({ now = 100 })
    local head = f.GGM.TRACKED_SLOTS[1].inventorySlotID
    f.items[head] = { id = 6789, link = nil, texture = 555 }
    beginInspect(f)
    T.assertEqual(f.GGM.HandleInspectGearReady(f.state, "Player-1-Target"), "retrying")
    T.assertEqual(#f.saves, 0)
    T.assertEqual(#f.timers, 1)

    f.items[head].link = "|Hitem:6789|h[Loaded]|h"
    f.setNow(101)
    f.timers[1].callback()
    T.assertEqual(#f.saves, 1)
    T.assertEqual(f.saves[1].snapshot.slots.HEAD.itemID, 6789)
    T.assertEqual(f.saves[1].snapshot.capturedAt, 100,
        "inspection observation time is fixed by the first matching INSPECT_READY event")
    T.assertEqual(f.changed(), 1)
end)

T.test("inspect retries stop at the configured bound for permanently unloaded data", function()
    local f = newFixture()
    local head = f.GGM.TRACKED_SLOTS[1].inventorySlotID
    f.items[head] = { id = 6789, link = nil, texture = 555 }
    beginInspect(f)
    T.assertEqual(f.GGM.HandleInspectGearReady(f.state, "Player-1-Target"), "retrying")
    local timerIndex = 1
    while timerIndex <= #f.timers do
        f.timers[timerIndex].callback()
        timerIndex = timerIndex + 1
    end
    T.assertTrue(#f.timers <= 3, "inspect retries must stay bounded")
    T.assertEqual(#f.saves, 0)
end)

T.test("clearing an inspection cancels its pending retries", function()
    local f = newFixture()
    local head = f.GGM.TRACKED_SLOTS[1].inventorySlotID
    f.items[head] = { id = 6789, link = nil, texture = 555 }
    beginInspect(f)
    T.assertEqual(f.GGM.HandleInspectGearReady(f.state, "Player-1-Target"), "retrying")
    f.hooks.ClearInspectPlayer()
    f.items[head].link = "|Hitem:6789|h[Loaded]|h"
    f.timers[1].callback()
    T.assertEqual(#f.saves, 0)
end)

T.test("inspect capture refuses an empty-all observation with no usable gear data", function()
    local f = newFixture({ equipped = false })
    beginInspect(f)
    T.assertEqual(f.GGM.HandleInspectGearReady(f.state, "Player-1-Target"), "ignored")
    T.assertEqual(#f.saves, 0)
end)

T.test("inspect capture rejects secret or throwing equipment values", function()
    local f = newFixture({ secretValue = "SECRET" })
    local head = f.GGM.TRACKED_SLOTS[1].inventorySlotID
    f.items[head] = { id = "SECRET", link = "|Hitem:12345|h[Helm]|h", texture = 987 }
    f.api.issecretvalue = function(value) return value == "SECRET" end
    beginInspect(f)
    T.assertEqual(f.GGM.HandleInspectGearReady(f.state, "Player-1-Target"), "ignored")
    T.assertEqual(#f.saves, 0)

    local throwing = newFixture()
    throwing.api.GetInventoryItemLink = function() error("protected read") end
    beginInspect(throwing)
    T.assertEqual(throwing.GGM.HandleInspectGearReady(throwing.state, "Player-1-Target"), "ignored")
    T.assertEqual(#throwing.saves, 0)
end)

T.test("inspect capture rechecks the target GUID immediately before saving", function()
    local f = newFixture()
    local lastSlot = f.GGM.TRACKED_SLOTS[#f.GGM.TRACKED_SLOTS].inventorySlotID
    f.items[lastSlot] = { id = 9988, link = "|Hitem:9988|h[Weapon]|h", texture = 777 }
    f.api.GetInventoryItemLink = function(_, slotID)
        if slotID == lastSlot then f.setTargetGUID("Player-1-Swapped") end
        return f.items[slotID].link
    end
    beginInspect(f)
    T.assertEqual(f.GGM.HandleInspectGearReady(f.state, "Player-1-Target"), "ignored")
    T.assertEqual(#f.saves, 0)
end)

T.test("Main registers INSPECT_READY and safely initializes without secure hook APIs", function()
    local registrations, handler = {}, nil
    local frame = {
        RegisterEvent = function(_, event) registrations[event] = true end,
        SetScript = function(_, _, callback) handler = callback end,
    }
    local original = {
        CreateFrame = _G.CreateFrame,
        TheGuildBookGearDB = _G.TheGuildBookGearDB,
        DysgearMemoryAPI = _G.DysgearMemoryAPI,
        DysgearMemoryError = _G.DysgearMemoryError,
    }
    _G.CreateFrame = function() return frame end
    _G.TheGuildBookGearDB = nil
    local GGM = {
        InitializeGearDatabase = function() return { schemaVersion = 7, characters = {}, localCharacters = {} } end,
        CreateGuildSync = function() return nil, "sync-disabled" end,
        InstallInspectGearCapture = function() return nil, "inspect-hook-unavailable" end,
        DEFAULT_STABILITY_DELAY_SECONDS = 1,
    }
    local ok, err = pcall(function()
        T.loadAddonFile("The Guild Book gear/Main.lua", GGM)
        T.assertTrue(registrations.INSPECT_READY)
        handler(frame, "ADDON_LOADED", "The Guild Book gear")
        handler(frame, "INSPECT_READY", "Player-1-Target")
    end)
    _G.CreateFrame, _G.TheGuildBookGearDB = original.CreateFrame, original.TheGuildBookGearDB
    _G.DysgearMemoryAPI, _G.DysgearMemoryError = original.DysgearMemoryAPI, original.DysgearMemoryError
    if not ok then error(err) end
    T.assertNil(GGM.startupError)
    T.assertEqual(GGM.lastInspectCaptureError, "inspect-hook-unavailable")
end)
