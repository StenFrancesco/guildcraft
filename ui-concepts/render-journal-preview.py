#!/usr/bin/env python3
"""Render GuildGearMemory's live Lua professions page into an off-game preview."""

from __future__ import annotations

import os
import sys
from pathlib import Path

PROJECT = Path(__file__).resolve().parents[1]
ADDON = PROJECT / "GuildGearMemory"
MEDIA = ADDON / "Media" / "ArtisanJournal"
TESTS = PROJECT / "tests"
OUTPUT = Path(__file__).resolve().parent / "artisan-journal-layout-preview.png"
LUA_RUNTIME = PROJECT / "tools" / "lua" / "python-runtime"
sys.path.insert(0, str(LUA_RUNTIME))

from lupa.lua51 import LuaRuntime  # noqa: E402
from PIL import Image, ImageDraw, ImageFont  # noqa: E402


def patch_fixture(source: str) -> str:
    """Instrument existing controls in memory; leave fixture and addon source untouched."""
    replacements = [
        (
            'local T = require("tests.testlib")',
            'local T = require("tests.testlib")\nlocal __previewControls = {}\nlocal __previewID = 0',
        ),
        (
            'local function newControl()\n    local control = { text = nil, visible = false, scripts = {} }',
            'local function newControl()\n    __previewID = __previewID + 1\n'
            '    local control = { text = nil, visible = true, scripts = {}, _previewID = __previewID }\n'
            '    __previewControls[#__previewControls + 1] = control',
        ),
        (
            '    function control:SetPoint(point, relativeTo, relativePoint, x, y)\n'
            '        self.point = { point = point, relativeTo = relativeTo, relativePoint = relativePoint, x = x, y = y }\n'
            '    end',
            '    function control:SetPoint(point, relativeTo, relativePoint, x, y)\n'
            '        self.points = self.points or {}\n'
            '        local anchor = { point = point, relativeTo = relativeTo or self.parent, relativePoint = relativePoint or point, x = x or 0, y = y or 0 }\n'
            '        self.points[#self.points + 1] = anchor\n'
            '        self.point = self.point or anchor\n'
            '    end',
        ),
        (
            '    function control:SetAllPoints(relativeTo) self.allPointsTo = relativeTo end',
            '    function control:SetAllPoints(relativeTo) self.allPointsTo = relativeTo or self.parent end',
        ),
        (
            '    function control:ClearAllPoints() self.point = nil; self.allPointsTo = nil end',
            '    function control:ClearAllPoints() self.point = nil; self.points = {}; self.allPointsTo = nil end',
        ),
        (
            '    function control:SetJustifyH() end',
            '    function control:SetJustifyH(value) self.justifyH = value end\n'
            '    function control:SetJustifyV(value) self.justifyV = value end\n'
            '    function control:SetShadowColor(...) self.shadowColor = { ... } end',
        ),
        (
            '    function control:CreateFontString() return newControl() end',
            '    function control:CreateFontString(name, layer, template)\n'
            '        local child = newControl(); child.parent = self; child.objectType = "FontString"; child.name = name; child.drawLayer = layer; child.fontTemplate = template; return child\n'
            '    end',
        ),
        (
            '    function control:CreateTexture() return newControl() end',
            '    function control:CreateTexture(name, layer, subLevel)\n'
            '        local child = newControl(); child.parent = self; child.objectType = "Texture"; child.name = name; child.drawLayer = layer; child.subLevel = subLevel; return child\n'
            '    end',
        ),
        (
            '            frame.name, frame.parent, frame.frameType, frame.template = name, parent, frameType, template\n'
            '            frame.TitleText = newControl()',
            '            frame.name, frame.parent, frame.frameType, frame.template, frame.objectType = name, parent, frameType, template, "Frame"\n'
            '            frame.TitleText = newControl()\n'
            '            frame.TitleText.parent, frame.TitleText.objectType = frame, "FontString"',
        ),
        (
            '            function frame:SetScrollChild(child) self.scrollChild = child end',
            '            function frame:SetScrollChild(child)\n'
            '                self.scrollChild = child\n'
            '                if child and (not child.points or #child.points == 0) then child:SetPoint("TOPLEFT", self, "TOPLEFT", 0, 0) end\n'
            '            end',
        ),
    ]
    for old, new in replacements:
        if old not in source:
            raise RuntimeError(f"UI test fixture changed; could not instrument: {old[:60]!r}")
        source = source.replace(old, new, 1)
    return source + "\nreturn { loadUI = loadUI, makeBrowserAPI = makeBrowserAPI, controls = __previewControls }\n"


