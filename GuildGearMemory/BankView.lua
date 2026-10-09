local _, GGM = ...

local BANK_SCHEMA_VERSION = 1
local BANK_KEY = "__guild_bank__"
local MAX_BANK_SLOTS = 200
local RECORD_STATES = { cached = true, incomplete = true }
local TAB_STATES = { cached = true, incomplete = true, unavailable = true }

local function isInteger(value, minimum, maximum)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge and value == math.floor(value)
        and value >= minimum and (not maximum or value <= maximum)
end

local function validTimestamp(value, optional)
    return (optional and value == nil) or isInteger(value, 1)
end

local function validItemLink(link, itemID)
    if link == nil then return true end
    if type(link) ~= "string" then return false end
    local payload = link
    -- Retail item links can use named quality colors (|cnIQ2:) as well as hex colors.
    if link:sub(1, 3) == "|cn" then
        payload = link:match("^|cn[%w_]+:(.+)|r$")
        if not payload then return false end
    elseif link:sub(1, 2) == "|c" then
        payload = link:match("^|c%x%x%x%x%x%x%x%x(.+)|r$")
        if not payload then return false end
    end
    local linkedID = payload:match("^|Hitem:(%d+)[^|]*|h%[[^%]]*%]|h$")
    return linkedID ~= nil and tonumber(linkedID) == itemID
end

local function validIdentity(identity, key)
    if type(identity) ~= "table" then return false end
    if type(identity.name) ~= "string" or identity.name == "" then return false end
    if type(identity.realm) ~= "string" or identity.realm == "" then return false end
    local expected = identity.name .. "-" .. identity.realm
    return identity.key == expected and (key == nil or key == expected)
end

local function validTab(tab, key)
    if type(tab) ~= "table" or not isInteger(key, 1) or tab.id ~= key then return false end
    if type(tab.name) ~= "string" or tab.name == "" then return false end
    if not isInteger(tab.numSlots, 0, MAX_BANK_SLOTS) then return false end
    if not validTimestamp(tab.capturedAt, true) or not TAB_STATES[tab.status] then return false end
    if tab.status == "cached" and tab.capturedAt == nil then return false end
    if type(tab.slots) ~= "table" then return false end
    for slotID, slot in pairs(tab.slots) do
        if not isInteger(slotID, 1, tab.numSlots) or type(slot) ~= "table"
            or not isInteger(slot.itemID, 1) or not isInteger(slot.count, 1)
            or not validItemLink(slot.itemLink, slot.itemID)
            or (type(slot.icon) == "number" and (slot.icon ~= slot.icon
                or slot.icon == math.huge or slot.icon == -math.huge or slot.icon <= 0))
            or (slot.icon ~= nil and type(slot.icon) ~= "number" and type(slot.icon) ~= "string")
            or (type(slot.icon) == "string" and slot.icon == "") then
            return false
        end
    end
    return true
end

local function validRecord(record, key)
    if type(record) ~= "table" or not validIdentity(record.identity, key) then return false end
    if not RECORD_STATES[record.status] or not validTimestamp(record.capturedAt, true)
        or type(record.tabs) ~= "table" then return false end
    if record.status == "cached" and record.capturedAt == nil then return false end
    local hasObservedTab = false
    local recordTimeObserved = false
    for tabID, tab in pairs(record.tabs) do
        if not validTab(tab, tabID) then return false end
        if tab.capturedAt ~= nil and tab.status ~= "unavailable" then
            hasObservedTab = true
            if tab.capturedAt == record.capturedAt then recordTimeObserved = true end
        end
    end
    return record.status ~= "cached" or (hasObservedTab and recordTimeObserved)
end

local function coverageStatus(record)
    if not record or record.status ~= "cached" then return "incomplete" end
    for _, tab in pairs(record.tabs) do
        if tab.status ~= "cached" or tab.capturedAt == nil then return "incomplete" end
    end
    return "cached"
end

local function getCompanionState()
    local companion = rawget(_G, "DysbankMemoryAPI")
    if type(companion) ~= "table" then return "missing" end
    if companion.schemaVersion ~= BANK_SCHEMA_VERSION then return "unsupported" end
    return "available"
end

local function validBankDatabase(bankDB)
    return type(bankDB) == "table"
        and bankDB.schemaVersion == BANK_SCHEMA_VERSION
        and type(bankDB.characters) == "table"
        and type(bankDB.guilds) == "table"
end

local function identityFromGGMRecord(record, key)
    if type(record) == "table" and validIdentity(record.identity, key) then
        return record.identity
    end
end

