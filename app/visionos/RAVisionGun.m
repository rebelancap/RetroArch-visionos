/* RAVisionGun.m — the NES Zapper, aimed with a PSVR2 Sense controller.
 *
 * Design + findings: The short version:
 *
 *   [Sense]  --GameController--> buttons (GCControllerLiveInput, NOT
 *            |                   extendedGamepad — a Sense has none)
 *            \--ARKit C API----> ar_accessory_tracking_provider, the `aim`
 *                                named location, 90 Hz, device-only
 *                     |
 *                     v
 *   ray x panel plane -> (u, v, offscreen) -> ONE seqlock snapshot
 *                     |
 *                     v
 *   overlay 0064 in cocoa_input_poll() -> touches[0] + mouse_buttons
 *                     |
 *                     v
 *   Mesen's Zapper (RETRO_DEVICE_SUBCLASS(RETRO_DEVICE_POINTER,0), device on
 *   port 2 but aim+trigger read from PORT 0's pointer/mouse)
 *
 * Everything here is inert unless a spatial controller is actually present, or
 * the mock pose source is switched on: `ra_vision_gun_active()` stays false and
 * the frontend hook does not run, so a build with no Sense paired behaves
 * byte-identically to the one before it.
 *
 * THREADING.  Every ARKit accessory call is documented AR_MT_UNSAFE and the
 * anchor collection is provider-owned, so tick() runs on the immersive render
 * thread and nowhere else.  Discovery (GameController notifications, the
 * accessory load completion) lands on the main queue and only appends to a
 * pending list under a mutex; the render thread picks it up.  No dispatch_sync
 * anywhere — the frontend owns the main thread (charter ground rule 5).
 */

#import "RAVision.h"

#if defined(RA_VISION_3D)

#import <Foundation/Foundation.h>
#import <GameController/GameController.h>
#import <ARKit/ARKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <simd/simd.h>

#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

/* ------------------------------------------------------------------ beacon */

static void ra_gun_beaconf(const char *fmt, ...)
{
   char    buf[512];
   va_list ap;
   va_start(ap, fmt);
   vsnprintf(buf, sizeof(buf), fmt, ap);
   va_end(ap);
   RA_BeaconMark(buf);
   NSLog(@"[RAGUN] %s", buf);
}

/* ----------------------------------------------------------- the published
 * snapshot (seqlock: one writer on the render thread, one reader on the
 * emulator thread, no locks and no blocking either way) */

static _Atomic uint32_t s_seq    = 0;
static ra_vision_gun_t  s_snap;
static _Atomic int      s_active = 0;
static _Atomic int      s_on     = 1;   /* ra_vision_gun_set_enabled */
static _Atomic int      s_wanted = 0;   /* set by overlay 0064 */

static void ra_gun_publish(const ra_vision_gun_t *g)
{
   uint32_t s = atomic_load_explicit(&s_seq, memory_order_relaxed);
   atomic_store_explicit(&s_seq, s + 1, memory_order_relaxed);
   atomic_thread_fence(memory_order_release);
   s_snap = *g;
   atomic_thread_fence(memory_order_release);
   atomic_store_explicit(&s_seq, s + 2, memory_order_release);
}

bool ra_vision_gun_fetch(ra_vision_gun_t *out)
{
   int i;
   if (!out)
      return false;
   for (i = 0; i < 8; i++)
   {
      uint32_t a = atomic_load_explicit(&s_seq, memory_order_acquire);
      ra_vision_gun_t t;
      uint32_t b;
      if (a == 0 || (a & 1u))
         continue;
      t = s_snap;
      atomic_thread_fence(memory_order_acquire);
      b = atomic_load_explicit(&s_seq, memory_order_acquire);
      if (a == b) { *out = t; return true; }
   }
   return false;
}

bool ra_vision_gun_active(void)  { return atomic_load(&s_active) != 0; }
void ra_vision_gun_set_enabled(bool on) { atomic_store(&s_on, on ? 1 : 0); }
bool ra_vision_gun_enabled(void) { return atomic_load(&s_on) != 0; }
void ra_vision_gun_set_wanted(bool on) { atomic_store(&s_wanted, on ? 1 : 0); }
bool ra_vision_gun_wanted(void)  { return atomic_load(&s_wanted) != 0; }

/* ------------------------------------------------------------------ config
 *
 * Documents/RetroArch/system/zapper.cfg, same shape as 3dsen.cfg — `key=value`
 * per line, unknown keys ignored, absent file = defaults.  Read once when the
 * immersive loop starts, so a change takes effect on the next entry into 3D
 * rather than needing a relaunch.
 *
 *   reticle=0        1 = draw the crosshair.  Off by default: the gun model
 *                    below is drawn in the hand and you aim by eye, like the
 *                    real Zapper.  Unset + mock pose source: on only when
 *                    RA_GUN_MOCK_RETICLE=1 (simulator rounds).
 *   reticle_size=0.014   half-extent in metres on the panel
 *   gun_model=1      draw the virtual Zapper at the controller pose (0 = off)
 *   hand=right       right | left | any — which Sense drives the gun (OQ-2)
 *   mock=0           1 = pose from a gamepad's right stick (simulator),
 *                    2 = automatic sweep (screenshots without a pad)
 *   grip_offscreen=0 1 = grip button forces "point off screen".  Off by
 *                    default since the grips became the camera zoom while
 *                    the gun is in play; pointing away from the panel still
 *                    reads as off screen.
 *   gun_up=0.045     where the gun model sits in the hand, metres in the aim
 *   gun_right=0.012  frame (+ = up / right / toward the screen).  A pure
 *   gun_forward=-0.02 translation: the barrel stays parallel to the shot ray.
 *                    gun_forward is the handle centre's distance in front of
 *                    the aim origin; when it is absent and the controller
 *                    publishes a `grip` location, that location's depth is
 *                    used instead.  gun_up = gun_right = 0 is the old fit.
 */

static bool  s_cfgReticle     = false;
static bool  s_cfgReticleSet  = false;  /* reticle= present (cfg or defaults key) */
static float s_cfgReticleSize = 0.014f;
static bool  s_cfgModel       = true;
static int   s_cfgHand        = 2;      /* 0 any, 1 left, 2 right */
static int   s_cfgMock        = 0;
static bool  s_cfgGripOff     = false;
static float s_cfgGunUp       = 0.045f;   /* RA_GM_* below, aim-frame metres */
static float s_cfgGunRight    = 0.012f;
static float s_cfgGunFwd      = -0.02f;   /* handle centre 2 cm behind the origin */
static bool  s_cfgGunFwdSet   = false;
/* simulator only: RA_GUN_MOCK_WANTED=1 makes the mock reticle
 * obey the `wanted` gate like a real Sense, so a sim round can show
 * that a plain-pad game draws no crosshair. */
static bool  s_mockStrict     = false;
/* Simulator only: RA_GUN_MOCK_T=<seconds> freezes the mock=2 sweep at that
 * phase (trigger up), so two launches can be compared at one pose. <0 = off. */
static double s_mockFreezeT   = -1.0;

static NSString *const kReticleKey = @"ra3d.v2.reticle";

void ra_vision_panel_set_reticle(bool on)
{
   s_cfgReticle = on;
   [NSUserDefaults.standardUserDefaults setBool:on forKey:kReticleKey];
}
bool ra_vision_panel_reticle(void) { return s_cfgReticle; }

