local _, GGM = ...

local function nonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function senderIdentity(api, sender)
    if not nonEmptyString(sender) then return nil, "profession-sender-invalid" end

    local name, realm = sender:match("^(.+)%-(.+)$")
    if not name then
        name = sender
        if type(api) == "table" and type(api.GetRealmName) == "function" then
            local ok, currentRealm = pcall(api.GetRealmName)
            if ok then realm = currentRealm end
        end
    end

    if not nonEmptyString(name) or not nonEmptyString(realm) then
        return nil, "profession-sender-identity-unavailable"
    end

    return {
        key = name .. "-" .. realm,
        name = name,
        realm = realm,
    }, nil
end

function GGM.ExtractProfessionTradeLinks(message)
    local links = {}
    if type(message) ~= "string" then return links end

    for link in message:gmatch("|H(trade:[^|]+)|h") do
        table.insert(links, link)
    end
    return links
end

function GGM.CreateProfessionLinkSaveController(api, db)
    return {
        api = api,
        db = db,
        sourceByLink = {},
        activeLink = nil,
        activeIdentity = nil,
        button = nil,
        status = nil,
    }
end

function GGM.ObserveGuildProfessionMessage(controller, message, sender)
    if type(controller) ~= "table" then return nil, "profession-controller-invalid" end
    local links = GGM.ExtractProfessionTradeLinks(message)
    if #links == 0 then return "ignored", nil end

    local identity, identityErr = senderIdentity(controller.api, sender)
    if not identity then return nil, identityErr end

    for _, link in ipairs(links) do
        controller.sourceByLink[link] = { identity = identity }
    end
    return "observed", nil
end
