local _, GGM = ...

local RETRY_DELAY_SECONDS = 0.2
local MAX_RETRIES = 3
local MAX_GUILD_MEMBERS = 1000

local function pack(...)
    return { n = select("#", ...), ... }
end

local function unpackValues(values, first, last)
    return unpack(values, first, last)
end

local function isReadable(api, value)
    local secretFunction
    local secretFunctionOK = pcall(function() secretFunction = api and api.issecretvalue end)
    if not secretFunctionOK or type(secretFunction) ~= "function" then
        local globalOK = pcall(function() secretFunction = _G and _G.issecretvalue end)
        if not globalOK then return false end
    end
    if type(secretFunction) == "function" then
        local ok, secret = pcall(secretFunction, value)
        if not ok or secret == true then return false end
    end
    return pcall(function() return type(value) end)
end

local function safeCall(api, method, ...)
    local functionOK, fn = pcall(function() return api and api[method] end)
    if not functionOK or type(fn) ~= "function" then return false, nil, "api-unavailable:" .. method end

    local result = pack(pcall(fn, ...))
    if result[1] ~= true then return false, nil, "api-failed:" .. method end
    for index = 2, result.n do
        if not isReadable(api, result[index]) then return false, nil, "api-value-unreadable:" .. method end
    end
    return true, unpackValues(result, 2, result.n)
end

local function hasFunction(api, method)
    local ok, fn = pcall(function() return api and api[method] end)
    return ok and type(fn) == "function"
end

