"""Render the real Bank Lua page with synthetic data, entirely outside WoW.

Uses the existing journal renderer and a Lua executable; no lupa is required.
"""
from pathlib import Path
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import types

PROJECT = Path(__file__).resolve().parents[1]
try:
    from lupa.lua51 import LuaRuntime
except ImportError:
    stub = types.ModuleType("lupa.lua51")
    stub.LuaRuntime = None
    sys.modules["lupa.lua51"] = stub

spec = importlib.util.spec_from_file_location("journal_preview", PROJECT / "ui-concepts/render-journal-preview.py")
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)
fixture = renderer.patch_fixture((PROJECT / "tests/snapshot_test_ui_test.lua").read_text(encoding="utf-8"))
scenario = next((arg.split("=", 1)[1] for arg in sys.argv if arg.startswith("--state=")), "personal")
lua_code = r'''
__previewStringHeight = function(control) return 16 end
__previewStringWidth = function(control) return #(control.text or "") * 7 end
local fixture = (function()
''' + fixture + r'''
end)()
local GGM, api = fixture.loadUI(), fixture.makeBrowserAPI()
api.GetGuildInfo = function() return "The Artisan Guild", "Member", 1, "Silvermoon" end
api.GetRealmName = function() return "Silvermoon" end
api.issecretvalue = function() return false end
api.InCombatLockdown = function() return false end
api.date = function() return "2026-10-09 16:42:00" end
local identity = { key="Dysheal-Silvermoon", name="Dysheal", realm="Silvermoon" }
local guildIdentity = { key="The Artisan Guild-Silvermoon", name="The Artisan Guild", realm="Silvermoon" }
local tab = { id=6, name="Supplies", numSlots=98, capturedAt=1791556920, status="cached", slots={} }
for i=1,30 do
    tab.slots[i] = { itemID=1000+i, itemLink="|Hitem:"..(1000+i).."|h[Supplies]|h", icon="Interface\\Icons\\INV_Misc_Bag_10", count=i*3 }
end
local record = { identity=identity, capturedAt=1791556920, status="cached", tabs={[6]=tab} }
local guildTab = { id=1, name="Guild Supplies", numSlots=98, capturedAt=1791556920, status="cached", slots=tab.slots }
local guild = { identity=guildIdentity, capturedAt=1791556920, status="incomplete", tabs={
    [1]=guildTab,
    [2]={id=2,name="Raid Materials",numSlots=0,status="unavailable",slots={}},
} }
_G.DysbankMemoryAPI = { schemaVersion=1 }
_G.DysbankMemoryDB = { schemaVersion=1, characters={[identity.key]=record}, guilds={[guildIdentity.key]=guild} }
api.DysbankMemoryAPI, api.DysbankMemoryDB = _G.DysbankMemoryAPI, _G.DysbankMemoryDB
local db = { schemaVersion=GGM.SCHEMA_VERSION, characters={ [identity.key]={identity=identity} } }
local frame = GGM.CreateGuildGearBrowserWindow(api)
frame.db = db
GGM.guildGearBrowserFrame = frame
GGM.SelectGuildGearBrowserTab(frame, "Bank")
frame:Show()
local page = frame.bankPage
if __scenario == "missing" then
    _G.DysbankMemoryAPI, _G.DysbankMemoryDB = nil, nil
    api.DysbankMemoryAPI, api.DysbankMemoryDB = nil, nil
    GGM.RefreshVisibleBankView()
elseif __scenario == "personal" and page.entryButtons[2] then
    page.entryButtons[2].scripts.OnClick(page.entryButtons[2])
elseif __scenario == "unavailable" and page.tabButtons[2] then
    page.tabButtons[2].scripts.OnClick(page.tabButtons[2])
end
local controls = {}
for _, item in ipairs(fixture.controls) do
    local points = {}
    for _, p in ipairs(item.points or {}) do
        points[#points+1] = { point=p.point, relative=p.relativePoint,
            relative_id=p.relativeTo and p.relativeTo._previewID, x=p.x,y=p.y }
    end
    local font = item.font or {}
    controls[#controls+1] = {
        id=item._previewID, parent=item.parent and item.parent._previewID,
        type=item.objectType or "Frame", frame_type=item.frameType,
        frame_level=item:GetFrameLevel(), name=item.name, template=item.template,
        layer=item.drawLayer or "OVERLAY",sublevel=type(item.subLevel)=="number" and item.subLevel or 0,
        visible=item.visible,text=tostring(item.text or ""),font_path=font.path,font_size=font.size or 14,
        font_template=item.fontTemplate,text_color=item.textColor,shadow_color=item.shadowColor,
        shadow_offset=item.shadowOffset or {},justify=item.justifyH or "LEFT",
        texture=type(item.texture)=="string" and item.texture or nil,
        atlas=item.atlas,fill=item.color,tint=item.vertexColor,alpha=item.alpha or 1,
        uv=item.texCoord or {},mask=item.mask and item.mask.texture,
        all_points=item.allPointsTo and item.allPointsTo._previewID,
        width=item.width,height=item.height,points=points,
    }
end
local visiting = {}
local function json(value, path)
    path = path or "scene"
    if type(value)=="string" then
        return '"'..value:gsub('[%z\1-\31\\"]',function(c)
            if c=='"' then return '\\"' elseif c=='\\' then return '\\\\' end
            return string.format('\\u%04x',string.byte(c))
        end)..'"'
    elseif type(value)=="number" or type(value)=="boolean" then return tostring(value)
    elseif type(value)=="table" then
        if visiting[value] then error("Cyclic preview value at "..path.." referencing "..visiting[value]) end
        visiting[value] = path
        local out={}
        if #value>0 then
            for i=1,#value do out[#out+1]=json(value[i],path.."."..i) end
            visiting[value] = nil
            return '['..table.concat(out,',')..']'
        end
        for k,v in pairs(value) do out[#out+1]=json(tostring(k))..':'..json(v,path.."."..tostring(k)) end
        visiting[value] = nil
        return '{'..table.concat(out,',')..'}'
    end
    return 'null'
end
print(json({controls=controls,root=frame._previewID,ui=api.UIParent._previewID}))
'''
lua_code = "__scenario = " + json.dumps(scenario) + "\n" + lua_code
lua_binary = os.environ.get("GGM_LUA") or shutil.which("lua")
if not lua_binary:
    raise SystemExit("Set GGM_LUA to your Lua executable.")
