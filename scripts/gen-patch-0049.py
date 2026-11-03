#!/usr/bin/env python3
"""Generate overlay/patches/0049-cores-mupen-gliden64-overscan-live-geometry.patch.

Why
---
 answered question and killed the 4:3-latch theory: the
`gliden64 live:` beacon fires at DRAW time on device and reads

    swap=240 aspect=3 adjust=1 scale=0.7500 screen=3840x2160 buf=3840x2160
    scaleXY=12.000/9.000

byte-identical to the mac harness at the same options — and the mac renders
full-width widescreen while the device renders the game in a centred ~2880-wide
box (in-game dumps: bbox 479,81-3358,2096 and 540,81-3168,2038; 2880 = 3840*0.75
and 480 = (3840-2880)/2). `DisplayWindow`'s numbers are therefore RIGHT on device
and are not what makes the box.

There is exactly one component left between "correct DisplayWindow geometry" and
"the pixels on screen" that carries its OWN copy of the geometry:
`FrameBufferList::OverscanBuffer`. It caches

    m_hOffset = (wnd.getScreenWidth() - wnd.getWidth()) / 2;
    m_vOffset = (wnd.getScreenHeight() - wnd.getHeight()) / 2;
    m_drawingWidth = wnd.getWidth();
    m_bufferWidth  = wnd.getScreenWidth();
    m_bufferHeight = wnd.getScreenHeight() + wnd.getHeightOffset();

in `init()` — called only from `FrameBufferList::init()`, i.e. from
`GraphicsDrawer::_initData()` — and `renderBuffer()` then computes the entire
destination rectangle from those cached values:

    dstScaleX = m_overscan.getDrawingWidth() / (640 * viScaleX)
    dstX0     = hx0 * viScaleX * dstScaleX + hOffset
    dstX1     = hOffset + drawingWidth - hx1 * viScaleX * dstScaleX

Upstream itself does not trust the cache for the scale: `getScaleX()` and
`getScaleY()` already read `dwnd()` LIVE whenever overscan is disabled, while the
offsets and widths stay cached. That inconsistency is the bug shape we are
looking at — if `_initData()` ever runs while the window is 2880 wide (a 4:3
`_setBufferSize()`, i.e. before the core options have been applied) and the
window later becomes 3840, then `getScaleX()` follows to 12 but `drawingWidth`
stays 2880 and `hOffset` stays 480, and `renderBuffer()` blits into 480..3360 for
the rest of the session — the measured device rectangle, exactly, with the strips
either side never written (0046 made those black instead of rainbow, which the
.19 device dumps confirm by pixel statistics: dump4 nb=5,800,609 against a box
area of 5,801,185).

That ordering is a FRONTEND property, not a core property, which is precisely why
five rounds of desktop reproduction have failed: the desktop host applies its option
overrides before the context is created, RetroArch on device reads them from
`Mupen64Plus-Next.opt` and drives `context_reset`/`reinitGfxContext` on its own
schedule. The mac cannot reach the state; the device can.

The patch therefore does two things:

(a) FIX CANDIDATE — refresh the overscan geometry from the live window once per
    presented frame when overscan is disabled, by re-running `init()` at the top
    of `renderBuffer()`. When overscan is disabled `init()` allocates nothing: it
    only recomputes the six cached values, so this is a handful of integer
    divisions per frame and is a no-op whenever the cache was already correct
    (which is why the mac harness must stay bit-identical). It also makes the
    cached values consistent with `getScaleX()`/`getScaleY()`, which upstream
    already reads live in the same state.

    Caveat, documented rather than coded around: if overscan were toggled ON->OFF
    at runtime, the first refresh would drop the old FBO handle without deleting
    it (one leaked framebuffer, once). visionOS forces overscan off (0043) and
    the option is not exposed in our build, so this cannot happen in the shipped
    configuration.

(b) MEASUREMENT — `gliden64 blit:`, the first beacon that reports the actual
    source and destination rectangles of the final blit, together with the
    overscan cache, the live window, and the draw state that decides the
    "adjusted" squeeze (`isAdjustScreen`, `adjustScale`, `VI.width`,
    `gDP.colorImage.width`, `gSP.viewport`, `gDP.scissor`). It fires on the same
    four frames the RetroArch-side pixel dump fires on (240 / 1140 / 2040 / 2940),
    so every dumped picture has the numbers that produced it sitting next to it in
    the log. This is the line the diagnosis needed: if
    `dst=480,..-3360,..` the box is made by the blit and (a) is the fix; if
    `dst=0,..-3840,..` the box is inside the framebuffer content and the next stop
    is the vertex-side squeeze, with `adj/ascale/ci/VI/vp` naming which term.

Both hunks are additive and anchored on pristine upstream text well clear of
0045's helper (top of file) and 0046's hunk (`FrameBuffer::init()`, ~line 269).

Run from the repo root. TRAP: macOS `patch` (Apple patch
2.0-12u11) rejects a mid-file hunk whose added lines are not followed by context,
so both hunks carry trailing context taken from the source.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REL = "cores/mupen64plus-next/GLideN64/src/FrameBuffer.cpp"
SRC = ROOT / "vendor" / REL
OUT = ROOT / "overlay/patches/0049-cores-mupen-gliden64-overscan-live-geometry.patch"

HELPER_ANCHOR = """FrameBufferList & FrameBufferList::get()
{
	static FrameBufferList frameBufferList;
	return frameBufferList;
}
"""

HELPER = """
/* 0049: beacon writer — see scripts/gen-patch-0049.py. A local copy of 0042's
 * (dlsym RA_BeaconMark when the host exports it, else append the identical
 * timestamped line ourselves — the frontend is built LLVM_LTO=YES_THIN and
 * ThinLTO internalizes RA_BeaconMark, so the dlsym returns NULL on device,
 *), kept self-contained so the overlay patches stay independent. */
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>

