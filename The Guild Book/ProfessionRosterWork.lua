local _, GGM = ...

local owner = {}
local generation = 0

function GGM.QueueProfessionRosterReconciliation(api, db, complete)
    generation = generation + 1
    local thisGeneration = generation
    local finished = false
    local function finish(ok, err, changed)
        if finished then return end
        finished = true
        if not ok and thisGeneration == generation then GGM.professionRosterMembershipCurrent = false end
        if type(complete) == "function" then complete(ok, err, changed) end
    end

    if type(api) ~= "table" or type(api.IsInGuild) ~= "function"
        or type(db) ~= "table"
        or type(GGM.CaptureCPUInput) ~= "function"
        or type(GGM.IsCPUInputCurrent) ~= "function"
        or type(GGM.StartCPUJob) ~= "function"
        or type(GGM.PrepareProfessionRosterValidation) ~= "function"
        or type(GGM.ReconcileProfessionGuildRoster) ~= "function" then
        finish(false, "profession-roster-unavailable")
        return nil, "profession-roster-unavailable"
    end

    local guildOk, initialGuildState = pcall(api.IsInGuild)
    if not guildOk or type(initialGuildState) ~= "boolean" then
        finish(false, "profession-roster-unavailable")
        return nil, "profession-roster-unavailable"
    end

    local stamp = GGM.CaptureCPUInput(db)
    local wasCurrent = GGM.professionRosterMembershipCurrent
    local guildIdentity
    if type(api.GetGuildInfo) == "function" then
        local ok, name, _, _, realm = pcall(api.GetGuildInfo, "player")
        if ok then guildIdentity = tostring(name) .. ":" .. tostring(realm) end
    end
    local function current()
        if thisGeneration ~= generation
            or (GGM.db ~= nil and GGM.db ~= db)
            or not GGM.IsCPUInputCurrent(db, stamp) then
            return false
        end
        local ok, inGuild = pcall(api.IsInGuild)
        if not ok or inGuild ~= initialGuildState then return false end
        if guildIdentity then
            local readOK, name, _, _, realm = pcall(api.GetGuildInfo, "player")
            if not readOK or tostring(name) .. ":" .. tostring(realm) ~= guildIdentity then return false end
        end
        return true
    end

    -- Retain a previously confirmed revision while validating a presence event;
    -- explicit guild changes clear readiness before queueing this work.
    GGM.professionRosterMembershipCurrent = wasCurrent == true
    local job, err = GGM.StartCPUJob(owner, function()
        if not current() then return nil, "profession-roster-stale" end
        return GGM.PrepareProfessionRosterValidation(api, db)
    end, function(token, validationErr)
        if not token then
            if not current() then finish(false, "profession-roster-stale"); return end
            -- A corrupt registry may require the original canonical recovery
            -- path. It retains full validation and never uses a reuse token.
            finish(GGM.ReconcileProfessionGuildRoster(api, db))
            return
        end
        if not current() then
            finish(false, "profession-roster-stale")
            return
        end
        if type(GGM.CompleteUnchangedProfessionRosterValidation) == "function" then
            local unchanged, unchangedErr, unchangedState =
                GGM.CompleteUnchangedProfessionRosterValidation(api, db, token)
            if unchanged then
                finish(true, nil, false)
                return
            elseif unchangedErr ~= "changed" then
                finish(false, unchangedErr or "profession-roster-stale")
                return
            end
        end
        local ok, reconcileErr, changed = GGM.ReconcileProfessionGuildRoster(api, db, token)
        finish(ok, reconcileErr, changed)
    end, {
        current = current,
        api = api,
        onCancel = function()
            if thisGeneration == generation then GGM.professionRosterMembershipCurrent = false end
            finish(false, "profession-roster-stale")
        end,
    })

    if not job then
        finish(false, err or "profession-roster-unavailable")
        return nil, err
    end
    return job, nil
end

function GGM.CancelProfessionRosterReconciliation()
    generation = generation + 1
    if GGM.CancelCPUJob then GGM.CancelCPUJob(owner) end
end
