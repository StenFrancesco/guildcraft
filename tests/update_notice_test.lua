local T = require("tests.testlib")
local oldCreateFrame = CreateFrame
CreateFrame = function() return { RegisterEvent = function() end, SetScript = function() end } end
local GGM = {}
T.loadAddonFile("The Guild Book/UpdateNotice.lua", GGM)
CreateFrame = oldCreateFrame

T.test("update notices compare versions and respond only once to older guild peers", function()
    local sent = {}
    local api = { IsInGuild = function() return true end, GetGuildInfo = function() return "Guild" end,
        ChatThrottleLib = { SendAddonMessage = function(_, _, prefix, message, channel, target)
            sent[#sent + 1] = { prefix, message, channel, target }
        end } }
    local notice = GGM.CreateUpdateNotice(api, "1.2.3-release")
    notice.registered = true
    notice:Announce(); notice:Announce()
    T.assertEqual(#sent, 1)
    notice:Receive("TGB_VERSION1", "Q:1.2.2", "GUILD", "Peer")
    notice:Receive("TGB_VERSION1", "Q:1.2.2", "GUILD", "Peer")
    T.assertEqual(#sent, 2)
    T.assertEqual(sent[2][3], "WHISPER")
    notice:Receive("TGB_VERSION1", "R:1.10.0", "WHISPER", "Peer")
    T.assertTrue(notice.available)
end)

T.test("update notices reject invalid versions and message channels", function()
    local notice = GGM.CreateUpdateNotice({}, "1.2.3")
    notice.registered = true
    for _, message in ipairs({ "Q:garbage", "Q:999999999999.0.0", "R:1.2.4", "Q:1.2.3" }) do
        notice:Receive("TGB_VERSION1", message, "GUILD", "Peer")
    end
    notice:Receive("OTHER", "Q:9.0.0", "GUILD", "Peer")
    T.assertFalse(notice.available)
    notice:Receive("TGB_VERSION1", "Q:1.2.4", "GUILD", "Peer")
    T.assertTrue(notice.available)
end)

T.test("update replies use a per-sender cooldown and expire", function()
    local now, sent = 0, {}
    local api = { GetTime = function() return now end,
        ChatThrottleLib = { SendAddonMessage = function(_, _, _, message) sent[#sent + 1] = message end } }
    local notice = GGM.CreateUpdateNotice(api, "1.2.3")
    notice.registered = true
    local function query(sender)
        notice:Receive("TGB_VERSION1", "Q:1.2.2", "GUILD", sender)
    end
    query("Peer")
    query("Peer")
    T.assertEqual(#sent, 1)
    now = 61
    query("Peer")
    T.assertEqual(#sent, 2)
    now = 182
    query("Peer")
    T.assertEqual(#sent, 3)
end)

T.test("update reply cache stays bounded without suppressing later peers", function()
    local sent = 0
    local api = { GetTime = function() return 1 end,
        ChatThrottleLib = { SendAddonMessage = function() sent = sent + 1 end } }
    local notice = GGM.CreateUpdateNotice(api, "1.2.3")
    notice.registered = true
    for i = 1, 160 do
        notice:Receive("TGB_VERSION1", "Q:1.2.2", "GUILD", "Peer" .. i)
    end
    T.assertEqual(sent, 160)
    T.assertEqual(#notice.replyOrder, 128)
    notice:Receive("TGB_VERSION1", "Q:1.2.2", "GUILD", "Peer1")
    T.assertEqual(sent, 161)
end)