static void gliden64_blit_beacon(const char *m)
{
	static void (*ra_beacon)(const char *) = NULL;
	static bool looked_up = false;
	if (!looked_up) {
		looked_up = true;
		ra_beacon = (void (*)(const char *))dlsym(RTLD_DEFAULT, "RA_BeaconMark");
	}
	if (ra_beacon != NULL) {
		ra_beacon(m);
		return;
	}
	{
		const char *home = getenv("HOME");
		char path[1024];
		int fd;
		if (home == NULL)
			return;
		snprintf(path, sizeof(path), "%s/Documents/launch-beacon.log", home);
		fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
		if (fd >= 0) {
			time_t tt = time(NULL);
			struct tm tmv;
			char line[768];
			int n;
			localtime_r(&tt, &tmv);
			n = snprintf(line, sizeof(line), "%04d-%02d-%02d %02d:%02d:%02d  %s\\n",
				tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday,
				tmv.tm_hour, tmv.tm_min, tmv.tm_sec, m);
			if (n > 0)
				(void)write(fd, line, (size_t)n);
			close(fd);
		}
	}
}
"""

REFRESH_ANCHOR = """	pBuffer->m_isMainBuffer = true;
	m_overscan.setInputBuffer(pBuffer);
"""

REFRESH = """
	/* 0049 (a): re-derive the overscan buffer's cached geometry from the live
	 * window every presented frame while overscan is disabled. init() allocates
	 * nothing in that state — it only recomputes m_hOffset/m_vOffset/m_scale/
	 * m_drawingWidth/m_bufferWidth/m_bufferHeight — and renderBuffer() below
	 * builds the whole destination rectangle out of exactly those values, while
	 * getScaleX()/getScaleY() already read dwnd() live in the same state. A
	 * cache captured when the window was still 4:3 (2880 of 3840) is the one
	 * remaining way to get the device's centred box out of a DisplayWindow whose
	 * own draw-time numbers are correct. No-op when the cache already agrees,
	 * which is what keeps the mac harness bit-identical. See gen-patch-0049.py
	 * for the ON->OFF toggle caveat (cannot occur in the shipped config). The
	 * pre-refresh values are kept so the beacon below can report both: after the
	 * refresh the cache always agrees with the window, so without these the fix
	 * would hide its own evidence. */
	const s32 ovs_pre_hoff = m_overscan.getHOffset();
	const u32 ovs_pre_draww = m_overscan.getDrawingWidth();
	if (config.frameBufferEmulation.enableOverscan == 0)
		m_overscan.init();
