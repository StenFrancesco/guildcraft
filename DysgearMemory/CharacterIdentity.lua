local _, GGM = ...

local function nonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function positiveInteger(value)
    return type(value) == "number" and value > 0 and value == math.floor(value)
end

local function observedModelIdentity(api)
    local raceID
    local sex

    if type(api.UnitRace) == "function" and type(api.UnitSex) == "function" then
        local raceOk, _, _, observedRaceID = pcall(api.UnitRace, "player")
        local sexOk, observedSex = pcall(api.UnitSex, "player")
        if raceOk and sexOk then
            local pairOk, pairValid = pcall(function()
                return positiveInteger(observedRaceID)
                    and (observedSex == 2 or observedSex == 3)
            end)
            if pairOk and pairValid then
                raceID, sex = observedRaceID, observedSex
            end
        end
    end

    local displayID
    if type(api.UnitDisplayID) == "function" then
        local displayOk, observedDisplayID = pcall(api.UnitDisplayID, "player")
        if displayOk then
            local displayValidOk, displayValid = pcall(positiveInteger, observedDisplayID)
            if displayValidOk and displayValid then
                displayID = observedDisplayID
            end
        end
    end

    return raceID, sex, displayID
end

function GGM.BuildPlayerIdentity(api)
    local name, realm = api.UnitFullName("player")

    if not nonEmptyString(name) then
        return nil, "player-name-unavailable"
    end

    if not nonEmptyString(realm) then
        realm = api.GetRealmName()
    end

    if not nonEmptyString(realm) then
        return nil, "player-realm-unavailable"
    end

    local raceID, sex, displayID = observedModelIdentity(api)

    return {
        key = name .. "-" .. realm,
        name = name,
        realm = realm,
        guid = api.UnitGUID("player"),
        raceID = raceID,
        sex = sex,
        displayID = displayID,
    }, nil
end
