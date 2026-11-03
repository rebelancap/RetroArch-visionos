#!/usr/bin/env python3
"""Generate overlay/patches/0052-cores-mupen-gliden64-fill-window.patch.

ITEM 1 of the polish round: kill the thin black margins that survive
around the N64 picture on the Vision Pro.

With the crop gone, the frame is full width *as GLideN64
intends it* — and GLideN64 intends a small border, because it reproduces the
N64's own VI blanking.  `FrameBufferList::renderBuffer()` builds the final blit
from the VI registers:

    dstX0 = (vi_h_start + vi_minhpass) * viScaleX * dstScaleX
    dstX1 = drawingWidth - (h0 + 640 - VI_H_START_end + vi_maxhpass) * viScaleX * dstScaleX
    dstY0 = vi_v_start * dstScaleY ; dstY1 = (vi_v_start + vi_vres) * dstScaleY

For SM64 at 3840x2160 that is the measured device line (.20/.21 logs):

    src=20,5-1583,1190 tex=1600x1200  ->  dst=48,0-3798,2133  of 3840x2160

i.e. ~48 px unwritten on the left, ~42 px on the right and ~27 px along the
bottom.  On a CRT those columns are behind the bezel.  On a fixed panel — and
on a Vision Pro window whose whole point is that the emulator fills it — they
are just black bars.

THE PATCH (compile-gated on `MUPEN_FILL_WINDOW`, which only this port's builds
define): after the source and destination rectangles are computed, scale the
mapping **uniformly** about the destination rectangle's own centre until it
covers the whole surface, clip the destination to the surface, and map the clip
back through the *same* linear transform onto the source rectangle.

Why uniform-about-the-centre rather than "stretch dst to 0,0-W,H":
`dw/sw` and `dh/sh` are NOT equal here (N64 pixels are not square, and
"16:9 adjusted" makes them less square still — 2.399 against 1.800 in the line
above).  Stretching each axis independently to fill would change that ratio by
the ratio of the two margins and put a ~1 % anamorphic error into every frame.
Multiplying **both** axes by one scalar `s` leaves the ratio exactly as GLideN64
computed it, so the geometry is bit-for-bit the same shape, only 2.6 % larger.
That is precisely what a TV does with overscan, and it is the behaviour the tester
asked for: crop the blanking, fill the window, do not distort.

The scalar:

    cx = (dst.x0+dst.x1)/2                s_x = 2*max(cx, W-cx) / dw
    cy = (dst.y0+dst.y1)/2                s_y = 2*max(cy, H-cy) / dh
    s   = max(s_x, s_y)                   (>= 1 whenever a margin exists)

`max(c, B-c)` rather than `B/2` because the margins are asymmetric (48 left vs
42 right, 0 top vs 27 bottom): a centre-scale has to reach the *far* edge.
For the measured SM64 line s = 1.0256, the destination becomes exactly
0,0-3840,2160, and the source loses ~15 rows of 1185 off the top/bottom
(1.3 %) — the part that scrolled off the surface.  Nothing is stretched.

Guards: only when overscan compositing is off (the shipped configuration — the
overscan path has its own destination rectangle and its own cropping UI, and
must be left alone), only for the single-buffer case (`pNextBuffer == nullptr`;
the split-buffer path re-derives `blitParams.dstY*` from `dstY0/dstY1`
afterwards and would disagree with a rewritten `dstCoord`), only when a margin
actually exists, and the mapped-back source is clamped into the texture so the
1-2 px the scale reaches beyond the original crop can never sample out of
bounds.

Measured on a desktop build (ANGLE/GLES3, device config `16:9 adjusted` /
3840x2160 / NativeResFactor 5): before/after PNGs and the presented
bounding boxes.

Run from the repo root.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REL = "cores/mupen64plus-next/GLideN64/src/FrameBuffer.cpp"
SRC = ROOT / "vendor" / REL
OUT = ROOT / "overlay/patches/0052-cores-mupen-gliden64-fill-window.patch"

# Anchored AFTER 0049 (b)'s beacon block so the two patches never share an
# edited region — 0049's own hunk uses the dstCoord[] declaration as context.
ANCHOR = """	ObjectHandle readBuffer;
"""

ADDITION = """
#if defined(MUPEN_FILL_WINDOW)
	/* 0052: fill the presented surface exactly (no VI-blanking bars).
	 *
	 * The rectangles above reproduce the N64's VI blanking, so the picture
	 * lands inset by a few pixels on each edge (SM64 at 3840x2160:
	 * dst=48,0-3798,2133). Scale the src->dst mapping uniformly about the
	 * destination's centre until it covers the surface, clip the destination
	 * to the surface, and map the clip back onto the source through the same
	 * transform. Uniform => the src/dst ratio GLideN64 computed is preserved
	 * exactly, so no anamorphic error is introduced; what is lost is the
	 * couple of percent that scrolls off the edge, which is what a TV does
	 * with overscan. See scripts/gen-patch-0052.py. */
	if (pNextBuffer == nullptr && config.frameBufferEmulation.enableOverscan == 0) {
		const f32 bw = static_cast<f32>(m_overscan.getBufferWidth());
		const f32 bh = static_cast<f32>(m_overscan.getBufferHeight());
		const f32 dw = static_cast<f32>(dstCoord[2] - dstCoord[0]);
		const f32 dh = static_cast<f32>(dstCoord[3] - dstCoord[1]);
		const f32 sw = static_cast<f32>(srcCoord[2] - srcCoord[0]);
		const f32 sh = static_cast<f32>(srcCoord[3] - srcCoord[1]);
		const bool hasMargin = dstCoord[0] > 0 || dstCoord[1] > 0 ||
			dstCoord[2] < static_cast<s32>(bw) || dstCoord[3] < static_cast<s32>(bh);
		if (hasMargin && bw > 1.0f && bh > 1.0f &&
			dw > 1.0f && dh > 1.0f && sw > 1.0f && sh > 1.0f) {
			const f32 cx = (static_cast<f32>(dstCoord[0]) + static_cast<f32>(dstCoord[2])) * 0.5f;
			const f32 cy = (static_cast<f32>(dstCoord[1]) + static_cast<f32>(dstCoord[3])) * 0.5f;
			const f32 sx = 2.0f * max(cx, bw - cx) / dw;
			const f32 sy = 2.0f * max(cy, bh - cy) / dh;
			f32 s = max(sx, sy);
			if (s < 1.0f)
				s = 1.0f;
#if defined(MUPEN_FILL_WINDOW_ZOOM)
			/* 0052b: an extra UNIFORM zoom about the same
			 * centre. The cover factor above makes the DESTINATION rectangle
			 * reach every edge, and it does — measured L0 R0 on the mac and
			 * full width on the device. What remained top and bottom is not
			 * destination margin at all but blank rows INSIDE the source: SM64
			 * draws ~8 of its 240 native lines black at the top and ~8 at the
			 * bottom, so the blit faithfully reproduces them. No rectangle
			 * arithmetic can remove content, only a zoom can, so this is the
			 * knob that does it. Uniform, so no anamorphic error is introduced;
			 * the cost is that the same fraction is lost from the left and
			 * right as well, exactly as a CRT's overscan did. Set by
			 * scripts/build-core-xros.sh (and the mac harness). Undefine, or set
			 * to 1.0f, to go back to the .23 picture. */
			s *= (MUPEN_FILL_WINDOW_ZOOM);
#endif
			/* the scaled destination, before clipping */
			const f32 nx0 = cx - dw * s * 0.5f, nx1 = cx + dw * s * 0.5f;
			const f32 ny0 = cy - dh * s * 0.5f, ny1 = cy + dh * s * 0.5f;
			if (nx1 - nx0 > 1.0f && ny1 - ny0 > 1.0f) {
				/* the visible part of it, in [0,B] */
				const f32 vx0 = max(nx0, 0.0f), vx1 = min(nx1, bw);
				const f32 vy0 = max(ny0, 0.0f), vy1 = min(ny1, bh);
				/* the same clip, expressed on the source */
				const f32 s0 = static_cast<f32>(srcCoord[0]);
				const f32 t0 = static_cast<f32>(srcCoord[1]);
				const f32 msx0 = s0 + (vx0 - nx0) / (nx1 - nx0) * sw;
				const f32 msx1 = s0 + (vx1 - nx0) / (nx1 - nx0) * sw;
				const f32 msy0 = t0 + (vy0 - ny0) / (ny1 - ny0) * sh;
				const f32 msy1 = t0 + (vy1 - ny0) / (ny1 - ny0) * sh;
				const f32 texW = static_cast<f32>(pBufferTexture->width);
				const f32 texH = static_cast<f32>(pBufferTexture->height);
				srcCoord[0] = static_cast<s32>(max(0.0f, min(msx0, texW)) + 0.5f);
				srcCoord[2] = static_cast<s32>(max(0.0f, min(msx1, texW)) + 0.5f);
				srcCoord[1] = static_cast<s32>(max(0.0f, min(msy0, texH)) + 0.5f);
				srcCoord[3] = static_cast<s32>(max(0.0f, min(msy1, texH)) + 0.5f);
				dstCoord[0] = static_cast<s32>(vx0 + 0.5f);
				dstCoord[2] = static_cast<s32>(vx1 + 0.5f);
				dstCoord[1] = static_cast<s32>(vy0 + 0.5f);
				dstCoord[3] = static_cast<s32>(vy1 + 0.5f);
			}
		}
	}
#endif
"""

TRAIL = 3
text = SRC.read_text()
n = text.count(ANCHOR)
if n != 1:
    sys.exit(f"anchor matched {n} times in {SRC} (want 1)")
if "MUPEN_FILL_WINDOW" in text:
    sys.exit("0052 already applied to vendor — reverse it out before regenerating")

start = text.index(ANCHOR)
line_no = text[:start].count("\n") + 1
anchor_lines = ANCHOR.rstrip("\n").split("\n")
add_lines = ADDITION.strip("\n").split("\n")
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