"""

BEACON_ANCHOR = """	const s32 hOffset = m_overscan.getHOffset();
	const s32 vOffset = m_overscan.getVOffset();
	s32 dstCoord[4] = { dstX0 + hOffset,
						vOffset + static_cast<s32>(dstY0*dstScaleY),
						hOffset + dstX1,
						vOffset + static_cast<s32>(dstY1*dstScaleY) };
"""

BEACON = """
	/* 0049 (b): the rectangles that actually produce the picture, on the same
	 * four frames the RetroArch-side pixel dump fires on. Everything beaconed so
	 * far has been config; this is geometry. */
	{
		static u32 rb_frames = 0;
		++rb_frames;
		if (rb_frames == 240 || rb_frames == 1140 ||
			rb_frames == 2040 || rb_frames == 2940) {
			DisplayWindow & bw = dwnd();
			char m[640];
			snprintf(m, sizeof(m),
				"gliden64 blit: f=%u src=%d,%d-%d,%d tex=%ux%u fbw=%u fbscale=%.2f "
				"dst=%d,%d-%d,%d drawW=%u(pre %u) bufWH=%ux%u hOff=%d(pre %d) vOff=%d "
				"wnd=%ux%u screen=%ux%u adj=%d ascale=%.4f dstScaleX=%.4f "
				"VI=%ux%u ci=%u vp=%.0f+%.0f sciss=%.0f-%.0f",
				rb_frames,
				srcCoord[0], srcCoord[1], srcCoord[2], srcCoord[3],
				pBufferTexture->width, pBufferTexture->height,
				pFilteredBuffer->m_width, pFilteredBuffer->m_scale,
				dstCoord[0], dstCoord[1], dstCoord[2], dstCoord[3],
				m_overscan.getDrawingWidth(), ovs_pre_draww,
				m_overscan.getBufferWidth(), m_overscan.getBufferHeight(),
				hOffset, ovs_pre_hoff, vOffset,
				bw.getWidth(), bw.getHeight(),
				bw.getScreenWidth(), bw.getScreenHeight(),
				bw.isAdjustScreen() ? 1 : 0, bw.getAdjustScale(), dstScaleX,
				VI.width, VI.height, gDP.colorImage.width,
				gSP.viewport.x, gSP.viewport.width,
				gDP.scissor.ulx, gDP.scissor.lrx);
			gliden64_blit_beacon(m);
		}
	}
"""

TRAIL = 2
text = SRC.read_text()
for name, anchor in (("helper", HELPER_ANCHOR),
                     ("refresh", REFRESH_ANCHOR),
                     ("beacon", BEACON_ANCHOR)):
    n = text.count(anchor)
    if n != 1:
        sys.exit(f"{name} anchor matched {n} times in {SRC} (want 1)")
if "0049:" in text or "0049 (a)" in text:
    sys.exit("0049 already applied to vendor — reverse it out before regenerating")


def hunk(anchor, addition):
    start = text.index(anchor)
    line_no = text[:start].count("\n") + 1
    anchor_lines = anchor.rstrip("\n").split("\n")
    add_lines = addition.rstrip("\n").split("\n")
    rest = text[start + len(anchor):].split("\n")[:TRAIL]
    body = [" " + l for l in anchor_lines]
    body += ["+" + l if l else "+" for l in add_lines]
    body += [" " + l if l else " " for l in rest]
    old_count = len(anchor_lines) + len(rest)
    return line_no, old_count, old_count + len(add_lines), body


hunks = [hunk(HELPER_ANCHOR, HELPER),
         hunk(REFRESH_ANCHOR, REFRESH),
         hunk(BEACON_ANCHOR, BEACON)]
hunks.sort(key=lambda h: h[0])

parts = [
    f"diff --git a/{REL} b/{REL}\n",
    f"--- a/{REL}\n",
    f"+++ b/{REL}\n",
]
offset = 0
for line_no, old_count, new_count, body in hunks:
    parts.append(f"@@ -{line_no},{old_count} +{line_no + offset},{new_count} @@\n")
    parts.append("\n".join(body) + "\n")
    offset += new_count - old_count

OUT.write_text("".join(parts))
print(f"wrote {OUT}")

subprocess.run(
    ["patch", "-p3", "--dry-run", "-d", str(ROOT / "vendor/cores/mupen64plus-next"),
     "-i", str(OUT)],
    check=True,
)
print("dry-run OK")
