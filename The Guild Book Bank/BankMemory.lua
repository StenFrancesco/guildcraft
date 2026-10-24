local _, BankMemory = ...
BankMemory = BankMemory or {}

local SCHEMA_VERSION = 1
-- Guild bank tabs have a fixed 14 by 7 slot grid in the Blizzard UI.
local GUILD_TAB_SLOTS = 98
local MAX_PERSONAL_SLOTS = 200
local MAX_GUILD_TABS = 8
local nextGuildSessionID = 0

local function safeValue(api, value)
    if type(api) ~= "table" or type(api.issecretvalue) ~= "function" then
        return false, "secret-check-unavailable"
    end

    local ok, secret = pcall(api.issecretvalue, value)
    if not ok or type(secret) ~= "boolean" then
        return false, "secret-check-failed"
    end
    if secret then
        return false, "secret-value"
    end

    return true, nil
end

local function safeCall(api, fn, checkedResults, ...)
    if type(fn) ~= "function" then
        return false, "api-unavailable"
    end

    local ok, first, second, third, fourth, fifth, sixth = pcall(fn, ...)
    if not ok then
        return false, "api-failed"
    end

    local results = { first, second, third, fourth, fifth, sixth }
    for index = 1, checkedResults do
        local valueOk, valueErr = safeValue(api, results[index])
        if not valueOk then
            return false, valueErr
        end
    end

    return true, first, second, third, fourth, fifth, sixth
end

local function safeCallSelected(api, fn, checkedIndexes, ...)
    if type(fn) ~= "function" then
        return false, "api-unavailable"
    end

    local ok, first, second, third, fourth, fifth, sixth = pcall(fn, ...)
    if not ok then
        return false, "api-failed"
    end

    local results = { first, second, third, fourth, fifth, sixth }
    for index = 1, #checkedIndexes do
        local valueOk, valueErr = safeValue(api, results[checkedIndexes[index]])
        if not valueOk then
            return false, valueErr
        end
    end

    local selected = {}
    for index = 1, #checkedIndexes do
        selected[index] = results[checkedIndexes[index]]
    end
    return true, selected
end

local function safeField(api, object, key)
    local objectOk, objectErr = safeValue(api, object)
    if not objectOk then
        return false, nil, objectErr
    end
    if type(object) ~= "table" then
        return false, nil, "data-invalid"
    end

    local readOk, value = pcall(rawget, object, key)
    if not readOk then
        return false, nil, "data-unavailable"
    end
    local valueOk, valueErr = safeValue(api, value)
    if not valueOk then
        return false, nil, valueErr
    end

    return true, value, nil
end

local function nonEmptyString(value)
    return type(value) == "string" and value ~= ""
end

local function isInteger(value, minimum, maximum)
    return type(value) == "number"
        and value == math.floor(value)
        and value >= minimum
        and value <= maximum
end

local function validIdentity(identity)
    return type(identity) == "table"
        and nonEmptyString(identity.key)
        and nonEmptyString(identity.name)
        and nonEmptyString(identity.realm)
        and (identity.guid == nil or nonEmptyString(identity.guid))
        and identity.key == identity.name .. "-" .. identity.realm
end

function BankMemory.InitializeDatabase(existing)
    if existing == nil then
        return {
            schemaVersion = SCHEMA_VERSION,
            characters = {},
            guilds = {},
        }, nil
    end

    if type(existing) ~= "table" then
        return nil, "database-invalid"
    end
    if existing.schemaVersion ~= SCHEMA_VERSION then
        local version = existing.schemaVersion
        if type(version) == "number" or type(version) == "string" then
            return nil, "unsupported-schema-version:" .. tostring(version)
        end
        return nil, "unsupported-schema-version"
    end
    if type(existing.characters) ~= "table" then
        return nil, "database-characters-invalid"
    end
    if type(existing.guilds) ~= "table" then
        return nil, "database-guilds-invalid"
    end

    return existing, nil
end

local function validExistingTab(tab, tabID)
    return type(tab) == "table"
        and tab.id == tabID
        and nonEmptyString(tab.name)
        and isInteger(tab.numSlots, 0, MAX_PERSONAL_SLOTS)
        and (tab.status == "cached" or tab.status == "incomplete" or tab.status == "unavailable")
        and type(tab.slots) == "table"
        and (tab.capturedAt == nil or isInteger(tab.capturedAt, 0, 9007199254740991))
end

local function validExistingRecord(record, identity)
    return type(record) == "table"
        and type(record.identity) == "table"
        and record.identity.key == identity.key
        and record.identity.name == identity.name
        and record.identity.realm == identity.realm
        and (record.status == "cached" or record.status == "incomplete")
        and type(record.tabs) == "table"
        and (record.capturedAt == nil or isInteger(record.capturedAt, 0, 9007199254740991))
end

local function ensureRecord(database, bucketName, identity)
    if not validIdentity(identity) then
        return nil, false, "identity-invalid"
    end

    local bucket = database[bucketName]
    local record = rawget(bucket, identity.key)
    if record == nil then
        record = {
            identity = { key = identity.key, name = identity.name, realm = identity.realm, guid = identity.guid },
            capturedAt = nil,
            status = "incomplete",
            tabs = {},
        }
        bucket[identity.key] = record
        return record, true, nil
    end

    if not validExistingRecord(record, identity) then
        return nil, false, "record-invalid-or-identity-mismatch"
    end
    local savedGUID = record.identity.guid
    if savedGUID and identity.guid and savedGUID ~= identity.guid then
        return nil, false, "record-invalid-or-identity-mismatch"
    end
    if not savedGUID and identity.guid then record.identity.guid = identity.guid end
    return record, false, nil
end

local function setIncomplete(tab)
    if type(tab) ~= "table" or tab.status == "incomplete" then
        return false
    end
    tab.status = "incomplete"
    return true
end

local function markAllTabsIncomplete(record)
    local changed = false
    for _, tab in pairs(record.tabs) do
        if setIncomplete(tab) then
            changed = true
        end
    end
    if record.status ~= "incomplete" then
        record.status = "incomplete"
        changed = true
    end
    return changed
end

local function forceRecordIncomplete(record)
    if record.status == "incomplete" then
        return false
    end
    record.status = "incomplete"
    return true
end

local function refreshRecordStatus(record)
    local sawTab = false
    local allCached = true
    for _, tab in pairs(record.tabs) do
        sawTab = true
        if type(tab) ~= "table" or tab.status ~= "cached" then
            allCached = false
        end
    end

    local status = sawTab and allCached and "cached" or "incomplete"
    if record.status ~= status then
        record.status = status
        return true
    end
    return false
end

local function recordForFailure(controller, bucketName, identity)
    local record, created, err = ensureRecord(controller.database, bucketName, identity)
    if not record then
        return nil, false, err
    end
    local changed = created or markAllTabsIncomplete(record)
    if created then
        record.status = "incomplete"
    end
    return record, changed, nil
end

