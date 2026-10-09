local T = require("tests.testlib")
local GGM = {}
T.loadAddonFile("GuildGearMemory/Constants.lua", GGM)
local bankViewChunk = loadfile("GuildGearMemory/BankView.lua")
if bankViewChunk then bankViewChunk("GuildGearMemory", GGM) end

local function characterRecord(name, realm, status, capturedAt)
    local key = name .. "-" .. realm
    return {
        identity = { key = key, name = name, realm = realm },
        capturedAt = capturedAt or 1700000000,
        status = status or "cached",
        tabs = {
            [1] = {
                id = 1, name = "Main Bank", numSlots = 2, capturedAt = 1700000000,
                status = "cached", slots = {
                    [1] = { itemID = 19019, itemLink = "|Hitem:19019|h[Thunderfury]|h", icon = 134, count = 1 },
                },
            },
            [2] = {
                id = 2, name = "Materials", numSlots = 1, capturedAt = 1700000100,
                status = "incomplete", slots = {},
            },
        },
    }
end

local function bankDB()
    local member = characterRecord("Alice", "Silvermoon")
    local guild = characterRecord("Testers", "Silvermoon")
    return {
        schemaVersion = 1,
        characters = { [member.identity.key] = member },
        guilds = { [guild.identity.key] = guild },
    }, member, guild
end

