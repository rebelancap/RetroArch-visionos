/* RAVisionLayers.m — pulls the core's depth planes across into the shell.
 *
 * The Mesen core exports `mesen_ra3d_get_planes`, which hands back the current
 * frame decomposed into background / sprites-front / sprites-behind.  We reach
 * it with dlsym rather than through libretro, which means:
 *   - RetroArch's video path is completely untouched, so 2D output is bit-for
 *     bit what it always was;
 *   - a core WITHOUT the symbol (snes9x, MAME, bsnes, mupen) simply reports no
 *     layers and the shell falls back to the flat composite.  No core needs to
 *     know this feature exists.
 *
 * Resolution is re-tried whenever the symbol is missing, because cores are
 * dlopen'd and swapped at runtime — the user can close NES content, load a
 * SNES game, and come back.
 */

#import "RAVision.h"

#if defined(RA_VISION_3D)

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <string.h>
#include <stdarg.h>

typedef int (*ra_planes_fn)(const uint32_t **planes, unsigned *w, unsigned *h,
                            uint32_t *frame, float *display_aspect);

static ra_planes_fn s_fn        = NULL;
static bool         s_looked    = false;
static uint32_t     s_lastFrame = 0xFFFFFFFFu;

/* Cores this shell knows how to take layers from.  Listed by symbol rather than
 * by core name so adding SNES later is one entry, not a new mechanism. */
static const char *kLayerSymbols[] = {
   "mesen_ra3d_get_planes",    /* NES  — 3 planes: behind / background / front */
   "snes9x_ra3d_get_planes",   /* SNES — 2 planes: background / sprites        */
   NULL
};

/* Is `name` still in the process's image list? Cores are dlopen'd and dlclose'd
 * at run time, so any cached function pointer must be re-validated against the
 * image it came from before it is called — calling through a stale one is a
 * jump into unmapped memory. */
static bool ra_image_loaded(const char *name, const void *header)
{
   uint32_t img, count;
   if (!name || !*name)
      return false;
   count = _dyld_image_count();
   for (img = 0; img < count; img++)
   {
      const char *n = _dyld_get_image_name(img);
      if (!n || strcmp(n, name))
         continue;
      /* The NAME is not enough. Closing content and loading another game
       * unloads the core and dlopen's the SAME path again, and nothing says
       * the second mapping lands at the first one's address — a pointer into
       * the old one is a jump into freed VM. Until that could not
       * happen, because our own leaked dlopen reference kept the first mapping
       * alive forever; now that we give the reference back, the header has to
       * be checked too. */
      return !header || (const void *)_dyld_get_image_header(img) == header;
   }
   return false;
}

/* Open an ALREADY-LOADED image just to read symbols out of it.
 *
 * and the whole reason died when a second game was loaded
 * after using 3D: on Darwin dlopen() defaults to **RTLD_GLOBAL** when neither
 * GLOBAL nor LOCAL is given, and RTLD_NOLOAD still takes a reference. So the
 * old `dlopen(name, RTLD_NOLOAD | RTLD_LAZY)` did two damaging things to a
 * core RetroArch owns:
 *   1. it promoted the core into the GLOBAL namespace, after which
 *      dlsym(RTLD_DEFAULT, "retro_init") resolves — and that is exactly the
 *      probe load_dynamic_core() uses to detect a statically linked core. The
 *      next content load hit "RetroArch wants to load libretro cores
 *      dynamically, but it is already linked. Aborting", failed the load, and
 *      left the drivers uninitialised.
 *   2. it leaked a reference every call, so RetroArch's own dlclose() never
 *      actually unmapped the old core.
 * RTLD_LOCAL keeps the namespace clean; dlclose() gives the reference straight
 * back. The image stays mapped for as long as RetroArch's own handle lives,
 * which is exactly the lifetime our cached pointers are validated against. */
static void *ra_peek_image(const char *name)
{
   return dlopen(name, RTLD_NOLOAD | RTLD_LAZY | RTLD_LOCAL);
}

/* The image ra_resolve()'s pointer came out of. */
static char        s_fn_image[1024] = {0};
static const void *s_fn_header = NULL;

static void ra_resolve(void)
{
   int i;
   uint32_t img, count;

   /* A cached pointer into a core that has been unloaded is a crash, not a
    * miss. Now that we no longer pin the image open, check it. */
   if (s_fn && s_fn_image[0] && !ra_image_loaded(s_fn_image, s_fn_header))
   {
      s_fn          = NULL;
      s_fn_image[0] = 0;
      s_fn_header   = NULL;
      s_looked      = false;
   }
   if (s_fn)
      return;

   /* RTLD_DEFAULT is not enough: RetroArch dlopen's cores without RTLD_GLOBAL,
    * so their symbols never enter the global namespace.  Walk the loaded images
    * instead, find the libretro core, and re-open it with RTLD_NOLOAD — that
    * returns a handle to the ALREADY-LOADED image (it does not load a second
    * copy) which we can then dlsym directly. */
   count = _dyld_image_count();
   for (img = 0; img < count; img++)
   {
      const char *name = _dyld_get_image_name(img);
      void       *h;
      if (!name || !strstr(name, "libretro"))
         continue;
      h = ra_peek_image(name);
      if (!h)
         continue;
      for (i = 0; kLayerSymbols[i]; i++)
      {
         void *sym = dlsym(h, kLayerSymbols[i]);
         if (sym)
         {
            s_fn = (ra_planes_fn)sym;
            strncpy(s_fn_image, name, sizeof(s_fn_image) - 1);
            s_fn_image[sizeof(s_fn_image) - 1] = 0;
            s_fn_header = (const void *)_dyld_get_image_header(img);
            NSLog(@"[RA3D] depth planes available: %s in %s", kLayerSymbols[i], name);
            dlclose(h);
            return;
         }
      }
      dlclose(h);
   }
   /* Belt and braces for a core that WAS opened globally. */
   for (i = 0; kLayerSymbols[i]; i++)
   {
      void *sym = dlsym(RTLD_DEFAULT, kLayerSymbols[i]);
      if (sym)
      {
         s_fn = (ra_planes_fn)sym;
         NSLog(@"[RA3D] depth planes available: %s (global)", kLayerSymbols[i]);
         return;
      }
   }
   if (!s_looked)
   {
      NSLog(@"[RA3D] no core layer support in this session — flat screen");
      s_looked = true;
   }
}

bool ra_vision_layers_available(void)
{
   ra_resolve();
   return s_fn != NULL;
}

/* the run-ahead visible-frame latch, ra3d_runahead.h (included
 * below, after the scene types). */
static bool ra_latch_active(void);
static bool ra_latch_planes(ra_vision_planes_t *out);

bool ra_vision_layers_fetch(ra_vision_planes_t *out)
{
   const uint32_t *p[RA_VISION_MAX_PLANES] = {0};
   unsigned w = 0, h = 0;
   uint32_t frame = 0;
   int n;

   if (!out)
      return false;
   memset(out, 0, sizeof(*out));

   ra_resolve();
   if (!s_fn)
      return false;

   float dar = 0.0f;
   n = s_fn(p, &w, &h, &frame, &dar);
   if (n <= 0 || w == 0 || h == 0)
   {
      /* Core is loaded but has no frame yet (content closed, or still booting).
       * Re-resolve next time in case the core was swapped out from under us. */
      s_fn          = NULL;
      s_fn_image[0] = 0;
      s_fn_header   = NULL;
      s_looked      = false;
      return false;
   }
   /* under run-ahead the core is alive (checked just above) but its
    * buffers may hold a hidden run's frame — read the latched visible one. */
   if (ra_latch_active())
      return ra_latch_planes(out);
   if (n > RA_VISION_MAX_PLANES)
      n = RA_VISION_MAX_PLANES;

   for (int i = 0; i < n; i++)
   {
      if (!p[i])
         return false;
      out->plane[i] = p[i];
   }
   out->count  = n;
   out->width  = w;
   out->height = h;
   out->frame  = frame;
   out->display_aspect = dar;
   s_lastFrame = frame;
   return true;
}


