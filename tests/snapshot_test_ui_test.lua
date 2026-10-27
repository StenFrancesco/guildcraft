local T = require("tests.testlib")
local makeRecord, compactRecord

local function loadUI()
    local GGM = {}
    T.loadAddonFile("The Guild Book/Constants.lua", GGM)
    T.loadAddonFile("The Guild Book gear/Constants.lua", GGM)
    T.loadAddonFile("The Guild Book gear/GearData.lua", GGM)
    T.loadAddonFile("The Guild Book gear/CharacterIdentity.lua", GGM)
    T.loadAddonFile("The Guild Book gear/GearSnapshot.lua", GGM)
    T.loadAddonFile("The Guild Book/ProfessionSnapshot.lua", GGM)
    T.loadAddonFile("The Guild Book/ProfessionIndex.lua", GGM)
    T.loadAddonFile("The Guild Book/Storage.lua", GGM)
    T.loadAddonFile("The Guild Book gear/Storage.lua", GGM)
    T.loadAddonFile("The Guild Book/SavedCharacterModel.lua", GGM)
    T.loadAddonFile("The Guild Book/RecipeDetails.lua", GGM)
    T.loadAddonFile("The Guild Book/WindowSettings.lua", GGM)
    T.loadAddonFile("The Guild Book/MaterialTracker.lua", GGM)
    T.loadAddonFile("The Guild Book/MaterialTrackerBanks.lua", GGM)
    T.loadAddonFile("The Guild Book/ProfessionRecipeFilters.lua", GGM)
    GGM.__testBuiltInRecipeFilterModelBuilder = GGM.BuildProfessionRecipeFilterModel
    T.loadAddonFile("The Guild Book/MaterialTrackerUI.lua", GGM)
    T.loadAddonFile("The Guild Book/RecipeDetailsUI.lua", GGM)
    local bankView = loadfile("The Guild Book/BankView.lua")
    if bankView then bankView("The Guild Book", GGM) end
    local bankUI = loadfile("The Guild Book/BankUI.lua")
    if bankUI then bankUI("The Guild Book", GGM) end
    T.loadAddonFile("The Guild Book/SnapshotTestUI.lua", GGM)
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
    function control:SetEnabled(value) self.enabled = value end
    function control:SetNumeric(value) self.numeric = value end
    function control:SetMaxLetters(value) self.maxLetters = value end
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
    function control:GetScale() return self.scale or 1 end
    function control:GetEffectiveScale()
        return self:GetScale() * (self.parent and self.parent:GetEffectiveScale() or 1)
    end
    function control:GetLeft() return self.left end
    function control:GetRight() return self.left and (self.left + self:GetWidth()) or nil end
    function control:GetTop() return self.top end
    function control:SetFont(path, size, flags) self.font = { path = path, size = size, flags = flags } end
    function control:SetShadowColor(...) self.shadowColor = { ... } end
    function control:SetShadowOffset(...) self.shadowOffset = { ... } end
    function control:SetTextInsets(...) self.textInsets = { ... } end
    function control:SetPoint(point, relativeTo, relativePoint, x, y)
        self.point = { point = point, relativeTo = relativeTo, relativePoint = relativePoint, x = x, y = y }
        self.points = self.points or {}
        self.points[point] = self.point
    end
    function control:SetAllPoints(relativeTo) self.allPointsTo = relativeTo end
    function control:ClearAllPoints() self.point = nil; self.points = nil; self.allPointsTo = nil end
    function control:SetClampedToScreen(value) self.clampedToScreen = value end
    function control:SetJustifyH(value) self.justifyH = value end
    function control:SetAutoFocus() end
    function control:SetHeight(height) self.height = height end
    function control:SetWidth(width) self.width = width end
    function control:SetFrameStrata(value) self.strata = value end
    function control:SetFrameLevel(value) self.frameLevel = value end
    function control:GetFrameLevel()
        if self.frameLevel ~= nil then return self.frameLevel end
        if self.parent and self.parent.GetFrameLevel then return self.parent:GetFrameLevel() + 1 end
        return 0
    end
    function control:SetMovable(value) self.movable = value end
    function control:EnableMouse() end
    function control:RegisterForDrag() end
    function control:StartMoving() self.moving = true end
    function control:StopMovingOrSizing() self.moving = false end
    function control:IsShown() return self.visible end
    function control:SetVerticalScroll(value)
        self.verticalScroll = value
        if self.scripts.OnVerticalScroll then self.scripts.OnVerticalScroll(self, value) end
    end
    function control:GetVerticalScroll() return self.verticalScroll or 0 end
    function control:EnableMouseWheel(value) self.mouseWheelEnabled = value end
    function control:SetScript(name, callback) self.scripts[name] = callback end
    function control:SetMinMaxValues(minimum, maximum)
        self.minValue, self.maxValue = minimum, maximum
    end
    function control:SetValueStep(step) self.valueStep = step end
    function control:SetObeyStepOnDrag(value) self.obeyStepOnDrag = value end
    function control:SetValue(value)
        self.value = math.max(self.minValue or 0, math.min(self.maxValue or value, value))
        if self.scripts.OnValueChanged then self.scripts.OnValueChanged(self, self.value) end
    end
    function control:GetValue() return self.value or 0 end
    function control:RegisterForClicks() end
    function control:RegisterEvent(name) self.registeredEvents = self.registeredEvents or {}; self.registeredEvents[name] = true end
    function control:SetDesaturated(value) self.desaturated = value end
    function control:SetAlpha(value) self.alpha = value end
    function control:SetChecked(value) self.checked = value end
    function control:GetChecked() return self.checked end
    function control:SetCheckedTexture(texture) self.checkedTexture = texture end
    function control:SetNormalTexture(texture) self.normalTexture = texture end
    function control:SetBlendMode(value) self.blendMode = value end
    function control:SetVertexColor(...) self.vertexColor = { ... } end
    function control:SetTexture(value) self.texture = value; self.atlas = nil; self.color = nil end
    function control:SetColorTexture(...) self.color = { ... }; self.texture = nil; self.atlas = nil end
    function control:SetAtlas(value) self.atlas = value; self.texture = nil; self.color = nil end
    function control:SetTexCoord(...) self.texCoord = { ... } end
    function control:CreateFontString() return newControl() end
    function control:CreateTexture() return newControl() end
    function control:CreateMaskTexture() return newControl() end
    function control:AddMaskTexture(mask) self.mask = mask end
    return control
end

local function makeBrowserAPI(enforceNumericColorTexture)
    local api = {
        UIParent = newControl(),
        CreateFrame = function(frameType, name, parent, template)
            local frame = newControl()
            frame.name, frame.parent, frame.frameType, frame.template = name, parent, frameType, template
            frame.TitleText = newControl()
            function frame:SetScrollChild(child) self.scrollChild = child end
            if frameType == "ScrollFrame" and template == "UIPanelScrollFrameTemplate" then
                frame.ScrollBar = newControl()
                frame.ScrollBar.parent = frame
            end
            return frame
        end,
        date = function(_, timestamp) return "saved-" .. tostring(timestamp) end,
        GetItemIcon = function(itemID) return "item-icon:" .. tostring(itemID) end,
        GetInventorySlotInfo = function(slotName) return 1, "slot-icon:" .. slotName end,
    }
    if enforceNumericColorTexture then
        local originalCreateFrame = api.CreateFrame
        api.CreateFrame = function(frameType, name, parent, template)
            local frame = originalCreateFrame(frameType, name, parent, template)
            local originalCreateTexture = frame.CreateTexture
            frame.CreateTexture = function(self, ...)
                local texture = originalCreateTexture(self, ...)
                function texture:SetColorTexture(r, g, b, a)
                    T.assertTrue(type(r) == "number", "SetColorTexture r must be numeric")
                    T.assertTrue(type(g) == "number", "SetColorTexture g must be numeric")
                    T.assertTrue(type(b) == "number", "SetColorTexture b must be numeric")
                    T.assertTrue(type(a) == "number", "SetColorTexture a must be numeric")
                    self.color = { r, g, b, a }
                    self.texture = nil
                    self.atlas = nil
                end
                return texture
            end
            return frame
        end
    end
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
        if atlas == "classicon-warrior" or atlas == "classicon-mage" then return {} end
    end }
    api.GetPlayerInfoByGUID = function(guid)
        if guid == "Player-portrait-Alice" then return "Warrior", "WARRIOR" end
        if guid == "Player-portrait-Beatrice" then return "Mage", "MAGE" end
    end
    local createFrame = api.CreateFrame
    api.CreateFrame = function(frameType, name, parent)
        if failModelCreation and frameType == "Frame" and parent
            and parent.width == 208 and parent.point and parent.point.point == "TOP" then return nil end
        return createFrame(frameType, name, parent)
    end
    return api
end

local function setSavedModelIdentity(record)
    record.identity.guid = "Player-portrait-" .. record.identity.name
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

