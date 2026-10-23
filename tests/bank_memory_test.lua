local T = require("tests.testlib")

local function loadModule()
    local memory = {}
    local chunk = loadfile("The Guild Book Bank/BankMemory.lua")
    if chunk then
        chunk("The Guild Book Bank", memory)
    end
    return memory
end

local function makeAPI()
    local api = {
        Enum = { BankType = { Character = 1, Guild = 2 } },
        combat = false,
        now = 1700000000,
        personalTabs = {
            { ID = 5, name = "Materials" },
        },
        personalSlots = {
            [5] = {
                [1] = { itemID = 1001, hyperlink = "|Hitem:1001|h[Ore]|h", iconFileID = 123, stackCount = 20 },
            },
        },
        personalNumSlotsOverride = nil,
        guildName = "Raid Team",
        guildRealm = "Silvermoon",
        guildTabCount = 2,
        currentGuildTab = 1,
        guildTabNames = { "Guild Tab 1", "Guild Tab 2" },
        guildItems = {},
        calls = {},
    }

    api.issecretvalue = function(value)
        api.calls.secretChecks = (api.calls.secretChecks or 0) + 1
        return type(value) == "table" and value.isSecret == true
    end
    api.InCombatLockdown = function()
        api.calls.combatChecks = (api.calls.combatChecks or 0) + 1
        return api.combat
    end
    api.time = function() return api.now end
    api.UnitFullName = function(unit)
        T.assertEqual(unit, "player")
        return "Alice", "Silvermoon"
    end
    api.GetRealmName = function() return "Silvermoon" end
    api.GetGuildInfo = function(unit)
        T.assertEqual(unit, "player")
        return api.guildName, nil, nil, api.guildRealm
    end
    api.C_Bank = {
        CanUseBank = function(bankType)
            api.calls.canUseBank = (api.calls.canUseBank or 0) + 1
            T.assertEqual(bankType, api.Enum.BankType.Character)
            return true
        end,
        FetchPurchasedBankTabData = function(bankType)
            api.calls.personalTabData = (api.calls.personalTabData or 0) + 1
            T.assertEqual(bankType, api.Enum.BankType.Character)
            return api.personalTabs
        end,
    }
    api.C_Container = {
        GetContainerNumSlots = function(containerID)
            api.calls.personalNumSlots = (api.calls.personalNumSlots or 0) + 1
            if api.personalNumSlotsOverride then return api.personalNumSlotsOverride end
            return api.personalSlots[containerID] and 2 or 0
        end,
        GetContainerItemInfo = function(containerID, slotID)
            api.calls.personalItemInfo = (api.calls.personalItemInfo or 0) + 1
            local slots = api.personalSlots[containerID]
            return slots and slots[slotID] or nil
        end,
    }
    api.GetNumGuildBankTabs = function()
        api.calls.guildTabCount = (api.calls.guildTabCount or 0) + 1
        return api.guildTabCount
    end
    api.GetGuildBankTabInfo = function(tabID)
        api.calls.guildTabInfo = (api.calls.guildTabInfo or 0) + 1
        return api.guildTabNames[tabID], 456, true, false, 0, 0
    end
    api.GetCurrentGuildBankTab = function()
        api.calls.currentGuildTab = (api.calls.currentGuildTab or 0) + 1
        return api.currentGuildTab
    end
    api.GetGuildBankItemInfo = function(tabID, slotID)
        api.calls.guildItemInfo = (api.calls.guildItemInfo or 0) + 1
        local item = api.guildItems[tabID] and api.guildItems[tabID][slotID]
        if item then return item.icon, item.count, false, false, 1, false end
        return nil, nil, false, false, nil, false
    end
    api.GetGuildBankItemLink = function(tabID, slotID)
        api.calls.guildItemLink = (api.calls.guildItemLink or 0) + 1
        local item = api.guildItems[tabID] and api.guildItems[tabID][slotID]
        return item and item.link or nil
    end

    return api
end

local function newController(memory, api, db, onChanged)
    T.assertTrue(type(memory.CreateController) == "function")
    return assert(memory.CreateController(api, db, onChanged))
end

local function send(controller, event, ...)
    T.assertTrue(type(controller.HandleEvent) == "function")
    local ok, err = controller:HandleEvent(event, ...)
    -- Older tests model a full game update for each event. New batching
    -- regressions below call HandleEvent directly and control the flush.
    if type(controller.FlushPending) == "function" then
        controller:FlushPending()
    end
    return ok, err
end

local function queue(controller, event, ...)
    T.assertTrue(type(controller.HandleEvent) == "function")
    return controller:HandleEvent(event, ...)
end

local function inventoryFixture()
    local memory, api = loadModule(), makeAPI()
    api.NUM_BAG_SLOTS = 4
    api.personalSlots[0] = {
        [1] = { itemID = 2001, stackCount = 3, hyperlink = "item:2001", iconFileID = 99 },
    }
    api.personalSlots[1] = { [2] = { itemID = 2002, stackCount = 7 } }
    local database = assert(memory.InitializeDatabase(nil))
    return api, database, newController(memory, api, database)
end