static void ra_gun_load_cfg(void)
{
   NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
   NSString *docs = [NSSearchPathForDirectoriesInDomains(
                        NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
   NSString *path = [docs stringByAppendingPathComponent:
                        @"RetroArch/system/zapper.cfg"];
   NSData   *d    = [NSData dataWithContentsOfFile:path];
   const char *env;

   if ([ud objectForKey:kReticleKey])
   {
      s_cfgReticle    = [ud boolForKey:kReticleKey];
      s_cfgReticleSet = true;
   }

   if (d && d.length)
   {
      char *copy = (char *)malloc(d.length + 1);
      if (copy)
      {
         char *line;
         memcpy(copy, d.bytes, d.length);
         copy[d.length] = 0;
         line = strtok(copy, "\r\n");
         while (line)
         {
            char *eq = strchr(line, '=');
            if (eq && line[0] != '#')
            {
               const char *v = eq + 1;
               *eq = 0;
               if      (strstr(line, "reticle_size"))   s_cfgReticleSize = (float)atof(v);
               else if (strstr(line, "reticle"))
               {
                  s_cfgReticle    = atoi(v) != 0;
                  s_cfgReticleSet = true;
               }
               else if (strstr(line, "gun_model"))      s_cfgModel       = atoi(v) != 0;
               else if (strstr(line, "gun_up"))         s_cfgGunUp       = (float)atof(v);
               else if (strstr(line, "gun_right"))      s_cfgGunRight    = (float)atof(v);
               else if (strstr(line, "gun_forward"))
               {
                  s_cfgGunFwd    = (float)atof(v);
                  s_cfgGunFwdSet = true;
               }
               else if (strstr(line, "grip_offscreen")) s_cfgGripOff     = atoi(v) != 0;
               else if (strstr(line, "mock"))           s_cfgMock        = atoi(v);
               else if (strstr(line, "hand"))
               {
                  if      (strstr(v, "left"))  s_cfgHand = 1;
                  else if (strstr(v, "right")) s_cfgHand = 2;
                  else                         s_cfgHand = 0;
               }
               *eq = '=';
            }
            line = strtok(NULL, "\r\n");
         }
         free(copy);
      }
   }

   /* Env override, for `simctl launch --console SIMCTL_CHILD_RA_GUN_MOCK=2`. */
   if ((env = getenv("RA_GUN_MOCK")) && *env)
      s_cfgMock = atoi(env);
   s_mockStrict = (env = getenv("RA_GUN_MOCK_WANTED")) && atoi(env) != 0;
   s_mockFreezeT = ((env = getenv("RA_GUN_MOCK_T")) && *env) ? atof(env) : -1.0;

   /* Simulator only: the mock has no gun in a hand to aim with, so a sim
    * round can ask for the old aim marker without writing zapper.cfg. */
   if (!s_cfgReticleSet && s_cfgMock
       && (env = getenv("RA_GUN_MOCK_RETICLE")) && atoi(env) != 0)
      s_cfgReticle = true;

   if (s_cfgReticleSize < 0.002f) s_cfgReticleSize = 0.002f;
   /* a typo must not throw the gun across the room */
   if (!(s_cfgGunUp    > -0.30f && s_cfgGunUp    < 0.30f)) s_cfgGunUp    = 0.045f;
   if (!(s_cfgGunRight > -0.30f && s_cfgGunRight < 0.30f)) s_cfgGunRight = 0.012f;
   if (!(s_cfgGunFwd   > -0.30f && s_cfgGunFwd   < 0.30f)) s_cfgGunFwd   = -0.02f;
   if (s_cfgReticleSize > 0.20f)  s_cfgReticleSize = 0.20f;

   ra_gun_beaconf("zapper: cfg %s — reticle=%d size=%.3fm gun_model=%d hand=%s "
                  "mock=%d grip_offscreen=%d",
                  d ? "zapper.cfg" : "defaults (no zapper.cfg)",
                  (int)s_cfgReticle, (double)s_cfgReticleSize, (int)s_cfgModel,
                  s_cfgHand == 1 ? "left" : (s_cfgHand == 2 ? "right" : "any"),
                  s_cfgMock, (int)s_cfgGripOff);
   ra_gun_beaconf("zapper: reticle %s (%s)", s_cfgReticle ? "on" : "off",
                  s_cfgReticleSet ? (s_cfgReticle ? "cfg reticle=1" : "cfg reticle=0")
                : s_cfgReticle    ? "RA_GUN_MOCK_RETICLE=1, mock pose source"
                                  : "cfg reticle=0, default");
   ra_gun_beaconf("zapper: gun model %s (cfg gun_model=%d)",
                  s_cfgModel ? "on" : "off", (int)s_cfgModel);
   ra_gun_beaconf("zapper: gun offset up %.3f right %.3f forward %.3f%s",
                  (double)s_cfgGunUp, (double)s_cfgGunRight, (double)s_cfgGunFwd,
                  s_cfgGunFwdSet ? " (cfg)" : " (default; `grip` depth wins when present)");
}

float ra_vision_gun_reticle_size(void) { return s_cfgReticleSize; }

/* ------------------------------------------------------------ discovery
 *
 * A Sense arrives as an ordinary GCController whose productCategory is
 * GCProductCategorySpatialController; extendedGamepad is nil on it, which is
 * also why overlay 0054's mfi_controller_is_gamepad() cannot hand it a joypad
 * port.  ar_accessory_load_from_device() bridges it into an ar_accessory_t. */

/* Which named location the accessory actually publishes: `aim` when it has
 * one (the PSVR2 Sense does), else `grip` as a coarse fallback.  Written once
 * from the load completion, read on the render thread.  s_hasGrip: the
 * accessory ALSO publishes `grip`, which then places the gun model's handle
 * along the aim ray (the barrel always stays on the ray itself). */
static const char *s_aimName;
static _Atomic int  s_hasGrip = 0;

static pthread_mutex_t  s_lock = PTHREAD_MUTEX_INITIALIZER;
static NSMutableArray  *s_pendingAcc;          /* ar_accessory_t, main queue  */
static NSMutableArray<GCController *> *s_pads; /* the spatial controllers     */
static int              s_accGen = 0;          /* bumped when the set changes */
static bool             s_started = false;

static void ra_gun_load_controller(GCController *c)
{
   if (!c || ![c.productCategory isEqualToString:GCProductCategorySpatialController])
      return;

   pthread_mutex_lock(&s_lock);
   if (!s_pads) s_pads = [NSMutableArray array];
   if (![s_pads containsObject:c]) [s_pads addObject:c];
   pthread_mutex_unlock(&s_lock);

   ra_gun_beaconf("zapper: spatial controller '%s' (vendor '%s') — loading accessory",
                  c.productCategory.UTF8String ?: "?",
                  c.vendorName.UTF8String ?: "?");

   ar_accessory_load_from_device(c, ^(id<GCDevice> device, bool ok,
                                      ar_error_t err, ar_accessory_t acc) {
      (void)device;
      if (!ok || !acc)
      {
         ra_gun_beaconf("zapper: ar_accessory_load_from_device FAILED (err=%ld)",
                        err ? (long)ar_error_get_error_code(err) : -1L);
         return;
      }
      {
         NSMutableString *names = [NSMutableString string];
         ar_strings_t     locs  = ar_accessory_copy_location_names(acc);
         const char      *cnames;
         if (locs)
            ar_strings_enumerate_strings(locs, ^bool(const char *s) {
               if (s)
                  [names appendFormat:@"%s%s", names.length ? "," : "", s];
               return true;
            });
         cnames    = names.UTF8String ?: "";
         s_aimName = strstr(cnames, "aim") ? ar_accessory_location_name_aim
                                           : ar_accessory_location_name_grip;
         atomic_store(&s_hasGrip, (strstr(cnames, "aim") && strstr(cnames, "grip")) ? 1 : 0);
         ra_gun_beaconf("zapper: accessory loaded name='%s' locations=[%s] "
                        "-> using '%s'",
                        ar_accessory_get_name(acc) ?: "?", cnames, s_aimName);
      }
      pthread_mutex_lock(&s_lock);
      if (!s_pendingAcc) s_pendingAcc = [NSMutableArray array];
      [s_pendingAcc addObject:acc];
      s_accGen++;
      pthread_mutex_unlock(&s_lock);
   });
}

void ra_vision_gun_start(void)
{
   if (s_started)
      return;
   s_started = true;
   ra_gun_load_cfg();

   dispatch_async(dispatch_get_main_queue(), ^{
      NSArray<GCController *> *all = GCController.controllers;
      NSMutableString *roster = [NSMutableString string];
      for (GCController *c in all)
         [roster appendFormat:@"%@%s/%s%s", roster.length ? @", " : @"",
                              c.vendorName.UTF8String ?: "?",
                              c.productCategory.UTF8String ?: "?",
                              c.extendedGamepad ? "" : " (no extendedGamepad)"];
      ra_gun_beaconf("zapper: controller roster (%lu) — %s",
                     (unsigned long)all.count,
                     roster.length ? roster.UTF8String : "none");
      for (GCController *c in all)
         ra_gun_load_controller(c);

      [NSNotificationCenter.defaultCenter
         addObserverForName:GCControllerDidConnectNotification
                     object:nil queue:NSOperationQueue.mainQueue
                 usingBlock:^(NSNotification *n) {
            GCController *c = (GCController *)n.object;
            ra_gun_beaconf("zapper: controller connected '%s' category '%s'",
                           c.vendorName.UTF8String ?: "?",
                           c.productCategory.UTF8String ?: "?");
            ra_gun_load_controller(c);
         }];

      [NSNotificationCenter.defaultCenter
         addObserverForName:GCControllerDidDisconnectNotification
                     object:nil queue:NSOperationQueue.mainQueue
                 usingBlock:^(NSNotification *n) {
            GCController *c = (GCController *)n.object;
            pthread_mutex_lock(&s_lock);
            if (s_pads && [s_pads containsObject:c])
            {
               [s_pads removeObject:c];
               ra_gun_beaconf("zapper: spatial controller disconnected");
            }
            pthread_mutex_unlock(&s_lock);
         }];
   });
}

/* --------------------------------------------------------- provider (render
 * thread only).  Rebuilt whenever the accessory set changes.  It runs on its
 * OWN ar_session_t rather than joining the immersive loop's world-tracking
 * session: accessories are discovered asynchronously, long after that session
 * started, and re-running the world-tracking session to add a provider risks
 * moving the origin the panel is frozen against. */

static ar_accessory_tracking_provider_t s_atp;
static ar_session_t                     s_gunSession;
static ar_accessory_anchor_t            s_predicted;
static int                              s_atpGen = -1;
static bool                             s_unsupportedLogged = false;
static bool                             s_firstTracked = false;

static void ra_gun_rebuild_provider(void)
{
   NSArray *accs = nil;
   int      gen;
   ar_accessories_t set;
   ar_accessory_tracking_configuration_t cfg;

   pthread_mutex_lock(&s_lock);
   gen  = s_accGen;
   accs = s_pendingAcc ? [s_pendingAcc copy] : nil;
   pthread_mutex_unlock(&s_lock);

   if (gen == s_atpGen)
      return;
   s_atpGen = gen;
   if (!accs.count)
      return;

   if (!ar_accessory_tracking_provider_is_supported())
   {
      if (!s_unsupportedLogged)
      {
         s_unsupportedLogged = true;
         ra_gun_beaconf("zapper: ar_accessory_tracking_provider_is_supported()=false "
                        "— device-only feature, staying off (mock=%d)", s_cfgMock);
      }
      return;
   }

   set = ar_accessories_create();
   for (id a in accs)
      ar_accessories_add_accessory(set, (ar_accessory_t)a);

   cfg = ar_accessory_tracking_configuration_create();
   ar_accessory_tracking_configuration_set_accessories(cfg, set);
   s_atp = ar_accessory_tracking_provider_create(cfg);
   /* Deliberately NO update handler: the header says omitting it disables the
    * routine anchor stream and saves CPU.  We poll get_latest_anchors instead,
    * which is also the lower-latency path. */

   if (!s_gunSession)
      s_gunSession = ar_session_create();
   {
      ar_data_providers_t dps =
         ar_data_providers_create_with_data_providers(s_atp, NULL);
      ar_session_run(s_gunSession, dps);
   }
   if (!s_predicted)
      s_predicted = ar_accessory_anchor_create();

   ra_gun_beaconf("zapper: accessory provider running with %lu accessory(ies), "
                  "required auth type 0x%lx",
                  (unsigned long)accs.count,
                  (unsigned long)ar_accessory_tracking_provider_get_required_authorization_type());

   ar_session_query_authorization_results(
      s_gunSession, ar_authorization_type_accessory_tracking,
      ^(ar_authorization_results_t results, ar_error_t err) {
         if (err || !results)
         {
            ra_gun_beaconf("zapper: ARKit authorization query FAILED (err=%ld)",
                           err ? (long)ar_error_get_error_code(err) : -1L);
            return;
         }
         ar_authorization_results_enumerate_results(results,
            ^bool(ar_authorization_result_t r) {
               ar_authorization_status_t st = ar_authorization_result_get_status(r);
               ra_gun_beaconf("zapper: ARKit accessory-tracking authorization = %s",
                              st == ar_authorization_status_allowed      ? "ALLOWED"
                            : st == ar_authorization_status_denied       ? "DENIED"
                            : st == ar_authorization_status_not_determined ? "not determined"
                            : "?");
               return true;
            });
      });
}

/* ------------------------------------------------------------ model pose
 *
 * The pose the gun model is drawn at, written by tick() and read by
 * ra_vision_gun_draw_model() — both on the immersive render thread, so plain
 * statics, no snapshot.  s_poseAim is the aim frame in the immersive origin
 * space (right-up-back, forward = -Z: the very ray ra_gun_from_ray()
 * intersects); s_poseGrip is the accessory's `grip` location when it has one. */
static bool          s_poseValid   = false;
static bool          s_poseHasGrip = false;
static simd_float4x4 s_poseAim, s_poseGrip;
static bool          s_trigPrev    = false;
static bool          s_zoPrev      = false;   /* ZapperOffset beacon edge */
static int           s_flashTicks  = 0;   /* muzzle flash, render ticks left */

static void ra_gun_set_pose(simd_float4x4 aim, bool hasGrip, simd_float4x4 grip)
{
   s_poseAim     = aim;
   s_poseGrip    = grip;
   s_poseHasGrip = hasGrip;
   s_poseValid   = true;
}

/* ------------------------------------------------------------ intersection */

static void ra_gun_from_ray(simd_float4x4 head, simd_float3 o, simd_float3 d,
                            uint8_t trigger, uint8_t aux)
{
   simd_float3 pos, right, up, normal;
   float       halfW = 1.0f, halfH = 1.0f, zo[3];
   bool        haveZo;
   ra_vision_gun_t g;

   /* Muzzle flash: two to three render ticks on each trigger press. */
   if (trigger && !s_trigPrev)
      s_flashTicks = 3;
   else if (s_flashTicks > 0)
      s_flashTicks--;
   s_trigPrev = trigger != 0;

   memset(&g, 0, sizeof(g));
   g.valid   = 1;
   g.trigger = trigger;
   g.aux     = aux;

   ra_vision_panel_plane(head, &pos, &right, &up, &normal, &halfW, &halfH);

   /* The profile's ZapperOffset, as 3dSen's Zapper reads it: cast against the plane the
    * targets were moved to (3dSen +Z is away from the viewer, ours toward),
    * then take the move back off the hit, so the shot lands where the duck
    * is DRAWN.  Zero for every profile that never writes it. */
   haveZo = ra_vision_scene_zapper_offset(zo) != 0;
   if (haveZo != s_zoPrev)
   {
      ra_gun_beaconf("zapper: profile ZapperOffset %s (%.1f, %.1f, %.1f px)",
                     haveZo ? "in use" : "cleared",
                     (double)zo[0], (double)zo[1], (double)zo[2]);
      s_zoPrev = haveZo;
   }

   if (ra_vision_fx_bend_active())
   {  /* a bent world — raycast the bent plane, as 3dSen's Zapper does */
      float bu = -1.0f, bv = -1.0f;
      if (!ra_vision_bend_ray(head, o, d, -zo[2], &bu, &bv))
      { g.u = -1.0f; g.v = -1.0f; g.offscreen = 1; goto publish; }
      bu -= zo[0] / 256.0f;
      bv += zo[1] / 240.0f;
      if (bu < 0.0f || bu > 1.0f || bv < 0.0f || bv > 1.0f) g.offscreen = 1;
      g.u = bu < 0.0f ? 0.0f : (bu > 1.0f ? 1.0f : bu);
      g.v = bv < 0.0f ? 0.0f : (bv > 1.0f ? 1.0f : bv);
      goto publish;
   }

   {
      float dl = simd_length(d);
      float denom, t;
      if (dl < 1e-6f) { g.u = -1.0f; g.v = -1.0f; g.offscreen = 1; goto publish; }
      d = d / dl;

      if (haveZo)   /* NES px -> metres along the normal, as the scene's Q */
         pos += normal * (-zo[2] * (halfW / 128.0f) * ra_vision_scene_depth_scale());
      denom = simd_dot(d, normal);
      if (fabsf(denom) < 1e-5f) { g.u = -1.0f; g.v = -1.0f; g.offscreen = 1; goto publish; }
      t = simd_dot(pos - o, normal) / denom;
      if (t <= 0.0f)            { g.u = -1.0f; g.v = -1.0f; g.offscreen = 1; goto publish; }

      {
         simd_float3 p   = o + d * t;
         simd_float3 rel = p - pos;
         float su = simd_dot(rel, right) / (halfW > 1e-5f ? halfW : 1.0f);
         float sv = simd_dot(rel, up)    / (halfH > 1e-5f ? halfH : 1.0f);
         su -= zo[0] / 128.0f;   /* NES x right; the offset's y is up, as the panel's */
         sv -= zo[1] / 120.0f;
         if (fabsf(su) > 1.0f || fabsf(sv) > 1.0f)
            g.offscreen = 1;
         if (su < -1.0f) su = -1.0f; else if (su > 1.0f) su = 1.0f;
         if (sv < -1.0f) sv = -1.0f; else if (sv > 1.0f) sv = 1.0f;
         g.u = (su + 1.0f) * 0.5f;
         /* image space is +Y DOWN — the same flip ra3d_geo_world_to_panel
          * already encodes for the shape layer. */
         g.v = (1.0f - sv) * 0.5f;
      }
   }

publish:
   if (aux && s_cfgGripOff)
      g.offscreen = 1;
   ra_gun_publish(&g);
   atomic_store(&s_active, 1);
}

static void ra_gun_publish_idle(void)
{
   ra_vision_gun_t g;
   s_poseValid  = false;
   s_flashTicks = 0;
   s_trigPrev   = false;
   memset(&g, 0, sizeof(g));
   g.u = g.v = -1.0f;
   ra_gun_publish(&g);
   atomic_store(&s_active, 0);
}

/* ------------------------------------------------------------------- mock
 *
 * The simulator cannot track accessories at all (§1.5), so the whole path
 * downstream of the pose is validated with a synthesised POSE — not a
 * synthesised UV — which means the real intersection code is what runs. */

static float  s_mockYaw, s_mockPitch;
static double s_mockLast;

static bool ra_gun_mock_tick(simd_float4x4 head)
{
   double now = CACurrentMediaTime();
   double dt  = (s_mockLast > 0.0) ? (now - s_mockLast) : 0.0;
   simd_float3 hp  = head.columns[3].xyz;
   simd_float3 fwd = -head.columns[2].xyz;
   simd_float3 wup = simd_make_float3(0.0f, 1.0f, 0.0f);
   simd_float3 right, dir, o;
   uint8_t trigger = 0, aux = 0;
   const float LIM = 0.6109f;   /* 35 degrees */

   s_mockLast = now;
   if (dt > 0.25) dt = 0.25;

   fwd.y = 0.0f;
   {
      float l = simd_length(fwd);
      fwd = (l < 1e-4f) ? simd_make_float3(0, 0, -1) : fwd / l;
   }
   right = simd_normalize(simd_cross(fwd, wup));

   if (s_cfgMock >= 2)
   {
      double t    = s_mockFreezeT >= 0.0 ? s_mockFreezeT : now;
      s_mockYaw   = 0.32f * sinf((float)t * 0.70f);
      s_mockPitch = 0.18f * sinf((float)t * 0.41f);
      trigger     = (s_mockFreezeT < 0.0 && fmod(now, 2.0) < 0.30) ? 1 : 0;
   }
   else
   {
      GCController *pad = nil;
      for (GCController *c in GCController.controllers)
         if (c.extendedGamepad) { pad = c; break; }
      if (pad)
      {
         GCExtendedGamepad *g = pad.extendedGamepad;
         s_mockYaw   -= g.rightThumbstick.xAxis.value * 0.90f * (float)dt;
         s_mockPitch += g.rightThumbstick.yAxis.value * 0.60f * (float)dt;
         trigger      = (g.rightTrigger.isPressed || g.buttonA.isPressed) ? 1 : 0;
         aux          = g.rightShoulder.isPressed ? 1 : 0;
      }
   }
   if (s_mockYaw   >  LIM) s_mockYaw   =  LIM;
   if (s_mockYaw   < -LIM) s_mockYaw   = -LIM;
   if (s_mockPitch >  LIM) s_mockPitch =  LIM;
   if (s_mockPitch < -LIM) s_mockPitch = -LIM;

   o   = hp + fwd * 0.30f + right * 0.20f - wup * 0.20f;
   dir = simd_normalize(fwd * cosf(s_mockYaw) + right * sinf(s_mockYaw));
   dir = simd_normalize(dir * cosf(s_mockPitch) + wup * sinf(s_mockPitch));

   {  /* the aim frame a real accessory would report: forward = -Z, level roll */
      simd_float4x4 m;
      simd_float3   mr = simd_normalize(simd_cross(dir, wup));
      simd_float3   mu = simd_cross(mr, dir);
      m.columns[0] = simd_make_float4(mr, 0.0f);
      m.columns[1] = simd_make_float4(mu, 0.0f);
      m.columns[2] = simd_make_float4(-dir, 0.0f);
      m.columns[3] = simd_make_float4(o, 1.0f);
      ra_gun_set_pose(m, false, m);
   }
   ra_gun_from_ray(head, o, dir, trigger, aux);
   return true;
}

/* --------------------------------------------------------------- buttons */

static void ra_gun_read_buttons(uint8_t *trigger, uint8_t *aux)
{
   NSArray<GCController *> *pads;
   *trigger = 0; *aux = 0;
   pthread_mutex_lock(&s_lock);
   pads = s_pads ? [s_pads copy] : nil;
   pthread_mutex_unlock(&s_lock);

   for (GCController *c in pads)
   {
      GCControllerLiveInput *in = c.input;
      id<GCButtonElement> trig;
      id<GCButtonElement> grip;
      if (!in)
         continue;
      trig = in.buttons[GCInputTrigger];
      grip = in.buttons[GCInputGripButton];
      if (trig && (trig.pressedInput.isPressed || trig.pressedInput.value > 0.5f))
         *trigger = 1;
      if (grip && grip.pressedInput.isPressed)
         *aux = 1;
   }
}

/* -------------------------------------------------------------- the tick */

void ra_vision_gun_tick(double trackable_time, simd_float4x4 head)
{
   __block int   best      = 0;      /* 0 none, 1 tracked, 2 preferred hand */
   __block simd_float3 bo  = {0}, bd = {0};
   __block simd_float4x4 bAim = matrix_identity_float4x4, bGrip = matrix_identity_float4x4;
   __block bool  bHasGrip  = false;
   const bool    wantGrip  = atomic_load(&s_hasGrip) != 0;
   ar_accessory_anchors_t anchors;
   uint8_t trigger = 0, aux = 0;
   static double s_lastLog = 0.0;

   if (!atomic_load(&s_on))
   {
      ra_gun_publish_idle();
      return;
   }

   ra_gun_rebuild_provider();

   if (!s_atp)
   {
      if (s_cfgMock)
      {
         ra_gun_mock_tick(head);
         goto log;
      }
      ra_gun_publish_idle();
      return;
   }

   ra_gun_read_buttons(&trigger, &aux);

   anchors = ar_accessory_tracking_provider_get_latest_anchors(s_atp);
   if (anchors)
      ar_accessory_anchors_enumerate_anchors(anchors, ^bool(ar_accessory_anchor_t a) {
         ar_accessory_anchor_tracking_state_t st = ar_accessory_anchor_get_tracking_state(a);
         ar_accessory_chirality_t ch;
         int rank;
         simd_float4x4 oa, al, om, ag = matrix_identity_float4x4;
         ar_accessory_anchor_t src = a;

         if (   st != ar_accessory_anchor_tracking_state_position_orientation_tracked
             && st != ar_accessory_anchor_tracking_state_position_orientation_tracked_low_accuracy)
            return true;

         ch   = ar_accessory_anchor_get_held_chirality(a);
         rank = 1;
         if (   (s_cfgHand == 2 && ch == ar_accessory_chirality_right)
             || (s_cfgHand == 1 && ch == ar_accessory_chirality_left)
             ||  s_cfgHand == 0)
            rank = 2;
         if (rank <= best)
            return true;

         if (s_predicted
             && ar_accessory_tracking_provider_predict_anchor_at_timestamp(
                   s_atp, a, trackable_time, s_predicted))
            src = s_predicted;
         oa = ar_accessory_anchor_get_origin_from_anchor_transform_with_correction(
                 src, ar_transform_correction_rendered);
         al = ar_accessory_anchor_get_anchor_from_location_transform_with_correction(
                 src, s_aimName ?: ar_accessory_location_name_aim,
                 ar_transform_correction_rendered);
         if (wantGrip)
            ag = ar_accessory_anchor_get_anchor_from_location_transform_with_correction(
                    src, ar_accessory_location_name_grip,
                    ar_transform_correction_rendered);
         om = simd_mul(oa, al);
         bo = om.columns[3].xyz;
         /* right-up-BACK: forward is -Z, the same convention the head pose and
          * cp_drawable_compute_projection already use. */
         bd = -om.columns[2].xyz;
         bAim     = om;
         bGrip    = simd_mul(oa, ag);
         bHasGrip = wantGrip;
         best = rank;
         return true;
      });

   if (!best)
   {
      /* Backgrounded, unpaired, or orientation-only: degrade to "no gun" so
       * the frontend leaves touches[0] alone rather than freezing the aim
       * at the last position. */
      if (s_cfgMock)
      {
         ra_gun_mock_tick(head);
         goto log;
      }
      ra_gun_publish_idle();
      return;
   }

   if (!s_firstTracked)
   {
      s_firstTracked = true;
      ra_gun_beaconf("zapper: first tracked anchor — aim origin (%.3f, %.3f, %.3f) "
                     "forward (%.3f, %.3f, %.3f)",
                     (double)bo.x, (double)bo.y, (double)bo.z,
                     (double)bd.x, (double)bd.y, (double)bd.z);
   }

   ra_gun_set_pose(bAim, bHasGrip, bGrip);
   ra_gun_from_ray(head, bo, bd, trigger, aux);

log:
   {
      double now = CACurrentMediaTime();
      if (now - s_lastLog >= 1.0)
      {
         ra_vision_gun_t g;
         s_lastLog = now;
         if (ra_vision_gun_fetch(&g) && g.valid)
            ra_gun_beaconf("zapper: u=%.3f v=%.3f onscreen=%d trigger=%d aux=%d "
                           "src=%s wanted=%d", (double)g.u, (double)g.v,
                           g.offscreen ? 0 : 1, g.trigger, g.aux,
                           s_atp ? "sense" : "mock",
                           atomic_load(&s_wanted) ? 1 : 0);
      }
   }
}

/* ------------------------------------------------------------------ reticle
 *
 * The real Zapper had no crosshair, but a 5.5 m panel at 3.6 m is not a CRT in
 * your living room; without one the first minute is pure frustration.  Drawn
 * from the SAME published u,v the frontend consumed this frame — if the two
 * ever disagreed the user would be aiming at a lie — on a quad 2 mm in front
 * of the panel plane, depth-always so the 3dSen extrusion cannot swallow it.
 *
 * Self-contained on purpose: pipeline, shader and state all live here, so the
 * immersive loop needs exactly one call and RAImmersive.m owns none of it.
 */

static NSString *const kRAGunShader =
   @"#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct RVOut { float4 pos [[position]]; float2 uv; };\n"
    "vertex RVOut ra_ret_vs(uint vid [[vertex_id]], constant float4x4& mvp [[buffer(0)]]) {\n"
    "  const float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };\n"
    "  RVOut o; o.pos = mvp * float4(p[vid], 0.0, 1.0);\n"
    "  o.uv = (p[vid] + 1.0) * 0.5; return o;\n"
    "}\n"
    "fragment float4 ra_ret_fs(RVOut in [[stage_in]],\n"
    "                          constant float4& tint [[buffer(0)]]) {\n"
    "  float2 p = in.uv * 2.0 - 1.0; float r = length(p);\n"
    "  float dot_a  = 1.0 - smoothstep(0.16, 0.24, r);\n"
    "  float ring_a = smoothstep(0.56, 0.64, r) * (1.0 - smoothstep(0.86, 0.94, r));\n"
    "  float a = max(dot_a, ring_a) * tint.a;\n"
    "  if (a < 0.02) discard_fragment();\n"
    "  return float4(tint.rgb * a, a);\n"
    "}\n";

static id<MTLRenderPipelineState> s_retPipe;
static id<MTLDepthStencilState>   s_retDepth;
static MTLPixelFormat             s_retColor = MTLPixelFormatInvalid;
static MTLPixelFormat             s_retDepthFmt = MTLPixelFormatInvalid;
static NSUInteger                 s_retSamples = 1;   /* the eye pass's MSAA */

static void ra_gun_build_reticle(id<MTLDevice> dev, MTLPixelFormat color,
                                 MTLPixelFormat depth, NSUInteger samples)
{
   NSError *err = nil;
   id<MTLLibrary> lib;
   MTLRenderPipelineDescriptor *rp;
   MTLDepthStencilDescriptor   *dd;

   if (samples < 1) samples = 1;
   if (s_retPipe && color == s_retColor && depth == s_retDepthFmt && samples == s_retSamples)
      return;
   s_retColor = color; s_retDepthFmt = depth; s_retSamples = samples; s_retPipe = nil;

   lib = [dev newLibraryWithSource:kRAGunShader options:nil error:&err];
   if (!lib)
   {
      ra_gun_beaconf("zapper: reticle shader compile FAILED: %s",
                     err.localizedDescription.UTF8String ?: "?");
      return;
   }
   rp = [MTLRenderPipelineDescriptor new];
   rp.vertexFunction                                  = [lib newFunctionWithName:@"ra_ret_vs"];
   rp.fragmentFunction                                = [lib newFunctionWithName:@"ra_ret_fs"];
   rp.colorAttachments[0].pixelFormat                 = color;
   rp.colorAttachments[0].blendingEnabled             = YES;
   /* Premultiplied: the fragment shader already multiplies rgb by alpha. */
   rp.colorAttachments[0].sourceRGBBlendFactor        = MTLBlendFactorOne;
   rp.colorAttachments[0].destinationRGBBlendFactor   = MTLBlendFactorOneMinusSourceAlpha;
   rp.colorAttachments[0].sourceAlphaBlendFactor      = MTLBlendFactorOne;
   rp.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
   rp.depthAttachmentPixelFormat                      = depth;
   rp.rasterSampleCount                               = samples;
   s_retPipe = [dev newRenderPipelineStateWithDescriptor:rp error:&err];
   if (!s_retPipe)
   {
      ra_gun_beaconf("zapper: reticle pipeline FAILED: %s",
                     err.localizedDescription.UTF8String ?: "?");
      return;
   }
   dd = [MTLDepthStencilDescriptor new];
   dd.depthCompareFunction = MTLCompareFunctionAlways;
   dd.depthWriteEnabled    = NO;
   s_retDepth = [dev newDepthStencilStateWithDescriptor:dd];
   ra_gun_beaconf("zapper: reticle pipeline built");
}

void ra_vision_gun_draw_reticle(id<MTLRenderCommandEncoder> enc,
                                simd_float4x4 viewProj, simd_float4x4 head,
                                MTLPixelFormat color, MTLPixelFormat depth,
                                NSUInteger samples)
{
   ra_vision_gun_t g;
   simd_float3     pp, pr, pu, pn;
   float           phw = 1.0f, phh = 1.0f, rs, su, sv;
   simd_float4x4   rm, mvp;
   simd_float4     tint;

   if (!enc || !s_cfgReticle || !ra_vision_gun_active())
      return;
   /* only when a port actually carries a light gun and the game (not
    * the menu) is in play — the same gate 0064 applies to the pointer, so the
    * crosshair and what the core is fed can never disagree.  The mock pose
    * source keeps drawing for simulator rounds. */
   if (!atomic_load(&s_wanted) && !(s_cfgMock && !s_mockStrict))
      return;
   if (!ra_vision_gun_fetch(&g) || !g.valid || g.u < 0.0f)
      return;   /* the ray never met the plane — draw nothing */

   ra_gun_build_reticle(enc.device, color, depth, samples);
   if (!s_retPipe)
      return;

   rs = s_cfgReticleSize;
   su = g.u * 2.0f - 1.0f;
   sv = 1.0f - g.v * 2.0f;
   tint = g.offscreen ? simd_make_float4(0.95f, 0.20f, 0.12f, 0.70f)
                      : simd_make_float4(1.00f, 1.00f, 1.00f, 0.90f);

   ra_vision_panel_plane(head, &pp, &pr, &pu, &pn, &phw, &phh);
   {  /* on a bent world the reticle sits on the bent plane */
      float bz = 0.0f;
      if (ra_vision_bend_reticle(g.u, g.v, &su, &sv, &bz)) pp += pn * (bz * phw);
   }
   rm.columns[0] = simd_make_float4(pr * rs, 0.0f);
   rm.columns[1] = simd_make_float4(pu * rs, 0.0f);
   rm.columns[2] = simd_make_float4(pn * rs, 0.0f);
   rm.columns[3] = simd_make_float4(pp + pr * (su * phw)
                                       + pu * (sv * phh)
                                       + pn * 0.002f, 1.0f);
   mvp = simd_mul(viewProj, rm);

   [enc setRenderPipelineState:s_retPipe];
   if (s_retDepth)
      [enc setDepthStencilState:s_retDepth];
   [enc setVertexBytes:&mvp  length:sizeof(mvp)  atIndex:0];
   [enc setFragmentBytes:&tint length:sizeof(tint) atIndex:0];
   [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

/* --------------------------------------------------------------- gun model
 *
 * A virtual NES Zapper in the hand, so the gun can be aimed by eye the way
 * the real one was, with no crosshair.  The model is Max Keeley's "Nintendo
 * Zapper Gun Model" (CC BY 4.0, credit in the README and in
 * gun-model/LICENSE-zapper-model.md), recoloured to the original grey Zapper
 * and converted offline by scripts/convert-zapper-mesh.py into gun-model/
 * zapper.mesh (one indexed, vertex-coloured triangle list in the model frame
 * below), about 26 cm from muzzle to rear.  If that file cannot be loaded, a
 * procedural stand-in built from unit boxes and cylinders is drawn instead.
 * One pipeline that lives here like the reticle's.
 *
 * MODEL FRAME, metres: +X right, +Y up, +Z back toward the user; the barrel
 * axis is the line x = y = 0 pointing down -Z.  The model is placed IN the aim
 * frame and only translated in it, so its barrel axis stays parallel to the
 * ray the shots are cast along.  Along the ray, the middle of the handle goes
 * `gun_forward` metres in front of the aim origin (default 2 cm behind), or,
 * when that key is absent and the accessory publishes a `grip` location, at
 * that location's depth (clamped).  `gun_up` / `gun_right` then lift and
 * shift the whole model so the grip, not the slide, lands in the hand.  Drawn in the eye pass, depth-tested and depth-written
 * against the scene (reverse-Z), lit by the scene's directional light. */

#define RA_GM_CM            0.01f
#define RA_GM_HAND_Z_CM     4.6f     /* handle centre, model z (cm)            */
#define RA_GM_GRIP_CLAMP    0.15f    /* max slide along the ray from `grip` (m) */
#define RA_GM_MAX_INST      24
#define RA_GM_CYL_SEG       20
#define RA_GM_AMBIENT_MIN   0.30f    /* linear ambient floor: the dark grey grip
                                        must not read as a black blob          */
#define RA_GM_FILE_MAX_VERTS (1u << 20)

static NSString *const kRAGunModelShader =
   @"#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct GMInst { float4x4 m; float4 n0, n1, n2; float4 col; };\n"
    "struct GMLight { float4 dir; float4 rgb; float4 params; };\n"
    "struct GMOut { float4 pos [[position]]; float3 n; float4 col; };\n"
    "static float3 gm_dec(float3 c) { return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045); }\n"
    "static float3 gm_enc(float3 c) { c = saturate(c); return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308); }\n"
    "vertex GMOut ra_gm_vs(uint vid [[vertex_id]], uint iid [[instance_id]],\n"
    "                      const device float4 *mesh [[buffer(0)]],\n"
    "                      constant GMInst *inst [[buffer(1)]],\n"
    "                      constant float4x4 &vp [[buffer(2)]]) {\n"
    "  GMInst I = inst[iid];\n"
    "  uint st = I.col.a > 2.5 ? 3u : 2u;\n"
    "  GMOut o; o.pos = vp * (I.m * float4(mesh[vid * st].xyz, 1.0));\n"
    "  o.n = float3x3(I.n0.xyz, I.n1.xyz, I.n2.xyz) * mesh[vid * st + 1].xyz;\n"
    "  o.col = I.col;\n"
    "  if (st == 3u) o.col = float4(mesh[vid * 3 + 2].rgb, 1.0);\n"
    "  return o;\n"
    "}\n"
    "fragment float4 ra_gm_fs(GMOut in [[stage_in]], constant GMLight &lt [[buffer(0)]]) {\n"
    "  float3 alb = gm_dec(in.col.rgb), c;\n"
    "  if (in.col.a > 1.5) c = alb;\n"
    "  else c = alb * (lt.rgb.xyz * max(0.0, dot(normalize(in.n), lt.dir.xyz)) + lt.params.x);\n"
    "  if (lt.params.y > 0.5) c = gm_enc(c);\n"
    "  return float4(c, 1.0);\n"
    "}\n";

typedef struct
{
   simd_float4x4 m;
   simd_float4   n0, n1, n2;
   simd_float4   col;          /* sRGB rgb; a = 1 lit, 2 emissive, 3 lit with
                                  the mesh's own vertex colours (stride 3) */
} ra_gm_inst_t;

typedef struct { simd_float4 dir, rgb, params; } ra_gm_light_t;

static id<MTLRenderPipelineState> s_gmPipe;
static id<MTLDepthStencilState>   s_gmDepth;
static MTLPixelFormat             s_gmColor = MTLPixelFormatInvalid;
static MTLPixelFormat             s_gmDepthFmt = MTLPixelFormatInvalid;
static NSUInteger                 s_gmSamples = 1;
static bool                       s_gmLogged = false;

static void ra_gm_push(float *v, NSUInteger *n, simd_float3 p, simd_float3 nm)
{
   float *d = v + (*n) * 8;
   d[0] = p.x;  d[1] = p.y;  d[2] = p.z;  d[3] = 1.0f;
   d[4] = nm.x; d[5] = nm.y; d[6] = nm.z; d[7] = 0.0f;
   (*n)++;
}

/* ---------------------------------------------------------- the gun mesh
 *
 * A gun mesh is up to RA_GM_MAX_MESH vertex buffers (triangle lists,
 * interleaved float4 position + float4 normal [+ float4 sRGB vertex colour],
 * in the MODEL FRAME described above, optionally indexed) plus a list of
 * parts: each part names one of those meshes and carries its model-frame
 * matrix, normal matrix, sRGB colour and kind (1 lit, 2 emissive, 3 lit with
 * vertex colours) and whether it shows only during the muzzle flash.
 * ra_gun_mesh_build() fills it once per device (the loaded Zapper, else the
 * procedural stand-in); the draw below applies the tracked pose and issues
 * one instanced draw per mesh, from one call site.  Any model drops in as
 * long as it is authored (or re-based) in the same model frame: barrel down
 * -Z on x = y = 0, handle centre at z = RA_GM_HAND_Z_CM. */

#define RA_GM_MAX_MESH 8

typedef struct
{
   simd_float4x4 m;          /* model frame, metres  */
   simd_float3x3 n;          /* its normal matrix    */
   simd_float4   col;        /* sRGB rgb, a = kind   */
   int           mesh;
   bool          flashOnly;
} ra_gm_part_t;

typedef struct
{
   id<MTLBuffer> vb[RA_GM_MAX_MESH];
   NSUInteger    nv[RA_GM_MAX_MESH];
   id<MTLBuffer> ib[RA_GM_MAX_MESH];   /* uint32 indices, or nil (plain list) */
   NSUInteger    ni[RA_GM_MAX_MESH];
   int           meshes;
   ra_gm_part_t  part[RA_GM_MAX_INST];
   int           parts;
   const char   *source;     /* for the beacon */
   NSUInteger    tris;       /* loaded model's triangles, 0 = stand-in */
} ra_gun_mesh_t;

static ra_gun_mesh_t s_gunMesh;
static bool          s_gunMeshOk = false;

/* Placeholder meshes: a cube [-0.5, 0.5]^3 (mesh 0) and a capped cylinder of
 * radius 1 along Z, z in [-0.5, 0.5] (mesh 1). */
static void ra_gm_build_meshes(id<MTLDevice> dev)
{
   float      box[36 * 8], cyl[RA_GM_CYL_SEG * 12 * 8];
   NSUInteger nb = 0, nc = 0;
   int        f, i;

   for (f = 0; f < 6; f++)
   {
      int         ax = f >> 1;
      float       sg = (f & 1) ? 1.0f : -1.0f;
      simd_float3 n  = 0, u = 0, w = 0, c;
      n[ax] = sg; u[(ax + 1) % 3] = 0.5f; w[(ax + 2) % 3] = 0.5f;
      c = n * 0.5f;
      ra_gm_push(box, &nb, c - u - w, n); ra_gm_push(box, &nb, c + u - w, n);
      ra_gm_push(box, &nb, c + u + w, n); ra_gm_push(box, &nb, c - u - w, n);
      ra_gm_push(box, &nb, c + u + w, n); ra_gm_push(box, &nb, c - u + w, n);
   }
   for (i = 0; i < RA_GM_CYL_SEG; i++)
   {
      float a0 = (float)i       * 2.0f * (float)M_PI / RA_GM_CYL_SEG;
      float a1 = (float)(i + 1) * 2.0f * (float)M_PI / RA_GM_CYL_SEG;
      simd_float3 r0 = simd_make_float3(cosf(a0), sinf(a0), 0.0f);
      simd_float3 r1 = simd_make_float3(cosf(a1), sinf(a1), 0.0f);
      simd_float3 zb = simd_make_float3(0, 0, -0.5f), zf = simd_make_float3(0, 0, 0.5f);
      ra_gm_push(cyl, &nc, r0 + zb, r0); ra_gm_push(cyl, &nc, r1 + zb, r1);
      ra_gm_push(cyl, &nc, r1 + zf, r1); ra_gm_push(cyl, &nc, r0 + zb, r0);
      ra_gm_push(cyl, &nc, r1 + zf, r1); ra_gm_push(cyl, &nc, r0 + zf, r0);
      ra_gm_push(cyl, &nc, zb, simd_make_float3(0, 0, -1));
      ra_gm_push(cyl, &nc, r1 + zb, simd_make_float3(0, 0, -1));
      ra_gm_push(cyl, &nc, r0 + zb, simd_make_float3(0, 0, -1));
      ra_gm_push(cyl, &nc, zf, simd_make_float3(0, 0, 1));
      ra_gm_push(cyl, &nc, r0 + zf, simd_make_float3(0, 0, 1));
      ra_gm_push(cyl, &nc, r1 + zf, simd_make_float3(0, 0, 1));
   }
   s_gunMesh.vb[0] = [dev newBufferWithBytes:box length:nb * 8 * sizeof(float)
                                     options:MTLResourceStorageModeShared];
   s_gunMesh.vb[1] = [dev newBufferWithBytes:cyl length:nc * 8 * sizeof(float)
                                     options:MTLResourceStorageModeShared];
   s_gunMesh.nv[0] = nb;
   s_gunMesh.nv[1] = nc;
   s_gunMesh.meshes = 2;
}

static void ra_gm_build(id<MTLDevice> dev, MTLPixelFormat color,
                        MTLPixelFormat depth, NSUInteger samples)
{
   NSError *err = nil;
   id<MTLLibrary> lib;
   MTLRenderPipelineDescriptor *rp;

   if (samples < 1) samples = 1;
   if (s_gmPipe && color == s_gmColor && depth == s_gmDepthFmt && samples == s_gmSamples)
      return;
   s_gmColor = color; s_gmDepthFmt = depth; s_gmSamples = samples; s_gmPipe = nil;

   lib = [dev newLibraryWithSource:kRAGunModelShader options:nil error:&err];
   if (!lib)
   {
      ra_gun_beaconf("zapper: gun model shader compile FAILED: %s",
                     err.localizedDescription.UTF8String ?: "?");
      return;
   }
   rp = [MTLRenderPipelineDescriptor new];
   rp.vertexFunction                  = [lib newFunctionWithName:@"ra_gm_vs"];
   rp.fragmentFunction                = [lib newFunctionWithName:@"ra_gm_fs"];
   rp.colorAttachments[0].pixelFormat = color;
   rp.depthAttachmentPixelFormat      = depth;
   rp.rasterSampleCount               = samples;
   s_gmPipe = [dev newRenderPipelineStateWithDescriptor:rp error:&err];
   if (!s_gmPipe)
   {
      ra_gun_beaconf("zapper: gun model pipeline FAILED: %s",
                     err.localizedDescription.UTF8String ?: "?");
      return;
   }
   if (!s_gmDepth)
   {
      MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
      dd.depthCompareFunction = MTLCompareFunctionGreaterEqual;   /* reverse-Z */
      dd.depthWriteEnabled    = YES;
      s_gmDepth = [dev newDepthStencilStateWithDescriptor:dd];
   }
}

/* One stand-in part, in the model frame: unit mesh -> scale (cm) -> rotate
 * rxDeg about X around the part's pivot -> pivot + local offset (cm). */
static void ra_gm_part(int mesh, simd_float3 pivot, float rxDeg, simd_float3 off,
                       simd_float3 size, simd_float3 rgb, float kind, bool flashOnly)
{
   float         a = rxDeg * (float)M_PI / 180.0f, c = cosf(a), s = sinf(a);
   simd_float3x3 R;
   simd_float3   t, sz = size * RA_GM_CM;
   ra_gm_part_t *q;

   if (s_gunMesh.parts >= RA_GM_MAX_INST)
      return;
   q = &s_gunMesh.part[s_gunMesh.parts++];
   R.columns[0] = simd_make_float3(1, 0, 0);
   R.columns[1] = simd_make_float3(0, c, s);
   R.columns[2] = simd_make_float3(0, -s, c);
   t = pivot * RA_GM_CM + simd_mul(R, off * RA_GM_CM);
   q->m.columns[0] = simd_make_float4(R.columns[0] * sz.x, 0.0f);
   q->m.columns[1] = simd_make_float4(R.columns[1] * sz.y, 0.0f);
   q->m.columns[2] = simd_make_float4(R.columns[2] * sz.z, 0.0f);
   q->m.columns[3] = simd_make_float4(t, 1.0f);
   /* R . S: the normal matrix is R . S^-1 */
   q->n.columns[0] = R.columns[0] / sz.x;
   q->n.columns[1] = R.columns[1] / sz.y;
   q->n.columns[2] = R.columns[2] / sz.z;
   q->col       = simd_make_float4(rgb, kind);
   q->mesh      = mesh;
   q->flashOnly = flashOnly;
}

static void ra_gun_mesh_reset(void)
{  /* ARC-owned buffers released by assignment, not memset */
   int k;
   for (k = 0; k < RA_GM_MAX_MESH; k++)
   {
      s_gunMesh.vb[k] = nil; s_gunMesh.nv[k] = 0;
      s_gunMesh.ib[k] = nil; s_gunMesh.ni[k] = 0;
   }
   s_gunMesh.meshes = s_gunMesh.parts = 0;
   s_gunMesh.source = NULL;
   s_gunMesh.tris   = 0;
}

/* The procedural stand-in, drawn only when zapper.mesh cannot be loaded. */
static bool ra_gun_mesh_build_standin(id<MTLDevice> dev)
{
   const simd_float3 GREY   = { 0.74f, 0.74f, 0.72f };
   const simd_float3 DARK   = { 0.28f, 0.28f, 0.30f };
   const simd_float3 ORANGE = { 0.96f, 0.45f, 0.10f };
   const simd_float3 FLASH  = { 1.00f, 0.95f, 0.70f };
   const simd_float3 O      = { 0, 0, 0 };
   const simd_float3 GRIPP  = { 0, -3.0f, 3.6f };   /* handle pivot: under the receiver */
   enum { BOX = 0, CYL = 1 };

   ra_gun_mesh_reset();
   ra_gm_build_meshes(dev);
   if (!s_gunMesh.vb[BOX] || !s_gunMesh.vb[CYL])
      return false;
   s_gunMesh.source = "procedural stand-in";

   /* receiver, top rib, rear cap, sights */
   ra_gm_part(BOX, (simd_float3){ 0, -0.6f,  1.0f }, 0, O, (simd_float3){ 3.8f, 5.2f, 12.0f }, GREY, 1, false);
   ra_gm_part(BOX, (simd_float3){ 0,  2.3f,  1.0f }, 0, O, (simd_float3){ 1.6f, 0.8f, 11.0f }, GREY, 1, false);
   ra_gm_part(BOX, (simd_float3){ 0, -0.6f,  7.3f }, 0, O, (simd_float3){ 3.4f, 4.6f,  0.6f }, DARK, 1, false);
   ra_gm_part(BOX, (simd_float3){ 0,  3.0f,  6.0f }, 0, O, (simd_float3){ 1.4f, 0.8f,  0.8f }, DARK, 1, false);
   ra_gm_part(BOX, (simd_float3){ 0,  1.9f,-17.0f }, 0, O, (simd_float3){ 0.5f, 1.0f,  1.2f }, DARK, 1, false);
   /* handle (raked back 16 degrees) and its butt cap */
   ra_gm_part(BOX, GRIPP, 16, (simd_float3){ 0, -5.0f, 0 },  (simd_float3){ 3.2f, 10.0f, 4.2f }, GREY, 1, false);
   ra_gm_part(BOX, GRIPP, 16, (simd_float3){ 0, -10.2f, 0 }, (simd_float3){ 3.4f,  0.6f, 4.6f }, DARK, 1, false);
   /* trigger guard (bottom bar, front post) and the orange trigger */
   ra_gm_part(BOX, (simd_float3){ 0, -6.4f, -0.6f }, 0, O, (simd_float3){ 1.0f, 0.7f, 5.4f }, GREY, 1, false);
   ra_gm_part(BOX, (simd_float3){ 0, -4.7f, -3.0f }, 0, O, (simd_float3){ 1.0f, 3.6f, 0.7f }, GREY, 1, false);
   ra_gm_part(BOX, (simd_float3){ 0, -4.6f, -0.4f }, -12, O, (simd_float3){ 0.8f, 2.4f, 0.9f }, ORANGE, 1, false);
   /* barrel shoulder, barrel, muzzle ring (cylinder size = radius, radius, length) */
   ra_gm_part(CYL, (simd_float3){ 0, 0,  -6.5f }, 0, O, (simd_float3){ 1.9f,  1.9f,  3.0f }, ORANGE, 1, false);
   ra_gm_part(CYL, (simd_float3){ 0, 0, -13.0f }, 0, O, (simd_float3){ 1.55f, 1.55f, 10.0f }, ORANGE, 1, false);
   ra_gm_part(CYL, (simd_float3){ 0, 0, -18.5f }, 0, O, (simd_float3){ 1.75f, 1.75f,  1.0f }, DARK, 1, false);
   /* muzzle flash: an emissive disc just past the muzzle */
   ra_gm_part(CYL, (simd_float3){ 0, 0, -19.3f }, 0, O, (simd_float3){ 1.4f, 1.4f, 0.4f }, FLASH, 2, true);
   return true;
}

/* gun-model/zapper.mesh, written by scripts/convert-zapper-mesh.py.
 * Little-endian: "RAZM", uint32 version 1, uint32 vertex count, uint32 index
 * count; then per vertex float32 position[3], float32 normal[3], uint8 sRGB
 * rgba[4] (28 bytes); then uint32 triangle-list indices.  Already in the model
 * frame, in metres.  Expanded here to the draw's float4 x 3 vertex layout.
 * Returns the vertex buffer (and *ib, *nv, *ni, *minZ), or nil with *why set. */
static id<MTLBuffer> ra_gm_load_file(id<MTLDevice> dev, NSString *path,
                                     id<MTLBuffer> *ib, NSUInteger *nv,
                                     NSUInteger *ni, float *minZ,
                                     const char **why)
{
   NSData         *d;
   const uint8_t  *b;
   uint32_t        hdr[4], nV, nI, i;
   NSUInteger      want;
   id<MTLBuffer>   vb;
   float          *out;
   const uint32_t *idx;

   *why = NULL;
   if (!path)                       { *why = "not in the app bundle"; return nil; }
   d = [NSData dataWithContentsOfFile:path];
   if (!d || d.length < 16)         { *why = "unreadable or truncated"; return nil; }
   b = (const uint8_t *)d.bytes;
   memcpy(hdr, b, sizeof(hdr));
   if (memcmp(b, "RAZM", 4) != 0)   { *why = "bad magic"; return nil; }
   if (hdr[1] != 1)                 { *why = "unknown version"; return nil; }
   nV = hdr[2]; nI = hdr[3];
   if (!nV || nV > RA_GM_FILE_MAX_VERTS || !nI || nI % 3 || nI > 3u * RA_GM_FILE_MAX_VERTS)
                                    { *why = "bad counts"; return nil; }
   want = 16 + (NSUInteger)nV * 28 + (NSUInteger)nI * 4;
   if (d.length != want)            { *why = "size does not match its header"; return nil; }
   idx = (const uint32_t *)(b + 16 + (NSUInteger)nV * 28);   /* 4-aligned: 16 + 28n */
   for (i = 0; i < nI; i++)
      if (idx[i] >= nV)             { *why = "index out of range"; return nil; }

   vb = [dev newBufferWithLength:(NSUInteger)nV * 12 * sizeof(float)
                         options:MTLResourceStorageModeShared];
   *ib = [dev newBufferWithBytes:idx length:(NSUInteger)nI * 4
                         options:MTLResourceStorageModeShared];
   if (!vb || !*ib)                 { *why = "Metal buffer allocation failed"; *ib = nil; return nil; }
   out   = (float *)vb.contents;
   *minZ = 0.0f;
   for (i = 0; i < nV; i++)
   {
      const uint8_t *v = b + 16 + (NSUInteger)i * 28;
      float          f[6];
      memcpy(f, v, sizeof(f));
      out[0] = f[0]; out[1] = f[1]; out[2]  = f[2]; out[3]  = 1.0f;
      out[4] = f[3]; out[5] = f[4]; out[6]  = f[5]; out[7]  = 0.0f;
      out[8] = v[24] / 255.0f; out[9] = v[25] / 255.0f; out[10] = v[26] / 255.0f;
      out[11] = v[27] / 255.0f;
      if (i == 0 || f[2] < *minZ)
         *minZ = f[2];
      out += 12;
   }
   *nv = nV;
   *ni = nI;
   return vb;
}

/* The in-hand Zapper: the converted model, else the procedural stand-in (the
 * beacon says why).  Mesh 0 = the model (one part, its own vertex colours),
 * mesh 1 = the unit cylinder, used for the flash-only muzzle disc. */
static bool ra_gun_mesh_build(id<MTLDevice> dev)
{
   NSString      *path = [[NSBundle mainBundle] pathForResource:@"zapper" ofType:@"mesh"
                                                    inDirectory:@"gun-model"];
   id<MTLBuffer>  vb, ib = nil;
   NSUInteger     nv = 0, ni = 0;
   float          minZ = 0.0f;
   const char    *why = NULL;
   ra_gm_part_t  *q;

   ra_gun_mesh_reset();
   vb = ra_gm_load_file(dev, path, &ib, &nv, &ni, &minZ, &why);
   if (!vb)
   {
      ra_gun_beaconf("zapper: gun mesh zapper.mesh not loaded (%s) — procedural stand-in",
                     why ? why : "?");
      return ra_gun_mesh_build_standin(dev);
   }
   ra_gm_build_meshes(dev);            /* fills meshes 0 (box) and 1 (cylinder) */
   if (!s_gunMesh.vb[1])
   {
      ra_gun_beaconf("zapper: gun mesh zapper.mesh not loaded (flash mesh failed) — procedural stand-in");
      return ra_gun_mesh_build_standin(dev);
   }
   s_gunMesh.vb[0] = vb;  s_gunMesh.nv[0] = nv;
   s_gunMesh.ib[0] = ib;  s_gunMesh.ni[0] = ni;
   s_gunMesh.meshes = 2;
   s_gunMesh.source = "zapper.mesh";
   s_gunMesh.tris   = ni / 3;

   q = &s_gunMesh.part[s_gunMesh.parts++];
   q->m         = matrix_identity_float4x4;
   q->n         = matrix_identity_float3x3;
   q->col       = simd_make_float4(1.0f, 1.0f, 1.0f, 3.0f);
   q->mesh      = 0;
   q->flashOnly = false;
   /* muzzle flash: an emissive disc just past the muzzle (cylinder size =
    * radius, radius, length in cm, centred 0.8 cm in front of the muzzle) */
   ra_gm_part(1, (simd_float3){ 0, 0, minZ / RA_GM_CM - 0.8f }, 0, (simd_float3){ 0, 0, 0 },
              (simd_float3){ 1.2f, 1.2f, 0.4f }, (simd_float3){ 1.00f, 0.95f, 0.70f }, 2, true);
   ra_gun_beaconf("zapper: gun mesh loaded (zapper.mesh, %lu verts, %lu tris, muzzle z %.3f m)",
                  (unsigned long)nv, (unsigned long)(ni / 3), minZ);
   return true;
}

/* The tracked pose the gun mesh is drawn at: the aim frame, translated in
 * that frame only (never rotated, so the barrel stays parallel to the ray):
 * along the ray to put the handle centre in the hand (the `grip` location's
 * depth when the accessory has one and gun_forward is not set), then up and
 * right by gun_up / gun_right. */
static simd_float4x4 ra_gun_mesh_pose(void)
{
   simd_float4x4 pose  = s_poseAim;
   float         slide = -s_cfgGunFwd;
   if (s_poseHasGrip && !s_cfgGunFwdSet)
   {
      simd_float3 g = simd_mul(simd_inverse(s_poseAim), s_poseGrip.columns[3]).xyz;
      slide = g.z;
      if (slide >  RA_GM_GRIP_CLAMP) slide =  RA_GM_GRIP_CLAMP;
      if (slide < -RA_GM_GRIP_CLAMP) slide = -RA_GM_GRIP_CLAMP;
   }
   slide -= RA_GM_HAND_Z_CM * RA_GM_CM;
   pose.columns[3] += pose.columns[2] * slide
                    + pose.columns[1] * s_cfgGunUp
                    + pose.columns[0] * s_cfgGunRight;
   return pose;
}

void ra_vision_gun_draw_model(id<MTLRenderCommandEncoder> enc,
                              simd_float4x4 viewProj,
                              simd_float3 toLight, simd_float3 lightRgb,
                              float ambient, bool encodeSrgb,
                              MTLPixelFormat color, MTLPixelFormat depth,
                              NSUInteger samples)
{
   ra_gm_inst_t  inst[RA_GM_MAX_INST];
   int           first[RA_GM_MAX_MESH], count[RA_GM_MAX_MESH];
   ra_gm_light_t lt;
   simd_float4x4 pose;
   simd_float3x3 P;
   bool          flash = s_flashTicks > 0;
   int           n = 0, k, i;

   if (!enc || !s_cfgModel || !s_poseValid || !ra_vision_gun_active())
      return;
   /* The same gate as the reticle (light gun in play, game not menu). */
   if (!atomic_load(&s_wanted) && !(s_cfgMock && !s_mockStrict))
      return;

   ra_gm_build(enc.device, color, depth, samples);
   if (!s_gunMeshOk)
      s_gunMeshOk = ra_gun_mesh_build(enc.device);
   if (!s_gmPipe || !s_gunMeshOk)
      return;

   pose = ra_gun_mesh_pose();
   P.columns[0] = pose.columns[0].xyz;
   P.columns[1] = pose.columns[1].xyz;
   P.columns[2] = pose.columns[2].xyz;

   /* The part list, posed and grouped by mesh (one instanced draw each). */
   for (k = 0; k < s_gunMesh.meshes && k < RA_GM_MAX_MESH; k++)
   {
      first[k] = n;
      for (i = 0; i < s_gunMesh.parts; i++)
      {
         const ra_gm_part_t *q = &s_gunMesh.part[i];
         simd_float3x3 nm;
         if (q->mesh != k || (q->flashOnly && !flash))
            continue;
         nm = simd_mul(P, q->n);
         inst[n].m   = simd_mul(pose, q->m);
         inst[n].n0  = simd_make_float4(nm.columns[0], 0.0f);
         inst[n].n1  = simd_make_float4(nm.columns[1], 0.0f);
         inst[n].n2  = simd_make_float4(nm.columns[2], 0.0f);
         inst[n].col = q->col;
         n++;
      }
      count[k] = n - first[k];
   }
   if (!n)
      return;

   {
      float l = simd_length(toLight);
      lt.dir  = simd_make_float4(l > 1e-5f ? toLight / l : simd_make_float3(0, 1, 0), 0.0f);
   }
   lt.rgb    = simd_make_float4(lightRgb, 0.0f);
   lt.params = simd_make_float4(fmaxf(ambient, RA_GM_AMBIENT_MIN), encodeSrgb ? 1.0f : 0.0f,
                                0.0f, 0.0f);

   [enc setRenderPipelineState:s_gmPipe];
   if (s_gmDepth && depth != MTLPixelFormatInvalid)
      [enc setDepthStencilState:s_gmDepth];
   [enc setVertexBytes:inst length:sizeof(ra_gm_inst_t) * (NSUInteger)n atIndex:1];
   [enc setVertexBytes:&viewProj length:sizeof(viewProj) atIndex:2];
   [enc setFragmentBytes:&lt length:sizeof(lt) atIndex:0];
   for (k = 0; k < s_gunMesh.meshes && k < RA_GM_MAX_MESH; k++)
   {
      if (!count[k] || !s_gunMesh.vb[k])
         continue;
      [enc setVertexBuffer:s_gunMesh.vb[k] offset:0 atIndex:0];
      if (s_gunMesh.ib[k])
         [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:s_gunMesh.ni[k]
                          indexType:MTLIndexTypeUInt32 indexBuffer:s_gunMesh.ib[k]
                  indexBufferOffset:0 instanceCount:(NSUInteger)count[k]
                         baseVertex:0 baseInstance:(NSUInteger)first[k]];
      else
         [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:s_gunMesh.nv[k]
               instanceCount:(NSUInteger)count[k] baseInstance:(NSUInteger)first[k]];
   }

   if (!s_gmLogged)
   {
      const char *src = s_poseHasGrip ? "grip" : (s_atp ? "aim" : "aim, mock pose source");
      s_gmLogged = true;
      if (s_gunMesh.tris)
         ra_gun_beaconf("zapper: gun model drawn (mesh: %s, %lu tris, source %s)",
                        s_gunMesh.source, (unsigned long)s_gunMesh.tris, src);
      else
         ra_gun_beaconf("zapper: gun model drawn (mesh: %s, %d instances, source %s)",
                        s_gunMesh.source ? s_gunMesh.source : "?", n, src);
   }
}

/* ------------------------------------------------- input while the gun plays
 *
 * Emulator thread, from ra_vision_camera_input() (itself called by the input
 * poll), so it reads the mfi joypad driver's port-1 state from the same poll
 * the core is handed.  While a light gun is in play (the `wanted` gate)
 * the triggers belong to the gun alone: the Sense pad no longer feeds them
 * into L2/R2 (overlay 0068), and the camera zoom moves to the grips — pad L
 * (left grip) is zoom out and pad R (right grip) is zoom in, passed in the
 * L2/R2 slots so camera_swap_zoom still swaps them.  Outside gun mode the
 * values pass through untouched.  Returns true in gun mode. */
#include "input/input_driver.h"

bool ra_vision_gun_zoom_remap(float *l2, float *r2)
{
   static int s_prevMode = -1;
   int        mode       = atomic_load(&s_wanted) ? 1 : 0;

   if (mode != s_prevMode)
   {
      s_prevMode = mode;
      if (mode)
         ra_gun_beaconf("zapper: gun mode input — triggers fire, grips zoom "
                        "[map: either trigger -> Zapper fire (pointer press), not "
                        "pad L2/R2, not zoom | left grip = pad L -> zoom out | "
                        "right grip = pad R -> zoom in | camera_swap_zoom swaps "
                        "the grips | grip_offscreen=%d]", (int)s_cfgGripOff);
      else
         ra_gun_beaconf("zapper: normal input mode — triggers zoom (L2 out, R2 in), "
                        "grips are pad L/R");
   }
   if (!mode || !l2 || !r2)
      return false;
   *l2 = mfi_joypad.button(0, (uint16_t)RETRO_DEVICE_ID_JOYPAD_L) ? 1.0f : 0.0f;
   *r2 = mfi_joypad.button(0, (uint16_t)RETRO_DEVICE_ID_JOYPAD_R) ? 1.0f : 0.0f;
   return true;
}

void ra_vision_gun_stop(void)
{
   /* The provider and its session are kept across immersive entries — ARKit
    * authorization and accessory loading are expensive and the accessory set
    * does not change with the space.  Only the published state is cleared, so
    * a core running outside 3D never sees a stale aim. */
   ra_gun_publish_idle();
   s_firstTracked = false;
   s_gmLogged     = false;
}

/* ------------------------------------------------------- auto-assign
 *
 * The tester, 2026-11-01: Duck Hunt with a Sense pair should just
 * work, with no Quick Menu trip — "but only for Duck Hunt; you don't want a
 * zapper for any other game".  So, on the MAIN thread (the frontend's own
 * thread; a 20 Hz main-queue timer, never dispatch_sync):
 *
 *   content loads in Mesen  AND  the ROM is Duck Hunt (CRC32, filename as a
 *   fallback)  AND  zapper.cfg zapper_auto != 0  AND  port 2 is at its default
 *   (device 1, no override/remap file naming input_libretro_device_p2)  AND  a
 *   Sense is connected (GameController: a Spatial Controller) or the mock pose
 *   source is on
 *     -> port 2 = Zapper (262) in RetroArch's settings, IN MEMORY ONLY (no
 *        SETTINGS_FLG_MODIFIED, so nothing is written to retroarch.cfg), and
 *        the core is told with core_set_controller_port_device() — the same
 *        two steps the menu's Device Type entry takes, minus the cfg flag.
 *     -> port 1 stays the Standard Controller (Duck Hunt's mode select).
 *   content closes / different content loads
 *     -> port 2 goes back to what it was, if it is still our Zapper.
 *
 * Why GameController and not ra_vision_gun_active(): accessory TRACKING only
 * starts inside the immersive space (ra_vision_gun_start), while the content is
 * normally loaded in the 2D window first.  "A Spatial Controller is connected"
 * is the earliest true signal, and it is re-checked once a second while Duck
 * Hunt is loaded without one, so pairing after the load still assigns.
 *
 * Inert otherwise: no Sense and no mock = no setting touched, only a beacon.
 */

#include "configuration.h"
#include "runloop.h"
#include "paths.h"
#include "core.h"
#include "input/input_driver.h"
#include <encodings/crc32.h>
#include <strings.h>

/* ROM bytes of the loaded content (plain file or archive#entry), shared with
 * the 3dSen matcher.  RAVisionLayers.m. */
NSData *ra_vision_content_bytes(void);

#define RA_ZA_PORT    1u                                          /* port 2  */
#define RA_ZA_ZAPPER  RETRO_DEVICE_SUBCLASS(RETRO_DEVICE_POINTER, 0) /* 262 */

typedef struct { uint32_t crc; const char *name; } ra_za_dump_t;

/* From the libretro database the app ships (`Nintendo - Nintendo Entertainment
 * System.rdb`,, read-only).  Two CRC kinds are listed there and
 * both are checked:
 *   - headerless (".unh" rows): CRC32 of PRG+CHR with the iNES header and any
 *     trainer stripped — the No-Intro CRC, the same value keys the
 *     camera on (`3dsen: rom crc32 …`);
 *   - whole-file (".nes" rows): CRC32 of the file as dumped, header included.
 * Duck Hunt (World) is the Japan + USA cart.  The multicarts need the Zapper
 * for their Duck Hunt half.  Vs. / PlayChoice-10 boards are left out (other
 * hardware), as are hacks, translations and pirates. */
static const ra_za_dump_t k_ra_za_nointro[] = {
   { 0x24598791u, "Duck Hunt (World)" },
   { 0xD26EFD78u, "Super Mario Bros. + Duck Hunt (USA)" },
   { 0x91B4B1D7u, "Super Mario Bros. + Duck Hunt (Europe, Asia) (En)" },
   { 0x529B621Fu, "Super Mario Bros. + Duck Hunt + World Class Track Meet (USA)" },
   { 0x60E63537u, "Super Mario Bros. + Duck Hunt + World Class Track Meet (USA) (Rev 1)" },
   { 0x7C988C1Eu, "Super Mario Bros. + Duck Hunt + World Class Track Meet (USA) (Sample)" },
};
static const ra_za_dump_t k_ra_za_file[] = {
   { 0xE9F806A9u, "Duck Hunt (World).nes" },
   { 0xECF8416Fu, "Super Mario Bros. + Duck Hunt (USA).nes" },
   { 0x3BA2A66Bu, "Super Mario Bros. + Duck Hunt (Europe, Asia) (En).nes" },
   { 0x58ED1B5Cu, "Super Mario Bros. + Duck Hunt + World Class Track Meet (USA).nes" },
   { 0x6A904C74u, "Super Mario Bros. + Duck Hunt + World Class Track Meet (USA) (Rev 1).nes" },
   { 0x76EEF55Du, "Super Mario Bros. + Duck Hunt + World Class Track Meet (USA) (Sample).nes" },
   /* TOSEC rows of the same database */
   { 0x4644085Eu, "Duck Hunt (1984-04-21)(Nintendo).nes" },
   { 0x25B4AE21u, "Super Mario Bros. + Duck Hunt (1989)(Nintendo)(EU).nes" },
   { 0x666EE28Eu, "2-in-1 Super Mario Bros. + Duck Hunt (1988-11)(Nintendo)(US).nes" },
   { 0xA0B0DFC7u, "3-in-1 Super Mario Bros. + Duck Hunt + World Class Track Meet Rev PRG0 (1990-12)(Nintendo)(US).nes" },
   { 0x92CD88EFu, "3-in-1 Super Mario Bros. + Duck Hunt + World Class Track Meet Rev PRG1 (1990-12)(Nintendo)(US).nes" },
};

enum { RA_ZA_IDLE = 0, RA_ZA_ASSIGNED, RA_ZA_WAIT_SENSE, RA_ZA_DONE };

static dispatch_source_t s_za_timer;
static char      s_za_key[4096]; /* content path last evaluated, "" = none */
static int       s_za_state = RA_ZA_IDLE;
static unsigned  s_za_orig  = RETRO_DEVICE_JOYPAD;
static uint32_t  s_za_crc   = 0;
static bool      s_za_byname = false;
static unsigned  s_za_ticks = 0;

static void ra_za_read_cfg(int *zauto, int *mock)
{
   NSString *docs = [NSSearchPathForDirectoriesInDomains(
                        NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
   NSString *txt  = [NSString stringWithContentsOfFile:
                        [docs stringByAppendingPathComponent:@"RetroArch/system/zapper.cfg"]
                                              encoding:NSUTF8StringEncoding error:nil];
   const char *env;
   *zauto = 1;
   *mock  = 0;
   for (NSString *raw in [txt componentsSeparatedByCharactersInSet:
                             NSCharacterSet.newlineCharacterSet])
   {
      NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
      NSRange   eq   = [line rangeOfString:@"="];
      NSString *k, *v;
      if (!line.length || [line hasPrefix:@"#"] || eq.location == NSNotFound) continue;
      k = [[line substringToIndex:eq.location]
             stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
      v = [[line substringFromIndex:eq.location + 1]
             stringByTrimmingCharactersInSet:
                [NSCharacterSet characterSetWithCharactersInString:@" \t\""]];
      if      ([k isEqualToString:@"zapper_auto"]) *zauto = atoi(v.UTF8String);
      else if ([k isEqualToString:@"mock"])        *mock  = atoi(v.UTF8String);
   }
   if ((env = getenv("RA_GUN_MOCK")) && *env)
      *mock = atoi(env);
}

/* "Sense present": a Spatial Controller in GameController's roster, or the
 * mock pose source configured (the simulator has no Sense). */
static bool ra_za_sense_present(int mock, char *why, size_t cap)
{
   for (GCController *c in GCController.controllers)
      if ([c.productCategory isEqualToString:GCProductCategorySpatialController])
      {
         snprintf(why, cap, "Sense present: '%s'", c.vendorName.UTF8String ?: "?");
         return true;
      }
   if (mock > 0)
   {
      snprintf(why, cap, "Sense present: mock pose source, mock=%d", mock);
      return true;
   }
   snprintf(why, cap, "no Sense");
   return false;
}

/* The ROM is Duck Hunt?  0 = no, 1 = by CRC, 2 = by filename. */
static int ra_za_is_duck_hunt(const char *path, uint32_t *crc_out, const char **name)
{
   NSData *rom = ra_vision_content_bytes();
   uint32_t nointro = 0, whole = 0;
   size_t i;
   const char *env, *leaf;

   *name = NULL;
   if (rom.length > 16)
   {
      const uint8_t *b = (const uint8_t *)rom.bytes;
      size_t hdr = 0;
      if (b[0] == 'N' && b[1] == 'E' && b[2] == 'S' && b[3] == 0x1A)
         hdr = 16 + ((b[6] & 0x04) ? 512 : 0);
      if (hdr < rom.length)
         nointro = encoding_crc32(0, b + hdr, rom.length - hdr);
      whole = encoding_crc32(0, b, rom.length);
      *crc_out = nointro;
      for (i = 0; i < sizeof(k_ra_za_nointro) / sizeof(k_ra_za_nointro[0]); i++)
         if (k_ra_za_nointro[i].crc == nointro) { *name = k_ra_za_nointro[i].name; return 1; }
      for (i = 0; i < sizeof(k_ra_za_file) / sizeof(k_ra_za_file[0]); i++)
         if (k_ra_za_file[i].crc == whole) { *name = k_ra_za_file[i].name; return 1; }
      /* Test-only (simulator): RA3D_ZAPPER_AUTO_CRC=hex[,hex…] adds headerless
       * CRCs, so the CRC path can be proven without a Duck Hunt dump. */
      if ((env = getenv("RA3D_ZAPPER_AUTO_CRC")) && *env)
      {
         char buf[256], *tok, *save = NULL;
         strlcpy(buf, env, sizeof(buf));
         for (tok = strtok_r(buf, ", ", &save); tok; tok = strtok_r(NULL, ", ", &save))
            if ((uint32_t)strtoul(tok, NULL, 16) == nointro)
            { *name = "RA3D_ZAPPER_AUTO_CRC (test)"; return 1; }
      }
   }
   else
      *crc_out = 0;
   leaf = strrchr(path, '/');
   leaf = leaf ? leaf + 1 : path;
   if (strcasestr(leaf, "duck hunt"))
   {
      *name = "filename";
      return 2;
   }
   return 0;
}

/* Has the user configured port 2 for this content?  The live value first (any
 * non-default device: retroarch.cfg, the menu, an override already applied),
 * then the override and remap files RetroArch loaded for it — an explicit
 * `input_libretro_device_p2 = "1"` there counts too. */
static bool ra_za_user_port2(runloop_state_t *rs, settings_t *st, char *why, size_t cap)
{
   unsigned cur = input_config_get_device(RA_ZA_PORT);
   NSMutableArray<NSString *> *files = [NSMutableArray array];
   const char *base = path_get(RARCH_PATH_BASENAME);
   const char *core = rs->system.info.library_name;

   if (cur != RETRO_DEVICE_JOYPAD)
   {
      snprintf(why, cap, "port 2 set by the user: device %u%s", cur,
               cur == RA_ZA_ZAPPER ? " = Zapper already" : "");
      return true;
   }
   if (rs->name.remapfile && *rs->name.remapfile)
      [files addObject:@(rs->name.remapfile)];
   if (st && st->paths.directory_menu_config[0] && core && *core && base && *base)
   {
      NSString *dir  = [@(st->paths.directory_menu_config)
                          stringByAppendingPathComponent:@(core)];
      NSString *b    = @(base);
      NSString *game = b.lastPathComponent;
      NSString *cdir = b.stringByDeletingLastPathComponent.lastPathComponent;
      [files addObject:[dir stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"%s.cfg", core]]];
      if (cdir.length)
         [files addObject:[dir stringByAppendingPathComponent:
                             [cdir stringByAppendingPathExtension:@"cfg"]]];
      if (game.length)
         [files addObject:[dir stringByAppendingPathComponent:
                             [game stringByAppendingPathExtension:@"cfg"]]];
   }
   for (NSString *f in files)
   {
      NSString *txt = [NSString stringWithContentsOfFile:f encoding:NSUTF8StringEncoding
                                                   error:nil];
      for (NSString *raw in [txt componentsSeparatedByCharactersInSet:
                                NSCharacterSet.newlineCharacterSet])
      {
         NSString *line = [raw stringByTrimmingCharactersInSet:
                              NSCharacterSet.whitespaceCharacterSet];
         NSRange eq = [line rangeOfString:@"="];
         if (eq.location == NSNotFound || [line hasPrefix:@"#"]) continue;
         if ([[[line substringToIndex:eq.location]
                 stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
                isEqualToString:@"input_libretro_device_p2"])
         {
            snprintf(why, cap, "port 2 set by the user: input_libretro_device_p2 in %s",
                     f.lastPathComponent.UTF8String);
            return true;
         }
      }
   }
   return false;
}

static void ra_za_assign(const char *sense_why)
{
   settings_t *st = config_get_ptr();
   runloop_state_t *rs = runloop_state_get_ptr();
   retro_ctx_controller_info_t pad;
   if (!st || !rs || !rs->current_core.retro_set_controller_port_device)
      return;
   s_za_orig = input_config_get_device(RA_ZA_PORT);
   /* Direct store, not input_config_set_device(): that goes through
    * configuration_set_uint(), which flags the config modified and would let
    * a later save write our Zapper into the user's retroarch.cfg. */
   st->uints.input_libretro_device[RA_ZA_PORT] = RA_ZA_ZAPPER;
   pad.port   = RA_ZA_PORT;
   pad.device = RA_ZA_ZAPPER;
   core_set_controller_port_device(&pad);
   s_za_state = RA_ZA_ASSIGNED;
   ra_gun_beaconf("zapper: auto-assigned port 2 = Zapper (Duck Hunt %08X%s, Sense present) "
                  "— %s; was device %u, port 1 untouched (device %u); in memory only",
                  s_za_crc, s_za_byname ? " (by filename)" : "", sense_why, s_za_orig,
                  input_config_get_device(0));
}

static void ra_za_restore(const char *why)
{
   settings_t *st = config_get_ptr();
   runloop_state_t *rs = runloop_state_get_ptr();
   unsigned cur;
   if (s_za_state != RA_ZA_ASSIGNED || !st)
      return;
   s_za_state = RA_ZA_IDLE;
   cur = st->uints.input_libretro_device[RA_ZA_PORT];
   if (cur == s_za_orig)
   {
      /* The usual case: RetroArch's own core deinit already put every port
       * back (runloop.c -> input_remapping_restore_global_config(), which
       * restores RETRO_DEVICE_JOYPAD), so the next content was initialised
       * with port 2 = device 1 and there is nothing left to undo. */
      ra_gun_beaconf("zapper: auto-assign restored port 2 (device %u, %s; RetroArch's "
                     "core deinit had already reset it)", s_za_orig, why);
      return;
   }
   if (cur != RA_ZA_ZAPPER)
   {
      ra_gun_beaconf("zapper: auto-assign released (%s) — port 2 is device %u now, "
                     "not ours; left alone", why, cur);
      return;
   }
   st->uints.input_libretro_device[RA_ZA_PORT] = s_za_orig;
   /* A different game already got the Zapper at its controller init: tell the
    * core.  After a close there is no game, so the setting alone is enough. */
   if (rs && (rs->current_core.flags & RETRO_CORE_FLAG_GAME_LOADED)
          && rs->current_core.retro_set_controller_port_device)
   {
      retro_ctx_controller_info_t pad;
      pad.port   = RA_ZA_PORT;
      pad.device = s_za_orig;
      core_set_controller_port_device(&pad);
   }
   ra_gun_beaconf("zapper: auto-assign restored port 2 (device %u, %s)", s_za_orig, why);
}

static void ra_za_evaluate(const char *path)
{
   runloop_state_t *rs = runloop_state_get_ptr();
   settings_t *st = config_get_ptr();
   const char *core = rs ? rs->system.info.library_name : NULL;
   const char *name = NULL;
   char why[256];
   int zauto, mock, dh;

   s_za_state  = RA_ZA_DONE;
   s_za_crc    = 0;
   s_za_byname = false;
   if (!core || strcmp(core, "Mesen"))
      return;                                  /* silent: not the NES core */
   dh = ra_za_is_duck_hunt(path, &s_za_crc, &name);
   if (!dh)
   {
      ra_gun_beaconf("zapper: auto-assign: not Duck Hunt (crc32 %08X) — port 2 untouched",
                     s_za_crc);
      return;
   }
   s_za_byname = dh == 2;
   ra_za_read_cfg(&zauto, &mock);
   if (!zauto)
   {
      ra_gun_beaconf("zapper: auto-assign skipped (zapper_auto = 0 in zapper.cfg) — "
                     "Duck Hunt %08X%s", s_za_crc, s_za_byname ? " (by filename)" : "");
      return;
   }
   if (ra_za_user_port2(rs, st, why, sizeof(why)))
   {
      ra_gun_beaconf("zapper: auto-assign skipped (%s) — Duck Hunt %08X%s, not overridden",
                     why, s_za_crc, s_za_byname ? " (by filename)" : "");
      return;
   }
   if (!ra_za_sense_present(mock, why, sizeof(why)))
   {
      s_za_state = RA_ZA_WAIT_SENSE;
      ra_gun_beaconf("zapper: auto-assign skipped (no Sense) — Duck Hunt %08X%s [%s]; "
                     "assigns if one connects while it is loaded",
                     s_za_crc, s_za_byname ? " (by filename)" : "",
                     name ? name : "?");
      return;
   }
   ra_gun_beaconf("zapper: auto-assign: Duck Hunt identified by %s [%s]",
                  s_za_byname ? "filename" : "crc32", name ? name : "?");
   ra_za_assign(why);
}

static void ra_za_tick(void)
{
   runloop_state_t *rs = runloop_state_get_ptr();
   const char *cp = NULL;
   if (rs && (rs->current_core.flags & RETRO_CORE_FLAG_GAME_LOADED))
      cp = path_get(RARCH_PATH_CONTENT);
   if (!cp) cp = "";
   s_za_ticks++;

   /* bounded compare: a path longer than the key buffer must not look
    * "changed" on every tick (review) */
   if (strncmp(cp, s_za_key, sizeof(s_za_key) - 1))
   {
      ra_za_restore(*cp ? "different content loaded" : "content closed");
      strlcpy(s_za_key, cp, sizeof(s_za_key));
      s_za_state = RA_ZA_IDLE;
      if (*cp)
         ra_za_evaluate(cp);
      return;
   }
   if (s_za_state == RA_ZA_WAIT_SENSE && (s_za_ticks % 20) == 0)
   {
      char why[256];
      int zauto, mock;
      ra_za_read_cfg(&zauto, &mock);
      if (zauto && input_config_get_device(RA_ZA_PORT) == RETRO_DEVICE_JOYPAD
          && ra_za_sense_present(mock, why, sizeof(why)))
         ra_za_assign(why);
   }
   else if (s_za_state == RA_ZA_ASSIGNED
            && input_config_get_device(RA_ZA_PORT) != RA_ZA_ZAPPER)
   {
      s_za_state = RA_ZA_DONE;
      ra_gun_beaconf("zapper: auto-assign released — port 2 changed to device %u by the "
                     "user; it will not be restored", input_config_get_device(RA_ZA_PORT));
   }
}

void ra_vision_zapper_auto_start(void)
{
   if (s_za_timer)
      return;
   s_za_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                       dispatch_get_main_queue());
   dispatch_source_set_timer(s_za_timer, DISPATCH_TIME_NOW,
                             50 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
   dispatch_source_set_event_handler(s_za_timer, ^{ ra_za_tick(); });
   dispatch_resume(s_za_timer);
}

#endif /* RA_VISION_3D */
