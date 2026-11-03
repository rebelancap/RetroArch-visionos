#!/usr/bin/env python3
"""Generate overlay/patches/0048-cores-mupen-gliden64-geometry-resync.patch.

Why
---
Three device rounds have now produced a contradiction that no *number* explains:
the `gliden64 wnd:` beacon reports `aspect=3 buf=3840x2160 adjust=1 scale=0.7500`
on device, byte-identical to the mac harness at the same core options — and the
mac renders full-width true-widescreen SM64 while the device renders a 4:3 box in
the middle of the frame with unwritten strips either side.

The beacon fires in `DisplayWindowMupen64plus::_start()`, i.e. **once, at content
load**. Everything that decides the output rectangle can move afterwards, and
nothing re-derives it:

- `Config_LoadConfig()` (`custom/GLideN64/mupenplus/Config_mupenplus.cpp`) begins
  with `config.resetToDefaults()`, which sets `frameBufferEmulation.aspect = a43`,
  and only then copies `AspectRatio` back over it. It is called from
  `main_set_core_defaults()` as well as at ROM open, and it never calls
  `_setBufferSize()` — so a runtime option change *cannot* take effect, and any
  path that resets the config without the copy leaves GLideN64 latched in 4:3.
- `m_width`/`m_screenWidth`/`m_bAdjustScreen` are only recomputed in `_start()`
  and `_resizeWindow()`. `DisplayWindow` is a process-lifetime singleton
  (`static DisplayWindowMupen64plus video;`), so those values survive content
  close/open and can arrive at the next game already wrong.

A 4:3-latched window is *exactly* the device picture: `_setBufferSize()`'s `a43`
branch gives `m_width = m_screenHeight * 4/3 = 2880` against a 3840 screen, the
overscan buffer captures `hOffset = (3840-2880)/2 = 480`, and
`FrameBufferList::renderBuffer()` blits into 480..3360 — the measured box —
leaving the strips either side untouched (0046 makes those black instead of
noise).

Rather than guess which of the paths above fires in the headset, make the
geometry a **pure function of the live core options, re-derived every frame**.
`_swapBuffers()` runs once per presented frame; if `config...aspect` disagrees
with `AspectRatio`, or the window disagrees with `get_retro_screen_*()`, fix the
config and raise `m_bResizeWindow` — `VI.cpp` calls `resizeWindow()` on the next
VI update, which re-runs `_setBufferSize()` and re-inits the drawer. When nothing
has drifted this is a comparison and nothing else, so the mac harness (which
never drifts) is bit-identical before and after; on device it self-heals within
one frame, and the `gliden64 resync:` beacon says it happened and from what.

It also fixes a real user-facing bug on every platform: changing Aspect Ratio /
Wide Resolution in the RetroArch menu now takes effect without reloading content.

The second half of the patch is the measurement that has been missing all along:
`gliden64 live:` reports the geometry **at draw time** (swap 240 and 1200 of the
process), not at load time. If the picture is still wrong after this, that line
says which value is wrong while the wrong frame is on screen.

Run from the repo root; asserts both anchors are unique against the vendor text,
then writes the patch. Anchors are pristine upstream text, deliberately clear of
overlay 0042's hunks in the same file (its include block and `_start()` body).

TRAP: macOS `patch` (Apple patch 2.0-12u11) rejects a mid-file hunk whose added
lines are not followed by at least one context line. Both hunks carry trailing
context taken from the source.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REL = ("cores/mupen64plus-next/GLideN64/src/Graphics/OpenGLContext/"
       "mupen64plus/mupen64plus_DisplayWindow.cpp")
SRC = ROOT / "vendor" / REL
OUT = ROOT / "overlay/patches/0048-cores-mupen-gliden64-geometry-resync.patch"

HELPER_ANCHOR = """void DisplayWindowMupen64plus::_stop()
{
    FunctionWrapper::CoreVideo_Quit();
}
"""

HELPER = """
/* 0048: beacon writer — see scripts/gen-patch-0048.py. A local copy of 0042's
 * (dlsym RA_BeaconMark when the host exports it, else append the identical
 * timestamped line ourselves — the frontend is built LLVM_LTO=YES_THIN and
 * ThinLTO internalizes RA_BeaconMark, so the dlsym returns NULL on device,
 *), kept self-contained so the two overlay patches stay independent. */
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>