T.test("initial combat-blocked inventory capture marks the saved character inventory incomplete", function()
    local api, db, initialController = inventoryFixture()
    send(initialController, "PLAYER_LOGIN")
    local record = db.characters["Alice-Silvermoon"]
    local inventory = assert(record.inventory)
    local capturedAt = inventory.capturedAt
    local bags = inventory.bags

    local reloadedController = newController(loadModule(), api, db)
    api.combat = true
    api.now = api.now + 10
    local ok, err = send(reloadedController, "PLAYER_LOGIN")

    T.assertFalse(ok)
    T.assertEqual(err, "combat-state-not-explicitly-false")
    T.assertEqual(inventory.status, "incomplete")
    T.assertEqual(inventory.capturedAt, capturedAt)
    T.assertEqual(inventory.bags, bags)
    T.assertEqual(inventory.bags[0].slots[1].count, 3)
end)

T.test("inventory login saves backpack and equipped bags independently of bank tabs", function()
    local api, db, controller = inventoryFixture()
    send(controller, "PLAYER_LOGIN")
    local record = assert(db.characters["Alice-Silvermoon"])
    local inventory = assert(record.inventory, "missing carried inventory")
    T.assertEqual(inventory.status, "cached")
    T.assertEqual(inventory.capturedAt, api.now)
    T.assertEqual(inventory.bags[0].slots[1].itemID, 2001)
    T.assertEqual(inventory.bags[0].slots[1].count, 3)
    T.assertEqual(inventory.bags[0].slots[1].itemLink, "item:2001")
    T.assertEqual(inventory.bags[0].slots[1].icon, 99)
    T.assertNil(inventory.bags[0].slots[2])
    T.assertEqual(inventory.bags[1].slots[2].count, 7)
    T.assertEqual(inventory.bags[4].numSlots, 0)
    T.assertNil(inventory.bags[5]) -- legacy bank container must never be carried inventory
    T.assertNil(next(record.tabs))
    T.assertNil(api.calls.canUseBank)
end)

T.test("inventory refresh clears removed items and bags while preserving bank and offline character data", function()
    local api, db, controller = inventoryFixture()
    send(controller, "BANKFRAME_OPENED")
    send(controller, "BANKFRAME_CLOSED")
    local record = db.characters["Alice-Silvermoon"]
    local bank, bankTime = record.tabs[5], record.capturedAt
    send(controller, "PLAYER_LOGIN")
    api.personalSlots[0] = {}
    api.personalSlots[1] = nil
    api.now = api.now + 10
    send(controller, "BAG_UPDATE_DELAYED")
    T.assertEqual(record.inventory.bags[0].numSlots, 2)
    T.assertNil(next(record.inventory.bags[0].slots))
    T.assertEqual(record.inventory.bags[1].numSlots, 0)
    T.assertEqual(record.inventory.capturedAt, api.now)
    T.assertEqual(record.tabs[5], bank)
    T.assertEqual(record.capturedAt, bankTime)
    T.assertEqual(record.status, "cached")
    local aliceInventory = record.inventory
    api.UnitFullName = function() return "Bob", "Silvermoon" end
    send(controller, "PLAYER_ENTERING_WORLD")
    T.assertNotNil(db.characters["Bob-Silvermoon"].inventory)
    T.assertEqual(record.inventory, aliceInventory)
    T.assertEqual(assert(loadModule().InitializeDatabase(db)), db)
end)

T.test("inventory includes modern reagent bag when the client declares equipped bag range", function()
    local api, db, controller = inventoryFixture()
    api.NUM_TOTAL_EQUIPPED_BAG_SLOTS = 5
    send(controller, "PLAYER_LOGIN")
    T.assertEqual(db.characters["Alice-Silvermoon"].inventory.bags[5].slots[1].itemID, 1001)
end)

T.test("inventory preserves last known contents on failed protected and transient empty backpack reads", function()
    for _, failure in ipairs({ "secret", "throw", "zero", "checker" }) do
        local api, db, controller = inventoryFixture()
        send(controller, "PLAYER_LOGIN")
        local inventory = assert(db.characters["Alice-Silvermoon"].inventory)
        if failure == "secret" then
            api.personalSlots[1][2].stackCount = { isSecret = true }
        elseif failure == "throw" then
            api.C_Container.GetContainerItemInfo = function() error("unavailable") end
        elseif failure == "zero" then
            api.personalSlots[0] = nil
        else
            api.issecretvalue = nil
        end
        api.now = api.now + 10
        send(controller, "BAG_UPDATE_DELAYED")
        T.assertEqual(db.characters["Alice-Silvermoon"].inventory, inventory)
        T.assertEqual(inventory.status, "incomplete")
        T.assertEqual(inventory.capturedAt, 1700000000)
        T.assertEqual(inventory.bags[0].slots[1].count, 3)
    end
end)

T.test("inventory defers combat reads and retries after combat with the bank closed", function()
    local api, db, controller = inventoryFixture()
    send(controller, "PLAYER_LOGIN")
    local reads = api.calls.personalItemInfo
    api.combat = true
    api.personalSlots[0][1].stackCount = 8
    send(controller, "BAG_UPDATE_DELAYED")
    T.assertEqual(api.calls.personalItemInfo, reads)
    T.assertEqual(db.characters["Alice-Silvermoon"].inventory.status, "incomplete")
    api.combat = false
    send(controller, "PLAYER_REGEN_ENABLED")
    T.assertEqual(db.characters["Alice-Silvermoon"].inventory.bags[0].slots[1].count, 8)
    T.assertEqual(db.characters["Alice-Silvermoon"].inventory.status, "cached")
end)

local function flush(controller)
    T.assertTrue(type(controller.FlushPending) == "function", "missing FlushPending")
    return controller:FlushPending()
end

