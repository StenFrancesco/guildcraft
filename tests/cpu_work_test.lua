local T = require('tests.testlib')
local function scheduler()
    local G = { CPUManualDriver = true }
    T.loadAddonFile('The Guild Book/CPUWork.lua', G)
    return G
end
T.test('CPU jobs yield, share a frame budget, and publish only complete results', function()
    local G, calls, results = scheduler(), 0, {}
    for id = 1, 2 do
        G.StartCPUJob('job' .. id, function()
            for i = 1, 1000 do calls = calls + 1; G.CPUCheckpoint() end
            return id, 'complete'
        end, function(value, state) results[value] = state end)
    end
    T.assertEqual(calls, 0)
    G.RunCPUFrame()
    T.assertTrue(calls > 0 and calls < 2000)
    T.assertNil(next(results))
    for i = 1, 100 do G.RunCPUFrame() end
    T.assertEqual(results[1], 'complete'); T.assertEqual(results[2], 'complete')
    T.assertEqual(G.GetCPUJobCount(), 0)
    local finished = calls; G.RunCPUFrame(); T.assertEqual(calls, finished)
end)
T.test('CPU jobs cancel superseded and stale results without retries', function()
    local G, revision, publications, cancellations = scheduler(), 0, 0, 0
    local function start()
        local captured = revision
        return G.StartCPUJob('owner', function()
            for i = 1, 1000 do G.CPUCheckpoint() end
            return 'result'
        end, function() publications = publications + 1 end, {
            current = function() return captured == revision end,
            onCancel = function() cancellations = cancellations + 1 end,
        })
    end
    start(); G.RunCPUFrame(); start()
    T.assertEqual(cancellations, 1)
    revision = 1; G.RunCPUFrame()
    T.assertEqual(cancellations, 2); T.assertEqual(publications, 0)
    T.assertEqual(G.GetCPUJobCount(), 0)
end)
T.test('CPU sort preserves synchronous results and resumes comparisons', function()
    local G, rows, result = scheduler(), {}, nil
    for i = 2048, 1, -1 do rows[#rows + 1] = i end
    G.StartCPUJob('sort', function() G.CPUSort(rows); return rows end, function(value) result = value end)
    G.RunCPUFrame(); T.assertNil(result)
    for i = 1, 1000 do if G.GetCPUJobCount() == 0 then break end; G.RunCPUFrame() end
    T.assertNotNil(result)
    for i = 1, 2048 do T.assertEqual(result[i], i) end
    G.CPUSort(rows, function(a,b) return a > b end); T.assertEqual(rows[1], 2048)
end)
T.test('CPU revision tokens are per database and never persisted', function()
    local G, first, second = scheduler(), {}, {}
    T.assertEqual(G.GetCPURevision(first), 0)
    G.InvalidateCPURevision(first)
    T.assertEqual(G.GetCPURevision(first), 1); T.assertEqual(G.GetCPURevision(second), 0)
    T.assertNil(next(first))
end)

T.test('CPU jobs share the calibrated clock budget and remove the idle frame handler',function()
    local G, tick, scripts = {}, 0, {}
    T.loadAddonFile('The Guild Book/CPUWork.lua',G)
    local api={CreateFrame=function() return {SetScript=function(_,event,fn) scripts[event]=fn end} end,
        debugprofilestop=function() return tick end}
    local work=0
    for i=1,2 do G.StartCPUJob(i,function()
        for j=1,100 do work=work+1;tick=tick+0.02;G.CPUCheckpoint() end
    end,function() end,{api=api}) end
    T.assertNotNil(scripts.OnUpdate)
    scripts.OnUpdate()
    T.assertTrue(tick<1.01,'all jobs must share a single clock deadline')
    for i=1,100 do if not scripts.OnUpdate then break end;scripts.OnUpdate() end
    T.assertEqual(work,200);T.assertNil(scripts.OnUpdate)
end)
T.test('CPU read stamps reject table replacements as well as controlled revisions',function()
    local G,db=scheduler(),{professions={},professionRecipeIndex={},professionCharacters={}}
    local stamp=G.CaptureCPUInput(db)
    T.assertTrue(G.IsCPUInputCurrent(db,stamp))
    db.professionCharacters={}
    T.assertFalse(G.IsCPUInputCurrent(db,stamp))
end)

return T
