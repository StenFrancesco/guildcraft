local T = require("tests.testlib")

local function fixture()
    local G = {}
    for _, name in ipairs({ "Constants", "CharacterIdentity", "ProfessionSnapshot", "ProfessionIndex", "Storage", "ProfessionLinkSave" }) do
        T.loadAddonFile("The Guild Book/" .. name .. ".lua", G)
    end
    local state = { ready = true, linked = false, professionID = 164, recipeReady = true, saves = 0 }
    local api = {
        UnitFullName = function() return "Own", "Realm" end,
        UnitGUID = function() return "Player-1-OWN" end,
        GetRealmName = function() return "Realm" end,
        GetServerTime = function() return 1700000000 + state.saves end,
        GetNumGuildMembers = function() return 1 end,
        GetGuildRosterInfo = function()
            return "Member-Realm", nil, nil, nil, nil, nil, nil, nil,
                nil, nil, nil, nil, nil, nil, nil, nil, "Player-1-MEMBER"
        end,
        C_TradeSkillUI = {
            IsTradeSkillLinked = function() return state.linked end,
            IsTradeSkillReady = function() return state.ready end,
            GetBaseProfessionInfo = function() return { professionID = state.professionID, professionName = "Profession" } end,
            GetAllRecipeIDs = function() return { 100 } end,
            GetRecipeInfo = function()
                if state.recipeReady then return { recipeID = 100, name = "Recipe", learned = true } end
            end,
        },
    }
    G.RefreshVisibleProfessionCatalog = function() state.saves = state.saves + 1 end
    G.professionRosterMembershipCurrent = true
    local db = assert(G.InitializeDatabase(nil))
    local c = G.CreateProfessionLinkSaveController(api, db)
    c.panelOpen = true
    local function openLink(guid, observed)
        local link = "trade:" .. guid .. ":164:75:100"
        state.linked = true
        if observed then G.ObserveGuildProfessionMessage(c, "|H" .. link .. "|h[Profession]|h", "Reporter-Realm") end
        G.HandleProfessionHyperlinkOpened(c, link)
    end
    return G, c, state, openLink
end

T.test("automatic snapshots save the ready own profession without a UI button or guild membership", function()
    local G, c, s = fixture()
    G.professionRosterMembershipCurrent = false
    T.assertEqual(G.TryAutoSaveProfession(c), "saved")
    T.assertEqual(s.saves, 1)
    T.assertEqual(c.db.professions["Own-Realm"].identity.guid, "Player-1-OWN")
end)

T.test("automatic snapshots wait for ready data and retry incomplete recipes", function()
    local G, c, s = fixture()
    s.ready = false
    G.TryAutoSaveProfession(c)
    T.assertEqual(s.saves, 0)
    s.ready = true
    s.recipeReady = false
    G.TryAutoSaveProfession(c)
    T.assertEqual(s.saves, 0)
    s.recipeReady = true
    T.assertEqual(G.TryAutoSaveProfession(c), "saved")
end)

T.test("automatic snapshots save once per profession and again after closing", function()
    local G, c, s = fixture()
    G.TryAutoSaveProfession(c)
    G.TryAutoSaveProfession(c)
    T.assertEqual(s.saves, 1)
    s.professionID = 171
    G.TryAutoSaveProfession(c)
    T.assertEqual(s.saves, 2)
    G.ClearProfessionSaveContext(c)
    G.TryAutoSaveProfession(c)
    T.assertEqual(s.saves, 2)
    c.panelOpen = true
    G.TryAutoSaveProfession(c)
    T.assertEqual(s.saves, 3)
end)

T.test("automatic guild snapshots use the roster owner instead of the chat sender", function()
    local G, c, s, open = fixture()
    open("Player-1-MEMBER", true)
    T.assertEqual(G.TryAutoSaveProfession(c), "saved")
    T.assertEqual(s.saves, 1)
    T.assertNotNil(c.db.professions["Member-Realm"])
    T.assertNil(c.db.professions["Reporter-Realm"])
end)

T.test("automatic snapshots reject outsiders even when reposted in guild chat", function()
    local G, c, s, open = fixture()
    open("Player-1-OUTSIDER", true)
    G.TryAutoSaveProfession(c)
    T.assertEqual(s.saves, 0)
    T.assertNil(next(c.db.professions))
end)

