local _, GGM = ...

local function readGearDatabase(api)
    local companion = rawget(api, "DysgearMemoryAPI")
    if type(companion) ~= "table" then
        return nil, rawget(api, "DysgearMemoryError") or "gear-companion-missing"
    end
    local schemaVersion = rawget(companion, "schemaVersion")
    local getDatabase = rawget(companion, "GetDatabase")
    local getBackend = rawget(companion, "GetBackend")
    if schemaVersion ~= 2 or type(getDatabase) ~= "function" or type(getBackend) ~= "function" then
        return nil, "gear-companion-unsupported"
    end
    if type(GGM.AttachGearBackend) ~= "function" then
        return nil, "gear-backend-incompatible"
    end

    GGM.gearBackend = nil
    local backendCallOk, backend = pcall(getBackend)
    if not backendCallOk then
        return nil, "gear-backend-call-failed"
    end
    local backendAttached, backendErr = GGM.AttachGearBackend(backend)
    if not backendAttached then
        return nil, backendErr
    end

    local ok, database = pcall(getDatabase)
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
    local gearDatabase = gear
    local gearUnavailableReason = gearErr
    local view = {}
    local function updateGearDatabase(database, unavailableReason)
        gearDatabase = database
        gearUnavailableReason = unavailableReason
    end

    setmetatable(view, {
        __index = function(_, key)
            if key == "gearUnavailableReason" then
                return gearUnavailableReason
            end
            if key == "characters" or key == "localCharacters" then
                return gearDatabase and gearDatabase[key] or nil
            end
            return professions[key]
        end,
        __newindex = function(_, key, value)
            if key == "gearUnavailableReason" then
                gearUnavailableReason = value
                return
            end
            if key == "characters" or key == "localCharacters" then
                if gearDatabase then gearDatabase[key] = value end
            else
                professions[key] = value
            end
        end,
    })
    return view, updateGearDatabase
end

function GGM.RefreshGearDatabase(api)
    local gear, gearErr = readGearDatabase(api or _G)
    if type(GGM.updateRuntimeGearDatabase) == "function" then
        GGM.updateRuntimeGearDatabase(gear, gearErr)
    end
    GGM.gearDB = gear
    GGM.gearStartupError = gearErr
    return gear, gearErr
end

function GGM.InitializeSavedDatabases(api)
    local professions = api.TheGuildBookDB
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
    local runtime, updateGearDatabase = runtimeDatabase(professions, gear, gearErr)
    return runtime, nil, professions, gear, gearErr, updateGearDatabase
end