def lv(table, key, default=None):
    if table is None:
        return default
    try:
        value = table[key]
    except (KeyError, TypeError, IndexError):
        return default
    return default if value is None else value


def seq(table):
    if table is None:
        return []
    try:
        return [table[i] for i in range(1, len(table) + 1)]
    except (TypeError, ValueError):
        return []


def norm_color(value, default=(0.19, 0.125, 0.07, 1)):
    try:
        vals = [float(value[i]) for i in range(1, 5)]
    except (TypeError, KeyError, IndexError):
        vals = list(default)
    while len(vals) < 4:
        vals.append(1)
    return tuple(max(0, min(255, round(v * 255))) for v in vals[:4])


def build_tree():
    os.chdir(PROJECT)
    lua = LuaRuntime(unpack_returned_tuples=True)
    fixture = (TESTS / "snapshot_test_ui_test.lua").read_text(encoding="utf-8")
    module = lua.execute(patch_fixture(fixture))
    ggm = module["loadUI"]()

    catalog = lua.table()
    catalog["state"] = "ready"
    catalog["recipes"] = lua.table()
    samples = [
        (41001, "Goggles", "INV_Gizmo_02", "Mira", "Silvermoon"),
        (41002, "Mechanical Toolkit", "INV_Gizmo_08", "Thorin", "Argent Dawn"),
        (41003, "Precision Gear Assembly", "INV_Gizmo_09", "Mira", "Silvermoon"),
    ]
    for i, (rid, name, icon, owner_name, realm) in enumerate(samples, 1):
        recipe = lua.table()
        recipe["recipeID"], recipe["name"] = rid, name
        recipe["outputIcon"] = "Interface\\Icons\\" + icon
        owner = lua.table()
        owner["name"], owner["realm"], owner["savedDate"] = owner_name, realm, "2026-10-04"
        recipe["knownBy"] = lua.table_from([owner])
        catalog["recipes"][i] = recipe

    lua.globals()["GGM"] = ggm
    lua.globals()["__previewCatalog"] = catalog
    lua.execute(
        "GGM.BuildProfessionRecipeCatalog = function(db, professionID, professionLabel, api) "
        "return __previewCatalog end"
    )
    api = module["makeBrowserAPI"]()
    api["UIParent"]["name"] = "UIParent"
    api["UIParent"]["objectType"] = "Frame"
    frame = ggm["CreateGuildGearBrowserWindow"](api)
    frame["db"] = lua.table_from({"schemaVersion": ggm["SCHEMA_VERSION"], "characters": {}})
    ggm["SelectGuildGearBrowserTab"](frame, "Professions")
    ggm["SelectProfession"](frame, "Engineering")
    frame["Show"](frame)

    controls = []
    for item in seq(module["controls"]):
        parent = lv(item, "parent")
        points = []
        for p in seq(lv(item, "points")):
            relative = lv(p, "relativeTo")
            points.append({
                "point": str(lv(p, "point", "CENTER")),
                "relative": str(lv(p, "relativePoint", lv(p, "point", "CENTER"))),
                "relative_id": int(lv(relative, "_previewID", 0)) if relative is not None else None,
                "x": float(lv(p, "x", 0)),
                "y": float(lv(p, "y", 0)),
            })
        all_points = lv(item, "allPointsTo")
        font = lv(item, "font")
        texture = lv(item, "texture")
        controls.append({
            "id": int(lv(item, "_previewID", 0)),
            "parent": int(lv(parent, "_previewID", 0)) if parent is not None else None,
            "type": str(lv(item, "objectType", "Frame")),
            "name": lv(item, "name"),
            "template": lv(item, "template"),
            "layer": str(lv(item, "drawLayer", "OVERLAY")),
            "sublevel": float(lv(item, "subLevel", 0)),
            "visible": bool(lv(item, "visible", True)),
            "text": str(lv(item, "text", "")),
            "font_path": lv(font, "path"),
            "font_size": float(lv(font, "size", 14)),
            "font_template": lv(item, "fontTemplate"),
            "text_color": lv(item, "textColor"),
            "justify": str(lv(item, "justifyH", "LEFT")),
            "texture": texture if isinstance(texture, str) else None,
            "atlas": lv(item, "atlas"),
            "fill": lv(item, "color"),
            "tint": lv(item, "vertexColor"),
            "alpha": float(lv(item, "alpha", 1)),
            "uv": seq(lv(item, "texCoord")),
            "all_points": int(lv(all_points, "_previewID", 0)) if all_points is not None else None,
            "width": float(lv(item, "width", 0)) or None,
            "height": float(lv(item, "height", 0)) or None,
            "points": points,
        })
    return controls, int(lv(frame, "_previewID")), int(lv(api["UIParent"], "_previewID"))