T.test("bag update delayed refreshes inventory and batches open bank capture", function()
    local api, db, controller = inventoryFixture()
    send(controller, "PLAYER_LOGIN")
    send(controller, "BANKFRAME_OPENED")
    local record = db.characters["Alice-Silvermoon"]
    local bankCapturedAt = record.tabs[5].capturedAt
    local readsBefore = api.calls.personalItemInfo

    api.now = api.now + 10
    api.personalSlots[0][1].stackCount = 11
    queue(controller, "BAG_UPDATE_DELAYED")

    T.assertEqual(record.inventory.bags[0].slots[1].count, 3)
    T.assertEqual(api.calls.personalItemInfo, readsBefore)
    T.assertEqual(record.tabs[5].capturedAt, bankCapturedAt)

    flush(controller)
    T.assertEqual(api.calls.personalItemInfo - readsBefore, 6)
    T.assertEqual(record.inventory.bags[0].slots[1].count, 11)
    T.assertEqual(record.tabs[5].capturedAt, api.now)
end)

T.test("pending inventory refreshes when the personal bank closes before batch flush", function()
    local api, db, controller = inventoryFixture()
    send(controller, "PLAYER_LOGIN")
    send(controller, "BANKFRAME_OPENED")
    local record = db.characters["Alice-Silvermoon"]

    api.now = api.now + 10
    api.personalSlots[0][1].stackCount = 14
    queue(controller, "BAG_UPDATE_DELAYED")
    T.assertEqual(record.inventory.bags[0].slots[1].count, 3)

    queue(controller, "BANKFRAME_CLOSED")
    T.assertEqual(record.inventory.bags[0].slots[1].count, 14)
    local readsAfterClose = api.calls.personalItemInfo
    flush(controller)
    T.assertEqual(api.calls.personalItemInfo, readsAfterClose)
    T.assertEqual(record.tabs[5].status, "incomplete")
end)

T.test("bank memory initializes version one and leaves unsupported saved schemas untouched", function()
    local memory = loadModule()
    T.assertTrue(type(memory.InitializeDatabase) == "function")

    local database = assert(memory.InitializeDatabase(nil))
    T.assertEqual(database.schemaVersion, 1)
    T.assertNotNil(database.characters)
    T.assertNotNil(database.guilds)

    local unsupported = { schemaVersion = 91, characters = { preserved = true }, guilds = {} }
    local result, err = memory.InitializeDatabase(unsupported)
    T.assertNil(result)
    T.assertEqual(err, "unsupported-schema-version:91")
    T.assertEqual(unsupported.schemaVersion, 91)
    T.assertEqual(unsupported.characters.preserved, true)
end)

T.test("personal bank capture requires an open bank and an explicit out of combat result", function()
    local memory = loadModule()
    local api = makeAPI()
    local database = assert(memory.InitializeDatabase(nil))
    local controller = newController(memory, api, database)

    send(controller, "PLAYERBANKSLOTS_CHANGED", 1)
    T.assertNil(database.characters["Alice-Silvermoon"])
    T.assertNil(api.calls.personalTabData)

    api.combat = nil
    send(controller, "BANKFRAME_OPENED")
    T.assertNil(api.calls.personalTabData)
    T.assertTrue(api.calls.combatChecks > 0)

    send(controller, "PLAYER_REGEN_ENABLED")
    T.assertNil(api.calls.personalTabData)
end)

T.test("personal capture deferred during combat runs on the regeneration event if the bank stays open", function()
    local memory = loadModule()
    local api = makeAPI()
    local database = assert(memory.InitializeDatabase(nil))
    local controller = newController(memory, api, database)

    api.combat = true
    send(controller, "BANKFRAME_OPENED")
    T.assertNil(api.calls.personalTabData)

    api.combat = false
    send(controller, "PLAYER_REGEN_ENABLED")
    T.assertNotNil(database.characters["Alice-Silvermoon"])
    T.assertTrue((api.calls.personalTabData or 0) > 0)
end)

T.test("personal update blocked in combat marks known cache incomplete before close without reading bank data", function()
    local memory = loadModule()
    local api = makeAPI()
    local database = assert(memory.InitializeDatabase(nil))
    local controller = newController(memory, api, database)
    send(controller, "BANKFRAME_OPENED")
    local record = database.characters["Alice-Silvermoon"]
    local oldItemID = record.tabs[5].slots[1].itemID
    local oldCapturedAt = record.tabs[5].capturedAt
    local readCount = api.calls.personalItemInfo

    api.combat = true
    send(controller, "PLAYERBANKSLOTS_CHANGED", 1)
    T.assertEqual(record.status, "incomplete")
    T.assertEqual(record.tabs[5].status, "incomplete")
    T.assertEqual(record.tabs[5].slots[1].itemID, oldItemID)
    T.assertEqual(record.tabs[5].capturedAt, oldCapturedAt)
    T.assertEqual(api.calls.personalItemInfo, readCount)

    send(controller, "BANKFRAME_CLOSED")
    api.combat = false
    send(controller, "PLAYER_REGEN_ENABLED")
    T.assertEqual(api.calls.personalItemInfo, readCount)
end)

T.test("personal update with no secret checker marks known cache incomplete without reading bank data", function()
    local memory = loadModule()
    local api = makeAPI()
    local database = assert(memory.InitializeDatabase(nil))
    local controller = newController(memory, api, database)
    send(controller, "BANKFRAME_OPENED")
    local record = database.characters["Alice-Silvermoon"]
    local readCount = api.calls.personalItemInfo

    api.issecretvalue = nil
    send(controller, "PLAYERBANKSLOTS_CHANGED", 1)

    T.assertEqual(record.status, "incomplete")
    T.assertEqual(record.tabs[5].status, "incomplete")
    T.assertEqual(api.calls.personalItemInfo, readCount)
end)

