local T = require("tests.testlib")

local function loadManifest(folder, api, namespace, skipMain)
    for line in io.lines(folder .. "/" .. folder .. ".toc") do
        local file = line:match("^([%w]+%.lua)%s*$")
        if file and not (skipMain and file == "Main.lua") then
            local chunk = assert(loadfile(folder .. "/" .. file))
            setfenv(chunk, api)
            chunk(folder, namespace)
        end
    end
end

local function client(saved)
    local c = { frames = {}, timers = {}, sent = {}, now = 100, items = {} }
    for id = 1, 19 do c.items[id] = 1000 + id end
    local api = setmetatable({ DysgearMemoryDB = saved }, { __index = _G })
    api._G = api
    api.CreateFrame = function()
        local frame = { events = {} }
        function frame:RegisterEvent(event) self.events[event] = true end
        function frame:SetScript(_, handler) self.handler = handler end
        c.frames[#c.frames + 1] = frame
        return frame
    end
    api.UnitFullName = function() return "Alice", "Silvermoon" end
    api.UnitGUID = function() return "Player-1-Alice" end
    api.GetRealmName = function() return "Silvermoon" end
    api.GetTime = function() return c.now end
    api.GetServerTime = function() return 1700000000 + c.now end
    api.IsInGuild = function() return true end
    api.GetInventorySlotInfo = function(name)
        local names = { HeadSlot = 1, NeckSlot = 2, ShoulderSlot = 3, ShirtSlot = 4,
            ChestSlot = 5, WaistSlot = 6, LegsSlot = 7, FeetSlot = 8, WristSlot = 9,
            HandsSlot = 10, Finger0Slot = 11, Finger1Slot = 12, Trinket0Slot = 13,
            Trinket1Slot = 14, BackSlot = 15, MainHandSlot = 16, SecondaryHandSlot = 17, RangedSlot = 18, TabardSlot = 19 }
        return names[name]
    end
    api.GetInventoryItemID = function(_, id) return c.items[id] end
    api.GetInventoryItemLink = function(_, id) return "|Hitem:" .. c.items[id] .. "|h[Gear]|h" end
    local function schedule(delay, fn)
        local timer = { due = c.now + delay, callback = fn }
        function timer:Cancel() self.cancelled = true end
        c.timers[#c.timers + 1] = timer
        return timer
    end
    api.C_Timer = { After = schedule, NewTimer = schedule }
    api.C_ChatInfo = {
        RegisterAddonMessagePrefix = function() c.registered = (c.registered or 0) + 1; return 0 end,
        SendAddonMessage = function(...) c.sent[#c.sent + 1] = { ... }; return 0 end,
    }
    function c:event(event, ...)
        for _, frame in ipairs(self.frames) do
            if frame.events[event] then frame.handler(frame, event, ...) end
        end
    end
    function c:advance(seconds)
        local finish = self.now + seconds
        for _ = 1, 1000 do
            local nextTimer
            for _, timer in ipairs(self.timers) do
                if not timer.cancelled and not timer.fired and timer.due <= finish
                    and (not nextTimer or timer.due < nextTimer.due) then nextTimer = timer end
            end
            if not nextTimer then self.now = finish; return end
            self.now, nextTimer.fired = nextTimer.due, true
            nextTimer.callback()
        end
        error("unbounded timer activity")
    end
    c.api, c.backend = api, {}
    loadManifest("DysgearMemory", api, c.backend)
    c:event("ADDON_LOADED", "DysgearMemory")
    return c
end

local function display(c)
    local GGM = {}
    loadManifest("GuildGearMemory", c.api, GGM, true)
    GGM.CreateProfessionLinkSaveController = function() return nil, "unavailable" end
    local chunk = assert(loadfile("GuildGearMemory/Main.lua"))
    setfenv(chunk, c.api)
    chunk("GuildGearMemory", GGM)
    c:event("ADDON_LOADED", "GuildGearMemory")
    return GGM
end

T.test("gear backend captures and publishes a stable change with display addon absent", function()
    local c = client()
    T.assertEqual(c.registered, 1, "DysgearMemory must register its own sync")
    c:event("PLAYER_LOGIN")
    c:advance(1)
    local record = c.api.DysgearMemoryDB.characters["Alice-Silvermoon"]
    T.assertNotNil(record)
    T.assertEqual(#c.sent, 0)
    c.items[1] = 9999
    c:event("PLAYER_EQUIPMENT_CHANGED", 1)
    c:advance(299)
    T.assertEqual(#c.sent, 0)
    c:advance(5)
    T.assertEqual(record.confirmedSequence, 1)
    T.assertTrue(#c.sent > 0)
    T.assertNil(c.api.GuildGearMemoryDB)
end)

T.test("gear backend preserves saved records and does not broadcast at startup", function()
    local record = { sentinel = true, confirmedSequence = 42 }
    local saved = { schemaVersion = 7, characters = { old = record }, localCharacters = { old = true } }
    local c = client(saved)
    T.assertTrue(c.api.DysgearMemoryDB == saved)
    T.assertTrue(saved.characters.old == record)
    T.assertEqual(#c.sent, 0)
end)

T.test("gear backend rejects an unsupported database without mutating it", function()
    local saved = { schemaVersion = 99, sentinel = true }
    local c = client(saved)
    c:event("PLAYER_LOGIN")
    c:advance(10)
    T.assertTrue(c.api.DysgearMemoryDB == saved)
    T.assertNil(rawget(c.api, "DysgearMemoryAPI"))
    T.assertEqual(c.api.DysgearMemoryError, "unsupported-schema-version:99")
    T.assertEqual(#c.sent, 0)
end)

T.test("display addon binds the same backend without a second tracker or sync registration", function()
    local c = client()
    local GGM = {}
    loadManifest("GuildGearMemory", c.api, GGM, true)
    GGM.RegisterSnapshotTestSlashCommand = function() end
    GGM.CreateProfessionLinkSaveController = function() return nil, "unavailable" end
    local chunk = assert(loadfile("GuildGearMemory/Main.lua"))
    setfenv(chunk, c.api)
    chunk("GuildGearMemory", GGM)
    c:event("ADDON_LOADED", "GuildGearMemory")
    c:event("PLAYER_LOGIN")
    c:advance(1)
    T.assertEqual(c.registered, 1)
    T.assertTrue(GGM.gearTracker == c.backend.gearTracker)
    T.assertTrue(GGM.guildSync == c.backend.guildSync)
    T.assertTrue(GGM.db.characters == c.api.DysgearMemoryDB.characters)
    T.assertNotNil(GGM.GetCharacterRecord(GGM.db, "Alice-Silvermoon"))
    local entries = GGM.BuildGuildGearBrowserEntries(GGM.db)
    T.assertEqual(#entries, 1)
    local detail = GGM.BuildGuildGearBrowserDetail(entries[1].record, c.api)
    T.assertTrue(detail.hasRecord)
    T.assertEqual(#detail.slots, 19)
    T.assertEqual(detail.slots[1].itemID, 1001)
    T.assertEqual(detail.completenessText, "Complete")
    T.assertNil(c.api.GuildGearMemoryDB.characters)
    local mainFrame = c.frames[#c.frames]
    T.assertNil(mainFrame.events.PLAYER_EQUIPMENT_CHANGED)
    T.assertNil(mainFrame.events.CHAT_MSG_ADDON)
end)

T.test("missing gear backend preserves the browser slot layout and status command", function()
    local c = client({ schemaVersion = 99 })
    c.api.DysgearMemoryError = nil
    local output = {}
    c.api.SlashCmdList = {}
    c.api.print = function(text) output[#output + 1] = text end
    local GGM = display(c)
    T.assertEqual(GGM.gearStartupError, "gear-companion-missing")
    T.assertEqual(#GGM.TRACKED_SLOTS, 19)
    for index, slot in ipairs(GGM.TRACKED_SLOTS) do
        T.assertEqual(slot.inventoryName, c.backend.TRACKED_SLOTS[index].inventoryName)
    end
    c.api.SlashCmdList.GUILDGEARMEMORY("status")
    T.assertTrue(#output > 0)
    T.assertEqual(type(GGM.db.professions), "table")
    T.assertNil(GGM.db.characters)
end)

T.test("profession ownership failure does not affect independent gear tracking", function()
    local c = client()
    c.api.SlashCmdList = {}
    local GGM = display(c)
    GGM.RecordLocalPlayerOwnership = function() return false, "player-guid-unavailable" end
    c:event("PLAYER_LOGIN")
    c:advance(1)
    T.assertEqual(GGM.lastLocalOwnershipError, "player-guid-unavailable")
    T.assertNotNil(c.backend.gearTracker)
    T.assertTrue(GGM.gearTracker == c.backend.gearTracker)
end)

T.test("profession ownership and saving remain available without gear backend", function()
    local c = client({ schemaVersion = 99 })
    c.api.SlashCmdList = {}
    local GGM = display(c)
    c:event("PLAYER_LOGIN")
    T.assertTrue(c.api.GuildGearMemoryDB.localCharacterGUIDs["Player-1-Alice"])
    local identity = assert(GGM.BuildPlayerIdentity(c.api))
    T.assertTrue(GGM.SaveProfessionSnapshot(GGM.db, identity, {
        complete = true, professionID = 164, professionName = "Blacksmithing",
        capturedAt = 1700000000, source = GGM.PROFESSION_SOURCE_PLAYER,
        status = GGM.PROFESSION_CACHE_STATUS,
        recipes = { { recipeID = 41234, name = "Copper Bracers" } },
    }, { guildMembershipVerified = true }))
    T.assertNotNil(c.api.GuildGearMemoryDB.professions[identity.key])
    T.assertNil(c.api.GuildGearMemoryDB.characters)
end)

T.test("old persistence-only companion is reported as unsupported", function()
    local c = client()
    c.api.DysgearMemoryAPI = { schemaVersion = 1, GetDatabase = function() return c.api.DysgearMemoryDB end }
    c.api.SlashCmdList = {}
    local GGM = display(c)
    T.assertEqual(GGM.gearStartupError, "gear-companion-unsupported")
    T.assertNil(GGM.db.characters)
end)

T.test("gear backend owns departed member cache cleanup", function()
    local c = client()
    T.assertEqual(type(c.backend.PurgeDepartedGearRecords), "function")
    local db = c.api.DysgearMemoryDB
    db.characters.Departed = { identity = { guid = "Player-1-Departed" } }
    db.characters.Local = { identity = { guid = "Player-1-Local" } }
    db.localCharacters.Local = true
    c.backend.PurgeDepartedGearRecords(db, {})
    T.assertNil(db.characters.Departed)
    T.assertNotNil(db.characters.Local)
    T.assertEqual(#c.sent, 0)
end)

return { client = client, loadManifest = loadManifest }
