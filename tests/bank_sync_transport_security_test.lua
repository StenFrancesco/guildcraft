local T = require("tests.testlib")

local G = {}
T.loadAddonFile("The Guild Book/BankSyncProtocol.lua", G)
T.loadAddonFile("The Guild Book/BankSyncTransport.lua", G)

local function transport()
    return {
        api = { GetTime = function() return 100 end },
        assemblies = {},
        priorityAssemblies = {},
        onMessage = function() error("incomplete frame must not reach the handler") end,
    }
end

local function frame(id)
    return string.format("F1|%06d|001|002|x", id)
end

local function count(map)
    local total = 0
    for _ in pairs(map) do total = total + 1 end
    return total
end

T.test("unauthorized whisper frames are rejected before reserving assembly state", function()
    local t = transport()
    local state, err = G.ReceiveBankSyncFrame(t, G.BankSyncProtocol.PREFIX, frame(1), "WHISPER", "Unknown-Silvermoon",
        nil, function() return false end)

    T.assertNil(state)
    T.assertEqual(err, "bank-sync-sender-unavailable")
    T.assertEqual(count(t.assemblies), 0)
    T.assertEqual(count(t.priorityAssemblies), 0)
end)

T.test("one sender cannot reserve multiple general partial-frame assemblies", function()
    local t = transport()
    local authorize = function() return true end
    local first = G.ReceiveBankSyncFrame(t, G.BankSyncProtocol.PREFIX, frame(1), "GUILD", "Alice-Silvermoon", nil, authorize)
    local second, err = G.ReceiveBankSyncFrame(t, G.BankSyncProtocol.PREFIX, frame(2), "GUILD", "Alice-Silvermoon", nil, authorize)

    T.assertEqual(first, "partial")
    T.assertNil(second)
    T.assertEqual(err, "bank-sync-sender-assembly-limit")
    T.assertEqual(count(t.assemblies), 1)
end)

T.test("expected responder has a reserved assembly when the general pool is full", function()
    local t = transport()
    local authorize = function() return true end
    for i = 1, 7 do
        T.assertEqual(G.ReceiveBankSyncFrame(t, G.BankSyncProtocol.PREFIX, frame(i), "GUILD", "Member" .. i,
            nil, authorize), "partial")
    end
    local expected = G.ReceiveBankSyncFrame(t, G.BankSyncProtocol.PREFIX, frame(8), "WHISPER", "Alice-Silvermoon",
        nil, authorize, function() return true end)

    T.assertEqual(expected, "partial")
    T.assertEqual(count(t.assemblies), 7)
    T.assertEqual(count(t.priorityAssemblies), 1)
end)

return true
