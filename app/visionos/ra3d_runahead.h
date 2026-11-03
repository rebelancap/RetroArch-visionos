/* ra3d_runahead.h — the visible-frame latch for 3dSen-style 3D under run-ahead
 * Included ONCE, by RAVisionLayers.m, after ra3d_shape.h.
 *
 * The problem.  RetroArch's single-instance run-ahead (runahead.c,
 * runahead_run) runs the core N+1 times per host frame: the real frame and
 * N-1 more with video and audio suspended, a savestate after the first, then
 * one VISIBLE frame, then a state reload.  Our 3D mode does not consume the
 * libretro video frame; it reads the Mesen RA3D planes and scene stream
 * (overlays 0057/0059/0060/0065) from the immersive render thread, whenever
 * that thread gets round to it.  The core publishes on EVERY emulated frame,
 * hidden ones included, so an unlatched reader can pick up the hidden frame
 * (one frame behind the visible one) and the scene would flicker between the
 * two.  Worse, with two publishes per host frame the core's double buffer
 * recycles the slot a reader holds within the same host frame, not the next.
 *
 * The fix, entirely in the shell.  RAVisionHost.m wraps
 * runloop_state->current_core.retro_run while 3D + `runahead` are on.  After
 * every call the wrapper reports whether it was a hidden run (RetroArch clears
 * VIDEO_FLAG_ACTIVE for those, runahead.c) and this file, on the MAIN thread:
 *   - hidden run:  only counts how far the core's publish counter moved;
 *   - visible run: COPIES the four planes, the scene (tiles, CHR atlas,
 *     palette RAM) and the 2 KB system RAM Script:ReadMem reads into the back
 *     slot of a lock-free triple buffer, and publishes it.
 * The visible run is the last retro_run of runahead_run, and the copy happens
 * before runahead_load_state rewinds the core — so the latched RAM is the
 * AHEAD state, as 3dSen's Lua ReadMem sees it.
 * The render thread then reads only the latch.  The scene's FrameNumber is
 * rewritten to a LOGICAL counter (the core's publish counter minus every
 * publish a hidden run made), so it advances exactly 1 per host frame — what
 * the shape tracker's frame-to-frame identity (ra3d_shape.h), the "reuse last
 * build" check and the Lua `frame`/`time` globals all assume.  A state reload
 * is invisible to them: they never see the frame it rewinds to.
 *
 * Off (`runahead = 0`, the default) nothing here is reachable: the wrapper is
 * not installed and ra_latch_active() is false, so the fetch paths are .46's.
 */
#ifndef RA3D_RUNAHEAD_H
#define RA3D_RUNAHEAD_H

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef int   (*ra_latch_planes_fn)(const uint32_t **planes, unsigned *w, unsigned *h,
                                    uint32_t *frame, float *display_aspect);
typedef int   (*ra_latch_scene_fn)(Ra3dScene *out);
typedef void *(*ra_latch_mem_fn)(unsigned id);

typedef struct
{
   uint32_t       gen;                 /* latch generation it was written under */
   int            valid;               /* planes present                        */
   int            n;
   unsigned       w, h;
   float          dar;
   uint32_t       frame;               /* LOGICAL frame number                  */
   uint32_t       raw;                 /* the core's publish counter            */
   uint32_t      *px;   size_t px_cap; /* n * w * h ARGB                        */
   int            scene_ok;
   Ra3dScene      sc;                  /* pointers into the arrays below        */
   Ra3dSceneTile *tiles; size_t tiles_cap;
   uint8_t       *atlas; size_t atlas_cap;
   uint8_t        pal[0x20];
   uint32_t       rgb[512];            /* the core's NES palette, copied: the
                                          core's own may be dlclose'd under us */
   uint8_t        ram[2048];
   int            ram_ok;
} ra_latch_slot;

static ra_latch_slot   s_lt[3];
/* Triple buffer: the writer owns s_lt_back, the reader s_lt_front, and the
 * third index sits in s_lt_mid with bit 2 set when it holds a newer frame
 * than the reader has taken. */
static _Atomic int      s_lt_mid   = 1;
static int              s_lt_back  = 0;   /* main thread */
static int              s_lt_front = 2;   /* render thread */
static _Atomic uint32_t s_lt_gen   = 0;
static _Atomic int      s_lt_on    = 0;