local function notifyChanged(controller, reason, tabID)
    if controller.batching then
        controller.batchChanged = true
        local nextIsSessionTransition = reason == "guild-session-open" or reason == "guild-session-close"
        local batchIsSessionTransition = controller.batchReason == "guild-session-open"
            or controller.batchReason == "guild-session-close"
        if reason and (nextIsSessionTransition or not batchIsSessionTransition) then
            controller.batchReason = reason
        end
        if tabID then controller.batchTabID = tabID end
        return
    end
    if reason == nil then reason = controller.batchReason end
    if tabID == nil then tabID = controller.batchTabID end
    controller.batchReason = nil
    controller.batchTabID = nil
    if type(controller.onChanged) == "function" then
        pcall(controller.onChanged, reason, tabID)
    end
end


local function clearGuildSession(controller, notify)
    local hadSession = controller.guildSessionToken ~= nil
    controller.guildSessionToken = nil
    controller.guildViewableTabIDs = {}
    controller.guildMetadata = nil
    if hadSession and notify then
        notifyChanged(controller, "guild-session-close")
    end
end

local function establishGuildSession(controller, identity, metadata, forceNew)
    if controller.guildSessionGuildKey ~= identity.key then
        clearGuildSession(controller, true)
        controller.guildSessionGuildKey = identity.key
        forceNew = true
    end
    local viewable = {}
    for tabID, descriptor in pairs(metadata.tabs) do
        if descriptor.viewable == true then viewable[tabID] = true end
    end
    if not next(viewable) then
        clearGuildSession(controller, true)
        controller.guildSessionEstablishPending = false
        return false, "guild-no-viewable-tabs"
    end
    local currentOk, currentTab = safeCall(controller.api, controller.api.GetCurrentGuildBankTab, 1)
    if not currentOk or not isInteger(currentTab, 1, metadata.count) or not viewable[currentTab] then
        clearGuildSession(controller, true)
        controller.guildSessionEstablishPending = controller.guildOpen
        return false, currentOk and "guild-current-tab-invalid" or currentTab
    end
    if not controller.guildSessionToken and not controller.guildSessionEstablishPending then
        controller.guildViewableTabIDs = {}
        return false, "guild-session-unavailable"
    end
    if forceNew or not controller.guildSessionToken then
        nextGuildSessionID = nextGuildSessionID + 1
        controller.guildSessionToken = tostring({}) .. ":" .. tostring(nextGuildSessionID)
        controller.guildSessionGuildKey = identity.key
        controller.guildViewableTabIDs = viewable
        controller.guildSessionEstablishPending = false
        notifyChanged(controller, "guild-session-open")
    else
        controller.guildViewableTabIDs = viewable
    end
    return true, nil
end

local function markCaptureFailure(controller, bucketName, identity, err)
    local _, changed = recordForFailure(controller, bucketName, identity)
    if changed then
        notifyChanged(controller)
    end
    return false, err
end

local function markKnownRecordIncomplete(controller, bucketName, identity, database)
    if not validIdentity(identity) then
        return false
    end
    local bucket = (database or controller.database)[bucketName]
    if type(bucket) ~= "table" then
        return false
    end
    local record = rawget(bucket, identity.key)
    if not validExistingRecord(record, identity) then
        return false
    end

    local changed = markAllTabsIncomplete(record)
    if changed then
        notifyChanged(controller)
    end
    return changed
end

local function combatState(api)
    if type(api.issecretvalue) ~= "function" then
        return nil, "secret-check-unavailable"
    end
    local ok, inCombat = safeCall(api, api.InCombatLockdown, 1)
    if not ok then
        return nil, inCombat
    end
    if inCombat ~= false then
        return false, "combat-state-not-explicitly-false"
    end
    return true, nil
end

local function getPlayerIdentity(api)
    local ok, name, realm = safeCall(api, api.UnitFullName, 2, "player")
    if not ok then
        return nil, name
    end
    if not nonEmptyString(name) then
        return nil, "player-name-unavailable"
    end
    if not nonEmptyString(realm) then
        local realmOk, fallbackRealm = safeCall(api, api.GetRealmName, 1)
        if not realmOk then
            return nil, fallbackRealm
        end
        realm = fallbackRealm
    end
    if not nonEmptyString(realm) then
        return nil, "player-realm-unavailable"
    end

    local identity = { key = name .. "-" .. realm, name = name, realm = realm }
    local guidOk, guid = safeCall(api, api.UnitGUID, 1, "player")
    if guidOk and nonEmptyString(guid) then identity.guid = guid end
    return identity, nil
end

local function getGuildIdentity(api)
    local ok, fields = safeCallSelected(api, api.GetGuildInfo, { 1, 4 }, "player")
    if not ok then
        return nil, fields
    end
    local name, guildRealm = fields[1], fields[2]
    if not nonEmptyString(name) then
        return nil, "guild-name-unavailable"
    end

    local realm = guildRealm
    if not nonEmptyString(realm) then
        local realmOk, fallbackRealm = safeCall(api, api.GetRealmName, 1)
        if not realmOk then
            return nil, fallbackRealm
        end
        realm = fallbackRealm
    end
    if not nonEmptyString(realm) then
        return nil, "guild-realm-unavailable"
    end

    return { key = name .. "-" .. realm, name = name, realm = realm }, nil
end

local function getBankType(api, bankTypeName)
    local enumOk, enumErr = safeValue(api, api.Enum)
    if not enumOk or type(api.Enum) ~= "table" then
        return nil, enumErr or "bank-type-unavailable"
    end
    local bankTypes = rawget(api.Enum, "BankType")
    local bankTypesOk, bankTypesErr = safeValue(api, bankTypes)
    if not bankTypesOk or type(bankTypes) ~= "table" then
        return nil, bankTypesErr or "bank-type-unavailable"
    end
    local value = rawget(bankTypes, bankTypeName)
    local valueOk, valueErr = safeValue(api, value)
    if not valueOk then
        return nil, valueErr
    end
    if value == nil then
        return nil, "bank-type-unavailable"
    end
    return value, nil
end

local function optionalIcon(api, icon)
    local iconOk, iconErr = safeValue(api, icon)
    if not iconOk then
        return nil, iconErr
    end
    if icon == nil then
        return nil, nil
    end
    if type(icon) ~= "number" and type(icon) ~= "string" then
        return nil, "icon-invalid"
    end
    if type(icon) == "number" and (icon ~= icon or icon == math.huge or icon == -math.huge) then
        return nil, "icon-invalid"
    end
    return icon, nil
end

local function iconForItem(api, itemID)
    local infoOK, fields = safeCallSelected(api, api.GetItemInfoInstant, { 5 }, itemID)
    if not infoOK then return nil end
    local icon = optionalIcon(api, fields[1])
    return icon
end

