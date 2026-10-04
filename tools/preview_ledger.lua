-- Development-only preview: executes the real UI layout with the test API.
-- Does not read a game client. Native models/icons are represented by placeholders.
package.path = "./?.lua;./?/init.lua;" .. package.path
require("tests.snapshot_test_ui_test")
local T = require("tests.testlib")
local helpers = {}
for _, test in ipairs(T.tests) do
    if test.name == "guild gear browser rows show name and realm and selecting renders saved identity time and slots" then
        local index = 1
        while true do
            local name, value = debug.getupvalue(test.fn, index)
            if not name then break end
            helpers[name] = value
            index = index + 1
        end
    end
end
local nodes = {}
local function instrument(control, kind, parent, layer, font, sublayer)
    if control.previewID then return control end
    control.previewID = #nodes + 1
    control.kind, control.parent, control.layer = kind, parent, layer
    control.font, control.sublayer, control.visible = font, sublayer, true
    local setText = control.SetText
    control.SetFontString = function(self, label) self.previewFontString = label end
    control.SetText = function(self, value)
        setText(self, value)
        if self.previewFontString then self.previewFontString:SetText(value) end
    end
    nodes[#nodes + 1] = control
    local texture, label = control.CreateTexture, control.CreateFontString
    control.CreateTexture = function(self, name, drawLayer, template, level)
        return instrument(texture(self), "Texture", self, drawLayer, nil, level)
    end
    control.CreateFontString = function(self, name, drawLayer, fontName)
        return instrument(label(self), "Text", self, drawLayer, fontName)
    end
    control.SetJustifyH = function(self, value) self.justify = value end
    return control
end
local GGM, api = helpers.loadUI(), helpers.makeBrowserAPI()
instrument(api.UIParent, "Frame")
api.UIParent:SetSize(1180, 720)
local create = api.CreateFrame
api.CreateFrame = function(kind, name, parent, template)
    local result = instrument(create(kind, name, parent), kind, parent)
    if result.TitleText then instrument(result.TitleText, "Text", result, "OVERLAY", "GameFontNormalSmall") end
    return result
end
api.date = function() return "2026-10-04 12:30" end
local record = helpers.makeRecord(GGM)
local frame = helpers.showBrowser(GGM, api, helpers.makeDB(GGM, { record }))
if arg[1] == "professions" then
    local recipes = {
        { recipeID = 11, name = "Copper Bracers", knownBy = {
            { key = "Alice-Silvermoon", name = "Alice", realm = "Silvermoon", savedDate = "2026-10-04" },
        } },
        { recipeID = 12, name = "Runed Copper Belt", knownBy = {} },
    }
    GGM.BuildProfessionRecipeCatalog = function()
        return { state = "ready", recipes = recipes, hasSnapshot = true }
    end
    GGM.BuildRecipeMaterialDetails = function()
        return { state = "ready", materials = {
            { name = "Copper Bar", quantity = 2, optional = false, choices = {
                { itemID = 1, name = "Copper Bar" },
            } },
            { name = "Rough Grinding Stone", quantity = 1, optional = false, choices = {
                { itemID = 2, name = "Rough Grinding Stone" },
            } },
        } }
    end
    GGM.SelectGuildGearBrowserTab(frame, "Professions")
    GGM.SelectProfession(frame, "Blacksmithing")
    GGM.ShowRecipeDetailsWindow(frame, recipes[1])
end
local function quote(value)
    return '"' .. tostring(value):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r') .. '"'
end
local function encode(value)
    if type(value) == "table" then
        assert(not value.previewID, "Control leaked into JSON: " .. tostring(value.previewID))
        local fields = {}
        for key, item in pairs(value) do fields[#fields + 1] = quote(key) .. ":" .. encode(item) end
        return "{" .. table.concat(fields, ",") .. "}"
    elseif type(value) == "string" then return quote(value)
    elseif type(value) == "number" or type(value) == "boolean" then return tostring(value)
    else return "null" end
end
local out = {}
for _, node in ipairs(nodes) do
    local points = {}
    for i, p in ipairs(node.points or {}) do
        points[tostring(i)] = { anchor = p.point, relative = p.relativeTo and p.relativeTo.previewID,
            relativeAnchor = p.relativePoint, x = p.x or 0, y = p.y or 0 }
    end
    out[#out + 1] = encode({ id = node.previewID, kind = node.kind, parent = node.parent and node.parent.previewID,
        width = node.width, height = node.height, text = type(node.text) == "string" and node.text or nil, font = node.font, justify = node.justify,
        visible = node.visible, texture = node.texture, color = node.color, textColor = node.textColor,
        vertexColor = node.vertexColor, alpha = node.alpha, layer = node.layer, sublayer = node.sublayer,
        allPoints = node.allPointsTo and node.allPointsTo.previewID, points = points })
end
local file = assert(io.open("tools/ledger-layout.json", "w"))
file:write("[" .. table.concat(out, ",") .. "]")
file:close()
print("Exported real Lua layout for a development preview (icons/model are placeholders).")
