local _, GGM = ...

local MAX_GROUPS, MAX_CHOICES, MAX_TOTAL_CHOICES = 128, 64, 256

local function public(api, value)
    if type(api.issecretvalue) ~= "function" then return false end
    local ok, secret = pcall(api.issecretvalue, value)
    return ok and secret == false
end

local function integer(api, value, maximum)
    return public(api, value) and type(value) == "number" and value >= 1
        and value <= maximum and value == math.floor(value)
end

local function label(api, value)
    return public(api, value) and type(value) == "string" and #value > 0 and #value <= 512
end

local function arraySize(api, value, maximum)
    if not public(api, value) or type(value) ~= "table" then return nil end
    local count = 0
    for key in pairs(value) do
        if not integer(api, key, maximum) then return nil end
        count = count + 1
        if count > maximum then return nil end
    end
    for index = 1, count do
        local entry = rawget(value, index)
        if not public(api, entry) or entry == nil then return nil end
    end
    return count
end

function GGM.CreateMaterialTrackingSnapshot(api, recipeID, name, amount, model)
    if not integer(api, recipeID, 2147483647) or not label(api, name)
        or not integer(api, amount, 999) or not public(api, model) or type(model) ~= "table"
        or not public(api, model.state) or model.state ~= "ready" then return nil end
    local count = arraySize(api, model.materials, MAX_GROUPS)
    if not count then return nil end
    local saved = { recipeID = recipeID, name = name, amount = amount, materials = {} }
    local total = 0
    for index = 1, count do
        local group = model.materials[index]
        if not public(api, group) or type(group) ~= "table" or not public(api, group.optional) then return nil end
        if group.optional ~= nil and type(group.optional) ~= "boolean" then return nil end
        if not group.optional then
            if not integer(api, group.quantity, 1000000) then return nil end
            local choiceCount = arraySize(api, group.choices, MAX_CHOICES)
            if not choiceCount or choiceCount == 0 then return nil end
            total = total + choiceCount
            if total > MAX_TOTAL_CHOICES then return nil end
            local copy = { quantity = group.quantity, choices = {} }
            for choiceIndex = 1, choiceCount do
                local choice = group.choices[choiceIndex]
                if not public(api, choice) or type(choice) ~= "table"
                    or not public(api, choice.itemID) or not public(api, choice.currencyID)
                    or not label(api, choice.name) then return nil end
                local itemID, currencyID = choice.itemID, choice.currencyID
                if itemID ~= nil then
                    if currencyID ~= nil or not integer(api, itemID, 2147483647) then return nil end
                elseif not integer(api, currencyID, 2147483647) then return nil end
                copy.choices[#copy.choices + 1] = { itemID = itemID, currencyID = currencyID, name = choice.name }
            end
            copy.name = label(api, group.name) and group.name or copy.choices[1].name
            saved.materials[#saved.materials + 1] = copy
        end
    end
    if #saved.materials == 0 then return nil end
    return saved
end

function GGM.ValidateMaterialTrackingSnapshot(api, value)
    if not public(api, value) or type(value) ~= "table" then return nil end
    local saved = GGM.CreateMaterialTrackingSnapshot(api, value.recipeID, value.name, value.amount,
        { state = "ready", materials = value.materials })
    if not saved then return nil end
    saved.showAltMaterials = public(api, value.showAltMaterials) and value.showAltMaterials == true
    local position = value.position
    if public(api, position) and type(position) == "table" then
        local x, y = position.x, position.y
        if public(api, x) and public(api, y) and type(x) == "number" and type(y) == "number"
            and x == x and y == y and math.abs(x) <= 10000 and math.abs(y) <= 10000 then
            saved.position = { x = x, y = y }
        end
    end
    return saved
end

local function playerGUID(api)
    if type(api.UnitGUID) ~= "function" then return nil end
    local ok, guid = pcall(api.UnitGUID, "player")
    if ok and label(api, guid) and guid:match("^Player%-%d+%-%x+$") then return guid end
end

function GGM.SaveMaterialTracking(api, db, snapshot)
    if type(db) ~= "table" then return false end
    local guid = playerGUID(api)
    if not guid then return false end
    local saved = snapshot and GGM.ValidateMaterialTrackingSnapshot(api, snapshot) or nil
    if snapshot and not saved then return false end
    if type(db.materialTracking) ~= "table" then db.materialTracking = {} end
    db.materialTracking[guid] = saved
    return true
end

function GGM.LoadMaterialTracking(api, db)
    local guid = playerGUID(api)
    if not guid or type(db) ~= "table" or type(db.materialTracking) ~= "table" then return nil end
    return GGM.ValidateMaterialTrackingSnapshot(api, db.materialTracking[guid])
end

local function ownedCount(api, choice)
    local ok, value
    if choice.itemID then
        local fn = type(api.C_Item) == "table" and api.C_Item.GetItemCount or api.GetItemCount
        if type(fn) ~= "function" then return nil end
        ok, value = pcall(fn, choice.itemID, false, false, false, false)
    else
        local fn = type(api.C_CurrencyInfo) == "table" and api.C_CurrencyInfo.GetCurrencyInfo
        if type(fn) ~= "function" then return nil end
        local info
        ok, info = pcall(fn, choice.currencyID)
        if not ok or not public(api, info) or type(info) ~= "table" then return nil end
        value = info.quantity
    end
    if not ok or not public(api, value) or type(value) ~= "number" or value < 0
        or value > 2147483647 or value ~= math.floor(value) then return nil end
    return value
end

local function choiceName(api, choice)
    local fn = choice.itemID and type(api.C_Item) == "table" and api.C_Item.GetItemNameByID
    if type(fn) == "function" then
        local ok, value = pcall(fn, choice.itemID)
        if ok and label(api, value) then return value end
    end
    return choice.name
end

function GGM.BuildMaterialTrackingRows(api, snapshot)
    local saved = GGM.ValidateMaterialTrackingSnapshot(api, snapshot)
    if not saved then return {} end
    local rows, edges, capacity, resources = {}, {}, {}, {}
    local source, sink = "source", "sink"
    local function edge(a, b, amount)
        edges[a], edges[b] = edges[a] or {}, edges[b] or {}
        capacity[a], capacity[b] = capacity[a] or {}, capacity[b] or {}
        edges[a][#edges[a] + 1], edges[b][#edges[b] + 1] = b, a
        capacity[a][b], capacity[b][a] = amount, 0
    end
    for index, group in ipairs(saved.materials) do
        local node, names, seen = "group" .. index, {}, {}
        local row = { required = group.quantity * saved.amount, unknown = false }
        rows[index] = row
        edge(source, node, row.required)
        for _, choice in ipairs(group.choices) do
            local key = choice.itemID and "item" .. choice.itemID or "currency" .. choice.currencyID
            if not seen[key] then
                seen[key] = true
                names[#names + 1] = choiceName(api, choice)
                if resources[key] == nil then
                    local count = ownedCount(api, choice)
                    resources[key] = count or false
                    edge(key, sink, count or 0)
                end
                if resources[key] == false then row.unknown = true end
                edge(node, key, row.required)
            end
        end
        row.name = table.concat(names, " / ")
    end
    -- Residual paths reassign interchangeable reagents when a later group needs
    -- an item already assigned to an earlier group. Work is bounded by the
    -- validated group/choice limits, rather than the quantity of individual items.
    while true do
        local queue, previous, head = { source }, { [source] = true }, 1
        while head <= #queue and not previous[sink] do
            local node = queue[head]
            head = head + 1
            for _, nextNode in ipairs(edges[node] or {}) do
                if not previous[nextNode] and capacity[node][nextNode] > 0 then
                    previous[nextNode] = node
                    queue[#queue + 1] = nextNode
                end
            end
        end
        if not previous[sink] then break end
        local node, amount = sink, math.huge
        while node ~= source do
            local parent = previous[node]
            amount = math.min(amount, capacity[parent][node])
            node = parent
        end
        node = sink
        while node ~= source do
            local parent = previous[node]
            capacity[parent][node] = capacity[parent][node] - amount
            capacity[node][parent] = capacity[node][parent] + amount
            node = parent
        end
    end
    for index, row in ipairs(rows) do
        local assigned = row.required - capacity[source]["group" .. index]
        row.complete = assigned >= row.required
        row.owned = (not row.unknown or row.complete) and assigned or nil
    end
    return rows
end
