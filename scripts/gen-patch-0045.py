#!/usr/bin/env python3
"""Generate overlay/patches/0045-cores-mupen-gliden64-fb-scale-beacon.patch.

Why
---
The tester reports that NativeResFactor OFF / 1 / 3 / 5 make **no visible difference
on device**. Factor 1 means a 320x240 internal render — at 4K output that would
be unmissable — so either the option is not reaching the place that decides the
internal resolution, or something else overrides it. Nothing we log today can
tell the two apart: the 0042 `gliden64 wnd:` beacon prints the option value as
*configured*, not the resolution actually allocated.

`FrameBuffer::init()` (GLideN64/src/FrameBuffer.cpp) is the single place where
that decision is made:

    if (isAuxiliary() && copyAuxToRDRAM != 0)      m_scale = 1.0f;
    else if (nativeResFactor != 0 && fbEmulation.enable != 0)
                                                  m_scale = nativeResFactor;
    else                                          m_scale = max(getScaleX(), 1)

Note the second branch's **`config.frameBufferEmulation.enable`** term: with
`EnableFBEmulation = False`, `nativeResFactor` is ignored outright and the scale
falls back to `screenWidth / VI.width` (12.0 at a 3840-wide screen) no matter
what the user picks. That is a complete, self-consistent explanation of "OFF and
5x look the same", and it is one beacon line away from being settled.

So: beacon the main (non-auxiliary) framebuffer's real allocation — the branch
taken, the resulting `m_scale`, the requested texture size, `VI.width/height`,
the effective `nativeResFactor` and `EnableFBEmulation`. Change-gated, so a
steady session prints one line per distinct configuration and a settings change
prints one more. Auxiliary buffers are skipped; a game allocates many of those
per frame and they are not the internal render resolution anyone means.

The beacon writer is a self-contained copy of the one 0042 added to
mupen64plus_DisplayWindow.cpp (dlsym RA_BeaconMark first, POSIX append to
$HOME/Documents/launch-beacon.log when ThinLTO has hidden it —), kept
local so the two patches stay independent of each other.

Run from the repo root; asserts its anchor is unique against pristine vendor
text, then writes the patch. Reverse the old patch out of vendor before
regenerating.

TRAP: macOS `patch` (Apple patch 2.0-12u11) rejects a mid-file hunk whose added
lines are not followed by at least one context line. Every hunk here carries
trailing context taken from the source.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REL = "cores/mupen64plus-next/GLideN64/src/FrameBuffer.cpp"
SRC = ROOT / "vendor/cores/mupen64plus-next/GLideN64/src/FrameBuffer.cpp"
OUT = ROOT / "overlay/patches/0045-cores-mupen-gliden64-fb-scale-beacon.patch"

ANCHOR = """	m_cfb = _cfb;
	m_cleared = false;
	m_fingerprint = false;
	m_swapCount = dwnd().getBuffersSwapCount();
"""

ADDITION = """
	/* 0045: the internal render resolution, as ACTUALLY allocated.
	 *
	 * The tester sees no difference between NativeResFactor OFF / 1 / 3 / 5 on the
	 * headset; factor 1 would be a 320x240 internal render, so something is
	 * overriding the option. The branch just above is the only place that
	 * decides, and its second arm also requires
	 * config.frameBufferEmulation.enable — with EnableFBEmulation off,
	 * nativeResFactor is ignored and m_scale falls back to
	 * screenWidth / VI.width (12.0 at 3840). This line says which branch ran
	 * and what got allocated, so the question is answered from one device log.
	 *
	 * Main framebuffers only (an auxiliary buffer is not the internal render
	 * resolution anyone means, and games allocate many per frame), and gated on
	 * change so a steady session prints one line.
	 *
	 * Beacon plumbing is 0042's, duplicated deliberately so the two patches do
	 * not depend on each other: RA_BeaconMark by dlsym when the host exports it,
	 * else write the identical timestamped line ourselves — the frontend is
	 * built LLVM_LTO=YES_THIN and ThinLTO internalizes RA_BeaconMark, so the
	 * dlsym returns NULL on device. */
	if (!isAuxiliary()) {
		static float    last_scale  = -1.0f;
		static unsigned last_w      = 0, last_h = 0, last_nrf = 0;
		static int      last_fbe    = -1;
		const unsigned  viw         = VI.width, vih = VI.height;
		const unsigned  nrf         = config.frameBufferEmulation.nativeResFactor;
		const int       fbe         = config.frameBufferEmulation.enable != 0 ? 1 : 0;
		if (   last_scale != m_scale || last_w != viw || last_h != vih
		    || last_nrf   != nrf     || last_fbe != fbe) {
			char m[256];
			last_scale = m_scale; last_w = viw; last_h = vih;
			last_nrf   = nrf;     last_fbe = fbe;
			snprintf(m, sizeof(m),
				"gliden64 fb: VI=%ux%u scale=%.3f -> internal=%ux%u "
				"nativeres=%u fbemu=%d dwndScaleX=%.3f branch=%s",
				viw, vih, m_scale,
				(unsigned)(viw * m_scale), (unsigned)(vih * m_scale),
				nrf, fbe, dwnd().getScaleX(),
				(nrf != 0 && fbe != 0) ? "nativeResFactor" : "screen/VI");
			gliden64_fb_beacon(m);
		}
	}
"""

HELPER_ANCHOR = """#include <Graphics/Context.h>
#include <Graphics/Parameters.h>
#include <Graphics/ColorBufferReader.h>
#include "DisplayWindow.h"
"""

HELPER = """
/* 0045: beacon writer — see scripts/gen-patch-0045.py. Local copy of 0042's, so
 * the two overlay patches stay independent. */
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>

static void gliden64_fb_beacon(const char *m)
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

TRAIL = 2
text = SRC.read_text()
for name, anchor in (("helper", HELPER_ANCHOR), ("beacon", ANCHOR)):
    n = text.count(anchor)
    if n != 1:
        sys.exit(f"{name} anchor matched {n} times in {SRC} (want 1)")
if "0045:" in text:
    sys.exit("0045 already applied to vendor — reverse it out before regenerating")


def hunk(anchor, addition):
    start = text.index(anchor)
    line_no = text[: start].count("\n") + 1
    anchor_lines = anchor.rstrip("\n").split("\n")
    add_lines = addition.strip("\n").split("\n")
    rest = text[start + len(anchor) :].split("\n")[:TRAIL]
    body = [" " + l for l in anchor_lines]
    body += ["+" + l if l else "+" for l in add_lines]
    body += [" " + l if l else " " for l in rest]
    old_count = len(anchor_lines) + len(rest)
    return line_no, old_count, old_count + len(add_lines), body


h1 = hunk(HELPER_ANCHOR, HELPER)
h2 = hunk(ANCHOR, ADDITION)

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
