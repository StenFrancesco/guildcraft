local _, GGM = ...

local PROFESSIONS = { 129, 164, 165, 171, 185, 197, 202, 333, 356 }

local function resetAutomaticGuild(sync)
    sync.automaticGuild, sync.automaticRemaining = nil, nil
end

local function initializeAutomaticRemaining(sync)
    if sync.automaticRemaining then return end
    sync.automaticRemaining = {}
    for _, professionID in ipairs(PROFESSIONS) do sync.automaticRemaining[professionID] = true end
end

local function interrupt(sync)
    local attempt = sync.automaticAttempt
    if not attempt then return end
    attempt.cancelled = true
    sync.automaticAttempt = nil
    if attempt.operation and sync.manualOperation == attempt.operation then GGM.CancelProfessionSync(sync) end
    attempt.done(true)
end

local function run(sync, done, controller)
    if not sync.registered or not sync.rosterReady then done(true); return end
    initializeAutomaticRemaining(sync)
    if sync.automaticGuild and sync.automaticGuild ~= sync.guild then
        GGM.StopAutomaticSync(controller)
        return
    end
    sync.automaticGuild = sync.guild
    local attempt = { index = 1, done = done, budgets = {}, allowedPeers = {} }
    sync.automaticAttempt = attempt
    local pump
    local function later(delay)
        local ok, handle = pcall(sync.api.C_Timer.NewTimer, delay, function()
            if sync.automaticAttempt == attempt and not attempt.cancelled then pump() end
        end)
        if not ok or not handle then interrupt(sync) end
    end
    pump = function()
        if sync.automaticAttempt ~= attempt or attempt.cancelled then return end
        if not sync.rosterReady or sync.automaticGuild ~= sync.guild then interrupt(sync); return end
        -- Manual requests and selected incoming transfers keep their priority.
        if sync.active or sync.manualOperation or sync.buttonRequest or #sync.transport.outboundFrames > 0 then later(0.5); return end
        local professionID
        while attempt.index <= #PROFESSIONS do
            local candidate = PROFESSIONS[attempt.index]
            attempt.index = attempt.index + 1
            if sync.automaticRemaining[candidate] then professionID = candidate; break end
        end
        if not professionID then
            sync.automaticAttempt = nil
            done(next(sync.automaticRemaining) ~= nil)
            return
        end
        local completed = false
        local function onComplete(result)
            if completed or attempt.cancelled or sync.automaticAttempt ~= attempt then return end
            completed = true
            attempt.operation = nil
            if not result.unfinished then sync.automaticRemaining[professionID] = nil end
            if not attempt.allowedPeers[professionID] and result.selectedPeers then
                attempt.allowedPeers[professionID] = {}
                for _, peer in ipairs(result.selectedPeers) do attempt.allowedPeers[professionID][peer] = true end
            end
            attempt.budgets[professionID] = (attempt.budgets[professionID] or 0) + (result.comparisons or 0)
            local hasEligibleRemaining = false
            for _, peer in ipairs(result.remainingPeers or {}) do
                if attempt.allowedPeers[professionID] and attempt.allowedPeers[professionID][peer] then hasEligibleRemaining = true; break end
            end
            if result.unfinished and result.competing and hasEligibleRemaining
                and (result.comparisons or 0) > 0 and attempt.budgets[professionID] < 8 then
                attempt.index = attempt.index - 1
            end
            later(0.5)
        end
        local options = { maxComparisons = 8 - (attempt.budgets[professionID] or 0),
            allowedPeers = attempt.allowedPeers[professionID],
            resumeOnly = (controller.recoveries > 0 or (attempt.budgets[professionID] or 0) > 0)
                and sync.resumePeers and sync.resumePeers[professionID] ~= nil }
        local accepted, err = GGM.RequestProfessionSync(sync, professionID, "manual", nil, onComplete, options)
        if accepted and not completed then attempt.operation = sync.manualOperation
        elseif not completed then
            completed = true
            if err == "profession-sync-cooldown" then
                attempt.index = attempt.index - 1
                later(math.max(0.5, (sync.cooldowns[professionID] or 0) + 60 - sync.api.GetTime()))
            else later(0.5) end
        end
    end
    pump()
end

function GGM.StartProfessionAutomaticSync(sync)
    if not sync or type(GGM.CreateAutomaticSyncController) ~= "function" then return false end
    if not sync.automaticController then
        initializeAutomaticRemaining(sync)
        sync.automaticController = GGM.CreateAutomaticSyncController(sync.api,
            function(done, controller) run(sync, done, controller) end,
            function() interrupt(sync) end)
    end
    return GGM.StartAutomaticSync(sync.automaticController)
end

function GGM.WakeProfessionSync(sync)
    if not sync or not sync.automaticController then return end
    if not GGM.AutomaticSyncAllowed(sync.api) then GGM.WakeAutomaticSync(sync.automaticController); return end
    local ok, inGuild = pcall(sync.api.IsInGuild)
    local guildReadable = false
    if ok and type(sync.api.issecretvalue) == "function" then
        local public, secret = pcall(sync.api.issecretvalue, inGuild)
        guildReadable = public and secret == false
    end
    if guildReadable and inGuild == false then
        GGM.StopAutomaticSync(sync.automaticController)
        resetAutomaticGuild(sync)
        return
    end
    if not sync.registered or not sync.rosterReady then
        if sync.automaticAttempt then interrupt(sync) end
        return
    end
    if sync.automaticGuild and sync.guild ~= sync.automaticGuild then
        GGM.StopAutomaticSync(sync.automaticController)
        resetAutomaticGuild(sync)
        GGM.WakeAutomaticSync(sync.automaticController)
        return
    end
    GGM.WakeAutomaticSync(sync.automaticController)
end