T.test("automatic guild snapshots retry when the current roster becomes available", function()
    local G, c, s, open = fixture()
    open("Player-1-MEMBER", true)
    G.professionRosterMembershipCurrent = false
    G.TryAutoSaveProfession(c)
    T.assertEqual(s.saves, 0)
    G.professionRosterMembershipCurrent = true
    T.assertEqual(G.TryAutoSaveProfession(c), "saved")
end)

T.test("opening an unknown link clears a previous automatic save context", function()
    local G, c, s, open = fixture()
    open("Player-1-MEMBER", true)
    G.TryAutoSaveProfession(c)
    open("Player-1-OUTSIDER", false)
    G.TryAutoSaveProfession(c)
    T.assertEqual(s.saves, 1)
end)

T.test("switching directly from a guild profession to own profession saves the player", function()
    local G, c, s, open = fixture()
    open("Player-1-MEMBER", true)
    G.TryAutoSaveProfession(c)
    s.linked = false
    T.assertEqual(G.TryAutoSaveProfession(c), "saved")
    T.assertEqual(s.saves, 2)
    T.assertNotNil(c.db.professions["Own-Realm"])
end)

T.test("a linked outsider cannot be saved under a stale player identity", function()
    local G, c, s = fixture()
    G.TryAutoSaveProfession(c)
    s.linked = true
    s.professionID = 171
    G.TryAutoSaveProfession(c)
    T.assertEqual(s.saves, 1)
    T.assertNil(c.db.professions["Own-Realm"].snapshots[171])
end)

T.test("unlinked guild or NPC browsing never saves as the logged-in player", function()
    for _, name in ipairs({ "IsTradeSkillGuild", "IsTradeSkillNPC", "IsNPCCrafting" }) do
        local G, c, s = fixture()
        c.api.C_TradeSkillUI[name] = function() return true end
        G.TryAutoSaveProfession(c)
        T.assertEqual(s.saves, 0)
    end
end)

T.test("guild owner links are eligible even without a prior guild chat message", function()
    local G, c, s, open = fixture()
    open("Player-1-MEMBER", false)
    T.assertEqual(G.TryAutoSaveProfession(c), "saved")
    T.assertEqual(s.saves, 1)
end)

T.test("an account-owned linked alt is eligible outside the guild", function()
    local G, c, s, open = fixture()
    local alt = { key = "Alt-Realm", name = "Alt", realm = "Realm", guid = "Player-1-ALT" }
    assert(G.MarkLocalCharacterGUID(c.db, alt.guid))
    assert(G.SaveProfessionSnapshot(c.db, alt, {
        complete = true, professionID = 164, professionName = "Profession",
        capturedAt = 1699999999, source = G.PROFESSION_SOURCE_PLAYER,
        status = G.PROFESSION_CACHE_STATUS, recipes = {},
    }))
    open(alt.guid, false)
    local result, err = G.TryAutoSaveProfession(c)
    T.assertEqual(result, "saved", tostring(err))
    T.assertEqual(s.saves, 1)
    T.assertNotNil(c.db.professions[alt.key].snapshots[164])
end)

T.test("stored foreign characters do not count as account ownership", function()
    local G, c, s, open = fixture()
    c.db.professions["Outsider-Realm"] = {
        identity = { key = "Outsider-Realm", name = "Outsider", realm = "Realm", guid = "Player-1-OUTSIDER" },
        snapshots = {},
    }
    open("Player-1-OUTSIDER", false)
    G.TryAutoSaveProfession(c)
    T.assertEqual(s.saves, 0)
end)