def fractions(point):
    x = 0 if "LEFT" in point else (1 if "RIGHT" in point else 0.5)
    y = 0 if "TOP" in point else (1 if "BOTTOM" in point else 0.5)
    if point in ("LEFT", "RIGHT"):
        y = 0.5
    if point in ("TOP", "BOTTOM"):
        x = 0.5
    return x, y


def font_for(rec, media=MEDIA):
    path = rec["font_path"]
    name = str(path).replace("\\", "/").split("/")[-1] if path else ""
    if name not in ("journal-serif.ttf", "journal-serif-bold.ttf"):
        name = "journal-serif-bold.ttf" if "Huge" in str(rec["font_template"] or "") else "journal-serif.ttf"
    return ImageFont.truetype(str(media / name), max(1, round(rec["font_size"] or 14)))


def solve_layout(controls, root_id, ui_id):
    by_id = {c["id"]: c for c in controls}
    rects = {ui_id: (0.0, 0.0, 1920.0, 1080.0)}
    natural = {}
    for c in controls:
        if c["type"] == "FontString" and c["text"]:
            f = font_for(c)
            box = f.getbbox("Ag")
            natural[c["id"]] = (max(f.getlength(line) for line in c["text"].splitlines()), (box[3] - box[1]) * len(c["text"].splitlines()))

    def solve_axis(c, vertical, size):
        values = []
        size_slot = 3 if vertical else 2
        fraction_slot = 1 if vertical else 0
        for p in c["points"]:
            target_id = p["relative_id"] or c["parent"]
            target = rects.get(target_id)
            if target is None:
                continue
            own_f = fractions(p["point"])[fraction_slot]
            rel_f = fractions(p["relative"])[fraction_slot]
            offset = -p["y"] if vertical else p["x"]
            target_base = target[(1 if vertical else 0)] + rel_f * target[size_slot] + offset
            values.append((own_f, target_base))
        if not values:
            return None, size
        if size is None:
            for i, (f1, b1) in enumerate(values):
                for f2, b2 in values[i + 1:]:
                    if abs(f2 - f1) > 1e-6:
                        size = (b2 - b1) / (f2 - f1)
                        break
                if size is not None:
                    break
        if size is None:
            size = natural.get(c["id"], (0, 0))[1 if vertical else 0]
        origin = sum(base - frac * size for frac, base in values) / len(values)
        return origin, max(0, size)

    for _ in range(max(40, len(controls) * 2)):
        changed = False
        for c in controls:
            cid = c["id"]
            if cid == ui_id:
                continue
            if c["all_points"]:
                target = rects.get(c["all_points"])
                if target and rects.get(cid) != target:
                    rects[cid] = target
                    changed = True
                continue
            if not c["points"]:
                continue
            width, height = c["width"], c["height"]
            if c["type"] == "FontString":
                _, nh = natural.get(cid, (0, 0))
                height = height or (nh if nh else None)
            left, width = solve_axis(c, False, width)
            top, height = solve_axis(c, True, height)
            if left is not None and top is not None:
                new_rect = (left, top, width or 0, height or 0)
                old_rect = rects.get(cid)
                if old_rect is None or any(abs(a - b) > 0.1 for a, b in zip(old_rect, new_rect)):
                    rects[cid] = new_rect
                    changed = True
        if not changed:
            break
    if root_id not in rects:
        raise RuntimeError("The Lua control anchors did not resolve the root frame")
    return rects, by_id


