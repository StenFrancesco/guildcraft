local _, GGM = ...

local function positiveInteger(value)
    return type(value) == "number"
        and value > 0
        and value < math.huge
        and value == math.floor(value)
end

local function validCache(cache)
    return type(cache) == "table"
        and type(cache.db) == "table"
        and type(cache.db.professionRecipeIndex) == "table"
        and type(cache.db.professionCharacters) == "table"
        and type(cache.byCharacter) == "table"
        and type(cache.readySlices) == "table"
        and type(cache.warmup) == "table"
end

local function clearSlice(cache, localID, professionID)
    local character = cache.byCharacter[localID]
    if type(character) ~= "table" then return end

    character[professionID] = nil
    if next(character) == nil then
        cache.byCharacter[localID] = nil
    end
end

local function ensureSlice(cache, localID, professionID)
    local character = cache.byCharacter[localID]
    if type(character) ~= "table" then
        character = {}
        cache.byCharacter[localID] = character
    end

    local slice = character[professionID]
    if type(slice) ~= "table" then
        slice = {}
        character[professionID] = slice
    end
    return slice
end

local function markSliceReady(cache, localID, professionID)
    local ready = cache.readySlices[localID]
    if type(ready) ~= "table" then
        ready = {}
        cache.readySlices[localID] = ready
    end
    ready[professionID] = true
end

local function markSliceNotReady(cache, localID, professionID)
    local ready = cache.readySlices[localID]
    if type(ready) ~= "table" then return end

    ready[professionID] = nil
    if next(ready) == nil then
        cache.readySlices[localID] = nil
    end
end

local function sliceIsReady(cache, localID, professionID)
    local ready = cache.readySlices[localID]
    return type(ready) == "table" and ready[professionID] == true
end

local function addRecipe(cache, localID, professionID, recipeID, recipeName)
    local slice = ensureSlice(cache, localID, professionID)
    slice[recipeID] = recipeName
end

local function recipeHasCrafter(recipe, localID)
    if type(recipe) ~= "table" or type(recipe.crafters) ~= "table" then
        return false
    end

    for _, candidateID in ipairs(recipe.crafters) do
        if candidateID == localID then return true end
        if type(candidateID) == "number" and candidateID > localID then
            return false
        end
    end
    return false
end

local function rebuildSlice(cache, localID, professionID)
    markSliceNotReady(cache, localID, professionID)
    clearSlice(cache, localID, professionID)

    local profession = cache.db.professionRecipeIndex[professionID]
    if profession ~= nil and type(profession) ~= "table" then
        return false, "profession-character-cache-source-invalid"
    end

    if type(profession) == "table" then
        for recipeID, recipe in pairs(profession) do
            if not positiveInteger(recipeID)
                or type(recipe) ~= "table"
                or type(recipe.name) ~= "string"
                or recipe.name == ""
                or type(recipe.crafters) ~= "table" then
                return false, "profession-character-cache-source-invalid"
            end

            if recipeHasCrafter(recipe, localID) then
                addRecipe(cache, localID, professionID, recipeID, recipe.name)
            end
        end
    end

    markSliceReady(cache, localID, professionID)
    return true, nil
end

function GGM.CreateProfessionCharacterCache(db)
    if type(db) ~= "table"
        or type(db.professionRecipeIndex) ~= "table"
        or type(db.professionCharacters) ~= "table" then
        return nil, "profession-character-cache-invalid"
    end

    return {
        db = db,
        byCharacter = {},
        readySlices = {},
        revision = 0,
        warmup = {
            running = false,
            complete = false,
            error = nil,
            seenRevision = 0,
            professionID = nil,
            profession = nil,
            recipeID = nil,
            recipe = nil,
            crafterPosition = 1,
        },
    }, nil
end

local DEFAULT_WARMUP_BUDGET = 64

local function resetWarmupCursor(cache)
    local warmup = cache.warmup
    cache.byCharacter = {}
    cache.readySlices = {}
    warmup.complete = false
    warmup.error = nil
    warmup.seenRevision = cache.revision
    warmup.professionID = nil
    warmup.profession = nil
    warmup.recipeID = nil
    warmup.recipe = nil
    warmup.crafterPosition = 1
end

local function safeNext(source, key)
    local ok, nextKey, value = pcall(next, source, key)
    return ok, nextKey, value
end

local function selectNextRecipe(cache)
    local warmup = cache.warmup
    local catalog = cache.db.professionRecipeIndex

    while true do
        if type(warmup.profession) == "table" then
            local ok, recipeID, recipe =
                safeNext(warmup.profession, warmup.recipeID)

            if not ok then
                warmup.recipeID = nil
                warmup.recipe = nil
                warmup.crafterPosition = 1
            elseif recipeID ~= nil then
                if not positiveInteger(recipeID)
                    or type(recipe) ~= "table"
                    or type(recipe.name) ~= "string"
                    or recipe.name == ""
                    or type(recipe.crafters) ~= "table" then
                    return false, "profession-character-cache-source-invalid"
                end

                warmup.recipeID = recipeID
                warmup.recipe = recipe
                warmup.crafterPosition = 1
                return true, nil
            else
                warmup.profession = nil
                warmup.recipeID = nil
                warmup.recipe = nil
                warmup.crafterPosition = 1
            end
        else
            local ok, professionID, profession =
                safeNext(catalog, warmup.professionID)

            if not ok then
                warmup.professionID = nil
            elseif professionID == nil then
                warmup.complete = true
                return false, nil
            elseif not positiveInteger(professionID)
                or type(profession) ~= "table" then
                return false, "profession-character-cache-source-invalid"
            else
                warmup.professionID = professionID
                warmup.profession = profession
                warmup.recipeID = nil
            end
        end
    end