/* ==========================================================================
 * 3dSen shape mode — the scene stream
 * ==========================================================================
 *
 * Same dlsym posture as the planes above, three symbols instead of one
 * (overlay 0060). The stream is OFF in the core until we turn it on, and we
 * only turn it on when a `.3dn` profile for the loaded ROM is actually
 * present — so an ordinary NES session pays nothing for this existing, and
 * +4.0 % is charged only to a session that renders geometry.
 *
 * Profiles live where the user puts them:
 *     Documents/RetroArch/system/3dsen/<rom name>.3dn
 * resolved exactly, then case-insensitively, then with region tags stripped —
 * the same three-step ladder overlay 0061 gives HD-pack folders, for the same
 * reason (a name that differs by one bracket is the failure that keeps
 * happening). Every step of the resolution is beaconed, so a miss names itself
 * in Documents/launch-beacon.log instead of looking like a dead feature.
 */

#define RA3D_SHAPE_IMPLEMENTATION
#include "ra3d_shape.h"
#include "ra3d_scene.h"
#include "ra3d_lua.h"      /* declarations; the implementation is at the END */
#define RA3D_MATCH_IMPLEMENTATION
#include "ra3d_match.h"    /* profile <- ROM content */
#include "ra3d_runahead.h" /* run-ahead visible-frame latch */

#include <sys/stat.h>
#include <dirent.h>
#include <ctype.h>

/* RetroArch's own path accessor; $(SRCBASE) is on the header search path. */
#include "paths.h"

typedef void (*ra_scene_enable_fn)(int);
typedef int  (*ra_scene_supported_fn)(void);
typedef int  (*ra_scene_get_fn)(Ra3dScene *out);

static ra_scene_enable_fn    s_scene_enable    = NULL;
static ra_scene_supported_fn s_scene_supported = NULL;
static ra_scene_get_fn       s_scene_get       = NULL;
static bool                  s_scene_looked    = false;
/* The image the three symbols were resolved out of. Cores are dlopen'd and
 * swapped at run time, so a cached function pointer can outlive its image —
 * calling through one is a jump into unmapped memory. Re-checked every poll
 * the planes above already re-resolve for the same reason. */
static char                  s_scene_image[1024] = {0};
static const void           *s_scene_header      = NULL;

static Ra3dProfile  *s_profile     = NULL;
static Ra3dGeoFrame  s_geo         = {0};
static Ra3dKnobs     s_knobs;
static bool          s_knobs_ready = false;
static bool          s_mode_on     = false;
static bool          s_enabled_core = false;
static uint32_t      s_last_frame  = 0xFFFFFFFFu;
static char          s_content[512]  = {0};
/* `plane_mode` is what the 2D depth planes do while shape mode is on:
 *   0 = no planes at all (pure geometry)
 *   1 = the solid NES backdrop-colour plane only, behind everything
 *   2 = all four planes ALONGSIDE the geometry
 * Mode 2 was the right default while the matcher covered 22-97 % of cells and
 * the planes filled the gaps. Since every measured frame is at 100 %
 * coverage, so the sprite and background planes no longer FILL anything — they
 * draw a second, flat copy of Mario and the goombas in front of the extruded
 * ones. The compiled default is
 * therefore 1 while shape mode is on and 2 while it is off.: the
 * `plane_mode` cfg key is legacy and ignored, so the auto rule always holds. */
static int           s_plane_mode  = 2;
static bool          s_plane_mode_set = false;   /* cfg said so explicitly */
/* 1.0 puts one NES pixel of Z at one NES pixel of X — a 24 px floor
 * slab is then 35 cm deep on the shipped 3.78 m panel, which reads as a
 * diorama, not as 3dSenVR's shallow relief (a few cm to ~20 cm on a 2-3 m
 * screen). 0.5 puts the common 8 px extrusion at 6 cm and the deepest shape
 * in the six profiles at 18 cm.: the `depth_scale` cfg key is
 * legacy and ignored; 0.5 is fixed. */
static float         s_depth_scale = 0.5f;
/* profile selection knobs (3dsen.cfg):
 *   profile_match_min    coverage a profile needs to be picked by content
 *   prefer_user_profiles 1 = a user .3dn wins even over the bundled copy of
 *                        the same official profile Id (3dSen: built-in wins)
 *   bundled_profiles     0 = ignore the 101 bundled profiles entirely */
static double        s_match_min   = RA3D_MATCH_MIN_COV;
static int           s_prefer_user = 0;
static int           s_bundled     = 1;

/* atlas expanded to one byte of colour index per pixel, and the 32 palette-RAM
 * entries resolved to RGBA — both rebuilt only when the emulator advances */
static uint8_t  *s_atlas_px  = NULL;
static unsigned  s_atlas_cap = 0, s_atlas_n = 0;
static uint32_t  s_pal[68];         /* 16 groups + the Backdrop's */

/* the profile's Lua VM (ra3d_lua.h, included at the end of this
 * file), the 2 KB RAM snapshot Script:ReadMem reads, and its source. */
static Ra3dLua  *s_lua = NULL;
static uint32_t  s_lua_serial = 0;
static long      s_lua_budget = 0;
static uint8_t   s_ram[2048];
static int       s_ram_ok = 0;
typedef void *(*ra_mem_data_fn)(unsigned id);
static ra_mem_data_fn s_mem_fn = NULL;
static uint32_t  s_lua_frames = 0;
static int       s_lua_first = 0;      /* the first frame of a VM was reported */
static double    s_lua_ms_sum = 0.0;
static Ra3dLua  *ra_scene_lua_new(void);
static void      ra_scene_lua_free(void);
static int       ra_scene_lua_frame(const Ra3dScene *sc);
static void      ra_scene_lua_report(void);

static void ra_scene_beaconf(const char *fmt, ...)
{
   char buf[512];
   va_list ap;
   va_start(ap, fmt);
   vsnprintf(buf, sizeof(buf), fmt, ap);
   va_end(ap);
   RA_BeaconMark(buf);
   NSLog(@"[RA3D] %s", buf);
}

/* Is the image the symbols came from still loaded? Cheap: one pass over the
 * image list, and only when we already hold pointers. Anything else — a core
 * swap, a dlclose — and the pointers are dropped rather than called. */
static bool ra_scene_image_alive(void)
{
   return ra_image_loaded(s_scene_image, s_scene_header);
}

static void ra_scene_forget_syms(void)
{
   s_scene_enable    = NULL;
   s_scene_supported = NULL;
   s_scene_get       = NULL;
   s_scene_image[0]  = 0;
   s_scene_header    = NULL;
   s_scene_looked    = false;
   s_mem_fn          = NULL;
}

