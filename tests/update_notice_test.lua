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