T.test("real panel events defer owner selection and cancel saves after close", function()
    local G, c, s, open = fixture()
    local originalCreateFrame, originalTimer = _G.CreateFrame, _G.C_Timer
    local callbacks, onEvent = {}, nil
    _G.CreateFrame = function()
        return { RegisterEvent = function() end, SetScript = function(_, _, handler) onEvent = handler end }
    end
    _G.C_Timer = { After = function(_, callback) callbacks[#callbacks + 1] = callback end }
    G.RegisterSnapshotTestSlashCommand = function() end
    local ok, err = pcall(function()
        T.loadAddonFile("The Guild Book/Main.lua", G)
        G.professionLinkSave = c
        G.professionRosterMembershipCurrent = true
        G.TryAutoSaveProfession(c)
        T.assertEqual(s.saves, 1)
        s.linked = true
        s.professionID = 171
        onEvent(nil, "TRADE_SKILL_SHOW")
        T.assertEqual(s.saves, 1)
        open("Player-1-OUTSIDER", false)
        callbacks[#callbacks]()
        T.assertEqual(s.saves, 1)
        open("Player-1-MEMBER", false)
        onEvent(nil, "TRADE_SKILL_LIST_UPDATE")
        onEvent(nil, "TRADE_SKILL_CLOSE")
        callbacks[#callbacks]()
        T.assertEqual(s.saves, 1)
        onEvent(nil, "TRADE_SKILL_LIST_UPDATE")
        T.assertEqual(s.saves, 1)
        open("Player-1-MEMBER", false)
        onEvent(nil, "TRADE_SKILL_SHOW")
        callbacks[#callbacks]()
        T.assertEqual(s.saves, 2)
        T.assertNotNil(c.db.professions["Member-Realm"].snapshots[171])
    end)
    _G.CreateFrame, _G.C_Timer = originalCreateFrame, originalTimer
    if not ok then error(err, 0) end
end)

T.test("manual saves and button visibility reject unlinked foreign browsing too", function()
    for _, name in ipairs({ "IsTradeSkillGuild", "IsTradeSkillNPC", "IsNPCCrafting" }) do
        local G, c, s = fixture()
        G.TryAutoSaveProfession(c)
        c.button = { Show = function() end, Hide = function() end }
        c.api.C_TradeSkillUI[name] = function() return true end
        s.professionID = 171
        T.assertEqual(G.RefreshProfessionSaveButton(c), "hidden")
        local result, err = G.SaveActiveLinkedProfession(c)
        T.assertNil(result)
        T.assertEqual(err, "profession-not-owned")
        T.assertNil(c.db.professions["Own-Realm"].snapshots[171])
    end
end)
T.test('queued profession save budgets preparation and keeps synchronous save results intact',function()
    local G,c,s=fixture()
    G.CPUManualDriver=true;T.loadAddonFile('The Guild Book/CPUWork.lua',G)
    T.loadAddonFile('The Guild Book/ProfessionSyncData.lua',G)
    c.api.C_TradeSkillUI.GetAllRecipeIDs=function() local ids={};for i=1,1000 do ids[i]=i end;return ids end
    c.api.C_TradeSkillUI.GetRecipeInfo=function(id) return {recipeID=id,name='Recipe '..id,learned=true} end
    T.assertTrue(G.QueueProfessionSave(c,true))
    G.RunCPUFrame();T.assertEqual(s.saves,0)
    for i=1,1000 do if G.GetCPUJobCount()==0 then break end;G.RunCPUFrame() end
    T.assertEqual(s.saves,1);T.assertEqual(G.GetCPUJobCount(),0)
    T.assertEqual(G.TryAutoSaveProfession(c),'unchanged')
end)
T.test('closing a profession cancels queued capture before saved data changes',function()
    local G,c,s=fixture()
    G.CPUManualDriver=true;T.loadAddonFile('The Guild Book/CPUWork.lua',G)
    T.loadAddonFile('The Guild Book/ProfessionSyncData.lua',G)
    T.assertTrue(G.QueueProfessionSave(c,true))
    G.ClearProfessionSaveContext(c);G.RunCPUFrame()
    T.assertEqual(s.saves,0);T.assertNil(next(c.db.professions));T.assertEqual(G.GetCPUJobCount(),0)
end)
T.test('queued guild saves resolve an owner after roster readiness recovers',function()
    local G,c,s,open=fixture()
    G.CPUManualDriver=true;T.loadAddonFile('The Guild Book/CPUWork.lua',G)
    T.loadAddonFile('The Guild Book/ProfessionSyncData.lua',G)
    G.professionRosterMembershipCurrent=false
    c.api.GetNumGuildMembers=function() return 0 end
    open('Player-1-MEMBER',true)
    T.assertNil(c.activeIdentity)
    c.api.GetNumGuildMembers=function() return 1 end
    G.professionRosterMembershipCurrent=true
    T.assertTrue(G.QueueProfessionSave(c,true))
    for i=1,100 do if G.GetCPUJobCount()==0 then break end;G.RunCPUFrame() end
    T.assertEqual(s.saves,1);T.assertNotNil(c.db.professions['Member-Realm'])
end)
