local T = require("tests.testlib")

local function setChunkEnv(chunk, env)
    if setfenv then
        setfenv(chunk, env)
    elseif debug and debug.setupvalue then
        debug.setupvalue(chunk, 1, env)
    end
end

local function fixture(saved)
    local frame = { events = {}, scripts = {} }
    function frame:RegisterEvent(event) self.events[event] = true end
    function frame:SetScript(name, callback) self.scripts[name] = callback end
    local reads, changes = 0, 0
    local api = setmetatable({
        TheGuildBookBankDB = saved,
        CreateFrame = function() return frame end,
        issecretvalue = function() return false end,
        InCombatLockdown = function() return false end,
        time = function() return 100 end,
        UnitFullName = function() return "Alice", "Silvermoon" end,
        GetRealmName = function() return "Silvermoon" end,
        Enum = { BankType = { Character = 0 } },
        C_Bank = {
            CanUseBank = function() return true end,
            FetchPurchasedBankTabData = function() return {{ ID = 6, name = "Materials" }} end,
        },
        C_Container = {
            GetContainerNumSlots = function() return 2 end,
            GetContainerItemInfo = function(_, slot)
                reads = reads + 1
                if slot == 1 then
                    return { itemID = 1001, hyperlink = "|Hitem:1001|h[Ore]|h", iconFileID = 123, stackCount = 8 }
                end
            end,
        },
        GuildGearMemoryBankChanged = function() changes = changes + 1 end,
    }, { __index = _G })
    api._G = api
    local memory, GGM = {}, {}
    local function load(path, name, namespace)
        local chunk = assert(loadfile(path))
        setChunkEnv(chunk, api)
        chunk(name, namespace)
    end
    load("The Guild Book Bank/BankMemory.lua", "The Guild Book Bank", memory)
    load("The Guild Book Bank/Main.lua", "The Guild Book Bank", memory)
    load("The Guild Book/Constants.lua", "The Guild Book", GGM)
    load("The Guild Book/BankView.lua", "The Guild Book", GGM)
    return api, frame, GGM, function() return reads, changes end
end