T.test("bank entries put Guild Bank first and include the current guild record only", function()
    local companionDB, member, currentGuild = bankDB()
    local otherGuild = characterRecord("OtherGuild", "Silvermoon")
    companionDB.guilds[otherGuild.identity.key] = otherGuild
    local entries = GGM.BuildBankEntries({ schemaVersion = GGM.SCHEMA_VERSION, characters = {} }, companionDB,
        { key = currentGuild.identity.key, name = "Testers", realm = "Silvermoon" })

    T.assertEqual(entries[1].kind, "guild")
    T.assertEqual(entries[1].label, "Guild Bank")
    T.assertTrue(entries[1].record == currentGuild)
    T.assertEqual(#entries, 2)
    T.assertEqual(entries[2].key, member.identity.key)
    T.assertNil(entries[3])
end)

T.test("bank entries union and deduplicate valid GGM and companion characters", function()
    local companionDB, member = bankDB()
    local ggmOnly = { identity = { key = "Beatrice-ArgentDawn", name = "Beatrice", realm = "ArgentDawn" } }
    local ggmMember = { identity = { key = member.identity.key, name = "Alice", realm = "Silvermoon" } }
    local entries = GGM.BuildBankEntries({ schemaVersion = GGM.SCHEMA_VERSION, characters = {
        [ggmOnly.identity.key] = ggmOnly, [member.identity.key] = ggmMember,
    } }, companionDB, nil)

    T.assertEqual(#entries, 3)
    T.assertEqual(entries[1].kind, "guild")
    T.assertEqual(entries[2].key, "Alice-Silvermoon")
    T.assertEqual(entries[3].key, "Beatrice-ArgentDawn")
    T.assertTrue(entries[2].record == member)
    T.assertNil(entries[3].record)
end)

T.test("bank detail validates tabs and distinguishes cached empty slots from failed tabs", function()
    local companionDB, member = bankDB()
    local entries = GGM.BuildBankEntries({ schemaVersion = GGM.SCHEMA_VERSION, characters = {} }, companionDB, nil)
    local detail = GGM.BuildBankDetail(entries[2], { date = function(_, stamp) return "time:" .. stamp end })

    T.assertTrue(detail.hasRecord)
    T.assertEqual(detail.capturedAtText, "time:1700000000")
    T.assertEqual(detail.completenessText, "Incomplete")
    T.assertEqual(#detail.tabs, 2)
    T.assertEqual(detail.tabs[1].id, 1)
    T.assertEqual(detail.tabs[2].status, "incomplete")
    T.assertEqual(entries[2].status, "incomplete", "mixed tab coverage must not be summarized as cached")
    T.assertEqual(detail.selectedTabID, 1)
    T.assertEqual(#detail.slots, 2)
    T.assertEqual(detail.slots[1].itemLink, "|Hitem:19019|h[Thunderfury]|h")
    T.assertTrue(detail.slots[2].empty)
    T.assertTrue(detail.slots[2].observed)
    T.assertTrue(member == entries[2].record)
end)

T.test("bank view never infers empty slots from an unobserved tab timestamp", function()
    local companionDB, member = bankDB()
    member.tabs[1].capturedAt = nil
    member.tabs[1].status = "incomplete"
    member.capturedAt = member.tabs[2].capturedAt
    local entries = GGM.BuildBankEntries({ schemaVersion = GGM.SCHEMA_VERSION, characters = {} }, companionDB, nil)
    local detail = GGM.BuildBankDetail(entries[2], {})

    T.assertTrue(detail.hasRecord)
    T.assertEqual(detail.completenessText, "Incomplete")
    T.assertFalse(detail.slots[1].observed)
    T.assertFalse(detail.slots[1].empty)
    T.assertEqual(detail.slots[1].statusText, "Not observed")
end)

T.test("cached bank snapshots require an observation timestamp", function()
    local companionDB, member = bankDB()
    member.capturedAt = nil
    local entries = GGM.BuildBankEntries({ schemaVersion = GGM.SCHEMA_VERSION, characters = {} }, companionDB, nil)

    T.assertNil(entries[2].record)
end)

T.test("cached tabs require their own observation time and cached records match an observed tab", function()
    local companionDB, member = bankDB()
    member.tabs[1].capturedAt = nil
    member.tabs[2].status = "unavailable"
    member.tabs[2].capturedAt = nil
    local entries = GGM.BuildBankEntries({ schemaVersion = GGM.SCHEMA_VERSION, characters = {} }, companionDB, nil)
    T.assertNil(entries[2].record, "a tab marked cached without a timestamp is malformed")

    member.tabs[1].capturedAt = 1700000000
    member.tabs[2].status = "incomplete"
    member.tabs[2].capturedAt = 1700000100
    member.capturedAt = 1700000200
    entries = GGM.BuildBankEntries({ schemaVersion = GGM.SCHEMA_VERSION, characters = {} }, companionDB, nil)
    T.assertNil(entries[2].record, "record time must identify an observation in one of its tabs")
end)

T.test("bank detail treats malformed record wrappers as no saved snapshot", function()
    for _, entry in ipairs({ { record = true }, { record = { identity = true } } }) do
        local ok, detail = pcall(GGM.BuildBankDetail, entry, {})
        T.assertTrue(ok, "malformed saved data must not throw during view-model construction")
        T.assertFalse(detail.hasRecord)
        T.assertEqual(detail.emptyStateText, "No bank snapshot")
    end
end)

T.test("bank model reports companion absence and preserves unsupported database schemas", function()
    local originalGlobal = _G.DysbankMemoryAPI
    _G.DysbankMemoryAPI = nil
    local absentEntries = GGM.BuildBankEntries({ schemaVersion = GGM.SCHEMA_VERSION, characters = {} }, nil, nil)
    T.assertEqual(absentEntries[1].companionState, "missing")

    _G.DysbankMemoryAPI = { schemaVersion = 77 }
    local unsupported = { schemaVersion = 77, characters = {}, guilds = {} }
    local unsupportedEntries = GGM.BuildBankEntries({ schemaVersion = GGM.SCHEMA_VERSION, characters = {} }, unsupported, nil)
    T.assertEqual(unsupportedEntries[1].companionState, "unsupported")
    T.assertNil(unsupportedEntries[1].record)
    T.assertEqual(unsupported.schemaVersion, 77)
    T.assertNil(GGM.BuildBankEntries(nil, unsupported, nil)[2])
    _G.DysbankMemoryAPI = originalGlobal
end)

T.test("bank model rejects malformed identities, tabs, and slots without mutating saved records", function()
    local companionDB, member = bankDB()
    local savedCapturedAt, savedSlot = member.capturedAt, member.tabs[1].slots[1]
    member.tabs[1].slots[2] = { itemID = 0, count = 1 }
    local entries = GGM.BuildBankEntries({ schemaVersion = GGM.SCHEMA_VERSION, characters = {} }, companionDB, nil)
    T.assertNil(entries[2].record)
    T.assertEqual(member.capturedAt, savedCapturedAt)
    T.assertTrue(member.tabs[1].slots[1] == savedSlot)

    member.tabs[1].slots[2] = nil
    member.identity.key = "Forged-Silvermoon"
    entries = GGM.BuildBankEntries({ schemaVersion = GGM.SCHEMA_VERSION, characters = {} }, companionDB, nil)
    T.assertNil(entries[2])
end)

T.test("bank model rejects invalid numeric icons and malformed item links", function()
    local cases = {
        { icon = math.huge, itemLink = "|Hitem:19019|h[Thunderfury]|h" },
        { icon = -1, itemLink = "|Hitem:19019|h[Thunderfury]|h" },
        { icon = 134, itemLink = "not an item link" },
        { icon = 134, itemLink = "|Hitem:19020|h[Wrong item]|h" },
        { icon = 134, itemLink = "|cnIQ2:|Hitem:19020|h[Wrong item]|h|r" },
        { icon = 134, itemLink = "|cnIQ2:|Hitem:19019|h[Thunderfury]|h" },
        { icon = 134, itemLink = "|cn:|Hitem:19019|h[Thunderfury]|h|r" },
        { icon = 134, itemLink = "|cnIQ2|Hitem:19019|h[Thunderfury]|h|r" },
        { icon = 134, itemLink = "|cff00ff0|Hitem:19019|h[Thunderfury]|h|r" },
    }
    for _, malformed in ipairs(cases) do
        local companionDB, member = bankDB()
        member.tabs[1].slots[1].icon = malformed.icon
        member.tabs[1].slots[1].itemLink = malformed.itemLink
        local entries = GGM.BuildBankEntries({ schemaVersion = GGM.SCHEMA_VERSION, characters = {} }, companionDB, nil)
        T.assertNil(entries[2].record)
    end
end)

T.test("bank model accepts plain, hexadecimal, and named quality colors without changing saved links", function()
    local links = {
        "|Hitem:19019|h[Thunderfury]|h",
        "|cff00ff00|Hitem:19019|h[Thunderfury]|h|r",
        "|cnIQ2:|Hitem:19019|h[Thunderfury]|h|r",
        "|cnIQ4:|Hitem:19019|h[Thunderfury]|h|r",
    }
    for _, link in ipairs(links) do
        local saved, member = bankDB()
        member.tabs[1].slots[1].itemLink = link
        local entries = GGM.BuildBankEntries(nil, saved)
        T.assertTrue(entries[2].record == member, "valid color wrapper was rejected: " .. link)
        local detail = GGM.BuildBankDetail(entries[2])
        T.assertEqual(detail.tabs[1].slots[1].itemLink, link)
        T.assertEqual(member.tabs[1].slots[1].itemLink, link)
    end
end)