static void ra_scene_resolve_syms(void)
{
   uint32_t img, count;
   int i;
   static const char *kSym[3] = { "mesen_ra3d_set_scene_enabled",
                                  "mesen_ra3d_scene_supported",
                                  "mesen_ra3d_get_scene" };
   void *found[3] = {0};

   if (s_scene_get)
      return;
   count = _dyld_image_count();
   for (img = 0; img < count; img++)
   {
      const char *name = _dyld_get_image_name(img);
      void *h;
      if (!name || !strstr(name, "libretro"))
         continue;
      h = ra_peek_image(name);
      if (!h)
         continue;
      for (i = 0; i < 3; i++)
         found[i] = dlsym(h, kSym[i]);
      if (found[0] && found[1] && found[2])   /* Script:ReadMem's RAM */
         s_mem_fn = (ra_mem_data_fn)dlsym(h, "retro_get_memory_data");
      dlclose(h);          /* never hold a reference on RetroArch's core */
      if (found[0] && found[1] && found[2])
      {
         s_scene_enable    = (ra_scene_enable_fn)found[0];
         s_scene_supported = (ra_scene_supported_fn)found[1];
         s_scene_get       = (ra_scene_get_fn)found[2];
         strncpy(s_scene_image, name, sizeof(s_scene_image) - 1);
         s_scene_image[sizeof(s_scene_image) - 1] = 0;
         s_scene_header = (const void *)_dyld_get_image_header(img);
         ra_scene_beaconf("3dsen: scene stream available in %s", name);
         return;
      }
   }
   if (!s_scene_looked)
   {
      ra_scene_beaconf("3dsen: loaded core exports no RA3D scene stream — "
                       "shape mode stays off");
      s_scene_looked = true;
   }
}

/* Overlay 0061's own normaliser, in C: drop anything inside (...) or [...],
 * keep alphanumerics, lower-case. "Super Mario Bros. (World).nes" ->
 * "supermariobros". */
static void ra_scene_normalize(const char *name, char *out, size_t cap)
{
   size_t n = 0;
   int depth = 0;
   for (; *name && n + 1 < cap; name++)
   {
      char c = *name;
      if (c == '(' || c == '[') { depth++; continue; }
      if (c == ')' || c == ']') { if (depth > 0) depth--; continue; }
      if (depth > 0) continue;
      if (isalnum((unsigned char)c)) out[n++] = (char)tolower((unsigned char)c);
   }
   out[n] = 0;
}

