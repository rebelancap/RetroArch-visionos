#!/usr/bin/env python3
"""Generate overlay/patches/0044-visionos-gl2-two-stage-pixel-dump.patch.

Why (revision 2)
---------------------------
Revision 1 shipped a ONE-SHOT two-stage capture that fired on the
first non-menu frame at/after frame 300 (~5 s after content load).  The tester ran
it and both stages came back **pure black** except RetroArch's own FPS counter,
correctly rendered, in the present stage.

That result is not the bug — it is a **sampling accident**, and the mac harness
proves it: run at the device's exact configuration
(3840x2160 / "16:9 adjusted" /
NativeResFactor 5), SM64's boot has several **completely black** seconds in its
first 11 s — frames 60, 120, 360 and 420 are 100 % black (fades), while 180-300
is the logo and 480+ is the Mario-head screen
The device dump fired 5 s after a
content RELOAD, with a 249.7 ms hitch inside that window (the pace beacon), so
it landed in a fade.  The instrument worked perfectly — the FPS text it captured
is proof the read is faithful — it just photographed a black frame.

Revision 2 therefore makes the capture impossible to waste, and makes the
BEACON LINE decisive on its own so a verdict no longer depends on
copying ~30 MB of BMPs off the device:

1. **Content-gated.**  From frame 240, every 30th frame cheaply probes the
   centre 1/8 rect of the hardware-render FBO.  A full capture is taken only
   when that probe is non-black (or, as a backstop, unconditionally once
   frame 1800 is reached — a core FBO that is STILL black after 30 s is itself
   the answer, so it must be recorded, not skipped).
2. **Up to four captures**, spaced >=900 frames (15 s), so a whole session is
   sampled rather than one instant.
3. **Statistics in the beacon**: for each stage, the count of non-black pixels
   and the **bounding box of the non-black content in TRUE pixels** (y measured
   from the bottom, GL order).  That single number pair answers the geometry
   question outright:
     - core bbox already ~0.75 of the width, centred -> the compression is
       inside GLideN64/ANGLE;
     - core bbox full, present bbox compressed -> RetroArch's blit;
     - both full while the headset shows a pillarboxed picture -> the bug is
       below GL (CAMetalLayer / visionOS presentation) and no GL-side change
       can fix it.
4. **Pre-composite probe** (`pre0=`): at the TOP of `gl2_frame`, before
   RetroArch clears and draws, the centre of the DEFAULT framebuffer is probed.
   This settles the "does the core blit straight past RetroArch into the window
   surface" theory with a number.  (Source already refutes it: glsm rewrites
   framebuffer 0 to RetroArch's hw FBO — `rglBindFramebuffer()`,
   `default_framebuffer = glsm_get_current_framebuffer()` — and GLideN64's
   `_getDefaultFramebuffer()` returns `ObjectHandle::null`, so every
   present-path bind lands in RetroArch's FBO.  The probe is the pixel-level
   confirmation.)

RetroArch's own screenshot machinery still cannot substitute:
`gl2_renderchain_readback()` reads the BACK BUFFER only, clipped to `gl->vp`,
and skips `glReadBuffer` entirely on GLES — it can never show the core's output.

Cost control
------------
- The probe reads a (w/8 x h/8) rect (480x270 at 4K, ~0.5 MB) twice a second.
- A full capture reads both buffers once and writes 24-bit BMPs point-sampled to
  a <=960 long edge (~2 MB each); at most 4 pairs (~16 MB) per session.
- Menu-gated: RetroArch draws the menu through this same swap path.
- visionOS only.

Run from the repo root; asserts every anchor is unique against pristine vendor
text, then writes the patch.  Reverse the old patch out of vendor before
regenerating.

DISABLED BY DEFAULT. A 60 s device log showed
iter_ms spikes of 170-270 ms landing immediately after each `gl2 dump` line, and
nothing like them in between (baseline 59.1-59.8 fps, swap_ms ~0, iter_ms avg
5-6 ms). The capture is a synchronous full-surface glReadPixels plus a BMP write
on the render thread, so it was costing most of the "56.89 fps" it was being used
to explain. All three blocks are now additionally gated on
**RA_VISION_PIXEL_DUMP**, which nothing defines.

TO RE-ENABLE for a future diagnostic round: add `-DRA_VISION_PIXEL_DUMP` to the
two xros `OTHER_CFLAGS` lines in `vendor/RetroArch/pkg/apple/BaseConfig.xcconfig`
(:167 xros, :169 xrsimulator — right next to `-DRA_VISIONOS`) and rebuild. Nothing else changes; the beacon format is unchanged. The
cheap geometry evidence — overlay 0049 (b)'s `gliden64 blit:` line, four log
lines per session and no readback — stays on and is what to read instead.
"""
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "vendor/RetroArch/gfx/drivers/gl2.c"
OUT = ROOT / "overlay/patches/0044-visionos-gl2-two-stage-pixel-dump.patch"