local function capturePersonalTab(api, descriptor)
    local containerAPI = api.C_Container
    local containerOk, containerErr = safeValue(api, containerAPI)
    if not containerOk or type(containerAPI) ~= "table" then
        return nil, containerErr or "container-api-unavailable"
    end
    local getSlots = rawget(containerAPI, "GetContainerNumSlots")
    local slotsOk, numSlots = safeCall(api, getSlots, 1, descriptor.id)
    if not slotsOk then
        return nil, numSlots
    end
    if not isInteger(numSlots, descriptor.allowEmpty and 0 or 1, MAX_PERSONAL_SLOTS) then
        return nil, "container-slot-count-invalid"
    end

    local slots = {}
    local getItem = rawget(containerAPI, "GetContainerItemInfo")
    for slotID = 1, numSlots do
        local itemOk, itemInfo = safeCall(api, getItem, 1, descriptor.id, slotID)
        if not itemOk then
            return nil, itemInfo
        end
        if itemInfo ~= nil then
            if type(itemInfo) ~= "table" then
                return nil, "container-item-info-invalid"
            end

            local idOk, itemID, idErr = safeField(api, itemInfo, "itemID")
            local countOk, count, countErr = safeField(api, itemInfo, "stackCount")
            local linkOk, link, linkErr = safeField(api, itemInfo, "hyperlink")
            local iconReadOk, iconValue, iconReadErr = safeField(api, itemInfo, "iconFileID")
            if not idOk then return nil, idErr end
            if not countOk then return nil, countErr end
            if not linkOk then return nil, linkErr end
            if not iconReadOk then return nil, iconReadErr end
            if not isInteger(itemID, 1, 9007199254740991) then
                return nil, "container-item-id-invalid"
            end
            if not isInteger(count, 1, 9007199254740991) then
                return nil, "container-item-count-invalid"
            end
            if link ~= nil and type(link) ~= "string" then
                return nil, "container-item-link-invalid"
            end
            local icon, iconErr = optionalIcon(api, iconValue)
            if iconErr then return nil, iconErr end

            slots[slotID] = {
                itemID = itemID,
                itemLink = link,
                icon = icon,
                count = count,
            }
        end
    end

    local timeOk, capturedAt = safeCall(api, api.time, 1)
    if not timeOk then
        return nil, capturedAt
    end
    if not isInteger(capturedAt, 0, 9007199254740991) then
        return nil, "capture-time-invalid"
    end

    return {
        id = descriptor.id,
        name = descriptor.name,
        numSlots = numSlots,
        capturedAt = capturedAt,
        status = "cached",
        slots = slots,
    }, nil
end

-- Carried inventory is independent of the bank's tabs, status and capture time.
local function captureInventory(controller)
    local api = controller.api
    local function failed(err)
        local identity = controller.lastInventoryIdentity
        local record = identity and rawget(controller.database.characters, identity.key)
        if type(record) == "table" and type(record.inventory) == "table" then
            if setIncomplete(record.inventory) then notifyChanged(controller) end
        end
        return false, err
    end

    local identity, identityErr = getPlayerIdentity(api)
    if not identity then return failed(identityErr) end
    controller.lastInventoryIdentity = identity
    local outOfCombat, combatErr = combatState(api)
    if outOfCombat ~= true then
        controller.inventoryPending = true
        return failed(combatErr)
    end

    -- The total includes the reagent bag on clients that support it. On legacy
    -- clients container 5 can be a bank bag, so only use their normal bag range.
    local lastBag = rawget(api, "NUM_TOTAL_EQUIPPED_BAG_SLOTS")
    local readable, readErr = safeValue(api, lastBag)
    if not readable then return failed(readErr) end
    if lastBag == nil then
        lastBag = rawget(api, "NUM_BAG_SLOTS")
        readable, readErr = safeValue(api, lastBag)
        if not readable then return failed(readErr) end
        if lastBag == nil then lastBag = 4 end
    end
    if not isInteger(lastBag, 0, 5) then return failed("inventory-bag-range-invalid") end

    local bags = {}
    for bagID = 0, lastBag do
        local bag, err = capturePersonalTab(api, {
            id = bagID,
            name = bagID == 0 and "Backpack" or ("Bag " .. tostring(bagID)),
            allowEmpty = bagID ~= 0,
        })
        if not bag then return failed(err) end
        bags[bagID] = bag
    end
    local record, _, recordErr = ensureRecord(controller.database, "characters", identity)
    if not record then return false, recordErr end
    record.inventory = {
        status = "cached",
        capturedAt = bags[0].capturedAt,
        bags = bags,
    }
    controller.inventoryPending = false
    notifyChanged(controller)
    return true, nil
end

