#!/usr/bin/env python3
"""Generate overlay/patches/0047-cores-mupen-gliden64-reset-adjustscale.patch.

Why
---
`DisplayWindow::_setBufferSize()` resets `m_bAdjustScreen` at the top of every
call but **never resets `m_adjustScale`**. It is only ever assigned inside the
two "adjust" branches, so once a session has been in an adjusted mode the value
0.75 sticks for the life of the process, through every later mode change.

That matters because `gSPClipVertex()` multiplies every vertex's X by
`dwnd().getAdjustScale()` before the clip test **unconditionally** — it does not
consult `isAdjustScreen()`. A stale 0.75 therefore widens the clip volume by 33 %
in stretch and 4:3 modes, which are supposed to clip at the true frustum, and
`ColorBufferToRDRAM` sizes its readback with the same stale factor.

This is open lead (c), and it is a latent-state bug of exactly the kind
that makes a device behave differently from a harness that only ever runs one
mode per process. One line, no behaviour change while the mode is unchanged.

Run from the repo root; asserts its anchor is unique against the vendor text,
then writes the patch. Reverse the old patch out of vendor before regenerating.

TRAP: macOS `patch` (Apple patch 2.0-12u11) rejects a mid-file hunk whose added
lines are not followed by at least one context line.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REL = "cores/mupen64plus-next/GLideN64/src/DisplayWindow.cpp"
SRC = ROOT / "vendor/cores/mupen64plus-next/GLideN64/src/DisplayWindow.cpp"
OUT = ROOT / "overlay/patches/0047-cores-mupen-gliden64-reset-adjustscale.patch"

ANCHOR = """void DisplayWindow::_setBufferSize()
{
	m_bAdjustScreen = false;
"""

ADDITION = """	/* 0047: reset the adjust factor with the flag it belongs to. Upstream only
	 * ever assigns m_adjustScale inside the two adjust branches, so a session
	 * that has been in "adjusted" mode keeps 0.75 forever — and gSPClipVertex()
	 * applies it to the clip test with no isAdjustScreen() check, silently
	 * widening the clip volume in stretch/4:3 modes. lead (c). */
	m_adjustScale = 1.0f;
"""

TRAIL = 2
text = SRC.read_text()
n = text.count(ANCHOR)
if n != 1:
    sys.exit(f"anchor matched {n} times in {SRC} (want 1)")
if "0047:" in text:
    sys.exit("0047 already applied to vendor — reverse it out before regenerating")

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