T.test("personal capture stores observed items and empty slots under name-realm identity", function()
    local memory = loadModule()
    local api = makeAPI()
    local database = assert(memory.InitializeDatabase(nil))
    local changeCount = 0
    local controller = newController(memory, api, database, function() changeCount = changeCount + 1 end)

    send(controller, "BANKFRAME_OPENED")

    local record = assert(database.characters["Alice-Silvermoon"])
    local tab = assert(record.tabs[5])
    T.assertEqual(record.identity.key, "Alice-Silvermoon")
    T.assertEqual(record.identity.name, "Alice")
    T.assertEqual(record.identity.realm, "Silvermoon")
    T.assertEqual(record.status, "cached")
    T.assertEqual(tab.name, "Materials")
    T.assertEqual(tab.numSlots, 2)
    T.assertEqual(tab.status, "cached")
    T.assertEqual(tab.capturedAt, api.now)
    T.assertEqual(tab.slots[1].itemID, 1001)
    T.assertEqual(tab.slots[1].count, 20)
    T.assertEqual(tab.slots[1].itemLink, "|Hitem:1001|h[Ore]|h")
    T.assertEqual(tab.slots[1].icon, 123)
    T.assertNil(tab.slots[2])
    T.assertEqual(changeCount, 1)
end)

T.test("secret personal item data marks the tab incomplete and preserves the prior snapshot", function()
    local memory = loadModule()
    local api = makeAPI()
    local database = assert(memory.InitializeDatabase(nil))
    local controller = newController(memory, api, database)
    send(controller, "BANKFRAME_OPENED")

    local tab = database.characters["Alice-Silvermoon"].tabs[5]
    local originalID = tab.slots[1].itemID
    api.personalSlots[5][1] = { itemID = { isSecret = true }, stackCount = 50 }
    api.now = api.now + 20
    send(controller, "PLAYERBANKSLOTS_CHANGED", 1)

    T.assertEqual(tab.slots[1].itemID, originalID)
    T.assertEqual(tab.status, "incomplete")
    T.assertEqual(tab.capturedAt, 1700000000)
    T.assertEqual(database.characters["Alice-Silvermoon"].status, "incomplete")
end)

T.test("a failed read cannot leave the parent record cached when a saved tab is malformed", function()
    local memory = loadModule()
    local api = makeAPI()
    local database = assert(memory.InitializeDatabase(nil))
    local controller = newController(memory, api, database)
    send(controller, "BANKFRAME_OPENED")

    local record = database.characters["Alice-Silvermoon"]
    record.tabs[5].numSlots = -1
    api.personalSlots[5][1] = { itemID = { isSecret = true }, stackCount = 20 }
    send(controller, "PLAYERBANKSLOTS_CHANGED", 1)

    T.assertEqual(record.status, "incomplete")
end)

T.test("missing secret-value or combat checks fail closed before personal reads", function()
    local memory = loadModule()
    local api = makeAPI()
    local database = assert(memory.InitializeDatabase(nil))
    local controller = newController(memory, api, database)

    api.issecretvalue = nil
    send(controller, "BANKFRAME_OPENED")
    T.assertNil(api.calls.canUseBank)
    T.assertNil(database.characters["Alice-Silvermoon"])

    api.issecretvalue = makeAPI().issecretvalue
    api.InCombatLockdown = nil
    send(controller, "PLAYERBANKSLOTS_CHANGED", 1)
    T.assertNil(api.calls.canUseBank)
end)

T.test("guild open records metadata as incomplete without reading any tab contents", function()
    local memory = loadModule()
    local api = makeAPI()
    local database = assert(memory.InitializeDatabase(nil))
    local controller = newController(memory, api, database)

    send(controller, "GUILDBANKFRAME_OPENED")

    local record = assert(database.guilds["Raid Team-Silvermoon"])
    T.assertEqual(record.status, "incomplete")
    T.assertEqual(record.identity.name, "Raid Team")
    T.assertEqual(record.tabs[1].name, "Guild Tab 1")
    T.assertEqual(record.tabs[1].status, "incomplete")
    T.assertNil(record.tabs[1].capturedAt)
    T.assertEqual(record.tabs[1].numSlots, 98)
    T.assertEqual(next(record.tabs[1].slots), nil)
    T.assertEqual(record.tabs[2].status, "incomplete")
    T.assertNil(api.calls.currentGuildTab)
    T.assertNil(api.calls.guildItemInfo)
    T.assertNil(api.calls.guildItemLink)
end)

T.test("guild bank session establishment retries after a transient invalid current tab", function()
    local memory = loadModule()
    local api = makeAPI()
    api.currentGuildTab = nil
    local database = assert(memory.InitializeDatabase(nil))
    local controller = newController(memory, api, database)

    send(controller, "GUILDBANKFRAME_OPENED")
    T.assertNil(controller.guildSessionToken)
    T.assertTrue(controller.guildSessionEstablishPending)

    api.currentGuildTab = 1
    send(controller, "GUILDBANKBAGSLOTS_CHANGED")
    T.assertNotNil(controller.guildSessionToken)
    T.assertFalse(controller.guildSessionEstablishPending)
end)

