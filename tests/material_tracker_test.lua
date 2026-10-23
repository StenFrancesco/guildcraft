local T = require("tests.testlib")

local function fixture()
    local GGM = {}
    T.loadAddonFile("The Guild Book/MaterialTracker.lua", GGM)
    local counts = { [101] = 1, [102] = 4, [103] = 2 }
    local api = {
        issecretvalue = function() return false end,
        UnitGUID = function() return "Player-1-ABC" end,
        C_Item = { GetItemCount = function(id, bank, uses, reagentBank, accountBank)
            T.assertFalse(bank); T.assertFalse(uses); T.assertFalse(reagentBank); T.assertFalse(accountBank)
            return counts[id] or 0
        end },
        C_CurrencyInfo = { GetCurrencyInfo = function() return { quantity = 3 } end },
    }
    local model = { state = "ready", materials = {
        { name = "Linen Cloth", quantity = 5, optional = false, choices = { { itemID = 101, name = "Linen Cloth" } } },
        { name = "Thread", quantity = 1, optional = true, choices = { { itemID = 103, name = "Thread" } } },
    } }
    return GGM, api, counts, model
end

T.test("tracker snapshots required materials and multiplies craft quantity without changing source", function()
    local GGM, api, _, model = fixture()
    T.assertEqual(type(GGM.CreateMaterialTrackingSnapshot), "function")
    local saved = assert(GGM.CreateMaterialTrackingSnapshot(api, 123, "Linen Bag", 3, model))
    T.assertEqual(#saved.materials, 1)
    local rows = GGM.BuildMaterialTrackingRows(api, saved)
    T.assertEqual(rows[1].required, 15)
    T.assertEqual(rows[1].owned, 1)
    T.assertFalse(rows[1].complete)
    model.materials[1].choices[1].name = "changed"
    T.assertEqual(saved.materials[1].choices[1].name, "Linen Cloth")
end)

T.test("tracker refreshes bag counts upward and downward and supports the legacy count API", function()
    local GGM, api, counts, model = fixture()
    local saved = assert(GGM.CreateMaterialTrackingSnapshot(api, 123, "Bag", 1, model))
    counts[101] = 8
    T.assertTrue(GGM.BuildMaterialTrackingRows(api, saved)[1].complete)
    counts[101] = 0
    api.GetItemCount, api.C_Item = api.C_Item.GetItemCount, nil
    T.assertEqual(GGM.BuildMaterialTrackingRows(api, saved)[1].owned, 0)
end)

T.test("tracker allocates alternatives across groups without double counting or starving fixed reagents", function()
    local GGM, api, counts, model = fixture()
    model.materials = {
        { name = "Either", quantity = 4, choices = { { itemID = 101, name = "A" }, { itemID = 102, name = "B" }, { itemID = 101, name = "A" } } },
        { name = "A", quantity = 1, choices = { { itemID = 101, name = "A" } } },
    }
    local saved = assert(GGM.CreateMaterialTrackingSnapshot(api, 123, "Bag", 1, model))
    local rows = GGM.BuildMaterialTrackingRows(api, saved)
    T.assertTrue(rows[1].complete); T.assertTrue(rows[2].complete)
    counts[102] = 0
    rows = GGM.BuildMaterialTrackingRows(api, saved)
    T.assertEqual(rows[1].owned + rows[2].owned, 1)
end)

T.test("tracker handles currency and marks unreadable or secret counts unknown", function()
    local GGM, api, _, model = fixture()
    model.materials[1].choices = { { currencyID = 301, name = "Token" } }
    local saved = assert(GGM.CreateMaterialTrackingSnapshot(api, 123, "Bag", 1, model))
    T.assertEqual(GGM.BuildMaterialTrackingRows(api, saved)[1].owned, 3)
    api.C_CurrencyInfo.GetCurrencyInfo = function() error("unavailable") end
    T.assertNil(GGM.BuildMaterialTrackingRows(api, saved)[1].owned)
    local secret = {}
    api.issecretvalue = function(value) return value == secret end
    api.C_CurrencyInfo.GetCurrencyInfo = function() return { quantity = secret } end
    T.assertNil(GGM.BuildMaterialTrackingRows(api, saved)[1].owned)
    api.issecretvalue = nil
    T.assertNil(GGM.CreateMaterialTrackingSnapshot(api, 123, "Bag", 1, model))
end)

T.test("tracker rejects invalid quantities unavailable recipes malformed snapshots and oversized groups", function()
    local GGM, api, _, model = fixture()
    for _, amount in ipairs({ 0, -1, 1000, 1.5, math.huge }) do
        T.assertNil(GGM.CreateMaterialTrackingSnapshot(api, 123, "Bag", amount, model))
    end
    T.assertNil(GGM.CreateMaterialTrackingSnapshot(api, 123, "Bag", 1, { state = "unavailable" }))
    local saved = assert(GGM.CreateMaterialTrackingSnapshot(api, 123, "Bag", 1, model))
    saved.materials[1].choices[1].itemID = -1
    T.assertNil(GGM.ValidateMaterialTrackingSnapshot(api, saved))
    model.materials = {}
    for i = 1, 129 do model.materials[i] = { quantity = 1, choices = { { itemID = 1, name = "A" } } } end
    T.assertNil(GGM.CreateMaterialTrackingSnapshot(api, 123, "Bag", 1, model))
end)

T.test("tracker persistence isolates characters and preserves unrelated database fields", function()
    local GGM, api, _, model = fixture()
    local db = { professions = { sentinel = true } }
    local saved = assert(GGM.CreateMaterialTrackingSnapshot(api, 123, "Bag", 1, model))
    T.assertTrue(GGM.SaveMaterialTracking(api, db, saved))
    T.assertEqual(GGM.LoadMaterialTracking(api, db).recipeID, 123)
    api.UnitGUID = function() return "Player-2-DEF" end
    T.assertNil(GGM.LoadMaterialTracking(api, db))
    T.assertTrue(GGM.SaveMaterialTracking(api, db, saved))
    T.assertTrue(GGM.SaveMaterialTracking(api, db, nil))
    T.assertNil(GGM.LoadMaterialTracking(api, db))
    api.UnitGUID = function() return "Player-1-ABC" end
    T.assertEqual(GGM.LoadMaterialTracking(api, db).recipeID, 123)
    T.assertTrue(db.professions.sentinel)
    db.materialTracking["Player-1-ABC"] = { recipeID = 123 }
    T.assertNil(GGM.LoadMaterialTracking(api, db))
end)

T.test("tracker rejects sparse snapshots and unknown bag counts rather than reporting zero", function()
    local GGM, api, _, model = fixture()
    local saved = assert(GGM.CreateMaterialTrackingSnapshot(api, 123, "Bag", 1, model))
    for _, count in ipairs({ -1, 0.5, math.huge, false, "3" }) do
        api.C_Item.GetItemCount = function() return count end
        local row = GGM.BuildMaterialTrackingRows(api, saved)[1]
        T.assertNil(row.owned)
        T.assertFalse(row.complete)
    end
    api.C_Item.GetItemCount = nil
    T.assertNil(GGM.BuildMaterialTrackingRows(api, saved)[1].owned)
    saved.materials[3], saved.materials[1] = saved.materials[1], nil
    T.assertNil(GGM.ValidateMaterialTrackingSnapshot(api, saved))
end)
