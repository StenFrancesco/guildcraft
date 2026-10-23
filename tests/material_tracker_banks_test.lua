local T = require("tests.testlib")

local function fixture()
    local G = {}
    T.loadAddonFile("The Guild Book/MaterialTracker.lua", G)
    T.loadAddonFile("The Guild Book/MaterialTrackerBanks.lua", G)
    G.IsLocalCharacterGUID = function(db, guid)
        return type(db) == "table" and type(db.localCharacterGUIDs) == "table"
            and type(guid) == "string" and db.localCharacterGUIDs[guid] == true
    end
    local api = { issecretvalue = function() return false end,
        UnitGUID = function() return "Player-1-ABC" end }
    local snapshot = assert(G.CreateMaterialTrackingSnapshot(api, 1, "Recipe", 1,
        { state = "ready", materials = {
            { quantity = 5, choices = { { itemID = 101, name = "Cloth" },
                { itemID = 101, name = "Cloth" }, { itemID = 102, name = "Other cloth" } } },
            { quantity = 1, choices = { { currencyID = 101, name = "Token" } } },
        } }))
    local function record(name, count)
        return { identity = { key = name .. "-Realm", name = name, realm = "Realm",
                guid = "Player-1234-" .. name },
            status = "cached", capturedAt = 100,
            tabs = { [1] = { id = 1, name = "Bank", numSlots = 2, status = "cached", capturedAt = 100,
                slots = { [1] = { itemID = 101, count = count }, [2] = { itemID = 102, count = 2 } } } } }
    end
    local db = { schemaVersion = 1, characters = { ["Zed-Realm"] = record("Zed", 8),
        ["Alice-Realm"] = record("Alice", 3) }, localCharacterGUIDs = {
        ["Player-1234-Zed"] = true, ["Player-1234-Alice"] = true,
    } }
    G.db = db
    setmetatable(db, { __index = function(_, key)
        if key == "guilds" then error("tracker must never read guild banks") end
    end })
    return G, api, snapshot, db
end

T.test("tracker bank locations reuse personal records in character order and deduplicate alternatives", function()
    local G, api, saved, db = fixture()
    T.assertEqual(type(G.BuildMaterialBankLocations), "function")
    local rows, status = G.BuildMaterialBankLocations(api, saved, db)
    T.assertEqual(status, "available")
    T.assertEqual(#rows[1], 2)
    T.assertEqual(rows[1][1].key, "Alice-Realm")
    T.assertEqual(rows[1][1].count, 5)
    T.assertEqual(rows[1][2].count, 10)
    T.assertEqual(rows[1][1].capturedAt, 100)
    T.assertEqual(#rows[2], 0, "currency IDs must not match bank item IDs")
end)

T.test("tracker bank locations mark partial and missing captures unknown and ignore retained incomplete slots", function()
    local G, api, saved, db = fixture()
    local alice = db.characters["Alice-Realm"]
    alice.status = "incomplete"
    alice.tabs[2] = { id = 2, name = "Old", numSlots = 1, status = "incomplete", capturedAt = 50,
        slots = { [1] = { itemID = 101, count = 999 } } }
    local rows = G.BuildMaterialBankLocations(api, saved, db)
    T.assertEqual(rows[1][1].count, 5)
    T.assertTrue(rows[1][1].partial)
    alice.tabs[1].status = "incomplete"
    rows = G.BuildMaterialBankLocations(api, saved, db)
    T.assertNil(rows[1][1].count)
    T.assertTrue(rows[1][1].partial)
end)

T.test("tracker bank locations reject invalid slot counts and malformed databases without false zeroes", function()
    local G, api, saved, db = fixture()
    for _, value in ipairs({ -1, 1.5, math.huge, "8" }) do
        db.characters["Alice-Realm"].tabs[1].slots[1].count = value
        local rows = G.BuildMaterialBankLocations(api, saved, db)
        T.assertNil(rows[1][1].count)
        T.assertTrue(rows[1][1].partial)
    end
    for _, value in ipairs({ false, {}, { schemaVersion = 2, characters = {} } }) do
        local _, status = G.BuildMaterialBankLocations(api, saved, value)
        T.assertEqual(status, "unavailable")
    end
    local rows, status = G.BuildMaterialBankLocations(api, saved, { schemaVersion = 1, characters = {} })
    T.assertEqual(status, "empty")
    T.assertEqual(#rows[1], 0)
end)

T.test("tracker toggle is additive and roundtrips through saved targets", function()
    local G, api, saved = fixture()
    T.assertFalse(G.ValidateMaterialTrackingSnapshot(api, saved).showAltMaterials)
    saved.showAltMaterials = true
    local db = {}
    T.assertTrue(G.SaveMaterialTracking(api, db, saved))
    T.assertTrue(G.LoadMaterialTracking(api, db).showAltMaterials)
end)

T.test("tracker personal banks distinguish known empty from malformed and protected records", function()
    local G, api, saved, db = fixture()
    db.characters["Alice-Realm"].tabs[1].slots = {}
    local rows = G.BuildMaterialBankLocations(api, saved, db)
    T.assertEqual(#rows[1], 1)
    T.assertEqual(rows[1][1].key, "Zed-Realm")
    db.characters["Zed-Realm"].identity.key = "Wrong-Realm"
    local status
    rows, status = G.BuildMaterialBankLocations(api, saved, db)
    T.assertEqual(status, "partial")
    T.assertEqual(#rows[1], 0)
    db.characters["Zed-Realm"] = nil
    local secret = {}
    api.issecretvalue = function(value) return value == secret end
    db.characters["Alice-Realm"].tabs[1].slots = { { itemID = 101, count = secret } }
    rows = G.BuildMaterialBankLocations(api, saved, db)
    T.assertNil(rows[1][1].count)
    T.assertTrue(rows[1][1].partial)
end)

T.test("tracker personal banks use the oldest tab time and keep bank counts separate from bags", function()
    local G, api, saved, db = fixture()
    db.characters["Alice-Realm"].tabs[2] = { id = 2, name = "Older bank", numSlots = 1,
        status = "cached", capturedAt = 50, slots = { { itemID = 101, count = 7 } } }
    local locations = G.BuildMaterialBankLocations(api, saved, db)
    T.assertEqual(locations[1][1].count, 12)
    T.assertEqual(locations[1][1].capturedAt, 50)
    api.C_Item = { GetItemCount = function() return 0 end }
    T.assertEqual(G.BuildMaterialTrackingRows(api, saved)[1].owned, 0)
    T.assertFalse(G.BuildMaterialTrackingRows(api, saved)[1].complete)
    T.assertEqual(db.characters["Alice-Realm"].tabs[2].slots[1].count, 7)
end)