T.test("guild bank session establishment retries after a transient metadata read failure", function()
    local memory = loadModule()
    local api = makeAPI()
    local getTabInfo = api.GetGuildBankTabInfo
    api.GetGuildBankTabInfo = function() error("tab metadata not ready") end
    local database = assert(memory.InitializeDatabase(nil))
    local controller = newController(memory, api, database)

    send(controller, "GUILDBANKFRAME_OPENED")
    T.assertNil(controller.guildSessionToken)
    T.assertTrue(controller.guildSessionEstablishPending)

    api.GetGuildBankTabInfo = getTabInfo
    send(controller, "GUILDBANK_UPDATE_TABS")
    T.assertNotNil(controller.guildSessionToken)
    T.assertFalse(controller.guildSessionEstablishPending)
end)

T.test("remote guild snapshots recover missing icons locally from item IDs", function()
    local memory = loadModule()
    local api = makeAPI()
    api.GetItemInfoInstant = function(itemID)
        T.assertEqual(itemID, 4001)
        return itemID, "Item", 1, 1, 98765
    end
    local database = assert(memory.InitializeDatabase(nil))
    local controller = newController(memory, api, database)
    send(controller, "GUILDBANKFRAME_OPENED")
    local context = assert(controller:GetGuildBankSyncContext())
    local snapshot = {
        id = 1, name = "Guild Tab 1", numSlots = 98, observedSlotCount = 98,
        capturedAt = api.now + 1, status = "cached",
        slots = { [1] = { itemID = 4001, itemLink = "|Hitem:4001|h[Item]|h", count = 3 } },
    }

    local merged, err = controller:MergeGuildBankSyncSnapshot(context.guildKey, context.sessionToken, 1, snapshot)

    T.assertTrue(merged)
    T.assertNil(err)
    T.assertEqual(database.guilds[context.guildKey].tabs[1].slots[1].icon, 98765)
end)

T.test("guild contents-ready captures only the current tab and timestamps each observed tab", function()
    local memory = loadModule()
    local api = makeAPI()
    api.guildItems[2] = {
        [1] = { icon = 789, count = 4, link = "|Hitem:2002:0|h[Token]|h" },
    }
    local database = assert(memory.InitializeDatabase(nil))
    local controller = newController(memory, api, database)
    send(controller, "GUILDBANKFRAME_OPENED")

    api.currentGuildTab = 2
    api.now = api.now + 15
    send(controller, "GUILDBANKBAGSLOTS_CHANGED")

    local record = database.guilds["Raid Team-Silvermoon"]
    T.assertEqual(record.tabs[1].status, "incomplete")
    T.assertNil(record.tabs[1].capturedAt)
    T.assertEqual(record.tabs[2].status, "cached")
    T.assertEqual(record.tabs[2].capturedAt, api.now)
    T.assertEqual(record.tabs[2].slots[1].itemID, 2002)
    T.assertEqual(record.tabs[2].slots[1].count, 4)
    T.assertEqual(record.tabs[2].slots[1].itemLink, "|Hitem:2002:0|h[Token]|h")
    T.assertNil(record.tabs[2].slots[2])

    api.currentGuildTab = 1
    api.now = api.now + 30
    send(controller, "GUILDBANKBAGSLOTS_CHANGED")
    T.assertEqual(record.tabs[1].status, "cached")
    T.assertEqual(record.tabs[1].capturedAt, api.now)
    T.assertEqual(record.tabs[2].capturedAt, 1700000015)
    T.assertEqual(record.status, "incomplete")
end)

T.test("guild metadata refresh keeps cached contents but marks unobserved tabs incomplete", function()
    local memory = loadModule()
    local api = makeAPI()
    api.guildItems[1] = {
        [1] = { icon = 101, count = 1, link = "|Hitem:3001|h[Gem]|h" },
    }
    local database = assert(memory.InitializeDatabase(nil))
    local controller = newController(memory, api, database)
    send(controller, "GUILDBANKFRAME_OPENED")
    send(controller, "GUILDBANKBAGSLOTS_CHANGED")
    local itemReadCount = api.calls.guildItemInfo

    api.now = api.now + 5
    send(controller, "GUILDBANK_UPDATE_TABS")

    local record = database.guilds["Raid Team-Silvermoon"]
    T.assertEqual(record.tabs[1].status, "incomplete")
    T.assertEqual(record.tabs[1].slots[1].itemID, 3001)
    T.assertEqual(record.tabs[1].capturedAt, 1700000000)
    T.assertEqual(record.tabs[2].status, "incomplete")
    T.assertEqual(api.calls.guildItemInfo, itemReadCount)
end)

T.test("guild snapshots remain isolated by guild name and realm", function()
    local memory = loadModule()
    local api = makeAPI()
    local database = assert(memory.InitializeDatabase(nil))
    local controller = newController(memory, api, database)
    send(controller, "GUILDBANKFRAME_OPENED")
    send(controller, "GUILDBANKBAGSLOTS_CHANGED")
    send(controller, "GUILDBANKFRAME_CLOSED")

    api.guildName = "Second Guild"
    api.now = api.now + 1
    send(controller, "GUILDBANKFRAME_OPENED")
    send(controller, "GUILDBANKBAGSLOTS_CHANGED")

    T.assertNotNil(database.guilds["Raid Team-Silvermoon"])
    T.assertNotNil(database.guilds["Second Guild-Silvermoon"])
    T.assertEqual(database.guilds["Raid Team-Silvermoon"].identity.name, "Raid Team")
    T.assertEqual(database.guilds["Second Guild-Silvermoon"].identity.name, "Second Guild")
end)