local function nonEmptyString(api, value, maximum)
    if not isReadable(api, value) then return false end
    local ok, valid = pcall(function()
        return type(value) == "string" and value ~= ""
            and (maximum == nil or #value <= maximum)
    end)
    return ok and valid == true
end

local function validGUID(api, value)
    return nonEmptyString(api, value, GGM.SYNC_MAX_GUID_BYTES or 64)
end

local function positiveInteger(api, value, maximum)
    if not isReadable(api, value) then return false end
    local ok, valid = pcall(function()
        return type(value) == "number" and value == math.floor(value)
            and value > 0 and value <= maximum
    end)
    return ok and valid == true
end

local function normalizeRealm(value)
    return (value:gsub("%s", "")):lower()
end

local function localCanonicalRealm(api)
    local unitOK, _, unitRealm = safeCall(api, "UnitFullName", "player")
    if unitOK and nonEmptyString(api, unitRealm, GGM.SYNC_MAX_REALM_BYTES or 32) then
        return unitRealm
    end
    local realmOK, realm = safeCall(api, "GetRealmName")
    if realmOK and nonEmptyString(api, realm, GGM.SYNC_MAX_REALM_BYTES or 32) then
        return realm
    end
    return nil
end

local function getUnitNameAndRealm(api, unit)
    local ok, name, realm = safeCall(api, "UnitFullName", unit)
    if not ok or not nonEmptyString(api, name, GGM.SYNC_MAX_NAME_BYTES or 32) then
        ok, name, realm = safeCall(api, "UnitName", unit)
    end
    if not ok or not nonEmptyString(api, name, GGM.SYNC_MAX_NAME_BYTES or 32) then
        return nil, nil, "inspect-identity-unavailable"
    end
    local canonicalLocalRealm = localCanonicalRealm(api)
    if nonEmptyString(api, realm, GGM.SYNC_MAX_REALM_BYTES or 32) then
        if canonicalLocalRealm and normalizeRealm(realm) == normalizeRealm(canonicalLocalRealm) then
            realm = canonicalLocalRealm
        end
    else
        if not canonicalLocalRealm then
            return nil, nil, "inspect-identity-unavailable"
        end
        realm = canonicalLocalRealm
    end
    return name, realm, nil
end

local function readIdentity(api, unit)
    local guidOK, guid = safeCall(api, "UnitGUID", unit)
    if not guidOK or not validGUID(api, guid) then return nil, "inspect-guid-unavailable" end
    local name, realm, identityErr = getUnitNameAndRealm(api, unit)
    if not name then return nil, identityErr end
    local identity = {
        key = name .. "-" .. realm,
        name = name,
        realm = realm,
        guid = guid,
        classToken = GGM.ReadUnitClassToken(api, unit),
    }
    if #identity.key > (GGM.SYNC_MAX_IDENTITY_KEY_BYTES or 80) then
        return nil, "inspect-identity-unavailable"
    end
    return identity, nil
end

local function readGuildFacts(api, unit)
    local ok, guildName, _, _, guildRealm = safeCall(api, "GetGuildInfo", unit)
    if not ok or not nonEmptyString(api, guildName, 128) then return nil end

    local actualRealm
    if nonEmptyString(api, guildRealm, GGM.SYNC_MAX_REALM_BYTES or 32) then
        actualRealm = guildRealm
    end
    local comparisonRealm = actualRealm
    if not comparisonRealm then
        local _, unitRealm = getUnitNameAndRealm(api, unit)
        comparisonRealm = unitRealm
    end
    if not nonEmptyString(api, comparisonRealm, GGM.SYNC_MAX_REALM_BYTES or 32) then return nil end
    return { name = guildName, realm = comparisonRealm, actualRealm = actualRealm }
end

local function rosterConfirmsMember(api, identity)
    if not hasFunction(api, "GetNumGuildMembers") or not hasFunction(api, "GetGuildRosterInfo") then
        return nil
    end
    local countOK, count = safeCall(api, "GetNumGuildMembers", true)
    if not countOK or not positiveInteger(api, count, MAX_GUILD_MEMBERS) then return false end

    local sawGUID = false
    local sawCompleteRows = true
    local matchedGUID = false
    local matchedName = false
    for index = 1, count do
        local rowOK, row = pcall(function()
            local values = pack(api.GetGuildRosterInfo(index))
            for valueIndex = 1, values.n do
                if not isReadable(api, values[valueIndex]) then error("guild roster value unreadable") end
            end
            return values
        end)
        if not rowOK then return false end

        local rawName = row[1]
        local rowGUID = row[17]
        if nonEmptyString(api, rowGUID, GGM.SYNC_MAX_GUID_BYTES or 64) then
            sawGUID = true
            if rowGUID == identity.guid then matchedGUID = true end
        end

        if nonEmptyString(api, rawName, 128) then
            local name, realm = rawName:match("^([^-]+)%-(.+)$")
            if not name then
                name = rawName
                local realmOK, currentRealm = safeCall(api, "GetRealmName")
                if realmOK then realm = currentRealm end
            end
            if nonEmptyString(api, name, GGM.SYNC_MAX_NAME_BYTES or 32)
                and nonEmptyString(api, realm, GGM.SYNC_MAX_REALM_BYTES or 32) then
                if name == identity.name and normalizeRealm(realm) == normalizeRealm(identity.realm) then
                    matchedName = true
                end
            else
                sawCompleteRows = false
            end
        else
            sawCompleteRows = false
        end
    end

    if sawGUID then return matchedGUID end
    if sawCompleteRows then return matchedName end
    return false
end

local function sameGuild(api, unit)
    local inGuildOK, inGuild = safeCall(api, "IsInGuild")
    if not inGuildOK or inGuild ~= true then return false end

    local directProof
    if hasFunction(api, "UnitIsInMyGuild") then
        local directOK, belongs = safeCall(api, "UnitIsInMyGuild", unit)
        if directOK and type(belongs) == "boolean" then
            if not belongs then return false end
            directProof = true
        end
    end

    local ownFacts = readGuildFacts(api, "player")
    local targetFacts = readGuildFacts(api, unit)
    if ownFacts and targetFacts then
        if ownFacts.name ~= targetFacts.name then
            return false
        end
        if directProof then
            if ownFacts.actualRealm and targetFacts.actualRealm
                and normalizeRealm(ownFacts.actualRealm) ~= normalizeRealm(targetFacts.actualRealm) then
                return false
            end
        elseif normalizeRealm(ownFacts.realm) ~= normalizeRealm(targetFacts.realm) then
            return false
        end
    elseif not directProof then
        return false
    end

    if directProof then return true end
    local identity, identityErr = readIdentity(api, unit)
    if not identity then return false, identityErr end

    local rosterResult = rosterConfirmsMember(api, identity)
    if rosterResult ~= nil then return rosterResult end

    -- Older Classic clients lack UnitIsInMyGuild and may not expose GUIDs in
    -- their roster. Matching guild name and guild realm is the available proof.
    return ownFacts ~= nil and targetFacts ~= nil
end

local function clearPending(state, pending)
    if pending then pending.active = false end
    if state.pending == pending then state.pending = nil end
end

local function currentIdentity(state, pending)
    if state.pending ~= pending or not pending.active then return nil, "inspect-request-stale" end
    local identity, identityErr = readIdentity(state.api, pending.unit)
    if not identity then return nil, identityErr end
    if identity.guid ~= pending.guid then return nil, "inspect-target-changed" end
    local guild, guildErr = sameGuild(state.api, pending.unit)
    if not guild then return nil, guildErr or "inspect-target-not-guild-member" end
    return identity, nil
end

local function inspectSlot(state, unit, trackedSlot)
    local api = state.api
    local slotOK, inventorySlotID = safeCall(api, "GetInventorySlotInfo", trackedSlot.inventoryName)
    if not slotOK then return nil, "fatal", "inspect-slot-api-unavailable" end
    if inventorySlotID == nil and GGM.OPTIONAL_TRACKED_SLOTS[trackedSlot.key] == true then
        return { unavailable = true }, "ready"
    end
    if inventorySlotID ~= trackedSlot.inventorySlotID then
        return nil, "fatal", "inspect-slot-id-mismatch:" .. trackedSlot.key
    end

    local idOK, itemID = safeCall(api, "GetInventoryItemID", unit, inventorySlotID)
    local linkOK, itemLink = safeCall(api, "GetInventoryItemLink", unit, inventorySlotID)
    local textureOK, texture = safeCall(api, "GetInventoryItemTexture", unit, inventorySlotID)
    if not idOK or not linkOK or not textureOK then
        return nil, "fatal", "inspect-item-read-failed:" .. trackedSlot.key
    end

    if itemID == nil and itemLink == nil and texture == nil then
        return { inventorySlotID = inventorySlotID, itemID = false, itemLink = false }, "empty"
    end
    if itemID == nil or itemLink == nil or texture == nil then
        return nil, "retry", "inspect-item-data-pending:" .. trackedSlot.key
    end

    local validOK, valid, validationErr = pcall(GGM.ValidateGearSlotValue, trackedSlot.key, {
        inventorySlotID = inventorySlotID,
        itemID = itemID,
        itemLink = itemLink,
    })
    if not validOK then return nil, "fatal", "inspect-item-value-unreadable:" .. trackedSlot.key end
    if not valid then return nil, "retry", validationErr or ("inspect-item-data-inconsistent:" .. trackedSlot.key) end
    return { inventorySlotID = inventorySlotID, itemID = itemID, itemLink = itemLink }, "equipped"
end

local function captureAndSave(state, pending)
    local identity, identityErr = currentIdentity(state, pending)
    if not identity then return "ignored", identityErr end

    local snapshot = { complete = true, capturedAt = pending.observedAt, slots = {} }
    local hasUsableGear = false
    for _, trackedSlot in ipairs(GGM.TRACKED_SLOTS) do
        local slotValue, status, slotErr = inspectSlot(state, pending.unit, trackedSlot)
        if not slotValue then
            if status == "retry" then return "retry", slotErr end
            return "ignored", slotErr
        end
        snapshot.slots[trackedSlot.key] = slotValue
        if status == "equipped" then hasUsableGear = true end
    end
    if not hasUsableGear then return "ignored", "inspect-no-usable-gear" end

    local finalIdentity, finalIdentityErr = currentIdentity(state, pending)
    if not finalIdentity then return "ignored", finalIdentityErr end
    if finalIdentity.key ~= identity.key or finalIdentity.name ~= identity.name
        or finalIdentity.realm ~= identity.realm or finalIdentity.guid ~= identity.guid then
        return "ignored", "inspect-target-changed"
    end

    local saveOK, saved, saveErr = pcall(GGM.SaveObservedCharacterRecord, state.db, finalIdentity, snapshot)
    if not saveOK then return "failed", "inspect-save-failed" end
    if saved ~= true then return "failed", saveErr or "inspect-save-rejected" end

    clearPending(state, pending)
    if type(state.onChanged) == "function" then pcall(state.onChanged, true) end
    return "saved", nil
end

local function runAttempt(state, pending)
    if state.pending ~= pending or not pending.active then return "ignored", "inspect-request-stale" end
    local result, err = captureAndSave(state, pending)
    if result == "retry" then
        if pending.retryCount >= MAX_RETRIES then
            clearPending(state, pending)
            return "ignored", err
        end
        local timerTable = state.api.C_Timer
        local after = type(timerTable) == "table" and timerTable.After or nil
        if type(after) ~= "function" then
            clearPending(state, pending)
            return "ignored", "inspect-retry-timer-unavailable"
        end
        pending.retryCount = pending.retryCount + 1
        pending.waiting = true
        local ok = pcall(after, RETRY_DELAY_SECONDS, function()
            if state.pending ~= pending or not pending.active then return end
            pending.waiting = false
            runAttempt(state, pending)
        end)
        if not ok then
            clearPending(state, pending)
            return "ignored", "inspect-retry-timer-failed"
        end
        return "retrying", nil
    end
    clearPending(state, pending)
    return result, err
end

function GGM.InstallInspectGearCapture(api, db, onChanged)
    if type(api) ~= "table" or type(db) ~= "table" then return nil, "inspect-setup-invalid" end
    if type(GGM.SaveObservedCharacterRecord) ~= "function" then return nil, "inspect-storage-unavailable" end
    if not hasFunction(api, "hooksecurefunc")
        or not hasFunction(api, "NotifyInspect")
        or not hasFunction(api, "ClearInspectPlayer") then
        return nil, "inspect-hook-unavailable"
    end

    local state = { api = api, db = db, onChanged = onChanged, pending = nil, generation = 0 }
    local function hookSecure(name, callback)
        local ok = pcall(api.hooksecurefunc, name, callback)
        return ok
    end

    local hookedNotify = hookSecure("NotifyInspect", function(unit)
        state.generation = state.generation + 1
        local guidOK, guid = safeCall(api, "UnitGUID", unit)
        if not guidOK or not validGUID(api, guid) then
            clearPending(state, state.pending)
            return
        end
        if state.pending then state.pending.active = false end
        state.pending = {
            unit = unit,
            guid = guid,
            token = state.generation,
            retryCount = 0,
            active = true,
            waiting = false,
            readyHandled = false,
        }
    end)
    if not hookedNotify then return nil, "inspect-notify-hook-failed" end

    local hookedClear = hookSecure("ClearInspectPlayer", function()
        state.generation = state.generation + 1
        clearPending(state, state.pending)
    end)
    if not hookedClear then
        state.disabled = true
        if state.pending then state.pending.active = false end
        return nil, "inspect-clear-hook-failed"
    end

    return state, nil
end

function GGM.HandleInspectGearReady(state, guid)
    if type(state) ~= "table" or state.disabled == true or type(state.pending) ~= "table" then
        return "ignored", nil
    end
    local pending = state.pending
    if not pending.active or pending.waiting or pending.readyHandled then return "ignored", nil end
    if not validGUID(state.api, guid) or guid ~= pending.guid then return "ignored", nil end

    local identity, identityErr = currentIdentity(state, pending)
    if not identity then
        clearPending(state, pending)
        return "ignored", identityErr
    end
    local timeOK, observedAt = safeCall(state.api, "GetServerTime")
    if not timeOK or not positiveInteger(state.api, observedAt, GGM.SYNC_MAX_TIMESTAMP or 4294967295) then
        clearPending(state, pending)
        return "ignored", "inspect-time-unavailable"
    end
    pending.observedAt = observedAt
    pending.readyHandled = true
    return runAttempt(state, pending)
end