# ---------------------------------------------------------------- hunk 1: helpers
ANCHOR1 = """   gl2_renderchain_readback(gl, gl->renderchain_data,
         gl2_get_alignment(gl->vp.width * sizeof(uint32_t)),
         fmt, type, NULL);
   gl2_renderchain_unbind_pbo();
}
"""

ADDITION1 = """#if defined(RA_VISIONOS) && defined(RA_VISION_PIXEL_DUMP)
/* 0044: content-gated two-stage device pixel capture + statistics.
 * See scripts/gen-patch-0044.py for the full rationale. */
#include <stdio.h>
#include <sys/stat.h>

/* Filled by the pre-composite probe at the top of gl2_frame, reported by the
 * capture beacon: how much of the DEFAULT framebuffer is already non-black
 * BEFORE RetroArch clears and composes. */
static unsigned ra_vision_pre_nb  = 0;
static unsigned ra_vision_pre_tot = 0;

typedef struct
{
   unsigned nb;                     /* non-black pixels (max channel > 8) */
   unsigned maxv;                   /* brightest channel value seen       */
   unsigned x0, y0, x1, y1;         /* bbox of non-black, y from BOTTOM   */
} ra_vision_stats_t;

static void ra_vision_scan(const unsigned char *rgba,
      unsigned w, unsigned h, ra_vision_stats_t *s)
{
   unsigned x, y;
   s->nb   = 0;
   s->maxv = 0;
   s->x0   = w;  s->y0 = h;
   s->x1   = 0;  s->y1 = 0;
   for (y = 0; y < h; y++)
   {
      const unsigned char *p = rgba + (size_t)y * w * 4;
      for (x = 0; x < w; x++, p += 4)
      {
         unsigned v = p[0];
         if (p[1] > v) v = p[1];
         if (p[2] > v) v = p[2];
         if (v > s->maxv)
            s->maxv = v;
         if (v > 8)
         {
            s->nb++;
            if (x < s->x0) s->x0 = x;
            if (x > s->x1) s->x1 = x;
            if (y < s->y0) s->y0 = y;
            if (y > s->y1) s->y1 = y;
         }
      }
   }
   if (!s->nb)
   {
      s->x0 = s->y0 = s->x1 = s->y1 = 0;
   }
}

/* Cheap "is there a picture at all" probe: reads the centre (w/8 x h/8) rect of
 * `fbo` and counts non-black pixels. ~0.5 MB at 4K. Binding is restored. */
static unsigned ra_vision_probe(GLuint fbo, unsigned fw, unsigned fh)
{
   unsigned char *buf;
   GLint          prev = 0;
   unsigned       i, nb = 0;
   unsigned       pw   = fw / 8;
   unsigned       ph   = fh / 8;

   if (pw < 16 || ph < 16)
      return 0;
   if (!(buf = (unsigned char*)malloc((size_t)pw * ph * 4)))
      return 0;

   glGetIntegerv(GL_FRAMEBUFFER_BINDING, &prev);
   gl2_bind_fb(fbo);
   glPixelStorei(GL_PACK_ALIGNMENT, 1);
   while (glGetError() != GL_NO_ERROR);
   glReadPixels(fw / 2 - pw / 2, fh / 2 - ph / 2, pw, ph,
         GL_RGBA, GL_UNSIGNED_BYTE, buf);
   if (glGetError() == GL_NO_ERROR)
   {
      for (i = 0; i < pw * ph; i++)
      {
         const unsigned char *p = buf + (size_t)i * 4;
         unsigned v = p[0];
         if (p[1] > v) v = p[1];
         if (p[2] > v) v = p[2];
         if (v > 8)
            nb++;
      }
   }
   free(buf);
   gl2_bind_fb((GLuint)prev);
   return nb;
}

/* 24-bit BMP, bottom-up — which is also glReadPixels' row order, so the rows go
 * out in the order they came in. `step` point-samples the image down. */
static void ra_vision_write_bmp(const char *path,
      const unsigned char *rgba, unsigned w, unsigned h, unsigned step)
{
   FILE          *f;
   unsigned char *line;
   unsigned char  hdr[54];
   unsigned       x, y;
   unsigned       ow     = w / step;
   unsigned       oh     = h / step;
   unsigned       row    = ow * 3;
   unsigned       pad    = (4 - (row & 3)) & 3;
   unsigned       stride = row + pad;
   unsigned       size   = 54 + stride * oh;

   if (!ow || !oh)
      return;
   if (!(f = fopen(path, "wb")))
      return;

   memset(hdr, 0, sizeof(hdr));
   hdr[0]  = 'B';  hdr[1] = 'M';
   hdr[2]  =  size        & 0xff; hdr[3]  = (size  >>  8) & 0xff;
   hdr[4]  = (size >> 16) & 0xff; hdr[5]  = (size  >> 24) & 0xff;
   hdr[10] = 54;    /* pixel data offset */
   hdr[14] = 40;    /* BITMAPINFOHEADER  */
   hdr[18] =  ow        & 0xff; hdr[19] = (ow >>  8) & 0xff;
   hdr[20] = (ow >> 16) & 0xff; hdr[21] = (ow >> 24) & 0xff;
   hdr[22] =  oh        & 0xff; hdr[23] = (oh >>  8) & 0xff;
   hdr[24] = (oh >> 16) & 0xff; hdr[25] = (oh >> 24) & 0xff;
   hdr[26] = 1;     /* planes */
   hdr[28] = 24;    /* bpp    */
   fwrite(hdr, 1, sizeof(hdr), f);

   if (!(line = (unsigned char*)calloc(1, stride)))
   {
      fclose(f);
      return;
   }
   for (y = 0; y < oh; y++)
   {
      const unsigned char *src = rgba + (size_t)(y * step) * w * 4;
      for (x = 0; x < ow; x++)
      {
         const unsigned char *p = src + (size_t)(x * step) * 4;
         line[x * 3 + 0] = p[2];   /* BMP is BGR */
         line[x * 3 + 1] = p[1];
         line[x * 3 + 2] = p[0];
      }
      fwrite(line, 1, stride, f);
   }
   free(line);
   fclose(f);
}

static void ra_vision_capture_pair(gl2_t *gl, unsigned idx,
      unsigned frame_width, unsigned frame_height, unsigned probe_nb,
      uint64_t frame_count)
{
   const char       *home  = getenv("HOME");
   unsigned char    *buf;
   GLint             prev_fbo = 0;
   GLenum            err_core = 0, err_present = 0;
   ra_vision_stats_t sc, sp;
   char              dir[512], path[640], msg[1024];
   unsigned          dw     = gl->vp.full_width;
   unsigned          dh     = gl->vp.full_height;
   unsigned          cw     = frame_width;
   unsigned          ch     = frame_height;
   unsigned          step_c = 1, step_d = 1;
   int               have_core = 0;

   memset(&sc, 0, sizeof(sc));
   memset(&sp, 0, sizeof(sp));

   if (!home || !dw || !dh)
      return;

   snprintf(dir, sizeof(dir), "%s/Documents/RetroArch/screenshots", home);
   mkdir(dir, 0755);   /* harmless if it already exists */

   if (cw > 960) step_c = (cw + 959) / 960;
   if (dw > 960) step_d = (dw + 959) / 960;

   glGetIntegerv(GL_FRAMEBUFFER_BINDING, &prev_fbo);
   glPixelStorei(GL_PACK_ALIGNMENT, 1);

   /* ---- stage 1: what the CORE produced ---------------------------------
    * hw_render_fbo[tex_index] is the FBO gl2_get_current_framebuffer() handed
    * out for the frame just run (with hw render gl->textures == 1, so the
    * index cannot drift), i.e. exactly the pixels GLideN64 wrote.  No
    * glReadBuffer call: it is not declared in RetroArch's GLES build, and an
    * FBO's read buffer defaults to COLOR_ATTACHMENT0 — glGetError() is
    * reported so a failed read cannot be mistaken for a black frame. */
   if (     (gl->flags & GL2_FLAG_HW_RENDER_FBO_INIT)
         && cw && ch
         && (buf = (unsigned char*)malloc((size_t)cw * ch * 4)))
   {
      gl2_bind_fb(gl->hw_render_fbo[gl->tex_index]);
      while (glGetError() != GL_NO_ERROR);
      glReadPixels(0, 0, cw, ch, GL_RGBA, GL_UNSIGNED_BYTE, buf);
      err_core = glGetError();
      ra_vision_scan(buf, cw, ch, &sc);
      snprintf(path, sizeof(path), "%s/cap%02u-1core-%ux%u.bmp", dir, idx, cw, ch);
      ra_vision_write_bmp(path, buf, cw, ch, step_c);
      free(buf);
      have_core = 1;
   }

   /* ---- stage 2: what RetroArch PRESENTS ---------------------------------
    * The default framebuffer with the whole composed frame in it, one call
    * before the context driver swaps. */
   gl2_bind_fb(0);
   if ((buf = (unsigned char*)malloc((size_t)dw * dh * 4)))
   {
      while (glGetError() != GL_NO_ERROR);
      glReadPixels(0, 0, dw, dh, GL_RGBA, GL_UNSIGNED_BYTE, buf);
      err_present = glGetError();
      ra_vision_scan(buf, dw, dh, &sp);
      snprintf(path, sizeof(path), "%s/cap%02u-2present-%ux%u.bmp", dir, idx, dw, dh);
      ra_vision_write_bmp(path, buf, dw, dh, step_d);
      free(buf);
   }
   gl2_bind_fb((GLuint)prev_fbo);

   {
      extern void RA_BeaconMark(const char *);
      snprintf(msg, sizeof(msg),
            "gl2 dump %u: fc=%llu probe=%u pre0=%u/%u | "
            "core=%ux%u(%s /%u err=0x%x tex=%ux%u) nb=%u max=%u bbox=%u,%u-%u,%u | "
            "present=%ux%u(/%u err=0x%x) nb=%u max=%u bbox=%u,%u-%u,%u | "
            "vp=%u,%u %ux%u -> %s",
            idx, (unsigned long long)frame_count, probe_nb,
            ra_vision_pre_nb, ra_vision_pre_tot,
            cw, ch, have_core ? "ok" : "SKIP", step_c,
            (unsigned)err_core, gl->tex_w, gl->tex_h,
            sc.nb, sc.maxv, sc.x0, sc.y0, sc.x1, sc.y1,
            dw, dh, step_d, (unsigned)err_present,
            sp.nb, sp.maxv, sp.x0, sp.y0, sp.x1, sp.y1,
            gl->vp.x, gl->vp.y, gl->vp.width, gl->vp.height, dir);
      RA_BeaconMark(msg);
   }
}
#endif

"""