end

function GGM.StepProfessionCharacterCacheWarmup(cache, budget)
    if not validCache(cache) then
        return false, "profession-character-cache-invalid", 0
    end

    budget = budget or DEFAULT_WARMUP_BUDGET
    if not positiveInteger(budget) then
        return false, "profession-character-cache-budget-invalid", 0
    end

    if cache.warmup.complete then
        return true, nil, 0
    end

    if cache.warmup.seenRevision ~= cache.revision then
        resetWarmupCursor(cache)
    end

    local processed = 0

    while processed < budget do
        local warmup = cache.warmup

        if warmup.recipe == nil then
            local found, selectErr = selectNextRecipe(cache)
            if selectErr then
                warmup.error = selectErr
                return false, selectErr, processed
            end
            if not found then
                return true, nil, processed
            end
        end

        local recipe = warmup.recipe
        local localID = recipe.crafters[warmup.crafterPosition]

        if localID == nil then
            warmup.recipe = nil
            warmup.crafterPosition = 1
        else
            if not positiveInteger(localID)
                or type(cache.db.professionCharacters[localID]) ~= "table" then
                warmup.error = "profession-character-cache-source-invalid"
                return false, warmup.error, processed
            end

            addRecipe(
                cache,
                localID,
                warmup.professionID,
                warmup.recipeID,
                recipe.name
            )
            warmup.crafterPosition = warmup.crafterPosition + 1
            processed = processed + 1
        end
    end

    return false, nil, processed
end

function GGM.StartProfessionCharacterCacheWarmup(cache, schedule, budget)
    if not validCache(cache) then
        return false, "profession-character-cache-invalid"
    end
    if type(schedule) ~= "function" then
        return false, "profession-character-cache-scheduler-invalid"
    end
    if cache.warmup.complete or cache.warmup.running then
        return true, nil
    end

    cache.warmup.running = true
    local immediateErr

    local function runChunk()
        local complete, err =
            GGM.StepProfessionCharacterCacheWarmup(cache, budget)

        if err then
            cache.warmup.running = false
            cache.warmup.error = err
            immediateErr = immediateErr or err
            return
        end

        if complete then
            cache.warmup.running = false
            cache.warmup.error = nil
            return
        end

        local scheduled = pcall(schedule, runChunk)
        if not scheduled then
            cache.warmup.running = false
            cache.warmup.error = "profession-character-cache-schedule-failed"
            immediateErr = immediateErr
                or "profession-character-cache-schedule-failed"
        end
    end

    runChunk()

    if immediateErr then return false, immediateErr end
    return true, nil
end

function GGM.GetCharacterProfessionRecipes(cache, localID, professionID)
    if not validCache(cache) then
        return nil, "profession-character-cache-invalid"
    end
    if not positiveInteger(localID) or not positiveInteger(professionID) then
        return nil, "profession-character-cache-query-invalid"
    end
    if type(cache.db.professionCharacters[localID]) ~= "table" then
        return nil, "profession-character-cache-character-missing"
    end

    if cache.warmup.complete ~= true
        and not sliceIsReady(cache, localID, professionID) then
        local built, buildErr = rebuildSlice(cache, localID, professionID)
        if not built then return nil, buildErr end
    end

    local character = cache.byCharacter[localID]
    local slice = type(character) == "table" and character[professionID] or nil
    local results = {}

    if type(slice) == "table" then
        for recipeID, name in pairs(slice) do
            results[#results + 1] = {
                recipeID = recipeID,
                name = name,
            }
        end
    end

    table.sort(results, function(left, right)
        return left.recipeID < right.recipeID
    end)
    return results, nil
end

function GGM.UpdateProfessionCharacterCacheFromCapture(cache, localID, capture)
    if not validCache(cache) then
        return false, "profession-character-cache-invalid"
    end
    if not positiveInteger(localID)
        or type(cache.db.professionCharacters[localID]) ~= "table" then
        return false, "profession-character-cache-character-missing"
    end

    local valid, captureErr = GGM.ValidateProfessionCapture(capture)
    if not valid then return false, captureErr end

    if cache.warmup.complete ~= true then
        cache.revision = cache.revision + 1
    end

    local rebuilt, rebuildErr = rebuildSlice(
        cache,
        localID,
        capture.professionID
    )

    if not rebuilt then return false, rebuildErr end
    return true, nil
end
