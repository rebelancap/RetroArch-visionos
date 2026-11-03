#!/usr/bin/env python3
"""Generate overlay/patches/0041-cores-mupen-gliden64-angle-clear-garbage.patch
and overlay/patches/0042-cores-mupen-gliden64-geometry-beacon.patch.

0041 — the rainbow bars
-----------------------
`ContextImpl::clearColorBuffer()` clears via `glClearBufferfv` on GLES3, except
on Android where upstream falls back to `glClear` with this comment:

    // Using the GLES3 paths causes some background garbage where the Overscan is
    // TODO: Investigate this

"Background garbage where the overscan is" is *exactly* what the tester reports:
rainbow noise in the bars around the N64 image. The workaround is gated to
`OS_ANDROID`, and Android was simply the only ANGLE target upstream tested —
visionOS drives ANGLE (GLES3-over-Metal) too and therefore takes the known-bad
path. Same shape, and the same fix, as overlay 0026, which had to un-gate
GLideN64's other ANGLE quirk from `OS_ANDROID` for exactly this reason.
`GLInfo::init()` already classifies the renderer as `Renderer::Angle` from the
GL version string, so the condition is available for free.

0042 — the decisive geometry beacon
-----------------------------------
Nothing the tester changes has a visible effect, but the mac harness honours every
one of those options, so the device
must differ somewhere between "RetroArch delivers the option" and "GLideN64
sizes its output". `DisplayWindowMupen64plus::_start()` is the single point
where every one of those values has landed: the screen size from
`169screensize`, the aspect mode from `-aspect`, the adjust scale that "16:9
adjusted" implies, and the native-res factor. One beacon line there says which
of them is wrong — or that all of them are right and the fault is further down.

The core dylib cannot link RetroArch's `RA_BeaconMark`, so it is resolved with
`dlsym(RTLD_DEFAULT, ...)` at first use; if it is not there (the mac harness,
any non-RetroArch host) the beacon silently does nothing.

Run from the repo root against pristine vendor text; asserts every anchor.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CORE = ROOT / "vendor/cores/mupen64plus-next"

CLEAR_SRC = "GLideN64/src/Graphics/OpenGLContext/opengl_ContextImpl.cpp"
DWND_SRC = "GLideN64/src/Graphics/OpenGLContext/mupen64plus/mupen64plus_DisplayWindow.cpp"

CLEAR_ANCHOR = """	} else {
#if defined(OS_ANDROID)
		// Using the GLES3 paths causes some background garbage where the Overscan is
		// TODO: Investigate this
		m_cachedFunctions->getCachedClearColor()->setClearColor(_red, _green, _blue, _alpha);
		glClear(GL_COLOR_BUFFER_BIT);
#else
		GLfloat values[4] = {_red, _green, _blue, _alpha};
		glClearBufferfv(GL_COLOR, 0, values);
#endif // OS_ANDROID
	}
"""

CLEAR_NEW = """	} else if (m_glInfo.renderer == Renderer::Angle) {
		/* 0041: upstream's own comment on the GLES3 clear path is "causes some
		 * background garbage where the Overscan is" — which is precisely the
		 * rainbow noise in the letterbox bars on visionOS. Upstream gated the
		 * glClear fallback to OS_ANDROID because Android was the only ANGLE
		 * target they tested; we drive ANGLE (GLES3-over-Metal) as well, so take
		 * the same fallback wherever the renderer IS ANGLE. Mirrors overlay 0026.
		 */
		m_cachedFunctions->getCachedClearColor()->setClearColor(_red, _green, _blue, _alpha);
		glClear(GL_COLOR_BUFFER_BIT);
	} else {
#if defined(OS_ANDROID)
		// Using the GLES3 paths causes some background garbage where the Overscan is
		// TODO: Investigate this
		m_cachedFunctions->getCachedClearColor()->setClearColor(_red, _green, _blue, _alpha);
		glClear(GL_COLOR_BUFFER_BIT);
#else
		GLfloat values[4] = {_red, _green, _blue, _alpha};
		glClearBufferfv(GL_COLOR, 0, values);
#endif // OS_ANDROID
	}
