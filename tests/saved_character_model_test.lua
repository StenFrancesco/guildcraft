local T = require("tests.testlib")

local VISUAL_SLOTS = {
    { key = "HEAD", id = 1 },
    { key = "SHOULDER", id = 3 },
    { key = "CHEST", id = 5 },
    { key = "WAIST", id = 6 },
    { key = "LEGS", id = 7 },
    { key = "FEET", id = 8 },
    { key = "WRIST", id = 9 },
    { key = "HANDS", id = 10 },
    { key = "BACK", id = 15 },
    { key = "MAIN_HAND", id = 16 },
    { key = "OFF_HAND", id = 17 },
    { key = "TABARD", id = 19 },
}
local LINK_SLOTS = {
    "HEAD", "SHOULDER", "CHEST", "WAIST", "LEGS", "FEET",
    "WRIST", "HANDS", "BACK", "TABARD",
}

local function loadModel()
    local GGM = {}
    T.loadAddonFile("GuildGearMemory/SavedCharacterModel.lua", GGM)
    return GGM
end

local function newFakeModel(log, resultOverrides)
    local model = { visible = false }
    local function call(name, ...)
        table.insert(log, { name = name, args = { ... }, argumentCount = select("#", ...) })
        if resultOverrides and resultOverrides[name] ~= nil then
            return resultOverrides[name]
        end
        if name == "TryOn" then return 0 end
        -- Undress, UndressSlot, and SetDisplayInfo are documented void methods.
        return nil
    end
    function model:Hide() self.visible = false; call("Hide") end
    function model:Show() self.visible = true; call("Show") end
    function model:Undress() return call("Undress") end
    function model:SetDisplayInfo(displayID) return call("SetDisplayInfo", displayID) end
    function model:TryOn(link, ...) return call("TryOn", link, ...) end
    function model:UndressSlot(slotID) return call("UndressSlot", slotID) end
    return model
end

local function makeRecord()
    local slots = {}
    for _, slot in ipairs(VISUAL_SLOTS) do
        local isHand = slot.key == "MAIN_HAND" or slot.key == "OFF_HAND"
        slots[slot.key] = {
            inventorySlotID = slot.id,
            itemID = isHand and false or 10000 + slot.id,
            itemLink = isHand and false or ("item-link:" .. slot.key),
        }
        if isHand then
            slots[slot.key].itemID = false
            slots[slot.key].itemLink = false
        end
    end
    return {
        identity = { name = "Saved", realm = "Silvermoon", raceID = 1, sex = 2, displayID = 12345 },
        gear = { slots = slots },
    }
end

local function makeView(GGM, overrides, enumSuccess)
    local log = {}
    local model = newFakeModel(log, overrides)
    local api = {
        CreateFrame = function(frameType, name, parent)
            T.assertEqual(frameType, "DressUpModel")
            T.assertNil(name)
            T.assertNotNil(parent)
            return model
        end,
        GetItemInfo = function(link)
            table.insert(log, { name = "GetItemInfo", args = { link } })
            return "item-name"
        end,
        Enum = { ItemTryOnReason = { Success = enumSuccess or 0, WrongRace = 1, NotEquippable = 2, DataPending = 3 } },
        MAINHANDSLOT = "Main hand",
        SECONDARYHANDSLOT = "Off hand",
    }
    local parent = {}
    return GGM.CreateSavedCharacterModel(api, parent), model, log
end

local function findCalls(log, name)
    local calls = {}
    for _, entry in ipairs(log) do
        if entry.name == name then table.insert(calls, entry) end
    end
    return calls
end