/* writer state (main thread only) */
static ra_latch_planes_fn s_lt_planes_fn = NULL;
static ra_latch_scene_fn  s_lt_scene_fn  = NULL;
static ra_latch_mem_fn    s_lt_mem_fn    = NULL;
static int      s_lt_frames      = 0;     /* configured run-ahead frames    */
static int      s_lt_have_raw    = 0;
static uint32_t s_lt_raw_last    = 0;
static uint32_t s_lt_hidden_adv  = 0;     /* publishes made by hidden runs  */
static uint32_t s_lt_logical_last = 0;
static int      s_lt_have_logical = 0;
static unsigned s_lt_hidden_since = 0;    /* hidden runs since last visible */
static double   s_lt_hidden_ms_since = 0.0;
/* writer stats, reported every RA_LATCH_REPORT visible runs */
#define RA_LATCH_REPORT 600
static unsigned s_lt_vis_n, s_lt_fresh_n, s_lt_stale_n, s_lt_first_logged;
static unsigned s_lt_hid_hist[4];         /* hidden runs per host frame 0,1,2,3+ */
static unsigned s_lt_dlog_hist[4];        /* logical delta 0,1,2,3+          */
static unsigned s_lt_hadv_hist[3];        /* publishes per hidden run 0,1,2+ */
static double   s_lt_ms_vis, s_lt_ms_hid, s_lt_ms_copy, s_lt_ms_peak;
static double   s_lt_ms_save, s_lt_ms_load;   /* runahead.c's state save / reload */
static unsigned s_lt_reports;
/* reader stats (render thread only) */
static uint32_t s_lt_rd_last = 0;
static uint32_t s_lt_rd_gen  = 0;
static int      s_lt_rd_have = 0;
static unsigned s_lt_rd_n, s_lt_rd_hist[4], s_lt_rd_back, s_lt_rd_reports;

static void ra_latch_beaconf(const char *fmt, ...)
{
   char buf[512];
   va_list ap;
   va_start(ap, fmt);
   vsnprintf(buf, sizeof(buf), fmt, ap);
   va_end(ap);
   RA_BeaconMark(buf);
   NSLog(@"[RA3D] %s", buf);
}

static bool ra_latch_active(void)
{
   return atomic_load_explicit(&s_lt_on, memory_order_acquire) != 0;
}

static double ra_latch_now_ms(void)
{
   struct timespec ts;
   clock_gettime(CLOCK_MONOTONIC, &ts);
   return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1.0e6;
}

static void ra_latch_reset_counters(void)
{
   s_lt_have_raw = 0; s_lt_raw_last = 0; s_lt_hidden_adv = 0;
   s_lt_have_logical = 0; s_lt_logical_last = 0;
   s_lt_hidden_since = 0; s_lt_hidden_ms_since = 0.0;
   s_lt_vis_n = s_lt_fresh_n = s_lt_stale_n = 0;
   memset(s_lt_hid_hist, 0, sizeof(s_lt_hid_hist));
   memset(s_lt_dlog_hist, 0, sizeof(s_lt_dlog_hist));
   memset(s_lt_hadv_hist, 0, sizeof(s_lt_hadv_hist));
   s_lt_ms_vis = s_lt_ms_hid = s_lt_ms_copy = s_lt_ms_peak = 0.0;
   s_lt_ms_save = s_lt_ms_load = 0.0;
}

/* Main thread, from the retro_unload_game wrapper: the core is about to go
 * away. Bump the generation so the render thread serves nothing until the
 * supervisor re-wraps the next core, and drop the symbols so a stray
 * after_run cannot call into it. */
void ra_vision_latch_invalidate(void)
{
   if (!ra_latch_active()) return;
   atomic_fetch_add_explicit(&s_lt_gen, 1u, memory_order_acq_rel);
   s_lt_planes_fn = NULL;
   s_lt_scene_fn  = NULL;
   s_lt_mem_fn    = NULL;
}