def effectively_visible(rec, by_id):
    current = rec
    visited = set()
    while current:
        if not current["visible"]:
            return False
        parent_id = current["parent"]
        if parent_id is None or parent_id in visited:
            break
        visited.add(parent_id)
        current = by_id.get(parent_id)
    return True


def local_texture(path):
    if not path:
        return None
    normalized = path.replace("/", "\\")
    marker = "Media\\ArtisanJournal\\"
    if marker.lower() not in normalized.lower():
        return None
    relative = normalized[normalized.lower().rfind(marker.lower()) + len(marker):]
    candidate = MEDIA / relative.replace("\\", os.sep)
    if candidate.is_file():
        return candidate
    # Source PNG fallback makes the script useful before TGA export is regenerated.
    if candidate.suffix.lower() == ".tga":
        stem = candidate.stem
        options = [MEDIA / "Source" / f"{stem}.png", MEDIA / "Source" / f"{stem}-page.png"]
        options.insert(0, MEDIA / "Source" / f"{stem}-v2.png")
        for option in options:
            if option.is_file():
                return option
    return None


def crop_uv(image, uv):
    if len(uv) < 4:
        return image
    u0, u1, v0, v1 = (float(v) for v in uv[:4])
    box = (
        max(0, round(min(u0, u1) * image.width)),
        max(0, round(min(v0, v1) * image.height)),
        min(image.width, round(max(u0, u1) * image.width)),
        min(image.height, round(max(v0, v1) * image.height)),
    )
    return image.crop(box) if box[2] > box[0] and box[3] > box[1] else image


def tint_image(image, tint, alpha):
    rgba = image.convert("RGBA")
    tint = norm_color(tint, (1, 1, 1, 1))
    r, g, b, a = rgba.split()
    r = r.point(lambda v: round(v * tint[0] / 255))
    g = g.point(lambda v: round(v * tint[1] / 255))
    b = b.point(lambda v: round(v * tint[2] / 255))
    a = a.point(lambda v: round(v * tint[3] / 255 * alpha))
    return Image.merge("RGBA", (r, g, b, a))


def draw_native_placeholder(draw, rect, texture):
    x, y, w, h = rect
    if w < 5 or h < 5:
        return
    x0, y0, x1, y1 = round(x), round(y), round(x + w), round(y + h)
    title = texture.replace("Interface\\Icons\\", "").replace("Interface\\PaperDoll\\", "")
    tokens = [s for s in title.replace("_", " ").split() if s]
    label = "".join(s[:1] for s in tokens[:2]).upper() or "?"
    colors = [(77, 93, 106, 255), (94, 69, 36, 255), (76, 88, 64, 255), (101, 55, 36, 255)]
    color = colors[sum(map(ord, title)) % len(colors)]
    draw.rectangle((x0, y0, x1 - 1, y1 - 1), fill=(34, 27, 21, 255), outline=(117, 82, 36, 255), width=max(1, round(min(w, h) * 0.05)))
    inset = max(2, round(min(w, h) * 0.12))
    draw.rectangle((x0 + inset, y0 + inset, x1 - inset - 1, y1 - inset - 1), fill=color, outline=(24, 21, 19, 255), width=1)
    f = ImageFont.truetype(str(MEDIA / "journal-serif-bold.ttf"), max(7, round(min(w, h) * 0.34)))
    draw.text(((x0 + x1) / 2, (y0 + y1) / 2), label, font=f, fill=(236, 216, 173, 255), anchor="mm")


