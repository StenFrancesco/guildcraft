local ADDON_NAME, GGM = ...

local function checkpoint()
    if type(GGM.CPUCheckpoint) == "function" then GGM.CPUCheckpoint() end
end

local function hasSelections(selection)
    if type(selection) ~= "table" then return false end
    for _, selected in pairs(selection) do
        checkpoint()
        if selected == true then return true end
    end
    return false
end

local function matchesSelection(values, selection)
    if not hasSelections(selection) then return true end
    if type(values) ~= "table" then return false end
    for _, value in ipairs(values) do
        checkpoint()
        if selection[value] == true then return true end
    end
    return false
end

local function hasCraftableItem(entry)
    if entry.craftable == true then return true end
    return type(entry.craftableCount) == "number" and entry.craftableCount > 0
end

local MAX_RECIPES, MAX_CATEGORIES, MAX_ENCHANT_TARGETS = 2048, 512, 128

local function public(api, value)
    if type(api) ~= "table" or type(api.issecretvalue) ~= "function" then return false end
    local ok, secret = pcall(api.issecretvalue, value)
    return ok and secret == false
end

local function field(api, object, key)
    if not public(api, object) or type(object) ~= "table" then return nil end
    local value = rawget(object, key)
    if public(api, value) then return value end
end

local function positiveInteger(api, value)
    return public(api, value) and type(value) == "number"
        and value > 0 and value <= 2147483647 and value == math.floor(value)
end

local function nonnegativeInteger(api, value)
    return public(api, value) and type(value) == "number"
        and value >= 0 and value <= 2147483647 and value == math.floor(value)
end

local function call(api, fn, ...)
    if type(fn) ~= "function" then return false end
    local result = { pcall(fn, ...) }
    if result[1] ~= true then return false end
    table.remove(result, 1)
    for _, value in ipairs(result) do
        if not public(api, value) then return false end
    end
    return true, unpack(result)
end

local function pack(...)
    return { n = select("#", ...), ... }
end

local function callReturns(api, fn, ...)
    if type(fn) ~= "function" then return false end
    local result = pack(pcall(fn, ...))
    if result[1] ~= true then return false end
    for index = 2, result.n do
        if not public(api, result[index]) then return false end
    end
    return true, unpack(result, 2, result.n)
end

local function newFilterModel(professionID)
    return {
        state = "unavailable",
        professionID = professionID,
        recipes = {},
        categories = {},
        slots = {},
        availability = {
            profession = "unavailable",
            materials = "unavailable",
            bank = "unverified",
            enchantTargets = "unavailable",
            categories = "unavailable",
            slots = "unavailable",
        },
    }
end

local function cloneCatalogRecipe(api, recipe)
    if not public(api, recipe) or type(recipe) ~= "table" then return nil end
    local recipeID = field(api, recipe, "recipeID")
    local name = field(api, recipe, "name")
    if not positiveInteger(api, recipeID) or type(name) ~= "string" or name == "" or #name > 512 then return nil end
    local outputIcon = field(api, recipe, "outputIcon")
    if not positiveInteger(api, outputIcon) then outputIcon = nil end
    return {
        recipeID = recipeID,
        name = name,
        searchName = string.lower(name),
        outputIcon = outputIcon,
        knownBy = field(api, recipe, "knownBy"),
        learned = nil,
        craftable = false,
        craftableCount = nil,
        bagCraftableCount = nil,
        categoryIDs = {},
        categoryPath = {},
        slotKeys = {},
        slotPath = {},
        metadataState = "unavailable",
    }
end

local CATEGORY_MAX_DEPTH = 16

