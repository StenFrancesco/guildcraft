local T = require("tests.testlib")
local makeRecord, compactRecord

local function loadUI()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/Constants.lua", GGM)
    T.loadAddonFile("GuildGearMemory/GearData.lua", GGM)
    T.loadAddonFile("GuildGearMemory/CharacterIdentity.lua", GGM)
    T.loadAddonFile("GuildGearMemory/GearSnapshot.lua", GGM)
    T.loadAddonFile("GuildGearMemory/ProfessionSnapshot.lua", GGM)
    T.loadAddonFile("GuildGearMemory/ProfessionIndex.lua", GGM)
    T.loadAddonFile("GuildGearMemory/Storage.lua", GGM)
    T.loadAddonFile("GuildGearMemory/SavedCharacterModel.lua", GGM)
    T.loadAddonFile("GuildGearMemory/RecipeDetails.lua", GGM)
    T.loadAddonFile("GuildGearMemory/RecipeDetailsUI.lua", GGM)
    T.loadAddonFile("GuildGearMemory/SnapshotTestUI.lua", GGM)
    return GGM
end

T.test("guild gear browser includes only valid records sorted by name then realm without mutation", function()
    local GGM = loadUI()
    local zulu = compactRecord(GGM, makeRecord(GGM))
    zulu.identity = { key = "zULu-Zenith", name = "zULu", realm = "Zenith" }
    local alpha = compactRecord(GGM, makeRecord(GGM))
    alpha.identity = { key = "ALPHA-amber", name = "ALPHA", realm = "amber" }
    local sameNameFirstRealm = compactRecord(GGM, makeRecord(GGM))
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
    local beforeZuluName, beforeAlphaSlot = zulu.identity.name, alpha.gear.slots[1]

    local entries = GGM.BuildGuildGearBrowserEntries(db)

    T.assertEqual(#entries, 3)
    T.assertEqual(entries[1].key, "ALPHA-amber")
    T.assertEqual(entries[2].key, "Alpha-Azure")
    T.assertEqual(entries[3].key, "zULu-Zenith")
    T.assertTrue(entries[1].record == alpha)
    T.assertTrue(db.characters[alpha.identity.key] == alpha)
    T.assertEqual(zulu.identity.name, beforeZuluName)
    T.assertEqual(alpha.gear.slots[1], beforeAlphaSlot)
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
    local record = compactRecord(GGM, makeRecord(GGM))
    record.gear.slots[17] = nil
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
            T.assertNil(row.itemID)
            T.assertNil(row.itemLink)
            T.assertEqual(row.icon, "texture:" .. trackedSlot.inventoryName)
            T.assertEqual(row.slotTexture, "texture:" .. trackedSlot.inventoryName)
        else
            local savedID = 4000 + index
            T.assertFalse(row.empty)
            T.assertEqual(row.itemID, savedID)
            T.assertEqual(row.itemLink, "|Hitem:" .. savedID .. "|h[Item " .. savedID .. "]|h")
            T.assertEqual(row.icon, "icon:" .. savedID)
        end
    end
    T.assertEqual(#iconCalls, #GGM.TRACKED_SLOTS - 1)
end)

T.test("guild gear browser detail rejects invalid or incomplete records", function()
    local GGM = loadUI()
    local malformed = compactRecord(GGM, makeRecord(GGM))
    malformed.gear.slots[1] = "item:invalid"

    T.assertFalse(GGM.BuildGuildGearBrowserDetail(nil, {}).hasRecord)
    T.assertFalse(GGM.BuildGuildGearBrowserDetail({ complete = false }, {}).hasRecord)
    T.assertFalse(GGM.BuildGuildGearBrowserDetail(malformed, {}).hasRecord)
end)

T.test("guild gear browser detail falls back to slot texture when item icon is unavailable", function()
    local GGM = loadUI()
    local record = compactRecord(GGM, makeRecord(GGM))
    local model = GGM.BuildGuildGearBrowserDetail(record, {
        GetItemIcon = function() return nil end,
        GetInventorySlotInfo = function() return 1, "slot-texture" end,
    })

    T.assertEqual(model.slots[1].itemID, 4001)
    T.assertEqual(model.slots[1].itemLink, "|Hitem:4001|h[Item 4001]|h")
    T.assertEqual(model.slots[1].icon, "slot-texture")
end)

makeRecord = function(GGM)
    local slots = {}

    for index, slot in ipairs(GGM.TRACKED_SLOTS) do
        slots[slot.key] = {
            inventorySlotID = slot.inventorySlotID,
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

compactRecord = function(GGM, record)
    local snapshot = { complete = true, capturedAt = record.gear.capturedAt, slots = {} }
    for _, trackedSlot in ipairs(GGM.TRACKED_SLOTS) do
        local slot = record.gear.slots[trackedSlot.key]
        if slot then
            snapshot.slots[trackedSlot.key] = {
                inventorySlotID = trackedSlot.inventorySlotID,
                itemID = slot.itemID,
                itemLink = slot.itemLink,
                unavailable = slot.unavailable,
            }
        end
    end
    record.gear = assert(GGM.CreateStoredGear(snapshot))
    return record
end

T.test("compact browser and snapshot models derive equipped empty and unavailable states", function()
    local GGM = loadUI()
    local record = compactRecord(GGM, makeRecord(GGM))
    record.gear.slots[17] = nil
    record.gear.slots[18] = nil
    record.gear.unavailableSlots[18] = true
    local api = {
        C_Item = { GetItemNameByID = function(itemID) return "Named " .. itemID end },
        GetItemIcon = function(itemID) return "icon:" .. itemID end,
        GetInventorySlotInfo = function(slotName)
            for _, slot in ipairs(GGM.TRACKED_SLOTS) do
                if slot.inventoryName == slotName then return slot.inventorySlotID, "texture:" .. slotName end
            end
        end,
    }
    local detail = GGM.BuildGuildGearBrowserDetail(record, api)
    T.assertTrue(detail.hasRecord)
    local byKey = {}
    for _, row in ipairs(detail.slots) do byKey[row.key] = row end
    T.assertEqual(byKey.HEAD.itemID, 4001)
    T.assertEqual(byKey.HEAD.itemLink, "|Hitem:4001|h[Named 4001]|h")
    T.assertEqual(byKey.HEAD.icon, "icon:4001")
    T.assertEqual(byKey.OFF_HAND.statusText, "Empty")
    T.assertTrue(byKey.OFF_HAND.empty)
    T.assertEqual(byKey.RANGED.statusText, "No data")
    T.assertTrue(byKey.RANGED.unavailable)
    T.assertEqual(record.gear.slots[1], "item:4001")

    local view = GGM.BuildSnapshotViewModel(record, nil, api)
    T.assertTrue(view.hasSnapshot)
    T.assertEqual(view.slots[1].valueText, "|Hitem:4001|h[Named 4001]|h")
    T.assertEqual(view.slots[19].valueText, "No data")
end)

T.test("sequence-gap compact baseline remains visible while malformed stale data is hidden", function()
    local GGM = loadUI()
    local record = compactRecord(GGM, makeRecord(GGM))
    record.complete, record.completeness = false, "incomplete"
    record.refreshNeeded, record.incompleteReason = true, "sequence-gap"
    record.requiredBaselineSequence, record.confirmedSequence = 2, 1
    record.gear.complete = false
    local db = { schemaVersion = GGM.SCHEMA_VERSION, characters = { [record.identity.key] = record } }
    local entries = GGM.BuildGuildGearBrowserEntries(db)
    T.assertEqual(#entries, 1)
    local model = GGM.BuildGuildGearBrowserDetail(entries[1].record, {})
    T.assertTrue(model.hasRecord)
    T.assertEqual(model.completenessText, "Refresh needed")
    T.assertEqual(model.slots[1].itemID, 4001)

    local malformedCases = {
        function(gear) gear.slots[1] = "item:broken" end,
        function(gear) gear.slots[99] = "item:1" end,
        function(gear) gear.unavailableSlots[1] = true end,
    }
    for _, makeMalformed in ipairs(malformedCases) do
        local malformed = compactRecord(GGM, makeRecord(GGM))
        malformed.complete, malformed.completeness = false, "incomplete"
        malformed.refreshNeeded, malformed.incompleteReason = true, "sequence-gap"
        malformed.requiredBaselineSequence, malformed.confirmedSequence = 2, 1
        malformed.gear.complete = false
        makeMalformed(malformed.gear)
        entries = GGM.BuildGuildGearBrowserEntries({
            schemaVersion = GGM.SCHEMA_VERSION,
            characters = { [malformed.identity.key] = malformed },
        })
        T.assertEqual(#entries, 0)
    end
end)

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
    local record = compactRecord(GGM, makeRecord(GGM))

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
    T.assertEqual(model.slots[1].valueText, "|Hitem:4001|h[Item 4001]|h")
end)

T.test("snapshot view model displays an empty saved equipment slot explicitly", function()
    local GGM = loadUI()
    local record = compactRecord(GGM, makeRecord(GGM))
    record.gear.slots[17] = nil

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
        local record = compactRecord(GGM, makeRecord(GGM))
        makeMalformed(record)
        local model = GGM.BuildSnapshotViewModel(record)
        T.assertFalse(model.hasSnapshot)
        T.assertEqual(model.emptyStateText, "No saved snapshot")
    end
end)

T.test("malformed slot records become the no saved snapshot state", function()
    local GGM = loadUI()
    local cases = {
        function(gear) gear.slots[99] = "item:1" end,
        function(gear) gear.slots[1] = "item:broken" end,
        function(gear) gear.slots[1], gear.unavailableSlots[1] = "item:1", true end,
        function(gear) gear.unavailableSlots[1] = true end,
    }

    for _, makeMalformed in ipairs(cases) do
        local record = compactRecord(GGM, makeRecord(GGM))
        makeMalformed(record.gear)
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
    function control:GetStringHeight() return #self:GetText() > 80 and 56 or 14 end
    function control:Show() self.visible = true end
    function control:Hide()
        local wasVisible = self.visible
        self.visible = false
        if wasVisible and self.scripts.OnHide then self.scripts.OnHide(self) end
    end
    function control:SetSize(width, height)
        self.width, self.height = width, height
    end
    function control:GetWidth() return self.width or 0 end
    function control:GetHeight() return self.height or 0 end
    function control:SetScale(value) self.scale = value end
    function control:SetFont(path, size, flags) self.font = { path = path, size = size, flags = flags } end
    function control:SetShadowColor(...) self.shadowColor = { ... } end
    function control:SetShadowOffset(...) self.shadowOffset = { ... } end
    function control:SetTextInsets(...) self.textInsets = { ... } end
    function control:SetPoint(point, relativeTo, relativePoint, x, y)
        self.point = { point = point, relativeTo = relativeTo, relativePoint = relativePoint, x = x, y = y }
    end
    function control:SetAllPoints(relativeTo) self.allPointsTo = relativeTo end
    function control:ClearAllPoints() self.point = nil; self.allPointsTo = nil end
    function control:SetClampedToScreen(value) self.clampedToScreen = value end
    function control:SetJustifyH() end
    function control:SetAutoFocus() end
    function control:SetHeight(height) self.height = height end
    function control:SetWidth(width) self.width = width end
    function control:SetFrameStrata(value) self.strata = value end
    function control:SetMovable(value) self.movable = value end
    function control:EnableMouse() end
    function control:RegisterForDrag() end
    function control:StartMoving() self.moving = true end
    function control:StopMovingOrSizing() self.moving = false end
    function control:IsShown() return self.visible end
    function control:SetVerticalScroll(value) self.verticalScroll = value end
    function control:SetScript(name, callback) self.scripts[name] = callback end
    function control:RegisterForClicks() end
    function control:SetDesaturated(value) self.desaturated = value end
    function control:SetAlpha(value) self.alpha = value end
    function control:SetBlendMode(value) self.blendMode = value end
    function control:SetVertexColor(...) self.vertexColor = { ... } end
    function control:SetTexture(value) self.texture = value; self.atlas = nil end
    function control:SetColorTexture(...) self.color = { ... }; self.texture = nil; self.atlas = nil end
    function control:SetAtlas(value) self.atlas = value; self.texture = nil end
    function control:SetTexCoord(...) self.texCoord = { ... } end
    function control:CreateFontString() return newControl() end
    function control:CreateTexture() return newControl() end
    function control:CreateMaskTexture() return newControl() end
    function control:AddMaskTexture(mask) self.mask = mask end
    return control
end

local function makeBrowserAPI()
    local api = {
        UIParent = newControl(),
        CreateFrame = function(frameType, name, parent, template)
            local frame = newControl()
            frame.name, frame.parent, frame.frameType, frame.template = name, parent, frameType, template
            frame.TitleText = newControl()
            function frame:SetScrollChild(child) self.scrollChild = child end
            return frame
        end,
        date = function(_, timestamp) return "saved-" .. tostring(timestamp) end,
        GetItemIcon = function(itemID) return "item-icon:" .. tostring(itemID) end,
        GetInventorySlotInfo = function(slotName) return 1, "slot-icon:" .. slotName end,
    }
    api.UIParent:SetSize(1920, 1080)
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
            and parent.width == 208 and parent.height == 226 then return nil end
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
        local displayRecord = {}
        for key, value in pairs(record) do
            if key ~= "identity" and key ~= "gear" then displayRecord[key] = value end
        end
        displayRecord.identity = {}
        for key, value in pairs(record.identity or {}) do displayRecord.identity[key] = value end
        if type(record.gear) == "table" and GGM.ValidateStoredGear(record.gear) == true then
            local slots, unavailableSlots = {}, {}
            for key, value in pairs(record.gear.slots or {}) do slots[key] = value end
            for key, value in pairs(record.gear.unavailableSlots or {}) do unavailableSlots[key] = value end
            displayRecord.gear = {
                complete = record.gear.complete,
                capturedAt = record.gear.capturedAt,
                slots = slots,
                unavailableSlots = unavailableSlots,
            }
        else
            local runtime = { complete = true, capturedAt = record.gear and record.gear.capturedAt, slots = {} }
            for _, trackedSlot in ipairs(GGM.TRACKED_SLOTS) do
                runtime.slots[trackedSlot.key] = record.gear and record.gear.slots
                    and record.gear.slots[trackedSlot.key]
            end
            local compact = GGM.CreateStoredGear(runtime)
            if compact then
                if record.gear.complete == false then compact.complete = false end
                displayRecord.gear = compact
            else
                displayRecord.gear = record.gear
            end
        end
        db.characters[displayRecord.identity.key] = displayRecord
    end
    return db
end

local function showBrowser(GGM, api, db)
    GGM.ShowGuildGearBrowserWindow(api, db)
    return GGM.guildGearBrowserFrame
end

T.test("character content stays within the journal's painted page borders", function()
    local GGM = loadUI()
    local frame = showBrowser(GGM, makeBrowserAPI(), makeDB(GGM, { makeRecord(GGM) }))
    local detail = frame.gearPanel
    T.assertTrue(detail.point.x >= 635 and detail.point.x <= 645, "detail misses the painted left border")
    T.assertTrue(-detail.point.y >= 70 and -detail.point.y <= 80, "detail misses the painted top border")
    T.assertTrue(detail.point.x + detail.width <= 1350, "detail extends beyond the painted right border")
    T.assertTrue(-detail.point.y + detail.height <= 574, "detail extends beyond the painted bottom border")
    local libraryLeft = frame.searchPanel.point.x
    T.assertTrue(libraryLeft + frame.listPanel.width <= 620, "library divider extends beyond its painted border")
    T.assertTrue(libraryLeft + frame.listScroll.point.x + frame.listScroll.width + 24 <= 620,
        "native scrollbar extends beyond the library border")
    local artworkLeft = detail.width + detail.armoryArt.point.x - detail.armoryArt.width
    T.assertTrue(frame.completenessBadge.point.x + frame.completenessBadge.width + 6 <= artworkLeft,
        "status badge overlaps the header artwork")
end)

T.test("journal headings reserve space for subtitles inside their columns", function()
    local GGM = loadUI()
    local frame = showBrowser(GGM, makeBrowserAPI(), makeDB(GGM, { makeRecord(GGM) }))
    T.assertTrue((frame.pageSubtitle.width or 0) > 0, "page subtitle needs a bounded wrapping region")
    T.assertTrue(frame.pageTitle.point.x + frame.pageSubtitle.width <= 620, "page subtitle crosses into the detail page")
    T.assertNil(frame.brandSubtitle, "brand subtitle should be removed")
end)

T.test("character header artwork is above parchment and captured date has a bounded region", function()
    local GGM = loadUI()
    local api = makeBrowserAPI()
    local createFrame = api.CreateFrame
    api.CreateFrame = function(...)
        local control = createFrame(...)
        local createTexture = control.CreateTexture
        control.CreateTexture = function(self, name, layer, ...)
            local texture = createTexture(self, name, layer, ...)
            texture.drawLayer = layer
            return texture
        end
        return control
    end
    local frame = showBrowser(GGM, api, makeDB(GGM, { makeRecord(GGM) }))
    T.assertEqual(frame.gearPanel.armoryArt.drawLayer, "ARTWORK",
        "armory illustration must draw above the opaque parchment background")
    T.assertTrue((frame.capturedLine.width or 0) >= 140,
        "capture date needs explicit space independent of caption autosizing")
    T.assertTrue((frame.capturedLine.height or 0) >= 14)
    T.assertTrue(frame.capturedLine.visible)
end)

T.test("character portrait and weapon labels have separate space above the footer", function()
    local GGM = loadUI()
    local frame = showBrowser(GGM, makeBrowserAPI(), makeDB(GGM, { makeRecord(GGM) }))
    local portraitBottom = -frame.modelStage.point.y + frame.modelStage.height
    local footerTop = frame.gearPanel.height - 14 - frame.detailFooter.height
    for _, button in ipairs(frame.slotButtons) do
        if button.paperDollGroup == "bottom" then
            local top = -button.point.y - button.height / 2
            local labelsBottom = -button.point.y + button.height / 2 + 5 + 16 + 1 + 14
            T.assertTrue(top >= portraitBottom + 8, "weapons overlap the saved portrait")
            T.assertTrue(labelsBottom <= footerTop - 6, "weapon labels overlap the footer")
        end
    end
end)

T.test("compact browser tooltip receives a hyperlink rebuilt from the exact item string", function()
    local GGM = loadUI()
    local record = compactRecord(GGM, makeRecord(GGM))
    record.gear.slots[1] = "item:4001:5:6"
    local tooltip = { SetOwner = function() end, Show = function() end }
    function tooltip:SetHyperlink(link) self.link = link end
    function tooltip:Hide() end
    local api = makeBrowserAPI()
    api.GameTooltip = tooltip
    api.C_Item = { GetItemNameByID = function() return "Headgear" end }
    local frame = showBrowser(GGM, api, makeDB(GGM, { record }))
    frame.slotButtons[1].scripts.OnEnter(frame.slotButtons[1])
    T.assertEqual(tooltip.link, "|Hitem:4001:5:6|h[Headgear]|h")
end)

local function professionCatalog(state, recipes, message, hasSnapshot)
    return { state = state, recipes = recipes or {}, message = message, hasSnapshot = hasSnapshot }
end

local function installProfessionCatalogStub(GGM, catalog, calls)
    GGM.professionRosterMembershipCurrent = true
    GGM.BuildProfessionRecipeCatalog = function(db, professionID, professionLabel, api)
        calls[#calls + 1] = { db = db, professionID = professionID, professionLabel = professionLabel, api = api }
        return catalog(professionID, professionLabel)
    end
end

local function recipeDetailsFixture()
    local GGM, api = loadUI(), makeBrowserAPI()
    local recipes = {
        { recipeID = 11, name = "Copper Bracers", outputIcon = 101, knownBy = {
            { key = "Bob-Realm", name = "Bob", realm = "Realm", savedDate = "2026-09-02" },
            { key = "Alice-Realm", name = "Alice", realm = "Realm", savedDate = "2026-09-01" },
        } },
        { recipeID = 22, name = "Silver Ring", knownBy = {} },
    }
    local reads = 0
    GGM.BuildRecipeMaterialDetails = function(_, id)
        reads = reads + 1
        if id == 22 then return { state = "unavailable", materials = {}, message = "Materials unavailable." } end
        return { state = "ready", materials = {
            { name = "Metal", quantity = 3, optional = false, choices = {
                { itemID = 1, name = "Copper", icon = 10 },
                { itemID = 2, name = "Fine Copper", icon = 20 },
            } },
            { name = "Finishing reagent", quantity = 1, optional = true, choices = {
                { itemID = 3, name = "Polish", icon = 30 },
            } },
        } }
    end
    local forbidden = function() error("Recipe details must stay local and read-only") end
    api.C_ChatInfo = { SendAddonMessage = forbidden }
    api.C_GuildInfo = { GuildRoster = forbidden }
    api.NotifyInspect, api.CraftRecipe = forbidden, forbidden
    local db = { schemaVersion = GGM.SCHEMA_VERSION, characters = {}, marker = "unchanged" }
    installProfessionCatalogStub(GGM, function() return professionCatalog("ready", recipes) end, {})
    local frame = showBrowser(GGM, api, db)
    GGM.SelectGuildGearBrowserTab(frame, "Professions")
    return GGM, api, frame, recipes, function() return reads end, db
end

T.test("recipe parchment and leather have explicit ordering on the same owning frame", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    local createFrame = api.CreateFrame
    api.CreateFrame = function(...)
        local control = createFrame(...)
        local createTexture = control.CreateTexture
        control.CreateTexture = function(self, name, layer, template, sublevel)
            local texture = createTexture(self, name, layer, template, sublevel)
            texture.owner, texture.drawLayer, texture.sublevel = self, layer, sublevel or 0
            return texture
        end
        return control
    end
    local details = GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    T.assertEqual(details.paper.background.owner, details,
        "paper must not depend on ordering between equal-level frames")
    T.assertEqual(details.materialPanel.background.owner, details)
    T.assertEqual(details.paper.background.drawLayer, "BACKGROUND")
    T.assertTrue(details.paper.background.sublevel > details.background.sublevel)
    T.assertTrue(details.materialPanel.background.sublevel > details.paper.background.sublevel)
    T.assertEqual(details.paper.background.allPointsTo, details.paper)
end)

T.test("recipe clicks open one movable details window and pooled rows use current recipes", function()
    local GGM, api, browser, recipes, reads, db = recipeDetailsFixture()
    browser.professionRecipeRows[1].scripts.OnClick(browser.professionRecipeRows[1])
    local details = browser.recipeDetailsFrame
    T.assertTrue(details:IsShown())
    T.assertTrue(details.movable)
    T.assertEqual(details.recipeName.text, "Copper Bracers")
    T.assertEqual(details.professionName.text, "Alchemy")
    T.assertEqual(details.recipeIcon.texture, 101)
    local registered = 0
    for _, name in ipairs(api.UISpecialFrames) do if name == details.name then registered = registered + 1 end end
    T.assertEqual(registered, 1)
    browser.professionSearchBox:SetText("Silver")
    browser.professionRecipeRows[1].scripts.OnClick(browser.professionRecipeRows[1])
    T.assertEqual(browser.recipeDetailsFrame, details)
    T.assertEqual(details.recipeName.text, recipes[2].name)
    T.assertEqual(details.materialStatus.text, "Materials unavailable.")
    T.assertEqual(reads(), 2)
    T.assertEqual(db.marker, "unchanged")
end)

T.test("recipe details display quantities optional groups and alternative choices", function()
    local GGM, _, browser, recipes = recipeDetailsFixture()
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    local details = browser.recipeDetailsFrame
    T.assertTrue(string.find(details.materialRows[1].label.text, "3", 1, true) ~= nil)
    T.assertTrue(string.find(details.materialRows[1].label.text, "choose one", 1, true) ~= nil)
    T.assertEqual(details.materialRows[2].label.text, "Copper")
    T.assertEqual(details.materialRows[3].label.text, "Fine Copper")
    T.assertTrue(string.find(details.materialRows[4].label.text, "Optional", 1, true) ~= nil)
    T.assertEqual(details.materialRows[5].label.text, "Polish")
end)

T.test("crafter dropdown sorts saved owners and selection displays saved knowledge date", function()
    local GGM, _, browser, recipes = recipeDetailsFixture()
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    local details = browser.recipeDetailsFrame
    T.assertEqual(details.crafters[1].key, "Alice-Realm")
    T.assertEqual(details.selectedCrafterKey, "Alice-Realm")
    T.assertTrue(string.find(details.crafterStatus.text, "2026-09-01", 1, true) ~= nil)
    T.assertTrue(string.find(details.crafterStatus.text, "Last-known", 1, true) ~= nil)
    details.crafterDropdown.scripts.OnClick(details.crafterDropdown)
    details.crafterButtons[2].scripts.OnClick(details.crafterButtons[2])
    T.assertEqual(details.selectedCrafterKey, "Bob-Realm")
    T.assertTrue(string.find(details.crafterStatus.text, "2026-09-02", 1, true) ~= nil)
    T.assertFalse(details.crafterMenu:IsShown())
end)

T.test("details refresh preserves eligible crafter without querying materials and removes obsolete attribution", function()
    local GGM, _, browser, recipes, reads = recipeDetailsFixture()
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    local details = browser.recipeDetailsFrame
    details.crafterDropdown.scripts.OnClick(details.crafterDropdown)
    details.crafterButtons[2].scripts.OnClick(details.crafterButtons[2])
    GGM.RefreshVisibleProfessionCatalog()
    T.assertEqual(details.selectedCrafterKey, "Bob-Realm")
    T.assertEqual(reads(), 1)
    recipes[1].knownBy = { recipes[1].knownBy[2] }
    GGM.RefreshVisibleProfessionCatalog()
    T.assertEqual(details.selectedCrafterKey, "Alice-Realm")
    table.remove(recipes, 1)
    GGM.RefreshVisibleProfessionCatalog()
    T.assertFalse(details:IsShown())
    T.assertNil(details.selectedCrafterKey)
end)

T.test("recipe details close with navigation main-window hide and the close button", function()
    local GGM, _, browser, recipes = recipeDetailsFixture()
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    local details = browser.recipeDetailsFrame
    details.closeButton.scripts.OnClick(details.closeButton)
    T.assertFalse(details:IsShown())
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    GGM.SelectProfession(browser, "Blacksmithing")
    T.assertFalse(details:IsShown())
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    GGM.SelectGuildGearBrowserTab(browser, "Character")
    T.assertFalse(details:IsShown())
    GGM.SelectGuildGearBrowserTab(browser, "Professions")
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    details.crafterDropdown.scripts.OnClick(details.crafterDropdown)
    browser:Hide()
    T.assertFalse(details:IsShown())
    T.assertFalse(details.crafterMenu:IsShown())
end)

T.test("recipe with no crafters shows an explicit cached-knowledge empty state", function()
    local GGM, _, browser, recipes = recipeDetailsFixture()
    GGM.ShowRecipeDetailsWindow(browser, recipes[2])
    local details = browser.recipeDetailsFrame
    T.assertEqual(#details.crafters, 0)
    T.assertNil(details.selectedCrafterKey)
    T.assertEqual(details.crafterStatus.text, "No known crafters in saved records.")
end)

T.test("native Blizzard crafter dropdown selects saved owners and closes on refresh", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    local entries, closes = {}, 0
    api.UIDropDownMenu_Initialize = function(dropdown, callback)
        dropdown.buildMenu = function()
            api.UIDROPDOWNMENU_OPEN_MENU = dropdown
            callback()
        end
    end
    api.UIDropDownMenu_CreateInfo = function() return {} end
    api.UIDropDownMenu_AddButton = function(info) entries[#entries + 1] = info end
    api.UIDropDownMenu_SetWidth = function(dropdown, width) dropdown.width = width end
    api.UIDropDownMenu_SetText = function(dropdown, value) dropdown.selectedText = value end
    api.UIDropDownMenu_SetSelectedValue = function(dropdown, value)
        dropdown.selectedValue = value
        -- Blizzard refreshes text here, using its default when menu buttons are hidden.
        dropdown.selectedText = "Low"
    end
    api.CloseDropDownMenus = function() closes = closes + 1; api.UIDROPDOWNMENU_OPEN_MENU = nil end
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    local details = browser.recipeDetailsFrame
    T.assertTrue(details.nativeDropdown)
    T.assertEqual(closes, 0, "opening details must not close unrelated native menus")
    local otherMenu = {}
    api.UIDROPDOWNMENU_OPEN_MENU = otherMenu
    GGM.RefreshVisibleProfessionCatalog()
    T.assertEqual(api.UIDROPDOWNMENU_OPEN_MENU, otherMenu)
    T.assertEqual(closes, 0)
    details.crafterDropdown.buildMenu()
    T.assertEqual(entries[1].text, "Alice-Realm")
    T.assertEqual(entries[2].value, "Bob-Realm")
    entries[2].func()
    T.assertEqual(details.selectedCrafterKey, "Bob-Realm")
    T.assertEqual(details.crafterDropdown.selectedText, "Bob-Realm")
    entries = {}
    details.crafterDropdown.buildMenu()
    local previousCloses = closes
    recipes[1].knownBy = { recipes[1].knownBy[2] }
    GGM.RefreshVisibleProfessionCatalog()
    T.assertEqual(details.selectedCrafterKey, "Alice-Realm")
    T.assertTrue(closes > previousCloses, "refresh must close menus holding obsolete crafter names")
    entries[2].func()
    T.assertEqual(details.selectedCrafterKey, "Alice-Realm", "obsolete menu callback must preserve the valid selection")
    T.assertTrue(string.find(details.crafterStatus.text, "2026-09-01", 1, true) ~= nil)
end)

T.test("long material names grow rows so wrapped text cannot overlap subsequent materials", function()
    local GGM, _, browser, recipes = recipeDetailsFixture()
    GGM.BuildRecipeMaterialDetails = function()
        return { state = "ready", materials = {
            { name = string.rep("Long material name ", 8), quantity = 3, optional = false,
                choices = { { name = string.rep("Long item name ", 8) }, { name = "Next item" } } },
        } }
    end
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    local rows = browser.recipeDetailsFrame.materialRows
    T.assertTrue(rows[1].height >= 72)
    T.assertTrue(rows[2].height >= 72)
    T.assertTrue(-rows[3].point.y >= rows[1].height + rows[2].height)
end)

T.test("large crafter lists switch native dropdown to a scrollable menu on refresh", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    api.UIDropDownMenu_Initialize = function() end
    api.UIDropDownMenu_CreateInfo = function() return {} end
    api.UIDropDownMenu_AddButton = function() end
    api.UIDropDownMenu_SetWidth = function() end
    api.UIDropDownMenu_SetText = function() end
    api.UIDropDownMenu_SetSelectedValue = function() end
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    local details = browser.recipeDetailsFrame
    T.assertTrue(details.nativeDropdown)
    local originalDropdown = details.crafterDropdown
    for index = 3, 20 do
        recipes[1].knownBy[index] = { key = "Crafter" .. index .. "-Realm", name = "Crafter" .. index,
            realm = "Realm", savedDate = "2026-09-01" }
    end
    GGM.RefreshVisibleProfessionCatalog()
    T.assertFalse(details.nativeDropdown)
    T.assertFalse(originalDropdown:IsShown())
    T.assertEqual(details.selectedCrafterKey, "Alice-Realm")
    details.crafterDropdown.scripts.OnClick(details.crafterDropdown)
    T.assertEqual(#details.crafterButtons, 20)
    T.assertEqual(details.crafterMenu.height, 220)
    details.crafterButtons[20].scripts.OnClick(details.crafterButtons[20])
    T.assertEqual(details.selectedCrafterKey, details.crafters[20].key)
end)

T.test("journal window uses the reference canvas size, custom backdrop, and screen-fit scale", function()
    local GGM = loadUI()
    local api = makeBrowserAPI()
    local frame = GGM.CreateGuildGearBrowserWindow(api)
    local separator = string.char(92)
    local mediaPath = table.concat({
        "Interface", "AddOns", "GuildGearMemory", "Media", "ArtisanJournal", "",
    }, separator)

    T.assertEqual(frame.width, 1400)
    T.assertEqual(frame.height, 630)
    T.assertNil(frame.template)
    T.assertEqual(frame.background.texture, mediaPath .. "journal-window.tga")
    T.assertTrue(frame.background.allPointsTo == frame)
    T.assertTrue(frame.movable)
    T.assertTrue(frame.clampedToScreen)
    T.assertEqual(frame.scale, 1)
    T.assertTrue(frame.proCloseButton ~= nil)
    T.assertEqual(frame.proCloseButton.point.point, "TOPRIGHT")

    api.UIParent:SetSize(1000, 700)
    frame = GGM.CreateGuildGearBrowserWindow(api)
    T.assertTrue(math.abs(frame.scale - (976 / 1400)) < 0.001)
end)

T.test("journal profession page follows the parchment reference proportions and typography", function()
    local GGM = loadUI()
    local frame = GGM.CreateGuildGearBrowserWindow(makeBrowserAPI())
    local ui = GGM.UIStyleTokens
    GGM.SelectGuildGearBrowserTab(frame, "Professions")

    T.assertEqual(ui.windowWidth, 1400)
    T.assertEqual(ui.windowHeight, 630)
    T.assertEqual(ui.professionLibraryX, 314)
    T.assertEqual(ui.professionDetailX, 629)
    T.assertEqual(ui.professionLibraryTop, 109)
    T.assertEqual(frame.pageTitle.text, "Professions")
    T.assertEqual(frame.pageTitle.font.path, GGM.UIJournalTextures.boldFont)
    T.assertEqual(frame.pageTitle.font.size, 26)
    T.assertEqual(frame.pageTitle.font.flags, "")
    T.assertEqual(frame.pageTitle.shadowColor[4], 0)
    T.assertEqual(frame.pageTitle.shadowOffset[1], 0)
    T.assertEqual(frame.pageSubtitle.font.path, GGM.UIJournalTextures.font)
    T.assertEqual(frame.professionButtons[1].width, 244)
    T.assertEqual(frame.professionButtons[1].height, 48)
    T.assertEqual(frame.professionButtons[1].point.x, 34)
    T.assertEqual(frame.professionButtons[1].point.y, -62)
    T.assertEqual(frame.professionButtons[1].background.texture, GGM.UIJournalTextures.professionButton)
    T.assertEqual(frame.professionButtons[1].background.texCoord[1], 0.03085)
    T.assertEqual(frame.professionButtons[1].background.texCoord[2], 0.96961)
    T.assertEqual(frame.professionButtons[1].background.texCoord[3], 0.23757)
    T.assertEqual(frame.professionButtons[1].background.texCoord[4], 0.76520)
    T.assertEqual(frame.professionButtons[1].label.font.path, GGM.UIJournalTextures.boldFont)
    T.assertEqual(frame.professionSearchBox.width, 400)
    T.assertEqual(frame.professionSearchBox.height, 27)
    T.assertEqual(frame.professionHeroArtwork, frame.professionDetailPanel.background)
    T.assertEqual(frame.professionHeroArtwork.texCoord[1], 0)
    T.assertEqual(frame.professionHeroArtwork.texCoord[2], 1)
    T.assertEqual(frame.professionHeroArtwork.texCoord[3], 0)
    T.assertEqual(frame.professionHeroArtwork.texCoord[4], 1)
    T.assertEqual(frame.professionHeroArtwork.point.point, "BOTTOMRIGHT")
    T.assertEqual(frame.professionHeroArtwork.point.x, -9)
    T.assertEqual(frame.professionHeroArtwork.point.y, 9)
    T.assertEqual(frame.professionRecipeScroll.point.point, "BOTTOMRIGHT")
    T.assertEqual(frame.professionRecipeScroll.point.y, 22)
end)

T.test("profession selection changes the full page artwork for each supported profession", function()
    local GGM = loadUI()
    local frame = GGM.CreateGuildGearBrowserWindow(makeBrowserAPI())
    local separator = string.char(92)
    local mediaPath = table.concat({
        "Interface", "AddOns", "GuildGearMemory", "Media", "ArtisanJournal", "",
    }, separator)
    local expected = {
        { key = "Alchemy", texture = mediaPath .. "alchemy-page.tga" },
        { key = "Blacksmithing", texture = mediaPath .. "blacksmithing-page.tga" },
        { key = "Enchanting", texture = mediaPath .. "enchanting-page.tga" },
        { key = "Engineering", texture = mediaPath .. "engineering-page.tga" },
        { key = "Leatherworking", texture = mediaPath .. "leatherworking-page.tga" },
        { key = "Tailoring", texture = mediaPath .. "tailoring-page.tga" },
    }

    for _, profession in ipairs(expected) do
        T.assertTrue(GGM.SelectProfession(frame, profession.key))
        T.assertTrue(frame.professionHeroArtwork ~= nil, "profession hero artwork should be visible")
        T.assertEqual(frame.professionHeroArtwork.texture, profession.texture)
        T.assertNotNil(frame.professionHeroArtwork.mask, "every profession must retain the shared rounded edge fade")
        T.assertEqual(frame.professionHeroArtwork.mask.texture, mediaPath .. "profession-page-mask.tga")
        T.assertEqual(frame.professionHeroArtwork.mask.allPointsTo, frame.professionHeroArtwork)
    end
end)

T.test("invalid profession selection preserves the current hero artwork", function()
    local GGM = loadUI()
    local frame = GGM.CreateGuildGearBrowserWindow(makeBrowserAPI())
    GGM.SelectProfession(frame, "Engineering")
    T.assertTrue(frame.professionHeroArtwork ~= nil, "profession hero artwork should be visible")
    local selectedProfession = frame.selectedProfession
    local artwork = frame.professionHeroArtwork.texture

    T.assertFalse(GGM.SelectProfession(frame, "UnlistedProfession"))

    T.assertEqual(frame.selectedProfession, selectedProfession)
    T.assertEqual(frame.professionHeroArtwork.texture, artwork)
end)

T.test("profession page defers catalog construction until database assignment and selects each profession ID", function()
    local GGM = loadUI()
    local calls = {}
    installProfessionCatalogStub(GGM, function()
        return professionCatalog("ready", { { recipeID = 1, name = "Copper Ore", knownBy = {} } })
    end, calls)
    local api, db = makeBrowserAPI(), { schemaVersion = GGM.SCHEMA_VERSION, characters = {} }
    local frame = GGM.CreateGuildGearBrowserWindow(api)
    GGM.guildGearBrowserFrame = frame

    T.assertEqual(#calls, 0)
    T.assertEqual(frame.selectedProfession, "Alchemy")
    T.assertNil(frame.db)
    GGM.ShowGuildGearBrowserWindow(api, db)
    T.assertEqual(#calls, 1)
    T.assertTrue(calls[1].db == db)
    T.assertEqual(calls[1].professionID, 171)
    T.assertTrue(calls[1].api == api)

    local expected = {
        { key = "Alchemy", id = 171 }, { key = "Blacksmithing", id = 164 },
        { key = "Enchanting", id = 333 }, { key = "Engineering", id = 202 },
        { key = "Leatherworking", id = 165 }, { key = "Tailoring", id = 197 },
    }
    T.assertEqual(calls[1].professionID, expected[1].id)
    for index = 2, #expected do
        local profession = expected[index]
        local button = frame.professionButtons[index]
        T.assertEqual(button.professionID, profession.id)
        T.assertEqual(button.key, profession.key)
        button.scripts.OnClick(button)
        T.assertEqual(frame.selectedProfession, profession.key)
        T.assertEqual(#calls, index, "each profession selection should build one local catalog")
        T.assertEqual(calls[#calls].professionID, profession.id)
    end
end)

T.test("profession search filters cached recipes only, changing profession clears query, and tab entry refreshes locally", function()
    local GGM = loadUI()
    local calls = {}
    installProfessionCatalogStub(GGM, function()
        return professionCatalog("ready", {
            { recipeID = 10, name = "Copper Bracers", knownBy = { { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", savedDate = "saved 2026-09-01" } } },
            { recipeID = 11, name = "Silver Ring", knownBy = { { key = "Bea-Silvermoon", name = "Bea", realm = "Silvermoon", savedDate = "saved 2026-09-02" } } },
        })
    end, calls)
    local api, db = makeBrowserAPI(), { schemaVersion = GGM.SCHEMA_VERSION, characters = {}, professions = {}, marker = "preserve" }
    local forbidden = function() error("profession browser interaction must remain local and read-only") end
    for _, name in ipairs({ "GuildRoster", "GetGuildRosterInfo", "GetProfessions", "GetProfessionInfo", "SendAddonMessage" }) do
        api[name] = forbidden
    end
    api.C_TradeSkillUI = { GetRecipeInfo = forbidden, GetProfessionInfoBySkillLineID = forbidden }
    for _, name in ipairs({ "EnsureProfessionIndex", "ValidateProfessionIndexCache", "ReconcileProfessionRoster" }) do
        GGM[name] = forbidden
    end
    local function copy(value)
        if type(value) ~= "table" then return value end
        local result = {}
        for key, child in pairs(value) do result[copy(key)] = copy(child) end
        return result
    end
    local function equal(left, right)
        if type(left) ~= type(right) then return false end
        if type(left) ~= "table" then return left == right end
        for key, value in pairs(left) do if not equal(value, right[key]) then return false end end
        for key in pairs(right) do if left[key] == nil then return false end end
        return true
    end
    local before = copy(db)
    local frame = showBrowser(GGM, api, db)
    local builderCalls = #calls

    frame.professionSearchBox:SetText("COPPER")
    T.assertEqual(#calls, builderCalls)
    T.assertEqual(#frame.filteredProfessionRecipes, 1)
    T.assertEqual(frame.professionRecipeRows[1].recipe.name, "Copper Bracers")
    T.assertTrue(string.find(frame.professionRecipeRows[1].knownBy.text, "saved 2026-09-01", 1, true) ~= nil)

    frame.professionButtons[2].scripts.OnClick(frame.professionButtons[2])
    T.assertEqual(frame.professionSearchBox:GetText(), "")
    T.assertEqual(#frame.filteredProfessionRecipes, 2)
    frame.navigationTabs[2].scripts.OnClick(frame.navigationTabs[2])
    T.assertEqual(#calls, builderCalls + 2)
    T.assertEqual(frame.professionSearchBox:GetText(), "")

    frame.professionSearchBox:SetText("ring")
    builderCalls = #calls
    frame.navigationTabs[1].scripts.OnClick(frame.navigationTabs[1])
    frame.navigationTabs[2].scripts.OnClick(frame.navigationTabs[2])
    T.assertEqual(#calls, builderCalls + 1)
    T.assertEqual(frame.professionSearchBox:GetText(), "ring")
    T.assertEqual(#frame.filteredProfessionRecipes, 1)
    T.assertEqual(frame.professionRecipeRows[1].recipe.name, "Silver Ring")
    T.assertTrue(equal(db, before), "opening, selecting, searching, and tab entry must not mutate SavedVariables")
end)

T.test("profession messages preserve unavailable and empty base states and distinguish a filtered no-match", function()
    local GGM = loadUI()
    local mode = "unavailable"
    local calls = {}
    installProfessionCatalogStub(GGM, function()
        if mode == "unavailable" then return professionCatalog("unavailable", {}, "Current guild membership could not be confirmed.", nil) end
        if mode == "identities" then return professionCatalog("unavailable", {}, "Current guild member identities could not be confirmed.", nil) end
        if mode == "incomplete" then return professionCatalog("incomplete", {}, "Some saved profession data is incomplete.", true) end
        if mode == "incomplete-safe" then
            return professionCatalog("incomplete", { { recipeID = 22, name = "Azure Dye", knownBy = {} } },
                "Some saved profession data is incomplete.", true)
        end
        if mode == "no-snapshot" then return professionCatalog("empty", {}, "No saved Alchemy snapshots for current guild members.", false) end
        if mode == "no-recipes" then return professionCatalog("empty", {}, "Saved Alchemy snapshots contain no learned recipes.", true) end
        return professionCatalog("ready", { { recipeID = 22, name = "Azure Dye", knownBy = {} } })
    end, calls)
    local frame = showBrowser(GGM, makeBrowserAPI(), { schemaVersion = GGM.SCHEMA_VERSION, characters = {} })

    T.assertEqual(frame.professionStatus.text, "Current guild membership could not be confirmed.")
    mode = "identities"; GGM.SelectProfession(frame, "Alchemy")
    T.assertEqual(frame.professionStatus.text, "Current guild member identities could not be confirmed.")
    mode = "incomplete"; GGM.SelectProfession(frame, "Alchemy")
    T.assertEqual(frame.professionStatus.text, "Some saved profession data is incomplete.")
    mode = "no-snapshot"; GGM.SelectProfession(frame, "Alchemy")
    T.assertEqual(frame.professionStatus.text, "No saved Alchemy snapshots for current guild members.")
    mode = "no-recipes"; GGM.SelectProfession(frame, "Alchemy")
    T.assertEqual(frame.professionStatus.text, "Saved Alchemy snapshots contain no learned recipes.")
    mode = "incomplete-safe"; GGM.SelectProfession(frame, "Alchemy")
    T.assertEqual(#frame.filteredProfessionRecipes, 1)
    frame.professionSearchBox:SetText("missing")
    T.assertEqual(frame.professionStatus.text,
        "Some saved profession data is incomplete. No recipes match this search.")
    mode = "ready"; GGM.SelectProfession(frame, "Alchemy")
    frame.professionSearchBox:SetText("missing")
    T.assertEqual(frame.professionStatus.text, "No recipes match this search.")
end)

T.test("visible profession catalog refreshes locally after roster reconciliation succeeds or fails", function()
    local GGM = loadUI()
    local calls = 0
    GGM.professionRosterMembershipCurrent = true
    GGM.BuildProfessionRecipeCatalog = function()
        calls = calls + 1
        if not GGM.professionRosterMembershipCurrent then
            return professionCatalog("unavailable", {}, "Current guild membership could not be confirmed.")
        end
        return professionCatalog("ready", { { recipeID = calls, name = "Recipe " .. calls, knownBy = {} } })
    end
    local api = makeBrowserAPI()
    for _, name in ipairs({ "GuildRoster", "SendAddonMessage" }) do
        api[name] = function() error("catalog refresh must not request roster data or send messages") end
    end
    local frame = showBrowser(GGM, api, { schemaVersion = GGM.SCHEMA_VERSION, characters = {} })
    GGM.SelectGuildGearBrowserTab(frame, "Professions")
    T.assertEqual(frame.professionRecipeRows[1].recipe.name, "Recipe 2")

    -- A completed reconciliation refreshes the currently visible catalog from local saved data.
    GGM.professionRosterMembershipCurrent = true
    T.assertTrue(GGM.RefreshVisibleProfessionCatalog())
    T.assertEqual(frame.professionRecipeRows[1].recipe.name, "Recipe 3")

    -- A failed reconciliation clears stale owners by rebuilding the fail-closed unavailable model.
    GGM.professionRosterMembershipCurrent = false
    T.assertTrue(GGM.RefreshVisibleProfessionCatalog())
    T.assertEqual(frame.professionStatus.text, "Current guild membership could not be confirmed.")
    T.assertEqual(#frame.filteredProfessionRecipes, 0)
end)

T.test("profession owner rows show name realm and date without ownership badges", function()
    local GGM = loadUI()
    local calls = {}
    local localOwner = {
        key = "Alice-Silvermoon",
        name = "Alice",
        realm = "Silvermoon",
        savedDate = "2026-10-01",
    }
    local guildOwner = {
        key = "Bob-ArgentDawn",
        name = "Bob",
        realm = "ArgentDawn",
        savedDate = "2026-09-30",
    }

    installProfessionCatalogStub(GGM, function()
        return professionCatalog("ready", {
            {
                recipeID = 100,
                name = "Copper Bracers",
                knownBy = { localOwner, guildOwner },
            },
        })
    end, calls)

    local frame = showBrowser(
        GGM,
        makeBrowserAPI(),
        { schemaVersion = GGM.SCHEMA_VERSION, characters = {} }
    )
    GGM.SelectGuildGearBrowserTab(frame, "Professions")

    local text = frame.professionRecipeRows[1].knownBy.text
    T.assertEqual(text,
        "Known by: Alice-Silvermoon — 2026-10-01\nBob-ArgentDawn — 2026-09-30")
end)

T.test("guild gear browser shows the no saved guild gear state for an empty database", function()
    local GGM = loadUI()
    local frame = showBrowser(GGM, makeBrowserAPI(), makeDB(GGM))

    T.assertTrue(frame.visible)
    T.assertEqual(frame.listEmpty.text, "No guild snapshots yet")
    T.assertEqual(frame.detailEmpty.text, "No guild snapshots yet")
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
    T.assertNotNil(frame.mineButton.label)
    T.assertEqual(frame.mineButton.variant, "ghost")
    for _, button in ipairs({ frame.mineButton, frame.guildButton }) do
        T.assertTrue(button.point.x >= 0, "view controls must remain inside the search panel")
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
    T.assertTrue(frame.mineButton.label.text == "My Characters")

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
    T.assertEqual(frame.listEmpty.text, "No guild snapshots yet")
    T.assertEqual(frame.detailEmpty.text, "No guild snapshots yet")
    frame.mineButton.scripts.OnClick(frame.mineButton)
    frame.searchBox:SetText("missing")
    T.assertEqual(frame.listEmpty.text, "No characters match your search")
    T.assertEqual(frame.detailEmpty.text, "No characters match your search")

    local emptyFrame = showBrowser(GGM, makeBrowserAPI(), makeDB(GGM))
    emptyFrame.mineButton.scripts.OnClick(emptyFrame.mineButton)
    T.assertEqual(emptyFrame.listEmpty.text, "No personal snapshots yet")
    T.assertEqual(emptyFrame.detailEmpty.text, "No personal snapshots yet")
end)

T.test("guild gear browser hides the model stage when detail has no valid record", function()
    local GGM = loadUI()
    local record = makeRecord(GGM)
    local db = makeDB(GGM, { record })
    local frame = showBrowser(GGM, makeBrowserAPI(), db)

    -- WoW frames are shown by default; model that initial state in the UI stub.
    frame.modelStage.visible = true
    T.assertTrue(frame.modelStage.visible)
    frame.searchBox:SetText("missing")
    T.assertFalse(frame.modelStage.visible)
    T.assertTrue(frame.detailEmpty.visible)

    frame.searchBox:SetText("")
    T.assertTrue(frame.modelStage.visible)
    frame.listRows[1].scripts.OnClick(frame.listRows[1])
    db.characters[record.identity.key].gear.slots[1] = "item:invalid"
    frame.listRows[1].scripts.OnClick(frame.listRows[1])
    T.assertFalse(frame.modelStage.visible)
    T.assertEqual(frame.detailEmpty.text, "No saved gear is available for this character")
end)

T.test("guild gear browser slot buttons fit inside the detail panel with a gap after the list", function()
    local GGM = loadUI()
    local frame = showBrowser(GGM, makeBrowserAPI(), makeDB(GGM, { makeRecord(GGM) }))
    local ui = GGM.UIStyleTokens
    local panelLeft = ui.railWidth + ui.pageMargin + ui.browserColumnWidth + ui.contentGap
    local listRight = ui.railWidth + ui.pageMargin + ui.browserColumnWidth
    local panelHeight = ui.windowHeight - ui.contentTop - ui.contentBottom
    local panelWidth = ui.detailColumnWidth
    local footerTop = panelHeight - 14 - 32

    for index, button in ipairs(frame.slotButtons) do
        local point = button.point
        T.assertTrue(point ~= nil, "slot button must have a recorded layout point")
        T.assertTrue(point.relativeTo == frame.gearPanel, "slot button must be positioned relative to the equipment panel")
        T.assertEqual(point.point, "CENTER")
        T.assertEqual(point.relativePoint, "TOPLEFT")
        local left = point.x - button.width / 2
        local right = point.x + button.width / 2
        local top = -point.y - button.height / 2
        local bottom = -point.y + button.height / 2
        T.assertTrue(panelLeft + left >= listRight + ui.contentGap,
            "slot " .. index .. " overlaps or crowds the character list")
        T.assertTrue(right <= panelWidth, "slot " .. index .. " exceeds the detail panel right edge")
        T.assertTrue(top >= 88, "slot " .. index .. " overlaps the detail panel header")
        T.assertTrue(bottom <= footerTop - 12, "slot " .. index .. " overlaps the detail panel footer")
    end
end)

T.test("guild gear browser keeps search text and shows no characters found after refresh", function()
    local GGM = loadUI()
    local record = makeRecord(GGM)
    local api = makeBrowserAPI()
    local frame = showBrowser(GGM, api, makeDB(GGM, { record }))

    frame.searchBox:SetText("missing-name")
    T.assertEqual(frame.searchBox:GetText(), "missing-name")
    T.assertEqual(frame.listEmpty.text, "No characters match your search")
    T.assertEqual(frame.detailEmpty.text, "No characters match your search")
    T.assertNil(frame.selectedEntry)

    GGM.ShowGuildGearBrowserWindow(api, makeDB(GGM, { record }))
    T.assertEqual(frame.searchBox:GetText(), "missing-name")
    T.assertEqual(frame.listEmpty.text, "No characters match your search")
end)

T.test("guild gear browser rows show name and realm and selecting renders saved identity time and slots", function()
    local GGM = loadUI()
    local alpha = makeRecord(GGM)
    local beta = makeRecord(GGM)
    beta.identity = { key = "Beatrice-ArgentDawn", name = "Beatrice", realm = "ArgentDawn" }
    beta.gear.capturedAt = 1700000200
    local api = makeBrowserAPI()
    local frame = showBrowser(GGM, api, makeDB(GGM, { beta, alpha }))

    T.assertEqual(frame.listRows[1].label.text, "Alice")
    T.assertEqual(frame.listRows[1].realm.text, "Silvermoon")
    T.assertEqual(frame.listRows[2].label.text, "Beatrice")
    T.assertEqual(frame.listRows[2].realm.text, "ArgentDawn")
    frame.listRows[1].scripts.OnClick(frame.listRows[1])
    T.assertEqual(frame.selectedEntry.key, "Alice-Silvermoon")
    T.assertEqual(frame.characterLine.text, "Alice")

    frame.listRows[2].scripts.OnClick(frame.listRows[2])
    T.assertEqual(frame.selectedEntry.key, "Beatrice-ArgentDawn")
    T.assertEqual(frame.characterLine.text, "Beatrice")
    T.assertEqual(frame.realmLine.text, "ArgentDawn")
    T.assertEqual(frame.capturedLine.text, "saved-1700000200")
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
    local record = compactRecord(GGM, makeRecord(GGM))
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
    T.assertEqual(frame.capturedLine.text, "saved-1700000200")
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
    T.assertEqual(frame.modelUnavailableLabel.text, "Saved character model unavailable")
    T.assertTrue(frame.characterLine.visible)
    T.assertTrue(frame.realmLine.visible)
    T.assertTrue(frame.capturedLine.visible)
    T.assertEqual(frame.capturedLine.text, "saved-1700000100")
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
    local legacy = compactRecord(GGM, makeRecord(GGM))
    legacy.identity.raceID, legacy.identity.sex, legacy.identity.displayID = nil, nil, nil
    legacy.complete, legacy.completeness = false, "incomplete"
    legacy.refreshNeeded, legacy.incompleteReason, legacy.requiredBaselineSequence = true, "sequence-gap", 2
    legacy.confirmedSequence = 1
    legacy.gear.complete = false
    local api = makeModelBrowserAPI()
    local frame = showBrowser(GGM, api, makeDB(GGM, { legacy }))

    T.assertEqual(frame.characterModelView.caption.text, "Saved gear - portrait not available")
    T.assertEqual(frame.completenessLine.text, "Refresh needed")
    T.assertEqual(frame.capturedLine.text, "saved-1700000100")
    T.assertTrue(frame.slotButtons[1].visible)
    T.assertEqual(#frame.detailModel.slots, #GGM.TRACKED_SLOTS)
    GGM.ShowGuildGearBrowserWindow(api, makeDB(GGM, { legacy }))
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
    T.assertEqual(emptySlot.icon.alpha, 0.32)
    T.assertEqual(emptySlot.key, "OFF_HAND")
    T.assertEqual(emptySlot.label.text, "Off hand")
    T.assertEqual(emptySlot.status.text, "Empty")
    T.assertNil(emptySlot.itemLink)
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

T.test("unsupported schema status gives backup and removal guidance with cleared data scope", function()
    local GGM = loadUI()
    local messages = {}
    local api = {
        SlashCmdList = {},
        DEFAULT_CHAT_FRAME = { AddMessage = function(_, message)
            table.insert(messages, message)
        end },
    }
    GGM.startupError = "unsupported-schema-version:5"

    GGM.RegisterSnapshotTestSlashCommand(api)
    api.SlashCmdList.GUILDGEARMEMORY("status")

    local output = table.concat(messages, "\n")
    T.assertTrue(output:find("No automatic migration", 1, true) ~= nil)
    T.assertTrue(output:find("back up", 1, true) ~= nil)
    T.assertTrue(output:find("GuildGearMemory.lua", 1, true) ~= nil)
    T.assertTrue(output:find("cached gear", 1, true) ~= nil)
    T.assertTrue(output:find("profession snapshots/index data", 1, true) ~= nil)
    T.assertTrue(output:find("local-character metadata", 1, true) ~= nil)
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

T.test("compact absent optional and required slots render as empty", function()
    local GGM = loadUI()
    local record = compactRecord(GGM, makeRecord(GGM))
    record.gear.slots[4], record.gear.slots[18], record.gear.unavailableSlots[18] = nil, nil, nil
    local entries = GGM.BuildGuildGearBrowserEntries(makeDB(GGM, { record }))
    T.assertEqual(#entries, 1)
    local model = GGM.BuildGuildGearBrowserDetail(entries[1].record, {})
    T.assertTrue(model.hasRecord)
    T.assertTrue(model.complete)
    T.assertEqual(model.completenessText, "Complete")
    local found = {}
    for _, row in ipairs(model.slots) do
        found[row.key] = row
    end
    T.assertFalse(found.SHIRT.unavailable)
    T.assertTrue(found.SHIRT.empty)
    T.assertFalse(found.HEAD.unavailable)
    local frame = showBrowser(GGM, makeBrowserAPI(), makeDB(GGM, { record }))
    T.assertEqual(frame.completenessLine.text, "Complete")
    local shirtIndex
    for index, slot in ipairs(GGM.TRACKED_SLOTS) do if slot.key == "SHIRT" then shirtIndex = index end end
    T.assertTrue(frame.slotButtons[shirtIndex].empty)
    T.assertEqual(frame.slotButtons[shirtIndex].label.text, "Shirt")
    T.assertEqual(frame.slotButtons[shirtIndex].status.text, "Empty")
    T.assertTrue(frame.slotButtons[shirtIndex].label.width <= 98)
    T.assertTrue(frame.slotButtons[shirtIndex].status.width <= 98)
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
        local expectedWidth = button.paperDollGroup == "bottom" and 92 or 98
        T.assertTrue(button.label.width <= expectedWidth)
        T.assertTrue(button.status.width <= expectedWidth)
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