scratch = PROJECT / "ui-concepts" / "__pycache__"
scratch.mkdir(exist_ok=True)
source = scratch / "bank-preview.lua"
source.write_text(lua_code, encoding="utf-8")
result = subprocess.run([lua_binary, str(source)], cwd=PROJECT, capture_output=True, text=True, encoding="utf-8")
if result.returncode:
    raise SystemExit(result.stderr)
scene = json.loads(result.stdout)
keys = ("parent", "frame_type", "name", "template", "font_path", "font_template", "text_color",
        "shadow_color", "texture", "atlas", "fill", "tint", "mask", "all_points", "width", "height")
for control in scene["controls"]:
    for key in keys:
        control.setdefault(key, None)
    for key in ("shadow_offset", "uv", "points"):
        if isinstance(control[key], dict):
            control[key] = []
renderer.build_tree = lambda: (scene["controls"], scene["root"], scene["ui"])
rects, by_id = renderer.solve_layout(scene["controls"], scene["root"], scene["ui"])
original_visible = renderer.effectively_visible
def visible_in_scroll_viewport(control, controls):
    if not original_visible(control, controls):
        return False
    parent = controls.get(control["parent"])
    while parent:
        if parent["frame_type"] == "ScrollFrame":
            viewport = rects[parent["id"]]
            bounds = rects[control["id"]]
            if bounds[1] < viewport[1] or bounds[1] + bounds[3] > viewport[1] + viewport[3]:
                return False
        parent = controls.get(parent["parent"])
    return True
renderer.effectively_visible = visible_in_scroll_viewport
renderer.OUTPUT = PROJECT / "ui-concepts" / f"bank-{scenario}-preview.png"
renderer.RECIPE_MODE = False
renderer.main()