# ------------------------------------------------- hunk 2: pre-composite probe
ANCHOR2 = """   gl->shader->use(gl, gl->shader_data, 1, true);
"""

ADDITION2 = """
#if defined(RA_VISIONOS) && defined(RA_VISION_PIXEL_DUMP)
   /* 0044b: probe the DEFAULT framebuffer BEFORE RetroArch clears and composes.
    *
    * If the core ever blitted its picture straight into the window surface
    * behind RetroArch's back, this is where it would show up as a non-black
    * centre. (Source says it cannot: glsm rewrites framebuffer 0 to
    * RetroArch's hardware-render FBO, and GLideN64's default framebuffer
    * handle is 0.) Twice a second, ~0.5 MB per read. */
   if (frame_count >= 240 && (frame_count % 30) == 0
         && gl->vp.full_width && gl->vp.full_height)
   {
      ra_vision_pre_tot = (gl->vp.full_width / 8) * (gl->vp.full_height / 8);
      ra_vision_pre_nb  = ra_vision_probe(0,
            gl->vp.full_width, gl->vp.full_height);
   }
#endif
"""

# ---------------------------------------------------------------- hunk 3: trigger
ANCHOR3 = """   if (gl->ctx_driver->update_window_title)
      gl->ctx_driver->update_window_title(gl->ctx_data);
"""