T.test("guild identity uses the safe guild realm returned by GetGuildInfo", function()
    local memory = loadModule()
    local api = makeAPI()
    api.guildRealm = "Connected Realm"
    local database = assert(memory.InitializeDatabase(nil))
    local controller = newController(memory, api, database)

    send(controller, "GUILDBANKFRAME_OPENED")

    local record = assert(database.guilds["Raid Team-Connected Realm"])
    T.assertEqual(record.identity.realm, "Connected Realm")
end)

T.test("guild data is not read during combat and awaits a fresh contents-ready event", function()
    local memory = loadModule()
    local api = makeAPI()
    local database = assert(memory.InitializeDatabase(nil))
    local controller = newController(memory, api, database)
    send(controller, "GUILDBANKFRAME_OPENED")
    api.guildItems[1] = {
        [1] = { icon = 101, count = 1, link = "|Hitem:3001|h[Gem]|h" },
    }
    send(controller, "GUILDBANKBAGSLOTS_CHANGED")
    local itemReadCount = api.calls.guildItemInfo
    local currentTabReadCount = api.calls.currentGuildTab

    api.combat = true
    send(controller, "GUILDBANKBAGSLOTS_CHANGED")
    T.assertEqual(api.calls.currentGuildTab, currentTabReadCount)
    T.assertEqual(api.calls.guildItemInfo, itemReadCount)

    api.combat = false
    send(controller, "PLAYER_REGEN_ENABLED")
    T.assertEqual(api.calls.currentGuildTab, currentTabReadCount)
    T.assertEqual(api.calls.guildItemInfo, itemReadCount)
    T.assertEqual(database.guilds["Raid Team-Silvermoon"].tabs[1].status, "incomplete")
    T.assertEqual(database.guilds["Raid Team-Silvermoon"].tabs[1].slots[1].itemID, 3001)

    send(controller, "GUILDBANKBAGSLOTS_CHANGED")
    T.assertTrue((api.calls.guildItemInfo or 0) > 0)
    T.assertEqual(database.guilds["Raid Team-Silvermoon"].tabs[1].status, "cached")
end)

T.test("guild update blocked in combat marks known tabs incomplete before close without reading them", function()
    local memory = loadModule()
    local api = makeAPI()
    api.guildItems[1] = {
        [1] = { icon = 101, count = 1, link = "|Hitem:3001|h[Gem]|h" },
    }
    local database = assert(memory.InitializeDatabase(nil))
    local controller = newController(memory, api, database)
    send(controller, "GUILDBANKFRAME_OPENED")
    send(controller, "GUILDBANKBAGSLOTS_CHANGED")
    local record = database.guilds["Raid Team-Silvermoon"]
    local oldCapturedAt = record.tabs[1].capturedAt
    local oldItemID = record.tabs[1].slots[1].itemID
    local itemReadCount = api.calls.guildItemInfo
    local linkReadCount = api.calls.guildItemLink

    api.combat = true
    send(controller, "GUILDBANKBAGSLOTS_CHANGED")
    T.assertEqual(record.status, "incomplete")
    T.assertEqual(record.tabs[1].status, "incomplete")
    T.assertEqual(record.tabs[1].slots[1].itemID, oldItemID)
    T.assertEqual(record.tabs[1].capturedAt, oldCapturedAt)
    T.assertEqual(api.calls.guildItemInfo, itemReadCount)
    T.assertEqual(api.calls.guildItemLink, linkReadCount)

    send(controller, "GUILDBANKFRAME_CLOSED")
    api.combat = false
    send(controller, "PLAYER_REGEN_ENABLED")
    T.assertEqual(api.calls.guildItemInfo, itemReadCount)
    T.assertEqual(api.calls.guildItemLink, linkReadCount)
end)

T.test("closed bank events and late combat callbacks do not capture contents", function()
    local memory = loadModule()
    local api = makeAPI()
    local database = assert(memory.InitializeDatabase(nil))
    local controller = newController(memory, api, database)

    send(controller, "BANKFRAME_OPENED")
    local personalItemReadCount = api.calls.personalItemInfo
    send(controller, "BANKFRAME_CLOSED")
    send(controller, "PLAYERBANKSLOTS_CHANGED", 1)
    send(controller, "PLAYER_REGEN_ENABLED")
    T.assertEqual(api.calls.personalItemInfo, personalItemReadCount)

    send(controller, "GUILDBANKFRAME_OPENED")
    send(controller, "GUILDBANKFRAME_CLOSED")
    send(controller, "GUILDBANKBAGSLOTS_CHANGED")
    T.assertNil(api.calls.guildItemInfo)
end)

local function sixTabAPI()
    local api = makeAPI()
    api.personalTabs, api.personalSlots = {}, {}
    api.personalNumSlotsOverride = 98
    for id = 1, 6 do
        api.personalTabs[id] = { ID = id, name = "Tab " .. id }
        api.personalSlots[id] = { [1] = { itemID = 1000 + id, stackCount = 1 } }
    end
    return api
end

T.test("personal three-event six-tab probe captures one full batch and notification", function()
    local memory, api = loadModule(), sixTabAPI()
    local database = assert(memory.InitializeDatabase(nil))
    local changes = 0
    local controller = newController(memory, api, database, function() changes = changes + 1 end)
    queue(controller, "BANKFRAME_OPENED")
    local readsBefore, changesBefore = api.calls.personalItemInfo, changes
    local metadataBefore = api.calls.personalTabData
    queue(controller, "PLAYERBANKSLOTS_CHANGED", 1)
    queue(controller, "BAG_UPDATE", 1)
    queue(controller, "BAG_UPDATE_DELAYED")
    T.assertEqual(api.calls.personalItemInfo, readsBefore)
    flush(controller)
    T.assertEqual(api.calls.personalItemInfo - readsBefore, 98 * 11)
    T.assertEqual(api.calls.personalTabData - metadataBefore, 1)
    T.assertEqual(changes - changesBefore, 1)
end)