"""


def read(rel):
    return (CORE / rel).read_text()


def one_hunk(rel, anchor, new, tag):
    text = read(rel)
    if tag in text:
        sys.exit(f"{rel}: {tag} already applied — reverse it out before regenerating")
    n = text.count(anchor)
    if n != 1:
        sys.exit(f"{rel}: anchor matched {n} times (want 1):\n{anchor}")
    start = text.index(anchor)
    line_no = text[:start].count("\n") + 1
    a = anchor.rstrip("\n").split("\n")
    b = new.rstrip("\n").split("\n")
    body = ["-" + l if l else "-" for l in a] + ["+" + l if l else "+" for l in b]
    p = f"cores/mupen64plus-next/{rel}"
    return (
        f"diff --git a/{p} b/{p}\n--- a/{p}\n+++ b/{p}\n"
        f"@@ -{line_no},{len(a)} +{line_no},{len(b)} @@\n" + "\n".join(body) + "\n"
    )


# ---- 0041 -------------------------------------------------------------------
out41 = ROOT / "overlay/patches/0041-cores-mupen-gliden64-angle-clear-garbage.patch"
out41.write_text(one_hunk(CLEAR_SRC, CLEAR_ANCHOR, CLEAR_NEW, "0041:"))
print(f"wrote {out41}")

# ---- 0042 -------------------------------------------------------------------
dwnd = read(DWND_SRC)
DW_ANCHOR = """	m_screenWidth = get_retro_screen_width();
	m_screenHeight = get_retro_screen_height();
	_getDisplaySize();
	_setBufferSize();
"""
if DW_ANCHOR not in dwnd:
    # Fall back: locate the _setBufferSize() call inside _start() and print
    # context so the anchor can be fixed rather than guessed at.
    idx = dwnd.find("_setBufferSize();")
    sys.exit(
        "0042 anchor not found; context around _setBufferSize():\n"
        + dwnd[max(0, idx - 400) : idx + 200]
    )

DW_NEW = """	m_screenWidth = get_retro_screen_width();
	m_screenHeight = get_retro_screen_height();
	_getDisplaySize();
	_setBufferSize();

	/* 0042: one beacon line carrying every value that decides the output
	 * rectangle, at the single point where all of them have landed. The tester sees
	 * a letterbox on device that this core does not produce in the mac harness
	 * so the disagreement is in one of
	 * these numbers. aspect: 0=stretch 1=4:3 2=16:9 3=adjust4:3 4=adjust16:9
	 * (Config.h). RetroArch's RA_BeaconMark is in the host executable, not
	 * linkable from here — resolve it once; absent (mac harness), do nothing. */
	{
		static void (*ra_beacon)(const char *) = NULL;
		static bool ra_beacon_looked_up = false;
		if (!ra_beacon_looked_up) {
			ra_beacon_looked_up = true;
			ra_beacon = (void (*)(const char *))dlsym(RTLD_DEFAULT, "RA_BeaconMark");
		}
		if (ra_beacon != NULL) {
			char m[256];
			snprintf(m, sizeof(m),
				"gliden64 wnd: screen=%ux%u buf=%ux%u adjust=%d scale=%.4f "
				"aspect=%d nativeres=%u overscan=%d scaleXY=%.3f/%.3f",
				m_screenWidth, m_screenHeight, m_width, m_height,
				m_bAdjustScreen ? 1 : 0, m_adjustScale,
				(int)config.frameBufferEmulation.aspect,
				config.frameBufferEmulation.nativeResFactor,
				config.frameBufferEmulation.enableOverscan ? 1 : 0,
				m_scaleX, m_scaleY);
			ra_beacon(m);
		}
	}
"""

hunk = one_hunk(DWND_SRC, DW_ANCHOR, DW_NEW, "0042:")

# The beacon needs <dlfcn.h>; add it next to the file's existing includes.
INC_ANCHOR = '#include <DisplayWindow.h>\n'
if INC_ANCHOR not in dwnd:
    sys.exit(f"{DWND_SRC}: include anchor not found")
inc_hunk = one_hunk(
    DWND_SRC,
    INC_ANCHOR,
    INC_ANCHOR + "#include <dlfcn.h>   /* 0042: RA_BeaconMark lives in the host */\n",
    "__never__",
)

out42 = ROOT / "overlay/patches/0042-cores-mupen-gliden64-geometry-beacon.patch"
out42.write_text(inc_hunk + hunk)
print(f"wrote {out42}")

for p in (out41, out42):
    subprocess.run(
        ["patch", "-p3", "--dry-run", "-d", str(CORE), "-i", str(p)], check=True
    )
print("dry-run OK")
