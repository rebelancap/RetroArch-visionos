#!/usr/bin/env python3
"""Regenerate overlay/patches/0043-cores-mupen-xros-force-threaded-off-overscan-off.patch.

0043 was hand-written for as a pair of *diagnostic* forces on the
visionOS mupen slice (`MUPEN_VK_DEFAULT`):

  EnableThreadedRenderer = 0;   /* GL replay on a worker thread — suspect */
  EnableOverscan         = 0;   /* OverscanBuffer stale-offset — suspect */

Both are FORCES rather than defaults because the values are persisted in
`Mupen64Plus-Next.opt` on the tester's device, so a changed default is inert there.

** revises only the ThreadedRenderer half**. The overscan force
stays exactly as it was and is now a feature decision, not a diagnostic one:
overlay 0052's window fill is *gated* on overscan compositing being off,
so the two are alternative answers to the same question and 0052 is the one that
is measured. Do not remove it.

The ThreadedRenderer half becomes a one-flag switch:

    #if defined(MUPEN_FORCE_THREADED_RENDERER)
           EnableThreadedRenderer = (MUPEN_FORCE_THREADED_RENDERER);
    #else
           EnableThreadedRenderer = 0;
    #endif

`scripts/build-core-xros.sh` and both pass
`-DMUPEN_FORCE_THREADED_RENDERER=1`. **Reverting the experiment is
one character** in build-core-xros.sh (`=1` -> `=0`) — no patch edit, no
regeneration, and the forced-off behaviour is bit-identical to .16-.23 because
the `#else` arm is the old line verbatim.

Why it is now safe to try at all: the static-TLS ANGLE work removed
the pthread-key disease that made a GL worker thread lethal on this slice.
GLideN64's ThreadedOpenGl layer (`FunctionWrapper`) replays every GL call from a
second thread; before that thread lost its ANGLE per-thread state and the
crash family was open. It is closed, and measured the win: `retro_run`
3.219 -> 1.970 ms (-39 %) at the tester's exact config on the mac harness.

Run from the repo root, against a vendor tree with 0043 (and 0051, which lands
in the same function) reversed out.
"""
import difflib
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REL = "cores/mupen64plus-next/libretro/libretro.c"
SRC = ROOT / "vendor" / REL
OUT = ROOT / "overlay/patches/0043-cores-mupen-xros-force-threaded-off-overscan-off.patch"

THREADED_ANCHOR = """          EnableThreadedRenderer = !strcmp(var.value, "True") ? 1 : 0;
       }
"""

THREADED_ADD = """          EnableThreadedRenderer = !strcmp(var.value, "True") ? 1 : 0;
       }

#if defined(MUPEN_VK_DEFAULT)
       /* 0043 (visionOS only) — the threaded-renderer force, one compile flag.
        *
        * GLideN64's ThreadedOpenGl layer (FunctionWrapper) replays every GL call
        * from a second thread. It defaulted to True on this slice (overlay 0016,
        * a macOS-harness perf win) and FORCED it off: it had never been
        * exercised against ANGLE on device, and / pthread-key TLS
        * disease is precisely a *worker thread* losing its ANGLE per-thread
        * state. Forced rather than defaulted because the value is persisted in
        * the per-core options file on the tester's device, so a changed default is
        * inert there.
        *
        * tries it ON: the static-TLS work closed that crash
        * family, and measured retro_run 3.219 -> 1.970 ms (-39 %) at
        * The tester's exact settings. The value is now whatever
        * MUPEN_FORCE_THREADED_RENDERER says, so reverting the experiment is a
        * single character in scripts/build-core-xros.sh; with the flag absent or
        * 0 this is byte-for-byte the .16-.23 behaviour. The `gliden64 wnd:`
        * beacon reports the effective value. */
#if defined(MUPEN_FORCE_THREADED_RENDERER)
       EnableThreadedRenderer = (MUPEN_FORCE_THREADED_RENDERER);
#else
       EnableThreadedRenderer = 0;
#endif
#endif
"""

OVERSCAN_ANCHOR = """          EnableOverscan = !strcmp(var.value, "Enabled") ? 1 : 0;
       }
"""

OVERSCAN_ADD = """          EnableOverscan = !strcmp(var.value, "Enabled") ? 1 : 0;
       }

#if defined(MUPEN_VK_DEFAULT)
       /* 0043 (visionOS only): FORCE overscan cropping off. Introduced in
        * as a diagnostic — with it on, GLideN64 presents through
        * OverscanBuffer, whose offsets are captured once in _initData() while
        * its scale is refreshed every frame. Kept as a FEATURE decision since
        * overlay 0052's uniform window fill is written
        * against the non-overscan destination rectangle and is the measured
        * answer to the black-margin question, so overscan compositing must stay
        * out of the path. Same persistence reasoning as ThreadedRenderer above:
        * forced, not defaulted. The beacon reports the effective value. */
       EnableOverscan = 0;
#endif
"""

text = SRC.read_text()
if "MUPEN_FORCE_THREADED_RENDERER" in text or "0043 (visionOS only)" in text:
    sys.exit("0043 already applied to vendor — reverse it out before regenerating")

for name, anchor in (("threaded", THREADED_ANCHOR), ("overscan", OVERSCAN_ANCHOR)):
    n = text.count(anchor)
    if n != 1:
        sys.exit(f"{name} anchor matched {n} times in {SRC} (want 1)")

new = text.replace(THREADED_ANCHOR, THREADED_ADD).replace(OVERSCAN_ANCHOR, OVERSCAN_ADD)
if new == text:
    sys.exit("no change produced")

diff = difflib.unified_diff(
    text.splitlines(keepends=True),
    new.splitlines(keepends=True),
    fromfile=f"a/{REL}",
    tofile=f"b/{REL}",
    n=3,
)
OUT.write_text(f"diff --git a/{REL} b/{REL}\n" + "".join(diff))
print(f"wrote {OUT}")

subprocess.run(
    ["patch", "-p3", "--dry-run", "--force", "--fuzz=0",
     "-d", str(ROOT / "vendor/cores/mupen64plus-next"), "-i", str(OUT)],
    check=True,
)
print("dry-run OK")
