#!/usr/bin/env python3
"""Generate overlay/patches/0050-cores-mupen-gliden64-needadjust-viewport-guard.patch.

THE ROOT CAUSE OF THE N64 "BOXED / FAT" PICTURE, reproduced end to end on the
mac harness.

`GraphicsDrawer.cpp`'s `_needAdjustCoordinate()` is GLideN64's heuristic for
"the game is drawing into a sub-viewport, so the 16:9-adjusted X squeeze must be
applied to the scissor as well":

    return _wnd.isAdjustScreen() &&
        gSP.viewport.width < gDP.colorImage.width &&
        u32(gSP.viewport.width + gSP.viewport.x * 2.0f) != gDP.colorImage.width &&
        gDP.colorImage.width > VI.width * 98 / 100;

`gSP.viewport` is HLE state: it is populated by `gSPViewport()` while GLideN64's
own display-list parser walks the DL. With an **LLE RSP** (cxd4) the ucode is
executed by the RSP plugin and `gSPViewport()` is never called, so
`gSP.viewport.width` stays **0.0** for the whole session. The heuristic then
reads `0 < 320` and `0 != 320` and fires on **every** draw, and `updateScissor()`
runs `_adjustScissorX()`, which shrinks the scissor to the centre
`adjustScale` (0.75) of the colour image:

    N64 x 40..280 of 0..320  ->  200..1400 of the 1600-wide internal buffer
    -> 480..3360 of the 3840-wide screen after the final blit

That is the tester's rectangle, to the pixel (device dumps: `bbox=479,81-3358,2096`
and `480,81-3358,2096`).

**Why the visionOS build is in that state**: overlay 0016 compiles
`-DMUPEN_SW_DEFAULT`, which makes the *default* `rsp-plugin` **cxd4**, to pair
with the software (angrylion) RDP. The tester runs the **GLideN64** RDP, so his
persisted `Mupen64Plus-Next.opt` carries `gliden64` + `cxd4` — an HLE graphics
plugin driven by an LLE RSP. The mac harness has always run `rsp-plugin = "hle"`,
which is exactly why five rounds of "the mac renders fine" were honest and
useless.

Measured on a desktop build (ANGLE/GLES3, device config `16:9 adjusted` /
3840x2160 / NativeResFactor 5, SM64 cold boot + input replay, column-fill
profile of the hardware-render FBO):

| run | needAdjust | picture |
|---|---|---|
| `rsp=hle` (baseline)  | true 6 / 2000 calls, `vp.w=320 ci=320` | full width `5eee…7` |
| `rsp=cxd4`            | true **2000 / 2000**, `vp.w=0 ci=320`  | **boxed 480..3352** |
| `rsp=cxd4` + this fix | (guard rejects `vp.w==0`)              | full width `5eee…7` |

 cxd4 test read only the *bounding box* of one saved state at one frame;
the outer bbox stays 48..3792 because SM64's full-screen 2D draws still paint
faint edge columns. The column-fill profile is what separates the two, and it
says cxd4 was boxed all along.

THE PATCH: one added condition — the heuristic requires a *known* viewport.
`gSP.viewport.width == 0` does not mean "a viewport narrower than the colour
image", it means "no viewport information at all", and no coordinate adjustment
can be justified from it. Platform-neutral, upstream-shaped, and a strict no-op
under HLE (where `gSP.viewport.width` is 320).

Run from the repo root.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REL = "cores/mupen64plus-next/GLideN64/src/GraphicsDrawer.cpp"
SRC = ROOT / "vendor" / REL
OUT = ROOT / "overlay/patches/0050-cores-mupen-gliden64-needadjust-viewport-guard.patch"

ANCHOR = """bool _needAdjustCoordinate(DisplayWindow & _wnd)
{
	return _wnd.isAdjustScreen() &&
"""

ADDITION = """		/* 0050: the heuristic below asks "is the game drawing into a
		 * sub-viewport?" out of gSP.viewport, which is HLE state filled in by
		 * gSPViewport() while GLideN64 walks the display list. With an LLE RSP
		 * (cxd4) the ucode runs in the RSP plugin, gSPViewport() is never
		 * called, and gSP.viewport.width stays 0.0 for the whole session — so
		 * "0 < colorImage.width" fires on every draw and _adjustScissorX()
		 * crops the picture to the centre 75%. That is the visionOS boxed
		 * frame, to the pixel. Zero is not a narrow viewport, it is an
		 * unknown viewport: require a real one before adjusting anything.
		 * No-op under HLE, where this reads 320 against a 320-wide colour
		 * image. */
		gSP.viewport.width > 0.0f &&
"""

TRAIL = 3
text = SRC.read_text()
n = text.count(ANCHOR)
if n != 1:
    sys.exit(f"anchor matched {n} times in {SRC} (want 1)")
if "gSP.viewport.width > 0.0f" in text:
    sys.exit("0050 already applied to vendor — reverse it out before regenerating")

start = text.index(ANCHOR)
line_no = text[:start].count("\n") + 1
anchor_lines = ANCHOR.rstrip("\n").split("\n")
add_lines = ADDITION.rstrip("\n").split("\n")
rest = text[start + len(ANCHOR):].split("\n")[:TRAIL]
body = [" " + l for l in anchor_lines]
body += ["+" + l if l else "+" for l in add_lines]
body += [" " + l if l else " " for l in rest]
old_count = len(anchor_lines) + len(rest)
new_count = old_count + len(add_lines)

OUT.write_text(
    f"diff --git a/{REL} b/{REL}\n"
    f"--- a/{REL}\n"
    f"+++ b/{REL}\n"
    f"@@ -{line_no},{old_count} +{line_no},{new_count} @@\n"
    + "\n".join(body) + "\n"
)
print(f"wrote {OUT}")

subprocess.run(
    ["patch", "-p3", "--dry-run", "-d", str(ROOT / "vendor/cores/mupen64plus-next"),
     "-i", str(OUT)],
    check=True,
)
print("dry-run OK")