T.test("saved character model initializes from saved identity and saved item links by visual slot", function()
    local GGM = loadModel()
    local view, model, log = makeView(GGM)
    local record = makeRecord()

    local state = GGM.RenderSavedCharacterModel(view, record)

    T.assertEqual(state, "shown")
    T.assertTrue(model.visible)
    local display = findCalls(log, "SetDisplayInfo")
    T.assertEqual(#display, 1)
    T.assertEqual(display[1].args[1], record.identity.displayID)
    local tried = findCalls(log, "TryOn")
    T.assertEqual(#tried, #LINK_SLOTS)
    for index, key in ipairs(LINK_SLOTS) do
        T.assertEqual(tried[index].args[1], record.gear.slots[key].itemLink)
        T.assertNil(tried[index].args[2])
        T.assertEqual(tried[index].argumentCount, 1)
    end
end)

T.test("saved false false visual slots are explicitly cleared and unavailable slots fail closed", function()
    local GGM = loadModel()
    local view, model, log = makeView(GGM)
    local record = makeRecord()
    record.gear.slots.MAIN_HAND.itemID = false
    record.gear.slots.MAIN_HAND.itemLink = false

    T.assertEqual(GGM.RenderSavedCharacterModel(view, record), "shown")
    local clears = findCalls(log, "UndressSlot")
    T.assertEqual(#clears, 2)
    T.assertEqual(clears[1].args[1], 16)
    T.assertEqual(#findCalls(log, "TryOn"), #LINK_SLOTS)

    record.gear.slots.MAIN_HAND = { unavailable = true }
    for index = #log, 1, -1 do table.remove(log, index) end
    T.assertEqual(GGM.RenderSavedCharacterModel(view, record), "render-unavailable")
    T.assertFalse(model.visible)
    T.assertEqual(#findCalls(log, "UndressSlot"), 0)
end)

T.test("selection changes clear the previous model before initializing the next record", function()
    local GGM = loadModel()
    local view, model, log = makeView(GGM)
    local first = makeRecord()
    local second = makeRecord()
    second.identity.displayID = 54321

    T.assertEqual(GGM.RenderSavedCharacterModel(view, first), "shown")
    for index = #log, 1, -1 do table.remove(log, index) end
    local state = GGM.RenderSavedCharacterModel(view, second)

    T.assertEqual(state, "shown")
    T.assertTrue(model.visible)
    T.assertEqual(log[1].name, "Hide")
    T.assertEqual(log[2].name, "Undress")
end)

T.test("missing or malformed saved race sex or display ID never initializes a model", function()
    local GGM = loadModel()
    local invalidCases = {
        function(r) r.identity.raceID = nil end,
        function(r) r.identity.raceID = "1" end,
        function(r) r.identity.sex = nil end,
        function(r) r.identity.sex = 1 end,
        function(r) r.identity.displayID = nil end,
        function(r) r.identity.displayID = 0 end,
    }
    for _, invalidate in ipairs(invalidCases) do
        local view, model, log = makeView(GGM)
        local record = makeRecord()
        invalidate(record)
        T.assertEqual(GGM.RenderSavedCharacterModel(view, record), "identity-unavailable")
        T.assertFalse(model.visible)
        T.assertEqual(#findCalls(log, "SetDisplayInfo"), 0)
        T.assertEqual(#findCalls(log, "TryOn"), 0)
    end
end)

T.test("failed and indeterminate native model or item calls clear and hide visuals", function()
    local failureNames = { "Undress", "SetDisplayInfo", "TryOn", "UndressSlot" }
    for _, failureName in ipairs(failureNames) do
        local GGM = loadModel()
        local view, model = makeView(GGM, { [failureName] = false })
        local record = makeRecord()
        if failureName == "UndressSlot" then
            record.gear.slots.MAIN_HAND.itemID = false
            record.gear.slots.MAIN_HAND.itemLink = false
        end
        T.assertEqual(GGM.RenderSavedCharacterModel(view, record), "render-unavailable")
        T.assertFalse(model.visible)
    end

end)

T.test("native model exceptions fail closed", function()
    local methodNames = { "Undress", "SetDisplayInfo", "TryOn", "UndressSlot" }
    for _, methodName in ipairs(methodNames) do
        local GGM = loadModel()
        local view, model = makeView(GGM)
        if methodName == "UndressSlot" then
            local emptyRecord = makeRecord()
            emptyRecord.gear.slots.MAIN_HAND.itemID = false
            emptyRecord.gear.slots.MAIN_HAND.itemLink = false
            model.UndressSlot = function() error("native failure") end
            T.assertEqual(GGM.RenderSavedCharacterModel(view, emptyRecord), "render-unavailable")
        else
            model[methodName] = function() error("native failure") end
            T.assertEqual(GGM.RenderSavedCharacterModel(view, makeRecord()), "render-unavailable")
        end
        T.assertFalse(model.visible)
    end
end)

T.test("saved weapon links use the API hand strings for their exact hands", function()
    local GGM = loadModel()
    local view, model, log = makeView(GGM)
    local record = makeRecord()
    record.gear.slots.MAIN_HAND.itemID = 10016
    record.gear.slots.MAIN_HAND.itemLink = "item-link:MAIN_HAND"
    record.gear.slots.OFF_HAND.itemID = 10017
    record.gear.slots.OFF_HAND.itemLink = "item-link:OFF_HAND"

    T.assertEqual(GGM.RenderSavedCharacterModel(view, record), "shown")
    T.assertTrue(model.visible)
    local tried = findCalls(log, "TryOn")
    T.assertEqual(#tried, #LINK_SLOTS + 2)
    local seenHands = {}
    for _, call in ipairs(tried) do
        if call.args[1] == "item-link:MAIN_HAND" then
            seenHands.main = true
            T.assertEqual(call.args[2], view.api.MAINHANDSLOT)
            T.assertEqual(call.argumentCount, 2)
        elseif call.args[1] == "item-link:OFF_HAND" then
            seenHands.off = true
            T.assertEqual(call.args[2], view.api.SECONDARYHANDSLOT)
            T.assertEqual(call.argumentCount, 2)
        else
            T.assertNil(call.args[2])
            T.assertEqual(call.argumentCount, 1)
        end
    end
    T.assertTrue(seenHands.main)
    T.assertTrue(seenHands.off)
end)

T.test("saved weapon links fail closed when an API hand string is absent or malformed", function()
    local GGM = loadModel()
    for _, invalidValue in ipairs({ false, "" }) do
        local view, model = makeView(GGM)
        view.api.MAINHANDSLOT = invalidValue
        view.api.SECONDARYHANDSLOT = invalidValue
        local record = makeRecord()
        record.gear.slots.MAIN_HAND.itemID = 10016
        record.gear.slots.MAIN_HAND.itemLink = "item-link:MAIN_HAND"
        record.gear.slots.OFF_HAND.itemID = 10017
        record.gear.slots.OFF_HAND.itemLink = "item-link:OFF_HAND"

        T.assertEqual(GGM.RenderSavedCharacterModel(view, record), "render-unavailable")
        T.assertFalse(model.visible)
    end
end)

T.test("TryOn accepts the documented enum success value and rejects data pending", function()
    local GGM = loadModel()
    local successView = makeView(GGM, { TryOn = 42 }, 42)
    T.assertEqual(GGM.RenderSavedCharacterModel(successView, makeRecord()), "shown")

    local pendingView, pendingModel = makeView(GGM, { TryOn = 3 })
    T.assertEqual(GGM.RenderSavedCharacterModel(pendingView, makeRecord()), "render-unavailable")
    T.assertFalse(pendingModel.visible)
end)

T.test("TryOn numeric zero fails closed when enum success metadata is absent", function()
    local GGM = loadModel()
    local view, model = makeView(GGM)
    view.api.Enum = nil

    T.assertEqual(GGM.RenderSavedCharacterModel(view, makeRecord()), "render-unavailable")
    T.assertFalse(model.visible)
end)

T.test("a failed second record render clears the previously shown model", function()
    local GGM = loadModel()
    local view, model, log = makeView(GGM)
    T.assertEqual(GGM.RenderSavedCharacterModel(view, makeRecord()), "shown")
    T.assertTrue(model.visible)
    for index = #log, 1, -1 do table.remove(log, index) end

    model.TryOn = function(self, link, handSlotName)
        table.insert(log, { name = "TryOn", args = { link, handSlotName } })
        return 2
    end
    local state = GGM.RenderSavedCharacterModel(view, makeRecord())

    T.assertEqual(state, "render-unavailable")
    T.assertFalse(model.visible)
    T.assertEqual(log[1].name, "Hide")
    T.assertEqual(log[2].name, "Undress")
end)

T.test("pending item data and indeterminate TryOn never produce a shown model", function()
    local GGM = loadModel()
    local view, model = makeView(GGM)
    view.api.GetItemInfo = function() return nil end
    T.assertEqual(GGM.RenderSavedCharacterModel(view, makeRecord()), "render-unavailable")
    T.assertFalse(model.visible)

    local view2, model2, log2 = makeView(GGM)
    view2.model.TryOn = function(self, link, handSlotName)
        table.insert(log2, { name = "TryOn", args = { link, handSlotName } })
    end
    T.assertEqual(GGM.RenderSavedCharacterModel(view2, makeRecord()), "render-unavailable")
    T.assertFalse(model2.visible)
end)