ADDITION3 = """
#if defined(RA_VISIONOS) && defined(RA_VISION_PIXEL_DUMP)
   /* 0044c: content-gated capture, up to four per content session.
    *
    * Revision 1 fired once, blind, at frame 300 — and landed inside one of
    * SM64's several second-long black boot fades (mac harness,
    * frames 60/120/360/420 are 100%
    * black). Both stages came back black and the round learned nothing.
    *
    * Now: from frame 240, every 30th non-menu frame probes the core's own FBO
    * cheaply; a full capture is taken only when there is actually a picture in
    * it. Frame 1800 forces a capture regardless — a core FBO still black after
    * 30 s is itself the answer and must be recorded. `frame_count` restarts at
    * 0 on every content load, so "it went backwards" re-arms the whole set. */
   {
      static uint64_t last_fc  = 0;
      static uint64_t next_try = 240;
      static unsigned shots    = 0;
      bool            menu_up  = false;
#ifdef HAVE_MENU
      menu_up = menu_is_alive;
#endif
      if (frame_count < last_fc)
      {
         shots    = 0;
         next_try = 240;
      }
      last_fc = frame_count;

      if (shots < 4 && frame && !menu_up && frame_count >= next_try)
      {
         unsigned probe_nb = 0;
         if (gl->flags & GL2_FLAG_HW_RENDER_FBO_INIT)
            probe_nb = ra_vision_probe(gl->hw_render_fbo[gl->tex_index],
                  frame_width, frame_height);
         if (probe_nb > 64 || frame_count >= 1800)
         {
            ra_vision_capture_pair(gl, ++shots, frame_width, frame_height,
                  probe_nb, frame_count);
            next_try = frame_count + 900;
         }
         else
            next_try = frame_count + 30;
      }
   }
#endif
"""

