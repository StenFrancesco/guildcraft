local T = require("tests.testlib")
local makeRecord

local function loadUI()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/Constants.lua", GGM)
    T.loadAddonFile("GuildGearMemory/GearSnapshot.lua", GGM)
    T.loadAddonFile("GuildGearMemory/Storage.lua", GGM)
    T.loadAddonFile("GuildGearMemory/SavedCharacterModel.lua", GGM)
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

T.test("guild gear browser ownership filter partitions locally owned keys without mutation", function()
    local GGM = loadUI()
    local entries = {
        { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon" },
        { key = "Beatrice-ArgentDawn", name = "Beatrice", realm = "ArgentDawn" },
        { key = "Charlie-Stormrage", name = "Charlie", realm = "Stormrage" },
    }
    local db = { localCharacters = { [entries[1].key] = true, [entries[2].key] = true } }
    local before = { [entries[1].key] = true, [entries[2].key] = true }

    local mine = GGM.FilterGuildGearBrowserOwnership(entries, db, "Mine")
    local guild = GGM.FilterGuildGearBrowserOwnership(entries, db, "Guild")

    T.assertEqual(#mine, 2)
    T.assertEqual(mine[1].key, entries[1].key)
    T.assertEqual(mine[2].key, entries[2].key)
    T.assertEqual(#guild, 1)
    T.assertEqual(guild[1].key, entries[3].key)
    T.assertTrue(db.localCharacters[entries[1].key] == before[entries[1].key])
    T.assertTrue(db.localCharacters[entries[2].key] == before[entries[2].key])
    T.assertNil(db.localCharacters[entries[3].key])
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
    function control:SetTextColor(...) self.textColor = { ... } end
    function control:GetText() return self.text or "" end
    function control:Show() self.visible = true end
    function control:Hide() self.visible = false end
    function control:SetSize(width, height)
        self.width, self.height = width, height
    end
    function control:SetPoint(point, relativeTo, relativePoint, x, y)
        self.point = { point = point, relativeTo = relativeTo, relativePoint = relativePoint, x = x, y = y }
    end
    function control:SetAllPoints(relativeTo) self.allPointsTo = relativeTo end
    function control:SetClampedToScreen() end
    function control:SetJustifyH() end
    function control:SetAutoFocus() end
    function control:SetHeight(height) self.height = height end
    function control:SetWidth(width) self.width = width end
    function control:SetScript(name, callback) self.scripts[name] = callback end
    function control:RegisterForClicks() end
    function control:SetDesaturated(value) self.desaturated = value end
    function control:SetAlpha(value) self.alpha = value end
    function control:SetTexture(value) self.texture = value; self.atlas = nil end
    function control:SetColorTexture(...) self.color = { ... }; self.texture = nil; self.atlas = nil end
    function control:SetAtlas(value) self.atlas = value; self.texture = nil end
    function control:SetTexCoord(...) self.texCoord = { ... } end
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

local function makeModelBrowserAPI(failModelCreation)
    local api = makeBrowserAPI()
    api.C_CreatureInfo = { GetRaceInfo = function(raceID)
        if raceID == 1 then return { raceName = "Human", clientFileString = "Human" } end
        if raceID == 2 then return { raceName = "Orc", clientFileString = "Orc" } end
    end }
    api.C_Texture = { GetAtlasInfo = function(atlas)
        if atlas == "raceicon128-human-male" or atlas == "raceicon128-orc-female" then return {} end
    end }
    local createFrame = api.CreateFrame
    api.CreateFrame = function(frameType, name, parent)
        if failModelCreation and frameType == "Frame" and parent
            and parent.width == 570 and parent.height == 438 then return nil end
        return createFrame(frameType, name, parent)
    end
    return api
end

local function setSavedModelIdentity(record)
    record.identity.raceID, record.identity.sex, record.identity.displayID = 1, 2, 101
    local visualSlotIDs = { HEAD = 1, SHOULDER = 3, CHEST = 5, WAIST = 6, LEGS = 7, FEET = 8,
        WRIST = 9, HANDS = 10, BACK = 15, MAIN_HAND = 16, OFF_HAND = 17, TABARD = 19 }
    for key, id in pairs(visualSlotIDs) do record.gear.slots[key].inventorySlotID = id end
end

local function makeDB(GGM, records)
    local db = { schemaVersion = GGM.SCHEMA_VERSION, characters = {} }
    for _, record in ipairs(records or {}) do
        db.characters[record.identity.key] = record
    end
    return db
end

local function showBrowser(GGM, api, db)
    GGM.ShowGuildGearBrowserWindow(api, db)
    return GGM.guildGearBrowserFrame
end

T.test("guild gear browser shows the no saved guild gear state for an empty database", function()
    local GGM = loadUI()
    local frame = showBrowser(GGM, makeBrowserAPI(), makeDB(GGM))

    T.assertTrue(frame.visible)
    T.assertEqual(frame.listEmpty.text, "No saved guild gear")
    T.assertEqual(frame.detailEmpty.text, "No saved guild gear")
    T.assertEqual(#frame.slotButtons, #GGM.TRACKED_SLOTS)
    T.assertNotNil(frame.navigationTabs)
    T.assertNotNil(frame.placeholderPages)
end)

T.test("guild gear browser ownership toggle defaults to Guild and switches filtered entries", function()
    local GGM = loadUI()
    local mineA, mineB, guild = makeRecord(GGM), makeRecord(GGM), makeRecord(GGM)
    mineB.identity = { key = "Beatrice-ArgentDawn", name = "Beatrice", realm = "ArgentDawn" }
    guild.identity = { key = "Charlie-Stormrage", name = "Charlie", realm = "Stormrage" }
    local db = makeDB(GGM, { mineA, mineB, guild })
    db.localCharacters = { [mineA.identity.key] = true, [mineB.identity.key] = true }
    local frame = showBrowser(GGM, makeBrowserAPI(), db)

    T.assertEqual(frame.browserView, "Guild")
    T.assertNotNil(frame.guildButton)
    T.assertNotNil(frame.mineButton)
    T.assertNotNil(frame.mineButton.hover)
    T.assertEqual(#frame.mineButton.border, 4)
    for _, button in ipairs({ frame.mineButton, frame.guildButton }) do
        T.assertTrue(button.point.x >= frame.searchLabel.point.x + frame.searchLabel.width + 8,
            "view controls must sit beyond the search label region")
        T.assertTrue(button.point.x + button.width <= frame.searchPanel.width,
            "view controls must stay inside the search panel")
    end
    T.assertTrue(frame.guildButton.selected)
    T.assertEqual(#frame.filteredEntries, 1)
    T.assertEqual(frame.filteredEntries[1].key, guild.identity.key)

    frame.searchBox:SetText("Alice")
    frame.mineButton.scripts.OnClick(frame.mineButton)
    T.assertEqual(frame.browserView, "Mine")
    T.assertEqual(frame.searchBox:GetText(), "Alice")
    T.assertEqual(#frame.filteredEntries, 1)
    T.assertEqual(frame.selectedEntry.key, mineA.identity.key)
    T.assertTrue(frame.mineButton.selected)
    T.assertTrue(frame.mineButton.label.text == "Mine")

    frame.searchBox:SetText("")
    local selectSecond
    for _, row in ipairs(frame.listRows) do
        if row.entry.key == mineB.identity.key then selectSecond = row end
    end
    T.assertNotNil(selectSecond)
    selectSecond.scripts.OnClick(selectSecond)
    T.assertEqual(frame.selectedEntry.key, mineB.identity.key)
    frame.guildButton.scripts.OnClick(frame.guildButton)
    T.assertEqual(frame.selectedEntry.key, guild.identity.key)
end)

T.test("guild gear browser distinguishes empty Mine and Guild views from unmatched searches", function()
    local GGM = loadUI()
    local owned = makeRecord(GGM)
    local db = makeDB(GGM, { owned })
    db.localCharacters = { [owned.identity.key] = true }
    local frame = showBrowser(GGM, makeBrowserAPI(), db)

    frame.mineButton.scripts.OnClick(frame.mineButton)
    T.assertEqual(#frame.filteredEntries, 1)
    frame.guildButton.scripts.OnClick(frame.guildButton)
    T.assertEqual(frame.listEmpty.text, "No saved guild gear")
    T.assertEqual(frame.detailEmpty.text, "No saved guild gear")
    frame.mineButton.scripts.OnClick(frame.mineButton)
    frame.searchBox:SetText("missing")
    T.assertEqual(frame.listEmpty.text, "No characters found")
    T.assertEqual(frame.detailEmpty.text, "No characters found")

    local emptyFrame = showBrowser(GGM, makeBrowserAPI(), makeDB(GGM))
    emptyFrame.mineButton.scripts.OnClick(emptyFrame.mineButton)
    T.assertEqual(emptyFrame.listEmpty.text, "No saved personal gear")
    T.assertEqual(emptyFrame.detailEmpty.text, "No saved personal gear")
end)

T.test("guild gear browser slot buttons fit inside the detail panel with a gap after the list", function()
    local GGM = loadUI()
    local frame = showBrowser(GGM, makeBrowserAPI(), makeDB(GGM, { makeRecord(GGM) }))
    local listRight = 20 + 250
    local detailRight = 900 - 20
    local gutter = 12
    local topInset, bottomInset = 32, 20

    for index, button in ipairs(frame.slotButtons) do
        local point = button.point
        T.assertTrue(point ~= nil, "slot button must have a recorded layout point")
        T.assertTrue(point.relativeTo == frame.gearPanel, "slot button must be positioned relative to the equipment panel")
        T.assertEqual(point.point, "CENTER")
        local left = 292 + point.x - button.width / 2
        local right = 292 + point.x + button.width / 2
        local top = 156 - point.y - button.height / 2
        local bottom = 156 - point.y + button.height / 2
        T.assertTrue(left >= listRight + gutter, "slot " .. index .. " overlaps or crowds the character list")
        T.assertTrue(right <= detailRight, "slot " .. index .. " exceeds the detail panel right edge")
        T.assertTrue(top >= topInset, "slot " .. index .. " exceeds the detail panel top edge")
        T.assertTrue(bottom <= 610 - bottomInset, "slot " .. index .. " exceeds the detail panel bottom edge")
    end
end)

T.test("guild gear browser keeps search text and shows no characters found after refresh", function()
    local GGM = loadUI()
    local record = makeRecord(GGM)
    local api = makeBrowserAPI()
    local frame = showBrowser(GGM, api, makeDB(GGM, { record }))

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
    local frame = showBrowser(GGM, api, makeDB(GGM, { beta, alpha }))

    T.assertEqual(frame.listRows[1].label.text, "Alice - Silvermoon")
    T.assertEqual(frame.listRows[2].label.text, "Beatrice - ArgentDawn")
    frame.listRows[1].scripts.OnClick(frame.listRows[1])
    T.assertEqual(frame.selectedEntry.key, "Alice-Silvermoon")
    T.assertEqual(frame.characterLine.text, "Alice")

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

T.test("browser detail carries the saved record for 2D portrait rendering", function()
    local GGM = loadUI()
    local record = makeRecord(GGM)
    local detail = GGM.BuildGuildGearBrowserDetail(record, makeBrowserAPI())

    T.assertEqual(detail.modelState, "render-unavailable")
    T.assertTrue(detail.modelInput == record)
    T.assertEqual(detail.completenessText, "Complete")
    T.assertEqual(#detail.slots, #GGM.TRACKED_SLOTS)
end)

T.test("browser portrait selection updates from A to B and clears on no selection", function()
    local GGM = loadUI()
    local alpha, beta = makeRecord(GGM), makeRecord(GGM)
    beta.identity = { key = "Beatrice-ArgentDawn", name = "Beatrice", realm = "ArgentDawn" }
    setSavedModelIdentity(beta)
    beta.identity.raceID, beta.identity.sex, beta.identity.displayID = 2, 3, 202
    beta.gear.capturedAt = 1700000200
    local api = makeModelBrowserAPI()
    local frame = showBrowser(GGM, api, makeDB(GGM, { alpha, beta }))

    T.assertTrue(frame.characterModelView.model.visible)
    T.assertEqual(frame.characterModelView.caption.text, "Saved gear - portrait not available")
    T.assertTrue(frame.characterModelView.questionMark.visible)
    frame.listRows[2].scripts.OnClick(frame.listRows[2])
    T.assertTrue(frame.characterModelView.model.visible)
    T.assertFalse(frame.modelUnavailableLabel.visible)
    T.assertEqual(frame.characterModelView.portrait.atlas, "raceicon128-orc-female")
    T.assertEqual(frame.characterLine.text, "Beatrice")
    T.assertEqual(frame.capturedLine.text, "Saved capture: saved-1700000200")
    T.assertEqual(frame.completenessLine.text, "Complete")
    frame.searchBox:SetText("no match")
    T.assertFalse(frame.characterModelView.model.visible)
    T.assertFalse(frame.modelUnavailableLabel.visible)
    T.assertNil(frame.characterModelView.portrait.atlas)
    T.assertEqual(frame.characterModelView.raceLabel.text, "")
    T.assertFalse(frame.characterLine.visible)
end)

T.test("browser replaces one saved race portrait with another and clears it on empty selection", function()
    local GGM = loadUI()
    local alpha, beta = makeRecord(GGM), makeRecord(GGM)
    setSavedModelIdentity(alpha)
    beta.identity = { key = "Beatrice-ArgentDawn", name = "Beatrice", realm = "ArgentDawn" }
    setSavedModelIdentity(beta)
    beta.identity.raceID, beta.identity.sex, beta.identity.displayID = 2, 3, 202
    for _, slot in pairs(beta.gear.slots) do
        if slot.itemID ~= false then
            slot.itemID = slot.itemID + 1000
            slot.itemLink = "|Hitem:" .. slot.itemID .. "|h[Distinct]|h"
        end
    end
    local api = makeModelBrowserAPI()
    local frame = showBrowser(GGM, api, makeDB(GGM, { alpha, beta }))
    local view = frame.characterModelView.model
    T.assertTrue(view.visible)
    T.assertEqual(frame.characterModelView.portrait.atlas, "raceicon128-human-male")

    frame.listRows[2].scripts.OnClick(frame.listRows[2])
    T.assertTrue(view.visible)
    T.assertEqual(frame.characterModelView.portrait.atlas, "raceicon128-orc-female")
    T.assertEqual(frame.characterModelView.raceLabel.text, "Orc")

    frame.searchBox:SetText("no match")
    T.assertFalse(view.visible)
    T.assertNil(frame.characterModelView.portrait.atlas)
    T.assertEqual(frame.characterModelView.raceLabel.text, "")
end)

T.test("failed 2D portrait frame creation leaves saved detail visible with unavailable label", function()
    local GGM = loadUI()
    local record = makeRecord(GGM)
    setSavedModelIdentity(record)
    local frame = showBrowser(GGM, makeModelBrowserAPI(true), makeDB(GGM, { record }))

    T.assertNil(frame.characterModelView.model)
    T.assertTrue(frame.modelUnavailableLabel.visible)
    T.assertEqual(frame.modelUnavailableLabel.text, "2D paper doll unavailable")
    T.assertTrue(frame.characterLine.visible)
    T.assertTrue(frame.realmLine.visible)
    T.assertTrue(frame.capturedLine.visible)
    T.assertEqual(frame.capturedLine.text, "Saved capture: saved-1700000100")
    T.assertTrue(frame.completenessLine.visible)
    T.assertEqual(#frame.detailModel.slots, #GGM.TRACKED_SLOTS)
    for _, slot in ipairs(frame.slotButtons) do T.assertTrue(slot.visible) end
end)

T.test("missing saved display ID still renders the race portrait", function()
    local GGM = loadUI()
    local record = makeRecord(GGM)
    setSavedModelIdentity(record)
    record.identity.displayID = nil
    local frame = showBrowser(GGM, makeModelBrowserAPI(), makeDB(GGM, { record }))

    T.assertTrue(frame.characterModelView.model.visible)
    T.assertEqual(frame.characterModelView.portrait.atlas, "raceicon128-human-male")
    T.assertFalse(frame.modelUnavailableLabel.visible)
    T.assertTrue(frame.capturedLine.visible)
    T.assertEqual(#frame.detailModel.slots, #GGM.TRACKED_SLOTS)
end)

T.test("browser missing portrait data preserves incomplete and refresh-needed gear details and hides by tab", function()
    local GGM = loadUI()
    local legacy = makeRecord(GGM)
    legacy.identity.raceID, legacy.identity.sex, legacy.identity.displayID = nil, nil, nil
    legacy.complete, legacy.completeness, legacy.gear.complete = false, "incomplete", false
    legacy.gear.slots.SHIRT, legacy.gear.slots.TABARD, legacy.gear.slots.RANGED = nil, nil, nil
    local api = makeModelBrowserAPI()
    local frame = showBrowser(GGM, api, makeDB(GGM, { legacy }))

    T.assertEqual(frame.characterModelView.caption.text, "Saved gear - portrait not available")
    T.assertEqual(frame.completenessLine.text, "Incomplete")
    T.assertTrue(frame.capturedLine.text:find("Saved capture:", 1, true) == 1)
    T.assertTrue(frame.slotButtons[1].visible)
    T.assertEqual(#frame.detailModel.slots, #GGM.TRACKED_SLOTS)
    local refresh = makeRecord(GGM)
    refresh.complete, refresh.completeness, refresh.gear.complete = false, "incomplete", false
    refresh.refreshNeeded, refresh.incompleteReason, refresh.requiredBaselineSequence = true, "sequence-gap", 2
    GGM.ShowGuildGearBrowserWindow(api, makeDB(GGM, { refresh }))
    T.assertEqual(frame.completenessLine.text, "Refresh needed")
    frame.navigationTabs[2].scripts.OnClick(frame.navigationTabs[2])
    T.assertFalse(frame.characterModelView.model.visible)
    T.assertFalse(frame.modelUnavailableLabel.visible)
    frame.navigationTabs[1].scripts.OnClick(frame.navigationTabs[1])
    T.assertTrue(frame.characterModelView.model.visible)
    T.assertFalse(frame.modelUnavailableLabel.visible)
    T.assertEqual(frame.completenessLine.text, "Refresh needed")
end)

T.test("guild gear browser gives a saved empty slot an explicit dimmed empty treatment", function()
    local GGM = loadUI()
    local record = makeRecord(GGM)
    record.gear.slots.OFF_HAND.itemID = false
    record.gear.slots.OFF_HAND.itemLink = false
    local frame = showBrowser(GGM, makeBrowserAPI(), makeDB(GGM, { record }))
    local offHandIndex
    for index, slot in ipairs(GGM.TRACKED_SLOTS) do
        if slot.key == "OFF_HAND" then offHandIndex = index; break end
    end

    local emptySlot = frame.slotButtons[offHandIndex]
    T.assertTrue(emptySlot.visible)
    T.assertTrue(emptySlot.empty)
    T.assertTrue(emptySlot.icon.desaturated)
    T.assertEqual(emptySlot.icon.alpha, 0.42)
    T.assertEqual(emptySlot.key, "OFF_HAND")
    T.assertEqual(emptySlot.label.text, "Off hand")
    T.assertEqual(emptySlot.status.text, "Empty")
    T.assertTrue(emptySlot.itemLink == false)
    T.assertTrue(emptySlot.label.width <= 92)
    T.assertTrue(emptySlot.status.width <= 92)
end)

T.test("opening and selecting browser entries never inspects, requests, captures, writes, or sends", function()
    local GGM = loadUI()
    local first, second = makeRecord(GGM), makeRecord(GGM)
    second.identity = { key = "Beatrice-ArgentDawn", name = "Beatrice", realm = "ArgentDawn" }
    setSavedModelIdentity(first)
    setSavedModelIdentity(second)
    local forbidden = function() error("browser interaction must remain local and read-only") end
    for _, name in ipairs({
        "InspectUnit", "NotifyInspect", "CanInspect", "RequestCompleteSnapshot", "CaptureAndStoreLocalPlayer",
        "CapturePlayerGearSnapshot", "SaveCompleteCharacterRecord", "UpdateConfirmedCharacterSlot",
        "ApplyReceivedCharacterSlot", "SaveReceivedCompleteCharacterRecord", "SendAddonMessage",
        "PublishConfirmedSlot", "SendGuildSyncMessage",
    }) do
        GGM[name] = forbidden
    end
    local api = makeModelBrowserAPI()
    api.NotifyInspect = forbidden
    api.InspectUnit = forbidden
    api.CanInspect = forbidden
    api.GetInventoryItemID = forbidden
    api.GetInventoryItemLink = forbidden
    api.SendAddonMessage = forbidden
    local db = makeDB(GGM, { first, second })
    local function copyTable(value)
        if type(value) ~= "table" then return value end
        local copy = {}
        for key, child in pairs(value) do copy[copyTable(key)] = copyTable(child) end
        return copy
    end
    local function tablesEqual(left, right)
        if type(left) ~= type(right) then return false end
        if type(left) ~= "table" then return left == right end
        for key, value in pairs(left) do
            if not tablesEqual(value, right[key]) then return false end
        end
        for key in pairs(right) do
            if left[key] == nil then return false end
        end
        return true
    end
    local before = copyTable(db)
    local frame = showBrowser(GGM, api, db)

    frame.searchBox:SetText("beatrice")
    T.assertEqual(#frame.filteredEntries, 1)
    T.assertEqual(frame.filteredEntries[1].key, "Beatrice-ArgentDawn")

    frame.listRows[1].scripts.OnClick(frame.listRows[1])

    frame.navigationTabs[2].scripts.OnClick(frame.navigationTabs[2])
    frame.navigationTabs[1].scripts.OnClick(frame.navigationTabs[1])

    T.assertEqual(frame.selectedEntry.key, "Beatrice-ArgentDawn")
    T.assertTrue(tablesEqual(db, before), "browser interaction must not mutate any SavedVariables data")
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
    local requestedSync, requestedTarget, requestCount, browserCount
    requestCount, browserCount = 0, 0
    local api = { SlashCmdList = {} }
    local sync = { marker = "sync" }
    GGM.guildSync = sync
    GGM.ShowGuildGearBrowserWindow = function()
        browserCount = browserCount + 1
    end
    GGM.RequestCompleteSnapshot = function(activeSync, target)
        requestCount = requestCount + 1
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
    T.assertEqual(requestCount, 1)
    T.assertEqual(browserCount, 0)
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

T.test("paper doll layout uses the requested left right and bottom slot order", function()
    local GGM = loadUI()
    local expected = {
        left = { "HEAD", "NECK", "SHOULDER", "BACK", "CHEST", "SHIRT", "TABARD", "WRIST" },
        right = { "HANDS", "WAIST", "LEGS", "FEET", "FINGER_1", "FINGER_2", "TRINKET_1", "TRINKET_2" },
        bottom = { "MAIN_HAND", "OFF_HAND", "RANGED" },
    }
    local frame = showBrowser(GGM, makeBrowserAPI(), makeDB(GGM, { makeRecord(GGM) }))
    T.assertNil(frame.characterModel)
    for group, keys in pairs(expected) do
        for index, key in ipairs(keys) do
            T.assertEqual(GGM.BROWSER_SLOT_LAYOUT[key].group, group)
            T.assertEqual(GGM.BROWSER_SLOT_LAYOUT[key].order, index)
        end
    end
    for index, slot in ipairs(GGM.TRACKED_SLOTS) do
        local button = frame.slotButtons[index]
        local layout = GGM.BROWSER_SLOT_LAYOUT[slot.key]
        T.assertEqual(button.key, slot.key)
        T.assertEqual(button.paperDollGroup, layout.group)
        T.assertEqual(button.paperDollOrder, layout.order)
    end
end)

T.test("incomplete detail marks migrated missing slots unavailable, not empty", function()
    local GGM = loadUI()
    local record = makeRecord(GGM)
    record.complete, record.completeness, record.gear.complete = false, "incomplete", false
    record.gear.slots.SHIRT, record.gear.slots.TABARD, record.gear.slots.RANGED = nil, nil, nil
    local entries = GGM.BuildGuildGearBrowserEntries(makeDB(GGM, { record }))
    T.assertEqual(#entries, 1)
    local model = GGM.BuildGuildGearBrowserDetail(entries[1].record, {})
    T.assertTrue(model.hasRecord)
    T.assertFalse(model.complete)
    T.assertEqual(model.completenessText, "Incomplete")
    local found = {}
    for _, row in ipairs(model.slots) do
        found[row.key] = row
    end
    T.assertTrue(found.SHIRT.unavailable)
    T.assertFalse(found.SHIRT.empty)
    T.assertEqual(found.SHIRT.valueText, "No data")
    T.assertFalse(found.HEAD.unavailable)
    local frame = showBrowser(GGM, makeBrowserAPI(), makeDB(GGM, { record }))
    T.assertEqual(frame.completenessLine.text, "Incomplete")
    local shirtIndex
    for index, slot in ipairs(GGM.TRACKED_SLOTS) do if slot.key == "SHIRT" then shirtIndex = index end end
    T.assertTrue(frame.slotButtons[shirtIndex].unavailable)
    T.assertEqual(frame.slotButtons[shirtIndex].label.text, "Shirt")
    T.assertEqual(frame.slotButtons[shirtIndex].status.text, "No data")
    T.assertTrue(frame.slotButtons[shirtIndex].label.width <= 92)
    T.assertTrue(frame.slotButtons[shirtIndex].status.width <= 92)
end)

T.test("sequence-gap browser records remain refresh-needed with all values and bounded captions", function()
    local GGM = loadUI()
    local record = makeRecord(GGM)
    record.complete, record.completeness = false, "incomplete"
    record.refreshNeeded, record.incompleteReason = true, "sequence-gap"
    record.requiredBaselineSequence = 2
    record.gear.complete = false
    record.gear.slots.OFF_HAND.itemID, record.gear.slots.OFF_HAND.itemLink = false, false
    local frame = showBrowser(GGM, makeBrowserAPI(), makeDB(GGM, { record }))
    T.assertTrue(frame.detailModel.hasRecord)
    T.assertFalse(frame.detailModel.complete)
    T.assertTrue(frame.detailModel.refreshNeeded)
    T.assertEqual(frame.detailModel.completenessText, "Refresh needed")
    T.assertEqual(frame.completenessLine.text, "Refresh needed")
    T.assertEqual(#frame.detailModel.slots, #GGM.TRACKED_SLOTS)
    for index, row in ipairs(frame.detailModel.slots) do
        local button = frame.slotButtons[index]
        T.assertFalse(row.unavailable)
        T.assertTrue(button.label.width <= 92)
        T.assertTrue(button.status.width <= 92)
        T.assertTrue(#button.label.text <= 9)
        T.assertTrue(#(button.status.text or "") <= 7)
        T.assertEqual(button.key, row.key)
        T.assertEqual(button.itemLink, row.itemLink)
    end
    local offHandIndex
    for index, slot in ipairs(GGM.TRACKED_SLOTS) do if slot.key == "OFF_HAND" then offHandIndex = index end end
    T.assertEqual(frame.slotButtons[offHandIndex].label.text, "Off hand")
    T.assertEqual(frame.slotButtons[offHandIndex].status.text, "Empty")

    local db = makeDB(GGM, { record })
    local baseline = { complete = true, capturedAt = 1700001000, slots = record.gear.slots }
    T.assertTrue(GGM.SaveReceivedCompleteCharacterRecord(db, record.identity, baseline, 7))
    frame = showBrowser(GGM, makeBrowserAPI(), db)
    T.assertTrue(frame.detailModel.complete)
    T.assertFalse(frame.detailModel.refreshNeeded)
    T.assertEqual(frame.completenessLine.text, "Complete")
end)
