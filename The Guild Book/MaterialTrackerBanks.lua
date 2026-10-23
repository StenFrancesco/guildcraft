local _, GGM = ...

local function public(api, value)
    if type(api.issecretvalue) ~= "function" then return false end
    local ok, secret = pcall(api.issecretvalue, value)
    return ok and secret == false
end

local function field(api, object, key)
    if not public(api, object) or type(object) ~= "table" then return nil end
    local value = rawget(object, key)
    if public(api, value) then return value end
end

local function integer(value, minimum, maximum)
    return type(value) == "number" and value >= minimum and value <= maximum
        and value == math.floor(value)
end

local function label(value)
    return type(value) == "string" and #value > 0 and #value <= 512
end

function GGM.GetMaterialBankPlayerKey(api)
    if type(api.UnitFullName) ~= "function" then return nil end
    local ok, name, realm = pcall(api.UnitFullName, "player")
    if not ok or not public(api, name) or not label(name) or not public(api, realm) then return nil end
    if not label(realm) and type(api.GetRealmName) == "function" then
        local realmOK, fallback = pcall(api.GetRealmName)
        if not realmOK or not public(api, fallback) then return nil end
        realm = fallback
    end
    if label(realm) then return name .. "-" .. realm end
end

-- A tab is atomic: a malformed slot must not turn a partial scan into a
-- believable total. Incomplete tabs can retain old slots, so never count them.
local function tabCounts(api, tab, id)
    if not public(api, id) or not integer(id, 1, 2147483647)
        or field(api, tab, "id") ~= id or not label(field(api, tab, "name"))
        or field(api, tab, "status") ~= "cached" then return nil end
    local size, capturedAt = field(api, tab, "numSlots"), field(api, tab, "capturedAt")
    local slots = field(api, tab, "slots")
    if not integer(size, 0, 200) or not integer(capturedAt, 0, 9007199254740991)
        or type(slots) ~= "table" then return nil end
    local counts = {}
    for slotID, slot in pairs(slots) do
        if not public(api, slotID) or not integer(slotID, 1, size) then return nil end
        local itemID, count = field(api, slot, "itemID"), field(api, slot, "count")
        if not integer(itemID, 1, 2147483647) or not integer(count, 1, 2147483647) then return nil end
        counts[itemID] = (counts[itemID] or 0) + count
    end
    return counts, capturedAt
end

local function characterBank(api, record, key)
    local identity = field(api, record, "identity")
    local name, realm = field(api, identity, "name"), field(api, identity, "realm")
    if not public(api, key) or not label(key) or not label(name) or not label(realm)
        or key ~= name .. "-" .. realm or field(api, identity, "key") ~= key then return nil end
    local result = { key = key, counts = {}, partial = field(api, record, "status") ~= "cached" }
    local tabs = field(api, record, "tabs")
    if type(tabs) ~= "table" or next(tabs) == nil then result.partial = true; return result end
    for id, tab in pairs(tabs) do
        local counts, capturedAt = tabCounts(api, tab, id)
        if not counts then result.partial = true
        else
            -- Use the oldest contributing observation, not the record's newest
            -- tab timestamp, so mixed-age bank data is never presented as fresh.
            result.capturedAt = math.min(result.capturedAt or capturedAt, capturedAt)
            for itemID, count in pairs(counts) do
                result.counts[itemID] = (result.counts[itemID] or 0) + count
            end
        end
    end
    return result
end

local function isLocalCharacter(key, record)
    local db = GGM.db
    if type(db) ~= "table" or type(GGM.IsLocalCharacterGUID) ~= "function" then return false end

    local identity = type(record) == "table" and record.identity or nil
    local guid = type(identity) == "table" and identity.guid or nil
    if type(guid) ~= "string" or guid == "" then
        local sharedCharacters = db.characters
        local sharedRecord = type(sharedCharacters) == "table" and rawget(sharedCharacters, key) or nil
        local sharedIdentity = type(sharedRecord) == "table" and sharedRecord.identity or nil
        guid = type(sharedIdentity) == "table" and sharedIdentity.guid or nil
    end
    return GGM.IsLocalCharacterGUID(db, guid)
end

local function readBanks(api, bankDB)
    local characters = field(api, bankDB, "characters")
    if field(api, bankDB, "schemaVersion") ~= 1 or type(characters) ~= "table" then
        return {}, "unavailable"
    end
    local banks, malformed = {}, false
    -- Deliberately read only the local characters bucket; guild bank contents
    -- and guild membership have no role in this view.
    for key, record in pairs(characters) do
        if isLocalCharacter(key, record) then
            local bank = characterBank(api, record, key)
            if bank then banks[#banks + 1] = bank else malformed = true end
        end
    end
    table.sort(banks, function(a, b) return a.key < b.key end)
    return banks, malformed and "partial" or (#banks > 0 and "available" or "empty")
end

local function locationsForItems(banks, ids)
    local locations = {}
    for _, bank in ipairs(banks) do
        local count = 0
        for itemID in pairs(ids) do count = count + (bank.counts[itemID] or 0) end
        if count > 0 or bank.partial then
            locations[#locations + 1] = { key = bank.key,
                count = (count > 0 or not bank.partial) and count or nil,
                partial = bank.partial, capturedAt = bank.capturedAt }
        end
    end
    return locations
end

-- Recipe details need individual item quantities, including optional items,
-- rather than the tracker's combined required-material groups. Scan banks once.
function GGM.BuildMaterialBankItemLocations(api, itemIDs, bankDB)
    local banks, status = readBanks(api, bankDB)
    local locations = {}
    for itemID in pairs(itemIDs) do
        if public(api, itemID) and integer(itemID, 1, 2147483647) then
            locations[itemID] = locationsForItems(banks, { [itemID] = true })
        end
    end
    return locations, status
end

function GGM.BuildMaterialBankLocations(api, snapshot, bankDB)
    local saved = GGM.ValidateMaterialTrackingSnapshot(api, snapshot)
    local rows = {}
    if not saved then return rows, "unavailable" end
    for index in ipairs(saved.materials) do rows[index] = {} end
    local banks, status = readBanks(api, bankDB)
    for index, group in ipairs(saved.materials) do
        local ids = {}
        for _, choice in ipairs(group.choices) do
            if choice.itemID then ids[choice.itemID] = true end
        end
        if next(ids) then
            rows[index] = locationsForItems(banks, ids)
        end
    end
    return rows, status
end
