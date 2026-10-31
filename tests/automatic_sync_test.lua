local T = require("tests.testlib")

local function fixture()
    local G, clock, timers, runs = {}, 0, {}, 0
    local api = { issecretvalue = function() return false end, GetTime = function() return clock end,
        random = function() return 300 end, IsResting = function() return true end,
        C_Map = { GetBestMapForUnit = function() return 84 end }, C_Timer = {} }
    api.C_Timer.NewTimer = function(delay, fn)
        local timer = { at = clock + delay, fn = fn }
        function timer:Cancel() self.cancelled = true end
        timers[#timers + 1] = timer
        return timer
    end
    T.loadAddonFile("The Guild Book/AutomaticSync.lua", G)
    local complete
    local controller = G.CreateAutomaticSyncController(api, function(done)
        runs = runs + 1
        complete = done
    end)
    local function advance(seconds)
        local limit, count = clock + seconds, 0
        while true do
            table.sort(timers, function(a, b) return a.at < b.at end)
            local nextTimer = timers[1]
            if not nextTimer or nextTimer.at > limit then break end
            table.remove(timers, 1); clock = nextTimer.at
            if not nextTimer.cancelled then nextTimer.fn() end
            count = count + 1; assert(count < 100, "automatic retry loop")
        end
        clock = limit
    end
    return G, api, controller, advance, function() return runs end, function(value) complete(value) end
end

T.test("automatic login waits up to five minutes and schedules only once", function()
    local G, _, c, advance, runs, done = fixture()
    assert(G.StartAutomaticSync(c)); assert(G.StartAutomaticSync(c))
    advance(299); T.assertEqual(runs(), 0)
    advance(1); T.assertEqual(runs(), 1)
    done(false); advance(20000); T.assertEqual(runs(), 1)
end)

T.test("unfinished automatic work retries in a stationary city at the cooldown deadline", function()
    local G, _, c, advance, runs, done = fixture()
    assert(G.StartAutomaticSync(c)); advance(300); done(true)
    advance(1199); T.assertEqual(runs(), 1)
    advance(1); T.assertEqual(runs(), 2)
    done(false); advance(4000); T.assertEqual(runs(), 2)
end)

T.test("automatic recovery waits for a city event outside the city and exhausts three retries", function()
    local G, api, c, advance, runs, done = fixture()
    assert(G.StartAutomaticSync(c)); advance(300)
    api.C_Map.GetBestMapForUnit = function() return 37 end
    done(true); advance(4000); T.assertEqual(runs(), 1)
    G.WakeAutomaticSync(c); T.assertEqual(runs(), 1)
    api.C_Map.GetBestMapForUnit = function() return 84 end
    for expected = 2, 4 do
        G.WakeAutomaticSync(c); T.assertEqual(runs(), expected)
        done(true); advance(1200)
    end
    advance(20000); G.WakeAutomaticSync(c)
    T.assertEqual(runs(), 4); T.assertTrue(c.exhausted)
end)

T.test("automatic completion and cancellation invalidate late callbacks", function()
    local G, _, c, advance, runs, done = fixture()
    assert(G.StartAutomaticSync(c)); advance(300)
    G.StopAutomaticSync(c); done(true); advance(20000)
    T.assertEqual(runs(), 1); T.assertFalse(c.pending)
end)

T.test("guild cancellation allows a fresh bounded automatic run after membership returns", function()
    local G, _, c, advance, runs, done = fixture()
    assert(G.StartAutomaticSync(c)); advance(300); T.assertEqual(runs(), 1)
    c.recoveries = 2
    G.StopAutomaticSync(c); done(true); advance(20000); T.assertEqual(runs(), 1)
    assert(G.WakeAutomaticSync(c))
    T.assertEqual(c.recoveries, 2)
    advance(300); T.assertEqual(runs(), 2)
    done(false); advance(20000); T.assertEqual(runs(), 2)
end)

T.test("city eligibility rejects inns unknown maps secret values and unavailable APIs", function()
    local G, api = fixture()
    T.assertTrue(G.IsAutomaticSyncMajorCity(api))
    api.C_Map.GetBestMapForUnit = function() return 37 end
    T.assertFalse(G.IsAutomaticSyncMajorCity(api))
    api.C_Map.GetBestMapForUnit = function() return 84 end
    api.issecretvalue = function() return true end
    T.assertFalse(G.IsAutomaticSyncMajorCity(api))
    api.issecretvalue = nil
    T.assertFalse(G.IsAutomaticSyncMajorCity(api))
end)

T.test("sync preference defaults to auto and town accepts resting inns", function()
    local G, api = fixture()
    T.assertTrue(G.AutomaticSyncAllowed(api))
    api.TheGuildBookDB = { uiSettings = { syncMode = "disable" } }
    T.assertFalse(G.AutomaticSyncAllowed(api))
    api.TheGuildBookDB.uiSettings.syncMode = "town"
    api.C_Map.GetBestMapForUnit = function() return 37 end
    T.assertTrue(G.AutomaticSyncAllowed(api))
    api.IsResting = function() return false end
    T.assertFalse(G.AutomaticSyncAllowed(api))
    api.issecretvalue = function() return true end
    api.IsResting = function() return true end
    T.assertFalse(G.AutomaticSyncAllowed(api))
end)

T.test("disabled and town modes hold login work until eligible", function()
    local G, api, c, advance, runs, done = fixture()
    api.TheGuildBookDB = { uiSettings = { syncMode = "disable" } }
    assert(G.StartAutomaticSync(c)); advance(300); T.assertEqual(runs(), 0)
    api.TheGuildBookDB.uiSettings.syncMode = "town"
    api.IsResting = function() return false end
    G.WakeAutomaticSync(c); T.assertEqual(runs(), 0)
    api.IsResting = function() return true end
    G.WakeAutomaticSync(c); T.assertEqual(runs(), 1)
    done(false)
end)

T.test("leaving town interrupts automatic work and allows it to resume", function()
    local G, api, c, advance, runs = fixture()
    api.TheGuildBookDB = { uiSettings = { syncMode = "town" } }
    local interrupts = 0
    c.interrupt = function() interrupts = interrupts + 1 end
    assert(G.StartAutomaticSync(c)); advance(300); T.assertEqual(runs(), 1)
    api.IsResting = function() return false end
    G.WakeAutomaticSync(c); T.assertEqual(interrupts, 1); T.assertFalse(c.running)
    api.IsResting = function() return true end
    G.WakeAutomaticSync(c); T.assertEqual(runs(), 2)
end)
