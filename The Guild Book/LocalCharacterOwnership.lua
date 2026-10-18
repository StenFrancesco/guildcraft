local _, GGM = ...

function GGM.RecordLocalPlayerOwnership(api, db)
    if type(api) ~= "table" or type(api.UnitGUID) ~= "function" then
        return false, "player-guid-unavailable"
    end

    local guidOk, guid = pcall(api.UnitGUID, "player")
    if not guidOk or not GGM.IsProfessionGUID(guid) then
        return false, "player-guid-unavailable"
    end

    return GGM.MarkLocalCharacterGUID(db, guid)
end
