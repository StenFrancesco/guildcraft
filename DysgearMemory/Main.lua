local ADDON_NAME = ...
local GEAR_SCHEMA_VERSION = 7

-- This companion owns persistence only. The main addon handles capture and
-- synchronization, using the same permitted APIs and conservative protocol.
local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(_, event, loadedName)
    if event ~= "ADDON_LOADED" or loadedName ~= ADDON_NAME then return end

    local database = DysgearMemoryDB
    local err
    if database == nil then
        database = {
            schemaVersion = GEAR_SCHEMA_VERSION,
            characters = {},
            localCharacters = {},
        }
    elseif type(database) ~= "table" then
        err = "database-invalid"
    elseif database.schemaVersion ~= GEAR_SCHEMA_VERSION then
        err = "unsupported-schema-version:" .. tostring(database.schemaVersion)
    elseif type(database.characters) ~= "table" or type(database.localCharacters) ~= "table" then
        err = "gear-database-invalid"
    end

    DysgearMemoryError = err
    if err then
        DysgearMemoryAPI = nil
        return
    end

    DysgearMemoryDB = database
    DysgearMemoryAPI = {
        schemaVersion = 1,
        GetDatabase = function() return DysgearMemoryDB end,
    }
end)
