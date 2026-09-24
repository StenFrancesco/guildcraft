local _, GGM = ...

local function nonEmptyString(value)
    return type(value) == "string" and value ~= ""
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

    return {
        key = name .. "-" .. realm,
        name = name,
        realm = realm,
        guid = api.UnitGUID("player"),
    }, nil
end