local function installCatalogOnlyFilterFixture(GGM, api)
    local builtInBuilder = GGM.__testBuiltInRecipeFilterModelBuilder
    local trade = api.C_TradeSkillUI
    if GGM.BuildProfessionRecipeFilterModel ~= builtInBuilder
        or type(GGM.BuildProfessionRecipeFilterModel) ~= "function"
        or (type(trade) == "table" and type(trade.IsTradeSkillReady) == "function"
            and type(trade.IsTradeSkillLinked) == "function" and type(trade.GetBaseProfessionInfo) == "function") then
        return
    end
    local buildLiveModel = GGM.BuildProfessionRecipeFilterModel
    GGM.BuildProfessionRecipeFilterModel = function(liveAPI, professionID, catalog, bankVerified, preserveCatalog)
        if preserveCatalog ~= true then
            return buildLiveModel(liveAPI, professionID, catalog, bankVerified, preserveCatalog)
        end
        local recipes = {}
        for _, entry in ipairs(catalog or {}) do
            local copy = {}
            for key, value in pairs(entry) do copy[key] = value end
            copy.learned, copy.craftable, copy.categoryIDs, copy.slotKeys = true, false, {}, {}
            recipes[#recipes + 1] = copy
        end
        return { state = "ready", professionID = professionID, recipes = recipes, categories = {}, slots = {},
            availability = { profession = "unavailable", materials = "available", bank = "verified",
                categories = "available", slots = "available" } }
    end
end

local function showBrowser(GGM, api, db)
    installCatalogOnlyFilterFixture(GGM, api)
    -- Gear fixtures explicitly open Characters; the default-view case uses the
    -- public opening function directly so it exercises the real initial tab.
    if not GGM.guildGearBrowserFrame then
        GGM.guildGearBrowserFrame = GGM.CreateGuildGearBrowserWindow(api)
        GGM.guildGearBrowserFrame.professionLibraryMode = "All"
        GGM.SelectGuildGearBrowserTab(GGM.guildGearBrowserFrame, "Character")
    end
    GGM.guildGearBrowserFrame.professionRecipeFilterState = GGM.guildGearBrowserFrame.professionRecipeFilterState
        or GGM.CreateProfessionRecipeFilterState()
    -- These fixtures exercise catalog behavior, not selected-character filters.
    GGM.guildGearBrowserFrame.professionRecipeFilterState.haveMaterials = false
    GGM.ShowGuildGearBrowserWindow(api, db)
    return GGM.guildGearBrowserFrame
end

local function showAllProfessionsBrowser(GGM, api, db)
    installCatalogOnlyFilterFixture(GGM, api)
    local frame = GGM.CreateGuildGearBrowserWindow(api)
    frame.professionLibraryMode = "All"
    GGM.guildGearBrowserFrame = frame
    frame.professionRecipeFilterState = frame.professionRecipeFilterState or GGM.CreateProfessionRecipeFilterState()
    -- Keep generic saved-catalog tests independent of live character metadata.
    frame.professionRecipeFilterState.haveMaterials = false
    GGM.ShowGuildGearBrowserWindow(api, db)
    return frame
end

local function selectAllProfessions(frame)
    frame.professionLibraryToggle.allRadio.scripts.OnClick(frame.professionLibraryToggle.allRadio)
end

T.test("browser opens Professions first, orders navigation, and remembers the session tab", function()
    local GGM = loadUI()
    local api, db = makeBrowserAPI(), makeDB(GGM)
    local syncCalls = 0
    GGM.professionSync = {}
    GGM.RequestProfessionSync = function()
        syncCalls = syncCalls + 1
        return true
    end
    local frame = GGM.CreateGuildGearBrowserWindow(api)
    GGM.guildGearBrowserFrame = frame
    T.assertEqual(syncCalls, 0, "constructing a hidden browser must not start profession sync")
    T.assertEqual(frame.activeTab, "Professions")
    T.assertEqual(frame.navigationTabs[1].key, "Professions")
    T.assertEqual(frame.navigationTabs[2].key, "Character")
    T.assertEqual(frame.navigationTabs[3].key, "Bank")
    T.assertTrue(frame.navigationTabs[1].point.y > frame.navigationTabs[2].point.y)
    T.assertTrue(frame.navigationTabs[2].point.y > frame.navigationTabs[3].point.y)

    GGM.ShowGuildGearBrowserWindow(api, db)
    T.assertEqual(frame.activeTab, "Professions")
    T.assertEqual(frame.pageTitle.text, "Professions")
    T.assertTrue(frame.professionsPage:IsShown())
    T.assertTrue(frame.navigationTabs[1].accent:IsShown())
    T.assertFalse(frame.navigationTabs[2].accent:IsShown())
    T.assertEqual(syncCalls, 0, "empty Own must not synchronize an unowned default profession")

    for index = 2, 3 do
        local tab = frame.navigationTabs[index]
        tab.scripts.OnClick(tab)
        frame:Hide()
        GGM.ShowGuildGearBrowserWindow(api, db)
        T.assertEqual(frame.activeTab, tab.key, "reopening must preserve the selected session tab")
        T.assertTrue(tab.accent:IsShown())
    end
    frame.activeTab = nil
    GGM.ShowGuildGearBrowserWindow(api, db)
    T.assertEqual(frame.activeTab, "Professions", "missing selection falls back to Professions")
end)

T.test("Own is the first default filter and both filters retain their meaning after reopening", function()
    local GGM = loadUI()
    local api, db = makeBrowserAPI(), makeDB(GGM)
    function api.UnitFullName() return "Alice", "Silvermoon" end
    function api.GetRealmName() return "Silvermoon" end
    function api.UnitGUID() return "Player-1" end
    db.professions = { ["Alice-Silvermoon"] = {
        identity = { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", guid = "Player-1" },
        snapshots = {
            [202] = { complete = true, professionID = 202, professionName = "Engineering",
                capturedAt = 1700000000, source = GGM.PROFESSION_SOURCE_PLAYER, status = GGM.PROFESSION_CACHE_STATUS },
            [197] = { complete = true, professionID = 197, professionName = "Tailoring",
                capturedAt = 1700000000, source = GGM.PROFESSION_SOURCE_PLAYER, status = GGM.PROFESSION_CACHE_STATUS },
        },
    } }
    GGM.ShowGuildGearBrowserWindow(api, db)
    local frame = GGM.guildGearBrowserFrame
    local toggle = frame.professionLibraryToggle
    T.assertEqual(frame.professionLibraryMode, "Own")
    T.assertEqual(toggle.ownRadio.label.text, "OWN")
    T.assertEqual(toggle.allRadio.label.text, "ALL")
    T.assertTrue(toggle.ownRadio.point.x < toggle.allRadio.point.x)
    T.assertTrue(toggle.ownRadio:GetChecked())
    T.assertFalse(toggle.allRadio:GetChecked())
    T.assertEqual(#frame.visibleProfessionEntries, 2)
    T.assertEqual(frame.selectedProfession, "Engineering")
    T.assertFalse(frame.professionButtons[1]:IsShown(), "unowned Alchemy must not appear in Own")

    toggle.allRadio.scripts.OnClick(toggle.allRadio)
    T.assertEqual(frame.professionLibraryMode, "All")
    T.assertTrue(toggle.allRadio:GetChecked())
    T.assertFalse(toggle.ownRadio:GetChecked())
    T.assertEqual(#frame.visibleProfessionEntries, #frame.professionButtons)
    toggle.ownRadio.scripts.OnClick(toggle.ownRadio)
    T.assertEqual(frame.professionLibraryMode, "Own")
    T.assertTrue(toggle.ownRadio:GetChecked())
    T.assertFalse(toggle.allRadio:GetChecked())
    T.assertEqual(#frame.visibleProfessionEntries, 2)
    toggle.allRadio.scripts.OnClick(toggle.allRadio)
    GGM.SelectProfession(frame, "Tailoring")
    frame.professionSearchBox:SetText("cloth")
    frame.professionRecipeScroll:SetVerticalScroll(18)
    frame:Hide()
    GGM.ShowGuildGearBrowserWindow(api, db)
    T.assertEqual(frame.professionLibraryMode, "Own")
    T.assertTrue(toggle.ownRadio:GetChecked())
    T.assertFalse(toggle.allRadio:GetChecked())
    T.assertEqual(#frame.visibleProfessionEntries, 2)
    T.assertEqual(frame.selectedProfession, "Tailoring", "reopening keeps a still-owned selection")
    T.assertEqual(frame.professionSearchBox:GetText(), "cloth")
    T.assertEqual(frame.professionRecipeScroll:GetVerticalScroll(), 0, "short results clamp the scroll offset")
end)

T.test("profession sync UI is silent while hidden and syncs clicked professions", function()
    local G = loadUI()
    local calls = {}
    G.professionSync = {}
    G.RequestProfessionSync = function(_, pid, reason)
        calls[#calls + 1] = { pid = pid, reason = reason }; return true
    end
    G.GetProfessionSyncStatus = function() return "Comparing cached data" end
    local frame = showBrowser(G, makeBrowserAPI(), makeDB(G, { makeRecord(G) }))
    T.assertEqual(#calls, 0)
    T.assertNil(frame.professionSyncButton)
    G.SelectGuildGearBrowserTab(frame, "Professions")
    T.assertEqual(#calls, 1)
    T.assertEqual(calls[1].pid, 171)
    T.assertEqual(calls[1].reason, "selection")
    G.SelectGuildGearBrowserTab(frame, "Character")
    G.SelectGuildGearBrowserTab(frame, "Professions")
    T.assertEqual(#calls, 1)
    G.SelectProfession(frame, "Blacksmithing")
    T.assertEqual(calls[2].pid, 164)
    for _, button in ipairs(frame.professionButtons) do
        if button.key == "Blacksmithing" then button.scripts.OnClick(button); button.scripts.OnClick(button) end
    end
    T.assertEqual(calls[3].pid, 164)
    T.assertEqual(calls[3].reason, "manual")
    T.assertEqual(calls[4].pid, 164)
end)

T.test("profession library uses the skill icons for Cooking, First Aid, and Leatherworking", function()
    local GGM = loadUI()
    local frame = showBrowser(GGM, makeBrowserAPI(), makeDB(GGM, { makeRecord(GGM) }))
    local icons = {}
    for _, button in ipairs(frame.professionButtons) do icons[button.key] = button.icon.texture end
    T.assertEqual(icons.Cooking, "Interface\\Icons\\INV_Misc_Food_15")
    T.assertEqual(icons["First Aid"], "Interface\\Icons\\Spell_Holy_SealOfSacrifice")
    T.assertEqual(icons.Leatherworking, "Interface\\Icons\\INV_Misc_ArmorKit_17")
end)

T.test("profession library scrolls all nine rows within its sidebar", function()
    local GGM = loadUI()
    local frame = showBrowser(GGM, makeBrowserAPI(), makeDB(GGM, { makeRecord(GGM) }))
    GGM.SelectGuildGearBrowserTab(frame, "Professions")
    local scroll = frame.professionLibraryScroll
    local content = frame.professionLibraryContent

    T.assertNotNil(scroll, "profession rows need a scroll viewport")
    T.assertEqual(scroll.template, "UIPanelScrollFrameTemplate")
    T.assertTrue(scroll.mouseWheelEnabled, "profession list needs mouse-wheel scrolling")
    T.assertTrue(scroll.scrollChild == content, "profession rows must be clipped by the viewport")
    T.assertEqual(#frame.visibleProfessionEntries, 9, "All mode should retain all profession entries")
    T.assertTrue(content.height > scroll.height, "the full profession list should extend beyond the viewport")
    T.assertTrue(scroll.ScrollBar.visible, "overflow should show the vertical scrollbar")
    T.assertTrue(scroll.point.x + scroll.width + 24 <= frame.professionSidebar.width,
        "the native scrollbar must stay within the profession sidebar")
    T.assertEqual(scroll.ScrollBar.maxValue, content.height - scroll.height,
        "the scrollbar range must expose the bottom of the final row")

    local lastButton = frame.visibleProfessionEntries[9]
    T.assertTrue(lastButton.parent == content, "the final profession row must live inside the scroll child")
    scroll.scripts.OnMouseWheel(scroll, -1)
    T.assertEqual(scroll.verticalScroll, 57, "one wheel notch should move one profession row")
    scroll.ScrollBar:SetValue(scroll.ScrollBar.maxValue)
    T.assertEqual(scroll.verticalScroll, scroll.ScrollBar.maxValue,
        "dragging the scrollbar to its end must reach the final profession row")
    T.assertEqual(-lastButton.point.y - scroll.verticalScroll + lastButton.height, scroll.height,
        "the final profession row should fit exactly at the end of the scroll range")
end)

T.test("profession clicks use the retained queued request path", function()
    local G = loadUI()
    local calls = {}
    G.professionSync = {}
    G.RequestProfessionSync = function() return false, "profession-sync-busy" end
    G.RequestProfessionSyncFromButton = function(sync, pid)
        T.assertEqual(sync, G.professionSync)
        calls[#calls + 1] = pid
        return true
    end
    G.GetProfessionSyncStatus = function() return "Sync queued: waiting for current comparison" end
    local frame = showBrowser(G, makeBrowserAPI(), makeDB(G, { makeRecord(G) }))
    G.SelectGuildGearBrowserTab(frame, "Professions")
    for _, button in ipairs(frame.professionButtons) do
        if button.key == "Blacksmithing" then button.scripts.OnClick(button) end
    end
    T.assertEqual(#calls, 1)
    T.assertEqual(calls[1], 164)
    T.assertEqual(frame.professionSyncStatus:GetText(), "Sync queued: waiting for current comparison")
end)

T.test("shared status is left aligned without a backing bar", function()
    local G = loadUI()
    local frame = showBrowser(G, makeBrowserAPI(), makeDB(G, { makeRecord(G) }))
    T.assertNil(frame.sharedStatusBackground, "shared status should not create a backing bar")
    T.assertNil(frame.professionSyncStatusBackground,
        "profession feedback should not create a backing bar")
    T.assertEqual(frame.sharedStatus.justifyH, "LEFT", "shared status text should align left")
end)

T.test("shared status stays in the header and carries the latest message across tabs", function()
    local GGM = loadUI()
    local frame = showBrowser(GGM, makeBrowserAPI(), makeDB(GGM, { makeRecord(GGM) }))
    T.assertTrue(frame.sharedStatus == frame.gearSyncStatus,
        "gear sync should use the shared status slot")
    T.assertTrue(frame.sharedStatus == frame.professionSyncStatus,
        "profession sync should use the shared status slot")

    GGM.SelectGuildGearBrowserTab(frame, "Professions")
    local message = frame.sharedStatus.text
    T.assertTrue(frame.sharedStatus.visible, "profession sync should display in the shared slot")
    T.assertEqual(message, "Sync unavailable")
    GGM.SelectGuildGearBrowserTab(frame, "Bank")
    T.assertEqual(frame.sharedStatus.text, message,
        "navigating should leave the latest shared status visible")
    T.assertTrue(frame.sharedStatus.visible)
    T.assertEqual(frame.sharedStatus.point.relativeTo, frame,
        "status position should remain anchored to the window")
end)

T.test("character content stays within the journal's painted page borders", function()
    local GGM = loadUI()
    local frame = showBrowser(GGM, makeBrowserAPI(), makeDB(GGM, { makeRecord(GGM) }))
    local detail = frame.gearPanel
    local inset = detail.background.point
    -- The fixture retains the last (bottom-right) anchor of the symmetric inset.
    T.assertTrue(detail.point.x - inset.x >= 635 and detail.point.x - inset.x <= 645, "detail misses the painted left border")
    T.assertTrue(-detail.point.y + inset.y >= 70 and -detail.point.y + inset.y <= 80, "detail misses the painted top border")
    T.assertTrue(detail.point.x + detail.width <= 1350, "detail extends beyond the painted right border")
    T.assertTrue(-detail.point.y + detail.height <= frame.height - 56, "detail extends beyond the painted bottom border")
    local libraryLeft = frame.searchPanel.point.x
    T.assertTrue(libraryLeft + frame.listPanel.width <= 620, "library divider extends beyond its painted border")
    T.assertTrue(libraryLeft + frame.listScroll.point.x + frame.listScroll.width + 24 <= 620,
        "native scrollbar extends beyond the library border")
    T.assertEqual(frame.capturedLine.point.relativeTo, frame.detailFooter,
        "capture date must be in the footer rather than beside the sync button")
    T.assertEqual(frame.capturedLine.point.point, "RIGHT")
    T.assertEqual(frame.capturedLine.justifyH, "RIGHT")
    T.assertEqual(frame.snapshotCaption.point.relativeTo, frame.capturedLine)
    T.assertEqual(frame.snapshotCaption.point.relativePoint, "LEFT")
    T.assertTrue(frame.snapshotCaption.point.x <= -8,
        "capture label needs a gap before the timestamp")
end)

T.test("journal headings reserve space for subtitles inside their columns", function()
    local GGM = loadUI()
    local frame = showBrowser(GGM, makeBrowserAPI(), makeDB(GGM, { makeRecord(GGM) }))
    T.assertTrue((frame.pageSubtitle.width or 0) > 0, "page subtitle needs a bounded wrapping region")
    T.assertTrue(frame.pageTitle.point.x + frame.pageSubtitle.width <= 620, "page subtitle crosses into the detail page")
    T.assertNil(frame.brandSubtitle, "brand subtitle should be removed")
end)

T.test("character realm stays left aligned beneath the character name", function()
    local GGM = loadUI()
    local frame = showBrowser(GGM, makeBrowserAPI(), makeDB(GGM, { makeRecord(GGM) }))
    T.assertEqual(frame.realmLine.justifyH, "LEFT")
    T.assertTrue(math.abs(frame.realmLine.point.x - frame.characterLine.point.x) <= 1,
        "realm label must share the name's left edge")
end)

T.test("equipment quickslot border stays behind the item artwork", function()
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
    for _, button in ipairs(frame.slotButtons) do
        T.assertEqual(button.quickslot.drawLayer, "BORDER",
            "padded quickslot artwork must not draw an inset box over the item")
        T.assertEqual(button.icon.drawLayer, "ARTWORK")
    end
end)

T.test("portrait decoration follows the portrait bounds without an overlay icon texture", function()
    local GGM = loadUI()
    local frame = showBrowser(GGM, makeModelBrowserAPI(), makeDB(GGM, { makeRecord(GGM) }))
    local view = frame.characterModelView
    T.assertTrue(view.portraitFrame.allPointsTo == view.model.portraitBorder,
        "portrait border must cover exactly the portrait surround")
    T.assertNil(view.portraitFrame.texture, "a padded icon texture must not cover the portrait")
    T.assertEqual(#view.portraitFrame.border, 4)
end)

T.test("character page uses blended artwork and captured date has a bounded region", function()
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
    T.assertEqual(frame.gearPanel.background.texture, GGM.UIJournalTextures.gearPage)
    T.assertEqual(frame.gearPanel.background.mask.texture, GGM.UIJournalTextures.professionMask)
    T.assertTrue(frame.gearPanel.background.mask.allPointsTo == frame.gearPanel.background,
        "armory page must blend into the same painted border as professions")
    T.assertTrue((frame.capturedLine.width or 0) >= 140,
        "capture date needs explicit space independent of caption autosizing")
    T.assertTrue((frame.capturedLine.height or 0) >= 14)
    T.assertTrue(frame.capturedLine.visible)
end)

T.test("character portrait and weapon labels have separate space above the footer", function()
    local GGM = loadUI()
    local api = makeBrowserAPI()
    api.GetItemInfo = function() return "The Untamed Blade" end
    local frame = showBrowser(GGM, api, makeDB(GGM, { makeRecord(GGM) }))
    local portraitBottom = -frame.modelStage.point.y + frame.modelStage.height
    local footerTop = frame.gearPanel.height - frame.detailFooter.point.y - frame.detailFooter.height
    for _, button in ipairs(frame.slotButtons) do
        if button.paperDollGroup == "bottom" then
            local top = -button.point.y - button.height / 2
            local labelsBottom = -button.point.y + button.height / 2 + 5
                + button.label.height + 1 + 14
            T.assertTrue(top >= portraitBottom + 8, "weapons overlap the saved portrait")
            T.assertTrue(button.label.height >= 42,
                "three-line weapon names need enough height to remain readable")
            T.assertEqual(button.label.text, "The Untamed Blade")
            T.assertTrue(labelsBottom <= footerTop - 6, "weapon labels overlap the footer")
        end
    end
end)

T.test("adjacent equipment rows leave room for icons and their separator", function()
    local GGM = loadUI()
    local frame = showBrowser(GGM, makeBrowserAPI(), makeDB(GGM, { makeRecord(GGM) }))
    local groups = { left = {}, right = {} }
    for _, button in ipairs(frame.slotButtons) do
        if groups[button.paperDollGroup] then
            groups[button.paperDollGroup][button.paperDollOrder] = button
        end
    end
    for _, rows in pairs(groups) do
        for index = 2, #rows do
            local previous, current = rows[index - 1], rows[index]
            local previousBottom = -previous.point.y + previous.height / 2
            local currentTop = -current.point.y - current.height / 2
            T.assertTrue(currentTop >= previousBottom + 3,
                "equipment icon and separator overlap the next row")
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
    api.C_SpellBook = { IsSpellKnown = function() return true end }
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
    local db = { schemaVersion = GGM.SCHEMA_VERSION, characters = {}, marker = "unchanged",
        localCharacterGUIDs = {
            ["Player-1234-Alice"] = true, ["Player-1234-Bob"] = true,
            ["Player-1234-Carol"] = true, ["Player-1234-Dave"] = true,
        } }
    GGM.db = db
    installProfessionCatalogStub(GGM, function() return professionCatalog("ready", recipes) end, {})
    local frame = showBrowser(GGM, api, db)
    GGM.SelectGuildGearBrowserTab(frame, "Professions")
    return GGM, api, frame, recipes, function() return reads end, db
end

local function exposeOwnProfession(GGM, browser, key)
    local button
    for _, entry in ipairs(browser.professionButtons) do
        if entry.key == key then button = entry; break end
    end
    T.assertNotNil(button, "owned profession button should exist")
    GGM.FilterProfessionLibraryEntries = function() return { button } end
end

T.test("recipe details show personal bank notes below individual materials without tracking", function()
    local G, api, browser, recipes, reads = recipeDetailsFixture()
    api.issecretvalue = function() return false end
    api.UnitFullName = function() return "Alice", "Realm" end
    local function bank(name, itemID, count, partial)
        return { identity = { key = name .. "-Realm", name = name, realm = "Realm",
                guid = "Player-1234-" .. name },
            status = partial and "incomplete" or "cached", capturedAt = 100,
            tabs = { [1] = { id = 1, name = "Personal", numSlots = 1, status = "cached", capturedAt = 100,
                slots = { { itemID = itemID, count = count } } } } }
    end
    api.TheGuildBookBankDB = { schemaVersion = 1, characters = {
        ["Alice-Realm"] = bank("Alice", 1, 4), ["Bob-Realm"] = bank("Bob", 1, 20, true),
        ["Carol-Realm"] = bank("Carol", 2, 7), ["Dave-Realm"] = bank("Dave", 3, 2),
    }, guilds = { ["Guild-Realm"] = bank("Guild", 1, 999) } }
    local details = G.ShowRecipeDetailsWindow(browser, recipes[1])
    T.assertNil(G.materialTrackerFrame)
    T.assertNotNil(details.materialRows[2].bankNote)
    T.assertFalse(details.materialRows[1].bankNote:IsShown(), "alternative heading has no item note")
    local note = details.materialRows[2].bankNote.text
    T.assertTrue(note:find("Your bank: 4", 1, true) ~= nil)
    T.assertTrue(note:find("Bob-Realm: at least 20 in personal bank", 1, true) ~= nil)
    T.assertNil(note:find("Available on", 1, true))
    T.assertTrue(note:find("last-known; incomplete", 1, true) ~= nil)
    T.assertNil(note:find("Carol", 1, true), "alternative items need their own quantities")
    T.assertNil(note:find("Guild", 1, true))
    T.assertTrue(details.materialRows[3].bankNote.text:find("Carol-Realm: 7", 1, true) ~= nil)
    T.assertTrue(details.materialRows[4].bankNote.text:find("Dave-Realm: 2", 1, true) ~= nil,
        "optional item notes do not depend on tracker required-only filtering")
    T.assertTrue(-details.materialRows[3].point.y >= details.materialRows[1].height + details.materialRows[2].height)
    local before = reads()
    details.materialScroll:SetVerticalScroll(12)
    api.TheGuildBookBankDB.characters["Bob-Realm"].tabs[1].slots[1].count = 9
    _G.GuildGearMemoryBankChanged()
    T.assertEqual(reads(), before, "bank changes reuse the current recipe model")
    T.assertEqual(details.materialScroll.verticalScroll, 12)
    T.assertTrue(details.materialRows[2].bankNote.text:find("at least 9", 1, true) ~= nil)
    api.TheGuildBookBankDB = nil
    details.materialScroll.GetVerticalScrollRange = function() return 0 end
    _G.GuildGearMemoryBankChanged()
    T.assertEqual(details.materialScroll.verticalScroll, 0, "clamp scrolling when removing bank notes shrinks the list")
    T.assertFalse(details.materialRows[2].bankNote:IsShown())
    T.assertEqual(details.materialRows[2].bankNote.text, "")
    T.assertEqual(details.materialRows[2].height, 32)
end)

T.test("recipe material refresh events preserve the current scroll position", function()
    local G, api, browser, recipes = recipeDetailsFixture()
    local materials = {}
    for index = 1, 20 do
        materials[index] = { quantity = 1, choices = {
            { itemID = index, name = "Material " .. index },
        } }
    end
    G.BuildRecipeMaterialDetails = function()
        return { state = "ready", materials = materials }
    end
    local details = G.ShowRecipeDetailsWindow(browser, recipes[1])
    for _, event in ipairs({ "GET_ITEM_INFO_RECEIVED", "TRADE_SKILL_LIST_UPDATE" }) do
        details.materialScroll:SetVerticalScroll(87)
        details.rosterEventFrame.scripts.OnEvent(details.rosterEventFrame, event)
        T.assertEqual(details.materialScroll.verticalScroll, 87,
            event .. " should retain the material list scroll position")
    end
end)

T.test("single recipe material bank note clears when rows are reused for currency or missing data", function()
    local G, api, browser, recipes = recipeDetailsFixture()
    api.issecretvalue = function() return false end
    local choice = { itemID = 1, name = "Rough Stone" }
    G.BuildRecipeMaterialDetails = function()
        return { state = "ready", materials = { { name = choice.name, quantity = 1, choices = { choice } } } }
    end
    api.TheGuildBookBankDB = { schemaVersion = 1, characters = { ["Bob-Realm"] = {
        identity = { key = "Bob-Realm", name = "Bob", realm = "Realm", guid = "Player-1234-Bob" },
        status = "cached", capturedAt = 100,
        tabs = { [1] = { id = 1, name = "Personal", numSlots = 1, status = "cached", capturedAt = 100,
            slots = { { itemID = 1, count = 20 } } } },
    } } }
    local details = G.ShowRecipeDetailsWindow(browser, recipes[1])
    T.assertNotNil(details.materialRows[1].bankNote)
    T.assertEqual(details.materialRows[1].bankNote.text, "Bob-Realm: 20 in personal bank (last-known)")
    T.assertTrue(details.materialRows[1].height > 32)
    choice = { currencyID = 1, name = "Currency" }
    G.ShowRecipeDetailsWindow(browser, recipes[1])
    T.assertFalse(details.materialRows[1].bankNote:IsShown())
    T.assertEqual(details.materialRows[1].height, 32)
    choice = { itemID = 900, name = "Missing item" }
    G.ShowRecipeDetailsWindow(browser, recipes[1])
    T.assertFalse(details.materialRows[1].bankNote:IsShown())
end)

T.test("changing profession library mode closes open recipe details", function()
    local GGM, _, browser, recipes = recipeDetailsFixture()
    local details = GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    T.assertTrue(details:IsShown())

    browser.professionLibraryToggle.ownRadio.scripts.OnClick(browser.professionLibraryToggle.ownRadio)
    T.assertEqual(browser.professionLibraryMode, "Own")
    T.assertFalse(details:IsShown())

    browser.professionLibraryToggle.allRadio.scripts.OnClick(browser.professionLibraryToggle.allRadio)
    details = GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    T.assertTrue(details:IsShown())
    browser.professionLibraryToggle.ownRadio.scripts.OnClick(browser.professionLibraryToggle.ownRadio)
    T.assertFalse(details:IsShown())
    browser.professionLibraryToggle.allRadio.scripts.OnClick(browser.professionLibraryToggle.allRadio)
    T.assertEqual(browser.professionLibraryMode, "All")
    T.assertFalse(details:IsShown())
end)

T.test("recipe list labels have explicit bounds inside their scroll rows", function()
    local _, _, browser, recipes = recipeDetailsFixture()
    for index, recipe in ipairs(recipes) do
        local row = browser.professionRecipeRows[index]
        T.assertEqual(row.name:GetText(), recipe.name)
        local top = row.name.points.TOPLEFT
        local bottom = row.name.points.BOTTOMRIGHT
        T.assertNotNil(top, "recipe label needs a top bound inside its scroll row")
        T.assertNotNil(bottom, "recipe label needs a bottom bound inside its scroll row")
        T.assertEqual(top.relativeTo, row)
        T.assertEqual(top.relativePoint, "TOPLEFT")
        T.assertEqual(bottom.relativeTo, row)
        T.assertEqual(bottom.relativePoint, "BOTTOMRIGHT")
        T.assertTrue(top.x > 38, "recipe text must clear the icon")
        T.assertTrue(bottom.x < 0, "recipe text must stay inside the right edge")
        local height = row:GetHeight() + top.y - bottom.y
        T.assertTrue(height >= row.name.font.size, "recipe label must have room for its font")
        T.assertTrue(height <= row:GetHeight(), "recipe label must stay inside the row")
    end
    browser.professionSearchBox:SetText("silver")
    T.assertEqual(browser.professionRecipeRows[1].name:GetText(), "Silver Ring")
end)

T.test("recipe track button uses Amount and tracker survives closing the browser with live counts", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    api.issecretvalue = function() return false end
    api.UnitGUID = function() return "Player-1-ABC" end
    local count = 1
    api.C_Item = { GetItemCount = function(id) return id == 1 and count or 0 end }
    local details = GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    T.assertNotNil(details.trackMaterialsButton)
    T.assertTrue(details.trackMaterialsButton.enabled)
    details.amountInput:SetText("3")
    details.trackMaterialsButton.scripts.OnClick()
    local tracker = GGM.materialTrackerFrame
    T.assertNotNil(tracker)
    T.assertTrue(tracker.parent == api.UIParent)
    T.assertEqual(tracker.rows[1].label.text, "Copper / Fine Copper: 1 / 9")
    T.assertEqual(tracker.snapshot.amount, 3)
    browser:Hide()
    T.assertTrue(tracker:IsShown())
    count = 9
    tracker.scripts.OnEvent(tracker, "BAG_UPDATE_DELAYED")
    T.assertEqual(tracker.rows[1].label.text, "Copper / Fine Copper: 9 / 9")
    T.assertEqual(tracker.rows[1].label.textColor[2], 1)
    count = 0
    tracker.scripts.OnEvent(tracker, "BAG_UPDATE_DELAYED")
    T.assertEqual(tracker.rows[1].label.text, "Copper / Fine Copper: 0 / 9")
    T.assertNotNil(GGM.LoadMaterialTracking(api, browser.db))
    tracker.untrackButton.scripts.OnClick()
    T.assertFalse(tracker:IsShown())
    T.assertNil(GGM.LoadMaterialTracking(api, browser.db))
end)

T.test("tracker personal bank toggle renders locations and refreshes without completing bag requirements", function()
    local G, api, browser, recipes = recipeDetailsFixture()
    api.issecretvalue = function() return false end
    api.UnitGUID = function() return "Player-1-ABC" end
    api.C_Item = { GetItemCount = function() return 0 end }
    api.UnitFullName = function() return "Alice", "Realm" end
    api.date = function(_, timestamp) return "time:" .. timestamp end
    local function bank(name, count)
        return { identity = { key = name .. "-Realm", name = name, realm = "Realm",
                guid = "Player-1234-" .. name },
            status = "cached", capturedAt = 100, tabs = { [1] = {
                id = 1, name = "Bank", status = "cached", capturedAt = 100, numSlots = 1,
                slots = { [1] = { itemID = 1, count = count } },
            } } }
    end
    api.TheGuildBookBankDB = { schemaVersion = 1, characters = {
        ["Alice-Realm"] = bank("Alice", 4), ["Bob-Realm"] = bank("Bob", 20),
    }, guilds = { ["Guild-Realm"] = bank("Guild", 999) } }
    G.ShowRecipeDetailsWindow(browser, recipes[1]).trackMaterialsButton.scripts.OnClick()
    local tracker = G.materialTrackerFrame
    T.assertNotNil(tracker.altMaterialsToggle)
    T.assertFalse(tracker.altMaterialsToggle:GetChecked())
    T.assertFalse(tracker.rows[1].bankDetails:IsShown())
    tracker.altMaterialsToggle:SetChecked(true)
    tracker.altMaterialsToggle.scripts.OnClick(tracker.altMaterialsToggle)
    local lines = tracker.rows[1].bankDetails.text
    T.assertTrue(lines:find("Your bank: 4", 1, true) ~= nil)
    T.assertTrue(lines:find("Bob-Realm - Bank: 20", 1, true) ~= nil)
    T.assertTrue(lines:find("last seen time:100", 1, true) ~= nil)
    T.assertNil(lines:find("Guild", 1, true))
    T.assertEqual(tracker.rows[1].label.text, "Copper / Fine Copper: 0 / 3")
    T.assertTrue(tracker.rows[1].label.textColor[2] < 1)
    T.assertTrue(G.LoadMaterialTracking(api, browser.db).showAltMaterials)
    browser:Hide()
    api.TheGuildBookBankDB.characters["Bob-Realm"].tabs[1].slots[1].count = 8
    api.UnitFullName = function() return "Alice", nil end
    api.GetRealmName = function() return "Realm" end
    _G.GuildGearMemoryBankChanged()
    T.assertTrue(tracker.rows[1].bankDetails.text:find("Bob-Realm - Bank: 8", 1, true) ~= nil)
    T.assertTrue(tracker.rows[1].bankDetails.text:find("Your bank: 4", 1, true) ~= nil)
    tracker.GetLeft, tracker.GetTop = function() return 800 end, function() return 700 end
    tracker.scripts.OnDragStop(tracker)
    T.assertTrue(G.LoadMaterialTracking(api, browser.db).showAltMaterials)
    local model = { state = "ready", materials = { { quantity = 1, choices = { { itemID = 1, name = "Copper" } } } } }
    G.TrackRecipeMaterials(api, browser.db, 124, "Replacement", 2, model)
    T.assertTrue(tracker.altMaterialsToggle:GetChecked())
    local fresh = loadUI()
    fresh.RestoreMaterialTracker(api, browser.db)
    T.assertTrue(fresh.materialTrackerFrame.altMaterialsToggle:GetChecked())
    tracker = fresh.materialTrackerFrame
    tracker.altMaterialsToggle:SetChecked(false)
    tracker.altMaterialsToggle.scripts.OnClick(tracker.altMaterialsToggle)
    T.assertFalse(tracker.rows[1].bankDetails:IsShown())
    T.assertFalse(fresh.LoadMaterialTracking(api, browser.db).showAltMaterials)
end)

T.test("tracker bank toggle handles missing companion and partial captures visibly", function()
    local G, api, browser, recipes = recipeDetailsFixture()
    api.issecretvalue = function() return false end
    api.UnitGUID = function() return "Player-1-ABC" end
    G.ShowRecipeDetailsWindow(browser, recipes[1]).trackMaterialsButton.scripts.OnClick()
    local tracker = G.materialTrackerFrame
    T.assertNotNil(tracker.altMaterialsToggle)
    tracker.altMaterialsToggle:SetChecked(true)
    tracker.altMaterialsToggle.scripts.OnClick(tracker.altMaterialsToggle)
    T.assertEqual(tracker.bankStatus.text, "Personal bank data unavailable.")
    api.TheGuildBookBankDB = { schemaVersion = 1, characters = {
        ["Bob-Realm"] = { identity = { key = "Bob-Realm", name = "Bob", realm = "Realm",
                guid = "Player-1234-Bob" },
            status = "incomplete", tabs = {} },
    } }
    G.RefreshMaterialTracker()
    T.assertTrue(tracker.rows[1].bankDetails.text:find("Bob-Realm - Bank: ?", 1, true) ~= nil)
    T.assertTrue(tracker.rows[1].bankDetails.text:find("incomplete", 1, true) ~= nil)
    tracker.untrackButton.scripts.OnClick()
    _G.GuildGearMemoryBankChanged()
    T.assertFalse(tracker:IsShown())
end)

T.test("recipe tracking toggles off on a second click even when Amount or material data is unavailable", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    api.issecretvalue = function() return false end
    api.UnitGUID = function() return "Player-1-ABC" end
    local details = GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    details.trackMaterialsButton.scripts.OnClick()
    local tracker = GGM.materialTrackerFrame
    T.assertTrue(tracker:IsShown())
    details.amountInput:SetText("0")
    T.assertTrue(details.trackMaterialsButton.enabled)
    GGM.BuildRecipeMaterialDetails = function() error("untracking must not read the recipe schematic") end
    details.trackMaterialsButton.scripts.OnClick()
    T.assertFalse(tracker:IsShown())
    T.assertNil(tracker.snapshot)
    T.assertNil(GGM.LoadMaterialTracking(api, browser.db))
    tracker.scripts.OnEvent(tracker, "BAG_UPDATE_DELAYED")
    T.assertFalse(tracker:IsShown())
    local fresh = loadUI()
    fresh.RestoreMaterialTracker(api, browser.db)
    T.assertNil(fresh.materialTrackerFrame)
end)

T.test("recipe tracking can be enabled again after toggling off", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    api.issecretvalue = function() return false end
    api.UnitGUID = function() return "Player-1-ABC" end
    local details = GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    details.trackMaterialsButton.scripts.OnClick()
    details.trackMaterialsButton.scripts.OnClick()
    T.assertFalse(GGM.materialTrackerFrame:IsShown())
    details.amountInput:SetText("2")
    details.trackMaterialsButton.scripts.OnClick()
    T.assertTrue(GGM.materialTrackerFrame:IsShown())
    T.assertEqual(GGM.LoadMaterialTracking(api, browser.db).amount, 2)
end)

T.test("tracker restores without browser and saves its position independently for each character", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    api.issecretvalue = function() return false end
    api.UnitGUID = function() return "Player-1-ABC" end
    local details = GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    T.assertNotNil(details.trackMaterialsButton)
    details.trackMaterialsButton.scripts.OnClick()
    local tracker = GGM.materialTrackerFrame
    tracker.GetLeft = function() return 800 end
    tracker.GetTop = function() return 700 end
    tracker.scripts.OnDragStop(tracker)
    local fresh = loadUI()
    fresh.RestoreMaterialTracker(api, browser.db)
    tracker = fresh.materialTrackerFrame
    T.assertTrue(tracker:IsShown())
    T.assertEqual(tracker.point.x, 800)
    T.assertEqual(tracker.point.y, 700)
    T.assertEqual(tracker.rows[1].label.text, "Copper / Fine Copper: ? / 3")
    T.assertNil(fresh.guildGearBrowserFrame)
    api.UnitGUID = function() return "Player-2-DEF" end
    fresh.RestoreMaterialTracker(api, browser.db)
    T.assertFalse(tracker:IsShown())
end)

T.test("tracker scrolls long lists and hides surplus rows when a shorter recipe replaces them", function()
    local GGM, api, browser = recipeDetailsFixture()
    api.issecretvalue = function() return false end
    api.UnitGUID = function() return "Player-1-ABC" end
    local model = { state = "ready", materials = {} }
    for index = 1, 20 do
        model.materials[index] = { quantity = 1, choices = { { itemID = index, name = "Material " .. index } } }
    end
    T.assertTrue(GGM.TrackRecipeMaterials(api, browser.db, 123, "Long recipe", 1, model))
    local tracker = GGM.materialTrackerFrame
    T.assertEqual(#tracker.rows, 20)
    T.assertTrue(tracker.content.height > tracker.height)
    T.assertTrue(tracker.scroll.scrollChild == tracker.content)
    model.materials = { model.materials[1] }
    T.assertTrue(GGM.TrackRecipeMaterials(api, browser.db, 124, "Short recipe", 1, model))
    T.assertTrue(GGM.materialTrackerFrame == tracker)
    T.assertTrue(tracker.rows[1]:IsShown())
    T.assertFalse(tracker.rows[20]:IsShown())
    T.assertEqual(tracker.scroll.verticalScroll, 0)
end)

T.test("recipe tracking rejects invalid Amount unavailable materials and refreshes once data is ready", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    api.issecretvalue = function() return false end
    api.UnitGUID = function() return "Player-1-ABC" end
    local details = GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    T.assertNotNil(details.trackMaterialsButton)
    details.amountInput:SetText("0")
    T.assertFalse(details.trackMaterialsButton.enabled)
    details.trackMaterialsButton.scripts.OnClick()
    T.assertNil(GGM.materialTrackerFrame)
    details = GGM.ShowRecipeDetailsWindow(browser, recipes[2])
    T.assertFalse(details.trackMaterialsButton.enabled)
    GGM.BuildRecipeMaterialDetails = function() return { state = "ready", materials = {
        { quantity = 2, choices = { { itemID = 4, name = "Silver" } } },
    } } end
    details.rosterEventFrame.scripts.OnEvent(nil, "PLAYER_REGEN_ENABLED")
    T.assertTrue(details.trackMaterialsButton.enabled)
    details.trackMaterialsButton.scripts.OnClick()
    T.assertEqual(GGM.materialTrackerFrame.snapshot.recipeID, 22)
    details = GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    details.trackMaterialsButton.scripts.OnClick()
    T.assertEqual(GGM.materialTrackerFrame.snapshot.recipeID, 11)
    T.assertEqual(#GGM.materialTrackerFrame.rows, 1)
end)

local function configureCrafterWhisperAPI(GGM, api, rows)
    local sent = {}
    GGM.professionRosterMembershipCurrent = true
    api.issecretvalue = function() return false end
    api.InCombatLockdown = function() return false end
    api.IsInGuild = function() return true end
    api.GetNumGuildMembers = function() return #rows end
    api.GetGuildRosterInfo = function(index)
        local row = rows[index]
        return row[1], nil, nil, nil, nil, nil, nil, nil, row[2]
    end
    api.C_ChatInfo = {
        InChatMessagingLockdown = function() return false end,
        SendChatMessage = function(message, channel, language, target)
            sent[#sent + 1] = { message, channel, language, target }
        end,
    }
    api.GetTime = function() return 10 end
    return sent
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

T.test("Own recipe details open for live recipes missing from the saved catalog", function()
    local GGM, _, browser = recipeDetailsFixture()
    browser.professionLibraryMode = "Own"
    browser.selectedProfession = "Blacksmithing"
    browser.selectedProfessionID = 164
    local liveRecipe = { recipeID = 33, name = "Replaced Servo Arm", outputIcon = 303, learned = false }
    browser.professionRecipeFilterModel = { professionID = 164, recipes = { liveRecipe } }
    browser.professionRecipeRows[1].recipe = liveRecipe

    browser.professionRecipeRows[1].scripts.OnClick(browser.professionRecipeRows[1])
    local details = browser.recipeDetailsFrame
    T.assertNotNil(details, "live Own recipes must open details even when absent from saved recipes")
    T.assertTrue(details:IsShown())
    T.assertEqual(details.recipeName.text, liveRecipe.name)

    GGM.RefreshRecipeDetailsWindow(browser)
    T.assertTrue(details:IsShown(), "live Own recipe details remain open during recipe refreshes")
    T.assertEqual(details.recipeName.text, liveRecipe.name)
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
    T.assertTrue(string.find(details.materialRows[4].label.text, "Polish", 1, true) ~= nil)
    T.assertEqual(#details.materialRows, 4, "single-choice materials should not repeat the item in a second row")
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

T.test("recipe detail whisper controls default to one and only an explicit click sends to the online selected crafter", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    local sent = {}
    api.issecretvalue = function() return false end
    api.InCombatLockdown = function() return false end
    api.IsInGuild = function() return true end
    api.GetNumGuildMembers = function() return 2 end
    api.GetGuildRosterInfo = function(index)
        if index == 1 then return "Alice-OtherRealm", nil, nil, nil, nil, nil, nil, nil, true end
        return "Alice-Realm", nil, nil, nil, nil, nil, nil, nil, true
    end
    api.C_ChatInfo = {
        InChatMessagingLockdown = function() return false end,
        SendChatMessage = function(message, channel, language, target)
            sent[#sent + 1] = { message, channel, language, target }
        end,
    }
    api.GetTime = function() return 10 end
    GGM.professionRosterMembershipCurrent = true

    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    local details = browser.recipeDetailsFrame
    T.assertEqual(details.amountInput:GetText(), "1")
    T.assertEqual(details.whisperButton.enabled, true)
    T.assertEqual(#sent, 0, "rendering must not send a whisper")
    details.amountInput:SetText("3")
    details.whisperButton.scripts.OnClick(details.whisperButton)

    T.assertEqual(#sent, 1)
    T.assertEqual(sent[1][1], "Hi! Do you have time to craft 3 x Copper Bracers for me?")
    T.assertEqual(sent[1][2], "WHISPER")
    T.assertEqual(sent[1][4], "Alice-Realm")
    T.assertTrue(string.find(details.whisperStatus.text, "Request attempted", 1, true) ~= nil)
end)

T.test("own Create All accepts counts above the manual amount limit", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    browser.professionLibraryMode = "Own"
    exposeOwnProfession(GGM, browser, "Blacksmithing")
    local opened, hidden = 0, 0
    api.C_TradeSkillUI = {
        GetTradeSkillLine = function() return 164, "Blacksmithing" end,
        GetTradeSkillLineForRecipe = function() return 164, "Blacksmithing", 164 end,
        OpenTradeSkill = function() opened = opened + 1; return true end,
        GetRecipeInfo = function(recipeID)
            return { recipeID = recipeID, learned = true, craftable = true }
        end,
        GetCraftableCount = function(recipeID)
            return 1200
        end,
        CraftRecipe = function(recipeID, quantity)
            api.craftCall = { recipeID, quantity }
            return true
        end,
    }
    api.HideUIPanel = function() hidden = hidden + 1 end
    api.ProfessionsFrame = {}
    api.issecretvalue = function() return false end
    api.InCombatLockdown = function() return false end

    GGM.SelectProfession(browser, "Blacksmithing")
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    local details = browser.recipeDetailsFrame
    T.assertTrue(details.createButton:IsShown())
    T.assertTrue(details.createAllButton:IsShown())
    T.assertFalse(details.whisperButton:IsShown())
    T.assertFalse(details.crafterDropdown:IsShown())
    T.assertEqual(details.createAllButton.label.text, "Create All [1200]")

    details.amountInput:SetText("3")
    details.createButton.scripts.OnClick(details.createButton)
    T.assertEqual(opened, 1)
    T.assertEqual(hidden, 1)
    T.assertEqual(api.craftCall[1], 11)
    T.assertEqual(api.craftCall[2], 3)

    details.amountInput:SetText("999")
    T.assertTrue(details.createButton.enabled)
    details.createButton.scripts.OnClick(details.createButton)
    T.assertEqual(api.craftCall[2], 999)

    details.amountInput:SetText("1000")
    T.assertFalse(details.createButton.enabled)

    details.createAllButton.scripts.OnClick(details.createAllButton)
    T.assertEqual(api.craftCall[2], 1200)
end)

T.test("Guild recipe details expose self-crafting from live learned data, not cached crafters", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    recipes[1].knownBy = { recipes[1].knownBy[1] }
    local opened, crafted = 0, 0
    api.C_TradeSkillUI = {
        OpenTradeSkill = function(skillLineID)
            T.assertEqual(skillLineID, 164)
            opened = opened + 1
            return true
        end,
        GetTradeSkillLine = function() return 164, "Blacksmithing" end,
        GetRecipeInfo = function(recipeID)
            return { recipeID = recipeID, learned = recipeID == 11, craftable = recipeID == 11 }
        end,
        GetCraftableCount = function() return 2 end,
        CraftRecipe = function(recipeID, quantity)
            T.assertEqual(recipeID, 11)
            T.assertEqual(quantity, 1)
            crafted = crafted + 1
            return true
        end,
    }
    api.issecretvalue = function() return false end
    api.InCombatLockdown = function() return false end
    GGM.SelectProfession(browser, "Blacksmithing")
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    local details = browser.recipeDetailsFrame
    T.assertEqual(opened, 1)
    T.assertTrue(details.whisperButton:IsShown())
    T.assertTrue(details.createButton:IsShown())
    T.assertTrue(details.createAllButton:IsShown())
    T.assertTrue(details.createButton.enabled)
    details.createButton.scripts.OnClick(details.createButton)
    T.assertEqual(crafted, 1)

    GGM.ShowRecipeDetailsWindow(browser, recipes[2])
    T.assertFalse(details.createButton:IsShown())
    T.assertFalse(details.createAllButton:IsShown())
end)

T.test("Guild Engineering self-crafting uses the current base profession API", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    local activeProfessionID = 202
    api.C_TradeSkillUI = {
        OpenTradeSkill = function(skillLineID)
            T.assertEqual(skillLineID, 202)
            return true
        end,
        GetBaseProfessionInfo = function() return { professionID = activeProfessionID } end,
        GetRecipeInfo = function(recipeID)
            return { recipeID = recipeID, learned = true, craftable = true }
        end,
        GetCraftableCount = function() return 2 end,
        CraftRecipe = function() return true end,
    }
    api.issecretvalue = function() return false end
    api.InCombatLockdown = function() return false end
    GGM.SelectProfession(browser, "Engineering")
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    local details = browser.recipeDetailsFrame
    T.assertTrue(details.whisperButton:IsShown())
    T.assertTrue(details.createButton:IsShown())
    T.assertTrue(details.createAllButton:IsShown())
    T.assertTrue(details.createButton.enabled)
    T.assertTrue(details.createAllButton.enabled)
    activeProfessionID = 164
    details.rosterEventFrame.scripts.OnEvent(details.rosterEventFrame, "TRADE_SKILL_LIST_UPDATE")
    T.assertFalse(details.createButton:IsShown())
    T.assertFalse(details.createAllButton:IsShown())
end)

T.test("Guild recipe details hide crafting when only the profession view knows the recipe", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    local playerKnowsRecipe = false
    api.C_TradeSkillUI = {
        OpenTradeSkill = function() return true end,
        GetBaseProfessionInfo = function() return { professionID = 202 } end,
        GetRecipeInfo = function(recipeID)
            return { recipeID = recipeID, learned = true, craftable = false }
        end,
        GetCraftableCount = function() return 0 end,
        CraftRecipe = function() error("must not craft an unlearned recipe") end,
    }
    api.C_SpellBook = { IsSpellKnown = function(recipeID)
        T.assertEqual(recipeID, recipes[1].recipeID)
        return playerKnowsRecipe
    end }
    api.issecretvalue = function() return false end
    api.InCombatLockdown = function() return false end
    GGM.SelectProfession(browser, "Engineering")
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    local details = browser.recipeDetailsFrame
    T.assertTrue(details.whisperButton:IsShown())
    T.assertFalse(details.createButton:IsShown())
    T.assertFalse(details.createAllButton:IsShown())
    playerKnowsRecipe = true
    details.rosterEventFrame.scripts.OnEvent(details.rosterEventFrame, "TRADE_SKILL_LIST_UPDATE")
    T.assertTrue(details.createButton:IsShown())
    T.assertTrue(details.createAllButton:IsShown())
    playerKnowsRecipe = false
    details.rosterEventFrame.scripts.OnEvent(details.rosterEventFrame, "TRADE_SKILL_LIST_UPDATE")
    T.assertFalse(details.createButton:IsShown())
    T.assertFalse(details.createAllButton:IsShown())
end)

T.test("Guild recipe details ignore cached self ownership when live learned data disagrees", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    recipes[1].knownBy[1].key = "Player-Realm"
    api.C_TradeSkillUI = {
        OpenTradeSkill = function() return true end,
        GetTradeSkillLine = function() return 164, "Blacksmithing" end,
        GetRecipeInfo = function(recipeID) return { recipeID = recipeID, learned = false, craftable = false } end,
        CraftRecipe = function() error("must not craft") end,
    }
    api.issecretvalue = function() return false end
    api.InCombatLockdown = function() return false end
    GGM.SelectProfession(browser, "Blacksmithing")
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    local details = browser.recipeDetailsFrame
    T.assertTrue(details.whisperButton:IsShown())
    T.assertFalse(details.createButton:IsShown())
    T.assertFalse(details.createAllButton:IsShown())
end)

T.test("Guild self-crafting places Whisper above both craft buttons and refreshes live state", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    local learned, craftable, inCombat = true, true, false
    api.C_TradeSkillUI = {
        OpenTradeSkill = function() return true end,
        GetTradeSkillLine = function() return 164, "Blacksmithing" end,
        GetRecipeInfo = function(recipeID)
            return { recipeID = recipeID, learned = learned, craftable = craftable }
        end,
        GetCraftableCount = function() return craftable and 2 or 0 end,
        CraftRecipe = function() return true end,
    }
    api.issecretvalue = function() return false end
    api.InCombatLockdown = function() return inCombat end
    GGM.SelectProfession(browser, "Blacksmithing")
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    local details = browser.recipeDetailsFrame
    T.assertTrue(details.whisperButton.point.y > details.createButton.point.y)
    T.assertTrue(details.createButton.point.y > details.createAllButton.point.y)
    T.assertTrue(details.createAllButton.point.y >= 30, "Create All should clear the lower border")
    T.assertTrue(details.createButton.point.y >= details.createAllButton.point.y + 32)
    T.assertTrue(details.whisperButton.point.y >= details.createButton.point.y + 32)
    T.assertTrue(details.crafterStatus.point.y >= details.whisperButton.point.y + 34)
    T.assertTrue(details.createButton.enabled)

    craftable = false
    details.rosterEventFrame.scripts.OnEvent(details.rosterEventFrame, "TRADE_SKILL_LIST_UPDATE")
    T.assertTrue(details.createButton:IsShown())
    T.assertFalse(details.createButton.enabled)
    learned, craftable = false, true
    details.rosterEventFrame.scripts.OnEvent(details.rosterEventFrame, "TRADE_SKILL_LIST_UPDATE")
    T.assertFalse(details.createButton:IsShown())
    learned = true
    details.rosterEventFrame.scripts.OnEvent(details.rosterEventFrame, "TRADE_SKILL_LIST_UPDATE")
    T.assertTrue(details.createButton:IsShown())
    inCombat = true
    details.rosterEventFrame.scripts.OnEvent(details.rosterEventFrame, "PLAYER_REGEN_DISABLED")
    T.assertFalse(details.createButton.enabled)
    inCombat = false
    details.rosterEventFrame.scripts.OnEvent(details.rosterEventFrame, "PLAYER_REGEN_ENABLED")
    T.assertTrue(details.createButton.enabled)
    details.rosterEventFrame.scripts.OnEvent(details.rosterEventFrame, "TRADE_SKILL_CLOSE")
    T.assertFalse(details.createButton:IsShown())
end)

T.test("Guild Create All count refreshes when a craft begins", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    local count = 2
    api.C_TradeSkillUI = {
        OpenTradeSkill = function() return true end,
        GetTradeSkillLine = function() return 164 end,
        GetRecipeInfo = function(recipeID)
            return { recipeID = recipeID, learned = true, craftable = count > 0 }
        end,
        GetCraftableCount = function() return count end,
        CraftRecipe = function() return true end,
    }
    api.issecretvalue = function() return false end
    api.InCombatLockdown = function() return false end
    GGM.SelectProfession(browser, "Blacksmithing")
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    local details = browser.recipeDetailsFrame
    T.assertEqual(details.createAllButton.label.text, "Create All [2]")
    count = 1
    details.rosterEventFrame.scripts.OnEvent(details.rosterEventFrame, "TRADE_SKILL_CRAFT_BEGIN")
    T.assertEqual(details.createAllButton.label.text, "Create All [1]")
end)

T.test("Guild recipe refresh removes craft buttons when live knowledge changes", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    local learned = true
    api.C_TradeSkillUI = {
        OpenTradeSkill = function() return true end,
        GetTradeSkillLine = function() return 164 end,
        GetRecipeInfo = function(recipeID)
            return { recipeID = recipeID, learned = learned, craftable = learned }
        end,
        CraftRecipe = function() return true end,
    }
    api.issecretvalue = function() return false end
    api.InCombatLockdown = function() return false end
    GGM.SelectProfession(browser, "Blacksmithing")
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    local details = browser.recipeDetailsFrame
    T.assertTrue(details.createButton:IsShown())
    learned = false
    GGM.RefreshRecipeDetailsWindow(browser)
    T.assertFalse(details.createButton:IsShown())
end)

T.test("Guild crafting shows its disabled reason until the player attempts a whisper", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    api.C_TradeSkillUI = {
        OpenTradeSkill = function() return true end,
        GetTradeSkillLine = function() return 164 end,
        GetRecipeInfo = function(recipeID)
            return { recipeID = recipeID, learned = true, craftable = false }
        end,
        CraftRecipe = function() return true end,
    }
    api.issecretvalue = function() return false end
    api.InCombatLockdown = function() return false end
    GGM.SelectProfession(browser, "Blacksmithing")
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    local details = browser.recipeDetailsFrame
    T.assertTrue(details.craftStatus:IsShown())
    T.assertFalse(details.whisperStatus:IsShown())
    details.whisperButton.scripts.OnClick(details.whisperButton)
    T.assertTrue(details.whisperStatus:IsShown())
end)

T.test("Guild craft click rejects a recipe removed from the current catalog", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    local crafted = 0
    api.C_TradeSkillUI = {
        OpenTradeSkill = function() return true end,
        GetTradeSkillLine = function() return 164 end,
        GetRecipeInfo = function(recipeID)
            return { recipeID = recipeID, learned = true, craftable = true }
        end,
        GetCraftableCount = function() return 1 end,
        CraftRecipe = function() crafted = crafted + 1; return true end,
    }
    api.issecretvalue = function() return false end
    api.InCombatLockdown = function() return false end
    GGM.SelectProfession(browser, "Blacksmithing")
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    local details = browser.recipeDetailsFrame
    T.assertTrue(details.createButton.enabled)
    browser.professionCatalog.recipes = { recipes[2] }
    details.createButton.scripts.OnClick(details.createButton)
    T.assertEqual(crafted, 0)
end)

T.test("Guild craft fails closed for the wrong live profession and protected craftability", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    local activeSkillLineID, protected = 164, false
    local crafted = 0
    api.C_TradeSkillUI = {
        OpenTradeSkill = function() return true end,
        GetTradeSkillLine = function() return activeSkillLineID end,
        GetRecipeInfo = function(recipeID)
            return { recipeID = recipeID, learned = true, craftable = true }
        end,
        GetCraftableCount = function() return 1 end,
        CraftRecipe = function() crafted = crafted + 1; return true end,
    }
    api.issecretvalue = function(value) return protected and value == true end
    api.InCombatLockdown = function() return false end
    GGM.SelectProfession(browser, "Blacksmithing")
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    local details = browser.recipeDetailsFrame
    T.assertTrue(details.createButton.enabled)
    activeSkillLineID = 171
    details.createButton.scripts.OnClick(details.createButton)
    T.assertEqual(crafted, 0)
    activeSkillLineID, protected = 164, true
    details.rosterEventFrame.scripts.OnEvent(details.rosterEventFrame, "TRADE_SKILL_LIST_UPDATE")
    T.assertFalse(details.createButton:IsShown())
end)

T.test("closing Guild recipe details keeps All filter context until the browser closes", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    local contextReady, closed, liveRecipeReads = false, 0, 0
    api.C_TradeSkillUI = {
        OpenTradeSkill = function() contextReady = true; return true end,
        CloseTradeSkill = function() contextReady = false; closed = closed + 1 end,
        IsTradeSkillReady = function() return contextReady end,
        IsTradeSkillLinked = function() return false end,
        GetBaseProfessionInfo = function() return { professionID = 164 } end,
        GetAllRecipeIDs = function()
            liveRecipeReads = liveRecipeReads + 1
            return { 11 }
        end,
        GetRecipeInfo = function(recipeID)
            return { recipeID = recipeID, name = "Copper Bracers", learned = true, craftable = true }
        end,
        CraftRecipe = function() return true end,
    }
    GGM.BuildProfessionRecipeFilterModel = GGM.__testBuiltInRecipeFilterModelBuilder
    api.issecretvalue = function() return false end
    api.InCombatLockdown = function() return false end
    GGM.SelectProfession(browser, "Blacksmithing")
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    T.assertEqual(browser.craftingContextSkillLineID, 164)
    browser.recipeDetailsFrame:Hide()
    T.assertEqual(closed, 0, "closing details must keep the browser's All-mode filter context open")
    T.assertEqual(browser.craftingContextSkillLineID, 164,
        "the selected profession context remains available to All filters")
    T.assertTrue(contextReady)

    browser.professionFilterEventFrame.scripts.OnEvent(browser.professionFilterEventFrame, "BAG_UPDATE_DELAYED")
    T.assertTrue(liveRecipeReads > 0, "bag changes rebuild live recipe metadata after details close")
    T.assertEqual(browser.professionRecipeFilterModel.availability.profession, "available",
        "the refreshed filter model still sees the selected character's live profession")
    local readsAfterBag = liveRecipeReads

    browser.professionFilterEventFrame.scripts.OnEvent(browser.professionFilterEventFrame, "BANKFRAME_OPENED")
    T.assertTrue(liveRecipeReads > readsAfterBag, "opening the selected character's bank refreshes live filters")
    local readsAfterBankOpen = liveRecipeReads
    browser.professionFilterEventFrame.scripts.OnEvent(browser.professionFilterEventFrame, "BANKFRAME_CLOSED")
    T.assertTrue(liveRecipeReads > readsAfterBankOpen, "closing the bank keeps live filters refreshable")

    browser:Hide()
    T.assertEqual(closed, 1, "closing the main browser releases the context it owns: details="
        .. tostring(browser.recipeDetailsFrame.openedCraftingContext)
        .. ", browser=" .. tostring(browser.craftingContextOpenedByGuildBook))
    T.assertNil(browser.craftingContextSkillLineID)
end)

T.test("opening a Guild recipe during combat waits for the Open profession click", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    local opened = 0
    local inCombat = true
    api.C_TradeSkillUI = {
        OpenTradeSkill = function()
            T.assertFalse(inCombat, "profession opening must wait until combat ends")
            opened = opened + 1
            return true
        end,
        GetTradeSkillLine = function() return 164 end,
        GetRecipeInfo = function(recipeID)
            return { recipeID = recipeID, learned = true, craftable = true }
        end,
        CraftRecipe = function() return true end,
    }
    api.issecretvalue = function() return false end
    api.InCombatLockdown = function() return inCombat end
    GGM.SelectProfession(browser, "Blacksmithing")
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    T.assertEqual(opened, 0)
    T.assertFalse(browser.recipeDetailsFrame.createButton:IsShown())
    inCombat = false
    browser.recipeDetailsFrame.rosterEventFrame.scripts.OnEvent(
        browser.recipeDetailsFrame.rosterEventFrame, "PLAYER_REGEN_ENABLED")
    T.assertEqual(opened, 0, "combat ending must not call the profession API")
    T.assertTrue(browser.recipeDetailsFrame.openProfessionButton:IsShown())
    T.assertTrue(browser.recipeDetailsFrame.openProfessionButton.enabled)
    browser.recipeDetailsFrame.openProfessionButton.scripts.OnClick(
        browser.recipeDetailsFrame.openProfessionButton)
    T.assertEqual(opened, 1)
    T.assertTrue(browser.recipeDetailsFrame.createButton:IsShown())
end)

T.test("Guild recipe crafting rejects a protected profession-open result", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    local protectedResult = {}
    api.C_TradeSkillUI = {
        OpenTradeSkill = function() return protectedResult end,
        GetTradeSkillLine = function() return 164 end,
        GetRecipeInfo = function(recipeID)
            return { recipeID = recipeID, learned = true, craftable = true }
        end,
        CraftRecipe = function() error("must not craft") end,
    }
    api.issecretvalue = function(value) return value == protectedResult end
    api.InCombatLockdown = function() return false end
    GGM.SelectProfession(browser, "Blacksmithing")
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    T.assertNil(browser.craftingContextSkillLineID)
    T.assertFalse(browser.recipeDetailsFrame.createButton:IsShown())
end)

T.test("Guild Create rejects unavailable craft counts while Own keeps its fallback", function()
    for _, countCase in ipairs({ "missing", "throwing", "protected" }) do
        local GGM, api, browser, recipes = recipeDetailsFixture()
        local crafted = 0
        api.C_TradeSkillUI = {
            OpenTradeSkill = function() return true end,
            GetTradeSkillLine = function() return 164 end,
            GetRecipeInfo = function(recipeID)
                return { recipeID = recipeID, learned = true, craftable = true }
            end,
            CraftRecipe = function() crafted = crafted + 1; return true end,
        }
        if countCase == "throwing" then
            api.C_TradeSkillUI.GetCraftableCount = function() error("unavailable") end
        elseif countCase == "protected" then
            api.C_TradeSkillUI.GetCraftableCount = function() return 3 end
        end
        api.issecretvalue = function(value) return countCase == "protected" and value == 3 end
        api.InCombatLockdown = function() return false end
        GGM.SelectProfession(browser, "Blacksmithing")
        GGM.ShowRecipeDetailsWindow(browser, recipes[1])
        local details = browser.recipeDetailsFrame
        T.assertFalse(details.createButton.enabled, countCase)
        details.createButton.scripts.OnClick(details.createButton)
        T.assertEqual(crafted, 0, countCase)
    end
end)

T.test("Guild Create rejects invalid amounts and reports a failed craft request", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    local attempts = 0
    api.C_TradeSkillUI = {
        OpenTradeSkill = function() return true end,
        GetTradeSkillLine = function() return 164 end,
        GetRecipeInfo = function(recipeID)
            return { recipeID = recipeID, learned = true, craftable = true }
        end,
        GetCraftableCount = function() return 3 end,
        CraftRecipe = function()
            attempts = attempts + 1
            return false
        end,
    }
    api.issecretvalue = function() return false end
    api.InCombatLockdown = function() return false end
    GGM.SelectProfession(browser, "Blacksmithing")
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    local details = browser.recipeDetailsFrame
    details.amountInput:SetText("0")
    T.assertFalse(details.createButton.enabled)
    details.createButton.scripts.OnClick(details.createButton)
    T.assertEqual(attempts, 0)

    details.amountInput:SetText("1")
    details.createButton.scripts.OnClick(details.createButton)
    T.assertEqual(attempts, 1)
    T.assertTrue(string.find(details.craftStatus.text, "could not be started", 1, true) ~= nil)
end)

T.test("own create remains available when Blizzard exposes craftability but not a maximum", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    browser.professionLibraryMode = "Own"
    exposeOwnProfession(GGM, browser, "Blacksmithing")
    api.C_TradeSkillUI = {
        GetTradeSkillLine = function() return 164, "Blacksmithing" end,
        GetTradeSkillLineForRecipe = function() return 164, "Blacksmithing", 164 end,
        OpenTradeSkill = function() return true end,
        CloseTradeSkill = function() end,
        GetRecipeInfo = function(recipeID)
            return { recipeID = recipeID, learned = true, craftable = true }
        end,
        CraftRecipe = function(recipeID, quantity)
            api.craftCall = { recipeID, quantity }
            return true
        end,
    }
    GGM.SelectProfession(browser, "Blacksmithing")
    api.issecretvalue = function() return false end
    api.InCombatLockdown = function() return false end

    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    local details = browser.recipeDetailsFrame
    T.assertTrue(details.createButton.enabled)
    T.assertFalse(details.createAllButton.enabled)
    details.createButton.scripts.OnClick(details.createButton)
    T.assertEqual(api.craftCall[2], 1)
end)

T.test("Own create still works when live recipe info omits learned", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    browser.professionLibraryMode = "Own"
    exposeOwnProfession(GGM, browser, "Blacksmithing")
    local crafted = 0
    api.C_TradeSkillUI = {
        OpenTradeSkill = function() return true end,
        GetRecipeInfo = function(recipeID) return { recipeID = recipeID, craftable = true } end,
        CraftRecipe = function() crafted = crafted + 1; return true end,
    }
    api.issecretvalue = function() return false end
    api.InCombatLockdown = function() return false end
    GGM.SelectProfession(browser, "Blacksmithing")
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    local details = browser.recipeDetailsFrame
    T.assertTrue(details.createButton.enabled)
    details.createButton.scripts.OnClick(details.createButton)
    T.assertEqual(crafted, 1)
end)

T.test("profession panel hide temporarily suppresses and then restores Blizzard OnHide", function()
    local GGM = loadUI()
    local onHideCalls, hideCalls = 0, 0
    local originalOnHide = function() onHideCalls = onHideCalls + 1 end
    local professionFrame = { onHide = originalOnHide }
    function professionFrame:GetScript(name)
        return name == "OnHide" and self.onHide or nil
    end
    function professionFrame:SetScript(name, script)
        if name == "OnHide" then self.onHide = script end
    end
    local api = {
        HideUIPanel = function(frame)
            hideCalls = hideCalls + 1
            if frame.onHide then frame.onHide() end
        end,
    }

    T.assertTrue(GGM.HideBlizzardProfessionPanel(api, professionFrame))
    T.assertEqual(hideCalls, 1)
    T.assertEqual(onHideCalls, 0)
    T.assertTrue(professionFrame.onHide == originalOnHide)
end)

T.test("closing the guild book closes the Blizzard profession context and frame", function()
    local GGM = loadUI()
    local closeCalls, hideCalls = 0, 0
    local api = {
        C_TradeSkillUI = { CloseTradeSkill = function() closeCalls = closeCalls + 1 end },
    }
    local professionFrame = { Hide = function() hideCalls = hideCalls + 1 end }
    local closed = GGM.CloseBlizzardProfessionPanel(api, professionFrame)
    T.assertTrue(closed)
    T.assertEqual(closeCalls, 1)
    T.assertEqual(hideCalls, 1)
end)

T.test("closing the guild book only closes a profession context it opened", function()
    local GGM = loadUI()
    local closeCalls, hideCalls = 0, 0
    local openCalls = 0
    local openedSkillLineID
    local api = makeBrowserAPI()
    api.C_TradeSkillUI = {
        OpenTradeSkill = function(skillLineID)
            openCalls = openCalls + 1
            openedSkillLineID = skillLineID
            return true
        end,
        CloseTradeSkill = function() closeCalls = closeCalls + 1 end,
    }
    api.HideUIPanel = function() end
    api.ProfessionsFrame = {
        Hide = function() hideCalls = hideCalls + 1 end,
    }
    local frame = GGM.CreateGuildGearBrowserWindow(api)
    frame.db = makeDB(GGM)

    frame.scripts.OnHide(frame)
    T.assertEqual(closeCalls, 0, "an independently opened profession context must remain open")
    T.assertEqual(hideCalls, 0, "the independently opened profession frame must remain visible")

    frame:Show()
    frame.professionLibraryMode = "Own"
    exposeOwnProfession(GGM, frame, "Alchemy")
    GGM.SelectProfession(frame, "Alchemy")
    T.assertEqual(openedSkillLineID, frame.selectedProfessionID)
    T.assertEqual(frame.craftingContextSkillLineID, frame.selectedProfessionID)

    GGM.guildGearBrowserFrame, GGM.db = frame, frame.db
    GGM.SelectGuildGearBrowserTab(frame, "Character")
    frame:Show()
    T.assertTrue(GGM.RefreshVisibleGuildGearBrowser())
    T.assertEqual(openCalls, 1, "a Characters refresh must not open a profession context")
    T.assertEqual(frame.craftingContextSkillLineID, openedSkillLineID)
    T.assertTrue(frame.craftingContextOpenedByGuildBook,
        "a Characters refresh must preserve ownership so closing can clean up")

    frame.scripts.OnHide(frame)
    T.assertEqual(closeCalls, 1)
    T.assertEqual(hideCalls, 1)
    T.assertNil(frame.craftingContextSkillLineID)
end)

T.test("selecting an own profession opens and immediately hides Blizzard's profession window", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    browser.professionLibraryMode = "Own"
    exposeOwnProfession(GGM, browser, "Blacksmithing")
    local openedSkillLine
    api.C_TradeSkillUI = {
        GetTradeSkillLine = function() return 164, "Blacksmithing" end,
        GetRecipeInfo = function(recipeID) return { recipeID = recipeID, learned = true, craftable = true } end,
        GetTradeSkillLineForRecipe = function() return 164, "Blacksmithing", 164 end,
        OpenTradeSkill = function(skillLineID) openedSkillLine = skillLineID; return true end,
        GetCraftableCount = function() return 31 end,
        CraftRecipe = function() return true end,
    }
    api.issecretvalue = function() return false end
    api.InCombatLockdown = function() return false end
    local hidden, lowered = 0, 0
    api.HideUIPanel = function() hidden = hidden + 1 end
    api.ProfessionsFrame = { SetFrameStrata = function() lowered = lowered + 1 end }

    GGM.SelectProfession(browser, "Blacksmithing")
    T.assertEqual(openedSkillLine, browser.selectedProfessionID)
    T.assertEqual(hidden, 1)
end)

T.test("opening an All recipe preserves an already visible Blizzard profession panel", function()
    local GGM = loadUI()
    local hidden, restyled = 0, 0
    local professionFrame = {
        IsShown = function() return true end,
        Hide = function() hidden = hidden + 1 end,
        SetFrameStrata = function() restyled = restyled + 1 end,
        SetFrameLevel = function() restyled = restyled + 1 end,
    }
    local frame = {
        professionLibraryMode = "All",
        api = {
            InCombatLockdown = function() return false end,
            issecretvalue = function() return false end,
            ProfessionsFrame = professionFrame,
            C_TradeSkillUI = { OpenTradeSkill = function() return true end },
        },
    }

    T.assertTrue(GGM.OpenSelectedProfessionContext(frame, 164, true))
    T.assertEqual(hidden, 0, "an existing panel must stay visible")
    T.assertEqual(restyled, 0, "an existing panel must keep its presentation")
    T.assertFalse(frame.craftingContextOpenedByGuildBook)
end)

T.test("clicking an own recipe row does not open Blizzard's profession window", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    browser.professionLibraryMode = "Own"
    exposeOwnProfession(GGM, browser, "Blacksmithing")
    GGM.BuildProfessionRecipeFilterModel = function(_, professionID, catalog)
        local filtered = {}
        for _, recipe in ipairs(catalog) do
            local copy = {}
            for key, value in pairs(recipe) do copy[key] = value end
            copy.learned, copy.craftable = true, true
            copy.categoryIDs, copy.slotKeys = {}, {}
            filtered[#filtered + 1] = copy
        end
        return { state = "ready", professionID = professionID, recipes = filtered, categories = {}, slots = {} }
    end
    local opened = 0
    api.C_TradeSkillUI = {
        GetTradeSkillLineForRecipe = function() return 164, "Blacksmithing", 164 end,
        OpenTradeSkill = function() opened = opened + 1; return true end,
        GetRecipeInfo = function(recipeID) return { recipeID = recipeID, learned = true, craftable = true } end,
        GetRecipeSchematic = function() return { reagentSlotSchematics = {} } end,
    }
    api.issecretvalue = function() return false end
    api.InCombatLockdown = function() return false end

    GGM.SelectProfession(browser, "Blacksmithing")
    local openedAfterSelection = opened
    browser.professionRecipeRows[1].scripts.OnClick(browser.professionRecipeRows[1])

    T.assertEqual(opened, openedAfterSelection)
    T.assertTrue(browser.recipeDetailsFrame:IsShown())
end)

T.test("craft click falls back to the selected profession when recipe skill-line data is secret", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    browser.professionLibraryMode = "Own"
    exposeOwnProfession(GGM, browser, "Blacksmithing")
    local openedSkillLine
    api.C_TradeSkillUI = {
        GetTradeSkillLineForRecipe = function() return {} end,
        OpenTradeSkill = function(skillLineID) openedSkillLine = skillLineID; return true end,
        GetRecipeInfo = function(recipeID) return { recipeID = recipeID, learned = true, craftable = true } end,
        GetRecipeSchematic = function() return { reagentSlotSchematics = {} } end,
        GetCraftableCount = function() return 1 end,
        CraftRecipe = function() return true end,
        CloseTradeSkill = function() end,
    }
    api.issecretvalue = function(value) return type(value) == "table" end
    api.InCombatLockdown = function() return false end

    GGM.SelectProfession(browser, "Blacksmithing")
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    local details = browser.recipeDetailsFrame
    details.createButton.scripts.OnClick(details.createButton)
    T.assertEqual(openedSkillLine, browser.selectedProfessionID)
end)

T.test("craft click opens the selected profession without recipe skill-line discovery", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    browser.professionLibraryMode = "Own"
    exposeOwnProfession(GGM, browser, "Blacksmithing")
    local openedSkillLine
    api.C_TradeSkillUI = {
        OpenTradeSkill = function(skillLineID) openedSkillLine = skillLineID; return true end,
        GetRecipeInfo = function(recipeID) return { recipeID = recipeID, learned = true, craftable = true } end,
        GetRecipeSchematic = function() return { reagentSlotSchematics = {} } end,
        GetCraftableCount = function() return 1 end,
        CraftRecipe = function() return true end,
        CloseTradeSkill = function() end,
    }
    api.issecretvalue = function() return false end
    api.InCombatLockdown = function() return false end

    GGM.SelectProfession(browser, "Blacksmithing")
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    browser.recipeDetailsFrame.createButton.scripts.OnClick(browser.recipeDetailsFrame.createButton)

    T.assertEqual(openedSkillLine, browser.selectedProfessionID)
end)

T.test("crafter whisper amount is preserved for same recipe and reset for a new recipe", function()
    local GGM, _, browser, recipes = recipeDetailsFixture()
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    local details = browser.recipeDetailsFrame
    details.amountInput:SetText("8")
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    T.assertEqual(details.amountInput:GetText(), "8")
    GGM.ShowRecipeDetailsWindow(browser, recipes[2])
    T.assertEqual(details.amountInput:GetText(), "1")
end)

T.test("crafter whisper rejects invalid amounts and rechecks online status on click and roster events", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    local rows = { { "Alice-Realm", true }, { "Bob-Realm", true } }
    local sent = configureCrafterWhisperAPI(GGM, api, rows)
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    local details = browser.recipeDetailsFrame
    for _, amount in ipairs({ "0", "1000", "2.5", "-1", "" }) do
        details.amountInput:SetText(amount)
        T.assertFalse(details.whisperButton.enabled, "invalid amount should disable the action: " .. amount)
        details.whisperButton.scripts.OnClick(details.whisperButton)
        T.assertEqual(#sent, 0)
    end
    details.amountInput:SetText("2")
    rows[1][2] = false
    details.whisperButton.scripts.OnClick(details.whisperButton)
    T.assertEqual(#sent, 0, "click must recheck presence after selection state changed")
    details.rosterEventFrame.scripts.OnEvent(details.rosterEventFrame, "GUILD_ROSTER_UPDATE")
    T.assertTrue(string.find(details.whisperPresenceStatus.text, "Offline", 1, true) ~= nil)
    T.assertFalse(details.whisperButton.enabled)
end)

T.test("crafter whisper respects combat and chat restrictions and never retries through a fallback API", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    local rows = { { "Alice-Realm", true }, { "Bob-Realm", true } }
    local sent = configureCrafterWhisperAPI(GGM, api, rows)
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    local details = browser.recipeDetailsFrame

    api.InCombatLockdown = function() return true end
    details.whisperButton.scripts.OnClick(details.whisperButton)
    T.assertEqual(#sent, 0)
    api.InCombatLockdown = function() return false end
    api.C_ChatInfo.InChatMessagingLockdown = function() return true end
    details.whisperButton.scripts.OnClick(details.whisperButton)
    T.assertEqual(#sent, 0)

    api.C_ChatInfo.InChatMessagingLockdown = function() return false end
    local primaryCalls, fallbackCalls = 0, 0
    api.C_ChatInfo.SendChatMessage = function() primaryCalls = primaryCalls + 1; error("restricted") end
    api.SendChatMessage = function() fallbackCalls = fallbackCalls + 1 end
    details.whisperButton.scripts.OnClick(details.whisperButton)
    T.assertEqual(primaryCalls, 1)
    T.assertEqual(fallbackCalls, 0)
    T.assertTrue(string.find(details.whisperStatus.text, "unavailable", 1, true) ~= nil)
end)

T.test("crafter whisper applies a local cooldown and renders unavailable when required checks are missing", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    local rows = { { "Alice-Realm", true }, { "Bob-Realm", true } }
    local sent = configureCrafterWhisperAPI(GGM, api, rows)
    local now = 10
    local cooldownCallback
    api.GetTime = function() return now end
    api.C_Timer = { After = function(seconds, callback)
        T.assertEqual(seconds, 2)
        cooldownCallback = callback
    end }
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    local details = browser.recipeDetailsFrame
    details.whisperButton.scripts.OnClick(details.whisperButton)
    details.whisperButton.scripts.OnClick(details.whisperButton)
    T.assertEqual(#sent, 1)
    T.assertFalse(details.whisperButton.enabled)
    now = 13
    cooldownCallback()
    T.assertTrue(details.whisperButton.enabled)
    details.whisperButton.scripts.OnClick(details.whisperButton)
    T.assertEqual(#sent, 2)

    api.issecretvalue = nil
    details.rosterEventFrame.scripts.OnEvent(details.rosterEventFrame, "PLAYER_REGEN_ENABLED")
    T.assertFalse(details.whisperButton.enabled)
    T.assertTrue(string.find(details.whisperPresenceStatus.text, "Unavailable", 1, true) ~= nil)
end)

T.test("crafter whisper uses the supported legacy sender only when the modern sender is absent", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    local rows = { { "Alice-Realm", true }, { "Bob-Realm", true } }
    local sent = configureCrafterWhisperAPI(GGM, api, rows)
    api.C_ChatInfo.SendChatMessage = nil
    local legacyCalls = 0
    api.SendChatMessage = function(message, channel, language, target)
        legacyCalls = legacyCalls + 1
        sent[#sent + 1] = { message, channel, language, target }
    end
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    local details = browser.recipeDetailsFrame
    details.whisperButton.scripts.OnClick(details.whisperButton)
    T.assertEqual(legacyCalls, 1)
    T.assertEqual(sent[1][2], "WHISPER")
    T.assertEqual(sent[1][4], "Alice-Realm")
end)

T.test("crafter whisper rejects recipe names that cannot fit a normal chat message", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    local rows = { { "Alice-Realm", true }, { "Bob-Realm", true } }
    local sent = configureCrafterWhisperAPI(GGM, api, rows)
    recipes[1].name = string.rep("Long recipe ", 30)
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    local details = browser.recipeDetailsFrame
    details.whisperButton.scripts.OnClick(details.whisperButton)
    T.assertEqual(#sent, 0)
    T.assertTrue(string.find(details.whisperStatus.text, "too long", 1, true) ~= nil)
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

T.test("item data loaded during combat preserves materials and retries after combat", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    local buildCount = 0
    GGM.BuildRecipeMaterialDetails = function()
        buildCount = buildCount + 1
        if buildCount == 2 then
            return { state = "unavailable", materials = {}, message = "Materials unavailable." }
        end
        return { state = "ready", materials = {
            { name = "Metal", quantity = 3, optional = false, choices = { { itemID = 44, name = "Copper" } } },
        }, pendingItemIDs = { [44] = true } }
    end
    api.InCombatLockdown = function() return false end
    api.issecretvalue = function() return false end
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    local details = browser.recipeDetailsFrame
    local originalModel = details.materialModel
    local originalPending = details.pendingMaterialItemIDs

    api.InCombatLockdown = function() return true end
    details.rosterEventFrame.scripts.OnEvent(details.rosterEventFrame, "ITEM_DATA_LOAD_RESULT", 44, true)
    T.assertEqual(details.materialModel, originalModel, "unavailable combat result must retain visible materials")
    T.assertEqual(details.pendingMaterialItemIDs, originalPending, "unavailable combat result must retain pending item IDs")
    T.assertEqual(buildCount, 2)

    api.InCombatLockdown = function() return false end
    details.rosterEventFrame.scripts.OnEvent(details.rosterEventFrame, "PLAYER_REGEN_ENABLED")
    T.assertEqual(buildCount, 3, "regen should retry the materials model")
    T.assertEqual(details.materialModel.state, "ready")
    T.assertEqual(details.pendingMaterialItemIDs[44], true)
end)

T.test("item metadata refresh preserves the material list scroll offset", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    GGM.BuildRecipeMaterialDetails = function()
        return { state = "ready", materials = {
            { name = "Metal", quantity = 3, optional = false, choices = {
                { itemID = 44, name = "Copper", icon = 10 },
            } },
        }, pendingItemIDs = { [44] = true } }
    end
    api.issecretvalue = function() return false end
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    local details = browser.recipeDetailsFrame
    details.materialScroll:SetVerticalScroll(37)
    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    T.assertEqual(details.materialScroll:GetVerticalScroll(), 0, "opening the recipe should start at the top")
    details.materialScroll:SetVerticalScroll(37)

    details.rosterEventFrame.scripts.OnEvent(details.rosterEventFrame, "ITEM_DATA_LOAD_RESULT", 44, true)

    T.assertEqual(details.materialScroll:GetVerticalScroll(), 37)
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

T.test("taller equipment window preserves the navigation artwork scale on every tab", function()
    local GGM = loadUI()
    local frame = showBrowser(GGM, makeBrowserAPI(), makeDB(GGM, { makeRecord(GGM) }))
    for _, tab in ipairs({ "Character", "Professions", "Bank" }) do
        GGM.SelectGuildGearBrowserTab(frame, tab)
        local top, bottom = frame.navigationBackdropTop, frame.navigationBackdropBottom
        T.assertTrue(top ~= nil and bottom ~= nil, "shared navigation needs its own unstretched artwork")
        T.assertEqual(top.texture, GGM.UIJournalTextures.window)
        T.assertEqual(top.width, GGM.UIStyleTokens.railWidth)
        T.assertTrue(top.height >= 332, "all three painted navigation rows must retain their original scale")
        T.assertEqual(top.point.y, 0)
        T.assertEqual(top.texCoord[1], 0)
        T.assertEqual(top.texCoord[3], 0)
        T.assertTrue(math.abs(top.width / top.texCoord[2] - 1400) < 0.001,
            "navigation artwork must retain its original horizontal scale")
        T.assertTrue(math.abs(top.height / top.texCoord[4] - 630) < 0.001,
            "navigation artwork must retain its original vertical scale")
        T.assertEqual(bottom.texCoord[3], top.texCoord[4])
        T.assertEqual(bottom.texCoord[4], 1)
        T.assertEqual(bottom.points.TOPLEFT.y, -top.height)
        T.assertEqual(bottom.points.BOTTOMLEFT.y, 0)
        T.assertTrue(bottom.points.BOTTOMLEFT.relativeTo == frame)
    end
end)

T.test("journal window uses the reference canvas size, custom backdrop, and screen-fit scale", function()
    local GGM = loadUI()
    local api = makeBrowserAPI()
    local frame = GGM.CreateGuildGearBrowserWindow(api)
    local separator = string.char(92)
    local mediaPath = table.concat({
        "Interface", "AddOns", "The Guild Book", "Media", "ArtisanJournal", "",
    }, separator)

    T.assertEqual(frame.width, 1400)
    T.assertEqual(frame.height, 694)
    T.assertNil(frame.template)
    T.assertEqual(frame.background.texture, mediaPath .. "journal-window.blp")
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

T.test("closing the browser leaves a profession frame open if it was already open", function()
    local GGM = loadUI()
    local hideCount = 0
    local professionFrame = {
        shown = true,
        IsShown = function(self) return self.shown end,
        Hide = function(self) hideCount = hideCount + 1; self.shown = false end,
        SetFrameStrata = function() end,
        SetFrameLevel = function() end,
    }
    local api = makeBrowserAPI()
    api.ProfessionsFrame = professionFrame
    api.C_TradeSkillUI = { OpenTradeSkill = function() return true end }
    local frame = GGM.CreateGuildGearBrowserWindow(api)
    frame.db = makeDB(GGM)
    frame:Show()
    frame.professionLibraryMode = "Own"

    GGM.SelectProfession(frame, "Alchemy")
    frame.scripts.OnHide(frame)

    T.assertEqual(hideCount, 0)
    T.assertTrue(professionFrame.shown)
end)

T.test("closing the browser hides a profession frame that it opened", function()
    local GGM = loadUI()
    local hideCount = 0
    local professionFrame = {
        shown = false,
        IsShown = function(self) return self.shown end,
        Hide = function(self) hideCount = hideCount + 1; self.shown = false end,
        SetFrameStrata = function() end,
        SetFrameLevel = function() end,
    }
    local api = makeBrowserAPI()
    api.ProfessionsFrame = professionFrame
    api.C_TradeSkillUI = { OpenTradeSkill = function() return true end }
    local frame = GGM.CreateGuildGearBrowserWindow(api)
    frame.db = makeDB(GGM)
    frame:Show()
    frame.professionLibraryMode = "Own"

    GGM.SelectProfession(frame, "Alchemy")
    frame.scripts.OnHide(frame)

    T.assertEqual(hideCount, 1)
    T.assertFalse(professionFrame.shown)
end)

T.test("journal profession page follows the parchment reference proportions and typography", function()
    local GGM = loadUI()
    local frame = GGM.CreateGuildGearBrowserWindow(makeBrowserAPI())
    local ui = GGM.UIStyleTokens
    GGM.SelectGuildGearBrowserTab(frame, "Professions")

    T.assertEqual(ui.windowWidth, 1400)
    T.assertEqual(ui.windowHeight, 694)
    T.assertEqual(ui.professionLibraryX, 314)
    T.assertEqual(ui.professionDetailX, 629)
    T.assertEqual(ui.professionLibraryTop, 145)
    T.assertEqual(frame.pageTitle.text, "Professions")
    T.assertEqual(frame.pageTitle.font.path, GGM.UIJournalTextures.boldFont)
    T.assertEqual(frame.pageTitle.font.size, 26)
    T.assertEqual(frame.pageTitle.font.flags, "")
    T.assertEqual(frame.pageTitle.shadowColor[4], 0)
    T.assertEqual(frame.pageTitle.shadowOffset[1], 0)
    T.assertEqual(frame.pageSubtitle.font.path, GGM.UIJournalTextures.font)
    local toggle = frame.professionLibraryToggle
    GGM.SelectGuildGearBrowserTab(frame, "Character")
    T.assertFalse(toggle:IsShown(), "profession toggle must be hidden outside the Professions page")
    GGM.SelectGuildGearBrowserTab(frame, "Professions")
    T.assertTrue(toggle:IsShown(), "profession toggle must show on the Professions page")
    GGM.SelectGuildGearBrowserTab(frame, "Character")
    T.assertFalse(toggle:IsShown(), "profession toggle must hide on the Characters page")
    GGM.SelectGuildGearBrowserTab(frame, "Bank")
    T.assertFalse(toggle:IsShown(), "profession toggle must hide on the Bank page")
    GGM.SelectGuildGearBrowserTab(frame, "Professions")
    T.assertTrue(toggle:IsShown(), "profession toggle must show again on the Professions page")
    T.assertTrue(toggle.parent == frame.professionsPage,
        "profession toggle must be parented to the Professions page")
    T.assertEqual(toggle.point.relativeTo, frame.professionSidebar)
    T.assertEqual(toggle.point.relativePoint, "TOPLEFT")
    T.assertEqual(toggle.point.x, 34)
    T.assertTrue(toggle.point.y ~= frame.professionLibraryEmpty.point.y,
        "toggle must not reuse the empty-state anchor")
    T.assertTrue(toggle.point.y > frame.professionLibraryHeading.point.y,
        "toggle must sit above the Profession Library heading in the journal")
    T.assertTrue(toggle.allRadio ~= nil, "All radio control must exist")
    T.assertTrue(toggle.ownRadio ~= nil, "Own radio control must exist")
    T.assertEqual(toggle.allRadio.label.text, "ALL")
    T.assertEqual(toggle.ownRadio.label.text, "OWN")
    T.assertEqual(toggle.allRadio.label.journalFont, frame.professionLibraryHeading.journalFont)
    T.assertEqual(toggle.allRadio.label.journalFontSize, frame.professionLibraryHeading.journalFontSize)
    T.assertFalse(toggle.allRadio:GetChecked())
    T.assertTrue(toggle.ownRadio:GetChecked())
    T.assertTrue(toggle.ownRadio.point.x < toggle.allRadio.point.x)
    T.assertTrue(toggle.height >= 20, "radio controls need a dedicated horizontal layout height")
    T.assertEqual(toggle.allRadio.point.relativeTo, toggle)
    T.assertEqual(toggle.ownRadio.point.relativeTo, toggle)
    T.assertTrue(toggle.point.y >= frame.professionLibraryHeading.point.y + 20,
        "radio controls must remain above the Profession Library heading")
    T.assertEqual(toggle.allRadio.checkedTexture.texture,
        "Interface\\AddOns\\The Guild Book\\Media\\ArtisanJournal\\profession-radio-checked")
    T.assertEqual(toggle.allRadio.uncheckedTexture.texture,
        "Interface\\AddOns\\The Guild Book\\Media\\ArtisanJournal\\profession-radio-unchecked")
    T.assertEqual(toggle.allRadio.normalTexture, toggle.allRadio.uncheckedTexture)
    T.assertEqual(frame.professionLibraryScroll.point.relativeTo, frame.professionSidebar)
    T.assertEqual(frame.professionLibraryScroll.point.x, 30)
    T.assertEqual(frame.professionLibraryScroll.point.y, -58)
    T.assertEqual(frame.professionButtons[1].point.relativeTo, frame.professionLibraryContent)
    T.assertEqual(frame.professionButtons[1].point.relativePoint, "TOPLEFT")
    T.assertEqual(frame.professionButtons[1].point.x, 4)
    T.assertEqual(frame.professionButtons[1].point.y, -4)
    T.assertEqual(frame.professionButtons[1].width, 231)
    T.assertEqual(frame.professionButtons[1].height, 48)
    T.assertEqual(frame.professionLibraryScroll.point.x + frame.professionButtons[1].point.x, 34)
    T.assertEqual(frame.professionLibraryScroll.point.y + frame.professionButtons[1].point.y, -62)
    T.assertEqual(frame.professionButtons[1].background.texture, GGM.UIJournalTextures.professionButton)
    T.assertEqual(frame.professionButtons[1].background.texCoord[1], 0.03085)
    T.assertEqual(frame.professionButtons[1].background.texCoord[2], 0.96961)
    T.assertEqual(frame.professionButtons[1].background.texCoord[3], 0.23757)
    T.assertEqual(frame.professionButtons[1].background.texCoord[4], 0.76520)
    T.assertEqual(frame.professionButtons[1].label.font.path, GGM.UIJournalTextures.boldFont)
    T.assertEqual(frame.professionSearchBox.width, 310)
    T.assertEqual(frame.professionSearchBox.height, 27)
    T.assertEqual(frame.professionSubtitle.width, 280,
        "profession subtitle should stay within the clear column under the icon")
    T.assertEqual(frame.professionSubtitle.point.relativeTo, frame.professionHeroIconFrame,
        "profession subtitle should be anchored below the profession icon")
    T.assertEqual(frame.professionSubtitle.point.point, "TOPLEFT")
    T.assertEqual(frame.professionSubtitle.point.relativePoint, "BOTTOMLEFT")
    T.assertEqual(frame.professionSubtitle.point.x, 0)
    T.assertEqual(frame.professionSubtitle.point.y, -6)
    T.assertEqual(frame.professionSubtitle.journalFontSize, 15)
    T.assertTrue(frame.sharedStatus == frame.professionSyncStatus,
        "profession sync feedback should use the shared status slot")
    T.assertEqual(frame.sharedStatus.point.relativeTo, frame)
    T.assertEqual(frame.sharedStatus.point.point, "TOPLEFT")
    T.assertEqual(frame.sharedStatus.point.x, ui.professionDetailX)
    T.assertEqual(frame.sharedStatus.point.y, -36)
    T.assertEqual(frame.sharedStatus.width, 480)
    T.assertEqual(frame.sharedStatus.height, 20)
    T.assertEqual(frame.sharedStatus.justifyH, "LEFT")
    T.assertNil(frame.sharedStatusBackground, "shared status should have no backing bar")
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

T.test("profession library toggle filters by selected character without changing recipe state", function()
    local GGM = loadUI()
    local api = makeBrowserAPI()
    function api.UnitFullName() return "Alice", "Silvermoon" end
    function api.GetRealmName() return "Silvermoon" end
    function api.UnitGUID() return "Player-1" end
    local aliceRecord = makeRecord(GGM)
    local bobRecord = makeRecord(GGM)
    bobRecord.identity = { key = "Beatrice-ArgentDawn", name = "Beatrice", realm = "ArgentDawn" }
    local frame = showBrowser(GGM, api, makeDB(GGM, { aliceRecord, bobRecord }))
    local alice = frame.selectedEntry.key
    local bob = "Beatrice-ArgentDawn"
    frame.db.professions = {
        [alice] = { identity = { key = alice, name = "Alice", realm = "Silvermoon", guid = "Player-1" }, snapshots = {
            [171] = { complete = true, professionID = 171, professionName = "Alchemy",
                capturedAt = 1700000000, source = GGM.PROFESSION_SOURCE_PLAYER,
                status = GGM.PROFESSION_CACHE_STATUS },
        } },
        [bob] = { identity = { key = bob, name = "Beatrice", realm = "ArgentDawn", guid = "Player-2" }, snapshots = {
            [164] = { complete = true, professionID = 164, professionName = "Blacksmithing",
                capturedAt = 1700000000, source = GGM.PROFESSION_SOURCE_PLAYER,
                status = GGM.PROFESSION_CACHE_STATUS },
        } },
    }
    GGM.GetProfessionSyncStatus = function() return "Compared cached data" end
    GGM.SelectGuildGearBrowserTab(frame, "Professions")
    local selectedProfession, selectedCatalog, selectedSearch = frame.selectedProfession,
        frame.professionCatalog, frame.professionSearchBox:GetText()
    local selectedSyncStatus = frame.professionSyncStatus.text
    local selectedSyncSelections = frame.professionSyncSelections
    local selectedSnapshot = frame.db.professions[alice].snapshots[171]
    T.assertEqual(frame.professionLibraryMode, "All")
    T.assertEqual(frame.professionLibraryToggle.allRadio.label.text, "ALL")
    T.assertEqual(frame.professionLibraryToggle.ownRadio.label.text, "OWN")
    T.assertTrue(frame.professionLibraryToggle.allRadio:GetChecked())
    T.assertFalse(frame.professionLibraryToggle.ownRadio:GetChecked())
    T.assertTrue(frame.professionButtons[1]:IsShown())
    T.assertTrue(frame.professionButtons[2]:IsShown())

    frame.professionLibraryToggle.ownRadio.scripts.OnClick(frame.professionLibraryToggle.ownRadio)
    T.assertEqual(frame.professionLibraryMode, "Own")
    T.assertFalse(frame.professionLibraryToggle.allRadio:GetChecked())
    T.assertTrue(frame.professionLibraryToggle.ownRadio:GetChecked())
    T.assertTrue(frame.professionButtons[1]:IsShown())
    T.assertFalse(frame.professionButtons[2]:IsShown())
    T.assertEqual(frame.selectedProfession, selectedProfession)
    T.assertEqual(frame.professionSearchBox:GetText(), selectedSearch)
    T.assertEqual(frame.professionCatalog.state, selectedCatalog.state)
    T.assertEqual(#frame.professionCatalog.recipes, #selectedCatalog.recipes)
    for index, recipe in ipairs(selectedCatalog.recipes) do
        T.assertEqual(frame.professionCatalog.recipes[index].recipeID, recipe.recipeID)
        T.assertEqual(frame.professionCatalog.recipes[index].name, recipe.name)
    end
    T.assertEqual(frame.db.professions[alice].snapshots[171], selectedSnapshot)
    T.assertEqual(frame.db.professions[alice].snapshots[171].status, GGM.PROFESSION_CACHE_STATUS)
    T.assertEqual(frame.professionSyncStatus.text, selectedSyncStatus)
    T.assertTrue(frame.professionSyncSelections == selectedSyncSelections)

    GGM.SelectGuildGearBrowserTab(frame, "Character")
    frame.listRows[2].scripts.OnClick(frame.listRows[2])
    GGM.SelectGuildGearBrowserTab(frame, "Professions")
    T.assertTrue(frame.professionButtons[1]:IsShown())
    T.assertFalse(frame.professionButtons[2]:IsShown())
    T.assertEqual(frame.db.professions[alice].snapshots[171].status, GGM.PROFESSION_CACHE_STATUS)
    T.assertEqual(frame.professionSyncStatus.text, selectedSyncStatus)

    frame.professionLibraryToggle.allRadio.scripts.OnClick(frame.professionLibraryToggle.allRadio)
    T.assertEqual(frame.professionLibraryMode, "All")
    for _, button in ipairs(frame.professionButtons) do T.assertTrue(button:IsShown()) end
    T.assertEqual(frame.db.professions[bob].snapshots[164].status, GGM.PROFESSION_CACHE_STATUS)
    T.assertEqual(frame.professionSyncStatus.text, selectedSyncStatus)
end)

T.test("switching to Own opens the selected owned profession and closes recipe details", function()
    local GGM, api, browser, recipes = recipeDetailsFixture()
    local openedSkillLine
    api.UnitFullName = function() return "Alice", "Realm" end
    api.GetRealmName = function() return "Realm" end
    api.UnitGUID = function() return "Player-1" end
    api.C_TradeSkillUI = {
        OpenTradeSkill = function(skillLineID)
            openedSkillLine = skillLineID
            return true
        end,
    }
    local alchemyButton = browser.professionButtons[1]
    GGM.FilterProfessionLibraryEntries = function() return { alchemyButton } end

    GGM.ShowRecipeDetailsWindow(browser, recipes[1])
    T.assertTrue(browser.recipeDetailsFrame:IsShown())
    T.assertNil(browser.craftingContextSkillLineID)

    browser.professionLibraryToggle.ownRadio.scripts.OnClick(browser.professionLibraryToggle.ownRadio)

    T.assertEqual(browser.professionLibraryMode, "Own")
    T.assertEqual(openedSkillLine, 171)
    T.assertEqual(browser.craftingContextSkillLineID, 171)
    T.assertFalse(browser.recipeDetailsFrame:IsShown())
end)

T.test("profession library Own mode uses the active player identity instead of selected entry", function()
    local GGM = loadUI()
    local api = makeBrowserAPI()
    function api.UnitFullName(unit) T.assertEqual(unit, "player"); return "Alice", "Silvermoon" end
    function api.GetRealmName() return "Silvermoon" end
    function api.UnitGUID(unit) T.assertEqual(unit, "player"); return "Player-1" end
    local aliceRecord = makeRecord(GGM)
    local bobRecord = makeRecord(GGM)
    bobRecord.identity = { key = "Beatrice-ArgentDawn", name = "Beatrice", realm = "ArgentDawn" }
    local frame = showBrowser(GGM, api, makeDB(GGM, { aliceRecord, bobRecord }))
    local filterKey
    local aliceButton = frame.professionButtons[1]
    GGM.FilterProfessionLibraryEntries = function(entries, _, characterKey)
        filterKey = characterKey
        return { aliceButton }
    end
    frame.db.professions = {
        [aliceRecord.identity.key] = { snapshots = { [171] = {
            complete = true, professionID = 171, professionName = "Alchemy",
            capturedAt = 1700000000, source = GGM.PROFESSION_SOURCE_PLAYER,
            status = GGM.PROFESSION_CACHE_STATUS,
        } } },
        [bobRecord.identity.key] = { snapshots = { [164] = {
            complete = true, professionID = 164, professionName = "Blacksmithing",
            capturedAt = 1700000000, source = GGM.PROFESSION_SOURCE_PLAYER,
            status = GGM.PROFESSION_CACHE_STATUS,
        } } },
    }
    frame.selectedEntry = frame.entries[2]
    GGM.SelectGuildGearBrowserTab(frame, "Professions")
    frame.professionLibraryToggle.ownRadio.scripts.OnClick(frame.professionLibraryToggle.ownRadio)
    T.assertEqual(frame.professionLibraryMode, "Own")
    T.assertEqual(filterKey, "Alice-Silvermoon")
    T.assertEqual(#frame.visibleProfessionEntries, 1)
    T.assertEqual(frame.visibleProfessionEntries[1].key, "Alchemy")
end)

T.test("profession library Own mode shows an empty state for a character without snapshots", function()
    local GGM = loadUI()
    local frame = showBrowser(GGM, makeBrowserAPI(), makeDB(GGM, { makeRecord(GGM) }))
    frame.db.professions = {}
    GGM.SelectGuildGearBrowserTab(frame, "Professions")
    frame.professionLibraryToggle.ownRadio.scripts.OnClick(frame.professionLibraryToggle.ownRadio)
    T.assertEqual(frame.professionLibraryMode, "Own")
    for _, button in ipairs(frame.professionButtons) do T.assertFalse(button:IsShown()) end
    T.assertTrue(frame.professionLibraryEmpty:IsShown())
    T.assertTrue(frame.professionLibraryEmpty.text:find("No captured professions", 1, true) ~= nil)
end)

T.test("empty Own clears an All recipe selection and stays empty across refresh and reopen", function()
    local GGM, api, frame, recipes = recipeDetailsFixture()
    frame.db.professions = {}
    GGM.ShowRecipeDetailsWindow(frame, recipes[1])
    frame.professionLibraryToggle.ownRadio.scripts.OnClick(frame.professionLibraryToggle.ownRadio)
    local function assertEmpty()
        T.assertNil(frame.selectedProfession)
        T.assertNil(frame.selectedProfessionID)
        T.assertFalse(frame.professionDetailPanel:IsShown())
        T.assertEqual(#frame.filteredProfessionRecipes, 0)
        for _, row in ipairs(frame.professionRecipeRows) do T.assertFalse(row:IsShown()) end
        T.assertFalse(frame.recipeDetailsFrame:IsShown())
    end
    assertEmpty()
    GGM.RefreshVisibleProfessionCatalog()
    GGM.SelectGuildGearBrowserTab(frame, "Character")
    GGM.SelectGuildGearBrowserTab(frame, "Professions")
    assertEmpty()
    frame:Hide()
    GGM.ShowGuildGearBrowserWindow(api, frame.db)
    assertEmpty()
    frame.professionLibraryToggle.allRadio.scripts.OnClick(frame.professionLibraryToggle.allRadio)
    T.assertEqual(frame.selectedProfession, "Alchemy")
    T.assertTrue(frame.professionDetailPanel:IsShown())
    T.assertEqual(frame.professionRecipeRows[1].name:GetText(), recipes[1].name)
end)

T.test("opening empty Own never builds or syncs the default Alchemy catalog", function()
    local GGM, api = loadUI(), makeBrowserAPI()
    local calls = {}
    installProfessionCatalogStub(GGM, function()
        error("empty Own must not read an unowned recipe catalog")
    end, calls)
    GGM.professionSync = {}
    GGM.RequestProfessionSync = function() error("empty Own must not sync an unowned profession") end
    GGM.ShowGuildGearBrowserWindow(api, makeDB(GGM))
    local frame = GGM.guildGearBrowserFrame
    T.assertEqual(frame.professionLibraryMode, "Own")
    T.assertNil(frame.selectedProfession)
    T.assertFalse(frame.professionDetailPanel:IsShown())
    T.assertTrue(frame.professionLibraryEmpty:IsShown())
    T.assertEqual(#calls, 0)
end)

T.test("switching to Own replaces an unowned selection with a listed profession", function()
    local GGM, _, frame = recipeDetailsFixture()
    local engineering = frame.professionButtons[5]
    GGM.FilterProfessionLibraryEntries = function() return { engineering } end
    frame.professionLibraryToggle.ownRadio.scripts.OnClick(frame.professionLibraryToggle.ownRadio)
    T.assertEqual(frame.selectedProfession, "Engineering")
    T.assertEqual(frame.selectedProfessionID, 202)
    T.assertTrue(frame.professionDetailPanel:IsShown())
    GGM.FilterProfessionLibraryEntries = function() return {} end
    GGM.RefreshVisibleProfessionLibrary(frame)
    T.assertNil(frame.selectedProfession)
    T.assertFalse(frame.professionDetailPanel:IsShown())
end)

T.test("profession selection changes the full page artwork for each supported profession", function()
    local GGM = loadUI()
    local frame = GGM.CreateGuildGearBrowserWindow(makeBrowserAPI())
    local separator = string.char(92)
    local mediaPath = table.concat({
        "Interface", "AddOns", "The Guild Book", "Media", "ArtisanJournal", "",
    }, separator)
    local expected = {
        { key = "Alchemy", texture = mediaPath .. "alchemy-page.blp" },
        { key = "Blacksmithing", texture = mediaPath .. "blacksmithing-page.blp" },
        { key = "Cooking", texture = mediaPath .. "cooking-page.tga" },
        { key = "Enchanting", texture = mediaPath .. "enchanting-page.blp" },
        { key = "Engineering", texture = mediaPath .. "engineering-page.blp" },
        { key = "First Aid", texture = mediaPath .. "first-aid-page.tga" },
        { key = "Fishing", texture = mediaPath .. "fishing-page.tga" },
        { key = "Leatherworking", texture = mediaPath .. "leatherworking-page.blp" },
        { key = "Tailoring", texture = mediaPath .. "tailoring-page.blp" },
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
    frame.professionLibraryToggle.allRadio.scripts.OnClick(frame.professionLibraryToggle.allRadio)
    GGM.ShowGuildGearBrowserWindow(api, db)
    local initialBuilds = #calls
    T.assertTrue(initialBuilds > 0)
    T.assertTrue(calls[1].db == db)
    T.assertEqual(calls[1].professionID, 171)
    T.assertTrue(calls[1].api == api)

    local expected = {
        { key = "Alchemy", id = 171 }, { key = "Blacksmithing", id = 164 },
        { key = "Cooking", id = 185 }, { key = "Enchanting", id = 333 },
        { key = "Engineering", id = 202 }, { key = "First Aid", id = 129 },
        { key = "Fishing", id = 356 }, { key = "Leatherworking", id = 165 },
        { key = "Tailoring", id = 197 },
    }
    T.assertEqual(calls[1].professionID, expected[1].id)
    for index = 2, #expected do
        local profession = expected[index]
        local button = frame.professionButtons[index]
        T.assertEqual(button.professionID, profession.id)
        T.assertEqual(button.key, profession.key)
        button.scripts.OnClick(button)
        T.assertEqual(frame.selectedProfession, profession.key)
        T.assertEqual(#calls, initialBuilds + index - 1, "each profession selection should build one local catalog")
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
    GGM.SelectGuildGearBrowserTab(frame, "Professions")
    local builderCalls = #calls

    frame.professionSearchBox:SetText("COPPER")
    T.assertEqual(#calls, builderCalls)
    T.assertEqual(#frame.filteredProfessionRecipes, 1)
    T.assertEqual(frame.professionRecipeRows[1].recipe.name, "Copper Bracers")
    T.assertEqual(frame.professionRecipeRows[1].recipe.knownBy[1].savedDate, "saved 2026-09-01")

    frame.professionButtons[2].scripts.OnClick(frame.professionButtons[2])
    T.assertEqual(frame.professionSearchBox:GetText(), "")
    T.assertEqual(#frame.filteredProfessionRecipes, 2)
    frame.navigationTabs[1].scripts.OnClick(frame.navigationTabs[1])
    T.assertEqual(#calls, builderCalls + 1)
    T.assertEqual(frame.professionSearchBox:GetText(), "")

    frame.professionSearchBox:SetText("ring")
    builderCalls = #calls
    frame.navigationTabs[2].scripts.OnClick(frame.navigationTabs[2])
    frame.navigationTabs[1].scripts.OnClick(frame.navigationTabs[1])
    T.assertEqual(#calls, builderCalls)
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

    GGM.SelectGuildGearBrowserTab(frame, "Professions")
    T.assertEqual(frame.professionStatus.text,
        "Current guild membership could not be confirmed. Live profession data is unavailable.")
    mode = "identities"; GGM.SelectProfession(frame, "Alchemy")
    T.assertEqual(frame.professionStatus.text,
        "Current guild member identities could not be confirmed. Live profession data is unavailable.")
    mode = "incomplete"; GGM.SelectProfession(frame, "Alchemy")
    T.assertEqual(frame.professionStatus.text,
        "Some saved profession data is incomplete. Live profession data is unavailable.")
    mode = "no-snapshot"; GGM.SelectProfession(frame, "Alchemy")
    T.assertEqual(frame.professionStatus.text,
        "No saved Alchemy snapshots for current guild members. Live profession data is unavailable.")
    mode = "no-recipes"; GGM.SelectProfession(frame, "Alchemy")
    T.assertEqual(frame.professionStatus.text,
        "Saved Alchemy snapshots contain no learned recipes. Live profession data is unavailable.")
    mode = "incomplete-safe"; GGM.SelectProfession(frame, "Alchemy")
    T.assertEqual(#frame.filteredProfessionRecipes, 1)
    frame.professionSearchBox:SetText("missing")
    T.assertEqual(frame.professionStatus.text,
        "Some saved profession data is incomplete. Live profession data is unavailable. No recipes match the current filters.")
    mode = "ready"; GGM.SelectProfession(frame, "Alchemy")
    frame.professionSearchBox:SetText("missing")
    T.assertEqual(frame.professionStatus.text,
        "Live profession data is unavailable; the selected character's recipes cannot be verified. No recipes match the current filters.")
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
    T.assertEqual(frame.professionRecipeRows[1].recipe.name, "Recipe 1")

    -- A completed reconciliation refreshes the currently visible catalog from local saved data.
    GGM.professionRosterMembershipCurrent = true
    T.assertTrue(GGM.RefreshVisibleProfessionCatalog())
    T.assertEqual(frame.professionRecipeRows[1].recipe.name, "Recipe 2")

    -- A failed reconciliation clears stale owners by rebuilding the fail-closed unavailable model.
    GGM.professionRosterMembershipCurrent = false
    T.assertTrue(GGM.RefreshVisibleProfessionCatalog())
    T.assertEqual(frame.professionStatus.text,
        "Current guild membership could not be confirmed. Live profession data is unavailable.")
    T.assertEqual(#frame.filteredProfessionRecipes, 0)
end)

T.test("profession rows retain owner metadata for details without constructing hidden labels", function()
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

    local row = frame.professionRecipeRows[1]
    T.assertNil(row.knownBy)
    T.assertTrue(row.recipe.knownBy[1] == localOwner)
    T.assertTrue(row.recipe.knownBy[2] == guildOwner)
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

T.test("gear browser explains missing or unavailable gear storage while other tabs remain usable", function()
    for _, reason in ipairs({
        "gear-companion-missing", "gear-database-invalid", "gear-backend-call-failed",
        "gear-backend-invalid", "gear-backend-incompatible",
    }) do
        local GGM = loadUI()
        local db = makeDB(GGM)
        db.gearUnavailableReason = reason
        local frame = showBrowser(GGM, makeBrowserAPI(), db)
        local expected
        if reason == "gear-companion-missing" then
            expected = "Install and enable The Guild Book gear beside The Guild Book to save and view gear."
        elseif reason:match("^gear%-backend%-") then
            expected = "Gear backend unavailable. Check /ggm status for details."
        else
            expected = "Gear storage is unavailable. Check /ggm status for details."
        end
        T.assertEqual(frame.detailEmpty.text, expected)
        T.assertEqual(frame.listEmpty.text, "Gear unavailable")
        GGM.SelectGuildGearBrowserTab(frame, "Professions")
        T.assertEqual(frame.activeTab, "Professions")
        GGM.SelectGuildGearBrowserTab(frame, "Bank")
        T.assertEqual(frame.activeTab, "Bank")
    end
end)

T.test("gear backend status explains initialization failures without suggesting a data reset", function()
    local GGM = loadUI()
    local messages = {}
    local api = {
        SlashCmdList = {},
        DEFAULT_CHAT_FRAME = { AddMessage = function(_, message) messages[#messages + 1] = message end },
    }
    GGM.gearStartupError = "gear-backend-call-failed"

    GGM.RegisterSnapshotTestSlashCommand(api)
    api.SlashCmdList.GUILDGEARMEMORY("status")

    local output = table.concat(messages, "\n")
    T.assertTrue(output:find("The Guild Book gear could not provide a compatible gear backend", 1, true) ~= nil)
    T.assertTrue(output:find("saved gear was left unchanged", 1, true) ~= nil)
    T.assertTrue(output:find("The Guild Book gear.lua", 1, true) == nil)
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
    local panelLeft = frame.gearPanel.point.x
    local listRight = frame.listPanel.point.relativeTo.point.x + frame.listPanel.width
    local panelWidth = frame.gearPanel.width
    local footerTop = frame.gearPanel.height - frame.detailFooter.point.y - frame.detailFooter.height

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
    T.assertEqual(frame.characterModelView.caption.text, "Class icon unavailable")
    T.assertTrue(frame.characterModelView.questionMark.visible)
    frame.listRows[2].scripts.OnClick(frame.listRows[2])
    T.assertTrue(frame.characterModelView.model.visible)
    T.assertFalse(frame.modelUnavailableLabel.visible)
    T.assertEqual(frame.characterModelView.portrait.atlas, "classicon-mage")
    T.assertEqual(frame.characterLine.text, "Beatrice")
    T.assertEqual(frame.capturedLine.text, "saved-1700000200")
    T.assertNil(frame.completenessBadge)
    frame.searchBox:SetText("no match")
    T.assertFalse(frame.characterModelView.model.visible)
    T.assertFalse(frame.modelUnavailableLabel.visible)
    T.assertNil(frame.characterModelView.portrait.atlas)
    T.assertEqual(frame.characterModelView.raceLabel.text, "")
    T.assertFalse(frame.characterLine.visible)
end)

T.test("browser replaces one class icon with another and clears it on empty selection", function()
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
    T.assertEqual(frame.characterModelView.portrait.atlas, "classicon-warrior")

    frame.listRows[2].scripts.OnClick(frame.listRows[2])
    T.assertTrue(view.visible)
    T.assertEqual(frame.characterModelView.portrait.atlas, "classicon-mage")
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
    T.assertNil(frame.completenessLine)
    T.assertEqual(#frame.detailModel.slots, #GGM.TRACKED_SLOTS)
    for _, slot in ipairs(frame.slotButtons) do T.assertTrue(slot.visible) end
end)

T.test("missing saved display ID still renders the class icon", function()
    local GGM = loadUI()
    local record = makeRecord(GGM)
    setSavedModelIdentity(record)
    record.identity.displayID = nil
    local frame = showBrowser(GGM, makeModelBrowserAPI(), makeDB(GGM, { record }))

    T.assertTrue(frame.characterModelView.model.visible)
    T.assertEqual(frame.characterModelView.portrait.atlas, "classicon-warrior")
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

    T.assertEqual(frame.characterModelView.caption.text, "Class icon unavailable")
    T.assertNil(frame.completenessBadge)
    T.assertEqual(frame.capturedLine.text, "saved-1700000100")
    T.assertTrue(frame.slotButtons[1].visible)
    T.assertEqual(#frame.detailModel.slots, #GGM.TRACKED_SLOTS)
    GGM.ShowGuildGearBrowserWindow(api, makeDB(GGM, { legacy }))
    T.assertNil(frame.completenessBadge)
    frame.navigationTabs[1].scripts.OnClick(frame.navigationTabs[1])
    T.assertFalse(frame.characterModelView.model.visible)
    T.assertFalse(frame.modelUnavailableLabel.visible)
    frame.navigationTabs[2].scripts.OnClick(frame.navigationTabs[2])
    T.assertTrue(frame.characterModelView.model.visible)
    T.assertFalse(frame.modelUnavailableLabel.visible)
    T.assertNil(frame.completenessBadge)
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
    T.assertTrue(emptySlot.icon.alpha > 0 and emptySlot.icon.alpha < 1)
    T.assertEqual(emptySlot.key, "OFF_HAND")
    T.assertEqual(emptySlot.label.text, "Off hand")
    T.assertEqual(emptySlot.status.text, "Empty")
    T.assertNil(emptySlot.itemLink)
    T.assertTrue(emptySlot.label.width <= 92)
    T.assertTrue(emptySlot.status.width <= 92)
end)

T.test("opening and selecting browser entries only backfills class metadata without gear capture or network activity", function()
    local GGM = loadUI()
    local first, second = makeRecord(GGM), makeRecord(GGM)
    second.identity = { key = "Beatrice-ArgentDawn", name = "Beatrice", realm = "ArgentDawn" }
    setSavedModelIdentity(first)
    setSavedModelIdentity(second)
    local forbidden = function() error("browser interaction must not capture gear or send messages") end
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
    local expected = copyTable(db)
    -- Cached class lookup may enrich legacy identities; every other saved field must stay unchanged.
    expected.characters["Alice-Silvermoon"].identity.classToken = "WARRIOR"
    expected.characters["Beatrice-ArgentDawn"].identity.classToken = "MAGE"
    local frame = showBrowser(GGM, api, db)

    frame.searchBox:SetText("beatrice")
    T.assertEqual(#frame.filteredEntries, 1)
    T.assertEqual(frame.filteredEntries[1].key, "Beatrice-ArgentDawn")

    frame.listRows[1].scripts.OnClick(frame.listRows[1])

    frame.navigationTabs[1].scripts.OnClick(frame.navigationTabs[1])
    frame.navigationTabs[2].scripts.OnClick(frame.navigationTabs[2])

    T.assertEqual(frame.selectedEntry.key, "Beatrice-ArgentDawn")
    T.assertTrue(tablesEqual(db, expected), "browser interaction may only backfill the selected characters' class tokens")
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
    T.assertTrue(output:find("The Guild Book.lua", 1, true) ~= nil)
    T.assertTrue(output:find("Gear and bank companion databases are separate", 1, true) ~= nil)
    T.assertTrue(output:find("profession snapshots/index data", 1, true) ~= nil)
    T.assertTrue(output:find("local-character metadata", 1, true) ~= nil)
end)

T.test("gear companion status points to its own SavedVariables file", function()
    local GGM = loadUI()
    local messages = {}
    local api = {
        SlashCmdList = {},
        DEFAULT_CHAT_FRAME = { AddMessage = function(_, message) messages[#messages + 1] = message end },
    }
    GGM.gearStartupError = "unsupported-schema-version:99"
    GGM.RegisterSnapshotTestSlashCommand(api)
    api.SlashCmdList.GUILDGEARMEMORY("status")
    local output = table.concat(messages, "\n")
    T.assertTrue(output:find("Gear storage: unavailable", 1, true) ~= nil)
    T.assertTrue(output:find("The Guild Book gear.lua", 1, true) ~= nil)
    T.assertTrue(output:find("TheGuildBookGearDB", 1, true) ~= nil)
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

T.test("gear requests print queued feedback without claiming transfer success", function()
    local GGM = loadUI()
    local messages = {}
    local api = { SlashCmdList = {}, print = function(message) messages[#messages + 1] = message end }
    GGM.guildSync = {}
    GGM.RequestCompleteSnapshot = function() return true end
    GGM.RegisterSnapshotTestSlashCommand(api)
    api.SlashCmdList.GUILDGEARMEMORY("request Alice-Silvermoon")
    T.assertEqual(#messages, 1)
    T.assertEqual(messages[1], "Gear request queued for Alice-Silvermoon. Waiting for a cached snapshot.")
end)

T.test("gear requests print readable failures and usage without opening the browser", function()
    local cases = {
        { command = "request Alice", expected = "Usage: /ggm request Name-Realm", err = "request-target-invalid" },
        { command = "request Alice-Silvermoon", expected = "Gear sync is unavailable.", unavailable = true, err = "sync-unavailable" },
        { command = "request Alice-Silvermoon", expected = "A gear request for this character is already pending.", err = "sync-snapshot-request-pending" },
        { command = "request Alice-Silvermoon", expected = "Please wait before requesting this character again.", err = "sync-snapshot-request-cooldown" },
        { command = "request Alice-Silvermoon", expected = "Gear sync requires guild membership.", err = "send-addon-message-failed:NotInGuild" },
        { command = "request Alice-Silvermoon", expected = "Gear sync was throttled. Try again later.", err = "send-addon-message-failed:AddonMessageThrottle" },
    }
    for _, case in ipairs(cases) do
        local GGM = loadUI()
        local messages = {}
        local api = { SlashCmdList = {}, DEFAULT_CHAT_FRAME = { AddMessage = function(_, message) messages[#messages + 1] = message end } }
        GGM.guildSync = not case.unavailable and {} or nil
        GGM.RequestCompleteSnapshot = function() return false, case.err end
        GGM.ShowGuildGearBrowserWindow = function() error("request must not open browser") end
        GGM.RegisterSnapshotTestSlashCommand(api)
        api.SlashCmdList.GUILDGEARMEMORY(case.command)
        T.assertEqual(messages[1], case.expected)
        T.assertEqual(GGM.lastSyncError, case.err)
    end
end)

T.test("status reports profession startup roster and transport failures without a database", function()
    local G = loadUI()
    local messages = {}
    local api = { SlashCmdList = {}, print = function(message) messages[#messages + 1] = message end }
    G.RegisterSnapshotTestSlashCommand(api)
    G.lastProfessionSyncError = "profession-prefix-register-failed:MaxPrefixes"
    api.SlashCmdList.GUILDGEARMEMORY("status")
    local output = table.concat(messages, "\n")
    T.assertTrue(output:find("Profession sync: unavailable (GC_PROF3)", 1, true) ~= nil)
    T.assertTrue(output:find("profession-prefix-register-failed:MaxPrefixes", 1, true) ~= nil)
    messages = {}
    G.professionSync = { registered = true, rosterReady = true,
        lastError = "profession-sync-no-responder", transport = {} }
    api.SlashCmdList.GUILDGEARMEMORY("status")
    output = table.concat(messages, "\n")
    T.assertTrue(output:find("Profession roster: ready", 1, true) ~= nil)
    T.assertTrue(output:find("Profession sync error: profession-sync-no-responder", 1, true) ~= nil)
    messages = {}
    G.professionSync.rosterReady = false
    G.lastProfessionIndexError = "profession-roster-incomplete"
    G.professionSync.transport.lastSendError = "profession-send-addon-message-failed:NotInGuild"
    api.SlashCmdList.GUILDGEARMEMORY("status")
    output = table.concat(messages, "\n")
    T.assertTrue(output:find("Profession roster: not ready", 1, true) ~= nil)
    T.assertTrue(output:find("Profession roster error: profession-roster-incomplete", 1, true) ~= nil)
    T.assertTrue(output:find("Profession sync error: profession-send-addon-message-failed:NotInGuild", 1, true) ~= nil)
end)

T.test("gear sync status reports prefix availability and async errors even without database", function()
    local GGM = loadUI()
    local messages = {}
    local api = { SlashCmdList = {}, print = function(message) messages[#messages + 1] = message end }
    GGM.RegisterSnapshotTestSlashCommand(api)
    api.SlashCmdList.GUILDGEARMEMORY("status")
    T.assertTrue(table.concat(messages, "\n"):find("Gear sync: unavailable (GC_GEAR)", 1, true) ~= nil)
    messages = {}
    GGM.guildSync = { transport = { lastSendError = "send-addon-message-failed:NotInGuild" } }
    GGM.lastSyncReceiveError = "sync-frame-invalid"
    api.SlashCmdList.GUILDGEARMEMORY("status")
    local output = table.concat(messages, "\n")
    T.assertTrue(output:find("Gear sync: registered (GC_GEAR)", 1, true) ~= nil)
    T.assertTrue(output:find("Gear sync send/request error: send-addon-message-failed:NotInGuild", 1, true) ~= nil)
    T.assertTrue(output:find("Gear sync receive error: sync-frame-invalid", 1, true) ~= nil)
end)

T.test("journal Bank page selects cached entries, tabs, and slots and refreshes without losing selection", function()
    local GGM = loadUI()
    local previousAPI, previousDB = _G.DysbankMemoryAPI, _G.TheGuildBookBankDB
    _G.DysbankMemoryAPI = { schemaVersion = 1 }
    local function record(name, realm, tabCount)
        local tabs = {}
        for tabID = 1, tabCount do
            local slots = {}
            for slotID = 1, 40 do
                if slotID == 3 then
                    slots[slotID] = {
                        itemID = 19019 + tabID, itemLink = "|Hitem:" .. tostring(19019 + tabID)
                            .. "|h[Saved " .. tostring(tabID) .. "]|h", icon = 134,
                        count = 2,
                    }
                end
            end
            tabs[tabID] = {
                id = tabID, name = "Tab " .. tostring(tabID), numSlots = 200,
                capturedAt = 1700000000 + tabID, status = "cached", slots = slots,
            }
        end
        local key = name .. "-" .. realm
        return {
            identity = { key = key, name = name, realm = realm, guid = "Player-1234-" .. name },
            capturedAt = 1700000001, status = "cached", tabs = tabs,
        }
    end
    local ggmRecord = makeRecord(GGM)
    local ggmRecords = { ggmRecord }
    for index = 1, 14 do
        local extra = makeRecord(GGM)
        extra.identity = {
            key = "Extra" .. tostring(index) .. "-Silvermoon",
            name = "Extra" .. tostring(index),
            realm = "Silvermoon",
        }
        table.insert(ggmRecords, extra)
    end
    local characterBank = record("Alice", "Silvermoon", 12)
    local guildBank = record("Testers", "Silvermoon", 2)
    _G.TheGuildBookBankDB = {
        schemaVersion = 1,
        characters = { [characterBank.identity.key] = characterBank },
        guilds = { [guildBank.identity.key] = guildBank },
    }
    local api = makeBrowserAPI()
    api.GetGuildInfo = function(unit)
        T.assertEqual(unit, "player")
        return "Testers", "Guild Leader", 0, "Silvermoon"
    end
    api.GetRealmName = nil
    api.issecretvalue = function() return false end
    local tooltip = { SetOwner = function() end }
    function tooltip:Show() self.visible = true end
    function tooltip:Hide() self.visible = false; self.hideCount = (self.hideCount or 0) + 1 end
    function tooltip:SetHyperlink(link) self.link = link end
    api.GameTooltip = tooltip

    local sharedDB = makeDB(GGM, ggmRecords)
    sharedDB.localCharacterGUIDs = { ["Player-1234-Alice"] = true }
    local frame = showBrowser(GGM, api, sharedDB)
    T.assertNotNil(frame.bankPage, "journal should construct a dedicated Bank page")
    T.assertTrue(GGM.SelectGuildGearBrowserTab(frame, "Bank"))
    local page = frame.bankPage
    T.assertTrue(page.visible)
    T.assertEqual(page.entries[1].label, "Guild Bank")
    T.assertTrue(page.entries[1].record == guildBank, "guild tab should use the realm returned with guild identity")
    T.assertEqual(page.libraryTitle.text, "BANK LIBRARY")
    T.assertFalse(frame.pageSubtitle.visible, "Bank uses its library helper instead of a duplicate shared subtitle")
    T.assertNotNil(page.libraryHelper)
    T.assertTrue(page.libraryHelper.point.relativeTo == page.libraryTitle)
    T.assertEqual(page.libraryHelper.point.relativePoint, "BOTTOMLEFT")
    T.assertTrue(page.libraryHelper.point.y < 0, "helper must sit below the library heading")
    local helperBottom = -page.libraryTitle.point.y + page.libraryTitle.font.size
        - page.libraryHelper.point.y + page.libraryHelper.font.size
    T.assertTrue(-page.searchBox.point.y > helperBottom, "search must sit below the helper")
    T.assertTrue(-page.listCount.point.y > -page.searchBox.point.y + page.searchBox.height,
        "entry count must sit below search")
    T.assertTrue(-page.listDivider.point.y > -page.listCount.point.y + page.listCount.font.size,
        "divider must sit below the entry count")
    T.assertTrue(-page.listScroll.points.TOPLEFT.y > -page.listDivider.point.y + page.listDivider.height,
        "bank list must begin below the divider")
    T.assertTrue(page.listScroll.points.BOTTOMLEFT.relativeTo == page,
        "bank list must stretch to the page bottom")
    T.assertEqual(page.listEmpty.justifyH, "LEFT")
    T.assertEqual(page.selectedEntry.kind, "guild")
    T.assertTrue(page.listScroll.scrollChild == page.listContent)
    T.assertTrue(page.tabScroll.scrollChild == page.tabContent)
    T.assertTrue(page.itemScroll.scrollChild == page.itemContent)
    T.assertTrue(page.listScroll.mouseWheelEnabled)
    T.assertTrue(page.tabScroll.mouseWheelEnabled)
    T.assertTrue(page.itemScroll.mouseWheelEnabled)
    T.assertTrue(page.listContent.height > page.listScroll.height, "character list should scroll when full")
    T.assertTrue(page.itemContent.height > page.itemScroll.height, "long item grids should scroll")
    page.listScroll.scripts.OnMouseWheel(page.listScroll, -1)
    T.assertEqual(page.listScroll.verticalScroll, 42, "mouse wheel should scroll long bank lists")

    page.entryButtons[2].scripts.OnClick(page.entryButtons[2])
    T.assertEqual(page.selectedEntry.key, "Alice-Silvermoon")
    T.assertTrue(page.tabContent.height > page.tabScroll.height, "long tab lists should scroll")
    T.assertTrue(GGM.SelectBankTab(page, 7))
    T.assertEqual(page.tabScroll:GetVerticalScroll(), 64,
        "banks with more than two rows should still scroll to later tabs")
    page.tabButtons[2].scripts.OnClick(page.tabButtons[2])
    T.assertEqual(page.selectedTabID, 2)
    T.assertNil(page.itemButtons[1].icon.texture,
        "observed empty bank slots should not draw an inner placeholder")
    T.assertEqual(page.itemButtons[3].icon.texture, 134,
        "occupied bank slots should keep their item icon")
    page.itemButtons[3].scripts.OnClick(page.itemButtons[3])
    T.assertEqual(page.selectedSlotID, 3)
    page.itemButtons[3].scripts.OnEnter(page.itemButtons[3])
    T.assertEqual(tooltip.link, "|Hitem:19021|h[Saved 2]|h")
    page.listScroll:SetVerticalScroll(42)
    page.tabScroll:SetVerticalScroll(28)
    page.itemScroll:SetVerticalScroll(80)

    local refreshed = record("Alice", "Silvermoon", 12)
    refreshed.capturedAt = 1700000500
    refreshed.tabs[1].capturedAt = refreshed.capturedAt
    _G.TheGuildBookBankDB.characters[refreshed.identity.key] = refreshed
    _G.GuildGearMemoryBankChanged()

    T.assertEqual(page.selectedEntry.key, "Alice-Silvermoon")
    T.assertEqual(page.selectedTabID, 2)
    T.assertEqual(page.selectedSlotID, 3)
    T.assertEqual(page.listScroll.verticalScroll, 42)
    T.assertEqual(page.tabScroll.verticalScroll, 28)
    T.assertEqual(page.itemScroll.verticalScroll, 80)
    T.assertEqual(page.detailModel.capturedAtText, "saved-1700000500")

    frame:Hide()
    local changedWhileHidden = record("Alice", "Silvermoon", 12)
    changedWhileHidden.capturedAt = 1700000600
    changedWhileHidden.tabs[1].capturedAt = changedWhileHidden.capturedAt
    _G.TheGuildBookBankDB.characters[changedWhileHidden.identity.key] = changedWhileHidden
    local addedWhileHidden = record("Beatrice", "Silvermoon", 6)
    sharedDB.localCharacterGUIDs[addedWhileHidden.identity.guid] = true
    _G.TheGuildBookBankDB.characters[addedWhileHidden.identity.key] = addedWhileHidden
    T.assertFalse(_G.GuildGearMemoryBankChanged(), "hidden Bank page should defer its visible refresh")
    GGM.ShowGuildGearBrowserWindow(api, frame.db)

    T.assertEqual(page.selectedEntry.key, "Alice-Silvermoon")
    T.assertEqual(page.detailModel.capturedAtText, "saved-1700000600",
        "reopening the journal should read the latest local bank snapshot")
    local foundAddedEntry = false
    for _, entry in ipairs(page.entries) do
        if entry.key == "Beatrice-Silvermoon" then foundAddedEntry = true end
    end
    T.assertTrue(foundAddedEntry, "reopening the journal should refresh the cached character list")
    T.assertEqual(page.selectedTabID, 2)
    T.assertEqual(page.selectedSlotID, 3)

    local beatrice
    for _, entry in ipairs(page.entries) do
        if entry.key == "Beatrice-Silvermoon" then beatrice = entry; break end
    end
    T.assertTrue(GGM.SelectBankEntry(page, beatrice))
    T.assertTrue(GGM.SelectBankTab(page, 4))
    T.assertEqual(page.tabScroll:GetVerticalScroll(), 0,
        "switching to the second row must keep both rows visible when six tabs fit")
    for index = 1, 6 do T.assertTrue(page.tabButtons[index].visible) end
    T.assertTrue(GGM.SelectBankTab(page, 1))
    T.assertEqual(page.tabScroll:GetVerticalScroll(), 0,
        "returning to the first row must not move the tab strip")
    T.assertTrue(GGM.SelectBankEntry(page, page.entries[2]))

    page.itemButtons[3].scripts.OnEnter(page.itemButtons[3])
    T.assertTrue(tooltip.visible)
    _G.DysbankMemoryAPI, _G.TheGuildBookBankDB = nil, nil
    _G.GuildGearMemoryBankChanged()
    T.assertEqual(page.tabStatus.text, "", "missing companion should clear the previously selected tab status")
    T.assertNil(page.selectedTabID)
    T.assertNil(page.selectedSlotID)
    T.assertFalse(tooltip.visible, "missing companion should close a tooltip from the previous snapshot")
    T.assertEqual(#page.entries, 0, "banks without observed snapshots are hidden")
    T.assertEqual(page.listEmpty.text, "No saved bank snapshots.")
    _G.DysbankMemoryAPI, _G.TheGuildBookBankDB = previousAPI, previousDB
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
    T.assertNil(frame.completenessBadge)
    local shirtIndex
    for index, slot in ipairs(GGM.TRACKED_SLOTS) do if slot.key == "SHIRT" then shirtIndex = index end end
    T.assertTrue(frame.slotButtons[shirtIndex].empty)
    T.assertEqual(frame.slotButtons[shirtIndex].label.text, "Shirt")
    T.assertEqual(frame.slotButtons[shirtIndex].status.text, "Empty")
    T.assertTrue(frame.slotButtons[shirtIndex].label.width <= 156)
    T.assertTrue(frame.slotButtons[shirtIndex].status.width <= 156)
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
    T.assertNil(frame.completenessBadge)
    T.assertEqual(#frame.detailModel.slots, #GGM.TRACKED_SLOTS)
    for index, row in ipairs(frame.detailModel.slots) do
        local button = frame.slotButtons[index]
        T.assertFalse(row.unavailable)
        local expectedWidth = button.paperDollGroup == "bottom" and 92 or 156
        T.assertTrue(button.label.width <= (button.paperDollGroup == "bottom" and 92 or 156))
        T.assertTrue(button.status.width <= expectedWidth)
        T.assertEqual(button.label.text, row.displayName)
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
    T.assertNil(frame.completenessBadge)
end)

T.test("gear sync button requests only the selected saved character and renders lifecycle status", function()
    local G = loadUI()
    local api = makeBrowserAPI()
    local alice, beta = makeRecord(G), makeRecord(G)
    beta.identity = { key = "Beatrice-ArgentDawn", name = "Beatrice", realm = "ArgentDawn" }
    local requested, count, status, busy = nil, 0, "", false
    G.guildSync = {}
    G.RequestCompleteSnapshot = function(sync, target)
        T.assertTrue(sync == G.guildSync)
        requested, count, status, busy = target, count + 1, "Waiting for a gear snapshot...", true
        return true
    end
    G.GetGearSyncStatus = function() return status, busy end
    local frame = showBrowser(G, api, makeDB(G, { alice, beta }))
    T.assertEqual(count, 0)
    T.assertTrue(frame.gearSyncButton.visible)
    frame.listRows[2].scripts.OnClick(frame.listRows[2])
    T.assertEqual(count, 0)
    frame.gearSyncButton.scripts.OnClick()
    T.assertEqual(requested.key, "Beatrice-ArgentDawn")
    T.assertEqual(count, 1)
    T.assertEqual(frame.gearSyncStatus.text, "Waiting for a gear snapshot...")
    status, busy = "Gear snapshot synchronized.", false
    G.RefreshVisibleGearSyncStatus()
    T.assertEqual(frame.gearSyncStatus.text, status)
    G.SelectGuildGearBrowserTab(frame, "Professions")
    T.assertFalse(frame.gearSyncButton.visible)
    G.SelectGuildGearBrowserTab(frame, "Character")
    T.assertTrue(frame.gearSyncButton.visible)
end)

T.test("gear sync button hides without selection and reports unavailable transport", function()
    local G = loadUI()
    local api = makeBrowserAPI()
    local frame = showBrowser(G, api, makeDB(G, {}))
    T.assertFalse(frame.gearSyncButton.visible)
    frame = showBrowser(G, api, makeDB(G, { makeRecord(G) }))
    frame.gearSyncButton.scripts.OnClick()
    T.assertEqual(frame.gearSyncStatus.text, "Gear sync is unavailable.")
end)

T.test("gear refresh shows cooldown rejection even after a prior successful synchronization", function()
    local G = loadUI()
    local api = makeBrowserAPI()
    G.guildSync = {}
    G.GetGearSyncStatus = function() return "Gear snapshot synchronized.", false end
    G.RequestCompleteSnapshot = function() return false, "sync-snapshot-request-cooldown" end
    local frame = showBrowser(G, api, makeDB(G, { makeRecord(G) }))
    frame.gearSyncButton.scripts.OnClick()
    T.assertEqual(frame.gearSyncStatus.text, "Please wait before requesting this character again.")
end)

T.test("equipped gear labels show item names from modern and legacy item APIs", function()
    for _, modern in ipairs({ true, false }) do
        local G, api = loadUI(), makeBrowserAPI()
        local name = "Crown of the Very Long Forgotten Kingdom"
        if modern then api.C_Item = { GetItemNameByID = function() return name end }
        else api.GetItemInfo = function() return name end end
        local frame = showBrowser(G, api, makeDB(G, { makeRecord(G) }))
        for _, button in ipairs(frame.slotButtons) do
            T.assertEqual(button.label.text, name)
            T.assertEqual(button.label.height, button.paperDollGroup == "bottom" and 44 or 32)
        end
    end
end)

T.test("uncached equipped item names refresh when item data becomes available", function()
    local G, api = loadUI(), makeBrowserAPI()
    local available = false
    api.GetItemInfo = function() if available then return "Crown of Memories" end end
    local frame = showBrowser(G, api, makeDB(G, { makeRecord(G) }))
    local button = frame.slotButtons[1]
    T.assertEqual(button.label.text, "Item " .. button.itemID)
    available = true
    frame.gearSyncButton.scripts.OnUpdate(nil, 1)
    T.assertEqual(button.label.text, "Crown of Memories")
    T.assertTrue(string.find(button.itemLink, "[Crown of Memories]", 1, true) ~= nil)
end)

T.test("item-name refresh follows the selected character without replacing empty slot labels", function()
    local G, api = loadUI(), makeBrowserAPI()
    local alice, beta = makeRecord(G), makeRecord(G)
    beta.identity = { key = "Beatrice-ArgentDawn", name = "Beatrice", realm = "ArgentDawn" }
    beta.gear.slots.HEAD = { inventorySlotID = 1, itemID = false, itemLink = false }
    local available = false
    api.GetItemInfo = function() if available then return "Alice's Crown" end end
    local frame = showBrowser(G, api, makeDB(G, { alice, beta }))
    frame.listRows[2].scripts.OnClick(frame.listRows[2])
    available = true
    frame.gearSyncButton.scripts.OnUpdate(nil, 1)
    local head = frame.slotButtons[1]
    T.assertEqual(head.label.text, "Head")
    T.assertEqual(head.status.text, "Empty")
    T.assertEqual(head.label.height, 14)
    T.assertNil(head.itemLink)
end)

T.test("browser opening applies saved appearance and respects the window drag lock", function()
    local G, api, browser, _, _, db = recipeDetailsFixture()
    db.uiSettings = {window={scale=0.85,opacity=0.65,locked=true}}
    G.ShowGuildGearBrowserWindow(api, db)
    T.assertEqual(browser.scale, 0.85)
    T.assertEqual(browser.alpha, 0.65)
    browser.scripts.OnDragStart(browser)
    T.assertFalse(browser.moving == true)
    db.uiSettings.window.locked = false
    browser.scripts.OnDragStart(browser)
    T.assertTrue(browser.moving)
    browser.scripts.OnDragStop(browser)
    T.assertFalse(browser.moving)
end)

T.test("recipe opens align independently and background refresh preserves dragged position", function()
    local G, api, browser, recipes, _, db = recipeDetailsFixture()
    api.UIParent:SetSize(2560, 1440)
    browser.left, browser.top = 100, 1300
    db.uiSettings = {window={scale=1,opacity=0.7,autoAlignRecipe=true,positionX=0.25,positionY=0.75}}
    browser:ClearAllPoints()
    browser:SetPoint("TOPLEFT", api.UIParent, "TOPLEFT", 123, -456)
    local browserAnchor = browser.point
    local details = G.ShowRecipeDetailsWindow(browser, recipes[1])
    T.assertTrue(browser.point == browserAnchor,
        "opening a recipe cannot apply saved main-window coordinates again")
    T.assertEqual(details.scale, 1)
    T.assertEqual(details.alpha, 0.7)
    T.assertEqual(details.point.relativeTo, api.UIParent)
    T.assertEqual(details.point.x, 1508)
    T.assertEqual(details.point.y, 1300)
    details.scripts.OnDragStart(details)
    T.assertTrue(details.moving)
    details.scripts.OnDragStop(details)
    details:ClearAllPoints()
    details:SetPoint("CENTER", api.UIParent, "CENTER", 0, 0)
    G.RefreshRecipeDetailsWindow(browser)
    T.assertEqual(details.point.point, "CENTER")
    browser.left = 50
    T.assertEqual(details.point.point, "CENTER", "main window movement cannot attach recipe details")

    browser:ClearAllPoints()
    browser:SetPoint("BOTTOMLEFT", api.UIParent, "BOTTOMLEFT", 222, 333)
    browserAnchor = browser.point
    details:ClearAllPoints()
    details:SetPoint("CENTER", api.UIParent, "CENTER", 15, -20)
    local detailsAnchor = details.point
    db.uiSettings.window.recipeScale = 0.9
    db.uiSettings.window.opacity = 0.6
    G.ShowRecipeDetailsWindow(browser, recipes[2])
    T.assertTrue(browser.point == browserAnchor, "later recipe selections retain a manually moved browser")
    T.assertTrue(details.point == detailsAnchor, "later recipe selections retain a manually moved details window")
    T.assertEqual(details.scale, 0.9, "recipe appearance settings still apply while changing selection")
    T.assertEqual(details.alpha, 0.6)
    db.uiSettings.window.autoAlignRecipe = false
    details:SetPoint("CENTER", api.UIParent, "CENTER", 0, 0)
    G.ShowRecipeDetailsWindow(browser, recipes[1])
    T.assertEqual(details.point.point, "CENTER")
end)

T.test("first recipe details display keeps its default anchor when auto-align is disabled", function()
    local G, api, browser, recipes, _, db = recipeDetailsFixture()
    db.uiSettings = { window = { autoAlignRecipe = false } }

    local details = G.ShowRecipeDetailsWindow(browser, recipes[1])

    T.assertEqual(details.point.point, "CENTER")
    T.assertEqual(details.point.relativeTo, api.UIParent)
    T.assertEqual(details.point.x, 100)
    T.assertEqual(details.point.y, 0)
end)

T.test("recipe opening and main reopening preserve separately saved sizes", function()
    local G, api, browser, recipes, _, db = recipeDetailsFixture()
    db.uiSettings = {window={scale=0.8,recipeScale=1.2}}
    G.ShowGuildGearBrowserWindow(api, db)
    local details = G.ShowRecipeDetailsWindow(browser, recipes[1])
    T.assertEqual(browser.scale, 0.8)
    T.assertEqual(details.scale, 1.2)
    G.ShowGuildGearBrowserWindow(api, db)
    T.assertEqual(browser.scale, 0.8)
    T.assertEqual(details.scale, 1.2)
    db.uiSettings.window.recipeScale = 0.9
    G.ShowRecipeDetailsWindow(browser, recipes[2])
    T.assertEqual(browser.scale, 0.8)
    T.assertEqual(details.scale, 0.9)
end)

T.test("PR1 hidden profession events build nothing and opening consumes latest data once", function()
    local G, api = loadUI(), makeBrowserAPI()
    installCatalogOnlyFilterFixture(G, api)
    local calls, revision = {}, 1
    installProfessionCatalogStub(G, function()
        return professionCatalog("ready", { { recipeID = 1, name = "Revision " .. revision, knownBy = {} } })
    end, calls)
    local db = makeDB(G)
    local frame = G.CreateGuildGearBrowserWindow(api)
    frame.professionLibraryMode = "All"
    frame.professionRecipeFilterState.haveMaterials = false
    G.guildGearBrowserFrame, frame.db = frame, db
    for i = 1, 5 do T.assertFalse(G.RefreshVisibleProfessionCatalog()) end
    T.assertEqual(#calls, 0, "an initialized hidden browser must build no catalog")
    G.ShowGuildGearBrowserWindow(api, db)
    T.assertEqual(#calls, 1, "opening must build one catalog")
    frame.professionSearchBox:SetText("Revision")
    frame.professionRecipeScroll:SetVerticalScroll(30)
    frame:Hide()
    local before = #calls
    revision = 2
    for i = 1, 5 do T.assertFalse(G.RefreshVisibleProfessionCatalog()) end
    T.assertEqual(#calls, before, "hidden events must build zero catalogs")
    selectAllProfessions(frame)
    G.ShowGuildGearBrowserWindow(api, db)
    T.assertEqual(#calls, before + 1, "reopening dirty data must build once")
    T.assertEqual(frame.professionRecipeRows[1].recipe.name, "Revision 2")
    T.assertEqual(frame.professionSearchBox:GetText(), "Revision")
    T.assertEqual(frame.professionRecipeScroll:GetVerticalScroll(), 0, "short results clamp the scroll offset")
    frame:Hide()
    selectAllProfessions(frame)
    G.ShowGuildGearBrowserWindow(api, db)
    T.assertEqual(#calls, before + 1, "clean reopening must reuse the catalog")
end)

T.test("PR1 inactive profession events wait until tab entry and gear never rebuilds other pages", function()
    local G, api, calls = loadUI(), makeBrowserAPI(), {}
    installProfessionCatalogStub(G, function() return professionCatalog("ready", {}) end, calls)
    local db = makeDB(G, { makeRecord(G) })
    G.db = db
    local frame = showBrowser(G, api, db)
    T.assertEqual(#calls, 0, "opening Characters must not build professions")
    local banks = 0
    G.RefreshVisibleBankView = function() banks = banks + 1 end
    for _, tab in ipairs({ "Character", "Bank", "Professions" }) do
        G.SelectGuildGearBrowserTab(frame, tab)
        local before, beforeBanks = #calls, banks
        for i = 1, 3 do G.RefreshVisibleGuildGearBrowser() end
        T.assertEqual(#calls, before, "gear must not build professions on " .. tab)
        T.assertEqual(banks, beforeBanks, "gear must not refresh Bank on " .. tab)
    end
    G.SelectGuildGearBrowserTab(frame, "Bank")
    local before = #calls
    for i = 1, 3 do T.assertFalse(G.RefreshVisibleProfessionCatalog()) end
    T.assertEqual(#calls, before)
    G.SelectGuildGearBrowserTab(frame, "Professions")
    T.assertEqual(#calls, before + 1)
    G.SelectGuildGearBrowserTab(frame, "Character")
    G.SelectGuildGearBrowserTab(frame, "Professions")
    T.assertEqual(#calls, before + 1, "clean tab entry reuses saved rendering")
end)

T.test("PR1 visible invalidations coalesce and callbacks retain hidden dirty data", function()
    local G, api, calls, timers = loadUI(), makeBrowserAPI(), {}, {}
    api.C_Timer = { After = function(_, callback) timers[#timers + 1] = callback end }
    installProfessionCatalogStub(G, function() return professionCatalog("ready", {}) end, calls)
    showAllProfessionsBrowser(G, api, makeDB(G))
    local frame, before = G.guildGearBrowserFrame, #calls
    for i = 1, 5 do G.RefreshVisibleProfessionCatalog() end
    T.assertEqual(#calls, before)
    T.assertEqual(#timers, 1, "one callback for an event burst")
    timers[1]()
    T.assertEqual(#calls, before + 1)
    G.RefreshVisibleProfessionCatalog()
    frame:Hide()
    timers[2]()
    T.assertEqual(#calls, before + 1, "queued callback must check actual visibility")
    selectAllProfessions(frame)
    G.ShowGuildGearBrowserWindow(api, frame.db)
    T.assertEqual(#calls, before + 2)
    G.RefreshVisibleProfessionCatalog()
    G.SelectGuildGearBrowserTab(frame, "Character")
    G.SelectGuildGearBrowserTab(frame, "Professions")
    T.assertEqual(#calls, before + 3)
    timers[3]()
    T.assertEqual(#calls, before + 3, "tab entry consumes queued work")
end)

T.test("PR1 gear refresh rebinds saved selection and coalesces without losing browsing state", function()
    local G, api, timers = loadUI(), makeBrowserAPI(), {}
    api.C_Timer = { After = function(_, callback) timers[#timers + 1] = callback end }
    G.RequestCompleteSnapshot = function() error("browsing must not request gear") end
    local db = makeDB(G, { makeRecord(G) })
    G.db = db
    local frame = showBrowser(G, api, db)
    frame.searchBox:SetText("Alice")
    timers[1]() -- Apply the debounced search before measuring event coalescing.
    timers = {}
    frame.listScroll:SetVerticalScroll(24)
    local replacement = makeDB(G, { makeRecord(G) }).characters["Alice-Silvermoon"]
    replacement.gear.capturedAt = 1700000900
    db.characters["Alice-Silvermoon"] = replacement
    for i = 1, 4 do G.RefreshVisibleGuildGearBrowser() end
    T.assertEqual(#timers, 1)
    timers[1]()
    T.assertTrue(frame.selectedEntry.record == replacement)
    T.assertEqual(frame.capturedLine.text, "saved-1700000900")
    T.assertEqual(frame.searchBox:GetText(), "Alice")
    T.assertEqual(frame.listScroll:GetVerticalScroll(), 0, "short results clamp the scroll offset")
    frame.listRows[1].scripts.OnClick(frame.listRows[1])
end)


T.test("PR1 shown but invisible professions and hidden selections retain dirty state", function()
    local G, api, calls = loadUI(), makeBrowserAPI(), {}
    installProfessionCatalogStub(G, function() return professionCatalog("ready", {}) end, calls)
    G.ShowGuildGearBrowserWindow(api, makeDB(G))
    local frame, before = G.guildGearBrowserFrame, #calls
    frame.professionLibraryMode = "All"
    frame.IsVisible = function() return false end
    T.assertTrue(frame:IsShown())
    T.assertFalse(G.RefreshVisibleProfessionCatalog())
    G.SelectProfession(frame, "Blacksmithing")
    T.assertEqual(#calls, before)
    frame.IsVisible = function() return true end
    G.SelectGuildGearBrowserTab(frame, "Professions")
    T.assertEqual(#calls, before + 1)
    T.assertEqual(calls[#calls].professionID, 164)
end)

T.test("PR1 paired catalog and library invalidations share one catalog build", function()
    local G, api, calls, timers = loadUI(), makeBrowserAPI(), {}, {}
    api.C_Timer = { After = function(_, callback) timers[#timers + 1] = callback end }
    installProfessionCatalogStub(G, function() return professionCatalog("ready", {}) end, calls)
    showAllProfessionsBrowser(G, api, makeDB(G))
    local before = #calls
    G.RefreshVisibleProfessionCatalog()
    G.RefreshVisibleProfessionLibrary()
    T.assertEqual(#timers, 1)
    timers[1]()
    T.assertEqual(#calls, before + 1)
end)


T.test("PR1 hidden gear changes flush latest Characters once and Bank opens once", function()
    local G, api, timers = loadUI(), makeBrowserAPI(), {}
    api.C_Timer = { After = function(_, callback) timers[#timers + 1] = callback end }
    local db = makeDB(G, { makeRecord(G) })
    G.db = db
    local frame = showBrowser(G, api, db)
    local builds, original = 0, G.BuildGuildGearBrowserEntries
    G.BuildGuildGearBrowserEntries = function(...)
        builds = builds + 1
        return original(...)
    end
    frame:Hide()
    db.characters["Alice-Silvermoon"].gear.capturedAt = 1700000999
    for i = 1, 3 do T.assertFalse(G.RefreshVisibleGuildGearBrowser()) end
    T.assertEqual(builds, 0)
    T.assertEqual(#timers, 0)
    G.ShowGuildGearBrowserWindow(api, db)
    T.assertEqual(builds, 1)
    T.assertEqual(frame.capturedLine.text, "saved-1700000999")
    local banks = 0
    G.RefreshVisibleBankView = function() banks = banks + 1 end
    G.SelectGuildGearBrowserTab(frame, "Bank")
    frame:Hide()
    banks = 0
    G.ShowGuildGearBrowserWindow(api, db)
    T.assertEqual(banks, 1)
end)


T.test("PR1 hidden and inactive profession sidebar resizing defers widget work", function()
    local G, api = loadUI(), makeBrowserAPI()
    local frame = G.CreateGuildGearBrowserWindow(api)
    G.guildGearBrowserFrame = frame
    local layouts = 0
    local original = frame.professionLibraryContent.SetSize
    frame.professionLibraryContent.SetSize = function(self, ...)
        layouts = layouts + 1
        return original(self, ...)
    end
    frame.professionLibraryScroll.scripts.OnSizeChanged()
    T.assertEqual(layouts, 0)
    G.ShowGuildGearBrowserWindow(api, makeDB(G))
    T.assertTrue(layouts > 0)
    G.SelectGuildGearBrowserTab(frame, "Character")
    local before = layouts
    frame.professionLibraryScroll.scripts.OnSizeChanged()
    T.assertEqual(layouts, before)
    G.SelectGuildGearBrowserTab(frame, "Professions")
    T.assertEqual(layouts, before + 1)
end)


T.test("large recipe lists recycle a bounded viewport pool and keep the last recipe clickable", function()
    local GGM, recipes = loadUI(), {}
    for i = 1, 4096 do recipes[i] = { recipeID = i, name = string.format("Recipe %04d", i), knownBy = {} } end
    installProfessionCatalogStub(GGM, function() return professionCatalog("ready", recipes) end, {})
    local api = makeBrowserAPI()
    showAllProfessionsBrowser(GGM, api, { schemaVersion = GGM.SCHEMA_VERSION, characters = {} })
    local frame = GGM.guildGearBrowserFrame
    frame.professionRecipeScroll:SetHeight(230)
    frame.professionRecipeScroll.scripts.OnSizeChanged(frame.professionRecipeScroll)
    local pool = #frame.professionRecipeRows
    T.assertTrue(pool <= 10, "4096 results must allocate only viewport rows")
    local opened
    GGM.ShowRecipeDetailsWindow = function(_, recipe) opened = recipe end
    local seen = {}
    for pass = 1, 3 do
        for offset = 0, 4096 * 46, 230 do
            frame.professionRecipeScroll:SetVerticalScroll(offset)
            for _, row in ipairs(frame.professionRecipeRows) do
                if row.recipe then seen[row.recipe.recipeID] = true end
            end
        end
    end
    for id = 1, 4096 do T.assertTrue(seen[id], "every recipe must remain reachable") end
    frame.professionRecipeScroll:SetVerticalScroll(4096 * 46 - 230)
    T.assertEqual(#frame.professionRecipeRows, pool)
    local last
    for _, row in ipairs(frame.professionRecipeRows) do
        if row.recipe and row.recipe.recipeID == 4096 then last = row end
    end
    T.assertNotNil(last)
    last.scripts.OnClick(last)
    T.assertEqual(opened and opened.recipeID, recipes[4096].recipeID,
        "All-mode filter entries preserve catalog recipe identity")
    frame.professionSearchBox:SetText("Recipe 4096")
    T.assertEqual(#frame.filteredProfessionRecipes, 1)
    T.assertEqual(frame.professionRecipeScroll:GetVerticalScroll(), 0)
    T.assertEqual(frame.professionRecipeRows[1].recipe.recipeID, recipes[4096].recipeID)
    for i = 2, pool do T.assertNil(frame.professionRecipeRows[i].recipe) end
    frame.professionSearchBox:SetText("")
    T.assertEqual(#frame.professionRecipeRows, pool)
end)

T.test("large character lists recycle rows without refiltering or changing selection on scroll", function()
    local GGM, api = loadUI(), makeBrowserAPI()
    GGM.ShowGuildGearBrowserWindow(api, { schemaVersion = GGM.SCHEMA_VERSION, characters = {} })
    local frame = GGM.guildGearBrowserFrame
    GGM.SelectGuildGearBrowserTab(frame, "Character")
    local entries = {}
    for i = 1, 1000 do
        entries[i] = { key = "Char" .. i .. "-Realm", name = "Char" .. i, realm = "Realm" }
    end
    frame.entries = entries
    frame.listScroll:SetHeight(200)
    GGM.SelectGuildGearBrowserTab(frame, "Character")
    local pool, filtered, selected = #frame.listRows, frame.filteredEntries, frame.selectedEntry
    T.assertTrue(pool <= 9, "1000 characters must allocate only viewport rows")
    local seen = {}
    for offset = 0, frame.listContent.height, 200 do
        frame.listScroll:SetVerticalScroll(offset)
        for _, row in ipairs(frame.listRows) do if row.entry then seen[row.entry.key] = true end end
    end
    for _, entry in ipairs(entries) do T.assertTrue(seen[entry.key], "every character must remain reachable") end
    T.assertTrue(frame.filteredEntries == filtered)
    T.assertTrue(frame.selectedEntry == selected)
    local last
    for _, row in ipairs(frame.listRows) do if row.entry == entries[1000] then last = row end end
    T.assertNotNil(last)
    last.scripts.OnClick(last)
    T.assertTrue(frame.selectedEntry == entries[1000])
    frame.searchBox:SetText("Char1000")
    T.assertEqual(frame.listScroll:GetVerticalScroll(), 0)
    T.assertEqual(#frame.filteredEntries, 1)
    T.assertTrue(frame.listRows[1].entry == entries[1000])
    T.assertEqual(#frame.listRows, pool)
end)

T.test("search debounces edits and hidden callbacks do no rendering", function()
    local GGM, api = loadUI(), makeBrowserAPI()
    local recipes = { { recipeID = 1, name = "Alpha" }, { recipeID = 2, name = "Beta" } }
    installProfessionCatalogStub(GGM, function() return professionCatalog("ready", recipes) end, {})
    showAllProfessionsBrowser(GGM, api, { schemaVersion = GGM.SCHEMA_VERSION, characters = {} })
    local frame = GGM.guildGearBrowserFrame
    local timers = {}
    api.C_Timer = { After = function(seconds, callback)
        timers[#timers + 1] = { seconds = seconds, callback = callback }
    end }
    frame.professionSearchBox:SetText("Al")
    frame.professionSearchBox:SetText("Beta")
    T.assertEqual(#frame.filteredProfessionRecipes, 2)
    T.assertEqual(timers[#timers].seconds, 0.125)
    for _, timer in ipairs(timers) do timer.callback() end
    T.assertEqual(#frame.filteredProfessionRecipes, 1)
    T.assertEqual(frame.filteredProfessionRecipes[1].recipeID, 2)
    frame.professionSearchBox:SetText("Alpha")
    frame:Hide()
    timers[#timers].callback()
    T.assertEqual(frame.filteredProfessionRecipes[1].recipeID, 2)
end)


T.test("character search applies only the latest edit and pending profession search refreshes after reopening", function()
    local GGM, api, timers = loadUI(), makeBrowserAPI(), {}
    local frame = showBrowser(GGM, api, makeDB(GGM, { makeRecord(GGM) }))
    local alchemyButton = frame.professionButtons[1]
    GGM.FilterProfessionLibraryEntries = function() return { alchemyButton } end
    api.C_Timer = { After = function(_, callback) timers[#timers + 1] = callback end }
    frame.searchBox:SetText("missing")
    frame.searchBox:SetText("Alice")
    local original = frame.filteredEntries
    timers[1]()
    T.assertTrue(frame.filteredEntries == original)
    timers[2]()
    T.assertEqual(#frame.filteredEntries, 1)
    T.assertEqual(frame.selectedEntry.name, "Alice")
    local recipes = { { recipeID = 1, name = "Alpha" }, { recipeID = 2, name = "Beta" } }
    installProfessionCatalogStub(GGM, function() return professionCatalog("ready", recipes) end, {})
    GGM.SelectGuildGearBrowserTab(frame, "Professions")
    frame.professionSearchBox:SetText("Beta")
    frame:Hide()
    timers[#timers]()
    GGM.ShowGuildGearBrowserWindow(api, frame.db)
    selectAllProfessions(frame)
    T.assertEqual(#frame.filteredProfessionRecipes, 1)
    T.assertEqual(frame.professionRecipeRows[1].recipe.recipeID, 2)
end)


T.test("switching profession cancels an obsolete pending search", function()
    local GGM, api, timers = loadUI(), makeBrowserAPI(), {}
    installProfessionCatalogStub(GGM, function() return professionCatalog("ready", { { recipeID = 1, name = "Alpha" } }) end, {})
    GGM.ShowGuildGearBrowserWindow(api, makeDB(GGM))
    local frame = GGM.guildGearBrowserFrame
    api.C_Timer = { After = function(_, callback) timers[#timers + 1] = callback end }
    local filters, filter = 0, GGM.FilterProfessionRecipeBrowserEntries
    GGM.FilterProfessionRecipeBrowserEntries = function(...) filters = filters + 1; return filter(...) end
    frame.professionSearchBox:SetText("Alpha")
    GGM.SelectProfession(frame, "Blacksmithing")
    local afterSelection = filters
    timers[1]()
    T.assertEqual(filters, afterSelection, "the previous profession's search must be cancelled")
end)
T.test('PR5 catalog preparation yields and cancels hidden or replaced selections', function()
    local G, api, calls = loadUI(), makeBrowserAPI(), {}
    G.CPUManualDriver = true
    T.loadAddonFile('The Guild Book/CPUWork.lua',G)
    installProfessionCatalogStub(G, function(id)
        for i=1,1000 do G.CPUCheckpoint() end
        return professionCatalog('ready',{{recipeID=id,name='Result '..id}})
    end, calls)
    showAllProfessionsBrowser(G,api,makeDB(G))
    local frame=G.guildGearBrowserFrame
    T.assertNil(frame.professionCatalog, 'catalog should publish only when complete')
    G.RunCPUFrame(); T.assertNil(frame.professionCatalog)
    frame:Hide(); G.RunCPUFrame()
    T.assertEqual(G.GetCPUJobCount(),0)
    selectAllProfessions(frame)
    G.ShowGuildGearBrowserWindow(api,frame.db)
    G.SelectProfession(frame,'Blacksmithing')
    for i=1,100 do G.RunCPUFrame() end
    T.assertEqual(frame.professionCatalog.recipes[1].recipeID,164)
    T.assertEqual(G.GetCPUJobCount(),0)
end)
T.test('PR5 recipe search slices and publishes only the latest complete query',function()
    local G, api, recipes=loadUI(),makeBrowserAPI(),{}
    for i=1,4096 do recipes[i]={recipeID=i,name='Recipe '..i} end
    installProfessionCatalogStub(G,function() return professionCatalog('ready',recipes) end,{})
    showAllProfessionsBrowser(G,api,makeDB(G))
    local frame=G.guildGearBrowserFrame
    G.CPUManualDriver=true; T.loadAddonFile('The Guild Book/CPUWork.lua',G)
    local original=frame.filteredProfessionRecipes
    frame.professionSearchBox:SetText('Recipe 4'); G.RunCPUFrame()
    T.assertTrue(frame.filteredProfessionRecipes==original)
    frame.professionSearchBox:SetText('Recipe 4096')
    for i=1,100 do G.RunCPUFrame() end
    T.assertEqual(#frame.filteredProfessionRecipes,1)
    T.assertEqual(frame.filteredProfessionRecipes[1].recipeID,4096)
    T.assertEqual(G.GetCPUJobCount(),0)
end)
T.test('PR5 character search yields and retains the latest selection and complete list',function()
    local G,api,entries=loadUI(),makeBrowserAPI(),{}
    local frame=showBrowser(G,api,makeDB(G,{makeRecord(G)}))
    for i=1,4096 do entries[i]={key='Char'..i..'-Realm',name='Char'..i,realm='Realm'} end
    frame.entries=entries
    G.SelectGuildGearBrowserTab(frame,'Character')
    G.CPUManualDriver=true; T.loadAddonFile('The Guild Book/CPUWork.lua',G)
    local original=frame.filteredEntries
    frame.searchBox:SetText('Char4'); G.RunCPUFrame()
    T.assertTrue(frame.filteredEntries==original)
    frame.searchBox:SetText('Char4096')
    for i=1,100 do G.RunCPUFrame() end
    T.assertEqual(#frame.filteredEntries,1); T.assertEqual(frame.selectedEntry.key,'Char4096-Realm')
    T.assertEqual(G.GetCPUJobCount(),0)
end)
T.test('PR5 character build restarts when the search changes while queued',function()
    local G,api,timers=loadUI(),makeBrowserAPI(),{}
    local frame=showBrowser(G,api,makeDB(G,{makeRecord(G),makeRecord(G)}))
    G.CPUManualDriver=true; T.loadAddonFile('The Guild Book/CPUWork.lua',G)
    api.C_Timer={After=function(_,callback) timers[#timers+1]=callback end}

    frame.charactersDirty=true
    G.SelectGuildGearBrowserTab(frame,'Character')
    T.assertEqual(G.GetCPUJobCount(),1)
    frame.searchBox:SetText('Alice')
    T.assertEqual(#timers,1,'search debounce should be waiting while build runs')

    for i=1,100 do G.RunCPUFrame() end
    T.assertEqual(G.GetCPUJobCount(),0)
    T.assertEqual(#timers,2,'stale build should queue a replacement refresh')

    timers[2]()
    T.assertEqual(G.GetCPUJobCount(),1)
    for i=1,100 do G.RunCPUFrame() end
    T.assertEqual(G.GetCPUJobCount(),0)
    T.assertEqual(#frame.filteredEntries,1)
    T.assertEqual(frame.filteredEntries[1].name,'Alice')
end)
T.test('changing profession clears recycled rows until the new catalog completes',function()
    local G,api=loadUI(),makeBrowserAPI()
    installProfessionCatalogStub(G,function(id) return professionCatalog('ready',{{recipeID=id,name='Recipe '..id}}) end,{})
    showAllProfessionsBrowser(G,api,makeDB(G))
    local frame=G.guildGearBrowserFrame
    T.assertNotNil(frame.professionRecipeRows[1].recipe)
    G.CPUManualDriver=true;T.loadAddonFile('The Guild Book/CPUWork.lua',G)
    G.SelectProfession(frame,'Blacksmithing')
    for _,row in ipairs(frame.professionRecipeRows) do T.assertNil(row.recipe) end
    for i=1,100 do G.RunCPUFrame() end
    T.assertEqual(frame.professionRecipeRows[1].recipe.recipeID,164)
end)

local function professionFilterFixture()
    local G, api = loadUI(), makeBrowserAPI()
    local recipes = {
        { recipeID = 701, name = "Plate Helm", learned = true, craftable = true,
            categoryIDs = { 10, 11 }, slotKeys = { "slot:helm" } },
        { recipeID = 702, name = "Two-Handed Mace", learned = true, craftable = false,
            categoryIDs = { 10, 12 }, slotKeys = { "slot:mace" } },
        { recipeID = 703, name = "Training Sword", learned = false, craftable = false,
            categoryIDs = { 10, 12 }, slotKeys = { "slot:sword" } },
    }
    local function node(key, name, children, id)
        return { key = key, name = name, id = id, children = children or {} }
    end
    local model = {
        state = "ready", recipes = recipes,
        categories = { node("category:10", "Blacksmithing", {
            node("category:11", "Armor", nil, 11),
            node("category:12", "Weapons", nil, 12),
        }, 10) },
        slots = { node("weapons", "Weapons", {
            node("slot:mace", "Two-Handed Maces"),
            node("slot:sword", "One-Handed Swords"),
        }) },
        availability = { profession = "available", materials = "available", bank = "verified",
            categories = "available", slots = "available" },
    }
    G.BuildProfessionRecipeFilterModel = function() return model end
    installProfessionCatalogStub(G, function()
        return professionCatalog("ready", {
            { recipeID = 701, name = "Plate Helm", knownBy = {} },
            { recipeID = 702, name = "Two-Handed Mace", knownBy = {} },
            { recipeID = 703, name = "Training Sword", knownBy = {} },
        })
    end, {})
    G.FilterProfessionLibraryEntries = function(entries)
        for _, entry in ipairs(entries) do
            if entry.key == "Blacksmithing" then return { entry } end
        end
        return {}
    end
    local frame = showAllProfessionsBrowser(G, api, makeDB(G))
    local categoryRoot = model.categories[1]
    for _, child in ipairs(categoryRoot.children) do child.parent = categoryRoot end
    frame.professionLibraryToggle.ownRadio.scripts.OnClick(frame.professionLibraryToggle.ownRadio)
    return G, api, frame, model
end

T.test("profession recipe filters work for the selected profession in Own and All modes", function()
    local G, api, frame = professionFilterFixture()
    local trigger = frame.professionFiltersButton
    T.assertNotNil(trigger, "Own profession page needs its filter dropdown trigger")
    T.assertTrue(frame.professionFiltersMenu:GetFrameLevel() >= trigger:GetFrameLevel() + 10,
        "filter menu should be raised above recipe content in the same frame strata")
    T.assertTrue(trigger:IsShown())
    T.assertFalse(frame.professionFiltersMenu:IsShown())
    trigger.scripts.OnClick(trigger)
    T.assertTrue(frame.professionFiltersMenu:IsShown())
    T.assertTrue(frame.professionFilterControls.learned:GetChecked())
    T.assertTrue(frame.professionFilterControls.unlearned:GetChecked())
    T.assertFalse(frame.professionFilterControls.materials:GetChecked())
    T.assertEqual(#frame.filteredProfessionRecipes, 3, "Have Materials starts disabled for the selected character")
    frame.professionFilterControls.materials.scripts.OnClick(frame.professionFilterControls.materials)
    T.assertTrue(frame.professionFilterControls.materials:GetChecked())
    T.assertEqual(#frame.filteredProfessionRecipes, 1, "enabling Have Materials shows craftable selected-character recipes")
    frame.professionLibraryToggle.allRadio.scripts.OnClick(frame.professionLibraryToggle.allRadio)
    T.assertFalse(frame.professionFiltersMenu:IsShown(), "switching library mode dismisses the filter menu")
    T.assertTrue(trigger:IsShown(), "All mode should expose the same filter menu for the selected profession")
    trigger.scripts.OnClick(trigger)
    T.assertTrue(frame.professionFiltersMenu:IsShown())
    T.assertEqual(#frame.filteredProfessionRecipes, 1, "All mode applies selected-character Have Materials to guild recipes")
    frame.professionFilterControls.materials.scripts.OnClick(frame.professionFilterControls.materials)
    T.assertEqual(#frame.filteredProfessionRecipes, 3, "All mode can disable Have Materials and browse guild recipes")
    G.SelectGuildGearBrowserTab(frame, "Character")
    T.assertFalse(trigger:IsShown(), "filters are hidden outside the Professions page")
    G.SelectGuildGearBrowserTab(frame, "Professions")
    T.assertTrue(trigger:IsShown(), "filters remain available in All mode after returning to Professions")
end)

T.test("profession filter button and recipe heading use the agreed layout", function()
    local _, _, frame = professionFilterFixture()
    local trigger = frame.professionFiltersButton
    T.assertEqual(trigger.template, "UIPanelButtonTemplate")
    T.assertEqual(trigger.point.point, "TOPRIGHT")
    T.assertEqual(trigger.point.relativeTo, frame.professionDetailPanel)
    T.assertEqual(trigger.point.relativePoint, "TOPRIGHT")

    T.assertEqual(frame.professionCount.font.size, 17)
    T.assertEqual(frame.professionCount.journalFontSize, frame.professionRecipeHeading.journalFontSize)
    T.assertEqual(frame.professionCount.journalFont, frame.professionRecipeHeading.journalFont)
    T.assertEqual(frame.professionCount.point.relativeTo, frame.professionRecipeHeading)
    T.assertEqual(frame.professionCount.point.relativePoint, "RIGHT")
    T.assertEqual(frame.professionCount.text, "(3)")
    T.assertTrue(frame.professionStatus:GetHeight() >= 36, "status space is reserved for two readable lines")
    T.assertTrue(frame.professionRecipeHeading.point.y <= -250, "the recipe heading starts below the reserved status space")
    T.assertTrue(frame.professionRecipeScroll.points.TOPLEFT.y <= -280, "recipe rows start below the heading")

    local headingY = frame.professionRecipeHeading.point.y
    frame.professionStatus:SetText(string.rep("Personal bank status text. ", 8))
    T.assertEqual(frame.professionRecipeHeading.point.y, headingY,
        "the heading has the same reserved position with long status text")
    frame.professionStatus:Hide()
    T.assertEqual(frame.professionRecipeHeading.point.y, headingY,
        "the heading keeps its position when no status is visible")
end)

T.test("recipe list shows bag craft counts beneath the CAN CRAFT heading", function()
    local _, _, frame, model = professionFilterFixture()
    model.recipes[1].bagCraftableCount = 4
    model.recipes[2].bagCraftableCount = 0
    model.recipes[3].bagCraftableCount = nil
    frame.professionFilterEventFrame.scripts.OnEvent(frame.professionFilterEventFrame, "BAG_UPDATE_DELAYED")

    T.assertEqual(frame.professionCraftableHeading:GetText(), "CAN CRAFT")
    T.assertNil(frame.professionCraftableCount, "the heading has no aggregate count")
    T.assertEqual(frame.professionRecipeRows[1].craftableCount:GetText(), "4")
    T.assertEqual(frame.professionRecipeRows[2].craftableCount:GetText(), "0")
    T.assertEqual(frame.professionRecipeRows[3].craftableCount:GetText(), "—",
        "recipes without a known bag count display an unavailable marker")
    T.assertTrue(frame.professionRecipeRows[1].craftableCount.point.x >= 300,
        "the craft-count column sits near the middle of the recipe row")
end)

T.test("profession filter close control uses Blizzard's default close button", function()
    local _, _, frame = professionFilterFixture()
    local close = frame.professionFiltersCloseButton
    T.assertNotNil(close)
    T.assertEqual(close.template, "UIPanelCloseButton")
    T.assertEqual(close:GetWidth(), 32)
    T.assertEqual(close:GetHeight(), 32)
    T.assertEqual(close.point.point, "TOPRIGHT")

    frame.professionFiltersMenu:Show()
    close.scripts.OnClick(close)
    T.assertFalse(frame.professionFiltersMenu:IsShown(), "Blizzard close button hides the filter menu")
end)

T.test("profession filter checkboxes keep a square outline and only toggle the checkmark", function()
    local _, _, frame = professionFilterFixture()
    frame.professionFiltersButton.scripts.OnClick(frame.professionFiltersButton)

    local learned = frame.professionFilterControls.learned
    local square = learned.checkboxSquare
    T.assertNotNil(square, "each filter checkbox needs a separate square indicator")
    T.assertEqual(square:GetWidth(), 16)
    T.assertEqual(square:GetHeight(), 16)
    T.assertEqual(learned.indicator.texture, "Interface\\Buttons\\UI-CheckBox-Check",
        "checked state must use the game's checkmark texture, not a font glyph")
    T.assertTrue(learned.indicator.visible, "checked controls display the checkmark")
    T.assertEqual(learned.visualState, "idle", "checked state must not tint the full row")

    local rowTint = table.concat(learned.background.vertexColor, ",")
    local squareTint = table.concat(square.background.vertexColor, ",")
    learned.scripts.OnClick(learned)
    T.assertFalse(learned:GetChecked())
    T.assertFalse(learned.indicator.visible, "unchecked controls leave the square open")
    T.assertEqual(learned.visualState, "idle")
    T.assertEqual(table.concat(learned.background.vertexColor, ","), rowTint)
    T.assertEqual(table.concat(square.background.vertexColor, ","), squareTint)

    learned.scripts.OnClick(learned)
    T.assertTrue(learned:GetChecked())
    T.assertTrue(learned.indicator.visible)
    T.assertEqual(learned.visualState, "idle")
    T.assertEqual(table.concat(learned.background.vertexColor, ","), rowTint)
    T.assertEqual(table.concat(square.background.vertexColor, ","), squareTint)
end)

T.test("profession filter groups only expand and leaves select categories and slots", function()
    local G, _, frame = professionFilterFixture()
    local trigger = frame.professionFiltersButton
    trigger.scripts.OnClick(trigger)
    local controls = frame.professionFilterControls
    T.assertEqual(#frame.filteredProfessionRecipes, 3)
    T.assertEqual(frame.professionCount.text, "(3)")
    T.assertTrue(frame.professionFiltersMenu:IsShown(), "toggling a filter keeps the menu open")

    local categoryRoot = controls.categories["category:10"]
    T.assertNotNil(categoryRoot, "category tree must render the profession's live categories")
    T.assertNil(categoryRoot.checkboxSquare, "category groups must not show a checkbox")
    T.assertEqual(categoryRoot.expandLabel.textColor[1], G.UITheme.text[1], "expand marks use the dark ink color")
    T.assertEqual(categoryRoot.expandLabel.textColor[2], G.UITheme.text[2])
    T.assertEqual(categoryRoot.expandLabel.textColor[3], G.UITheme.text[3])
    categoryRoot.expandButton.scripts.OnClick(categoryRoot.expandButton)
    local armor = controls.categories["category:11"]
    local weapons = controls.categories["category:12"]
    T.assertNotNil(armor, "expanding a group reveals child categories")
    T.assertNotNil(armor.checkboxSquare, "leaf categories keep their checkboxes")
    T.assertNotNil(weapons.checkboxSquare, "leaf categories keep their checkboxes")
    categoryRoot.scripts.OnClick(categoryRoot)
    T.assertNil(next(frame.professionRecipeFilterState.categoryIDs), "expanding or collapsing a group must not select its descendants")
    T.assertEqual(#frame.filteredProfessionRecipes, 3)
    categoryRoot.expandButton.scripts.OnClick(categoryRoot.expandButton)
    controls.categories["category:11"].scripts.OnClick(controls.categories["category:11"])
    T.assertTrue(frame.professionRecipeFilterState.categoryIDs[11], "a leaf category can be selected")
    T.assertEqual(#frame.filteredProfessionRecipes, 1)
    T.assertEqual(frame.professionCount.text, "(1)")
    controls.categories["category:11"].scripts.OnClick(controls.categories["category:11"])
    T.assertNil(next(frame.professionRecipeFilterState.categoryIDs))

    local slotGroup = controls.slots.weapons
    T.assertNotNil(slotGroup, "slot options are tailored to outputs made by this profession")
    T.assertNil(slotGroup.checkboxSquare, "slot groups must not show a checkbox")
    slotGroup.expandButton.scripts.OnClick(slotGroup.expandButton)
    T.assertNotNil(controls.slots["slot:mace"].checkboxSquare, "terminal slots have checkboxes")
    T.assertNotNil(controls.slots["slot:sword"].checkboxSquare, "terminal slots have checkboxes")
    slotGroup.scripts.OnClick(slotGroup)
    T.assertNil(next(frame.professionRecipeFilterState.slotKeys), "expanding or collapsing a slot group must not select its descendants")
    T.assertEqual(#frame.filteredProfessionRecipes, 3)
    slotGroup.expandButton.scripts.OnClick(slotGroup.expandButton)
    controls.slots["slot:mace"].scripts.OnClick(controls.slots["slot:mace"])
    T.assertTrue(frame.professionRecipeFilterState.slotKeys["slot:mace"])
    T.assertEqual(#frame.filteredProfessionRecipes, 1)
    T.assertEqual(frame.filteredProfessionRecipes[1].recipeID, 702)
end)

T.test("empty category and slot sections are omitted from the filter menu", function()
    local _, _, frame, model = professionFilterFixture()
    model.slots = {}
    frame.professionFiltersButton.scripts.OnClick(frame.professionFiltersButton)

    local function visibleCount(labels, text)
        local count = 0
        for _, label in pairs(labels) do
            if label:IsShown() and label:GetText() == text then count = count + 1 end
        end
        return count
    end
    local function refresh()
        frame.professionFilterEventFrame.scripts.OnEvent(frame.professionFilterEventFrame, "BAG_UPDATE_DELAYED")
    end
    T.assertEqual(visibleCount(frame.professionFilterSectionLabels, "CATEGORIES"), 1,
        "categories remain visible when the profession has category nodes")
    T.assertEqual(visibleCount(frame.professionFilterSectionLabels, "SLOTS"), 0,
        "a profession with no slots has no Slots heading")
    T.assertEqual(visibleCount(frame.professionFilterEmptyLabels, "No equipment slots for this profession."), 0,
        "a profession with no slots has no empty-state message")

    model.categories = {}
    model.slots = { { key = "slot:head", name = "Head", children = {} } }
    refresh()
    T.assertEqual(visibleCount(frame.professionFilterSectionLabels, "CATEGORIES"), 0,
        "a profession with no categories has no Categories heading")
    T.assertEqual(visibleCount(frame.professionFilterSectionLabels, "SLOTS"), 1,
        "slots remain visible when the profession has slot nodes")
    T.assertEqual(visibleCount(frame.professionFilterEmptyLabels, "No live categories available."), 0,
        "a profession with no categories has no empty-state message")

    model.slots = {}
    refresh()
    T.assertEqual(visibleCount(frame.professionFilterSectionLabels, "CATEGORIES"), 0)
    T.assertEqual(visibleCount(frame.professionFilterSectionLabels, "SLOTS"), 0)
    T.assertEqual(visibleCount(frame.professionFilterEmptyLabels, "No equipment slots for this profession."), 0)
end)

T.test("disappeared selected slots remain clearable after a model refresh", function()
    local _, _, frame, model = professionFilterFixture()
    frame.professionFiltersButton.scripts.OnClick(frame.professionFiltersButton)
    frame.professionFilterControls.slots.weapons.expandButton.scripts.OnClick(
        frame.professionFilterControls.slots.weapons.expandButton)
    frame.professionFilterControls.slots["slot:mace"].scripts.OnClick(
        frame.professionFilterControls.slots["slot:mace"])
    T.assertEqual(#frame.filteredProfessionRecipes, 1)

    model.slots = {}
    frame.professionFilterEventFrame.scripts.OnEvent(frame.professionFilterEventFrame, "BAG_UPDATE_DELAYED")

    local disappeared = frame.professionFilterControls.slots["slot:mace"]
    T.assertNotNil(disappeared, "the selected slot remains represented after disappearing from the model")
    T.assertTrue(disappeared:IsShown())
    T.assertTrue(disappeared:GetChecked())
    T.assertTrue(string.find(disappeared:GetText(), "Unavailable slot", 1, true) ~= nil)

    disappeared.scripts.OnClick(disappeared)
    T.assertNil(frame.professionRecipeFilterState.slotKeys["slot:mace"], "the retained row clears the stale selection")
    T.assertEqual(#frame.filteredProfessionRecipes, 3)
end)

T.test("filter tree preserves scrollbar position when a group changes content height", function()
    local _, _, frame = professionFilterFixture()
    local scroll = frame.professionFilterScroll
    scroll:SetHeight(80)
    frame.professionFiltersButton.scripts.OnClick(frame.professionFiltersButton)
    local nativeRange = frame.professionFilterContent:GetHeight() - scroll:GetHeight()
    frame.api.issecretvalue = function() return false end
    scroll.GetVerticalScrollRange = function() return nativeRange end
    local deferred = {}
    frame.api.C_Timer = { After = function(delay, callback)
        T.assertEqual(delay, 0, "range restoration runs on the next frame")
        deferred[#deferred + 1] = callback
    end }

    local group = frame.professionFilterNodeControls.categories["category:10"]
    local function position()
        local range = frame.professionFilterContent:GetHeight() - scroll:GetHeight()
        return range > 0 and scroll:GetVerticalScroll() / range or 0
    end
    local initialRange = frame.professionFilterContent:GetHeight() - scroll:GetHeight()
    T.assertTrue(initialRange > 0)
    scroll:SetVerticalScroll(initialRange / 2)
    group.expandButton.scripts.OnClick(group.expandButton)
    T.assertEqual(#deferred, 1, "expanding defers restoration until the scroll range settles")
    nativeRange = frame.professionFilterContent:GetHeight() - scroll:GetHeight()
    scroll:SetVerticalScroll(0) -- simulate WoW clamping the old offset after child layout
    deferred[1]()
    T.assertTrue(math.abs(position() - 0.5) < 0.001, "opening a group keeps the scrollbar at the same relative position")

    local expandedRange = frame.professionFilterContent:GetHeight() - scroll:GetHeight()
    scroll:SetVerticalScroll(expandedRange * 0.5)
    group.expandButton.scripts.OnClick(group.expandButton)
    T.assertEqual(#deferred, 2, "collapsing also defers restoration")
    nativeRange = frame.professionFilterContent:GetHeight() - scroll:GetHeight()
    scroll:SetVerticalScroll(0)
    deferred[2]()
    T.assertTrue(math.abs(position() - 0.5) < 0.001, "closing a group keeps the scrollbar at the same relative position")

    scroll:SetVerticalScroll(initialRange * 0.35)
    group.expandButton.scripts.OnClick(group.expandButton)
    local rangeAfterOpen = frame.professionFilterContent:GetHeight() - scroll:GetHeight()
    nativeRange = rangeAfterOpen
    scroll:SetVerticalScroll(rangeAfterOpen * 0.35)
    group.expandButton.scripts.OnClick(group.expandButton)
    nativeRange = frame.professionFilterContent:GetHeight() - scroll:GetHeight()
    T.assertEqual(#deferred, 4)
    scroll:SetVerticalScroll(0)
    deferred[3]()
    T.assertEqual(scroll:GetVerticalScroll(), 0, "an obsolete restore cannot replace the most recent layout position")
    deferred[4]()
    T.assertTrue(math.abs(position() - 0.35) < 0.001, "the newest expand/collapse callback owns the restored fraction")
end)

T.test("bag and personal bank changes refresh Have Materials for the selected character", function()
    local _, _, frame, model = professionFilterFixture()
    frame.professionFilterControls.materials.scripts.OnClick(frame.professionFilterControls.materials)
    T.assertFalse(frame.professionFilterBankVerified, "a new session starts with unverified bank contents")
    T.assertTrue(frame.professionFilterEventFrame.registeredEvents.BAG_UPDATE_DELAYED)
    T.assertTrue(frame.professionFilterEventFrame.registeredEvents.BANKFRAME_OPENED)
    T.assertTrue(frame.professionFilterEventFrame.registeredEvents.BANKFRAME_CLOSED)
    T.assertTrue(frame.professionFilterEventFrame.registeredEvents.PLAYERREAGENTBANKSLOTS_CHANGED)
    T.assertEqual(#frame.filteredProfessionRecipes, 1)
    frame.professionFiltersButton.scripts.OnClick(frame.professionFiltersButton)

    frame.professionFilterEventFrame.scripts.OnEvent(frame.professionFilterEventFrame, "BANKFRAME_OPENED")
    T.assertTrue(frame.professionFilterBankVerified, "opening the character bank verifies its current session contents")
    T.assertTrue(frame.professionFiltersMenu:IsShown(), "bank refreshes do not dismiss the menu")

    model.recipes[1].craftable = false
    frame.professionFilterEventFrame.scripts.OnEvent(frame.professionFilterEventFrame, "BAG_UPDATE_DELAYED")
    T.assertEqual(#frame.filteredProfessionRecipes, 0)
    T.assertTrue(frame.professionFiltersMenu:IsShown(), "refreshing materials does not dismiss the menu")

    model.recipes[1].craftable = true
    frame.professionFilterEventFrame.scripts.OnEvent(frame.professionFilterEventFrame, "BANKFRAME_CLOSED")
    T.assertTrue(frame.professionFilterBankVerified, "closing the bank keeps this session's fresh snapshot usable")
    T.assertEqual(#frame.filteredProfessionRecipes, 1)

    model.recipes[1].craftable = false
    model.availability.materials = "unavailable"
    frame.professionFilterEventFrame.scripts.OnEvent(frame.professionFilterEventFrame, "BAG_UPDATE_DELAYED")
    T.assertEqual(#frame.filteredProfessionRecipes, 0)
    T.assertTrue(string.find(frame.professionStatus.text, "Live material availability is unavailable", 1, true) ~= nil)
    T.assertTrue(string.find(frame.professionFilterModelLabel.text, "Live material availability is unavailable", 1, true) ~= nil)
end)

T.test("leaving combat refreshes the profession recipe filter model", function()
    local G, _, frame = professionFilterFixture()
    T.assertTrue(frame.professionFilterEventFrame.registeredEvents.PLAYER_REGEN_ENABLED,
        "the filter model refresh frame must retry after combat ends")
    local buildModel = G.BuildProfessionRecipeFilterModel
    local buildCount = 0
    G.BuildProfessionRecipeFilterModel = function(...)
        buildCount = buildCount + 1
        return buildModel(...)
    end
    frame.professionRecipeFilterModel = nil
    frame.professionFilterEventFrame.scripts.OnEvent(frame.professionFilterEventFrame, "PLAYER_REGEN_ENABLED")
    T.assertNotNil(frame.professionRecipeFilterModel,
        "combat-end refresh rebuilds the model instead of leaving filters unavailable")
    T.assertEqual(buildCount, 1, "combat-end refresh reruns the material availability build")
end)

T.test("bag updates refresh Have Materials in All using the selected character model", function()
    local _, _, frame, model = professionFilterFixture()
    frame.professionLibraryToggle.allRadio.scripts.OnClick(frame.professionLibraryToggle.allRadio)
    frame.professionFilterControls.materials.scripts.OnClick(frame.professionFilterControls.materials)
    T.assertEqual(#frame.filteredProfessionRecipes, 1)
    frame.professionFiltersButton.scripts.OnClick(frame.professionFiltersButton)

    model.recipes[1].craftable = false
    frame.professionFilterEventFrame.scripts.OnEvent(frame.professionFilterEventFrame, "BAG_UPDATE_DELAYED")
    T.assertEqual(#frame.filteredProfessionRecipes, 0,
        "All must refresh selected-character material availability after bag changes")
    T.assertTrue(frame.professionFiltersMenu:IsShown(), "a bag refresh does not dismiss the filter menu")

    model.recipes[1].craftable = true
    frame.professionFilterEventFrame.scripts.OnEvent(frame.professionFilterEventFrame, "BAG_UPDATE_DELAYED")
    T.assertEqual(#frame.filteredProfessionRecipes, 1)
end)

T.test("currency updates refresh Have Materials in All using the selected character model", function()
    local _, _, frame, model = professionFilterFixture()
    frame.professionLibraryToggle.allRadio.scripts.OnClick(frame.professionLibraryToggle.allRadio)
    frame.professionFilterControls.materials.scripts.OnClick(frame.professionFilterControls.materials)
    T.assertEqual(#frame.filteredProfessionRecipes, 1)
    T.assertTrue(frame.professionFilterEventFrame.registeredEvents.CURRENCY_DISPLAY_UPDATE,
        "currency changes must invalidate currency-backed reagent counts")

    model.recipes[1].craftable = false
    frame.professionFilterEventFrame.scripts.OnEvent(frame.professionFilterEventFrame, "CURRENCY_DISPLAY_UPDATE")
    T.assertEqual(#frame.filteredProfessionRecipes, 0,
        "currency changes refresh selected-character material availability")

    model.recipes[1].craftable = true
    frame.professionFilterEventFrame.scripts.OnEvent(frame.professionFilterEventFrame, "CURRENCY_DISPLAY_UPDATE")
    T.assertEqual(#frame.filteredProfessionRecipes, 1)
end)

T.test("filter metadata jobs cannot publish after switching profession or Own/All mode", function()
    local G, _, frame, model = professionFilterFixture()
    G.CPUManualDriver = true
    T.loadAddonFile("The Guild Book/CPUWork.lua", G)
    G.BuildProfessionRecipeFilterModel = function(_, professionID, catalog)
        for _ = 1, 200 do G.CPUCheckpoint() end
        local recipes = {}
        for _, recipe in ipairs(catalog) do
            local copy = {}
            for key, value in pairs(recipe) do copy[key] = value end
            copy.learned, copy.craftable = true, true
            copy.categoryIDs, copy.slotKeys = {}, {}
            recipes[#recipes + 1] = copy
        end
        return { state = "ready", professionID = professionID, recipes = recipes,
            categories = model.categories, slots = model.slots }
    end
    G.FilterProfessionLibraryEntries = function(entries)
        local visible = {}
        for _, entry in ipairs(entries) do
            if entry.key == "Blacksmithing" or entry.key == "Tailoring" then visible[#visible + 1] = entry end
        end
        return visible
    end

    frame.professionFilterEventFrame.scripts.OnEvent(frame.professionFilterEventFrame, "BAG_UPDATE_DELAYED")
    T.assertTrue(G.GetCPUJobCount() > 0)
    G.SelectProfession(frame, "Tailoring")
    for _ = 1, 300 do G.RunCPUFrame() end
    T.assertEqual(frame.professionRecipeFilterModel.professionID, 197,
        "a pending Blacksmithing model must not replace Tailoring's current model")

    frame.professionFilterEventFrame.scripts.OnEvent(frame.professionFilterEventFrame, "BANKFRAME_CLOSED")
    T.assertTrue(G.GetCPUJobCount() > 0)
    frame.professionLibraryToggle.allRadio.scripts.OnClick(frame.professionLibraryToggle.allRadio)
    for _ = 1, 300 do G.RunCPUFrame() end
    T.assertNotNil(frame.professionRecipeFilterModel, "All mode must build its own catalog-preserving filter model")
    T.assertEqual(frame.professionRecipeFilterModelMode, "All", "a pending Own result cannot publish into All mode")
    T.assertEqual(frame.professionRecipeFilterModel.professionID, 197)
    T.assertEqual(frame.professionLibraryMode, "All")
    T.assertEqual(G.GetCPUJobCount(), 0)
end)

T.test("reused category controls bind to the newly selected profession tree", function()
    local G, _, frame, model = professionFilterFixture()
    frame.professionFiltersButton.scripts.OnClick(frame.professionFiltersButton)
    local oldControl = frame.professionFilterControls.categories["category:10"]
    T.assertNotNil(oldControl)
    model.categories = { { key = "category:10", id = 10, name = "Tailoring", children = {
        { key = "category:20", id = 20, name = "Cloth", children = {} },
    } } }
    model.categories[1].children[1].parent = model.categories[1]
    G.FilterProfessionLibraryEntries = function(entries)
        local visible = {}
        for _, entry in ipairs(entries) do
            if entry.key == "Blacksmithing" or entry.key == "Tailoring" then visible[#visible + 1] = entry end
        end
        return visible
    end
    G.SelectProfession(frame, "Tailoring")
    frame.professionFiltersButton.scripts.OnClick(frame.professionFiltersButton)
    local root = frame.professionFilterControls.categories["category:10"]
    T.assertTrue(root == oldControl, "matching keys may reuse the visible option control")
    T.assertNil(root.checkboxSquare, "a reused category group remains expand-only")
    root.scripts.OnClick(root)
    local leaf = frame.professionFilterControls.categories["category:20"]
    T.assertNotNil(leaf)
    T.assertNotNil(leaf.checkboxSquare, "the newly selected profession's terminal category gets a checkbox")
    leaf.scripts.OnClick(leaf)
    T.assertTrue(frame.professionRecipeFilterState.categoryIDs[20])
    T.assertNil(frame.professionRecipeFilterState.categoryIDs[11], "the previous profession's child must not be selected")
end)