local function validatePersonalTabData(api, tabData)
    local tableOk, tableErr = safeValue(api, tabData)
    if not tableOk or type(tabData) ~= "table" then
        return nil, tableErr or "personal-tabs-invalid"
    end
    local lengthOk, length = pcall(function() return #tabData end)
    if not lengthOk or not isInteger(length, 1, MAX_PERSONAL_SLOTS) then
        return nil, "personal-tabs-invalid"
    end

    local descriptors = {}
    local seen = {}
    for index = 1, length do
        local readOk, entry = pcall(rawget, tabData, index)
        if not readOk then
            return nil, "personal-tab-unavailable"
        end
        local entryOk, entryErr = safeValue(api, entry)
        if not entryOk or type(entry) ~= "table" then
            return nil, entryErr or "personal-tab-invalid"
        end

        local idOk, id, idErr = safeField(api, entry, "ID")
        local nameOk, name, nameErr = safeField(api, entry, "name")
        if not idOk then return nil, idErr end
        if not nameOk then return nil, nameErr end
        if not isInteger(id, 1, MAX_PERSONAL_SLOTS) or not nonEmptyString(name) then
            return nil, "personal-tab-invalid"
        end
        if seen[id] then
            return nil, "personal-tab-duplicate"
        end
        seen[id] = true
        descriptors[#descriptors + 1] = { id = id, name = name }
    end
    return descriptors, nil
end

local function setTabIncomplete(record, tabID, name, numSlots, unavailable)
    if not isInteger(tabID, 1, MAX_PERSONAL_SLOTS) then
        return false, "tab-id-invalid"
    end
    local old = rawget(record.tabs, tabID)
    if old ~= nil and not validExistingTab(old, tabID) then
        return false, "existing-tab-invalid"
    end

    local changed = false
    if old then
        if nonEmptyString(name) and old.name ~= name then
            old.name = name
            changed = true
        end
        if isInteger(numSlots, 0, MAX_PERSONAL_SLOTS) and old.numSlots ~= numSlots then
            old.numSlots = numSlots
            changed = true
        end
        local status = unavailable and "unavailable" or "incomplete"
        if old.status ~= status then
            old.status = status
            changed = true
        end
    else
        record.tabs[tabID] = {
            id = tabID,
            name = nonEmptyString(name) and name or ("Tab " .. tostring(tabID)),
            numSlots = isInteger(numSlots, 0, MAX_PERSONAL_SLOTS) and numSlots or 0,
            capturedAt = nil,
            status = unavailable and "unavailable" or "incomplete",
            slots = {},
        }
        changed = true
    end
    return changed, nil
end

local function failPersonalRecord(controller, identity, err)
    return markCaptureFailure(controller, "characters", identity, err)
end

local function capturePersonal(controller, dirtyIDs)
    local api = controller.api
    local outOfCombat, combatErr = combatState(api)
    if outOfCombat ~= true then
        if combatErr == "combat-state-not-explicitly-false" then
            controller.personalPending = true
        end
        markKnownRecordIncomplete(controller, "characters", controller.lastPersonalIdentity)
        return false, combatErr
    end

    local identity, identityErr = getPlayerIdentity(api)
    if not identity then
        return false, identityErr
    end
    controller.lastPersonalIdentity = identity
    local record, created, recordErr = ensureRecord(controller.database, "characters", identity)
    if not record then
        return false, recordErr
    end

    local bankType, bankTypeErr = getBankType(api, "Character")
    if bankType == nil then
        local changed = created or markAllTabsIncomplete(record)
        if changed then notifyChanged(controller) end
        return false, bankTypeErr
    end
    local bankAPI = api.C_Bank
    local bankApiOk, bankApiErr = safeValue(api, bankAPI)
    if not bankApiOk or type(bankAPI) ~= "table" then
        local changed = created or markAllTabsIncomplete(record)
        if changed then notifyChanged(controller) end
        return false, bankApiErr or "bank-api-unavailable"
    end

    local canUseOk, canUse = safeCall(api, rawget(bankAPI, "CanUseBank"), 1, bankType)
    if not canUseOk or canUse ~= true then
        local changed = created or markAllTabsIncomplete(record)
        if changed then notifyChanged(controller) end
        return false, canUseOk and "personal-bank-unavailable" or canUse
    end

    local tabsOk, tabData = safeCall(api, rawget(bankAPI, "FetchPurchasedBankTabData"), 1, bankType)
    if not tabsOk then
        local changed = created or markAllTabsIncomplete(record)
        if changed then notifyChanged(controller) end
        return false, tabData
    end
    local descriptors, descriptorsErr = validatePersonalTabData(api, tabData)
    if not descriptors then
        local changed = created or markAllTabsIncomplete(record)
        if changed then notifyChanged(controller) end
        return false, descriptorsErr
    end

    controller.personalContainerIDs = {}
    local captured = {}
    local failures = {}
    for _, descriptor in ipairs(descriptors) do
        controller.personalContainerIDs[descriptor.id] = true
        if not dirtyIDs or dirtyIDs[descriptor.id] then
            local tab, tabErr = capturePersonalTab(api, descriptor)
            if tab then
                captured[#captured + 1] = tab
            else
                failures[#failures + 1] = { id = descriptor.id, name = descriptor.name, err = tabErr }
            end
        end
    end

    local changed = created
    for _, tab in ipairs(captured) do
        local old = rawget(record.tabs, tab.id)
        if old ~= nil and not validExistingTab(old, tab.id) then
            failures[#failures + 1] = { id = tab.id, name = tab.name, err = "existing-tab-invalid" }
        else
            record.tabs[tab.id] = tab
            record.capturedAt = tab.capturedAt
            changed = true
        end
    end
    for _, failure in ipairs(failures) do
        local marked = setTabIncomplete(record, failure.id, failure.name, nil, false)
        if marked then changed = true end
    end
    if #failures > 0 then
        if forceRecordIncomplete(record) then changed = true end
    elseif refreshRecordStatus(record) then
        changed = true
    end
    if changed then notifyChanged(controller) end

    if #failures > 0 then
        return false, failures[1].err
    end
    return true, nil
end

local function readGuildMetadata(api)
    local countOk, count = safeCall(api, api.GetNumGuildBankTabs, 1)
    if not countOk then
        return nil, count
    end
    if not isInteger(count, 1, MAX_GUILD_TABS) then
        return nil, "guild-tab-count-invalid"
    end

    local tabs = {}
    for tabID = 1, count do
        local nameOk, fields = safeCallSelected(api, api.GetGuildBankTabInfo, { 1, 3 }, tabID)
        if not nameOk then
            return nil, fields
        end
        local name, viewable = fields[1], fields[2]
        if not nonEmptyString(name) or (viewable ~= true and viewable ~= false) then
            return nil, "guild-tab-metadata-invalid"
        end
        tabs[tabID] = { id = tabID, name = name, viewable = viewable }
    end
    return { count = count, tabs = tabs }, nil
end

local function applyGuildMetadata(record, metadata)
    local changed = false
    for tabID, descriptor in pairs(metadata.tabs) do
        local old = rawget(record.tabs, tabID)
        if old ~= nil and not validExistingTab(old, tabID) then
            return false, "existing-tab-invalid"
        end
        local status = descriptor.viewable and (old and old.status == "cached" and "cached" or "incomplete") or "unavailable"
        if old then
            if old.name ~= descriptor.name then old.name = descriptor.name; changed = true end
            if old.numSlots ~= GUILD_TAB_SLOTS then old.numSlots = GUILD_TAB_SLOTS; changed = true end
            if old.status ~= status then old.status = status; changed = true end
        else
            record.tabs[tabID] = {
                id = tabID,
                name = descriptor.name,
                numSlots = GUILD_TAB_SLOTS,
                capturedAt = nil,
                status = status,
                slots = {},
            }
            changed = true
        end
    end

    for tabID, tab in pairs(record.tabs) do
        if not metadata.tabs[tabID] and type(tab) == "table" and tab.status ~= "incomplete" then
            tab.status = "incomplete"
            changed = true
        end
    end
    if refreshRecordStatus(record) then changed = true end
    return changed, nil
end

local function refreshGuildMetadata(controller)
    local api = controller.api
    local outOfCombat, combatErr = combatState(api)
    if outOfCombat ~= true then
        if combatErr == "combat-state-not-explicitly-false" then
            controller.guildMetadataPending = true
        end
        markKnownRecordIncomplete(controller, "guilds", controller.lastGuildIdentity)
        return false, combatErr
    end

    local identity, identityErr = getGuildIdentity(api)
    if not identity then
        clearGuildSession(controller, true)
        if identityErr == "guild-name-unavailable" then
            controller.guildSessionEstablishPending = false
        elseif controller.guildOpen then
            controller.guildSessionEstablishPending = true
        end
        return false, identityErr
    end
    if controller.guildSessionGuildKey and controller.guildSessionGuildKey ~= identity.key then
        clearGuildSession(controller, true)
        controller.guildSessionGuildKey = identity.key
    end
    controller.lastGuildIdentity = identity
    local record, created, recordErr = ensureRecord(controller.database, "guilds", identity)
    if not record then
        return false, recordErr
    end

    local metadata, metadataErr = readGuildMetadata(api)
    if not metadata then
        clearGuildSession(controller, true)
        controller.guildSessionEstablishPending = controller.guildOpen
        local changed = created or markAllTabsIncomplete(record)
        if changed then notifyChanged(controller, "guild-metadata") end
        return false, metadataErr
    end
    local metadataChanged, applyErr = applyGuildMetadata(record, metadata)
    if applyErr then
        clearGuildSession(controller, true)
        controller.guildSessionEstablishPending = controller.guildOpen
        local changed = created or markAllTabsIncomplete(record)
        if changed then notifyChanged(controller, "guild-metadata") end
        return false, applyErr
    end

    local sessionOK, sessionErr = establishGuildSession(controller, identity, metadata, false)
    if not sessionOK and controller.guildOpen then
        clearGuildSession(controller, true)
    end
    controller.guildMetadata = sessionOK and {
        identityKey = identity.key,
        count = metadata.count,
        tabs = metadata.tabs,
    } or nil
    local changed = created or metadataChanged
    if changed then notifyChanged(controller, "guild-metadata") end
    return sessionOK, sessionErr
end

local function parseItemID(itemLink)
    if type(itemLink) ~= "string" then return nil end
    local digits = string.match(itemLink, "item:(%d+)")
    local itemID = digits and tonumber(digits) or nil
    if not isInteger(itemID, 1, 9007199254740991) then return nil end
    return itemID
end

local function captureGuildTab(api, tabID, descriptor)
    local slots = {}
    for slotID = 1, GUILD_TAB_SLOTS do
        local infoOk, iconValue, count = safeCall(api, api.GetGuildBankItemInfo, 2, tabID, slotID)
        if not infoOk then return nil, iconValue end
        local linkOk, itemLink = safeCall(api, api.GetGuildBankItemLink, 1, tabID, slotID)
        if not linkOk then return nil, itemLink end

        local icon, iconErr = optionalIcon(api, iconValue)
        if iconErr then return nil, iconErr end
        if itemLink ~= nil then
            if type(itemLink) ~= "string" then return nil, "guild-item-link-invalid" end
            local itemID = parseItemID(itemLink)
            if not itemID or not isInteger(count, 1, 9007199254740991) then
                return nil, "guild-item-data-invalid"
            end
            slots[slotID] = {
                itemID = itemID,
                itemLink = itemLink,
                icon = icon,
                count = count,
            }
        elseif count ~= nil and count ~= 0 then
            return nil, "guild-empty-slot-invalid"
        elseif icon ~= nil then
            return nil, "guild-empty-slot-invalid"
        end
    end

    local timeOk, capturedAt = safeCall(api, api.time, 1)
    if not timeOk then return nil, capturedAt end
    if not isInteger(capturedAt, 0, 9007199254740991) then
        return nil, "capture-time-invalid"
    end

    return {
        id = tabID,
        name = descriptor.name,
        numSlots = GUILD_TAB_SLOTS,
        capturedAt = capturedAt,
        status = "cached",
        slots = slots,
    }, nil
end

local function captureGuildReady(controller, readyTab)
    local api = controller.api
    if not controller.guildOpen then
        return false, "guild-bank-closed"
    end

    local outOfCombat, combatErr = combatState(api)
    if outOfCombat ~= true then
        if combatErr == "combat-state-not-explicitly-false" then
            controller.guildReadinessDeferred = true
        end
        markKnownRecordIncomplete(controller, "guilds", controller.lastGuildIdentity)
        return false, combatErr
    end

    local identity, identityErr = getGuildIdentity(api)
    if not identity then
        return false, identityErr
    end
    controller.lastGuildIdentity = identity
    local record, created, recordErr = ensureRecord(controller.database, "guilds", identity)
    if not record then
        return false, recordErr
    end

    local currentOk, currentTab = safeCall(api, api.GetCurrentGuildBankTab, 1)
    if not currentOk then
        local changed = created or markAllTabsIncomplete(record)
        if changed then notifyChanged(controller) end
        return false, currentTab
    end
    -- Readiness belongs to the selected tab at event time, never a later selection.
    if readyTab ~= currentTab then return false, "guild-ready-tab-changed" end
    local metadata = controller.guildMetadata
    local descriptor = metadata and metadata.tabs[currentTab]
    if not isInteger(currentTab, 1, metadata and metadata.count or 0) or not descriptor then
        local changed = created or markAllTabsIncomplete(record)
        if changed then notifyChanged(controller) end
        return false, "guild-current-tab-invalid"
    end
    if descriptor.viewable ~= true then
        local changed = setTabIncomplete(record, currentTab, descriptor.name, GUILD_TAB_SLOTS, true)
        if refreshRecordStatus(record) then changed = true end
        if forceRecordIncomplete(record) then changed = true end
        if changed then notifyChanged(controller) end
        return false, "guild-current-tab-unavailable"
    end

    local tab, tabErr = captureGuildTab(api, currentTab, descriptor)
    if not tab then
        local changed = setTabIncomplete(record, currentTab, descriptor.name, GUILD_TAB_SLOTS, false)
        if refreshRecordStatus(record) then changed = true end
        if forceRecordIncomplete(record) then changed = true end
        if changed then notifyChanged(controller) end
        return false, tabErr
    end

    local old = rawget(record.tabs, currentTab)
    if old ~= nil and not validExistingTab(old, currentTab) then
        local changed = setTabIncomplete(record, currentTab, descriptor.name, GUILD_TAB_SLOTS, false)
        if refreshRecordStatus(record) then changed = true end
        if forceRecordIncomplete(record) then changed = true end
        if changed then notifyChanged(controller) end
        return false, "existing-tab-invalid"
    end
    record.tabs[currentTab] = tab
    record.capturedAt = tab.capturedAt
    local changed = true
    if refreshRecordStatus(record) then changed = true end
    if changed then notifyChanged(controller, "guild-capture", currentTab) end
    controller.guildReadinessDeferred = false
    return true, nil
end

-- Pending work belongs to this controller and open session, outside SavedVariables.
local function cancelQueue(controller, kind)
    local queue = controller[kind .. "Queue"]
    controller[kind .. "Queue"] = nil
    if queue then
        markKnownRecordIncomplete(controller, kind == "personal" and "characters" or "guilds", queue.identity, queue.database)
    end
end

local function queueCapture(controller, kind, id)
    local bucket = kind == "personal" and "characters" or "guilds"
    local identity = kind == "personal" and controller.lastPersonalIdentity or controller.lastGuildIdentity
    local outOfCombat, err = combatState(controller.api)
    if outOfCombat ~= true then
        if kind == "personal" then controller.personalPending = true
        else controller.guildReadinessDeferred = true end
        cancelQueue(controller, kind)
        markKnownRecordIncomplete(controller, bucket, identity)
        return false, err
    end
    if not validIdentity(identity) then
        if kind == "personal" then identity = getPlayerIdentity(controller.api)
        else identity = getGuildIdentity(controller.api) end
    end
    local key = kind .. "Queue"
    local queue = controller[key]
    if not queue then
        queue = { ids = {}, identity = identity, database = controller.database }
        controller[key] = queue
    end
    if kind == "personal" then
        if id == nil then queue.full = true else queue.ids[id] = true end
    elseif id then
        queue.ids[id] = true
    end
    if type(controller.requestFlush) == "function" then controller.requestFlush() end
    return true, nil
end


local function copyGuildTab(tab)
    local copy = {
        id = tab.id,
        name = tab.name,
        numSlots = tab.numSlots,
        capturedAt = tab.capturedAt,
        status = tab.status,
        observedSlotCount = GUILD_TAB_SLOTS,
        slots = {},
    }
    for slotID, slot in pairs(tab.slots) do
        copy.slots[slotID] = {
            itemID = slot.itemID,
            itemLink = slot.itemLink,
            icon = slot.icon,
            count = slot.count,
        }
    end
    return copy
end

local function validateGuildSnapshot(api, tabID, snapshot, descriptor, requireObservedSlotCount)
    local snapshotOk, snapshotErr = safeValue(api, snapshot)
    if not snapshotOk or type(snapshot) ~= "table" then
        return nil, snapshotErr or "snapshot-invalid"
    end
    local idOk, id, idErr = safeField(api, snapshot, "id")
    local nameOk, name, nameErr = safeField(api, snapshot, "name")
    local slotsOk, slots, slotsErr = safeField(api, snapshot, "slots")
    local countOk, numSlots, countErr = safeField(api, snapshot, "numSlots")
    local timeOk, capturedAt, timeErr = safeField(api, snapshot, "capturedAt")
    local statusOk, status, statusErr = safeField(api, snapshot, "status")
    if not idOk then return nil, idErr end
    if not nameOk then return nil, nameErr end
    if not slotsOk then return nil, slotsErr end
    if not countOk then return nil, countErr end
    if not timeOk then return nil, timeErr end
    if not statusOk then return nil, statusErr end
    if requireObservedSlotCount then
        local observedOk, observedSlotCount, observedErr = safeField(api, snapshot, "observedSlotCount")
        if not observedOk then return nil, observedErr end
        if observedSlotCount ~= GUILD_TAB_SLOTS then
            return nil, "snapshot-slot-count-incomplete"
        end
    end
    if id ~= tabID or name ~= descriptor.name or numSlots ~= GUILD_TAB_SLOTS
        or status ~= "cached" or not isInteger(capturedAt, 0, 9007199254740991)
        or type(slots) ~= "table" then
        return nil, "snapshot-invalid"
    end

    local clone = {
        id = tabID,
        name = name,
        numSlots = GUILD_TAB_SLOTS,
        capturedAt = capturedAt,
        status = "cached",
        slots = {},
    }
    for slotID, slot in pairs(slots) do
        local keyOk, keyErr = safeValue(api, slotID)
        if not keyOk then return nil, keyErr end
        if not isInteger(slotID, 1, GUILD_TAB_SLOTS) then
            return nil, "snapshot-slot-id-invalid"
        end
        local slotOk, slotErr = safeValue(api, slot)
        if not slotOk or type(slot) ~= "table" then
            return nil, slotErr or "snapshot-slot-invalid"
        end
        local itemIDOk, itemID, itemIDErr = safeField(api, slot, "itemID")
        local linkOk, itemLink, linkErr = safeField(api, slot, "itemLink")
        local itemCountOk, itemCount, itemCountErr = safeField(api, slot, "count")
        local iconOk, iconValue, iconErr = safeField(api, slot, "icon")
        if not itemIDOk then return nil, itemIDErr end
        if not linkOk then return nil, linkErr end
        if not itemCountOk then return nil, itemCountErr end
        if not iconOk then return nil, iconErr end
        if not isInteger(itemID, 1, 9007199254740991)
            or (itemLink ~= nil and (type(itemLink) ~= "string" or parseItemID(itemLink) ~= itemID))
            or not isInteger(itemCount, 1, 9007199254740991) then
            return nil, "snapshot-item-invalid"
        end
        local safeIcon, safeIconErr = optionalIcon(api, iconValue)
        if safeIconErr then return nil, safeIconErr end
        if safeIcon == nil and requireObservedSlotCount then
            safeIcon = iconForItem(api, itemID)
        end
        clone.slots[slotID] = {
            itemID = itemID,
            itemLink = itemLink,
            icon = safeIcon,
            count = itemCount,
        }
    end
    return clone, nil
end

local function guildSyncContext(controller)
    if not controller.guildOpen or not controller.guildSessionToken then
        return nil, "guild-session-unavailable"
    end
    local refreshed, refreshErr = refreshGuildMetadata(controller)
    if not refreshed then return nil, refreshErr end
    if not controller.guildOpen or not controller.guildSessionToken or not controller.guildMetadata then
        return nil, "guild-session-unavailable"
    end
    local viewable = {}
    for tabID, descriptor in pairs(controller.guildMetadata.tabs) do
        if descriptor.viewable == true then viewable[tabID] = true end
    end
    controller.guildViewableTabIDs = viewable
    local publicViewable = {}
    for tabID in pairs(viewable) do publicViewable[tabID] = true end
    return {
        guildKey = controller.guildMetadata.identityKey,
        sessionToken = controller.guildSessionToken,
        viewableTabIDs = publicViewable,
    }, nil
end

local function getGuildSyncSnapshot(controller, tabID, sessionToken)
    local context, contextErr = guildSyncContext(controller)
    if not context then return nil, contextErr end
    if sessionToken ~= context.sessionToken then return nil, "guild-session-token-mismatch" end
    if not isInteger(tabID, 1, MAX_GUILD_TABS) or not context.viewableTabIDs[tabID] then
        return nil, "guild-tab-not-viewable"
    end
    local record = rawget(controller.database.guilds, context.guildKey)
    if type(record) ~= "table" or type(record.tabs) ~= "table" then
        return nil, "guild-record-unavailable"
    end
    local tab = rawget(record.tabs, tabID)
    local descriptor = controller.guildMetadata.tabs[tabID]
    if not validExistingTab(tab, tabID) or tab.status ~= "cached"
        or tab.numSlots ~= GUILD_TAB_SLOTS
        or not isInteger(tab.capturedAt, 0, 9007199254740991)
        or tab.name ~= descriptor.name then
        return nil, "guild-tab-snapshot-unavailable"
    end
    local validated, validationErr = validateGuildSnapshot(controller.api, tabID, tab, descriptor)
    if not validated then return nil, validationErr end
    return copyGuildTab(validated), nil
end

local function mergeGuildSyncSnapshot(controller, guildKey, sessionToken, tabID, snapshot)
    local context, contextErr = guildSyncContext(controller)
    if not context then return false, contextErr end
    if guildKey ~= context.guildKey or sessionToken ~= context.sessionToken then
        return false, "guild-session-mismatch"
    end
    if not isInteger(tabID, 1, MAX_GUILD_TABS) or not context.viewableTabIDs[tabID] then
        return false, "guild-tab-not-viewable"
    end
    local descriptor = controller.guildMetadata.tabs[tabID]
    if not descriptor or descriptor.viewable ~= true then return false, "guild-tab-metadata-invalid" end
    local validated, validationErr = validateGuildSnapshot(controller.api, tabID, snapshot, descriptor, true)
    if not validated then return false, validationErr end
    local identity = controller.lastGuildIdentity
    if not validIdentity(identity) or identity.key ~= guildKey then return false, "guild-identity-invalid" end
    local record, _, recordErr = ensureRecord(controller.database, "guilds", identity)
    if not record then return false, recordErr end
    local old = rawget(record.tabs, tabID)
    if old ~= nil and not validExistingTab(old, tabID) then return false, "existing-tab-invalid" end
    if old and isInteger(old.capturedAt, 0, 9007199254740991)
        and validated.capturedAt <= old.capturedAt then
        return false, nil
    end
    record.tabs[tabID] = validated
    record.capturedAt = validated.capturedAt
    refreshRecordStatus(record)
    notifyChanged(controller, "remote-merge", tabID)
    return true, nil
end

-- City synchronization uses only data already saved by a normal bank capture.
-- These helpers deliberately do not query guild-bank tab metadata or read bank APIs.
local function guildCacheSyncContext(controller)
    local identity, identityErr = getGuildIdentity(controller.api)
    if not identity then return nil, identityErr end
    return { guildKey = identity.key }, nil
end

local function getGuildCacheSyncManifest(controller, guildKey)
    local context, contextErr = guildCacheSyncContext(controller)
    if not context then return nil, contextErr end
    if guildKey ~= context.guildKey then return nil, "guild-identity-invalid" end
    local record = rawget(controller.database.guilds, context.guildKey)
    local tabs = {}
    if type(record) ~= "table" or type(record.tabs) ~= "table" then return tabs, nil end
    for tabID, tab in pairs(record.tabs) do
        if isInteger(tabID, 1, MAX_GUILD_TABS) and validExistingTab(tab, tabID)
            and tab.status == "cached" and tab.numSlots == GUILD_TAB_SLOTS
            and isInteger(tab.capturedAt, 0, 9007199254740991) then
            tabs[tabID] = { capturedAt = tab.capturedAt }
        end
    end
    return tabs, nil
end

local function getGuildCacheSyncSnapshot(controller, guildKey, tabID)
    local context, contextErr = guildCacheSyncContext(controller)
    if not context then return nil, contextErr end
    if guildKey ~= context.guildKey then return nil, "guild-identity-invalid" end
    if not isInteger(tabID, 1, MAX_GUILD_TABS) then return nil, "guild-tab-invalid" end
    local record = rawget(controller.database.guilds, context.guildKey)
    local tab = type(record) == "table" and type(record.tabs) == "table" and rawget(record.tabs, tabID) or nil
    if not validExistingTab(tab, tabID) or tab.status ~= "cached"
        or tab.numSlots ~= GUILD_TAB_SLOTS
        or not isInteger(tab.capturedAt, 0, 9007199254740991) then
        return nil, "guild-tab-snapshot-unavailable"
    end
    local validated, validationErr = validateGuildSnapshot(controller.api, tabID, tab, { name = tab.name })
    if not validated then return nil, validationErr end
    return copyGuildTab(validated), nil
end

local function mergeGuildCacheSyncSnapshot(controller, guildKey, tabID, snapshot)
    local context, contextErr = guildCacheSyncContext(controller)
    if not context then return false, contextErr end
    if guildKey ~= context.guildKey then return false, "guild-identity-invalid" end
    if not isInteger(tabID, 1, MAX_GUILD_TABS) then return false, "guild-tab-invalid" end
    local identity, identityErr = getGuildIdentity(controller.api)
    if not identity or identity.key ~= guildKey then return false, identityErr or "guild-identity-invalid" end
    local record = rawget(controller.database.guilds, guildKey)
    local old = type(record) == "table" and type(record.tabs) == "table" and rawget(record.tabs, tabID) or nil
    if old ~= nil and not validExistingTab(old, tabID) then return false, "existing-tab-invalid" end
    local descriptorName = old and old.name or (type(snapshot) == "table" and snapshot.name)
    if not nonEmptyString(descriptorName) then return false, "guild-tab-metadata-invalid" end
    local validated, validationErr = validateGuildSnapshot(controller.api, tabID, snapshot,
        { name = descriptorName }, true)
    if not validated then return false, validationErr end
    if old and isInteger(old.capturedAt, 0, 9007199254740991)
        and validated.capturedAt <= old.capturedAt then
        return false, nil
    end
    if not record then
        local createdRecord, _, recordErr = ensureRecord(controller.database, "guilds", identity)
        if not createdRecord then return false, recordErr end
        record = createdRecord
    end
    record.tabs[tabID] = validated
    record.capturedAt = validated.capturedAt
    refreshRecordStatus(record)
    notifyChanged(controller, "remote-merge", tabID)
    return true, nil
end

function BankMemory.CreateController(api, database, onChanged, requestFlush)
    if type(api) ~= "table" then
        return nil, "api-invalid"
    end
    if type(database) ~= "table" or database.schemaVersion ~= SCHEMA_VERSION
        or type(database.characters) ~= "table" or type(database.guilds) ~= "table" then
        return nil, "database-invalid"
    end

    local controller = {
        api = api,
        database = database,
        onChanged = onChanged,
        requestFlush = requestFlush,
        personalOpen = false,
        guildOpen = false,
        inventoryPending = false,
        personalPending = false,
        guildMetadataPending = false,
        guildReadinessDeferred = false,
        personalContainerIDs = {},
        guildMetadata = nil,
        guildSessionToken = nil,
        guildSessionGuildKey = nil,
        guildSessionEstablishPending = false,
        guildViewableTabIDs = {},
    }

    function controller:CancelPending()
        self.batching = true
        cancelQueue(self, "personal")
        cancelQueue(self, "guild")
        if self.inventoryPending then
            local identity = self.lastInventoryIdentity
            local record = identity and rawget(self.database.characters, identity.key)
            if type(record) == "table" and type(record.inventory) == "table"
                and setIncomplete(record.inventory) then
                notifyChanged(self)
            end
            self.inventoryPending = false
        end
        self.personalOpen, self.guildOpen = false, false
        self.personalPending, self.guildMetadataPending, self.guildReadinessDeferred = false, false, false
        self.guildSessionEstablishPending = false
        self.batching = false
        if self.batchChanged then
            self.batchChanged = false
            notifyChanged(self)
        end
    end

    function controller:FlushPending()
        self.batching = true
        local personal, guild = self.personalQueue, self.guildQueue
        self.personalQueue, self.guildQueue = nil, nil
        if self.inventoryPending then captureInventory(self) end
        local function validSession(queue, identity)
            return queue.database == self.database and validIdentity(queue.identity)
                and identity and queue.identity.key == identity.key
        end
        if personal and self.personalOpen then
            local identity = getPlayerIdentity(self.api)
            if validSession(personal, identity) then
                capturePersonal(self, not personal.full and personal.ids or nil)
            else
                markKnownRecordIncomplete(self, "characters", personal.identity, personal.database)
            end
        end
        if guild and self.guildOpen then
            local identity = getGuildIdentity(self.api)
            if validSession(guild, identity) then
                local ok = refreshGuildMetadata(self)
                if ok then
                    for tabID in pairs(guild.ids) do captureGuildReady(self, tabID) end
                end
            else
                markKnownRecordIncomplete(self, "guilds", guild.identity, guild.database)
            end
        end
        self.batching = false
        if self.batchChanged then
            self.batchChanged = false
            notifyChanged(self)
        end
    end

    function controller:GetGuildBankSyncContext()
        return guildSyncContext(self)
    end

    function controller:GetGuildBankSyncSnapshot(tabID, sessionToken)
        return getGuildSyncSnapshot(self, tabID, sessionToken)
    end

    function controller:MergeGuildBankSyncSnapshot(guildKey, sessionToken, tabID, snapshot)
        return mergeGuildSyncSnapshot(self, guildKey, sessionToken, tabID, snapshot)
    end

    function controller:GetGuildBankCachedSyncContext()
        return guildCacheSyncContext(self)
    end

    function controller:GetGuildBankCachedSyncManifest(guildKey)
        return getGuildCacheSyncManifest(self, guildKey)
    end

    function controller:GetGuildBankCachedSyncSnapshot(guildKey, tabID)
        return getGuildCacheSyncSnapshot(self, guildKey, tabID)
    end

    function controller:MergeGuildBankCachedSyncSnapshot(guildKey, tabID, snapshot)
        return mergeGuildCacheSyncSnapshot(self, guildKey, tabID, snapshot)
    end

    function controller:HandleEvent(event, ...)
        if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
            return captureInventory(self)
        end
        if event == "BANKFRAME_OPENED" then
            self.batching = true
            cancelQueue(self, "personal")
            self.personalOpen = true
            self.personalPending = false
            local ok, err = capturePersonal(self)
            if self.inventoryPending then captureInventory(self) end
            self.batching = false
            if self.batchChanged then
                self.batchChanged = false
                notifyChanged(self)
            end
            return ok, err
        end
        if event == "BANKFRAME_CLOSED" then
            self.batching = true
            cancelQueue(self, "personal")
            self.personalOpen = false
            self.personalPending = false
            self.personalContainerIDs = {}
            if self.inventoryPending then captureInventory(self) end
            self.batching = false
            if self.batchChanged then
                self.batchChanged = false
                notifyChanged(self)
            end
            return true, nil
        end

        if event == "PLAYER_REGEN_ENABLED" then
            local changed = false
            if self.inventoryPending then
                local ok = captureInventory(self)
                if ok then changed = true end
            end
            if self.personalPending then
                self.personalPending = false
                if self.personalOpen then
                    local ok = queueCapture(self, "personal")
                    if ok then changed = true end
                end
            end
            if self.guildOpen and (self.guildMetadataPending or self.guildReadinessDeferred) then
                self.guildMetadataPending = false
                self.guildReadinessDeferred = false
                local ok = queueCapture(self, "guild")
                if ok then changed = true end
            end
            return changed, nil
        end

        if event == "BAG_UPDATE_DELAYED" then
            if self.personalOpen then
                local queued, queueErr = queueCapture(self, "personal")
                if queued then
                    self.inventoryPending = true
                    return true, nil
                end
                local inventoryOk, inventoryErr = captureInventory(self)
                if not inventoryOk then return false, inventoryErr or queueErr end
                return false, queueErr
            end
            return captureInventory(self)
        end
        if event == "PLAYERBANKSLOTS_CHANGED" then
            if self.personalOpen then return queueCapture(self, "personal") end
            return false, "personal-bank-closed"
        end
        if event == "BAG_UPDATE" then
            if not self.personalOpen then return false, "personal-bank-closed" end
            local containerID = ...
            local idOk = safeValue(self.api, containerID)
            if not idOk then return false, "container-id-invalid" end
            if not isInteger(containerID, 1, MAX_PERSONAL_SLOTS) then return false, "container-id-invalid" end
            if self.personalContainerIDs[containerID] then return queueCapture(self, "personal", containerID) end
            return false, "unrelated-container-update"
        end
        if event == "BANK_TABS_CHANGED" or event == "BANK_TAB_SETTINGS_UPDATED" then
            if not self.personalOpen then return false, "personal-bank-closed" end
            local bankType = ...
            local bankTypeOk = safeValue(self.api, bankType)
            local characterBankType = getBankType(self.api, "Character")
            if not bankTypeOk or characterBankType == nil or bankType ~= characterBankType then
                return false, "unrelated-bank-update"
            end
            return queueCapture(self, "personal")
        end

        if event == "GUILDBANKFRAME_OPENED" then
            cancelQueue(self, "guild")
            self.guildOpen = true
            self.guildReadinessDeferred = false
            clearGuildSession(self, true)
            self.guildSessionGuildKey = nil
            self.guildSessionEstablishPending = true
            return refreshGuildMetadata(self)
        end
        if event == "GUILDBANKFRAME_CLOSED" then
            cancelQueue(self, "guild")
            self.guildOpen = false
            self.guildMetadataPending = false
            self.guildReadinessDeferred = false
            clearGuildSession(self, true)
            self.guildSessionGuildKey = nil
            self.guildSessionEstablishPending = false
            return true, nil
        end
        if event == "PLAYER_GUILD_UPDATE" then
            if self.guildOpen then
                local identity, identityErr = getGuildIdentity(self.api)
                if not identity or identity.key ~= self.guildSessionGuildKey then
                    clearGuildSession(self, true)
                    self.guildSessionGuildKey = identity and identity.key or nil
                    if not identity then
                        self.guildSessionEstablishPending = identityErr ~= "guild-name-unavailable"
                    else
                        self.guildSessionEstablishPending = false
                    end
                else
                    return refreshGuildMetadata(self)
                end
            else
                clearGuildSession(self, false)
                self.guildSessionGuildKey = nil
                self.guildSessionEstablishPending = false
            end
            return true, nil
        end
        if event == "GUILDBANK_UPDATE_TABS" then
            if self.guildOpen then return queueCapture(self, "guild") end
            return false, "guild-bank-closed"
        end
        if event == "GUILDBANKBAGSLOTS_CHANGED" then
            if not self.guildOpen then return false, "guild-bank-closed" end
            local outOfCombat = combatState(self.api)
            if outOfCombat ~= true then return queueCapture(self, "guild") end
            local ok, tabID = safeCall(self.api, self.api.GetCurrentGuildBankTab, 1)
            if not ok or not isInteger(tabID, 1, MAX_GUILD_TABS) then
                markKnownRecordIncomplete(self, "guilds", self.lastGuildIdentity)
                return false, "guild-current-tab-invalid"
            end
            return queueCapture(self, "guild", tabID)
        end

        return false, "event-unhandled"
    end

    return controller, nil
end

BankMemory.schemaVersion = SCHEMA_VERSION
