#!/usr/bin/env python3
"""Generate a visionOS layered app icon (.solidimagestack) for RetroArch.

A visionOS icon must be a .solidimagestack (layered icon), not a flat PNG --
a flat icon gives a blank tile. RetroArch's Icons.xcassets only
carries flat `.appiconset`s, so on visionOS the launcher tile is BLANK. This adds
a `Default.solidimagestack` (same name as the primary iOS icon,
ASSETCATALOG_COMPILER_APPICON_NAME=Default) so the SAME catalog serves a layered
icon on xrOS and the flat icon on iOS -- actool picks per platform (the
same-name trick from the charter).

Layers are derived from RetroArch's OWN icon (Default.appiconset/Icon-83.5-3.png,
a light retropad glyph on #333):
  - Front: the retropad glyph, chroma-keyed onto transparency, so it floats with
           parallax.
  - Back:  an opaque dark tile (subtle radial around #333, the icon's own bg).
           visionOS requires the back layer opaque (it is the masked tile).

This writes directly into the vendored Icons.xcassets (a generated build input,
like assets.zip); the visionOS Xcode build's actool compiles it into Assets.car.
Re-run after a clean bootstrap. Idempotent.

Run:  python3 scripts/build-vision-icon.py
"""
import json, pathlib, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
XCASSETS = ROOT / "vendor/RetroArch/pkg/apple/iOS/Resources/Icons.xcassets"
SRC = XCASSETS / "Default.appiconset" / "Icon-83.5-3.png"
STACK = XCASSETS / "Default.solidimagestack"
SIZE = 1024

def info():
    return {"author": "retroarch-visionos", "version": 1}

def write_json(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2) + "\n")

def make_layer(name, img):
    layer = STACK / f"{name}.solidimagestacklayer"
    write_json(layer / "Contents.json", {"info": info()})
    imgset = layer / "Content.imageset"
    write_json(imgset / "Contents.json", {
        "images": [{"filename": f"{name.lower()}.png", "idiom": "vision", "scale": "2x"}],
        "info": info(),
    })
    img.save(imgset / f"{name.lower()}.png")

def main():
    try:
        from PIL import Image
    except ImportError:
        sys.exit("FATAL: needs Pillow (python3 -m pip install pillow)")
    if not SRC.exists():
        sys.exit(f"FATAL: source icon missing: {SRC}")

    import shutil
    if STACK.exists():
        shutil.rmtree(STACK)

    art = Image.open(SRC).convert("RGBA")
    if art.size != (SIZE, SIZE):
        art = art.resize((SIZE, SIZE), Image.LANCZOS)
    src = art.load()

    # --- Back: opaque radial around the icon's own dark bg (#333) --------------
    cx = cy = (SIZE - 1) / 2.0
    maxd = (cx * cx + cy * cy) ** 0.5
    back = Image.new("RGBA", (SIZE, SIZE))
    bpx = back.load()
    for y in range(SIZE):
        for x in range(SIZE):
            d = ((x - cx) ** 2 + (y - cy) ** 2) ** 0.5 / maxd  # 0 center -> 1 rim
            v = int(0x3a + (0x24 - 0x3a) * d + 0.5)            # #3a center -> #24 rim
            bpx[x, y] = (v, v, v, 255)

    # --- Front: the retropad glyph, dark #333 bg keyed to transparent ---------
    # Glyph is light (~#f2), bg is dark (~#33). Alpha ramps with luminance so the
    # glyph stays opaque and the tile background drops out cleanly.
    front = Image.new("RGBA", (SIZE, SIZE))
    fpx = front.load()
    LO, HI = 90.0, 150.0
    for y in range(SIZE):
        for x in range(SIZE):
            r, g, b, a = src[x, y]
            lum = 0.299 * r + 0.587 * g + 0.114 * b
            t = (lum - LO) / (HI - LO)
            t = 0.0 if t < 0 else 1.0 if t > 1 else t
            t = t * t * (3.0 - 2.0 * t)                        # smoothstep
            fpx[x, y] = (r, g, b, int(a * t + 0.5))

    STACK.mkdir(parents=True, exist_ok=True)
    make_layer("Back", back)
    make_layer("Front", front)
    write_json(STACK / "Contents.json", {
        "info": info(),
        "layers": [
            {"filename": "Front.solidimagestacklayer"},
            {"filename": "Back.solidimagestacklayer"},
        ],
    })
    print(f"wrote {STACK}  (Front glyph + Back tile, 1024 idiom=vision)")

if __name__ == "__main__":
    main()