static NSString *ra_scene_dir(void)
{
   NSString *docs = [NSSearchPathForDirectoriesInDomains(
                        NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
   return [docs stringByAppendingPathComponent:@"RetroArch/system/3dsen"];
}

/* one beacon line per legacy key an old 3dsen.cfg still carries */
static void ra_scene_legacy_key(const char *key, void *ud)
{
   (void)ud;
   ra_scene_beaconf("3dsen: 3dsen.cfg ignores legacy key %s", key);
}

static void ra_scene_load_knobs(void)
{
   NSString *cfg = [ra_scene_dir() stringByAppendingPathComponent:@"3dsen.cfg"];
   NSData   *d   = [NSData dataWithContentsOfFile:cfg];
   ra3d_knobs_defaults(&s_knobs);
   s_plane_mode     = 2;
   s_plane_mode_set = false;
   s_depth_scale    = 0.5f;
   s_lua_budget     = 0;
   s_match_min      = RA3D_MATCH_MIN_COV;
   s_prefer_user    = 0;
   s_bundled        = 1;
   s_knobs_ready = true;
   if (!d)
   {
      ra_scene_beaconf("3dsen: no 3dsen.cfg — defaults (size_z_scale=1 "
                       "layer_z=UI64/0/-24/-48/-72 fallback_z=8 pattern3d=-1(all) "
                       "planes=auto (1 with shapes, 2 without) depth=0.50 "
                       "flat_shapes=auto)");
      return;
   }
   {
      int unknown = 0;
      const char *txt = (const char *)d.bytes;
      /* shell-side knobs (Lua budget, profile selection) are read here
       * rather than inside ra3d_shape.h */
      char *copy = (char *)malloc(d.length + 1);
      memcpy(copy, txt, d.length); copy[d.length] = 0;
      {
         char *line = strtok(copy, "\n");
         while (line)
         {
            char *eq = strchr(line, '=');
            if (eq)
            {
               *eq = 0;
               /* plane_mode / depth_scale: legacy since */
               if      (strstr(line, "lua_budget"))  s_lua_budget = atol(eq + 1);
               else if (strstr(line, "profile_match_min"))    s_match_min   = atof(eq + 1);
               else if (strstr(line, "prefer_user_profiles")) s_prefer_user = atoi(eq + 1);
               else if (strstr(line, "bundled_profiles"))     s_bundled     = atoi(eq + 1);
               *eq = '=';
            }
            line = strtok(NULL, "\n");
         }
      }
      free(copy);
      ra3d_knobs_parse_ex(&s_knobs, txt, d.length, &unknown,
                          ra_scene_legacy_key, NULL);
      ra_scene_beaconf("3dsen: 3dsen.cfg read (%d unknown keys ignored) — "
                       "size_z_scale=%.3f fallback_z=%.1f layer_z UI %.0f L1 %.0f "
                       "L2 %.0f L3 %.0f L4 %.0f pattern3d=%d planes=%d%s depth=%.2f "
                       "flat_shapes=%d",
                       unknown, (double)s_knobs.size_z_scale,
                       (double)s_knobs.fallback_size_z,
                       (double)s_knobs.layer_z[1], (double)s_knobs.layer_z[2],
                       (double)s_knobs.layer_z[3], (double)s_knobs.layer_z[4],
                       (double)s_knobs.layer_z[5], s_knobs.pattern3d_index,
                       s_plane_mode,
                       s_plane_mode_set ? "" : " (auto: 1 with shapes, 2 without)",
                       (double)s_depth_scale, s_knobs.flat_shapes);
   }
}

/* Exact -> case-insensitive -> region-tag-tolerant, unique match only, in
 * `dir`. Quiet: the caller beacons the verdict. *how names the step. */
static NSString *ra_scene_find_by_name(NSString *dir, const char *stem, const char **how)
{
   NSFileManager *fm  = NSFileManager.defaultManager;
   NSString      *want = [NSString stringWithUTF8String:stem];
   NSArray       *entries;
   NSString      *hit = nil;
   char wantn[256], gotn[256];
   int nmatch = 0;

   *how = NULL;
   if (!dir || !want) return nil;
   NSString *exact = [dir stringByAppendingPathComponent:
                        [want stringByAppendingString:@".3dn"]];
   if ([fm fileExistsAtPath:exact]) { *how = "exact"; return exact; }

   entries = [fm contentsOfDirectoryAtPath:dir error:NULL];
   if (!entries) return nil;
   for (NSString *e in entries)
   {
      if (![e.pathExtension.lowercaseString isEqualToString:@"3dn"]) continue;
      if ([e.stringByDeletingPathExtension caseInsensitiveCompare:want] == NSOrderedSame)
      { *how = "case-insensitive"; return [dir stringByAppendingPathComponent:e]; }
   }
   ra_scene_normalize(stem, wantn, sizeof(wantn));
   for (NSString *e in entries)
   {
      if (![e.pathExtension.lowercaseString isEqualToString:@"3dn"]) continue;
      ra_scene_normalize(e.stringByDeletingPathExtension.UTF8String,
                         gotn, sizeof(gotn));
      if (!strcmp(gotn, wantn))
      { nmatch++; hit = [dir stringByAppendingPathComponent:e]; }
   }
   if (nmatch == 1) { *how = "tolerant"; return hit; }
   return nil;
}

/* ---------------------------------------------------------------------------
 * pick the profile by ROM CONTENT (ra3d_match.h).
 *
 * Candidates: every .3dn the user dropped in system/3dsen/ (signed here, cached
 * by path+size+mtime) and the 101 official 3dSenVR v2 profiles bundled in
 * <app>/3dsen-profiles/ (signed at build time, index.bin). Precedence:
 *   1. the best content-eligible USER profile — unless it carries the same
 *      profile Id as a bundled one (an older copy of an official profile):
 *      3dSen refuses to import a custom profile over a built-in Id, so the
 *      bundled (v2) copy wins there; `prefer_user_profiles = 1` overrides;
 *   2. else the best content-eligible BUNDLED profile;
 *   3. else filename (exact / case / region-tolerant): user dir, then bundle;
 *   4. else none (2D planes).
 * ------------------------------------------------------------------------- */
#if defined(HAVE_ZLIB) || defined(HAVE_7ZIP)
int file_archive_compressed_read(const char *path, void **buf,
                                 const char *optional_filename, int64_t *length);
#endif

#define RA_SCENE_USER_MAX 32
typedef struct
{
   char      path[1024];
   long long size;
   double    mtime;
   char      id[32];
   uint64_t *tiles;
   uint32_t  ntiles;
   bool      used;
} RaSceneUserSig;

static RaSceneUserSig  s_user_sig[RA_SCENE_USER_MAX];
/* the picked content's No-Intro CRC32, the camera key when no profile
 * (or one without an Id) matched */
static unsigned        s_rom_crc    = 0;
static int             s_rom_crc_ok = 0;
static Ra3dMatchIndex *s_bundle_ix       = NULL;
static bool            s_bundle_ix_tried = false;

static NSString *ra_scene_bundle_dir(void)
{
   return [NSBundle.mainBundle.resourcePath
             stringByAppendingPathComponent:@"3dsen-profiles"];
}

/* the public build (RA_PUBLIC=1) bundles no 3dSen profiles and
 * no index.bin; user .3dn files in system/3dsen/ are signed at run time and
 * matched by content, then filename, exactly as in the private build. */
static bool ra_scene_public_build(void)
{
   NSString *v = [NSBundle.mainBundle objectForInfoDictionaryKey:@"RABuildVariant"];
   return [v isEqualToString:@"public"];
}

static void ra_scene_load_bundle_index(void)
{
   NSString *p;
   NSData   *d;
   char err[96] = {0};
   if (s_bundle_ix || s_bundle_ix_tried) return;
   s_bundle_ix_tried = true;
   p = [ra_scene_bundle_dir() stringByAppendingPathComponent:@"index.bin"];
   d = [NSData dataWithContentsOfFile:p];
   if (!d && ra_scene_public_build())
   {  /* expected, not a fault — only user profiles exist */
      ra_scene_beaconf("profiles: none bundled (public build); user dir %s",
                       ra_scene_dir().UTF8String);
      return;
   }
   if (!d)
   {
      ra_scene_beaconf("3dsen: no bundled profile index at %s — bundled profiles off",
                       p.UTF8String);
      return;
   }
   s_bundle_ix = ra3d_match_index_load(d.bytes, d.length, err, sizeof(err));
   if (s_bundle_ix)
   {
      uint32_t i; unsigned long t = 0;
      for (i = 0; i < s_bundle_ix->n; i++) t += s_bundle_ix->e[i].ntiles;
      ra_scene_beaconf("3dsen: bundled profile index: %u profiles, %lu tile hashes",
                       s_bundle_ix->n, t);
   }
   else
      ra_scene_beaconf("3dsen: bundled profile index UNREADABLE (%s) — bundled profiles off", err);
}

/* The loaded content's bytes: a plain file, or an `archive#entry` path. */
static NSData *ra_scene_read_rom(void)
{
   const char *cp = path_get(RARCH_PATH_CONTENT);
   NSString *ps;
   NSDictionary *at;
   if (!cp || !*cp) return nil;
#if defined(HAVE_ZLIB) || defined(HAVE_7ZIP)
   /* only a real `archive#entry` path: a plain ROM name may contain '#', and
    * file_archive_get_file_backend() has no backend (NULL) for a non-archive */
   if (
#ifdef HAVE_ZLIB
       strcasestr(cp, ".zip#") ||
#endif
#ifdef HAVE_7ZIP
       strcasestr(cp, ".7z#") ||
#endif
       0)
   {
      void *buf = NULL; int64_t len = 0;
      if (file_archive_compressed_read(cp, &buf, NULL, &len) && buf && len > 0
          && len <= RA3D_MATCH_MAX_ROM)
         return [NSData dataWithBytesNoCopy:buf length:(NSUInteger)len freeWhenDone:YES];
      free(buf);
      return nil;
   }
#endif
   ps = [NSString stringWithUTF8String:cp];
   at = ps ? [NSFileManager.defaultManager attributesOfItemAtPath:ps error:NULL] : nil;
   if (!at || at.fileSize > RA3D_MATCH_MAX_ROM) return nil;   /* not an NES ROM */
   return [NSData dataWithContentsOfFile:ps options:NSDataReadingMappedIfSafe error:NULL];
}

/* the same bytes for the Zapper auto-assign (RAVisionGun.m),
 * main thread. */
NSData *ra_vision_content_bytes(void) { return ra_scene_read_rom(); }

/* Signs (or re-uses) every user .3dn; returns how many are usable. */
static int ra_scene_sign_user(NSString *dir, int *parsed)
{
   NSFileManager *fm = NSFileManager.defaultManager;
   NSArray *entries = [[fm contentsOfDirectoryAtPath:dir error:NULL]
                         sortedArrayUsingSelector:@selector(compare:)];
   int i, n = 0;
   *parsed = 0;
   for (i = 0; i < RA_SCENE_USER_MAX; i++) s_user_sig[i].used = false;
   for (NSString *e in entries)
   {
      NSString *full;
      NSDictionary *at;
      RaSceneUserSig *slot = NULL, *freeslot = NULL;
      long long sz; double mt;
      if (![e.pathExtension.lowercaseString isEqualToString:@"3dn"]) continue;
      full = [dir stringByAppendingPathComponent:e];
      at   = [fm attributesOfItemAtPath:full error:NULL];
      if (!at || strlen(full.UTF8String) >= sizeof(s_user_sig[0].path)) continue;
      sz = (long long)at.fileSize;
      mt = at.fileModificationDate.timeIntervalSince1970;
      for (i = 0; i < RA_SCENE_USER_MAX; i++)
      {
         RaSceneUserSig *u = &s_user_sig[i];
         if (u->path[0] && !strcmp(u->path, full.UTF8String)) { slot = u; break; }
         if (!u->path[0] && !freeslot) freeslot = u;
      }
      if (slot && (slot->size != sz || slot->mtime != mt))
      {  /* changed on disk: re-sign */
         free(slot->tiles); slot->tiles = NULL; slot->ntiles = 0;
         freeslot = slot; slot = NULL;
      }
      if (!slot)
      {
         NSData *d;
         Ra3dProfile *pr;
         char err[64];
         if (!freeslot)
         {
            ra_scene_beaconf("3dsen: more than %d user profiles — %s not content-matched",
                             RA_SCENE_USER_MAX, e.UTF8String);
            continue;
         }
         slot = freeslot;
         memset(slot, 0, sizeof(*slot));
         strncpy(slot->path, full.UTF8String, sizeof(slot->path) - 1);
         slot->size = sz; slot->mtime = mt;
         d = [NSData dataWithContentsOfFile:full];
         if (d)
         {
            ra3d_match_profile_id(d.bytes, d.length, slot->id, sizeof(slot->id));
            pr = ra3d_profile_parse(d.bytes, d.length, err, sizeof(err));
            if (pr)
            {
               ra3d_match_profile_tiles(pr, &slot->tiles, &slot->ntiles);
               ra3d_profile_free(pr);
            }
         }
         (*parsed)++;
      }
      slot->used = true;
      n++;
   }
   /* forget files that are gone */
   for (i = 0; i < RA_SCENE_USER_MAX; i++)
      if (s_user_sig[i].path[0] && !s_user_sig[i].used)
      {
         free(s_user_sig[i].tiles);
         memset(&s_user_sig[i], 0, sizeof(s_user_sig[i]));
      }
   return n;
}

static const char *ra_scene_user_name(const RaSceneUserSig *u)
{
   const char *nm = strrchr(u->path, '/');
   return nm ? nm + 1 : u->path;
}

static double ra_scene_now_ms(void)
{
   return CFAbsoluteTimeGetCurrent() * 1000.0;
}

static NSString *ra_scene_pick_profile(const char *stem)
{
   NSString *udir = ra_scene_dir(), *bdir = ra_scene_bundle_dir();
   NSData *rom;
   Ra3dRomTiles rt;
   Ra3dMatchScore bu = {0}, bb = {0}, ru = {0}, tw = {0}, s;
   int ibu = -1, ibb = -1, iru = -1, itw = -1, i, nuser, parsed = 0;
   bool ru_user = false, have_rom;
   double t0, t1, t2, t3, t4;
   const char *how = NULL;
   NSString *hit;

   memset(&rt, 0, sizeof(rt));
   if (s_bundled) ra_scene_load_bundle_index();
   t0 = ra_scene_now_ms();
   rom = ra_scene_read_rom();
   t1 = ra_scene_now_ms();
   have_rom = rom && ra3d_match_rom_scan((const uint8_t *)rom.bytes, rom.length, &rt);
   t2 = ra_scene_now_ms();
   nuser = ra_scene_sign_user(udir, &parsed);
   t3 = ra_scene_now_ms();
   if (have_rom)
   {
      for (i = 0; i < RA_SCENE_USER_MAX; i++)
      {
         const RaSceneUserSig *u = &s_user_sig[i];
         if (!u->used || !u->tiles) continue;
         ra3d_match_score(&rt, u->tiles, u->ntiles, &s);
         if (s.ntiles < RA3D_MATCH_MIN_SIG) continue;
         if (ra3d_match_eligible(&s, s_match_min)
             && (ibu < 0 || ra3d_match_better(&s, ra_scene_user_name(u),
                                              &bu, ra_scene_user_name(&s_user_sig[ibu]))))
         { bu = s; ibu = i; }
         if (iru < 0 || s.cov > ru.cov) { ru = s; iru = i; ru_user = true; }
      }
      if (s_bundled && s_bundle_ix)
         for (i = 0; i < (int)s_bundle_ix->n; i++)
         {
            const Ra3dMatchEntry *e = &s_bundle_ix->e[i];
            ra3d_match_score(&rt, e->tiles, e->ntiles, &s);
            if (s.ntiles < RA3D_MATCH_MIN_SIG) continue;
            if (ra3d_match_eligible(&s, s_match_min)
                && (ibb < 0 || ra3d_match_better(&s, e->name, &bb, s_bundle_ix->e[ibb].name)))
            { bb = s; ibb = i; }
            if (iru < 0 || s.cov > ru.cov) { ru = s; iru = i; ru_user = false; }
            /* the bundled profile with the winning user profile's Id */
            if (ibu >= 0 && s_user_sig[ibu].id[0] && !strcmp(e->id, s_user_sig[ibu].id)
                && ra3d_match_eligible(&s, s_match_min))
            { tw = s; itw = i; }
         }
   }
   t4 = ra_scene_now_ms();
   s_rom_crc_ok = have_rom; s_rom_crc = have_rom ? rt.crc_nointro : 0u;
   if (have_rom)
      ra_scene_beaconf("3dsen: rom crc32 %08X (No-Intro, header stripped) 3dsen-crc %08X "
                       "%s prg %u chr %u, %u distinct tiles",
                       rt.crc_nointro, rt.crc_3dsen, rt.ines ? "iNES" : "headerless",
                       rt.prg, rt.chr, rt.count);
   else
      ra_scene_beaconf("3dsen: content bytes unreadable (%s) — content matching skipped",
                       path_get(RARCH_PATH_CONTENT) ? path_get(RARCH_PATH_CONTENT) : "?");
   ra_scene_beaconf("3dsen: match cost read %.1f ms scan %.1f ms user-sign %.1f ms "
                    "(%d user .3dn, %d parsed) score %.1f ms (%u bundled) total %.1f ms",
                    t1 - t0, t2 - t1, t3 - t2, nuser, parsed, t4 - t3,
                    s_bundle_ix && s_bundled ? s_bundle_ix->n : 0, t4 - t0);
   ra3d_match_rom_free(&rt);

   /* 1. user, by content — the Id rule first */
   if (ibu >= 0)
   {
      const RaSceneUserSig *u = &s_user_sig[ibu];
      const char *un = ra_scene_user_name(u);
      if (itw >= 0 && !s_prefer_user)
      {
         const Ra3dMatchEntry *e = &s_bundle_ix->e[itw];
         ra_scene_beaconf("3dsen: user profile \"%s\" carries official profile Id %s — "
                          "the bundled 3dSenVR v2 copy wins, as 3dSen refuses a custom "
                          "profile over a built-in Id (prefer_user_profiles = 1 keeps yours)",
                          un, u->id);
         ra_scene_beaconf("3dsen: profile %s matched by content (tile hash, bundled) — "
                          "coverage %.3f, %u/%u tiles (the user copy scored %.3f)",
                          e->name, tw.cov, tw.found, tw.ntiles, bu.cov);
         return [bdir stringByAppendingPathComponent:[NSString stringWithUTF8String:e->name]];
      }
      ra_scene_beaconf("3dsen: profile %s matched by content (tile hash, user) — "
                       "coverage %.3f, %u/%u tiles%s%s", un, bu.cov, bu.found, bu.ntiles,
                       ibb >= 0 ? "; bundled best was " : "",
                       ibb >= 0 ? s_bundle_ix->e[ibb].name : "");
      return [NSString stringWithUTF8String:u->path];
   }
   /* 2. bundled, by content */
   if (ibb >= 0)
   {
      const Ra3dMatchEntry *e = &s_bundle_ix->e[ibb];
      ra_scene_beaconf("3dsen: profile %s matched by content (tile hash, bundled) — "
                       "coverage %.3f, %u/%u tiles", e->name, bb.cov, bb.found, bb.ntiles);
      return [bdir stringByAppendingPathComponent:[NSString stringWithUTF8String:e->name]];
   }
   if (iru >= 0)
   {
      const char *rn = ru_user ? ra_scene_user_name(&s_user_sig[iru])
                               : s_bundle_ix->e[iru].name;
      ra_scene_beaconf("3dsen: no profile reaches coverage %.2f by content (best %s %.3f, "
                       "%u/%u tiles)", s_match_min, rn, ru.cov, ru.found, ru.ntiles);
   }
   /* 3. filename */
   hit = ra_scene_find_by_name(udir, stem, &how);
   if (hit)
   {
      ra_scene_beaconf("3dsen: profile %s matched by filename (%s, user)",
                       hit.lastPathComponent.UTF8String, how);
      return hit;
   }
   if (s_bundled && s_bundle_ix)
   {
      hit = ra_scene_find_by_name(bdir, stem, &how);
      if (hit)
      {
         ra_scene_beaconf("3dsen: profile %s matched by filename (%s, bundled)",
                          hit.lastPathComponent.UTF8String, how);
         return hit;
      }
   }
   /* 4. none */
   ra_scene_beaconf("3dsen: profile none matched by none for \"%s\" (%d user .3dn in %s, "
                    "%u bundled) — shape mode off", stem, nuser, udir.UTF8String,
                    s_bundled && s_bundle_ix ? s_bundle_ix->n : 0);
   return nil;
}

static void ra_scene_drop_profile(void)
{
   /* Only ever reach into the core through a pointer whose image is still
    * mapped — leaving 3D can race a core swap. */
   if (s_enabled_core && s_scene_enable && ra_scene_image_alive())
      s_scene_enable(0);
   s_enabled_core = false;
   ra_scene_lua_free();               /* End(), before the profile it reads */
   if (s_profile) { ra3d_profile_free(s_profile); s_profile = NULL; }
   s_mode_on = false;
   s_last_frame = 0xFFFFFFFFu;
   /* The last frame's build refers to the OLD ROM's atlas; make it impossible
    * for anything downstream to draw it against the new one. */
   s_geo.instance_count = 0;
   s_geo.cell_count     = 0;
   s_atlas_n            = 0;
}

/* The emulator has stopped producing frames — the menu is up, or content is
 * being swapped. Stop the core capturing (it costs 4 % while it runs) and mark
 * the mode not-live, but KEEP the parsed profile and the remembered content
 * path: re-parsing Punch-Out's 1 MB profile on the render thread every time
 * the Quick Menu closes would be a dropped frame per menu visit. Idempotent
 * and safe to call every frame. */
void ra_vision_scene_suspend(void)
{
   if (!s_mode_on && !s_enabled_core)
      return;
   if (s_enabled_core && s_scene_enable && ra_scene_image_alive())
      s_scene_enable(0);
   s_enabled_core = false;
   s_mode_on      = false;
   s_last_frame   = 0xFFFFFFFFu;
   s_geo.instance_count = 0;
   s_geo.cell_count     = 0;
}

void ra_vision_scene_stop(void)
{
   ra_scene_drop_profile();
   s_content[0] = 0;
}

void ra_vision_scene_poll(void)
{
   const char *base;
   char stem[512];
   size_t n;

   /* A cached pointer into a core that has been unloaded is a crash, not a
    * miss — check the image is still there before anything else. */
   if (s_scene_get && !ra_scene_image_alive())
   {
      s_enabled_core = false;      /* the PPU that had it enabled is gone */
      ra_scene_forget_syms();
      ra_scene_beaconf("3dsen: core unloaded — scene stream dropped");
      ra_vision_scene_suspend();
   }
   ra_scene_resolve_syms();
   if (!s_scene_get)
   {
      if (s_mode_on) ra_scene_drop_profile();
      return;
   }
   if (!s_knobs_ready) ra_scene_load_knobs();

   base = path_get(RARCH_PATH_BASENAME);
   if (!base || !*base)
   {
      if (s_content[0])
      {
         ra_vision_camera_persist_key(NULL, 0, 0, "content closed");
         ra_scene_drop_profile(); s_content[0] = 0;
      }
      return;
   }
   if (!strcmp(base, s_content))
   {
      /* Same content. Two reasons to re-assert the capture flag rather than
       * assume it:
       *   - a suspend turned it off while the menu was up, and
       *   - `mesen_hdpacks` (Quick Menu > Core Options > Enable HD Packs)
       *     toggles LIVE: `Console::UpdateHdPackMode()` swaps PPU for HdPpu
       *     in place, and the flag lives ON the PPU, so the new one starts
       *     with capture off and the stream would quietly die.
       * The setter is two stores; re-issuing it once a second is free. */
      if (s_profile)
      {
         s_scene_enable(1);
         s_enabled_core = true;
         s_mode_on      = true;
      }
      return;
   }

   strncpy(s_content, base, sizeof(s_content) - 1);
   s_content[sizeof(s_content) - 1] = 0;
   ra_scene_drop_profile();

   /* basename, extension stripped */
   {
      const char *slash = strrchr(base, '/');
      const char *dot;
      strncpy(stem, slash ? slash + 1 : base, sizeof(stem) - 1);
      stem[sizeof(stem) - 1] = 0;
      /* Strip a ROM extension only if the tail actually LOOKS like one.
       * `path_get(RARCH_PATH_BASENAME)` usually has none already, and a blind
       * strrchr('.') turns "Super Mario Bros. (World)" into
       * "Super Mario Bros" and "Mr. Gimmick (J)" into "Mr" — a title with a
       * dot in it would silently lose its region tag and stop matching. */
      dot = strrchr(stem, '.');
      if (dot && dot != stem)
      {
         const char *q; int ok = dot[1] != 0;
         for (q = dot + 1; *q && ok; q++)
            if (!isalnum((unsigned char)*q)) ok = 0;
         if (ok && strlen(dot + 1) <= 4) *(char *)dot = 0;
      }
   }
   n = strlen(stem);
   if (!n) return;

   {
      NSString *path;
      NSData   *d;
      char err[128] = {0};
      ra_scene_load_knobs();     /* re-read the cfg on every content change */
      s_rom_crc_ok = 0;
      path = ra_scene_pick_profile(stem);
      d    = path ? [NSData dataWithContentsOfFile:path] : nil;
      {  /* the camera's game — the profile Id, else the ROM CRC32 */
         char pid[64] = {0};
         if (d) ra3d_match_profile_id(d.bytes, d.length, pid, sizeof(pid));
         ra_vision_camera_persist_key(pid, s_rom_crc, s_rom_crc_ok, "content change");
      }
      if (!d) return;
      s_profile = ra3d_profile_parse(d.bytes, d.length, err, sizeof(err));
      if (!s_profile)
      {
         ra_scene_beaconf("3dsen: profile parse FAILED (%s) — shape mode off", err);
         return;
      }
      ra_scene_beaconf("3dsen: profile loaded — %u patterns, %u shapes, "
                       "%u tile variants, %u scripts, %.0f KB",
                       ra3d_profile_pattern_count(s_profile),
                       ra3d_profile_shape_count(s_profile),
                       ra3d_profile_variant_count(s_profile),
                       s_profile->scripts.n,
                       (double)d.length / 1024.0);
      if (s_knobs.lua)
      {
         s_lua = ra_scene_lua_new();
         ra_scene_beaconf("3dlua: %s — static Lua scrapers (Start() layer flags, "
                          "LocalCam, UpdateS hides, EmptyTile) %s",
                          s_lua ? "profile Lua RUNNING" : "no VM (no scripts)",
                          s_lua ? "retired for this profile" : "in use");
      }
      else
         ra_scene_beaconf("3dlua: cfg lua = 0 — profile Lua NOT run, static scrapers in use");
      s_scene_enable(1);
      s_enabled_core = true;
      s_mode_on      = true;
      ra_scene_beaconf("3dsen: SHAPE MODE ON for \"%s\"", stem);
      {
         float ld[3], lc[3];
         int lf = ra3d_profile_light(s_profile, ld, lc);
         ra_scene_beaconf("3dsen: profile light — %s%s dir %.3f,%.3f,%.3f color %.3f,%.3f,%.3f",
                          (lf & 1) ? "dir" : "no-dir", (lf & 2) ? "+color" : " no-color",
                          (double)ld[0], (double)ld[1], (double)ld[2],
                          (double)lc[0], (double)lc[1], (double)lc[2]);
      }
      {
         float pc[4] = {0};
         int cf = ra3d_profile_clipping(s_profile, pc);
         ra_scene_beaconf("3dsen: profile clipping — %s %.2f,%.2f,%.2f,%.2f "
                          "(3dSen order L,B,R,T)", cf ? "static" : "none (3dSen default)",
                          (double)pc[0], (double)pc[1], (double)pc[2], (double)pc[3]);
      }
      {  /* harness hook, env-gated and inert in every normal launch
          * (like RA3D_CAM): RA3D_TEST_ALPHA=<a> makes the first Pattern3D of
          * every pattern authored >= 2x2 tiles translucent, so the simulator
          * can photograph the translucent path without reaching a level whose
          * profile is translucent on its own (SMB's are water/lava). */
         const char *ta = getenv("RA3D_TEST_ALPHA");
         float a = ta ? (float)atof(ta) : 0.0f;
         if (a > 0.0f && a < 1.0f)
         {
            uint32_t i, n = 0;
            for (i = 0; i < s_profile->patterns.n; i++)
            {
               Ra3dPattern *pt = &s_profile->patterns.v[i];
               if (pt->w >= 2 && pt->h >= 2 && pt->shape_count)
               { s_profile->shapes.v[pt->shape_first].alpha = a; n++; }
            }
            ra_scene_beaconf("3dsen: RA3D_TEST_ALPHA %.2f forced on %u patterns (harness)",
                             (double)a, n);
         }
      }
      {
         float rx = 0.0f, dd = 0.0f;
         int lc = ra3d_profile_localcam(s_profile, &rx, &dd);
         ra_scene_beaconf("3dsen: profile LocalCam — %s (src %s) Rot.x %.1f Distance %.1f%s",
                          (lc & 1) ? "ON" : "off",
                          (lc & 8) ? "UpdateS literal" : (lc & 4) ? "Start() literal"
                          : (lc & 16) ? "scene-gated + floor pose" : (lc & 2) ? "static _Setting_"
                          : "none",
                          (double)rx, (double)dd, dd > 0.0f ? "" : " (3dSen default 189.65)");
      }
      /* what the static Stage-0 reads took from the profile */
      ra_scene_beaconf("3dsen: profile EmptyTile %d (static %d, Start %d, scene-gated %d; "
                       "cfg empty_tile %d) | %u hiding scripts -> %u Pattern3Ds hidden | "
                       "knobs flat_shapes %d unity_frame %d pattern3d %d retina %d tile_share %d",
                       ra3d_profile_empty_tile(s_profile), s_profile->et_static,
                       s_profile->et_start, s_profile->et_dyn, s_knobs.empty_tile,
                       s_profile->hide_scripts, s_profile->lua_hidden,
                       s_knobs.flat_shapes, s_knobs.unity_frame, s_knobs.pattern3d_index,
                       s_knobs.retina, s_knobs.tile_share);
   }
}

bool  ra_vision_scene_mode_on(void)     { return s_mode_on; }
static const Ra3dLuaState *ra_scene_lua_st(void);
int   ra_vision_scene_lua_active(void) { return s_mode_on && s_profile && s_lua; }
int   ra_vision_scene_profile_light(float dir[3], float col[3])
{
   int f;
   const Ra3dLuaState *st;
   if (!s_mode_on || !s_profile) return 0;
   f = ra3d_profile_light(s_profile, dir, col);
   if ((st = ra_scene_lua_st()))
   {  /* the scripts' Light.Direction / Light.Color win over _Setting_ */
      if (st->light_dir_set) { memcpy(dir, st->light_dir, sizeof(float) * 3); f |= 1; }
      if (st->light_col_set) { memcpy(col, st->light_col, sizeof(float) * 3); f |= 2; }
   }
   return f;
}
int   ra_vision_scene_profile_clipping(float clip[4])
{
   const Ra3dLuaState *st;
   if (!s_mode_on || !s_profile) return 0;
   if ((st = ra_scene_lua_st())) { memcpy(clip, st->clip, sizeof(float) * 4); return 1; }
   return ra3d_profile_clipping(s_profile, clip);
}
int   ra_vision_scene_profile_localcam(float *rotx, float *dist)
{  /* Setting.LocalCam + Camera.Rot.x / Distance from the scripts */
   const Ra3dLuaState *st;
   if (!s_mode_on || !s_profile) { if (rotx) *rotx = 0.0f; if (dist) *dist = 0.0f; return 0; }
   if ((st = ra_scene_lua_st()))
   {
      if (rotx) *rotx = st->cam_set ? st->cam_rot[0] : 0.0f;
      if (dist) *dist = st->cam_set ? st->cam_dist : 0.0f;
      return st->localcam ? (1 | 32) : 32;          /* src 32 = the VM */
   }
   return ra3d_profile_localcam(s_profile, rotx, dist);
}
int   ra_vision_scene_zapper_offset(float ofs[3])
{
   const Ra3dLuaState *st = ra_scene_lua_st();
   ofs[0] = ofs[1] = ofs[2] = 0.0f;
   if (!st) return 0;
   memcpy(ofs, st->zapper_ofs, sizeof(float) * 3);
   return (ofs[0] != 0.0f || ofs[1] != 0.0f || ofs[2] != 0.0f);
}
int   ra_vision_scene_lua_camera(float rot[3], float *dist, uint32_t *gen)
{
   const Ra3dLuaState *st = ra_scene_lua_st();
   if (!st || !st->cam_set) return 0;
   memcpy(rot, st->cam_rot, sizeof(float) * 3);
   *dist = st->cam_dist;
   *gen  = (s_lua_serial << 20) ^ st->cam_gen;
   return 1;
}
void  ra_vision_scene_set_localcam(int on)
{
   on = on ? 1 : 0;
   if (s_knobs.localcam_active != on)
   {
      s_knobs.localcam_active = on;
      s_last_frame = 0xFFFFFFFFu;     /* rebuild with the new flat_shapes verdict */
   }
}
int   ra_vision_scene_profile_layer_shadow(uint8_t cast[6], uint8_t recv[6])
{  /* 3dSen's defaults when no profile is live */
   const Ra3dLuaState *st = ra_scene_lua_st();
   if (st)
   {
      memcpy(cast, st->layer_cast, 6); memcpy(recv, st->layer_recv, 6);
      return 0x40;                                 /* the VM's table */
   }
   return ra3d_profile_layer_shadow((s_mode_on && s_profile) ? s_profile : NULL, cast, recv);
}
int   ra_vision_scene_plane_mode(void)
{
   if (s_plane_mode_set)
      return s_plane_mode;
   return s_mode_on ? 1 : 2;      /* backdrop only once shapes are drawn */
}
float ra_vision_scene_depth_scale(void) { return s_depth_scale; }

const uint8_t *ra_vision_scene_atlas(unsigned *count)
{
   if (count) *count = s_atlas_n;
   return s_atlas_px;
}
const uint32_t *ra_vision_scene_palette(void) { return s_pal; }
static uint32_t s_bd_core = 0;
uint32_t ra_vision_scene_backdrop_core_rgb(void) { return s_bd_core; }

const Ra3dGeoFrame *ra_vision_scene_fetch(int *is_new)
{
   Ra3dScene sc;
   const uint8_t *latched_ram = NULL;
   int latched = 0;
   if (is_new) *is_new = 0;
   if (!s_mode_on || !s_profile || !s_scene_get)
      return NULL;
   memset(&sc, 0, sizeof(sc));
   if (ra_latch_active())
   {  /* the visible run's scene + RAM, never a hidden run's */
      if (!ra_latch_scene(&sc, &latched_ram))
         return NULL;
      latched = 1;
   }
   else if (!s_scene_get(&sc))
      return NULL;
   /* An empty or half-published scene is a NO-OP, not a build: the core has
    * been told to capture but has not finished a frame yet (the state the tester's
    * first .28 run sat in), or content is closing under us. */
   if (!sc.Tiles || !sc.Atlas || !sc.TileCount || !sc.AtlasCount)
      return NULL;
   if (sc.FrameNumber == s_last_frame)
      return s_geo.instance_count ? &s_geo : NULL;   /* reuse last build */

   /* Script:ReadMem's 2 KB, copied right after the scene was
    * handed over. NOT taken inside the core's publish (that would mean
    * revising overlay 0059 and rebuilding every Mesen slice), so it can be up
    * to the part of one frame the emulator thread has run since — benign for
    * what the scripts read (Punch-Out's opponent id, SMB's world number). */
   s_ram_ok = 0;
   if (latched)
   {  /* copied on the main thread after the visible run, before the
       * state reload: the AHEAD state, as 3dSen's ReadMem reads it */
      if (s_lua && latched_ram) { memcpy(s_ram, latched_ram, sizeof(s_ram)); s_ram_ok = 1; }
   }
   else if (s_lua && s_mem_fn)
   {
      const uint8_t *ram = (const uint8_t *)s_mem_fn(2 /* RETRO_MEMORY_SYSTEM_RAM */);
      if (ram) { memcpy(s_ram, ram, sizeof(s_ram)); s_ram_ok = 1; }
   }
   {
      Ra3dKnobs kk = s_knobs;
      const Ra3dLuaState *st = s_lua ? ra_scene_lua_st() : NULL;
      if (st)
      {  /* the scripts' settings feed the matcher (3dSen: the next segmentation) */
         kk.lua_active   = 1;
         kk.lua_localcam = st->localcam;
         if (kk.empty_tile < 0) kk.empty_tile = st->empty_tile;
         kk.cull_set = 1; memcpy(kk.cull, st->clip, sizeof(kk.cull));   /* Converter culls by the live Clipping */
      }
      if (!ra3d_build_frame(s_profile, &sc, &kk, &s_geo))
         return NULL;
      if (st && !ra_scene_lua_frame(&sc))
         return NULL;
   }
   s_last_frame = sc.FrameNumber;
   if (latched) ra_latch_note_consumed(sc.FrameNumber);

   /* Expand the atlas to one byte of colour index per pixel. The GPU could do
    * the bitplane unpack, but at 1024 tiles this is 64 KB of memcpy-grade work
    * on a frame the emulator only produces 60 times a second, and it keeps the
    * fragment shader to one texture read. */
   {
      /* plus the CHR the scripts' inserted shapes and the Backdrop use */
      /* the frame's extra tiles (textures + Lua inserts), already
       * pixel values, follow the scene's CHR */
      unsigned xn = s_geo.xpx_n, total = sc.AtlasCount + xn;
      if (total > s_atlas_cap)
      {
         uint8_t *np = (uint8_t *)realloc(s_atlas_px, (size_t)total * 64);
         if (!np) return NULL;
         s_atlas_px = np; s_atlas_cap = total;
      }
   {
      unsigned t, y, x;
      for (t = 0; t < total; t++)
      {
         const uint8_t *tile = sc.Atlas + (size_t)t * 16;
         uint8_t *dst = s_atlas_px + (size_t)t * 64;
         if (t >= sc.AtlasCount)
         {
            memcpy(dst, s_geo.xpx + (size_t)(t - sc.AtlasCount) * 64, 64);
            continue;
         }
         for (y = 0; y < 8; y++)
         {
            uint8_t lo = tile[y], hi = tile[8 + y];
            for (x = 0; x < 8; x++)
            {
               unsigned bit = 7 - x;
               dst[y * 8 + x] = (uint8_t)((((hi >> bit) & 1) << 1) |
                                          ((lo >> bit) & 1));
            }
         }
      }
      s_atlas_n = total;
   }
   }
   {
      /* 3dSen's 16-group table (Converter: group g = palette RAM g % 8,
       * colour 0 = the backdrop), as the scripts left it; group 16 = the
       * Backdrop box's own colour */
      const Ra3dLuaState *st = ra_scene_lua_st();
      unsigned i;
      for (i = 0; i < 64; i++)
      {
         unsigned e = st ? st->pal_idx[i]
                         : (sc.PaletteRam ? (sc.PaletteRam[(i & 3) ? (i & 31) : 0] & 0x3Fu) : 0u);
         s_pal[i] = ra3d_nes_rgb(&s_knobs, sc.RgbPalette, e);   /* 3dSen's table */
      }
      /* the backdrop as the core drew it (the plane texture) */
      s_bd_core = (sc.RgbPalette && sc.PaletteRam)
                ? (sc.RgbPalette[sc.PaletteRam[0] & 0x3Fu] & 0x00FFFFFFu) : 0u;
      {
         uint32_t bd = 0xFF000000u;
         if (st)
         {
            int c;
            for (c = 0; c < 3; c++)
            {
               float v = st->bd_color[c] < 0.0f ? 0.0f : (st->bd_color[c] > 1.0f ? 1.0f : st->bd_color[c]);
               bd |= (uint32_t)(v * 255.0f + 0.5f) << (16 - 8 * c);
            }
         }
         for (i = 64; i < 68; i++) s_pal[i] = bd;
      }
   }
   if (is_new) *is_new = 1;
   return &s_geo;
}

/* ---------------------------------------------------------------- Lua
 * Everything that needs the Lua VM's types sits down here, after
 * ra3d_lua.h's implementation — whose unity build of Lua 5.3.6 must be the
 * LAST code in this translation unit. */
#define RA3D_LUA_IMPLEMENTATION
#include "ra3d_lua.h"

static void ra_scene_lua_log(const char *line) { ra_scene_beaconf("%s", line); }

static const Ra3dLuaState *ra_scene_lua_st(void)
{
   return (s_mode_on && s_profile && s_lua) ? ra3d_lua_state(s_lua) : NULL;
}

static Ra3dLua *ra_scene_lua_new(void)
{
   Ra3dLua *rt = ra3d_lua_new(s_profile, ra_scene_lua_log, s_lua_budget);
   s_lua_serial++;
   s_lua_frames = 0; s_lua_ms_sum = 0.0; s_lua_first = 0;
   return rt;
}

static void ra_scene_lua_free(void)
{
   if (!s_lua) return;
   ra_scene_lua_report();
   ra3d_lua_free(s_lua);
   s_lua = NULL;
   s_lua_serial++;
}

static void ra_scene_lua_report(void)
{
   const Ra3dLuaState *st = s_lua ? ra3d_lua_state(s_lua) : NULL;
   if (!st || !s_lua_frames) return;
   ra_scene_beaconf("3dlua: %u frames, Lua avg %.3f ms peak %.3f ms (Update+UpdateS+LateUpdate+"
                    "write-back), %u/%u scripts alive, %u scriptable, %u inserted, ram %s | "
                    "EmptyTile %d LocalCam %d clip %.0f,%.0f,%.0f,%.0f light %s%.2f,%.2f,%.2f "
                    "backdrop %d %.0fx%.0fx%.0f ofs %.0f,%.0f,%.0f camera %.1f,%.1f d%.1f",
                    s_lua_frames, s_lua_ms_sum / s_lua_frames, st->ms_peak, st->alive, st->scripts,
                    st->scriptable, st->inserted, s_ram_ok ? "ok" : "MISSING",
                    st->empty_tile, st->localcam, st->clip[0], st->clip[1], st->clip[2], st->clip[3],
                    st->light_col_set ? "" : "(profile) ", st->light_col[0], st->light_col[1],
                    st->light_col[2], st->bd_enable, st->bd_size[0], st->bd_size[1], st->bd_size[2],
                    st->bd_ofs[0], st->bd_ofs[1], st->bd_ofs[2], st->cam_rot[0], st->cam_rot[1],
                    st->cam_dist);
   s_lua_frames = 0; s_lua_ms_sum = 0.0;
   ra3d_lua_reset_peak(s_lua);
}

static int ra_scene_lua_frame(const Ra3dScene *sc)
{
   Ra3dKnobs kk = s_knobs;
   const Ra3dLuaState *st = ra3d_lua_state(s_lua);
   kk.lua_active = 1;
   kk.lua_localcam = st->localcam;
   if (!ra3d_lua_frame(s_lua, sc, s_ram_ok ? s_ram : NULL, &kk, &s_geo))
      return 0;
   s_lua_ms_sum += st->ms;
   ++s_lua_frames;
   if ((s_lua_frames == 1 && !s_lua_first) || s_lua_frames >= 600)
   {
      s_lua_first = 1;
      ra_scene_lua_report();
   }
   return 1;
}

#endif /* RA_VISION_3D */
