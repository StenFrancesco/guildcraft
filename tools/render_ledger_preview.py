"""Render exported Lua anchors for visual QA, without accessing a game client."""
import json
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
nodes = {n['id']: n for n in json.loads((ROOT / 'tools/ledger-layout.json').read_text())}
canvas = Image.new('RGBA', (1180, 752), '#21160e')
fonts = {}
def font(n):
    name = n.get('font', '')
    size = 24 if 'Huge' in name else 18 if 'Large' in name else 11 if 'Small' in name else 13
    if size not in fonts:
        fonts[size] = ImageFont.truetype('C:/Windows/Fonts/georgia.ttf', size)
    return fonts[size]

def rgba(c):
    if isinstance(c, dict): c = [c.get(str(i), 1) for i in range(1, 5)]
    return tuple(round(max(0, min(1, x)) * 255) for x in c)

def factor(anchor):
    return (0 if 'LEFT' in anchor else 1 if 'RIGHT' in anchor else .5,
            0 if 'TOP' in anchor else 1 if 'BOTTOM' in anchor else .5)

boxes = {1: (0, 0, 1180, 720)}
busy = set()
def bounds(n):
    ident = n['id']
    if ident in boxes: return boxes[ident]
    if ident in busy: return (0, 0, 0, 0)
    busy.add(ident)
    if n.get('allPoints'):
        result = bounds(nodes[n['allPoints']])
    else:
        parent = nodes.get(n.get('parent'), nodes[1])
        px, py, pw, ph = bounds(parent)
        w, h = n.get('width'), n.get('height')
        if n['kind'] == 'Text':
            f = font(n)
            w = w or max(1, f.getlength(n.get('text', '').split('\n')[0]))
            h = h or (f.size + 3) * max(1, len(n.get('text', '').split('\n')))
        w, h = w or 0, h or 0
        xs, ys = [], []
        for p in n.get('points', {}).values():
            rx, ry, rw, rh = bounds(nodes.get(p.get('relative'), parent))
            ax, ay = factor(p['anchor'])
            bx, by = factor(p.get('relativeAnchor') or p['anchor'])
            xs.append((ax, rx + rw * bx + p.get('x', 0)))
            ys.append((ay, ry + rh * by - p.get('y', 0)))
        def solve(eq, size, default):
            for a, target in eq:
                for b, other in eq:
                    if a != b: size = (other - target) / (b - a)
            return ((eq[0][1] - eq[0][0] * size) if eq else default, max(0, size))
        x, w = solve(xs, w, px)
        y, h = solve(ys, h, py)
        result = x, y, w, h
    busy.remove(ident)
    boxes[ident] = result
    return result

def region(n):
    x, y, w, h = bounds(n)
    x, y, w, h = round(x), round(y), round(w), round(h)
    if w <= 0 or h <= 0 or not n.get('visible', True): return
    if n['kind'] == 'Text':
        draw = ImageDraw.Draw(canvas)
        text, f = n.get('text', ''), font(n)
        c = rgba(n.get('textColor', [0.23, .14, .07, 1]))
        for index, line in enumerate(text.split('\n')):
            while line and f.getlength(line) > w: line = line[:-1]
            align = n.get('justify', 'CENTER')
            left = x if align == 'LEFT' else x + w - f.getlength(line) if align == 'RIGHT' else x + (w-f.getlength(line))/2
            top = y + max(0, (h - (f.size+3)*len(text.split('\n'))) / 2)
            draw.text((left, top + index*(f.size+3)), line, font=f, fill=c)
        return
    if n['kind'] != 'Texture' or n.get('layer') == 'HIGHLIGHT': return
    tex = str(n.get('texture', ''))
    if 'Media' in tex:
        file = ROOT / 'GuildGearMemory/Media' / (tex.split('\\')[-1] + '.tga')
        fill = Image.open(file).convert('RGBA').resize((w, h), Image.Resampling.LANCZOS)
    elif n.get('color'):
        fill = Image.new('RGBA', (w, h), rgba(n['color']))
    elif tex:
        if 'Quickslot' in tex or 'Border' in tex: return
        fill = Image.new('RGBA', (w, h), '#51412b')
        d = ImageDraw.Draw(fill)
        d.rectangle((1, 1, w-2, h-2), outline='#aa8c54')
        d.line((4, 4, w-5, h-5), fill='#8e7850', width=2)
        d.line((w-5, 4, 4, h-5), fill='#8e7850', width=2)
    else: return
    if n.get('alpha') is not None:
        fill.putalpha(fill.getchannel('A').point(lambda a: round(a * n['alpha'])))
    canvas.alpha_composite(fill, (x, y))

layers = {'BACKGROUND': 0, 'BORDER': 1, 'ARTWORK': 2, 'OVERLAY': 3, 'HIGHLIGHT': 4}
children = {}
for n in nodes.values(): children.setdefault(n.get('parent'), []).append(n)
def render(n):
    if not n.get('visible', True): return
    own = children.get(n['id'], [])
    regions = [c for c in own if c['kind'] in ('Text', 'Texture')]
    for child in sorted(regions, key=lambda c: (layers.get(c.get('layer'), 2), c.get('sublayer', 0), c['id'])): region(child)
    for child in own:
        if child['kind'] not in ('Text', 'Texture'): render(child)
render(nodes[1])
ImageDraw.Draw(canvas).text((18, 732), 'DEVELOPMENT PREVIEW · Real Lua layout and textures; game fonts, icons and character model are approximated.',
                           fill='#d8c49e', font=ImageFont.truetype('C:/Windows/Fonts/arial.ttf', 12))
canvas.convert('RGB').save(ROOT / 'tools/ledger-preview.png')
print('Saved tools/ledger-preview.png')
