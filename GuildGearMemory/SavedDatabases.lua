local _, GGM = ...

local function readGearDatabase(api)
    local companion = api.DysgearMemoryAPI
    if type(companion) ~= "table" then
        return nil, api.DysgearMemoryError or "gear-companion-missing"
    end
    if companion.schemaVersion ~= 2 or type(companion.GetDatabase) ~= "function" or type(companion.GetBackend) ~= "function" then
        return nil, "gear-companion-unsupported"
    end
    local ok, database = pcall(companion.GetDatabase)
    if not ok or type(database) ~= "table" then return nil, "gear-database-unavailable" end
    if database.schemaVersion ~= GGM.SCHEMA_VERSION then
        return nil, "unsupported-gear-schema-version:" .. tostring(database.schemaVersion)
    end
    if type(database.characters) ~= "table" or type(database.localCharacters) ~= "table" then
        return nil, "gear-database-invalid"
    end
    return database, nil
end

local function runtimeDatabase(professions, gear, gearErr)
    -- Never save this view. Only the two concrete databases are SavedVariables.
    -- Keeping routing here lets presentation and profession membership use a view
    -- without duplicating gear in the profession SavedVariables.
    return setmetatable({ gearUnavailableReason = gearErr }, {
        __index = function(_, key)
            if key == "characters" or key == "localCharacters" then
                return gear and gear[key] or nil
            end
            return professions[key]
        end,
        __newindex = function(_, key, value)
            if key == "characters" or key == "localCharacters" then
                if gear then gear[key] = value end
            else
                professions[key] = value
            end
        end,
    })
end

function GGM.InitializeSavedDatabases(api)
    local professions = api.GuildGearMemoryDB
    if professions == nil then
        local err
        professions, err = GGM.InitializeDatabase(nil)
        if not professions then return nil, err end
    elseif type(professions) ~= "table" then
        return nil, "database-invalid"
    end

    local gear, gearErr = readGearDatabase(api)
    local valid, err = GGM.InitializeDatabase(professions)
    if not valid then return nil, err end

    -- Deliberately no migration: the user requested a fresh gear database.
    -- Only remove legacy fields after the profession schema passes validation.
    professions.characters = nil
    professions.localCharacters = nil
    return runtimeDatabase(professions, gear, gearErr), nil, professions, gear, gearErr
end