local function categoryNodeBuilder(api, trade, model)
    local nodesByID, roots, invalid = {}, {}, false

    local ensure
    ensure = function(categoryID, seen, depth)
        checkpoint()
        if not positiveInteger(api, categoryID) or depth > CATEGORY_MAX_DEPTH then
            invalid = true
            return nil
        end
        if seen[categoryID] then invalid = true; return nil end
        if nodesByID[categoryID] then return nodesByID[categoryID] end

        local infoOK, info = call(api, trade.GetCategoryInfo, categoryID)
        if not infoOK or type(info) ~= "table" then invalid = true; return nil end
        local name = field(api, info, "name")
        local id = field(api, info, "categoryID")
        if not positiveInteger(api, id) or id ~= categoryID
            or type(name) ~= "string" or name == "" or #name > 512 then
            invalid = true
            return nil
        end

        local node = {
            id = id,
            key = "category:" .. tostring(id),
            name = name,
            uiOrder = field(api, info, "uiOrder"),
            parentCategoryID = field(api, info, "parentCategoryID"),
            children = {},
        }
        nodesByID[id] = node
        local parentID = node.parentCategoryID
        if positiveInteger(api, parentID) and parentID ~= id then
            seen[id] = true
            local parent = ensure(parentID, seen, depth + 1)
            seen[id] = nil
            if parent then
                node.parent = parent
                parent.children[#parent.children + 1] = node
            else
                invalid = true
                roots[#roots + 1] = node
            end
        else
            roots[#roots + 1] = node
        end
        return node
    end

    local categoriesOK = false
    if type(trade.GetCategories) == "function" then
        local results = pack(pcall(trade.GetCategories))
        if results[1] == true then
            local ids = {}
            if results.n == 2 and public(api, results[2]) and type(results[2]) == "table" then
                local list = results[2]
                local count, highest = 0, 0
                for key in pairs(list) do
                    checkpoint()
                    if not positiveInteger(api, key) or key > MAX_CATEGORIES then invalid = true; break end
                    count, highest = count + 1, math.max(highest, key)
                end
                if count == highest then
                    for index = 1, count do ids[#ids + 1] = rawget(list, index) end
                    categoriesOK = not invalid
                else
                    invalid = true
                end
            else
                categoriesOK = true
                for index = 2, results.n do
                    local categoryID = results[index]
                    if not positiveInteger(api, categoryID) or #ids >= MAX_CATEGORIES then
                        invalid = true
                        categoriesOK = false
                        break
                    end
                    ids[#ids + 1] = categoryID
                end
            end
            if categoriesOK then
                for _, categoryID in ipairs(ids) do ensure(categoryID, {}, 1) end
            end
        else
            invalid = true
        end
    end

    local function path(categoryID)
        local node = ensure(categoryID, {}, 1)
        if not node then return {}, {} end
        local pathNodes = {}
        while node do
            table.insert(pathNodes, 1, node)
            node = node.parent
        end
        local ids, names = {}, {}
        for _, item in ipairs(pathNodes) do
            ids[#ids + 1] = item.id
            names[#names + 1] = item.name
        end
        return ids, names
    end

    local function less(left, right)
        local a, b = left.uiOrder, right.uiOrder
        if type(a) ~= "number" or a ~= a then a = math.huge end
        if type(b) ~= "number" or b ~= b then b = math.huge end
        if a ~= b then return a < b end
        local leftName, rightName = string.lower(left.name), string.lower(right.name)
        if leftName ~= rightName then return leftName < rightName end
        return left.id < right.id
    end

    local function sortTree(nodes)
        local sort = GGM.CPUSort or table.sort
        sort(nodes, less)
        for _, node in ipairs(nodes) do checkpoint(); sortTree(node.children) end
    end

    return roots, nodesByID, path, sortTree, function() return categoriesOK, invalid end
end

local EQUIPMENT_NAMES = {
    INVTYPE_HEAD = "Head", INVTYPE_NECK = "Neck", INVTYPE_SHOULDER = "Shoulders",
    INVTYPE_CLOAK = "Cloak", INVTYPE_CHEST = "Chest", INVTYPE_ROBE = "Chest",
    INVTYPE_WRIST = "Wrist", INVTYPE_HAND = "Hands", INVTYPE_WAIST = "Waist",
    INVTYPE_LEGS = "Legs", INVTYPE_FEET = "Feet", INVTYPE_FINGER = "Ring",
    INVTYPE_TRINKET = "Trinket", INVTYPE_SHIELD = "Shield", INVTYPE_WEAPON = "One-Handed Weapon",
    INVTYPE_WEAPONMAINHAND = "Main-Hand Weapon", INVTYPE_WEAPONOFFHAND = "Off-Hand Weapon",
    INVTYPE_2HWEAPON = "Two-Handed Weapon", INVTYPE_RANGED = "Ranged Weapon",
    INVTYPE_RANGEDRIGHT = "Ranged Weapon", INVTYPE_THROWN = "Thrown Weapon",
    INVTYPE_HOLDABLE = "Off-Hand", INVTYPE_BODY = "Shirt", INVTYPE_TABARD = "Tabard",
}

local WEAPON_PREFIXES = {
    INVTYPE_WEAPON = "One-Handed", INVTYPE_WEAPONMAINHAND = "Main-Hand",
    INVTYPE_WEAPONOFFHAND = "Off-Hand", INVTYPE_2HWEAPON = "Two-Handed",
    INVTYPE_RANGED = "Ranged", INVTYPE_RANGEDRIGHT = "Ranged", INVTYPE_THROWN = "Thrown",
}

local function equipmentName(api, inventoryType, enchantTarget)
    local name = EQUIPMENT_NAMES[inventoryType]
    if enchantTarget then return name end
    if name and public(api, api[inventoryType]) and type(api[inventoryType]) == "string" then
        if inventoryType == "INVTYPE_2HWEAPON" then return api[inventoryType] .. " Weapon" end
        return api[inventoryType]
    end
    return name
end

local function addChild(parent, key, name)
    for _, child in ipairs(parent.children) do
        checkpoint()
        if child.key == key then return child end
    end
    local child = { key = key, name = name, children = {} }
    parent.children[#parent.children + 1] = child
    return child
end

local function slotNode(roots, key, name)
    for _, root in ipairs(roots) do
        checkpoint()
        if root.key == key then return root end
    end
    local node = { key = key, name = name, children = {} }
    roots[#roots + 1] = node
    return node
end

local function deriveItemSlot(api, itemInfo, enchantTarget)
    local itemType = field(api, itemInfo, "itemType")
    local itemSubType = field(api, itemInfo, "itemSubType")
    local itemEquipLoc = field(api, itemInfo, "itemEquipLoc")
    local classID = field(api, itemInfo, "classID")
    local subClassID = field(api, itemInfo, "subClassID")
    if type(itemEquipLoc) ~= "string" or itemEquipLoc == "" or itemEquipLoc == "INVTYPE_NON_EQUIP" then
        return nil
    end
    local leafName = equipmentName(api, itemEquipLoc, enchantTarget)
    if enchantTarget then
        if not leafName then return nil end
        return "enchant:" .. itemEquipLoc, leafName, "enchant-targets", "Enchant Targets"
    end
    if type(classID) ~= "number" then
        if itemType == "Weapon" then classID = 2
        elseif itemType == "Armor" then classID = 4 end
    end
    if classID == 2 then
        local prefix = WEAPON_PREFIXES[itemEquipLoc]
        if prefix and type(itemSubType) == "string" and itemSubType ~= "" then
            leafName = prefix .. " " .. itemSubType
        elseif not leafName then
            leafName = itemSubType
        end
        if not leafName then return nil end
        return "weapon:" .. tostring(subClassID or 0) .. ":" .. itemEquipLoc,
            leafName, "weapons", "Weapons"
    end
    if classID == 4 then
        if not leafName then return nil end
        if type(itemSubType) == "string" and itemSubType ~= "" then
            return "armor:" .. tostring(subClassID or 0) .. ":" .. itemEquipLoc,
                leafName, "armor", "Armor", "armor-type:" .. tostring(subClassID or itemSubType), itemSubType
        end
        return "armor:" .. tostring(subClassID or 0) .. ":" .. itemEquipLoc,
            leafName, "armor", "Armor"
    end
    if not leafName then return nil end
    return "equipment:" .. tostring(classID or 0) .. ":" .. itemEquipLoc,
        leafName, "equipment", "Other Equipment"
end

local function appendUnique(values, value)
    for _, existing in ipairs(values) do
        checkpoint()
        if existing == value then return end
    end
    values[#values + 1] = value
end

local function insertSlot(roots, key, name, groupKey, groupName, subKey, subName)
    local group = slotNode(roots, groupKey, groupName)
    if subKey then group = addChild(group, subKey, subName) end
    local leaf = addChild(group, key, name)
    leaf.children = nil
end

local function itemMetadata(api, itemID)
    local itemAPI = type(api) == "table" and api.C_Item or nil
    local fn = type(itemAPI) == "table" and itemAPI.GetItemInfoInstant or api.GetItemInfoInstant
    if type(fn) ~= "function" then return nil end
    local ok, id, itemType, itemSubType, itemEquipLoc, icon, classID, subClassID = callReturns(api, fn, itemID)
    if not ok or not positiveInteger(api, id) or id ~= itemID then return nil end
    return {
        itemType = itemType,
        itemSubType = itemSubType,
        itemEquipLoc = itemEquipLoc,
        classID = classID,
        subClassID = subClassID,
        icon = icon,
    }
end

local function readRecipeOutput(api, trade, recipeID, recipeInfo)
    local itemID, outputKnown
    if type(trade.GetRecipeSchematic) == "function" then
        local ok, schematic = call(api, trade.GetRecipeSchematic, recipeID, false)
        if ok and type(schematic) == "table" then
            outputKnown = true
            itemID = field(api, schematic, "outputItemID")
        end
    end
    if not positiveInteger(api, itemID) and type(trade.GetRecipeOutputItemData) == "function" then
        local ok, output = call(api, trade.GetRecipeOutputItemData, recipeID)
        if ok and type(output) == "table" then
            outputKnown = true
            itemID = field(api, output, "itemID")
        end
    end
    if not positiveInteger(api, itemID) then
        itemID = field(api, recipeInfo, "itemID")
        if positiveInteger(api, itemID) then outputKnown = true end
    end
    if not positiveInteger(api, itemID) then return nil, outputKnown == true end
    return itemID, true
end

local function addOutputSlot(api, model, recipe, itemID, slotRoots)
    if not positiveInteger(api, itemID) then return nil end
    local itemInfo = itemMetadata(api, itemID)
    if not itemInfo then return nil end
    if type(itemInfo.itemEquipLoc) == "string"
        and (itemInfo.itemEquipLoc == "" or itemInfo.itemEquipLoc == "INVTYPE_NON_EQUIP") then
        return false
    end
    if type(itemInfo.itemEquipLoc) ~= "string" then return nil end
    local key, name, groupKey, groupName, subKey, subName = deriveItemSlot(api, itemInfo, false)
    if not key then
        if itemInfo.classID == 2 or itemInfo.classID == 4 then return nil end
        return false
    end
    insertSlot(slotRoots, key, name, groupKey, groupName, subKey, subName)
    appendUnique(recipe.slotKeys, key)
    recipe.slotPath[#recipe.slotPath + 1] = name
    return true
end

local function addEnchantTargets(api, trade, model, recipeID, recipe, slotRoots)
    if type(trade.GetEnchantItems) ~= "function" then return false end
    local ok, targetGUIDs = call(api, trade.GetEnchantItems, recipeID)
    if not ok or type(targetGUIDs) ~= "table" then return false end
    model.availability.enchantTargets = "inventory-limited"
    local count, highest = 0, 0
    for index in pairs(targetGUIDs) do
        checkpoint()
        if not positiveInteger(api, index) or index > MAX_ENCHANT_TARGETS then return false end
        count, highest = count + 1, math.max(highest, index)
    end
    if count ~= highest then return false end
    local itemAPI = api.C_Item
    if type(itemAPI) ~= "table" or type(itemAPI.GetItemIDByGUID) ~= "function" then return false end
    local found = false
    for index = 1, count do
        checkpoint()
        local guid = rawget(targetGUIDs, index)
        if not public(api, guid) or type(guid) ~= "string" or #guid == 0 or #guid > 128 then return false end
        local idOK, itemID = call(api, itemAPI.GetItemIDByGUID, guid)
        if idOK and positiveInteger(api, itemID) then
            local itemInfo = itemMetadata(api, itemID)
            if itemInfo then
                local key, name, groupKey, groupName = deriveItemSlot(api, itemInfo, true)
                if key then
                    insertSlot(slotRoots, key, name, groupKey, groupName)
                    appendUnique(recipe.slotKeys, key)
                    recipe.slotPath[#recipe.slotPath + 1] = name
                    found = true
                end
            end
        end
    end
    return found or count == 0
end

local function sortSlotTree(roots)
    local sort = GGM.CPUSort or table.sort
    sort(roots, function(left, right)
        local a, b = string.lower(left.name), string.lower(right.name)
        if a ~= b then return a < b end
        return left.key < right.key
    end)
    for _, root in ipairs(roots) do
        checkpoint()
        if root.children then sortSlotTree(root.children) end
    end
end

local function denseArraySize(api, value, maximum)
    if not public(api, value) or type(value) ~= "table" then return nil end
    local count, highest = 0, 0
    for key, entry in pairs(value) do
        checkpoint()
        if not positiveInteger(api, key) or key > maximum or not public(api, entry) then return nil end
        count, highest = count + 1, math.max(highest, key)
    end
    if count ~= highest then return nil end
    return count
end

local function recipeCraftableFromMaterials(api, recipe, includeBank, noMaterialCraftable)
    if type(GGM.BuildRecipeMaterialDetails) ~= "function"
        or type(GGM.CreateMaterialTrackingSnapshot) ~= "function"
        or type(GGM.BuildMaterialTrackingRows) ~= "function"
        or type(GGM.GetMaximumMaterialTrackingAmount) ~= "function" then
        return false, nil, false, nil
    end
    local detailsOK, details = pcall(GGM.BuildRecipeMaterialDetails, api, recipe.recipeID)
    if not detailsOK or type(details) ~= "table" or details.state ~= "ready"
        or type(details.materials) ~= "table" then return false, nil, false, nil end
    local snapshot = GGM.CreateMaterialTrackingSnapshot(api, recipe.recipeID, recipe.name, 1, details)
    if not snapshot then
        for _, group in ipairs(details.materials) do
            checkpoint()
            if type(group) == "table" and group.optional ~= true then
                return false, nil, false, nil
            end
        end
        local craftable = noMaterialCraftable == true
        local count = craftable and 1 or 0
        return craftable, count, true, count
    end
    local bagCraftableCount = GGM.GetMaximumMaterialTrackingAmount(api, snapshot, false)
    local rowsOK, rows = pcall(GGM.BuildMaterialTrackingRows, api, snapshot, includeBank == true)
    if not rowsOK or type(rows) ~= "table" or #rows ~= #snapshot.materials then
        return false, nil, false, bagCraftableCount
    end
    for _, row in ipairs(rows) do
        checkpoint()
        if type(row) ~= "table" or type(row.complete) ~= "boolean" then
            return false, nil, false, bagCraftableCount
        end
        if not row.complete then
            if row.unknown == true then return false, nil, false, bagCraftableCount end
            return false, 0, true, bagCraftableCount
        end
    end
    if bagCraftableCount == nil then return true, 1, false, nil end
    return true, 1, true, bagCraftableCount
end

function GGM.BuildProfessionRecipeFilterModel(api, professionID, catalogRecipes, bankVerified, preserveCatalog)
    local model = newFilterModel(professionID)
    if type(api) ~= "table" or not positiveInteger(api, professionID) or type(catalogRecipes) ~= "table" then
        return model
    end

    local recipesByID = {}
    local recipeCount, highest = 0, 0
    for index in pairs(catalogRecipes) do
        checkpoint()
        if not positiveInteger(api, index) or index > MAX_RECIPES then
            model.state = "partial"
            return model
        end
        recipeCount, highest = recipeCount + 1, math.max(highest, index)
    end
    if recipeCount ~= highest then
        model.state = "partial"
        return model
    end
    for index = 1, recipeCount do
        checkpoint()
        local copy = cloneCatalogRecipe(api, rawget(catalogRecipes, index))
        if copy and not recipesByID[copy.recipeID] then
            recipesByID[copy.recipeID] = copy
            model.recipes[#model.recipes + 1] = copy
        else
            model.state = "partial"
        end
    end

    local trade = api.C_TradeSkillUI
    if type(trade) ~= "table" or type(trade.IsTradeSkillReady) ~= "function"
        or type(trade.IsTradeSkillLinked) ~= "function" or type(trade.GetBaseProfessionInfo) ~= "function" then
        return model
    end
    local readyOK, ready = call(api, trade.IsTradeSkillReady)
    local linkedOK, linked = call(api, trade.IsTradeSkillLinked)
    local professionOK, profession = call(api, trade.GetBaseProfessionInfo)
    if not readyOK or ready ~= true or not linkedOK or linked ~= false
        or not professionOK or type(profession) ~= "table"
        or field(api, profession, "professionID") ~= professionID then
        return model
    end
    for _, externalMethod in ipairs({ "IsTradeSkillGuild", "IsTradeSkillGuildMember" }) do
        if type(trade[externalMethod]) == "function" then
            local externalOK, external = call(api, trade[externalMethod])
            if not externalOK or external ~= false then return model end
        end
    end
    model.availability.profession = "available"
    bankVerified = bankVerified == true
    model.availability.bank = bankVerified and "verified" or "unverified"

    local savedRecipesByID = recipesByID
    local liveRecipeInfoByID = {}
    local liveRecipeIDsOK, liveRecipeIDs = call(api, trade.GetAllRecipeIDs)
    local liveRecipeCount = liveRecipeIDsOK and denseArraySize(api, liveRecipeIDs, MAX_RECIPES) or nil
    if liveRecipeCount ~= nil then
        local liveRecipes, liveRecipesByID = {}, {}
        for index = 1, liveRecipeCount do
            checkpoint()
            local recipeID = rawget(liveRecipeIDs, index)
            if not positiveInteger(api, recipeID) or liveRecipesByID[recipeID] then
                model.state = "partial"
            else
                local infoOK, info = call(api, trade.GetRecipeInfo, recipeID)
                local learned
                if infoOK then learned = field(api, info, "learned") end
                local name = infoOK and field(api, info, "name") or nil
                local saved = savedRecipesByID[recipeID]
                if infoOK and type(info) == "table" then
                    if type(name) ~= "string" or name == "" or #name > 512 then
                        name = saved and saved.name or nil
                    end
                    if type(name) == "string" and name ~= "" and #name <= 512 then
                        local icon = field(api, info, "icon")
                        local recipe = cloneCatalogRecipe(api, {
                            recipeID = recipeID,
                            name = name,
                            outputIcon = icon,
                        })
                        if recipe then
                            liveRecipesByID[recipeID] = recipe
                            liveRecipes[#liveRecipes + 1] = recipe
                            liveRecipeInfoByID[recipeID] = info
                            if type(learned) ~= "boolean" then model.state = "partial" end
                        else
                            model.state = "partial"
                        end
                    else
                        model.state = "partial"
                    end
                else
                    model.state = "partial"
                end
            end
        end
        if preserveCatalog ~= true then model.recipes, recipesByID = liveRecipes, liveRecipesByID end
        model.liveRecipeListAvailable = model.state ~= "partial"
    else
        model.state = "partial"
        model.liveRecipeListAvailable = false
    end

    local categoryRoots, _, getCategoryPath, sortCategoryTree, getCategoryStatus = categoryNodeBuilder(api, trade, model)
    local categoryIncomplete = false
    local categorySourceAvailable = false
    do
        local _, invalid = getCategoryStatus()
        categorySourceAvailable, categoryIncomplete = getCategoryStatus()
        if invalid then categoryIncomplete = true end
    end

    local slotRoots = {}
    local materialUnavailable = type(GGM.BuildRecipeMaterialDetails) ~= "function"
        or type(GGM.CreateMaterialTrackingSnapshot) ~= "function"
        or type(GGM.BuildMaterialTrackingRows) ~= "function"
    local materialPartial = false
    local metadataPartial = model.state == "partial"
    local slotMetadataPartial = false
    for _, recipe in ipairs(model.recipes) do
        checkpoint()
        local info = liveRecipeInfoByID[recipe.recipeID]
        local recipeOK = info ~= nil
        if not recipeOK and (liveRecipeCount == nil or preserveCatalog == true) then
            recipeOK, info = call(api, trade.GetRecipeInfo, recipe.recipeID)
        end
        if not recipeOK or type(info) ~= "table" then
            metadataPartial = true
            materialPartial = true
            recipe.metadataState = "unavailable"
        else
            local infoID = field(api, info, "recipeID")
            local learned = field(api, info, "learned")
            if infoID ~= nil and infoID ~= recipe.recipeID then learned = nil end
            if type(learned) == "boolean" then
                recipe.learned = learned
                recipe.metadataState = "available"
                local liveName = field(api, info, "name")
                if type(liveName) == "string" and liveName ~= "" and #liveName <= 512 then
                    recipe.name = liveName
                    recipe.searchName = string.lower(liveName)
                end
                local liveIcon = field(api, info, "icon")
                if positiveInteger(api, liveIcon) then recipe.outputIcon = liveIcon end

                if learned then
                    local craftable, count, materialOK, bagCraftableCount = recipeCraftableFromMaterials(api, recipe,
                        bankVerified, field(api, info, "craftable"))
                    recipe.bagCraftableCount = bagCraftableCount
                    if materialOK then
                        recipe.craftable = craftable
                        recipe.craftableCount = count
                    else
                        materialPartial = true
                        recipe.metadataState = "partial"
                    end
                else
                    recipe.craftableCount = 0
                    recipe.bagCraftableCount = 0
                end

                local categoryID = field(api, info, "categoryID")
                if positiveInteger(api, categoryID) then
                    local categoryIDs, categoryPath = getCategoryPath(categoryID)
                    recipe.categoryIDs, recipe.categoryPath = categoryIDs, categoryPath
                    if #categoryIDs == 0 then categoryIncomplete = true end
                else
                    categoryIncomplete = true
                end

                local outputItemID, outputKnown = readRecipeOutput(api, trade, recipe.recipeID, info)
                if outputItemID then
                    local slotState = addOutputSlot(api, model, recipe, outputItemID, slotRoots)
                    if slotState == nil then
                        slotMetadataPartial = true
                    end
                elseif professionID == 333 or field(api, info, "isEnchantingRecipe") == true then
                    if not addEnchantTargets(api, trade, model, recipe.recipeID, recipe, slotRoots) then
                        slotMetadataPartial = true
                    end
                elseif not outputKnown then
                    slotMetadataPartial = true
                end
            else
                metadataPartial = true
                materialPartial = true
            end
        end
    end

    sortCategoryTree(categoryRoots)
    sortSlotTree(slotRoots)
    model.categories, model.slots = categoryRoots, slotRoots
    model.availability.categories = categorySourceAvailable and not categoryIncomplete
        and "available" or (#categoryRoots > 0 and "partial" or "unavailable")
    model.availability.materials = materialUnavailable and "unavailable"
        or ((materialPartial or not bankVerified) and "partial" or "available")
    model.availability.slots = #slotRoots > 0 and (slotMetadataPartial and "partial" or "available")
        or (slotMetadataPartial and "partial" or "none")
    model.state = (metadataPartial or categoryIncomplete or slotMetadataPartial or materialPartial or not bankVerified)
        and "partial" or "ready"
    if model.state == "ready" and materialUnavailable then model.state = "partial" end
    return model
end

function GGM.CreateProfessionRecipeFilterState()
    return {
        showLearned = true,
        showUnlearned = true,
        haveMaterials = false,
        categoryIDs = {},
        slotKeys = {},
    }
end

function GGM.FilterProfessionRecipeEntries(entries, query, state)
    local filtered = {}
    if type(entries) ~= "table" then return filtered end
    if type(state) ~= "table" then state = GGM.CreateProfessionRecipeFilterState() end
    local needle = type(query) == "string" and string.lower(query) or ""
    local categories = state.categoryIDs
    local slots = state.slotKeys
    local filterCategories = hasSelections(categories)
    local filterSlots = hasSelections(slots)

    for _, entry in ipairs(entries) do
        checkpoint()
        if type(entry) == "table" then
            local learned = entry.learned
            local learningMatches = (learned == true and state.showLearned == true)
                or (learned == false and state.showUnlearned == true)
                or (learned == nil and state.showLearned == true and state.showUnlearned == true)
            local materialsMatch = state.haveMaterials ~= true
                or (learned == true and hasCraftableItem(entry))
            local categoryMatches = not filterCategories
                or matchesSelection(entry.categoryIDs, categories)
            local slotMatches = not filterSlots
                or matchesSelection(entry.slotKeys, slots)
            local name = type(entry.searchName) == "string" and entry.searchName
                or (type(entry.name) == "string" and string.lower(entry.name) or "")
            local searchMatches = needle == "" or string.find(name, needle, 1, true) ~= nil

            if learningMatches and materialsMatch and categoryMatches and slotMatches and searchMatches then
                table.insert(filtered, entry)
            end
        end
    end
    return filtered
end
