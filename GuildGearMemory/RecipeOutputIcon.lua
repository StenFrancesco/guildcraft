local _, GGM = ...

function GGM.ResolveRecipeOutputIcon(api, recipeID, cachedIcon)
    local function validIcon(value)
        return type(value) == "number" and value > 0 and value < math.huge
            and value == math.floor(value)
    end
    local function public(value)
        if type(api) ~= "table" or type(api.issecretvalue) ~= "function" then return false end
        local ok, secret = pcall(api.issecretvalue, value)
        return ok and secret == false
    end
    -- SavedVariables contain ordinary, already validated metadata. When a
    -- safety checker exists, still reject restricted values before comparison.
    if type(api) == "table" and type(api.issecretvalue) == "function" then
        if public(cachedIcon) and validIcon(cachedIcon) then return cachedIcon end
    elseif validIcon(cachedIcon) then
        return cachedIcon
    end
    if type(api) ~= "table" or type(api.issecretvalue) ~= "function" then return nil end
    if not public(recipeID) or not validIcon(recipeID) then return nil end
    if type(api.InCombatLockdown) ~= "function" then return nil end
    local ok, combat = pcall(api.InCombatLockdown)
    if not ok or not public(combat) or combat ~= false then return nil end
    local trade = api.C_TradeSkillUI
    if type(trade) ~= "table" or type(trade.GetRecipeOutputItemData) ~= "function" then return nil end
    local outputOK, output = pcall(trade.GetRecipeOutputItemData, recipeID)
    if not outputOK or not public(output) or type(output) ~= "table" then return nil end
    local icon = rawget(output, "icon")
    if public(icon) and validIcon(icon) then return icon end
    return nil
end