text = SRC.read_text()
HUNKS = (("hunk 1", ANCHOR1, ADDITION1),
         ("hunk 2", ANCHOR2, ADDITION2),
         ("hunk 3", ANCHOR3, ADDITION3))
for name, anchor, _ in HUNKS:
    n = text.count(anchor)
    if n != 1:
        sys.exit(f"{name} anchor matched {n} times in {SRC} (want 1)")
if "0044:" in text:
    sys.exit("0044 already applied to vendor — reverse it out before regenerating")

TRAIL = 2   # trailing context lines


def hunk(anchor, addition, before):
    """Build one unified-diff hunk (insertion AFTER the anchor when before=False).

    TRAP (cost a round an hour): macOS `patch` is Apple patch 2.0-12u11, and it
    REJECTS a mid-file hunk whose added lines are not followed by at least one
    context line — a minimal, byte-correct two-context-line hunk fails, and the
    same hunk with one trailing context line applies. (gen-patch-0039.py has the
    same `body.append(" ")` for the same reason.) So every hunk here carries
    real trailing context taken from the source.
    """
    start = text.index(anchor)
    line_no = text[: start].count("\n") + 1
    anchor_lines = anchor.rstrip("\n").split("\n")
    add_lines = addition.strip("\n").split("\n")
    rest = text[start + len(anchor) :].split("\n")[:TRAIL]
    plus = ["+" + l if l else "+" for l in add_lines]
    ctx = [" " + l for l in anchor_lines]
    trail = [" " + l if l else " " for l in rest]
    body = (plus + ctx + trail) if before else (ctx + plus + trail)
    old_count = len(anchor_lines) + len(trail)
    new_count = old_count + len(add_lines)
    return line_no, old_count, new_count, body


parts = [
    "diff --git a/gfx/drivers/gl2.c b/gfx/drivers/gl2.c\n",
    "--- a/gfx/drivers/gl2.c\n",
    "+++ b/gfx/drivers/gl2.c\n",
]
offset = 0
for _, anchor, addition in HUNKS:
    line_no, old_count, new_count, body = hunk(anchor, addition, before=False)
    parts.append(f"@@ -{line_no},{old_count} +{line_no + offset},{new_count} @@\n")
    parts.append("\n".join(body) + "\n")
    offset += new_count - old_count

OUT.write_text("".join(parts))
print(f"wrote {OUT}")

subprocess.run(
    ["patch", "-p1", "--dry-run", "-d", str(ROOT / "vendor/RetroArch"), "-i", str(OUT)],
    check=True,
)
print("dry-run OK")