T.test("known personal tab burst reads 98 slots and leaves other capture times untouched", function()
    local memory, api = loadModule(), sixTabAPI()
    local database = assert(memory.InitializeDatabase(nil))
    local changes = 0
    local controller = newController(memory, api, database, function() changes = changes + 1 end)
    queue(controller, "BANKFRAME_OPENED")
    local record = database.characters["Alice-Silvermoon"]
    local oldTab, oldTime = record.tabs[1], api.now
    api.now = api.now + 20
    local readsBefore, changesBefore = api.calls.personalItemInfo, changes
    for _ = 1, 3 do queue(controller, "BAG_UPDATE", 5) end
    flush(controller)
    T.assertEqual(api.calls.personalItemInfo - readsBefore, 98)
    T.assertEqual(changes - changesBefore, 1)
    T.assertTrue(record.tabs[1] == oldTab)
    T.assertEqual(record.tabs[1].capturedAt, oldTime)
    T.assertEqual(record.tabs[5].capturedAt, api.now)
    T.assertEqual(record.status, "cached")
end)

T.test("multiple personal dirty IDs are deduplicated within a batch", function()
    local memory, api = loadModule(), sixTabAPI()
    local database = assert(memory.InitializeDatabase(nil))
    local controller = newController(memory, api, database)
    queue(controller, "BANKFRAME_OPENED")
    local readsBefore = api.calls.personalItemInfo
    queue(controller, "BAG_UPDATE", 1)
    queue(controller, "BAG_UPDATE", 5)
    queue(controller, "BAG_UPDATE", 1)
    flush(controller)
    T.assertEqual(api.calls.personalItemInfo - readsBefore, 196)
end)

T.test("ambiguous personal event dominates known updates in either order", function()
    for _, ambiguousFirst in ipairs({ true, false }) do
        local memory, api = loadModule(), sixTabAPI()
        local database = assert(memory.InitializeDatabase(nil))
        local controller = newController(memory, api, database)
        queue(controller, "BANKFRAME_OPENED")
        local readsBefore = api.calls.personalItemInfo
        if ambiguousFirst then queue(controller, "BAG_UPDATE_DELAYED") end
        queue(controller, "BAG_UPDATE", 1)
        if not ambiguousFirst then queue(controller, "BAG_UPDATE_DELAYED") end
        flush(controller)
        T.assertEqual(api.calls.personalItemInfo - readsBefore, 98 * 11)
    end
end)

T.test("closing or reopening personal bank cancels queued captures", function()
    local memory = loadModule()
    local api = makeAPI()
    local database = assert(memory.InitializeDatabase(nil))
    local controller = newController(memory, api, database)
    queue(controller, "BANKFRAME_OPENED")
    queue(controller, "BAG_UPDATE", 5)
    queue(controller, "BANKFRAME_CLOSED")
    local readsBefore = api.calls.personalItemInfo
    flush(controller)
    T.assertEqual(api.calls.personalItemInfo, readsBefore)

    queue(controller, "BANKFRAME_OPENED")
    queue(controller, "BAG_UPDATE", 5)
    queue(controller, "BANKFRAME_OPENED")
    readsBefore = api.calls.personalItemInfo
    flush(controller)
    T.assertEqual(api.calls.personalItemInfo, readsBefore)
end)

T.test("guild ready burst captures the ready current tab once with one notification", function()
    local memory = loadModule()
    local api = makeAPI()
    local database = assert(memory.InitializeDatabase(nil))
    local changes = 0
    local controller = newController(memory, api, database, function() changes = changes + 1 end)
    queue(controller, "GUILDBANKFRAME_OPENED")
    local readsBefore = api.calls.guildItemInfo or 0
    local changesBefore = changes
    for _ = 1, 3 do queue(controller, "GUILDBANKBAGSLOTS_CHANGED") end
    flush(controller)
    T.assertEqual((api.calls.guildItemInfo or 0) - readsBefore, 98)
    T.assertEqual(changes - changesBefore, 1)
    local record = database.guilds["Raid Team-Silvermoon"]
    T.assertEqual(record.tabs[1].status, "cached")
    T.assertEqual(record.tabs[2].status, "incomplete")
end)

T.test("guild ready batch is discarded when selection changes before flush", function()
    local memory = loadModule()
    local api = makeAPI()
    local database = assert(memory.InitializeDatabase(nil))
    local controller = newController(memory, api, database)
    queue(controller, "GUILDBANKFRAME_OPENED")
    local itemReads = api.calls.guildItemInfo or 0
    queue(controller, "GUILDBANKBAGSLOTS_CHANGED")
    api.currentGuildTab = 2
    flush(controller)
    T.assertEqual(api.calls.guildItemInfo or 0, itemReads)
    local record = database.guilds["Raid Team-Silvermoon"]
    T.assertEqual(record.tabs[1].status, "incomplete")
    T.assertEqual(record.tabs[2].status, "incomplete")
end)