/* Main thread: a timed retro_serialize (load = 0) / retro_unserialize (1). */
void ra_vision_latch_note_state(int load, double ms)
{
   if (!ra_latch_active()) return;
   if (load) s_lt_ms_load += ms; else s_lt_ms_save += ms;
}

/* Main thread.  on = 1 with the CURRENT core's symbols (RAVisionHost.m
 * resolves them from RetroArch's own lib_handle at every (re)install); on = 0
 * when run-ahead is restored.  Every call bumps the generation, so a slot
 * written for the previous core or session is never read. */
void ra_vision_latch_set(int on, void *planes_fn, void *scene_fn, void *mem_fn, int frames)
{
   atomic_fetch_add_explicit(&s_lt_gen, 1u, memory_order_acq_rel);
   s_lt_planes_fn = on ? (ra_latch_planes_fn)planes_fn : NULL;
   s_lt_scene_fn  = on ? (ra_latch_scene_fn)scene_fn   : NULL;
   s_lt_mem_fn    = on ? (ra_latch_mem_fn)mem_fn       : NULL;
   s_lt_frames    = frames;
   s_lt_first_logged = 0;
   ra_latch_reset_counters();
   atomic_store_explicit(&s_lt_on, on ? 1 : 0, memory_order_release);
}

static bool ra_latch_grow(void **p, size_t *cap, size_t need)
{
   void *np;
   if (*cap >= need) return true;
   np = realloc(*p, need);
   if (!np) return false;
   *p = np; *cap = need;
   return true;
}

static void ra_latch_report(void)
{
   unsigned n = s_lt_vis_n ? s_lt_vis_n : 1;
   s_lt_reports++;
   ra_latch_beaconf("runahead: %u host frames — hidden runs/frame {0:%u 1:%u 2:%u 3+:%u}, "
                    "core publishes/hidden run {0:%u 1:%u 2+:%u}, latched frame delta "
                    "{0:%u 1:%u 2:%u 3+:%u}, scene from the visible run %u/%u (stale %u); "
                    "core ms/host frame avg %.2f (hidden %.2f + visible %.2f) peak %.2f, "
                    "state save %.3f + reload %.3f ms, latch copy %.3f ms",
                    s_lt_vis_n, s_lt_hid_hist[0], s_lt_hid_hist[1], s_lt_hid_hist[2],
                    s_lt_hid_hist[3], s_lt_hadv_hist[0], s_lt_hadv_hist[1], s_lt_hadv_hist[2],
                    s_lt_dlog_hist[0], s_lt_dlog_hist[1], s_lt_dlog_hist[2], s_lt_dlog_hist[3],
                    s_lt_fresh_n, s_lt_vis_n, s_lt_stale_n,
                    (s_lt_ms_hid + s_lt_ms_vis) / n, s_lt_ms_hid / n, s_lt_ms_vis / n,
                    s_lt_ms_peak, s_lt_ms_save / n, s_lt_ms_load / n, s_lt_ms_copy / n);
   s_lt_vis_n = s_lt_fresh_n = s_lt_stale_n = 0;
   memset(s_lt_hid_hist, 0, sizeof(s_lt_hid_hist));
   memset(s_lt_dlog_hist, 0, sizeof(s_lt_dlog_hist));
   memset(s_lt_hadv_hist, 0, sizeof(s_lt_hadv_hist));
   s_lt_ms_vis = s_lt_ms_hid = s_lt_ms_copy = s_lt_ms_peak = 0.0;
   s_lt_ms_save = s_lt_ms_load = 0.0;
}

/* Main thread, right after each wrapped retro_run.  `hidden` = RetroArch ran
 * it with video suspended (a run-ahead frame nobody sees). */
