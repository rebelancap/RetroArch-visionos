#!/usr/bin/env python3
"""Generate overlay/patches/0039-visionos-gl2-clear-hw-fbo-vp-beacon.patch.

Why
---
0038 clears the *backbuffer* outside RetroArch's viewport, but the device beacon
(`angle vp: drawable=3840x2160 vp=0,0 3840x2160 full=3840x2160`) shows the
viewport already covers the whole drawable, so 0038 never fires — and the tester
still sees rainbow bars. That places the garbage INSIDE the core's own output:
GLideN64 under `aspect = "16:9 adjusted"` shrinks full-width draws back to 4:3
(HUD anti-stretch) and blits only that rect into the
hardware-render FBO RetroArch handed it. RetroArch never clears that FBO, and on
the ANGLE/Metal path its backing texture is not zero-initialised, so every pixel
the core does not touch shows undefined memory — rainbow.

Fix: at the end of gl2_frame, clear the hw-render FBO the core will render into
NEXT (`hw_render_fbo[(tex_index + 1) % textures]`, the same index
gl2_get_current_framebuffer hands out). One clear of one FBO per frame; the
scissor is disabled around it and restored, and the previous FBO binding is put
back so nothing else sees a state change. visionOS only.

Run from the repo root; asserts its anchor is unique against pristine vendor
text, then writes the patch. Reverse the old patch out of vendor before
regenerating.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "vendor/RetroArch/gfx/drivers/gl2.c"
OUT = ROOT / "overlay/patches/0039-visionos-gl2-clear-hw-fbo-vp-beacon.patch"

ANCHOR = """   /* Reset state which could easily mess up libretro core. */
   if (gl->flags & GL2_FLAG_HW_RENDER_FBO_INIT)
   {
      gl->shader->use(gl, gl->shader_data, 0, true);
      glBindTexture(GL_TEXTURE_2D, 0);
   }
"""

ADDITION = """
#if defined(RA_VISIONOS)
   /* 0039: clear the hardware-render FBO the core will draw into next.
    *
    * 0038 clears the backbuffer outside RetroArch's viewport, but on visionOS
    * the viewport already covers the whole drawable (the `angle vp` beacon), so
    * it never fires and the rainbow bars survived it. They are inside the
    * CORE's output: GLideN64 under "16:9 adjusted" shrinks full-width draws
    * back to 4:3 and blits only that rect here, and an ANGLE/Metal FBO texture
    * is not zero-initialised, so untouched pixels show undefined memory.
    *
    * gl2_get_current_framebuffer() hands the core
    * hw_render_fbo[(tex_index + 1) % textures]; clear exactly that one, then
    * restore the binding and the scissor state. */
   if (gl->flags & GL2_FLAG_HW_RENDER_FBO_INIT)
   {
      GLint prev_fbo        = 0;
      GLboolean scissor_on  = glIsEnabled(GL_SCISSOR_TEST);
      glGetIntegerv(GL_FRAMEBUFFER_BINDING, &prev_fbo);
      gl2_bind_fb(gl->hw_render_fbo[(gl->tex_index + 1) % gl->textures]);
      if (scissor_on)
         glDisable(GL_SCISSOR_TEST);
      glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
      glClear(GL_COLOR_BUFFER_BIT);
      if (scissor_on)
         glEnable(GL_SCISSOR_TEST);
      gl2_bind_fb((GLuint)prev_fbo);
   }

   /* 0039b: the viewport gl2_frame actually renders with, beaconed on change.
    * The `angle vp` beacon reports the drawable at swap time; this reports what
    * the frame was composed into, together with the size the core handed us —
    * the pair says whether a letterbox is RetroArch's or the core's. */
   {
      static unsigned last[6];
      if (     last[0] != gl->vp.x          || last[1] != gl->vp.y
            || last[2] != gl->vp.width      || last[3] != gl->vp.height
            || last[4] != frame_width       || last[5] != frame_height)
      {
         char _m[192];
         extern void RA_BeaconMark(const char *);
         last[0] = gl->vp.x;      last[1] = gl->vp.y;
         last[2] = gl->vp.width;  last[3] = gl->vp.height;
         last[4] = frame_width;   last[5] = frame_height;
         snprintf(_m, sizeof(_m),
               "gl2 vp: %u,%u %ux%u full=%ux%u core_frame=%ux%u",
               gl->vp.x, gl->vp.y, gl->vp.width, gl->vp.height,
               gl->vp.full_width, gl->vp.full_height,
               frame_width, frame_height);
         RA_BeaconMark(_m);
      }
   }
#endif
"""

text = SRC.read_text()
n = text.count(ANCHOR)
if n != 1:
    sys.exit(f"anchor matched {n} times in {SRC} (want 1) — is vendor pristine for 0039?")
if "0039:" in text:
    sys.exit("0039 already applied to vendor — reverse it out before regenerating")

start = text.index(ANCHOR)
line_no = text[:start].count("\n") + 1  # 1-based line of the anchor's first line

anchor_lines = ANCHOR.rstrip("\n").split("\n")
add_lines = ADDITION.strip("\n").split("\n")

body = [" " + l for l in anchor_lines]
body += ["+" + l if l else "+" for l in add_lines]
body.append(" ")  # trailing context: the blank line after the anchor block

old_count = len(anchor_lines) + 1
new_count = old_count + len(add_lines)

patch = (
    "diff --git a/gfx/drivers/gl2.c b/gfx/drivers/gl2.c\n"
    "--- a/gfx/drivers/gl2.c\n"
    "+++ b/gfx/drivers/gl2.c\n"
    f"@@ -{line_no},{old_count} +{line_no},{new_count} @@\n"
    + "\n".join(body)
    + "\n"
)
OUT.write_text(patch)
print(f"wrote {OUT} ({new_count - old_count} lines added at gl2.c:{line_no})")

subprocess.run(
    ["patch", "-p1", "--dry-run", "-d", str(ROOT / "vendor/RetroArch"), "-i", str(OUT)],
    check=True,
)
print("dry-run OK")
