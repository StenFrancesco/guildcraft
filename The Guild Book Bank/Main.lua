local ADDON_NAME, BankMemory = ...
local addon = _G

local frame = CreateFrame("Frame")
local controller
local flushGeneration = 0

local events = {
    "ADDON_LOADED",
    "PLAYER_LOGIN",
    "PLAYER_ENTERING_WORLD",
    "BANKFRAME_OPENED",
    "BANKFRAME_CLOSED",
    "PLAYERBANKSLOTS_CHANGED",
    "BAG_UPDATE",
    "BAG_UPDATE_DELAYED",
    "BANK_TABS_CHANGED",
    "BANK_TAB_SETTINGS_UPDATED",
    "GUILDBANKFRAME_OPENED",
    "GUILDBANKFRAME_CLOSED",
    "GUILDBANK_UPDATE_TABS",
    "GUILDBANKBAGSLOTS_CHANGED",
    "PLAYER_REGEN_ENABLED",
}

for _, event in ipairs(events) do
    frame:RegisterEvent(event)
end

local function notifyMainAddon()
    local callback = addon.GuildGearMemoryBankChanged
    if type(callback) == "function" then
        pcall(callback)
    end
end

local function publishAPI()
    addon.DysbankMemoryAPI = {
        schemaVersion = 1,
        GetDatabase = function()
            return addon.TheGuildBookBankDB
        end,
    }
end

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        local addonLoadedName = ...
        if addonLoadedName ~= ADDON_NAME then
            return
        end

        if controller then
            flushGeneration = flushGeneration + 1
            frame:SetScript("OnUpdate", nil)
            controller:CancelPending()
            controller = nil
        end
        local database, err = BankMemory.InitializeDatabase(addon.TheGuildBookBankDB)
        if not database then
            addon.DysbankMemoryError = err
            addon.DysbankMemoryAPI = nil
            return
        end

        addon.TheGuildBookBankDB = database
        addon.DysbankMemoryError = nil
        local newController, controllerErr = BankMemory.CreateController(
            addon,
            database,
            notifyMainAddon,
            function()
                flushGeneration = flushGeneration + 1
                local generation, owner = flushGeneration, controller
                frame:SetScript("OnUpdate", function()
                    if generation ~= flushGeneration or owner ~= controller then return end
                    flushGeneration = flushGeneration + 1
                    frame:SetScript("OnUpdate", nil)
                    owner:FlushPending()
                end)
            end
        )
        if not newController then
            addon.DysbankMemoryError = controllerErr
            addon.DysbankMemoryAPI = nil
            return
        end
        controller = newController
        publishAPI()
        notifyMainAddon()
        return
    end

    if controller then
        controller:HandleEvent(event, ...)
        if not controller.personalQueue and not controller.guildQueue then
            flushGeneration = flushGeneration + 1
            frame:SetScript("OnUpdate", nil)
        end
    end
end)
