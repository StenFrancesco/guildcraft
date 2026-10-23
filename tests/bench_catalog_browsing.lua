-- Run with Lua 5.1 from the repository root. Optional argument: baseline ProfessionIndex.lua.
package.path = "./?.lua;./?/init.lua;" .. package.path
local T = require("tests.testlib")
local function loadModules()
    local G = {}
    T.loadAddonFile("The Guild Book/Constants.lua", G)
    T.loadAddonFile("The Guild Book/ProfessionSnapshot.lua", G)
    T.loadAddonFile(arg[1] or "The Guild Book/ProfessionIndex.lua", G)
    T.loadAddonFile("The Guild Book/Storage.lua", G)
    G.professionRosterMembershipCurrent = true
    return G
end
local function database(G, owners, recipes)
    local db = assert(G.InitializeDatabase(nil))
    db.nextLocalCharacterID = owners + 1
    for i = 1, owners do
        local guid, name = "Player-1-" .. i, "Crafter" .. i
        local key = name .. "-Realm"
        db.professionCharacters[i] = { guid = guid, key = key, active = true }
        db.localCharacterIDByGUID[guid] = i
        db.professions[key] = { identity = { guid = guid, key = key, name = name, realm = "Realm" },
            snapshots = { [164] = { complete = true, professionID = 164, professionName = "Blacksmithing",
                capturedAt = 1700000000, source = G.PROFESSION_SOURCE_GUILD_LINK, status = G.PROFESSION_CACHE_STATUS } } }
    end
    local index = {}; db.professionRecipeIndex[164] = index
    for id = 1, recipes do
        local crafters = {}; for i = 1, owners do crafters[i] = i end
        index[id] = { name = "Recipe " .. id, crafters = crafters }
    end
    return db
end
local function median(values)
    table.sort(values); return values[math.ceil(#values / 2)]
end
print(_VERSION .. "; five samples; median os.clock CPU; fixture setup/forced GC excluded")
for _, size in ipairs({ { 10, 500 }, { 50, 1000 }, { 100, 2000 } }) do
    local cold, warm = {}, {}
    local coldDates, warmDates, descriptors, reused
    for sample = 1, 5 do
        local G, dates = loadModules(), 0
        local db = database(G, size[1], size[2])
        local api = { date = function(format, timestamp) dates = dates + 1; return os.date(format, timestamp) end }
        collectgarbage("collect")
        local start = os.clock()
        local first = G.BuildProfessionRecipeCatalog(db, 164, "Blacksmithing", api)
        cold[sample], coldDates = (os.clock() - start) * 1000, dates
        assert(first.state == "ready" and #first.recipes == size[2])
        local seen = {}; descriptors = 0
        for _, recipe in ipairs(first.recipes) do
            for _, owner in ipairs(recipe.knownBy) do
                if not seen[owner] then seen[owner] = true; descriptors = descriptors + 1 end
            end
        end
        dates = 0
        collectgarbage("collect")
        start = os.clock()
        local second = G.BuildProfessionRecipeCatalog(db, 164, "Blacksmithing", api)
        warm[sample], warmDates, reused = (os.clock() - start) * 1000, dates, first == second
        assert(#second.recipes == size[2])
    end
    print(string.format("%dx%d: cold=%.3fms warm=%.3fms coldDates=%d warmDates=%d ownerDescriptors=%d sameModel=%s",
        size[1], size[2], median(cold), median(warm), coldDates, warmDates, descriptors, tostring(reused)))
end