void ra_vision_latch_after_run(int hidden, double run_ms)
{
   const uint32_t *p[RA_VISION_MAX_PLANES] = {0};
   unsigned w = 0, h = 0;
   uint32_t raw = 0;
   float    dar = 0.0f;
   int      n, i;
   double   t0;
   ra_latch_slot *s;

   if (!ra_latch_active() || !s_lt_planes_fn)
      return;
   n = s_lt_planes_fn(p, &w, &h, &raw, &dar);

   if (hidden)
   {
      if (n > 0 && s_lt_have_raw)
      {
         uint32_t adv = raw - s_lt_raw_last;
         s_lt_hidden_adv += adv;
         s_lt_hadv_hist[adv > 2 ? 2 : adv]++;
      }
      if (n > 0) { s_lt_raw_last = raw; s_lt_have_raw = 1; }
      s_lt_hidden_since++;
      s_lt_hidden_ms_since += run_ms;
      return;
   }

   /* the visible run: this is the frame the user sees and hears */
   s_lt_hid_hist[s_lt_hidden_since > 3 ? 3 : s_lt_hidden_since]++;
   s_lt_ms_hid += s_lt_hidden_ms_since;
   s_lt_ms_vis += run_ms;
   if (s_lt_hidden_ms_since + run_ms > s_lt_ms_peak)
      s_lt_ms_peak = s_lt_hidden_ms_since + run_ms;
   s_lt_hidden_since = 0;
   s_lt_hidden_ms_since = 0.0;
   s_lt_vis_n++;

   if (n <= 0 || w == 0 || h == 0)
   {
      s_lt_have_raw = 0;
      if (s_lt_vis_n >= RA_LATCH_REPORT) ra_latch_report();
      return;
   }
   if (n > RA_VISION_MAX_PLANES) n = RA_VISION_MAX_PLANES;
   /* logical = raw until the first hidden publish, so the Lua `frame` /
    * `time` globals carry on from where .46's raw counter had them */
   s_lt_raw_last = raw;
   s_lt_have_raw = 1;

   t0 = ra_latch_now_ms();
   s = &s_lt[s_lt_back];
   s->gen   = atomic_load_explicit(&s_lt_gen, memory_order_acquire);
   s->valid = 0;
   s->scene_ok = 0;
   s->ram_ok = 0;
   if (!ra_latch_grow((void **)&s->px, &s->px_cap, (size_t)n * w * h * 4))
      return;
   for (i = 0; i < n; i++)
   {
      if (!p[i]) return;
      memcpy(s->px + (size_t)i * w * h, p[i], (size_t)w * h * 4);
   }
   s->n = n; s->w = w; s->h = h; s->dar = dar;
   s->raw   = raw;
   s->frame = raw - s_lt_hidden_adv;
   s->valid = 1;

   if (s_lt_have_logical)
   {
      uint32_t d = s->frame - s_lt_logical_last;
      s_lt_dlog_hist[d > 3 ? 3 : d]++;
   }
   s_lt_logical_last = s->frame;
   s_lt_have_logical = 1;

   if (s_lt_scene_fn)
   {
      Ra3dScene sc;
      memset(&sc, 0, sizeof(sc));
      if (s_lt_scene_fn(&sc) && sc.Tiles && sc.Atlas && sc.TileCount && sc.AtlasCount)
      {
         if (sc.FrameNumber == raw)   /* published by THIS run, not earlier */
         {
            if (ra_latch_grow((void **)&s->tiles, &s->tiles_cap,
                              (size_t)sc.TileCount * sizeof(Ra3dSceneTile))
                && ra_latch_grow((void **)&s->atlas, &s->atlas_cap,
                                 (size_t)sc.AtlasCount * 16))
            {
               memcpy(s->tiles, sc.Tiles, (size_t)sc.TileCount * sizeof(Ra3dSceneTile));
               memcpy(s->atlas, sc.Atlas, (size_t)sc.AtlasCount * 16);
               if (sc.PaletteRam) memcpy(s->pal, sc.PaletteRam, sizeof(s->pal));
               else               memset(s->pal, 0, sizeof(s->pal));
               s->sc             = sc;
               s->sc.FrameNumber = s->frame;
               s->sc.Tiles       = s->tiles;
               s->sc.Atlas       = s->atlas;
               s->sc.PaletteRam  = s->pal;
               if (sc.RgbPalette)
               {
                  memcpy(s->rgb, sc.RgbPalette, sizeof(s->rgb));
                  s->sc.RgbPalette = s->rgb;
               }
               s->scene_ok       = 1;
               s_lt_fresh_n++;
            }
         }
         else
            s_lt_stale_n++;
      }
   }
   if (s_lt_mem_fn)
   {
      const uint8_t *ram = (const uint8_t *)s_lt_mem_fn(2 /* RETRO_MEMORY_SYSTEM_RAM */);
      if (ram) { memcpy(s->ram, ram, sizeof(s->ram)); s->ram_ok = 1; }
   }
   s_lt_back = atomic_exchange_explicit(&s_lt_mid, s_lt_back | 4, memory_order_acq_rel) & 3;
   s_lt_ms_copy += ra_latch_now_ms() - t0;

   if (!s_lt_first_logged && s->scene_ok)
   {
      s_lt_first_logged = 1;
      ra_latch_beaconf("runahead: %d frame%s, single instance, scene sampled after the "
                       "visible run (frame %u, core publish %u, %u hidden publishes excluded)",
                       s_lt_frames, s_lt_frames == 1 ? "" : "s", s->frame, raw,
                       s_lt_hidden_adv);
   }
   if (s_lt_vis_n >= RA_LATCH_REPORT) ra_latch_report();
}