def main():
    controls, root_id, ui_id = build_tree()
    rects, by_id = solve_layout(controls, root_id, ui_id)
    root = rects[root_id]
    root_x, root_y = root[0], root[1]
    width, height = round(root[2]), round(root[3])
    canvas = Image.new("RGBA", (width, height + 38), (39, 27, 18, 255))
    draw = ImageDraw.Draw(canvas, "RGBA")
    layer_order = {"BACKGROUND": 0, "BORDER": 1, "ARTWORK": 2, "OVERLAY": 3, "HIGHLIGHT": 4}
    textures = sorted(
        (c for c in controls if c["type"] == "Texture"),
        key=lambda c: (layer_order.get(c["layer"].upper(), 3), c["sublevel"], c["id"]),
    )
    for c in textures:
        if not effectively_visible(c, by_id) or c["layer"].upper() == "HIGHLIGHT":
            continue
        rect = rects.get(c["id"])
        if not rect:
            continue
        x, y, w, h = rect
        x, y = x - root_x, y - root_y
        box = (round(x), round(y), round(x + w), round(y + h))
        if box[2] <= box[0] or box[3] <= box[1]:
            continue
        local = local_texture(c["texture"])
        if local:
            try:
                with Image.open(local) as opened:
                    img = crop_uv(opened.convert("RGBA"), c["uv"])
                    img = tint_image(img, c["tint"], c["alpha"])
                    img = img.resize((box[2] - box[0], box[3] - box[1]), Image.Resampling.LANCZOS)
                    canvas.alpha_composite(img, (box[0], box[1]))
                continue
            except (OSError, ValueError):
                pass
        if c["fill"] is not None:
            fill = norm_color(c["fill"])
            fill = (fill[0], fill[1], fill[2], round(fill[3] * max(0, min(1, c["alpha"]))))
            if fill[3] > 0:
                overlay = Image.new("RGBA", (box[2] - box[0], box[3] - box[1]), fill)
                canvas.alpha_composite(overlay, (box[0], box[1]))
        elif c["texture"] and c["texture"].startswith("Interface\\"):
            draw_native_placeholder(draw, (x, y, w, h), c["texture"])

    for c in sorted((x for x in controls if x["type"] == "FontString" and x["text"]), key=lambda x: x["id"]):
        if not effectively_visible(c, by_id):
            continue
        rect = rects.get(c["id"])
        if not rect:
            continue
        x, y, w, _ = rect
        x, y = x - root_x, y - root_y
        font = font_for(c)
        color = norm_color(c["text_color"])
        lines = c["text"].splitlines() or [""]
        line_height = max(1, font.getbbox("Ag")[3] - font.getbbox("Ag")[1])
        for row, line in enumerate(lines):
            line_width = font.getlength(line)
            if c["justify"].upper() == "RIGHT":
                tx = x + w - line_width
            elif c["justify"].upper() == "CENTER":
                tx = x + (w - line_width) / 2
            else:
                tx = x
            draw.text((tx, y + row * line_height), line, font=font, fill=color, anchor="lt")

    # Native frame template content is not represented by the addon fixture; show its Lua-sized placeholder.
    for c in controls:
        if c["template"] == "UIPanelCloseButton" and effectively_visible(c, by_id):
            rect = rects.get(c["id"])
            if rect:
                x, y, w, h = rect
                size = min(w, h) * 0.82
                l, t = x - root_x + (w - size) / 2, y - root_y + (h - size) / 2
                draw.rounded_rectangle((l, t, l + size, t + size), radius=4, fill=(55, 31, 21, 255), outline=(184, 122, 43, 255), width=2)
                close_font = ImageFont.truetype(str(MEDIA / "journal-serif-bold.ttf"), max(8, round(size * 0.6)))
                draw.text((l + size / 2, t + size / 2), "×", font=close_font, fill=(240, 181, 45, 255), anchor="mm")

    caption_font = ImageFont.truetype(str(MEDIA / "journal-serif.ttf"), 13)
    draw.text((14, height + 11), "Off-game layout preview • native WoW icons are represented by placeholders", font=caption_font, fill=(225, 203, 165, 255), anchor="lt")
    canvas.convert("RGB").save(OUTPUT, optimize=True)

    print(f"Rendered {OUTPUT}")
    print(f"Window {width}x{height}; captured {len(controls)} Lua controls")
    for c in controls:
        if c["text"] in ("Professions", "Engineering", "Search recipes", "3 recipes"):
            r = rects.get(c["id"])
            if r:
                print(f"{c['text']}: x={r[0]-root_x:.1f}, y={r[1]-root_y:.1f}, {r[2]:.1f}x{r[3]:.1f}")


if __name__ == "__main__":
    main()