T.test("CancelPending discards queued work and preserves the saved snapshot as incomplete", function()
    local memory = loadModule()
    local api = makeAPI()
    local database = assert(memory.InitializeDatabase(nil))
    local controller = newController(memory, api, database)
    send(controller, "BANKFRAME_OPENED")
    local record = database.characters["Alice-Silvermoon"]
    local originalItem = record.tabs[5].slots[1].itemID
    queue(controller, "BAG_UPDATE", 5)
    T.assertTrue(type(controller.CancelPending) == "function", "missing CancelPending")
    controller:CancelPending()
    local reads = api.calls.personalItemInfo
    flush(controller)
    T.assertEqual(api.calls.personalItemInfo, reads)
    T.assertEqual(record.status, "incomplete")
    T.assertEqual(record.tabs[5].status, "incomplete")
    T.assertEqual(record.tabs[5].slots[1].itemID, originalItem)
end)

T.test("personal update entering combat before flush marks incomplete without reading", function()
    local memory = loadModule()
    local api = makeAPI()
    local database = assert(memory.InitializeDatabase(nil))
    local controller = newController(memory, api, database)
    send(controller, "BANKFRAME_OPENED")
    local record = database.characters["Alice-Silvermoon"]
    local reads = api.calls.personalItemInfo
    queue(controller, "BAG_UPDATE", 5)
    api.combat = true
    flush(controller)
    T.assertEqual(api.calls.personalItemInfo, reads)
    T.assertEqual(record.status, "incomplete")
    T.assertEqual(record.tabs[5].status, "incomplete")
    api.combat = false
    queue(controller, "PLAYER_REGEN_ENABLED")
    flush(controller)
    T.assertTrue(api.calls.personalItemInfo > reads)
end)

T.test("guild combat readiness requires a fresh ready event after regeneration", function()
    local memory = loadModule()
    local api = makeAPI()
    local database = assert(memory.InitializeDatabase(nil))
    local controller = newController(memory, api, database)
    queue(controller, "GUILDBANKFRAME_OPENED")
    api.combat = true
    queue(controller, "GUILDBANKBAGSLOTS_CHANGED")
    local readsBefore = api.calls.guildItemInfo or 0
    api.combat = false
    queue(controller, "PLAYER_REGEN_ENABLED")
    flush(controller)
    T.assertEqual(api.calls.guildItemInfo or 0, readsBefore)
    queue(controller, "GUILDBANKBAGSLOTS_CHANGED")
    flush(controller)
    T.assertEqual((api.calls.guildItemInfo or 0) - readsBefore, 98)
end)

T.test("main controller registers bank lifecycle and contents update events", function()
    local memory = loadModule()
    local api = makeAPI()
    local registered = {}
    local handler
    api._G = api
    api["The Guild Book Bank"] = memory
    setmetatable(api, { __index = _G })
    api.CreateFrame = function()
        return {
            RegisterEvent = function(_, event) registered[event] = true end,
            SetScript = function(_, script, callback)
                if script == "OnEvent" then handler = callback end
            end,
        }
    end
    local chunk = loadfile("The Guild Book Bank/Main.lua")
    if chunk then
        if setfenv then
            setfenv(chunk, api)
        elseif debug and debug.setupvalue then
            debug.setupvalue(chunk, 1, api)
        end
        chunk("The Guild Book Bank", memory)
    end

    T.assertNotNil(handler)
    for _, event in ipairs({
        "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "BANKFRAME_OPENED", "BANKFRAME_CLOSED",
        "PLAYERBANKSLOTS_CHANGED",
        "BANK_TABS_CHANGED", "BANK_TAB_SETTINGS_UPDATED",
        "GUILDBANKFRAME_OPENED", "GUILDBANKFRAME_CLOSED",
        "GUILDBANK_UPDATE_TABS", "GUILDBANKBAGSLOTS_CHANGED",
        "PLAYER_REGEN_ENABLED",
    }) do
        T.assertTrue(registered[event] == true, "missing registered event " .. event)
    end

    handler(nil, "ADDON_LOADED", "The Guild Book Bank")
    T.assertEqual(api.TheGuildBookBankDB.schemaVersion, 1)
    T.assertEqual(api.DysbankMemoryAPI.schemaVersion, 1)
    T.assertTrue(type(api.DysbankMemoryAPI.GetDatabase) == "function")
end)

T.test("personal combat recovery shares a queued update batch", function()
    local memory, api = loadModule(), sixTabAPI()
    local database = assert(memory.InitializeDatabase(nil))
    local changes = 0
    local controller = newController(memory, api, database, function() changes = changes + 1 end)
    send(controller, "BANKFRAME_OPENED")
    api.combat = true
    queue(controller, "BAG_UPDATE", 5)
    api.combat = false
    local reads, previousChanges = api.calls.personalItemInfo, changes
    queue(controller, "BAG_UPDATE", 5)
    queue(controller, "PLAYER_REGEN_ENABLED")
    T.assertEqual(api.calls.personalItemInfo, reads)
    flush(controller)
    T.assertEqual(api.calls.personalItemInfo - reads, 588)
    T.assertEqual(changes - previousChanges, 1)
end)

T.test("database replacement cancels reads and marks the old pending snapshot incomplete", function()
    local memory, api = loadModule(), makeAPI()
    local database = assert(memory.InitializeDatabase(nil))
    local controller = newController(memory, api, database)
    send(controller, "BANKFRAME_OPENED")
    queue(controller, "BAG_UPDATE", 5)
    local reads = api.calls.personalItemInfo
    controller.database = assert(memory.InitializeDatabase(nil))
    flush(controller)
    T.assertEqual(api.calls.personalItemInfo, reads)
    T.assertEqual(database.characters["Alice-Silvermoon"].status, "incomplete")
    T.assertNil(controller.database.characters["Alice-Silvermoon"])
end)