/* Render thread: take the newest complete slot, if there is one. */
static ra_latch_slot *ra_latch_front(void)
{
   ra_latch_slot *s;
   if (atomic_load_explicit(&s_lt_mid, memory_order_acquire) & 4)
      s_lt_front = atomic_exchange_explicit(&s_lt_mid, s_lt_front, memory_order_acq_rel) & 3;
   s = &s_lt[s_lt_front];
   if (s->gen != atomic_load_explicit(&s_lt_gen, memory_order_acquire) || !s->valid)
      return NULL;
   return s;
}

/* Render thread: the planes, from the latch.  Takes a new slot (once per
 * render frame — ra_latch_scene reuses it, so planes and scene always come
 * from the same visible run). */
static bool ra_latch_planes(ra_vision_planes_t *out)
{
   ra_latch_slot *s = ra_latch_front();
   int i;
   if (!s)
      return false;
   for (i = 0; i < s->n; i++)
      out->plane[i] = s->px + (size_t)i * s->w * s->h;
   out->count  = s->n;
   out->width  = s->w;
   out->height = s->h;
   out->frame  = s->frame;
   out->display_aspect = s->dar;
   return true;
}

/* Render thread: the scene + RAM of the slot ra_latch_planes took. */
static bool ra_latch_scene(Ra3dScene *out, const uint8_t **ram)
{
   ra_latch_slot *s = &s_lt[s_lt_front];
   *ram = NULL;
   if (s->gen != atomic_load_explicit(&s_lt_gen, memory_order_acquire)
       || !s->valid || !s->scene_ok)
      return false;
   *out = s->sc;
   if (s->ram_ok) *ram = s->ram;
   return true;
}

/* Render thread: what the consumer actually built, for the alignment proof.
 * The render loop runs at its own rate (90 Hz on device, ~30/60 in the sim),
 * so a delta of 2+ here is a frame the loop slept through, never a hidden
 * one — the writer's histogram is the per-host-frame proof. Backwards = a
 * reload leaking through (must stay 0). */
static void ra_latch_note_consumed(uint32_t frame)
{
   uint32_t g = s_lt[s_lt_front].gen;
   if (g != s_lt_rd_gen) { s_lt_rd_gen = g; s_lt_rd_have = 0; }   /* new core / session */
   if (s_lt_rd_have)
   {
      uint32_t d = frame - s_lt_rd_last;
      if ((int32_t)d < 0) s_lt_rd_back++;
      else s_lt_rd_hist[d > 3 ? 3 : d]++;
   }
   s_lt_rd_last = frame;
   s_lt_rd_have = 1;
   if (++s_lt_rd_n >= RA_LATCH_REPORT)
   {
      s_lt_rd_reports++;
      ra_latch_beaconf("runahead: consumer built %u scenes — frame delta {0:%u 1:%u 2:%u 3+:%u}, "
                       "backwards %u", s_lt_rd_n, s_lt_rd_hist[0], s_lt_rd_hist[1],
                       s_lt_rd_hist[2], s_lt_rd_hist[3], s_lt_rd_back);
      s_lt_rd_n = 0; s_lt_rd_back = 0;
      memset(s_lt_rd_hist, 0, sizeof(s_lt_rd_hist));
   }
}

#endif /* RA3D_RUNAHEAD_H */
