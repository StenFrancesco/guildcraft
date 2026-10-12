local _, GGM = ...

function GGM.BuildPlayerIdentity(api)
    if GGM.gearBackend then return GGM.gearBackend.BuildPlayerIdentity(api) end
    local name, realm = api.UnitFullName("player")
    if type(name) ~= "string" or name == "" then return nil, "player-name-unavailable" end
    if type(realm) ~= "string" or realm == "" then realm = api.GetRealmName() end
    if type(realm) ~= "string" or realm == "" then return nil, "player-realm-unavailable" end
    return { key = name .. "-" .. realm, name = name, realm = realm, guid = api.UnitGUID("player") }, nil
end
