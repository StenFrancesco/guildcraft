local _, GGM = ...

-- A single driver shares one budget across all main-addon preparation jobs.
-- Work must be read-only until completion: mutations and protocol ACKs stay atomic.
local jobs, byOwner, active, driver = {}, {}, nil, nil
local revisions = setmetatable({}, { __mode = 'k' })
local frameDeadline, frameSteps, clock
local FRAME_BUDGET_MS, MAX_FRAME_STEPS, MAX_JOBS = 0.65, 8192, 16
local FALLBACK_FRAME_STEPS = 256
local unpack = unpack

function GGM.GetCPURevision(db)
    return revisions[db] or 0
end
function GGM.InvalidateCPURevision(db)
    if type(db) == 'table' then revisions[db] = (revisions[db] or 0) + 1 end
end

local inputFields = {
    "schemaVersion", "professions", "professionRecipeIndex", "professionCharacters",
    "localCharacterIDByGUID", "localCharacterGUIDs", "localCharacters", "characters",
    "professionIndexRepairCandidates", "professionIndexRepairNeeded",
    "professionRecipeIndexVersion", "nextLocalCharacterID",
}
function GGM.CaptureCPUInput(db)
    local stamp = { db = db, revision = GGM.GetCPURevision(db) }
    for _, field in ipairs(inputFields) do stamp[field] = db[field] end
    return stamp
end
function GGM.IsCPUInputCurrent(db, stamp)
    if db ~= stamp.db or GGM.GetCPURevision(db) ~= stamp.revision then return false end
    for _, field in ipairs(inputFields) do if db[field] ~= stamp[field] then return false end end
    return true
end

local function idle()
    if #jobs == 0 and driver then driver:SetScript('OnUpdate', nil) end
end
local function remove(job, reason)
    if job.done then return end
    job.done = true
    if byOwner[job.owner] == job then byOwner[job.owner] = nil end
    for i, candidate in ipairs(jobs) do
        if candidate == job then table.remove(jobs, i); break end
    end
    job.thread, job.sortScratch = nil, nil
    idle()
    if reason and job.onCancel then job.onCancel(reason) end
end
function GGM.CancelCPUJob(owner)
    local job = byOwner[owner]
    if job then remove(job, 'cancelled') end
end
function GGM.GetCPUJobCount() return #jobs end
function GGM.IsCPUWorkActive() return active ~= nil and coroutine.running() == active.thread end

-- Outside this driver's coroutine these helpers preserve synchronous contracts.
function GGM.CPUCheckpoint()
    if not active or coroutine.running() ~= active.thread then return end
    frameSteps = frameSteps + 1
    if frameSteps >= (clock and MAX_FRAME_STEPS or FALLBACK_FRAME_STEPS)
        or (clock and frameSteps % 16 == 0 and clock() >= frameDeadline) then
        coroutine.yield()
    end
end
function GGM.CPUSort(rows, less)
    if not active or coroutine.running() ~= active.thread then return table.sort(rows, less) end
    less = less or function(a, b) return a < b end
    local size, width = #rows, 1
    local scratch = active.sortScratch or {}
    active.sortScratch = scratch
    while width < size do
        local start = 1
        while start <= size do
            local left, right = start, start + width
            local leftEnd, rightEnd = math.min(right - 1, size), math.min(start + width * 2 - 1, size)
            for out = start, rightEnd do
                if left <= leftEnd and (right > rightEnd or not less(rows[right], rows[left])) then
                    scratch[out] = rows[left]; left = left + 1
                else
                    scratch[out] = rows[right]; right = right + 1
                end
                GGM.CPUCheckpoint()
            end
            start = start + width * 2
        end
        for i = 1, size do rows[i] = scratch[i]; GGM.CPUCheckpoint() end
        width = width * 2
    end
end

function GGM.RunCPUFrame()
    if active or #jobs == 0 then idle(); return end
    frameSteps = 0
    frameDeadline = clock and (clock() + FRAME_BUDGET_MS) or nil
    -- A yielded job moves to the back, so concurrent consumers cannot starve.
    local count = #jobs
    for i = 1, count do
        local job = jobs[1]
        if not job then break end
        if job.current and not job.current() then
            remove(job, 'stale')
        else
            active = job
            local values = { coroutine.resume(job.thread) }
            active = nil
            if not values[1] then
                job.error = values[2]; remove(job, 'error')
            elseif coroutine.status(job.thread) == 'dead' then
                remove(job)
                if not job.current or job.current() then
                    job.complete(unpack(values, 2, job.resultCount or #values))
                elseif job.onCancel then job.onCancel('stale') end
            else
                table.remove(jobs, 1); jobs[#jobs + 1] = job
            end
        end
        if frameSteps >= (clock and MAX_FRAME_STEPS or FALLBACK_FRAME_STEPS)
            or (clock and clock() >= frameDeadline) then break end
    end
    idle()
end

function GGM.StartCPUJob(owner, build, complete, options)
    options = options or {}
    if owner == nil or type(build) ~= 'function' or type(complete) ~= 'function' then
        return nil, 'cpu-job-invalid'
    end
    if not driver and not GGM.CPUManualDriver then
        local api = options.api or _G
        local create = api.CreateFrame or _G.CreateFrame
        if type(create) ~= 'function' then return nil, 'cpu-driver-unavailable' end
        driver = create('Frame')
        if not driver then return nil, 'cpu-driver-unavailable' end
        clock = api.debugprofilestop or _G.debugprofilestop
        if type(clock) ~= 'function' then clock = nil end
    elseif not clock then
        local api = options.api or _G
        clock = type(api.debugprofilestop) == 'function' and api.debugprofilestop or nil
    end
    GGM.CancelCPUJob(owner)
    if #jobs >= MAX_JOBS then return nil, 'cpu-queue-full' end
    local job = { owner = owner, complete = complete, current = options.current, onCancel = options.onCancel }
    job.thread = coroutine.create(function()
        -- Store arity separately so nil error/optional results survive the handoff.
        local function results(...)
            job.resultCount = select('#', ...) + 1
            return ...
        end
        return results(build())
    end)
    jobs[#jobs + 1], byOwner[owner] = job, job
    if driver then driver:SetScript('OnUpdate', GGM.RunCPUFrame) end
    return job
end
