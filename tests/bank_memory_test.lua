local T = require("tests.testlib")

local function loadModule()
    local memory = {}
    local chunk = loadfile("DysbankMemory/BankMemory.lua")
    if chunk then
        chunk("DysbankMemory", memory)
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
    return controller:HandleEvent(event, ...)
end

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

T.test("main controller registers bank lifecycle and contents update events", function()
    local memory = loadModule()
    local api = makeAPI()
    local registered = {}
    local handler
    api._G = api
    api.DysbankMemory = memory
    setmetatable(api, { __index = _G })
    api.CreateFrame = function()
        return {
            RegisterEvent = function(_, event) registered[event] = true end,
            SetScript = function(_, script, callback)
                if script == "OnEvent" then handler = callback end
            end,
        }
    end
    local chunk = loadfile("DysbankMemory/Main.lua")
    if chunk then
        if setfenv then
            setfenv(chunk, api)
        elseif debug and debug.setupvalue then
            debug.setupvalue(chunk, 1, api)
        end
        chunk("DysbankMemory", memory)
    end

    T.assertNotNil(handler)
    for _, event in ipairs({
        "ADDON_LOADED", "BANKFRAME_OPENED", "BANKFRAME_CLOSED",
        "PLAYERBANKSLOTS_CHANGED",
        "BANK_TABS_CHANGED", "BANK_TAB_SETTINGS_UPDATED",
        "GUILDBANKFRAME_OPENED", "GUILDBANKFRAME_CLOSED",
        "GUILDBANK_UPDATE_TABS", "GUILDBANKBAGSLOTS_CHANGED",
        "PLAYER_REGEN_ENABLED",
    }) do
        T.assertTrue(registered[event] == true, "missing registered event " .. event)
    end

    handler(nil, "ADDON_LOADED", "DysbankMemory")
    T.assertEqual(api.DysbankMemoryDB.schemaVersion, 1)
    T.assertEqual(api.DysbankMemoryAPI.schemaVersion, 1)
    T.assertTrue(type(api.DysbankMemoryAPI.GetDatabase) == "function")
end)
