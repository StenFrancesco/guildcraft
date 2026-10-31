local T = require("tests.testlib")

local function setup(options)
    options = options or {}
    local G = {}
    T.loadAddonFile("The Guild Book/BankSyncProtocol.lua", G)

    local api = {
        now = 100,
        timers = {},
        sent = {},
        snapshotReads = 0,
        snapshotSends = 0,
        C_Timer = {},
        roster = options.roster or {
            { "Alice-Silvermoon", "Officer", 1 },
            { "Bob-Silvermoon", "Member", 2 },
        },
    }
    api.issecretvalue = function() return false end
    api.GetTime = function() return api.now end
    api.C_Timer.NewTimer = function(delay, callback)
        local timer = { delay = delay, callback = callback, cancelled = false }
        function timer:Cancel() self.cancelled = true end
        function timer:Fire()
            if not self.cancelled then self.callback() end
        end
        api.timers[#api.timers + 1] = timer
        return timer
    end
    api.GetNumGuildMembers = function() return #api.roster end
    api.GetGuildRosterInfo = function(index)
        local row = api.roster[index]
        return row[1], row[2], row[3]
    end

    G.BuildPlayerIdentity = function()
        local key = options.senderKey or "Bob-Silvermoon"
        local name, realm = key:match("^(.+)%-(.+)$")
        return { key = key, name = name, realm = realm }
    end
    G.CreateBankSyncTransport = function(_, onMessage)
        return { onMessage = onMessage }
    end
    G.SetBankSyncTransportIdentity = function() return true end
    G.RegisterBankSyncTransport = function() return true end
    G.CancelBankSyncTransport = function() return true end
    G.SendBankSyncMessage = function(transport, kind, fields, target, channel, done)
        api.sent[#api.sent + 1] = { kind = kind, fields = fields, target = target, channel = channel }
        if kind == "Q" and options.failRequests then
            if done then done(false, "bank-sync-send-failed") end
            return false, "bank-sync-send-failed"
        end
        if done then done(true) end
        return true
    end
    G.SendBankSyncSnapshot = function(_, target, fields, snapshot)
        api.snapshotSends = api.snapshotSends + 1
        api.snapshotSendTarget = target
        api.snapshotSendFields = fields
        api.snapshotSendSnapshot = snapshot
        return true
    end
    G.RefreshVisibleBankView = function() end
    G.DecompressProfessionDeflate = function() end
    T.loadAddonFile("The Guild Book/BankSync.lua", G)

    local bankAPI = {
        schemaVersion = 1,
        GetGuildBankSyncContext = function()
            return { guildKey = "Raid Team-Silvermoon", sessionToken = options.localToken or "bob-token", viewableTabIDs = { [1] = true } }
        end,
        GetGuildBankSyncSnapshot = function(tabID)
            api.snapshotReads = api.snapshotReads + 1
            if options.localSnapshot == false then return nil, "snapshot-unavailable" end
            return { id = tabID, name = "Tab 1", numSlots = 98, capturedAt = 200,
                status = "cached", slots = { [1] = { itemID = 1001, count = 1 } } }
        end,
        MergeGuildBankSyncSnapshot = function() return true end,
    }
    api.DysbankMemoryAPI = bankAPI
    local sync = assert(G.CreateBankSync(api))
    T.assertTrue(G.OnBankMemoryChanged(sync, "guild-session-open"))
    return G, api, sync
end

local function manifest(G, sender, token, capturedAt)
    local pages = assert(G.BankSyncProtocol.BuildManifest(sender, "Raid Team-Silvermoon", token, {
        [1] = { capturedAt = capturedAt or 10 },
    }))
    return assert(G.BankSyncProtocol.Decode(pages[1], "GUILD"))
end

T.test("guild bank Q replies require the requester to be roster-confirmed at the same rank", function()
    local G, api, sync = setup()
    sync.transport.onMessage(manifest(G, "Alice-Silvermoon", "alice-token"), "Alice-Silvermoon", "GUILD")
    local readsBeforeRequest = api.snapshotReads
    local request = assert(G.BankSyncProtocol.Decode(assert(G.BankSyncProtocol.Encode("Q", {
        "Alice-Silvermoon", "Raid Team-Silvermoon", "alice-token", "bob-token", "1", "1",
    })), "WHISPER"))

    local accepted, err = sync.transport.onMessage(request, "Alice-Silvermoon", "WHISPER")

    T.assertFalse(accepted)
    T.assertEqual(err, "bank-sync-request-unbound")
    T.assertEqual(api.snapshotReads, readsBeforeRequest)
    T.assertEqual(api.snapshotSends, 0)
end)

T.test("same-rank guild bank requesters may receive tabs the local rank can view", function()
    local G, api, sync = setup({
        roster = {
            { "Alice-Silvermoon", "Member", 2 },
            { "Bob-Silvermoon", "Member", 2 },
        },
    })
    sync.transport.onMessage(manifest(G, "Alice-Silvermoon", "alice-token"), "Alice-Silvermoon", "GUILD")
    local readsBeforeRequest = api.snapshotReads
    local request = assert(G.BankSyncProtocol.Decode(assert(G.BankSyncProtocol.Encode("Q", {
        "Alice-Silvermoon", "Raid Team-Silvermoon", "alice-token", "bob-token", "1", "1",
    })), "WHISPER"))

    local accepted = sync.transport.onMessage(request, "Alice-Silvermoon", "WHISPER")

    T.assertTrue(accepted)
    T.assertEqual(api.snapshotReads, readsBeforeRequest + 1)
    T.assertEqual(api.snapshotSends, 1)
    T.assertEqual(api.snapshotSendTarget, "Alice-Silvermoon")
end)

T.test("bank sync stops after two requests per peer tab and manifest", function()
    local G, api, sync = setup({ senderKey = "Alice-Silvermoon", localToken = "alice-local-token", localSnapshot = false,
        roster = { { "Alice-Silvermoon", "Member", 2 }, { "Bob-Silvermoon", "Member", 2 } } })
    sync.transport.onMessage(manifest(G, "Bob-Silvermoon", "bob-token"), "Bob-Silvermoon", "GUILD")

    local attempts = 0
    for _, sent in ipairs(api.sent) do if sent.kind == "Q" then attempts = attempts + 1 end end
    local fired = 0
    while sync.responseTimer and fired < 3 do
        sync.responseTimer:Fire()
        fired = fired + 1
        attempts = 0
        for _, sent in ipairs(api.sent) do if sent.kind == "Q" then attempts = attempts + 1 end end
    end

    T.assertEqual(attempts, 2)
    T.assertNil(sync.current)
    T.assertEqual(G.GetBankSyncStatus(sync), "No compatible responder replied before timeout")
end)

T.test("bank sync bounds immediate send failures as well as response timeouts", function()
    local G, api, sync = setup({ senderKey = "Alice-Silvermoon", localToken = "alice-local-token",
        localSnapshot = false, failRequests = true,
        roster = { { "Alice-Silvermoon", "Member", 2 }, { "Bob-Silvermoon", "Member", 2 } } })

    sync.transport.onMessage(manifest(G, "Bob-Silvermoon", "bob-token"), "Bob-Silvermoon", "GUILD")

    local attempts = 0
    for _, sent in ipairs(api.sent) do if sent.kind == "Q" then attempts = attempts + 1 end end
    T.assertEqual(attempts, 2)
    T.assertNil(sync.current)
    T.assertEqual(G.GetBankSyncStatus(sync), "Guild sync could not send a request")
end)

T.test("bank sync replies to a late manifest once per peer session", function()
    local G, api, sync = setup()
    local peerManifest = manifest(G, "Alice-Silvermoon", "alice-token")
    local before = 0
    for _, sent in ipairs(api.sent) do if sent.kind == "M" then before = before + 1 end end

    sync.transport.onMessage(peerManifest, "Alice-Silvermoon", "GUILD")
    local afterFirst = 0
    for _, sent in ipairs(api.sent) do if sent.kind == "M" then afterFirst = afterFirst + 1 end end
    sync.transport.onMessage(peerManifest, "Alice-Silvermoon", "GUILD")
    local afterDuplicate = 0
    for _, sent in ipairs(api.sent) do if sent.kind == "M" then afterDuplicate = afterDuplicate + 1 end end

    T.assertEqual(afterFirst, before + 1)
    T.assertEqual(afterDuplicate, afterFirst)
end)

T.test("bank sync keeps a newly earlier peer queued while the current request finishes", function()
    local G, api, sync = setup({ senderKey = "Zed-Silvermoon", localSnapshot = false,
        roster = {
            { "Alice-Silvermoon", "Member", 2 },
            { "Cara-Silvermoon", "Member", 2 },
            { "Zed-Silvermoon", "Member", 2 },
        } })
    sync.transport.onMessage(manifest(G, "Cara-Silvermoon", "cara-token"), "Cara-Silvermoon", "GUILD")
    T.assertEqual(api.sent[#api.sent].kind, "Q")
    T.assertEqual(api.sent[#api.sent].target, "Cara-Silvermoon")

    sync.transport.onMessage(manifest(G, "Alice-Silvermoon", "alice-token"), "Alice-Silvermoon", "GUILD")
    T.assertEqual(sync.current.peer, "cara-silvermoon")
    sync.responseTimer:Fire()
    sync.responseTimer:Fire()
    T.assertEqual(sync.peersInWindow, 1)

    T.assertEqual(api.sent[#api.sent].kind, "Q")
    T.assertEqual(api.sent[#api.sent].target, "Alice-Silvermoon")
end)


T.test("disabled bank sync stays passive until the manual button is pressed", function()
    local G, api, sync = setup()
    G.AutomaticSyncAllowed = function() return false end
    G.BankSyncPreferenceChanged(sync)
    local sent = #api.sent
    T.assertTrue(sync.sessionActive)
    T.assertFalse(sync.autoSession)
    G.OnBankMemoryChanged(sync, "guild-capture", 1)
    T.assertEqual(#api.sent, sent)
    T.assertTrue(G.RequestBankSyncFromButton(sync))
    T.assertTrue(#api.sent > sent)
end)

T.test("bank auto sync resumes when entering an eligible resting area", function()
    local G, api, sync = setup()
    local allowed = false
    G.AutomaticSyncAllowed = function() return allowed end
    G.BankSyncPreferenceChanged(sync)
    local sent = #api.sent
    allowed = true
    G.HandleBankSyncEvent(sync, "PLAYER_UPDATE_RESTING")
    T.assertTrue(sync.autoSession)
    T.assertTrue(#api.sent > sent)
end)


T.test("disabling bank sync cancels its session without sending a session-end notice", function()
    local G, api, sync = setup()
    G.IsSyncDisabled = function() return true end
    G.AutomaticSyncAllowed = function() return false end
    local before = #api.sent
    G.BankSyncPreferenceChanged(sync)
    T.assertEqual(#api.sent, before)
    T.assertTrue(sync.sessionActive)
    T.assertFalse(sync.autoSession)
end)

return true
