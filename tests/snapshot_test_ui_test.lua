local T = require("tests.testlib")
local makeRecord

local function loadUI()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/Constants.lua", GGM)
    T.loadAddonFile("GuildGearMemory/GearSnapshot.lua", GGM)
    T.loadAddonFile("GuildGearMemory/Storage.lua", GGM)
    T.loadAddonFile("GuildGearMemory/SnapshotTestUI.lua", GGM)
    return GGM
end

T.test("guild gear browser includes only valid records sorted by name then realm without mutation", function()
    local GGM = loadUI()
    local zulu = makeRecord(GGM)
    zulu.identity = { key = "zULu-Zenith", name = "zULu", realm = "Zenith" }
    local alpha = makeRecord(GGM)
    alpha.identity = { key = "ALPHA-amber", name = "ALPHA", realm = "amber" }
    local sameNameFirstRealm = makeRecord(GGM)
    sameNameFirstRealm.identity = { key = "Alpha-Azure", name = "Alpha", realm = "Azure" }
    local db = { schemaVersion = GGM.SCHEMA_VERSION, characters = {
        [zulu.identity.key] = zulu,
        [alpha.identity.key] = alpha,
        [sameNameFirstRealm.identity.key] = sameNameFirstRealm,
        ["missing"] = false,
        ["incomplete"] = { complete = false },
        ["malformed"] = { complete = true, identity = { key = "wrong", name = "Bad", realm = "Realm" } },
        ["invalid-snapshot"] = { complete = true, identity = { key = "invalid-snapshot", name = "invalid", realm = "snapshot" }, gear = { complete = false } },
    } }
    local beforeZuluName, beforeAlphaSlot = zulu.identity.name, alpha.gear.slots.HEAD.itemID

    local entries = GGM.BuildGuildGearBrowserEntries(db)

    T.assertEqual(#entries, 3)
    T.assertEqual(entries[1].key, "ALPHA-amber")
    T.assertEqual(entries[2].key, "Alpha-Azure")
    T.assertEqual(entries[3].key, "zULu-Zenith")
    T.assertTrue(entries[1].record == alpha)
    T.assertTrue(db.characters[alpha.identity.key] == alpha)
    T.assertEqual(zulu.identity.name, beforeZuluName)
    T.assertEqual(alpha.gear.slots.HEAD.itemID, beforeAlphaSlot)
    T.assertNil(GGM.BuildGuildGearBrowserEntries(nil)[1])
end)

T.test("guild gear browser filter matches name and realm case-insensitively without mutation", function()
    local GGM = loadUI()
    local entries = {
        { key = "a", name = "Alpha", realm = "Silvermoon" },
        { key = "b", name = "Beta", realm = "Argent Dawn" },
    }
    local originalFirst = entries[1]

    local all = GGM.FilterGuildGearBrowserEntries(entries, nil)
    local byName = GGM.FilterGuildGearBrowserEntries(entries, "ALP")
    local byRealm = GGM.FilterGuildGearBrowserEntries(entries, "DAWN")

    T.assertEqual(#all, 2)
    T.assertEqual(#GGM.FilterGuildGearBrowserEntries(entries, ""), 2)
    T.assertEqual(#byName, 1)
    T.assertEqual(byName[1].key, "a")
    T.assertEqual(#byRealm, 1)
    T.assertEqual(byRealm[1].key, "b")
    T.assertEqual(#entries, 2)
    T.assertTrue(entries[1] == originalFirst)
end)

T.test("guild gear browser detail renders captured time and all saved or empty slots", function()
    local GGM = loadUI()
    local record = makeRecord(GGM)
    local empty = record.gear.slots.OFF_HAND
    empty.itemID, empty.itemLink = false, false
    local iconCalls, textureCalls = {}, {}
    local api = {
        date = function(format, timestamp)
            T.assertEqual(format, "%Y-%m-%d %H:%M:%S")
            T.assertEqual(timestamp, 1700000100)
            return "saved time"
        end,
        GetItemIcon = function(itemID)
            table.insert(iconCalls, itemID)
            return "icon:" .. itemID
        end,
        GetInventorySlotInfo = function(slotName)
            for _, slot in ipairs(GGM.TRACKED_SLOTS) do
                if slot.inventoryName == slotName then
                    table.insert(textureCalls, slotName)
                    return slot.inventorySlotID or #textureCalls, "texture:" .. slotName
                end
            end
        end,
    }

    local model = GGM.BuildGuildGearBrowserDetail(record, api)

    T.assertTrue(model.hasRecord)
    T.assertEqual(model.characterName, "Alice")
    T.assertEqual(model.realm, "Silvermoon")
    T.assertEqual(model.capturedAtText, "saved time")
    T.assertEqual(#model.slots, #GGM.TRACKED_SLOTS)
    for index, trackedSlot in ipairs(GGM.TRACKED_SLOTS) do
        local row = model.slots[index]
        T.assertEqual(row.key, trackedSlot.key)
        if trackedSlot.key == "OFF_HAND" then
            T.assertTrue(row.empty)
            T.assertEqual(row.itemID, false)
            T.assertEqual(row.itemLink, false)
            T.assertEqual(row.icon, "texture:" .. trackedSlot.inventoryName)
            T.assertEqual(row.slotTexture, "texture:" .. trackedSlot.inventoryName)
        else
            local saved = record.gear.slots[trackedSlot.key]
            T.assertFalse(row.empty)
            T.assertEqual(row.itemID, saved.itemID)
            T.assertEqual(row.itemLink, saved.itemLink)
            T.assertEqual(row.icon, "icon:" .. saved.itemID)
        end
    end
    T.assertEqual(#iconCalls, #GGM.TRACKED_SLOTS - 1)
end)

T.test("guild gear browser detail rejects invalid or incomplete records", function()
    local GGM = loadUI()
    local malformed = makeRecord(GGM)
    malformed.gear.slots.HEAD.itemLink = false

    T.assertFalse(GGM.BuildGuildGearBrowserDetail(nil, {}).hasRecord)
    T.assertFalse(GGM.BuildGuildGearBrowserDetail({ complete = false }, {}).hasRecord)
    T.assertFalse(GGM.BuildGuildGearBrowserDetail(malformed, {}).hasRecord)
end)

T.test("guild gear browser detail falls back to slot texture when item icon is unavailable", function()
    local GGM = loadUI()
    local record = makeRecord(GGM)
    local model = GGM.BuildGuildGearBrowserDetail(record, {
        GetItemIcon = function() return nil end,
        GetInventorySlotInfo = function() return 1, "slot-texture" end,
    })

    T.assertEqual(model.slots[1].itemID, record.gear.slots.HEAD.itemID)
    T.assertEqual(model.slots[1].itemLink, record.gear.slots.HEAD.itemLink)
    T.assertEqual(model.slots[1].icon, "slot-texture")
end)

makeRecord = function(GGM)
    local slots = {}

    for index, slot in ipairs(GGM.TRACKED_SLOTS) do
        slots[slot.key] = {
            inventorySlotID = index,
            itemID = 4000 + index,
            itemLink = "|Hitem:" .. tostring(4000 + index) .. "|h[Test " .. slot.key .. "]|h",
        }
    end

    return {
        complete = true,
        identity = {
            key = "Alice-Silvermoon",
            name = "Alice",
            realm = "Silvermoon",
            guid = "Player-1234-ABCDEF",
        },
        gear = {
            complete = true,
            capturedAt = 1700000100,
            slots = slots,
        },
    }
end

local function newTextControl()
    return {
        text = nil,
        visible = false,
        SetText = function(self, text)
            self.text = text
        end,
        Show = function(self)
            self.visible = true
        end,
        Hide = function(self)
            self.visible = false
        end,
    }
end

local function newRenderableFrame(GGM)
    local frame = {
        emptyState = newTextControl(),
        characterLine = newTextControl(),
        realmLine = newTextControl(),
        capturedLine = newTextControl(),
        completenessLine = newTextControl(),
        slotRows = {},
        shown = false,
    }

    for _ = 1, #GGM.TRACKED_SLOTS do
        table.insert(frame.slotRows, newTextControl())
    end

    function frame:Show()
        self.shown = true
    end

    return frame
end

T.test("snapshot view model exposes saved identity time completeness and every tracked slot", function()
    local GGM = loadUI()
    local record = makeRecord(GGM)

    local model = GGM.BuildSnapshotViewModel(record, function(format, timestamp)
        T.assertEqual(format, "%Y-%m-%d %H:%M:%S")
        T.assertEqual(timestamp, 1700000100)
        return "2023-11-14 22:15:00"
    end)

    T.assertTrue(model.hasSnapshot)
    T.assertEqual(model.characterName, "Alice")
    T.assertEqual(model.realm, "Silvermoon")
    T.assertEqual(model.capturedAtText, "2023-11-14 22:15:00")
    T.assertEqual(model.completenessText, "Complete")
    T.assertEqual(#model.slots, #GGM.TRACKED_SLOTS)
    T.assertEqual(model.slots[1].key, "HEAD")
    T.assertEqual(model.slots[1].valueText, record.gear.slots.HEAD.itemLink)
end)

T.test("snapshot view model displays an empty saved equipment slot explicitly", function()
    local GGM = loadUI()
    local record = makeRecord(GGM)
    record.gear.slots.OFF_HAND.itemID = false
    record.gear.slots.OFF_HAND.itemLink = false

    local model = GGM.BuildSnapshotViewModel(record)

    local offHand
    for _, slot in ipairs(model.slots) do
        if slot.key == "OFF_HAND" then
            offHand = slot
            break
        end
    end

    T.assertNotNil(offHand)
    T.assertEqual(offHand.valueText, "Empty")
end)

T.test("missing or incomplete records become the no saved snapshot state", function()
    local GGM = loadUI()

    local missing = GGM.BuildSnapshotViewModel(nil)
    T.assertFalse(missing.hasSnapshot)
    T.assertEqual(missing.emptyStateText, "No saved snapshot")

    local incomplete = makeRecord(GGM)
    incomplete.complete = false

    local invalid = GGM.BuildSnapshotViewModel(incomplete)
    T.assertFalse(invalid.hasSnapshot)
    T.assertEqual(invalid.emptyStateText, "No saved snapshot")
end)

T.test("malformed identity records become the no saved snapshot state", function()
    local GGM = loadUI()
    local cases = {
        function(record) record.identity.key = "" end,
        function(record) record.identity.key = false end,
        function(record) record.identity.name = "" end,
        function(record) record.identity.realm = false end,
    }

    for _, makeMalformed in ipairs(cases) do
        local record = makeRecord(GGM)
        makeMalformed(record)
        local model = GGM.BuildSnapshotViewModel(record)
        T.assertFalse(model.hasSnapshot)
        T.assertEqual(model.emptyStateText, "No saved snapshot")
    end
end)

T.test("malformed slot records become the no saved snapshot state", function()
    local GGM = loadUI()
    local cases = {
        function(slot) slot.inventorySlotID = "1" end,
        function(slot) slot.itemID = 4001; slot.itemLink = false end,
        function(slot) slot.itemID = false; slot.itemLink = "not-empty" end,
        function(slot) slot.itemID = nil; slot.itemLink = nil end,
    }

    for _, makeMalformed in ipairs(cases) do
        local record = makeRecord(GGM)
        makeMalformed(record.gear.slots.HEAD)
        local model = GGM.BuildSnapshotViewModel(record)
        T.assertFalse(model.hasSnapshot)
        T.assertEqual(model.emptyStateText, "No saved snapshot")
    end
end)

local function newControl()
    local control = { text = nil, visible = false, scripts = {} }
    function control:SetText(text)
        self.text = text
        local changed = self.scripts.OnTextChanged
        if changed then changed(self, true) end
    end
    function control:GetText() return self.text or "" end
    function control:Show() self.visible = true end
    function control:Hide() self.visible = false end
    function control:SetSize() end
    function control:SetPoint() end
    function control:SetClampedToScreen() end
    function control:SetJustifyH() end
    function control:SetAutoFocus() end
    function control:SetHeight(height) self.height = height end
    function control:SetWidth(width) self.width = width end
    function control:SetScript(name, callback) self.scripts[name] = callback end
    function control:RegisterForClicks() end
    function control:SetDesaturated(value) self.desaturated = value end
    function control:SetAlpha(value) self.alpha = value end
    function control:SetTexture(value) self.texture = value end
    function control:CreateFontString() return newControl() end
    function control:CreateTexture() return newControl() end
    return control
end

local function makeBrowserAPI()
    local api = {
        UIParent = newControl(),
        CreateFrame = function(_, name, parent)
            local frame = newControl()
            frame.name, frame.parent = name, parent
            frame.TitleText = newControl()
            function frame:SetScrollChild(child) self.scrollChild = child end
            return frame
        end,
        date = function(_, timestamp) return "saved-" .. tostring(timestamp) end,
        GetItemIcon = function(itemID) return "item-icon:" .. tostring(itemID) end,
        GetInventorySlotInfo = function(slotName) return 1, "slot-icon:" .. slotName end,
    }
    return api
end

local function makeDB(GGM, records)
    local db = { schemaVersion = GGM.SCHEMA_VERSION, characters = {} }
    for _, record in ipairs(records or {}) do
        db.characters[record.identity.key] = record
    end
    return db
end

T.test("guild gear browser shows the no saved guild gear state for an empty database", function()
    local GGM = loadUI()
    local frame = GGM.ShowGuildGearBrowserWindow(makeBrowserAPI(), makeDB(GGM))

    T.assertTrue(frame.visible)
    T.assertEqual(frame.listEmpty.text, "No saved guild gear")
    T.assertEqual(frame.detailEmpty.text, "No saved guild gear")
    T.assertEqual(#frame.slotButtons, #GGM.TRACKED_SLOTS)
    T.assertNil(frame.navigationTabs)
    T.assertNil(frame.placeholderPages)
end)

T.test("guild gear browser keeps search text and shows no characters found after refresh", function()
    local GGM = loadUI()
    local record = makeRecord(GGM)
    local api = makeBrowserAPI()
    local frame = GGM.ShowGuildGearBrowserWindow(api, makeDB(GGM, { record }))

    frame.searchBox:SetText("missing-name")
    T.assertEqual(frame.searchBox:GetText(), "missing-name")
    T.assertEqual(frame.listEmpty.text, "No characters found")
    T.assertEqual(frame.detailEmpty.text, "No characters found")
    T.assertNil(frame.selectedEntry)

    GGM.ShowGuildGearBrowserWindow(api, makeDB(GGM, { record }))
    T.assertEqual(frame.searchBox:GetText(), "missing-name")
    T.assertEqual(frame.listEmpty.text, "No characters found")
end)

T.test("guild gear browser rows show name and realm and selecting renders saved identity time and slots", function()
    local GGM = loadUI()
    local alpha = makeRecord(GGM)
    local beta = makeRecord(GGM)
    beta.identity = { key = "Beatrice-ArgentDawn", name = "Beatrice", realm = "ArgentDawn" }
    beta.gear.capturedAt = 1700000200
    local api = makeBrowserAPI()
    local frame = GGM.ShowGuildGearBrowserWindow(api, makeDB(GGM, { beta, alpha }))

    T.assertEqual(frame.listRows[1].label.text, "Alice - Silvermoon")
    T.assertEqual(frame.listRows[2].label.text, "Beatrice - ArgentDawn")
    frame.listRows[2].scripts.OnClick(frame.listRows[2])

    T.assertEqual(frame.selectedEntry.key, "Beatrice-ArgentDawn")
    T.assertEqual(frame.characterLine.text, "Beatrice")
    T.assertEqual(frame.realmLine.text, "ArgentDawn")
    T.assertEqual(frame.capturedLine.text, "Saved capture: saved-1700000200")
    T.assertEqual(frame.detailModel.key, "Beatrice-ArgentDawn")
    T.assertEqual(#frame.detailModel.slots, #GGM.TRACKED_SLOTS)
    for index, slot in ipairs(frame.detailModel.slots) do
        T.assertTrue(frame.slotButtons[index].visible)
        T.assertEqual(frame.slotButtons[index].key, slot.key)
        T.assertEqual(frame.slotButtons[index].itemID, slot.itemID)
    end
end)

T.test("guild gear browser gives a saved empty slot an explicit dimmed empty treatment", function()
    local GGM = loadUI()
    local record = makeRecord(GGM)
    record.gear.slots.OFF_HAND.itemID = false
    record.gear.slots.OFF_HAND.itemLink = false
    local frame = GGM.ShowGuildGearBrowserWindow(makeBrowserAPI(), makeDB(GGM, { record }))
    local offHandIndex
    for index, slot in ipairs(GGM.TRACKED_SLOTS) do
        if slot.key == "OFF_HAND" then offHandIndex = index; break end
    end

    local emptySlot = frame.slotButtons[offHandIndex]
    T.assertTrue(emptySlot.visible)
    T.assertTrue(emptySlot.empty)
    T.assertTrue(emptySlot.icon.desaturated)
    T.assertEqual(emptySlot.icon.alpha, 0.35)
    T.assertEqual(emptySlot.label.text, "OFF_HAND (empty)")
end)

T.test("opening and selecting browser entries never inspects, requests, captures, writes, or sends", function()
    local GGM = loadUI()
    local first, second = makeRecord(GGM), makeRecord(GGM)
    second.identity = { key = "Beatrice-ArgentDawn", name = "Beatrice", realm = "ArgentDawn" }
    local forbidden = function() error("browser interaction must remain local and read-only") end
    for _, name in ipairs({
        "InspectUnit", "NotifyInspect", "RequestCompleteSnapshot", "CaptureAndStoreLocalPlayer",
        "CapturePlayerGearSnapshot", "SaveCompleteCharacterRecord", "UpdateConfirmedCharacterSlot",
        "ApplyReceivedCharacterSlot", "SaveReceivedCompleteCharacterRecord", "SendAddonMessage",
        "PublishConfirmedSlot", "SendGuildSyncMessage",
    }) do
        GGM[name] = forbidden
    end
    local api = makeBrowserAPI()
    api.NotifyInspect = forbidden
    api.SendAddonMessage = forbidden
    local before = first.gear.slots.HEAD.itemID
    local frame = GGM.ShowGuildGearBrowserWindow(api, makeDB(GGM, { first, second }))

    frame.listRows[2].scripts.OnClick(frame.listRows[2])

    T.assertEqual(frame.selectedEntry.key, "Beatrice-ArgentDawn")
    T.assertEqual(first.gear.slots.HEAD.itemID, before)
end)

T.test("ggm slash command opens the local guild gear browser", function()
    local GGM = loadUI()
    local db = makeDB(GGM)
    local calledApi, calledDB
    GGM.db = db
    GGM.ShowGuildGearBrowserWindow = function(api, receivedDB)
        calledApi, calledDB = api, receivedDB
    end
    local api = { SlashCmdList = {} }

    GGM.RegisterSnapshotTestSlashCommand(api)
    api.SlashCmdList.GUILDGEARMEMORY("")

    T.assertTrue(calledApi == api)
    T.assertTrue(calledDB == db)
end)

T.test("snapshot slash command can explicitly request exactly one named character", function()
    local GGM = loadUI()
    local requestedSync, requestedTarget
    local api = { SlashCmdList = {} }
    local sync = { marker = "sync" }
    GGM.guildSync = sync
    GGM.RequestCompleteSnapshot = function(activeSync, target)
        requestedSync, requestedTarget = activeSync, target
        return true, nil
    end

    GGM.RegisterSnapshotTestSlashCommand(api)
    api.SlashCmdList.GUILDGEARMEMORY("request Alice-Silvermoon")

    T.assertTrue(requestedSync == sync)
    T.assertEqual(requestedTarget.key, "Alice-Silvermoon")
    T.assertEqual(requestedTarget.name, "Alice")
    T.assertEqual(requestedTarget.realm, "Silvermoon")
    T.assertNil(requestedTarget.guid)
    T.assertNil(GGM.lastSyncError)
end)

T.test("snapshot slash command rejects malformed requests without sending", function()
    local GGM = loadUI()
    local sendCount = 0
    local api = { SlashCmdList = {} }
    GGM.guildSync = {}
    GGM.RequestCompleteSnapshot = function()
        sendCount = sendCount + 1
        return true, nil
    end

    GGM.RegisterSnapshotTestSlashCommand(api)
    api.SlashCmdList.GUILDGEARMEMORY("request Alice")

    T.assertEqual(sendCount, 0)
    T.assertEqual(GGM.lastSyncError, "request-target-invalid")
end)