local function characterEntries(db, bankDB)
    local byKey = {}
    if type(db) == "table" and db.schemaVersion == GGM.SCHEMA_VERSION and type(db.characters) == "table" then
        for key, record in pairs(db.characters) do
            local identity = identityFromGGMRecord(record, key)
            if identity then byKey[key] = { key = key, identity = identity } end
        end
    end
    if validBankDatabase(bankDB) then
        for key, record in pairs(bankDB.characters) do
            local identity = identityFromGGMRecord(record, key)
            if identity then
                local entry = byKey[key] or { key = key, identity = identity }
                entry.identity = entry.identity or identity
                entry.record = validRecord(record, key) and record or nil
                byKey[key] = entry
            end
        end
    end

    local entries = {}
    for _, entry in pairs(byKey) do
        entry.kind = "character"
        entry.name = entry.identity.name
        entry.realm = entry.identity.realm
        table.insert(entries, entry)
    end
    table.sort(entries, function(left, right)
        local leftName, rightName = string.lower(left.name), string.lower(right.name)
        if leftName ~= rightName then return leftName < rightName end
        local leftRealm, rightRealm = string.lower(left.realm), string.lower(right.realm)
        if leftRealm ~= rightRealm then return leftRealm < rightRealm end
        return left.key < right.key
    end)
    return entries
end

function GGM.BuildBankEntries(db, bankDB, guildIdentity)
    local companionState = getCompanionState()
    local databaseState = bankDB == nil and "missing"
        or (validBankDatabase(bankDB) and "available" or "unsupported")
    local guildEntry = {
        key = BANK_KEY,
        kind = "guild",
        label = "Guild Bank",
        name = "Guild Bank",
        companionState = companionState,
        databaseState = databaseState,
    }
    if validIdentity(guildIdentity) then
        guildEntry.identity = guildIdentity
        guildEntry.guildKey = guildIdentity.key
        if validBankDatabase(bankDB) then
            local candidate = bankDB.guilds[guildIdentity.key]
            if validRecord(candidate, guildIdentity.key) then guildEntry.record = candidate end
        end
    end
    guildEntry.status = guildEntry.record and coverageStatus(guildEntry.record)
        or (databaseState == "available" and "no-data" or databaseState)

    local entries = { guildEntry }
    for _, entry in ipairs(characterEntries(db, bankDB)) do
        entry.companionState = companionState
        entry.databaseState = databaseState
        entry.status = entry.record and coverageStatus(entry.record)
            or (databaseState == "available" and "no-data" or databaseState)
        table.insert(entries, entry)
    end
    return entries
end

local function formatTimestamp(api, timestamp)
    if timestamp == nil then return "Time unavailable" end
    if type(api) == "table" and type(api.date) == "function" then
        local ok, formatted = pcall(api.date, "%Y-%m-%d %H:%M:%S", timestamp)
        if ok and type(formatted) == "string" then return formatted end
    end
    return tostring(timestamp)
end

local function tabStatusText(tab)
    if tab.status == "cached" then return "Cached" end
    if tab.status == "incomplete" then return "Incomplete" end
    return "Unavailable"
end

local function buildTabDetail(tab, api)
    local observed = tab.capturedAt ~= nil
    local slots = {}
    if tab.status ~= "unavailable" then
        for slotID = 1, tab.numSlots do
            local saved = tab.slots[slotID]
            local item = observed and saved or nil
            table.insert(slots, {
                id = slotID,
                itemID = item and item.itemID or nil,
                itemLink = item and item.itemLink or nil,
                icon = item and item.icon or nil,
                count = item and item.count or nil,
                empty = observed and saved == nil,
                observed = observed,
                statusText = not observed and "Not observed" or (saved and nil or "Empty"),
            })
        end
    end
    return {
        id = tab.id,
        name = tab.name,
        numSlots = tab.numSlots,
        capturedAt = tab.capturedAt,
        capturedAtText = formatTimestamp(api, tab.capturedAt),
        status = tab.status,
        statusText = tabStatusText(tab),
        observed = observed,
        slots = slots,
    }
end

function GGM.BuildBankDetail(entry, api)
    api = type(api) == "table" and api or {}
    if type(entry) ~= "table" then
        return { hasRecord = false, emptyStateText = "No bank snapshot" }
    end
    local record = entry.record
    if not validRecord(record) then return { hasRecord = false, emptyStateText = "No bank snapshot" } end
    local tabs = {}
    local hasIncompleteTab = false
    for _, tab in pairs(record.tabs) do
        local tabDetail = buildTabDetail(tab, api)
        if tab.status ~= "cached" or not tabDetail.observed then hasIncompleteTab = true end
        table.insert(tabs, tabDetail)
    end
    table.sort(tabs, function(left, right) return left.id < right.id end)
    local selectedTab
    for _, tab in ipairs(tabs) do
        if tab.status ~= "unavailable" then selectedTab = tab; break end
    end
    selectedTab = selectedTab or tabs[1]
    return {
        hasRecord = true,
        key = entry.key,
        kind = entry.kind,
        name = entry.kind == "guild" and "Guild Bank" or record.identity.name,
        realm = record.identity.realm,
        capturedAt = record.capturedAt,
        capturedAtText = formatTimestamp(api, record.capturedAt),
        status = record.status,
        completenessText = record.status == "cached" and not hasIncompleteTab and "Cached" or "Incomplete",
        tabs = tabs,
        selectedTabID = selectedTab and selectedTab.id or nil,
        slots = selectedTab and selectedTab.slots or {},
        emptyStateText = #tabs == 0 and "No observed bank tabs" or nil,
    }
end
