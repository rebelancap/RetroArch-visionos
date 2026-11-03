#!/usr/bin/env python3
"""Generate overlay/patches/0046-cores-mupen-gliden64-clear-fb-on-alloc.patch.

Why
---
The tester's device capture of stage 1 — the hardware-render FBO the core
draws into, read back BEFORE RetroArch composites anything — shows the game in a
centred box and **rainbow noise** (uninitialised memory) in the strips either
side of it. RetroArch is therefore innocent: the noise is inside GLideN64's own
output.

Where it comes from is not mysterious once you look at the blit. With frame
buffer emulation on, GLideN64 renders the game into an *internal* framebuffer
(`VI.width * nativeResFactor` wide — 1600x1200 at the tester's settings) and
`FrameBufferList::renderBuffer()` copies **the whole internal texture** onto the
screen. Anything inside that texture the game never drew to is copied out
verbatim. `FrameBuffer::init()` allocates the colour attachment with
`glTexImage2D(..., nullptr)`, whose contents are undefined — on ANGLE/Metal that
is whatever was last in that piece of VRAM, i.e. rainbow noise — and upstream's
own clear on the line below is **commented out**:

    } else
        _setAndAttachTexture(m_FBO, m_pTexture, 0, false);

//  gfxContext.clearColorBuffer(0.0f, 0.0f, 0.0f, 0.0f);

Every mode where the game does not cover the full buffer therefore shows noise
rather than black: 4:3 and "16:9 adjusted" on a 16:9 screen, overscan, and any
game whose scissor is smaller than its colour image. Clearing at the destination
cannot fix it (RetroArch's clear, GLideN64's own `clearColorBuffer` before the
blit, overlay 0039's hw-FBO clear — all of them are overwritten by the blit that
carries the noise). It has to be cleared at the source, once, at allocation.

So: bind the freshly attached FBO and clear it. `ContextImpl::clearColorBuffer()`
already disables the scissor test around the clear, so the whole attachment is
covered. Cost is one clear per framebuffer allocation, not per frame.

Run from the repo root; asserts its anchor is unique against the vendor text,
then writes the patch. Reverse the old patch out of vendor before regenerating.

TRAP: macOS `patch` (Apple patch 2.0-12u11) rejects a mid-file hunk whose added
lines are not followed by at least one context line. The hunk here carries
trailing context taken from the source.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
REL = "cores/mupen64plus-next/GLideN64/src/FrameBuffer.cpp"
SRC = ROOT / "vendor/cores/mupen64plus-next/GLideN64/src/FrameBuffer.cpp"
OUT = ROOT / "overlay/patches/0046-cores-mupen-gliden64-clear-fb-on-alloc.patch"

ANCHOR = """	} else
		_setAndAttachTexture(m_FBO, m_pTexture, 0, false);

//	gfxContext.clearColorBuffer(0.0f, 0.0f, 0.0f, 0.0f);
"""

ADDITION = """
	/* 0046: zero the colour attachment we just allocated.
	 *
	 * glTexImage2D(..., nullptr) leaves undefined contents, and
	 * FrameBufferList::renderBuffer() blits the WHOLE internal texture to the
	 * screen — so every pixel the game never draws to is presented as whatever
	 * was in that VRAM. On ANGLE/Metal (visionOS) that is the rainbow noise
	 * The tester sees in the side bars of the core's own framebuffer, before
	 * RetroArch touches the frame. Upstream's clear on the line above is
	 * commented out; restore it. clearColorBuffer() disables the scissor test
	 * itself, so this covers the whole attachment, and it costs one clear per
	 * framebuffer allocation, not per frame. Must hold in EVERY aspect mode:
	 * a mode that does not fill the screen shows black bars, never noise. */
	gfxContext.bindFramebuffer(bufferTarget::DRAW_FRAMEBUFFER, m_FBO);
	gfxContext.clearColorBuffer(0.0f, 0.0f, 0.0f, 0.0f);
"""

TRAIL = 2
text = SRC.read_text()
n = text.count(ANCHOR)
if n != 1:
    sys.exit(f"anchor matched {n} times in {SRC} (want 1)")
if "0046:" in text:
    sys.exit("0046 already applied to vendor — reverse it out before regenerating")

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
