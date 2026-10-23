-- Reproducible CPU probe; run from repository root with Lua 5.1.
-- The frozen implementation is the selected compression baseline's data path.
package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.testlib")
local guild = require("tests.profession_sync_fixture")
local SAMPLES = 5
local function load(reference)
    local G = {}
    for _, file in ipairs({"Constants", "ProfessionSnapshot", "ProfessionIndex", "Storage", "ProfessionSyncData"}) do
        T.loadAddonFile("The Guild Book/" .. file .. ".lua", G)
    end
    if reference then T.loadAddonFile("tests/fixtures/profession_sync_data_uncached.lua", G) end
    return G
end
local function database(G, characters, recipes)
    local db = assert(G.InitializeDatabase(nil))
    db.nextLocalCharacterID = characters + 1
    for i = 1, characters do
        local guid, key = "Player-1-" .. i, "Crafter" .. i .. "-Realm"
        db.professionCharacters[i] = {guid=guid, key=key, active=true}
        db.localCharacterIDByGUID[guid] = i
        db.professions[key] = {identity={guid=guid, key=key, name="Crafter" .. i, realm="Realm"}, snapshots={
            [164]={complete=true, professionID=164, professionName="Blacksmithing", capturedAt=1700000000,
                source=G.PROFESSION_SOURCE_GUILD_LINK, status="cached"}}}
    end
    local index = {}; db.professionRecipeIndex[164] = index
    for id = 1, recipes do
        local crafters = {}; for i = 1, characters do crafters[i] = i end
        index[id] = {name="Recipe " .. id, crafters=crafters}
    end
    assert(G.EnsureProfessionIndex(db, true))
    return db
end
local function median(values)
    table.sort(values); return values[math.ceil(#values / 2)]
end
local function measure(make)
    local times, hashes, captures, records, frames, bytes, codec = {}, {}, {}, {}, {}, {}, {}
    for sample = 1, SAMPLES do
        local run, stats, verify = make()
        collectgarbage("collect")
        local start = os.clock(); run(); times[sample] = (os.clock() - start) * 1000
        hashes[sample], captures[sample], records[sample] = stats.hashes or 0, stats.captures or 0, stats.records or 0
        frames[sample], bytes[sample], codec[sample] = stats.frames or 0, stats.bytes or 0, stats.codec or 0
        if verify then verify() end
    end
    return string.format("%.3f ms; hashes=%d captures=%d records=%d frames=%d bytes=%d codec=%.3f ms",
        median(times), median(hashes), median(captures), median(records), median(frames), median(bytes), median(codec))
end
local function counters(G, stats)
    local hash, validate, record = G.HashProfessionRecipes, G.ValidateProfessionCapture, G.GetProfessionRecord
    G.GetProfessionRecord = function(...) stats.records = (stats.records or 0) + 1; return record(...) end
    G.HashProfessionRecipes = function(...) stats.hashes = (stats.hashes or 0) + 1; return hash(...) end
    G.ValidateProfessionCapture = function(...) stats.captures = (stats.captures or 0) + 1; return validate(...) end
end
print("Lua: " .. _VERSION .. "; five samples, median CPU; setup/prewarm/forced GC excluded")
for _, size in ipairs({{10,500}, {50,1000}, {100,2000}}) do
    for _, reference in ipairs({true, false}) do
        for _, warm in ipairs({false, true}) do
            for _, combined in ipairs({false, true}) do
                local label = string.format("%dx%d %s %s %s", size[1], size[2], reference and "baseline" or "cached",
                    warm and "warm" or "cold", combined and "manifest+digest" or "digest")
                print(label .. ": " .. measure(function()
                    local G, stats = load(reference), {}
                    local db = database(G, size[1], size[2])
                    if warm then assert(G.GetProfessionSyncDigest(db,164)) end
                    counters(G, stats)
                    return function()
                        if combined then assert(G.GetProfessionSyncManifest(db,164)) end
                        assert(G.GetProfessionSyncDigest(db,164))
                    end, stats
                end))
            end
        end
    end
end
-- Equal comparisons exercise real Q/C/M coordination and transport, whereas
-- the divergent case also exercises compressed D records, validation and ACKs.
for _, reference in ipairs({true,false}) do
    for _, warm in ipairs({false,true}) do
        for _, divergent in ipairs({false,true}) do
            local label = string.format("sync %s %s %s", reference and "baseline" or "cached", warm and "warm" or "cold",
                divergent and "record-2000" or "equal-10x500")
            print(label .. ": " .. measure(function()
                local bus, stats = guild(), {frames=0,bytes=0,codec=0}
                local a, b = bus:client("Alice"), bus:client("Bob")
                if reference then
                    T.loadAddonFile("tests/fixtures/profession_sync_data_uncached.lua",a.G)
                    T.loadAddonFile("tests/fixtures/profession_sync_data_uncached.lua",b.G)
                    -- Restore the baseline Q responder's redundant digest read too.
                    -- The reference GetDigest never calls this helper itself.
                    for _,client in ipairs({a,b}) do
                        client.G.GetProfessionSyncManifestDigest = function(professionID)
                            return client.G.GetProfessionSyncDigest(client.db,professionID,client.sync.members)
                        end
                    end
                end
                local ids = {}; for i=1,divergent and 2000 or 500 do ids[i]=i end
                if divergent then a:save(a.identity,ids)
                else
                    local owners = {a.identity,b.identity}
                    for i=3,10 do owners[i] = bus:member("Offline" .. i) end
                    for _,owner in ipairs(owners) do a:save(owner,ids); b:save(owner,ids) end
                end
                a:ready(); b:ready()
                for _,client in ipairs({a,b}) do
                    if warm then assert(client.G.GetProfessionSyncDigest(client.db,164,client.sync.members)) end
                    counters(client.G,stats)
                    for _,name in ipairs({"EncodeProfessionPayload","DecodeProfessionPayload"}) do
                        local original = client.G[name]
                        client.G[name] = function(...)
                            local start = os.clock(); local result,err = original(...)
                            stats.codec = stats.codec + (os.clock()-start)*1000
                            return result,err
                        end
                    end
                end
                return function()
                    assert(b.G.RequestProfessionSync(b.sync,164,"manual")); bus:advance(180)
                    stats.frames = #bus.frames
                    for _,frame in ipairs(bus.frames) do stats.bytes=stats.bytes+#frame.text end
                end, stats, function()
                    -- Verify convergence outside timing and operation counts.
                    local da = assert(a.G.GetProfessionSyncDigest(a.db,164,a.sync.members))
                    local db = assert(b.G.GetProfessionSyncDigest(b.db,164,b.sync.members))
                    assert(da==db,"sync did not converge")
                    if divergent then
                        local compressed = false
                        for _,frame in ipairs(bus.frames) do
                            if frame.text:find("|Z1|",1,true) then compressed=true end
                        end
                        assert(compressed,"missing compressed record transfer")
                    end
                end
            end))
        end
    end
end
local G = {}; T.loadAddonFile("The Guild Book/ProfessionTransport.lua",G)
local payload = "P5|D|Bob-Realm|000001|164|" .. string.rep("12345:Tempered%20Steel%20Sword:98765,", 1000)
local encoded = assert(G.EncodeProfessionPayload(payload))
assert(encoded:sub(1,3)=="Z1|")
print(string.format("codec payload: %d plain bytes -> %d wire bytes",#payload,#encoded))
print("codec encode: " .. measure(function() return function() assert(G.EncodeProfessionPayload(payload)==encoded) end, {} end))
print("codec decode: " .. measure(function() return function() assert(G.DecodeProfessionPayload(encoded)==payload) end, {} end))
