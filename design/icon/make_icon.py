#!/usr/bin/env python3
"""Builds MacSpace's app icon (direction "C · Spicchio") as an Icon Composer document.

Usage: make_icon.py <path/to/AppIcon.icon>

The mark is the sunburst reduced to a sign: a neutral ring (inner radius a third of the outer)
in two arcs, and an orange wedge at the top right lifted outward along its bisector. Colors are
Fusion's (see docs/superpowers/specs/2026-11-27-app-icon-design.md). Layers are drawn on the
1024-point canvas, so their positions survive Icon Composer's centering.
"""
import json
import math
import os
import sys

CANVAS = 1024
CENTER = (484.0, 544.0)
R_OUT = 304.0
R_IN = R_OUT / 3
GAP = 2.0                     # degrees between the two arcs
ARCS = [(-30.0, 150.0), (150.0, 268.0)]
WEDGE = (-88.0, -32.0)        # 56°, top right
LIFT = 62.0                   # outward along the wedge's bisector

LIGHT = {"arcs": ["#5F574E", "#918578"], "wedge": "#F26431",
         "bg": ["#FAF8F4", "#E8E1D6"]}
DARK = {"arcs": ["#C7C7CC", "#8E8E93"], "wedge": "#F06535",
        "bg": ["#3A3A3E", "#1C1C1E"]}


def point(r, deg, cx=CENTER[0], cy=CENTER[1]):
    a = math.radians(deg)
    return cx + r * math.cos(a), cy + r * math.sin(a)


def ring_segment(a0, a1, color, cx=CENTER[0], cy=CENTER[1]):
    large = 1 if (a1 - a0) % 360 > 180 else 0
    x0, y0 = point(R_OUT, a0, cx, cy)
    x1, y1 = point(R_OUT, a1, cx, cy)
    x2, y2 = point(R_IN, a1, cx, cy)
    x3, y3 = point(R_IN, a0, cx, cy)
    return (f'<path d="M{x0:.2f},{y0:.2f} A{R_OUT},{R_OUT} 0 {large} 1 {x1:.2f},{y1:.2f} '
            f'L{x2:.2f},{y2:.2f} A{R_IN},{R_IN} 0 {large} 0 {x3:.2f},{y3:.2f} Z" fill="{color}"/>')


def arc(index, color):
    a0, a1 = ARCS[index]
    return ring_segment(a0 + GAP / 2, a1 - GAP / 2, color)


def ring(palette):
    return arc(0, palette["arcs"][0]) + arc(1, palette["arcs"][1])


def wedge(palette):
    dx, dy = point(LIFT, (WEDGE[0] + WEDGE[1]) / 2, 0, 0)
    return ring_segment(WEDGE[0], WEDGE[1], palette["wedge"], CENTER[0] + dx, CENTER[1] + dy)


def svg(body, background=None):
    bg = ""
    if background:
        bg = (f'<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">'
              f'<stop offset="0" stop-color="{background[0]}"/><stop offset="1" stop-color="{background[1]}"/>'
              f'</linearGradient></defs><rect width="{CANVAS}" height="{CANVAS}" rx="230" fill="url(#bg)"/>')
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}" '
            f'viewBox="0 0 {CANVAS} {CANVAS}">{bg}{body}</svg>\n')


def srgb(hex_color):
    r, g, b = (int(hex_color[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return f"srgb:{r:.5f},{g:.5f},{b:.5f},1.00000"


def gradient(colors):
    return {"linear-gradient": [srgb(c) for c in colors],
            "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}}}


def solid(light, dark):
    return [{"value": {"solid": srgb(light)}}, {"appearance": "dark", "value": {"solid": srgb(dark)}}]


def layer(name, light, dark):
    """One shape, colored by the layer's fill so each appearance gets its own tone."""
    return {"name": name, "image-name": f"{name}.svg", "glass": True,
            "fill-specializations": solid(light, dark)}


def icon_json():
    return {
        "fill-specializations": [{"value": gradient(LIGHT["bg"])},
                                 {"appearance": "dark", "value": gradient(DARK["bg"])}],
        "groups": [{
            "layers": [layer("wedge", LIGHT["wedge"], DARK["wedge"]),
                       layer("arc-a", LIGHT["arcs"][0], DARK["arcs"][0]),
                       layer("arc-b", LIGHT["arcs"][1], DARK["arcs"][1])],
            "shadow": {"kind": "neutral", "opacity": 0.5},
            "translucency": {"enabled": False, "value": 0.5},
        }],
        "supported-platforms": {"squares": ["macOS"]},
    }


def write(path, text):
    with open(path, "w") as f:
        f.write(text)


def main(out):
    os.makedirs(os.path.join(out, "Assets"), exist_ok=True)
    assets = os.path.join(out, "Assets")
    for name in os.listdir(assets):
        os.remove(os.path.join(assets, name))
    # Shapes only: the layer fills (icon.json) give each appearance its color.
    write(os.path.join(assets, "arc-a.svg"), svg(arc(0, "#000000")))
    write(os.path.join(assets, "arc-b.svg"), svg(arc(1, "#000000")))
    write(os.path.join(assets, "wedge.svg"), svg(wedge({"wedge": "#000000"})))
    write(os.path.join(out, "icon.json"), json.dumps(icon_json(), indent=2) + "\n")


def flat(path, palette):
    """A flat mark on its tile, for the design system and documents."""
    write(path, svg(ring(palette) + wedge(palette), palette["bg"]))


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--flat":
        flat(sys.argv[2], DARK if sys.argv[3] == "dark" else LIGHT)
    elif len(sys.argv) == 2:
        main(sys.argv[1])
    else:
        sys.exit("usage: make_icon.py <AppIcon.icon> | --flat <out.svg> light|dark")