static void gliden64_geom_beacon(const char *m)
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
			char line[512];
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

SWAP_ANCHOR = """void DisplayWindowMupen64plus::_swapBuffers()
{
"""

SWAP = """	/* 0048: re-derive the output geometry from the live core options, every
	 * frame. See scripts/gen-patch-0048.py for the full reasoning; in short,
	 * config.frameBufferEmulation.aspect and the window size are latched at
	 * _start() into a process-lifetime singleton, Config_LoadConfig() resets the
	 * aspect to a43 before copying AspectRatio back, and nothing re-runs
	 * _setBufferSize() afterwards — so the frontend can be showing "16:9
	 * adjusted" while GLideN64 is still laying the frame out as 4:3. When
	 * nothing has drifted this is two comparisons and no side effect. */
	{
		const u32 want_w = get_retro_screen_width();
		const u32 want_h = get_retro_screen_height();
		const int want_a = (int)AspectRatio;
		bool drifted = false;

		if ((int)config.frameBufferEmulation.aspect != want_a) {
			config.frameBufferEmulation.aspect = (Config::Aspect)want_a;
			drifted = true;
		}
		if (want_w != 0 && want_h != 0 &&
			(m_screenWidth != want_w || m_screenHeight != want_h))
			drifted = true;

		if (drifted && want_w != 0 && want_h != 0) {
			char m[256];
			snprintf(m, sizeof(m),
				"gliden64 resync: aspect->%d screen=%ux%u->%ux%u buf=%ux%u "
				"adjust=%d scale=%.4f",
				want_a, m_screenWidth, m_screenHeight, want_w, want_h,
				m_width, m_height, m_bAdjustScreen ? 1 : 0, m_adjustScale);
			gliden64_geom_beacon(m);
			/* resizeWindow() (VI.cpp, next VI update) re-runs _resizeWindow() ->
			 * _setBufferSize() and re-inits the drawer with the new geometry. */
			m_resizeWidth = want_w;
			m_resizeHeight = want_h;
			m_bResizeWindow = true;
		}
	}

	/* 0048: the geometry AT DRAW TIME. Every previous round beaconed it at
	 * content load only, which is why three device logs read correct while the
	 * picture was wrong. Twice per process, well clear of boot. */
	{
		static u32 swaps = 0;
		++swaps;
		if (swaps == 240 || swaps == 1200) {
			char m[256];
			snprintf(m, sizeof(m),
				"gliden64 live: swap=%u aspect=%d adjust=%d scale=%.4f "
				"screen=%ux%u buf=%ux%u scaleXY=%.3f/%.3f",
				swaps, (int)config.frameBufferEmulation.aspect,
				m_bAdjustScreen ? 1 : 0, m_adjustScale,
				m_screenWidth, m_screenHeight, m_width, m_height,
				m_scaleX, m_scaleY);
			gliden64_geom_beacon(m);
		}
	}

"""

TRAIL = 2
text = SRC.read_text()
for name, anchor in (("helper", HELPER_ANCHOR), ("swap", SWAP_ANCHOR)):
    n = text.count(anchor)
    if n != 1:
        sys.exit(f"{name} anchor matched {n} times in {SRC} (want 1)")
if "0048:" in text:
    sys.exit("0048 already applied to vendor — reverse it out before regenerating")


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


h1 = hunk(HELPER_ANCHOR, HELPER)
h2 = hunk(SWAP_ANCHOR, SWAP)

parts = [
    f"diff --git a/{REL} b/{REL}\n",
    f"--- a/{REL}\n",
    f"+++ b/{REL}\n",
]
offset = 0
for line_no, old_count, new_count, body in (h1, h2):
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
