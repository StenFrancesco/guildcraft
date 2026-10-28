local _, GGM = ...

-- This policy is bundled with both independent addons; keep the copies equal.
-- Only unfinished jobs own timers. Zone events supply eligibility after a wait.
local COOLDOWN, MAX_RECOVERIES, ATTEMPT_SECONDS = 1200, 3, 3600
local CAPITAL_MAPS = { [84] = true, [85] = true, [87] = true, [88] = true,
    [89] = true, [90] = true, [103] = true, [110] = true, [111] = true,
    [125] = true, [126] = true, [391] = true, [392] = true,
    [393] = true, [622] = true, [624] = true, [627] = true, [628] = true,
    [1161] = true, [1165] = true, [1670] = true, [1671] = true,
    [2112] = true, [2339] = true, [2393] = true }

local function readable(api, value)
    if type(api.issecretvalue) ~= "function" then return false end
    local ok, secret = pcall(api.issecretvalue, value)
    return ok and secret == false
end

-- Shared account preference; the gear addon also works without the main addon.
function GGM.AutomaticSyncAllowed(api)
    local db = api.TheGuildBookDB
    local settings = type(db) == "table" and db.uiSettings
    local mode = type(settings) == "table" and settings.syncMode or "auto"
    if mode == "disable" then return false end
    if mode ~= "town" then return true end
    if type(api.IsResting) ~= "function" then return false end
    local ok, resting = pcall(api.IsResting)
    return ok and readable(api, resting) and resting == true
end

local function clock(controller)
    local ok, value = pcall(controller.api.GetTime)
    if ok and readable(controller.api, value) and type(value) == "number"
        and value >= 0 and value < math.huge then return value end
end

function GGM.IsAutomaticSyncMajorCity(api)
    local ok, resting = pcall(api.IsResting)
    if not ok or not readable(api, resting) or resting ~= true then return false end
    if type(api.C_Map) ~= "table" then return false end
    local mapOK, mapID = pcall(api.C_Map.GetBestMapForUnit, "player")
    if not mapOK or not readable(api, mapID) then return false end
    -- Explicit city maps, not resting alone: an inn in the wilderness is ineligible.
    return type(mapID) == "number" and CAPITAL_MAPS[mapID] == true
end

local function cancel(handle)
    if handle and type(handle.Cancel) == "function" then pcall(handle.Cancel, handle) end
end

local function schedule(controller, delay, fn)
    local generation = controller.generation
    local ok, handle = pcall(controller.api.C_Timer.NewTimer, delay, function()
        if controller.generation == generation and not controller.stopped then fn() end
    end)
    if not ok or not handle then controller.lastError = "automatic-sync-timer-unavailable"; return nil end
    return handle
end

function GGM.CreateAutomaticSyncController(api, run, interrupt)
    return { api = api, run = run, interrupt = interrupt, generation = 0,
        recoveries = 0, pending = false, running = false, started = false }
end

function GGM.StopAutomaticSync(controller)
    if not controller then return end
    controller.generation = controller.generation + 1
    controller.stopped, controller.pending, controller.running = true, false, false
    cancel(controller.wakeTimer); cancel(controller.deadlineTimer)
    controller.wakeTimer, controller.deadlineTimer = nil, nil
    if controller.interrupt then pcall(controller.interrupt) end
end

function GGM.WakeAutomaticSync(controller)
    if not controller then return false end
    if not GGM.AutomaticSyncAllowed(controller.api) then
        if controller.running then
            controller.generation = controller.generation + 1
            controller.running, controller.pending = false, true
            cancel(controller.deadlineTimer); controller.deadlineTimer = nil
            controller.lastStarted = nil
            if controller.interrupt then pcall(controller.interrupt) end
        end
        return false
    end
    -- Guild identity changes cancel the old run. A later guild/zone wake starts
    -- a fresh bounded run for the current membership in the same session.
    if controller.stopped then
        controller.stopped, controller.started, controller.exhausted = false, false, nil
        controller.lastStarted = nil
        controller.nextAt, controller.pending = nil, false
        return GGM.StartAutomaticSync(controller)
    end
    if not controller.started or not controller.pending
        or controller.running or controller.exhausted then return false end
    local current = clock(controller)
    if not current then return false end
    if current < controller.nextAt then return false end
    if controller.lastStarted and not GGM.IsAutomaticSyncMajorCity(controller.api) then return false end
    if controller.lastStarted then
        if controller.recoveries >= MAX_RECOVERIES then controller.exhausted = true; return false end
        controller.recoveries = controller.recoveries + 1
    end
    cancel(controller.wakeTimer); controller.wakeTimer = nil
    controller.running, controller.lastStarted = true, current
    local generation = controller.generation
    local finished = false
    local function done(unfinished)
        if finished or controller.generation ~= generation or controller.stopped then return end
        finished = true
        cancel(controller.deadlineTimer); controller.deadlineTimer = nil
        controller.running, controller.pending = false, unfinished == true
        if not controller.pending then return end
        if controller.recoveries >= MAX_RECOVERIES then controller.exhausted = true; return end
        local completedAt = clock(controller)
        if not completedAt then return end
        controller.nextAt = math.max(current + COOLDOWN, completedAt + 1)
        controller.wakeTimer = schedule(controller, controller.nextAt - completedAt, function()
            controller.wakeTimer = nil
            GGM.WakeAutomaticSync(controller)
        end)
    end
    controller.deadlineTimer = schedule(controller, ATTEMPT_SECONDS, function()
        if controller.interrupt then pcall(controller.interrupt) end
        done(true)
    end)
    if not controller.deadlineTimer then done(true); return false end
    local ok = pcall(controller.run, done, controller)
    if not ok then controller.lastError = "automatic-sync-attempt-failed"; done(true) end
    return true
end

function GGM.StartAutomaticSync(controller)
    if not controller or controller.stopped then return false end
    if controller.started then return true end
    local current = clock(controller)
    if not current then return false end
    local ok, delay = pcall(controller.api.random or math.random, 0, 300)
    if not ok or not readable(controller.api, delay) or type(delay) ~= "number"
        or delay < 0 or delay > 300 or delay ~= math.floor(delay) then delay = 300 end
    controller.started, controller.pending, controller.nextAt = true, true, current + delay
    controller.wakeTimer = schedule(controller, delay, function()
        controller.wakeTimer = nil
        GGM.WakeAutomaticSync(controller)
    end)
    if not controller.wakeTimer then controller.started = false; return false end
    return true
end