T.test("companion captures bank on open and carried inventory with bank closed in the same SavedVariables", function()
    local saved = { schemaVersion = 1, characters = {}, guilds = {} }
    local api, frame, GGM, counts = fixture(saved)
    local event = assert(frame.scripts.OnEvent)
    event(frame, "ADDON_LOADED", "The Guild Book")
    T.assertEqual(counts(), 0)
    event(frame, "ADDON_LOADED", "The Guild Book Bank")
    T.assertTrue(api.TheGuildBookBankDB == saved)
    T.assertEqual(api.DysbankMemoryAPI.schemaVersion, 1)
    local initialReads, initialChanges = counts()
    T.assertEqual(initialReads, 0)
    event(frame, "BANKFRAME_OPENED")
    local reads, changes = counts()
    T.assertEqual(reads, 2)
    T.assertEqual(changes, initialChanges + 1)
    local entries = GGM.BuildBankEntries({ schemaVersion = GGM.SCHEMA_VERSION, characters = {} }, saved)
    T.assertEqual(#entries, 2)
    T.assertEqual(entries[1].label, "Guild Bank")
    T.assertEqual(entries[2].key, "Alice-Silvermoon")
    local detail = GGM.BuildBankDetail(entries[2], api)
    T.assertTrue(detail.hasRecord)
    T.assertEqual(detail.tabs[1].slots[1].itemID, 1001)
    T.assertEqual(detail.tabs[1].slots[1].count, 8)
    T.assertTrue(detail.tabs[1].slots[2].empty)
    event(frame, "BANKFRAME_CLOSED")
    local bank = saved.characters["Alice-Silvermoon"].tabs[6]
    event(frame, "BAG_UPDATE_DELAYED")
    T.assertTrue(counts() > reads)
    T.assertEqual(saved.characters["Alice-Silvermoon"].tabs[6], bank)
    local inventory = assert(saved.characters["Alice-Silvermoon"].inventory)
    T.assertEqual(inventory.bags[0].slots[1].count, 8)
    T.assertEqual(inventory.status, "cached")
    T.assertNil(inventory.bags[6])
    local reloaded, reloadFrame = fixture(saved)
    reloadFrame.scripts.OnEvent(reloadFrame, "ADDON_LOADED", "The Guild Book Bank")
    T.assertEqual(reloaded.TheGuildBookBankDB.characters["Alice-Silvermoon"].inventory, inventory)
end)

T.test("companion login routes carried inventory capture without opening a bank", function()
    local api, frame = fixture(nil)
    local event = frame.scripts.OnEvent
    event(frame, "ADDON_LOADED", "The Guild Book Bank")
    event(frame, "PLAYER_LOGIN")
    local record = assert(api.TheGuildBookBankDB.characters["Alice-Silvermoon"])
    T.assertNotNil(record.inventory)
    T.assertNil(next(record.tabs))
    T.assertNil(record.capturedAt)
end)

T.test("main installs OnUpdate only for pending work and batches bank event bursts", function()
    local saved = { schemaVersion = 1, characters = {}, guilds = {} }
    local api, frame, _, counts = fixture(saved)
    local event = assert(frame.scripts.OnEvent)
    event(frame, "ADDON_LOADED", "The Guild Book Bank")
    T.assertNil(frame.scripts.OnUpdate)

    event(frame, "BANKFRAME_OPENED")
    local readsBefore = counts()
    local changesBefore = select(2, counts())
    T.assertNil(frame.scripts.OnUpdate)
    event(frame, "BAG_UPDATE", 6)
    event(frame, "BAG_UPDATE", 6)
    event(frame, "BAG_UPDATE_DELAYED")
    T.assertEqual(counts(), readsBefore)
    local update = assert(frame.scripts.OnUpdate, "pending work did not install OnUpdate")
    update(frame, 0)
    T.assertEqual(counts(), readsBefore + 12)
    T.assertEqual(select(2, counts()), changesBefore + 1)
    T.assertNil(frame.scripts.OnUpdate)
end)

T.test("closing the bank removes pending OnUpdate work without another capture", function()
    local saved = { schemaVersion = 1, characters = {}, guilds = {} }
    local api, frame, _, counts = fixture(saved)
    local event = assert(frame.scripts.OnEvent)
    event(frame, "ADDON_LOADED", "The Guild Book Bank")
    event(frame, "BANKFRAME_OPENED")
    event(frame, "BAG_UPDATE", 6)
    local staleUpdate = assert(frame.scripts.OnUpdate)
    local readsBeforeClose = counts()
    event(frame, "BANKFRAME_CLOSED")
    T.assertNil(frame.scripts.OnUpdate)
    staleUpdate(frame, 0)
    T.assertEqual(counts(), readsBeforeClose)
    T.assertEqual(saved.characters["Alice-Silvermoon"].status, "incomplete")
    event(frame, "BANKFRAME_OPENED")
    event(frame, "BAG_UPDATE", 6)
    local currentUpdate = assert(frame.scripts.OnUpdate)
    local readsAfterOpen = counts()
    staleUpdate(frame, 0)
    T.assertEqual(counts(), readsAfterOpen)
    T.assertTrue(frame.scripts.OnUpdate == currentUpdate)
    currentUpdate(frame, 0)
    T.assertEqual(counts(), readsAfterOpen + 2)
end)

T.test("replacing the controller cancels the old pending batch", function()
    local saved = { schemaVersion = 1, characters = {}, guilds = {} }
    local api, frame, _, counts = fixture(saved)
    local event = assert(frame.scripts.OnEvent)
    event(frame, "ADDON_LOADED", "The Guild Book Bank")
    event(frame, "BANKFRAME_OPENED")
    event(frame, "BAG_UPDATE", 6)
    local staleUpdate = assert(frame.scripts.OnUpdate)
    local readsBeforeReplace = counts()

    event(frame, "ADDON_LOADED", "The Guild Book Bank")
    T.assertNil(frame.scripts.OnUpdate)
    staleUpdate(frame, 0)
    T.assertEqual(counts(), readsBeforeReplace)
    T.assertEqual(saved.characters["Alice-Silvermoon"].status, "incomplete")
    event(frame, "BANKFRAME_OPENED")
    event(frame, "BAG_UPDATE", 6)
    local currentUpdate = assert(frame.scripts.OnUpdate)
    local readsAfterOpen = counts()
    staleUpdate(frame, 0)
    T.assertEqual(counts(), readsAfterOpen)
    T.assertTrue(frame.scripts.OnUpdate == currentUpdate)
    currentUpdate(frame, 0)
    T.assertEqual(counts(), readsAfterOpen + 2)
end)

T.test("companion entrypoint preserves unsupported SavedVariables and does no capture", function()
    local saved = { schemaVersion = 99, characters = { preserved = true }, guilds = {} }
    local api, frame, _, counts = fixture(saved)
    frame.scripts.OnEvent(frame, "ADDON_LOADED", "The Guild Book Bank")
    frame.scripts.OnEvent(frame, "BANKFRAME_OPENED")
    T.assertTrue(api.TheGuildBookBankDB == saved)
    T.assertEqual(saved.characters.preserved, true)
    T.assertEqual(counts(), 0)
end)

T.test("reloaded bank snapshot displays a named quality color link while the bank is closed", function()
    local link = "|cnIQ2:|Hitem:170617::::::::11:105::105:1:13572:2:9:11:28:2852:::::|h[Springrain Spear]|h|r"
    local record = {
        status = "cached", capturedAt = 1791558481,
        identity = { key = "Dysheal-Stormscale", name = "Dysheal", realm = "Stormscale" },
        tabs = {
            [6] = {
                id = 6, name = "Tab 1", numSlots = 98,
                status = "cached", capturedAt = 1791558481,
                slots = { [47] = { itemLink = link, itemID = 170617, count = 1, icon = 655715 } },
            },
        },
    }
    local saved = { schemaVersion = 1, characters = { [record.identity.key] = record }, guilds = {} }
    local api, frame, GGM, counts = fixture(saved)
    api.C_Bank.CanUseBank = function() return false end
    api.C_Bank.FetchPurchasedBankTabData = function() return {} end
    frame.scripts.OnEvent(frame, "ADDON_LOADED", "The Guild Book Bank")

    local entries = GGM.BuildBankEntries(nil, saved)
    T.assertTrue(entries[2].record == record, "valid saved bank record was discarded")
    local detail = GGM.BuildBankDetail(entries[2], api)
    T.assertTrue(detail.hasRecord)
    T.assertEqual(detail.completenessText, "Cached")
    T.assertEqual(detail.selectedTabID, 6)
    T.assertEqual(#detail.slots, 98)
    T.assertEqual(detail.slots[47].itemID, 170617)
    T.assertEqual(detail.slots[47].itemLink, link)
    T.assertEqual(detail.slots[47].count, 1)
    T.assertEqual(counts(), 0)
    T.assertTrue(api.TheGuildBookBankDB == saved)
end)

T.test("bank addon manifests declare optional companion and independent SavedVariables", function()
    local companion = assert(io.open("The Guild Book Bank/The Guild Book Bank.toc", "r")):read("*a")
    local main = assert(io.open("The Guild Book/The Guild Book.toc", "r")):read("*a")
    T.assertTrue(companion:find("## SavedVariables: TheGuildBookBankDB", 1, true) ~= nil)
    T.assertTrue(main:find("## OptionalDeps: The Guild Book Bank, The Guild Book gear", 1, true) ~= nil)
    T.assertTrue(companion:find("BankMemory.lua", 1, true) < companion:find("Main.lua", 1, true))
    T.assertTrue(main:find("BankView.lua", 1, true) < main:find("BankUI.lua", 1, true))
    T.assertTrue(main:find("BankUI.lua", 1, true) < main:find("SnapshotTestUI.lua", 1, true))
end)
