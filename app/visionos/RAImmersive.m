/* RAImmersive.m — the visionOS stereoscopic render loop.
 *
 * CompositorServices vends per-eye Metal drawable textures plus the ARKit head
 * pose each frame; this file owns that loop, and the three depth planes the
 * Mesen core publishes are drawn as three world-locked quads at three
 * distances.  Each eye sees them from its own position through its own
 * asymmetric projection, so the sprite layers genuinely stand off the
 * background — that is where the stereo comes from, not from any camera.
 *
 * Loop shape follows Apple's CompositorServices pattern, and every
 * element is load-bearing: dedicated thread, pacing on the predicted optimal
 * input time, an ARKit device anchor on every drawable, depth cleared AND
 * written, a command queue created from the DRAWABLE's device, per-view
 * targeting driven by the view's texture map, and each view's own
 * rasterization rate map.
 */

#import "RAVision.h"

#if defined(RA_VISION_3D)

#import "ra3d_scene.h"

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <CompositorServices/CompositorServices.h>
#import <ARKit/ARKit.h>
#import <simd/simd.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <UIKit/UIKit.h>        /* scene/app deactivate notifications */
#include <os/lock.h>

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define RA3D_GEO_GPU_IMPLEMENTATION
#include "ra3d_geo_gpu.h"
#define RA3D_CAMSTORE_IMPLEMENTATION
#include "ra3d_camstore.h"      /* per-game camera file */
#include "ra3d_post.h"          /* Depth AO + SSR */

volatile int ra_imm_stop    = 0;
volatile int ra_imm_running = 0;
int          ra_imm_frames  = 0;

/* ------------------------------------------------------------ panel settings */
/* Rows, ranges and defaults are SETTINGS-SPEC-FROM-VKQUAKE.md's, not invented. */

static float s_dist      = 3.6f;   /* metres, head to panel            */
static float s_width     = 5.5f;   /* metres, full width               */
static float s_height    = 3.1f;   /* metres, full height              */
static float s_posHeight = 0.0f;   /* metres above eye level (signed)  */
static float s_stereo    = 1.0f;   /* 0 .. 3.2, 1.0 = tuned default    */
static float s_dimUser   = 0.8f;   /* raw slider value                 */
static float s_dim       = 0.0f;   /* perceptual, derived              */
static bool  s_feet      = true;   /* readout units only               */
static float s_aspect      = 4.0f / 3.0f;
static float s_planeAspect = 0.0f;   /* set by the core while layered */

/* Stereo Depth 100% separates adjacent planes by this fraction of the panel
 * distance.  A fraction rather than a fixed distance, so the effect survives
 * moving the screen: what the eyes actually judge is the vergence angle, and
 * that holds still if the spread scales with distance.
 *
 * Tuned by the number the session report prints: at the 3.6 m default this is
 * ~0.79 m between planes, which works out to ~17 arcmin of vergence difference
 * between the background and the near sprite layer.  Stereo perception starts
 * around 1 arcmin and the eyes start fighting to fuse past ~60, so this sits
 * in the strong-but-easy band.  0.10 was tried first and measured only 6.7
 * arcmin — real, but too timid to read as 3D. */
#define RA_STEREO_SPREAD_FRACTION 0.22f

#define RA_CLAMP(v, lo, hi) ((v) < (lo) ? (lo) : ((v) > (hi) ? (hi) : (v)))

void ra_vision_panel_set_distance(float m)        { s_dist      = RA_CLAMP(m,  1.0f, 8.0f);  }
void ra_vision_panel_set_width(float m)           { s_width     = RA_CLAMP(m,  1.2f, 8.0f);  }
void ra_vision_panel_set_height(float m)          { s_height    = RA_CLAMP(m,  1.0f, 6.0f);  }
void ra_vision_panel_set_position_height(float m) { s_posHeight = RA_CLAMP(m, -1.5f, 10.0f); }
void ra_vision_panel_set_stereo_depth(float p)    { s_stereo    = RA_CLAMP(p,  0.0f, 3.2f);  }
void ra_vision_panel_set_units_feet(bool feet)    { s_feet      = feet; }

void ra_vision_panel_set_dim(float d)
{
   s_dimUser = RA_CLAMP(d, 0.0f, 1.0f);
   /* Linear dimming "doesn't really get dark until 80%" on device; this keeps
    * the 0-100 slider feel but makes darkness arrive early. */
   s_dim     = 1.0f - powf(1.0f - s_dimUser, 2.2f);
}

float ra_vision_panel_distance(void)        { return s_dist; }
float ra_vision_panel_width(void)           { return s_width; }
float ra_vision_panel_height(void)          { return s_height; }
float ra_vision_panel_position_height(void) { return s_posHeight; }
float ra_vision_panel_stereo_depth(void)    { return s_stereo; }
float ra_vision_panel_dim(void)             { return s_dimUser; }
bool  ra_vision_panel_units_feet(void)      { return s_feet; }

void ra_vision_panel_defaults(void)
{
   s_dist = 3.6f; s_width = 5.5f; s_height = 3.1f;
   s_posHeight = 0.0f; s_stereo = 1.0f;
   ra_vision_panel_set_dim(0.8f);
}

/* ------------------------------------------------------------------ settings */

static NSString *const kDist   = @"ra3d.v2.distance";
static NSString *const kWidth  = @"ra3d.v2.width";
static NSString *const kHeight = @"ra3d.v2.height";
static NSString *const kPosH   = @"ra3d.v2.positionHeight";
static NSString *const kStereo = @"ra3d.v2.stereoDepth";
static NSString *const kDim    = @"ra3d.v2.dim";
static NSString *const kFeet   = @"ra3d.v2.unitsFeet";

void ra_vision_settings_load(void)
{
   NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
   ra_vision_panel_defaults();
   if ([d objectForKey:kDist])   ra_vision_panel_set_distance([d floatForKey:kDist]);
   if ([d objectForKey:kWidth])  ra_vision_panel_set_width([d floatForKey:kWidth]);
   if ([d objectForKey:kHeight]) ra_vision_panel_set_height([d floatForKey:kHeight]);
   if ([d objectForKey:kPosH])   ra_vision_panel_set_position_height([d floatForKey:kPosH]);
   if ([d objectForKey:kStereo]) ra_vision_panel_set_stereo_depth([d floatForKey:kStereo]);
   if ([d objectForKey:kDim])    ra_vision_panel_set_dim([d floatForKey:kDim]);
   if ([d objectForKey:kFeet])   ra_vision_panel_set_units_feet([d boolForKey:kFeet]);
}

void ra_vision_settings_save(void)
{
   NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
   [d setFloat:s_dist      forKey:kDist];
   [d setFloat:s_width     forKey:kWidth];
   [d setFloat:s_height    forKey:kHeight];
   [d setFloat:s_posHeight forKey:kPosH];
   [d setFloat:s_stereo    forKey:kStereo];
   [d setFloat:s_dimUser   forKey:kDim];
   [d setBool:s_feet       forKey:kFeet];
}

/* --------------------------------------------------------- aspect + geometry */

void ra_vision_3d_set_aspect(float dar, unsigned rotation)
{
   if (dar <= 0.01f || dar > 100.0f)
      return;
   if (rotation == 90 || rotation == 270)
      dar = 1.0f / dar;
   s_aspect = dar;
}

float ra_vision_3d_aspect(void) { return s_aspect; }

/* The flat-composite fallback renders at the panel's shape with a ~3840 long
 * edge — comfortably past the ~2x supersample sweet spot at any panel size. */
void ra_vision_3d_render_size(unsigned *w, unsigned *h)
{
   /* Render at the content's aspect — the panel letterboxes it into the
    * user's box, so rendering at the box aspect would waste pixels on bars. */
   float a = (s_aspect > 0.01f) ? s_aspect : (4.0f / 3.0f);
   unsigned rw, rh;
   if (a >= 1.0f) { rw = 3840;                           rh = (unsigned)(3840.0f / a + 0.5f); }
   else           { rw = (unsigned)(3840.0f * a + 0.5f); rh = 3840; }
   rw &= ~1u; rh &= ~1u;
   if (rw < 64) rw = 64;
   if (rh < 64) rh = 64;
   if (w) *w = rw;
   if (h) *h = rh;
}

void ra_vision_panel_render_size(unsigned *w, unsigned *h) { ra_vision_3d_render_size(w, h); }

/* --------------------------------------------------------------- world lock */

static bool          s_haveAnchor = false;
static simd_float4x4 s_frozenHead;

void ra_vision_panel_recenter(void) { s_haveAnchor = false; }

static simd_float4x4 ra_scale(float x, float y, float z)
{
   simd_float4x4 m = matrix_identity_float4x4;
   m.columns[0].x = x; m.columns[1].y = y; m.columns[2].z = z;
   return m;
}

/* The picture's half-extents in metres, i.e. the same fit the plane transform
 * applies. Pulled out so the shape mode can convert NES pixels to metres with
 * exactly the scale the panel already uses — a Z that drifted from X would put
 * the extrusion at a different depth than the geometry's own width implies. */
static void ra_panel_half(float *halfW, float *halfH)
{
   float boxW = s_width * 0.5f, boxH = s_height * 0.5f;
   float dar  = (s_planeAspect > 0.01f) ? s_planeAspect
              : ((s_aspect > 0.01f) ? s_aspect : (4.0f / 3.0f));
   float hw = boxW, hh = boxW / dar;
   if (hh > boxH) { hh = boxH; hw = boxH * dar; }
   if (halfW) *halfW = hw;
   if (halfH) *halfH = hh;
}

/* Place a plane at `dist` from the frozen head, on the panel's axis, and scale
 * it by dist/panelDist so every plane subtends the SAME angle from the head.
 * That keeps all three registered — the only thing differing between the eyes
 * is parallax, which is exactly the depth cue we want and nothing else. */
/* The unscaled basis: centre, axes and normal of the plane at `dist`, without
 * the ra_scale() the render applies.  Factored out so the spatial light gun
 * (RAVisionGun.m) can intersect the same plane the render draws — the aim and
 * the picture must come from ONE definition or the reticle points at a lie.
 * ra_plane_transform() below is exactly this plus ra_scale(halfW*k, halfH*k, 1),
 * i.e. the matrix it returns is unchanged from before the refactor. */
static void ra_plane_basis(simd_float4x4 head, float dist, float panelDist,
                           simd_float3 *pos_o, simd_float3 *right_o,
                           simd_float3 *up_o,  simd_float3 *normal_o,
                           float *k_o)
{
   simd_float3 headPos = head.columns[3].xyz;
   simd_float3 fwd     = -head.columns[2].xyz;
   float       len;

   fwd.y = 0.0f;                       /* level: the screen never pitches or rolls */
   len   = simd_length(fwd);
   fwd   = (len < 1e-4f) ? simd_make_float3(0, 0, -1) : fwd / len;

   float k = (panelDist > 1e-4f) ? (dist / panelDist) : 1.0f;

   simd_float3 pos = headPos + fwd * dist;
   pos.y += s_posHeight * k;

   simd_float3 normal = simd_normalize(headPos - pos);
   simd_float3 up     = simd_make_float3(0, 1, 0);
   simd_float3 right  = simd_normalize(simd_cross(up, normal));
   up                 = simd_cross(normal, right);

   if (pos_o)    *pos_o    = pos;
   if (right_o)  *right_o  = right;
   if (up_o)     *up_o     = up;
   if (normal_o) *normal_o = normal;
   if (k_o)      *k_o      = k;
}

static simd_float4x4 ra_plane_transform(simd_float4x4 head, float dist, float panelDist)
{
   simd_float3   pos, right, up, normal;
   float         k, halfW, halfH;
   simd_float4x4 m;

   ra_plane_basis(head, dist, panelDist, &pos, &right, &up, &normal, &k);

   m.columns[0] = simd_make_float4(right,  0.0f);
   m.columns[1] = simd_make_float4(up,     0.0f);
   m.columns[2] = simd_make_float4(normal, 0.0f);
   m.columns[3] = simd_make_float4(pos,    1.0f);

   /* Fit the picture INSIDE the width x height box the user sculpted, keeping
    * the system's own aspect (ra_panel_half above is the same computation this
    * used to inline — a console cannot re-render at the box's shape, so the box
    * is a bound and the tighter of width/height decides the size). */
   ra_panel_half(&halfW, &halfH);

   return simd_mul(m, ra_scale(halfW * k, halfH * k, 1.0f));
}

/* ============================================================= scene camera
 * 3dSenVR-style controller camera.
 *
 * 3dSenVR lets you fly around the diorama with the controller; the panel-locked
 * view we have shipped since .28 is only its default pose.  This is that camera,
 * expressed as ONE world-space matrix multiplied in front of every world-locked
 * thing the layered path draws — the four depth planes, the 3dSen geometry and
 * the Zapper's aim plane.  Nothing downstream knows it exists.
 *
 *     C = T(c + panx*right + pany*up) . Ryaw(world up) . Rpitch(panel right)
 *         . S(zoom) . T(-c)
 *
 * c is the panel centre, so the scene ORBITS the picture the user placed rather
 * than swinging around the room.  Yaw is about world +Y (never about the head's
 * own axis — the panel is level by construction, ra_plane_basis) and pitch is
 * about the panel's right axis, applied after the yaw, which is the standard
 * orbit composition: Rot(Ryaw*right, pitch) . Ryaw == Ryaw . Rot(right, pitch).
 *
 * Zoom is a uniform SCALE about the panel centre, not 3dSen's `Camera.Distance`
 * dolly.  Scaling keeps the panel centre — and
 * therefore the whole scene's vergence budget — where the user put it, so a
 * zoom cannot walk the picture into the viewer's face; a dolly can, and on a
 * head-mounted display that is a comfort bug, not a feature.  The magnification
 * is the same and the extrusion depth scales with it, which is what the eye
 * reads as "closer".
 *
 * WHO TOUCHES WHAT.  The pad is read on the EMULATOR thread, at the end of
 * cocoa_input_poll() (overlay 0064), through the mfi joypad driver's own state
 * — so the PSVR2 Sense pair synthesised by overlay 0068 drives the camera for
 * free, and no second GameController poll exists to disagree with RetroArch's.
 * That thread integrates and smooths, then publishes ONE seqlock snapshot; the
 * render thread reads it.  No locks, no dispatch, either way.
 */

typedef struct
{
   float   yaw, pitch;      /* degrees */
   float   zoom;            /* uniform scale about the panel centre */
   float   panx, pany;      /* metres, along the panel's right / up */
   uint8_t moved;           /* 0 => exactly identity; render skips the multiply */
} ra_cam_t;

static _Atomic uint32_t s_camSeq = 0;
static ra_cam_t         s_camSnap = { 0.0f, 0.0f, 1.0f, 0.0f, 0.0f, 0 };

/* Knobs, `camera_*` in 3dsen.cfg. Read once when
 * the immersive loop starts, so an edit costs a re-entry into 3D, not a build. */
/* The defaults match how 3dSenVR's camera feels: it turns at a FLAT 30 deg/s
 * off a stick treated as on/off past 0.34, zooms at about 37 %/s at the
 * default framing, and smooths everything with a 0.4 s time constant.
 * Ours is exponential in zoom rather than linear in distance so a step feels the
 * same at 0.4x as at 2.5x — ln(1.45) = 0.37/s reproduces 3dSen's rate at the
 * default framing.  Where ours differs (pan, the zoom curve) it is deliberate. */
static int   s_camMode       = 1;      /* 0 off, 1 auto (NES only), 2 always   */
static float s_camOrbitSpeed = 30.0f;  /* deg/s, 3dSen's rate                  */
static float s_camPanSpeed   = 1.2f;   /* m/s at full stick (3dSen has no pan) */
static float s_camZoomSpeed  = 1.45f;  /* zoom multiplier per second at full   */
static float s_camZoomMin    = 0.40f;
static float s_camZoomMax    = 2.50f;
static float s_camYawMin     = -80.0f, s_camYawMax   = 80.0f;
static float s_camPitchMin   = -80.0f, s_camPitchMax = 80.0f;
static float s_camPanMax     = 1.5f;
static float s_camDead       = 0.34f;  /* stick on/off threshold, as 3dSen    */
static float s_camSmooth     = 0.40f;  /* seconds; 3dSen's smoothing time     */
static int   s_camInvertY    = 0;
static int   s_camDigital    = 1;      /* 1 = 3dSen's on/off stick, 0 = analog */
static int   s_camSwapZoom   = 0;      /* 1 = 3dSen's own sense: L2 IN, R2 OUT */
/* `zoom_default` — the wall-panel 3D view starts this much tighter
 * than the panel the user placed (1.0 = `.44` and earlier). Applied in
 * ra_camera_matrix() on top of the user's/scripts' zoom, wall panel only while
 * the NES camera gate is on; LocalCam tables (Punch-Out fight, Ice Hockey rink)
 * keep their size. The user zoom range is rescaled so R2/L2 still reach
 * exactly [camera_zoom_min .. camera_zoom_max] effective. */
static float s_camZoomDefault = 1.25f;
/* the 3dSen geometry's light, `light_*` in the same 3dsen.cfg. */
static float                      s_lightDir[3]   = { RA3D_LIGHT_DIR_X, RA3D_LIGHT_DIR_Y,
                                                      RA3D_LIGHT_DIR_Z };
static float                      s_lightColor[3] = { 1.0f, 1.0f, 1.0f };
static float                      s_lightIntensity = RA3D_LIGHT_INTENSITY;
static float                      s_lightAmbient   = RA3D_LIGHT_AMBIENT;
/* 1 (default): a profile's own Light.Direction / Light.Color win over
 * light_dir / light_color, as 3dSen's _Setting_ deep-copy does; 0 ignores them. */
static int                        s_lightProfile   = 1;
/* 3dSen's background and screen clip, same 3dsen.cfg.
 *   sky_mode  0 = the old far plane in the backdrop colour (a wall when
 *               orbited), 1 = passthrough (no sky, the diorama floats in the
 *               room), 2 = surround (default): the eye pass CLEARS to the
 *               NES backdrop colour, unlit and infinite, so the whole view is
 *               the NES sky as in 3dSenVR. 1 and 2 also drop the backdrop
 *               plane's backdrop-colour pixels.
 *               3 = box (default): the sky is ONE unlit,
 *               opaque box in the backdrop colour (3dSen's palette)
 *               whose xy is exactly the `_View` rect the geometry is clipped
 *               to and whose z spans the geometry; only its far (inside)
 *               faces draw, so it never hides the diorama and its outline is
 *               one crisp convex silhouette. The clear is transparent (the
 *               room shows outside the box) and the backdrop plane is not
 *               drawn (the box replaces it, as 3dSen has no backdrop plane).
 *   view_clip 1 (default) = 3dSen's `_View` discard, 0 = off.
 *   clipping  "c0, c1, c2, c3" in 3dSen's own order (L, B, R, T — see
 *             ra3d_geo_view); overrides the profile's _Setting_.Clipping,
 *             which overrides 3dSen's default (0.1, 8.1, 8.1, 0.1). */
static int                        s_skyMode        = 3;
/* multisampling on the eye pass, `msaa` in 3dsen.cfg: 0 (off),
 * 2 or 4 (default, as 3dSenVR v2). Like 3dSenVR's it is fixed
 * when the immersive loop starts (pipelines are built then), so a change
 * applies on the next entry into 3D. The shadow pass stays single-sample. */
static int                        s_msaaCfg        = 4;
static NSUInteger                 s_msaaSamples    = 1;   /* resolved at pipeline build */
static int                        s_viewClip       = 1;
/* 3dSen's directional shadow, same 3dsen.cfg.
 *   shadows          1 (default) / 0
 *   shadow_strength  Light.shadowStrength, 0.8 (3dSen pins it)
 *   shadow_map_size  square depth map edge, 2048 (as 3dSen) */
static int                        s_shadows        = 1;
static float                      s_shadowStrength = RA3D_SHADOW_STRENGTH;
static int                        s_shadowMapSize  = (int)RA3D_SHADOW_MAP_SIZE;
static int                        s_clipCfgSet     = 0;
static float                      s_clipCfg[4]     = { RA3D_CLIP_DEFAULT_0, RA3D_CLIP_DEFAULT_1,
                                                       RA3D_CLIP_DEFAULT_2, RA3D_CLIP_DEFAULT_3 };
/* 3dSenVR v2's "Enhanced" style, same 3dsen.cfg, every key
 * default 0 (= v2's defaults, Classic):
 *   pixel_shadow  0/1     shadow lookups snapped to the voxel centre
 *   groove        0/2/4/8 voxel grooves every N voxels (v2 "Voxel Grid")
 *   bend_lr / bend_tb / arc_h   degrees, -180..180 (v2 "World curvature")
 *   arc_center    0 screen centre / 1 bottom edge (arc_h's pivot)
 *   bend_tess     backdrop / sky-box subdivisions while bending (32)
 * Parsed by ra3d_fx_cfg_parse (ra3d_geo_gpu.h); the frame's GPU copy is
 * s_fx, rebuilt by ra_geo_upload. */
static Ra3dFxCfg                  s_fxCfg;
static Ra3dGeoFx                  s_fx;

/* The render thread's verdict on whether a camera is meaningful this frame:
 * true only while a four-plane (NES) layered set is being drawn.  This is the
 * whole conflict story — the right stick and L2/R2 are dead inputs on an NES
 * pad but are C-buttons and Z on an N64 one, so on any core that is not the
 * NES the camera never claims them.  `camera_input = 2` overrides. */
static _Atomic int s_camGate = 0;

/* Emulator-thread-only integration state. */
static float  s_camTYaw = 0.0f, s_camTPitch = 0.0f, s_camTZoom = 1.0f;
static float  s_camWobAmp = 0.0f, s_camWobPer = 0.0f, s_camWobYaw = 0.0f, s_camWobPitch = 0.0f;
static double s_camWobT0 = 0.0;   /* harness: RA3D_CAM_WOBBLE */
static float  s_camTPanX = 0.0f, s_camTPanY = 0.0f;
static float  s_camSYaw = 0.0f, s_camSPitch = 0.0f, s_camSZoom = 1.0f;
static float  s_camSPanX = 0.0f, s_camSPanY = 0.0f;
static double s_camLast = 0.0;

/* Per-profile defaults, published by the profile loader (RAVisionLayers.m) from
 * the `.3dn` camera script's Start() constants where they are constants at all
 * — R6.  These become the RESET pose, so R3 returns to the profile's idea of
 * the shot rather than always to flat-on. */
static float s_camHomeYaw = 0.0f, s_camHomePitch = 0.0f, s_camHomeZoom = 1.0f;
/* a per-scene home pose the profile Lua asked for, handed from
 * the render thread to the emulator-thread integrator. The integrator moves
 * its TARGETS by (new home - old home) — the user's own orbit offset is kept
 * and the 0.4 s smoothing glides the rest — instead of snapping. */
static _Atomic uint32_t s_camHomeReq = 0;
static _Atomic float    s_camHomeReqYaw = 0.0f, s_camHomeReqPitch = 0.0f,
                        s_camHomeReqZoom = 1.0f;
static uint32_t         s_camHomeSeen = 0;      /* emulator thread only */

/* 3dSen's LocalCam ("floor" diorama — Ice Hockey, Punch-Out). In 3dSen
 * the camera orbits a screen laid as a floor:
 *     q = R(+Z, Rot.y) * R(+X, Rot.x), pos = q*(0,0,-D) + T,
 * no LookAt, so Rot.x = -55 views the floor from
 * 35 deg above it and Rot.y spins it about its own normal. Here the head is
 * fixed and the diorama moves, so the equivalent is: the NES screen
 * becomes a tabletop centred `localcam_dist` from the eye and
 * `localcam_height` below it, tilted about its right axis until the line of
 * sight meets it at 3dSen's angle (90 + Rot.x, plus the user's pitch), spun
 * about its own normal by the user's yaw, and sized to the user's panel's
 * angular width times 3dSen's Distance ratio (189.65 / Distance).
 *   localcam         0 = never (exactly), 1 = when the profile says
 *                    (default), 2 = every 3dSen profile (experiments)
 *   localcam_dist    metres, eye to the table centre (1.4)
 *   localcam_height  metres, table centre relative to the eye, negative =
 *                    below (-0.45)
 * The render thread decides per frame (ra_lc_update) and publishes the three
 * values below before the flag; the camera input reads only the flag and
 * s_lcElev0 for its pitch limits. */
static int            s_lcCfg    = 1;
static float          s_lcDist   = 1.4f;
static float          s_lcHeight = -0.45f;
static _Atomic int    s_lcActive = 0;
static _Atomic float  s_lcElev0  = 35.0f;   /* degrees above the floor, 90 + Rot.x */
static _Atomic float  s_lcFrame  = 1.0f;    /* 189.65 / profile Distance          */
/* the NES point on the line of sight — 3dSen's LocalCam camera
 * looks at Target + ((c0 - c2)/2, (c1 - c3)/2) (the target plus the Clipping
 * offset), Target (128, 120) in its 3dSen frame (+Y up), i.e.
 * NES (128 + (c0-c2)/2, 248 - 120 - (c1-c3)/2): Punch-Out (128, 168), the near
 * half of the ring; Ice Hockey (124, 124). `localcam_target = 0` = the screen
 * centre (earlier). */
static int            s_lcTarget = 1;
static _Atomic float  s_lcTx = 128.0f, s_lcTy = 120.0f;
/* `localcam_size = 1` sizes the table to 3dSen's own view of it
 * (one NES px = localcam_dist / Distance m), 0 = the earlier panel-relative
 * size; `localcam_near_min` (m) caps it so the near visible edge (s_lcNear,
 * NES y = min(240, 248 - Clipping[1])) stays that far from the eye. */
static int            s_lcSize = 1;
static float          s_lcNearMin = 0.8f;
static _Atomic float  s_lcNear = 240.0f;
#define RA_LC_DEFAULT_DISTANCE 189.653f     /* 104 / tan(35 deg), 3dSen's default  */
#define RA_LC_ELEV_MIN 5.0f                 /* never edge-on                       */

/* Pitch/yaw limits for the CURRENT mode. Under LocalCam pitch is an offset
 * from the profile's elevation, so its range is [5, 90] deg of elevation
 * (90 = straight down onto the floor, i.e. facing it), and yaw spins the
 * floor freely (3dSen's Rot.y is unbounded; +-180 covers every heading). */
static void ra_cam_limits(float *ymin, float *ymax, float *pmin, float *pmax)
{
   if (atomic_load_explicit(&s_lcActive, memory_order_relaxed))
   {
      float e0 = atomic_load_explicit(&s_lcElev0, memory_order_relaxed);
      *ymin = -180.0f; *ymax = 180.0f;
      *pmin = RA_LC_ELEV_MIN - e0; *pmax = 90.0f - e0;
      return;
   }
   *ymin = s_camYawMin;   *ymax = s_camYawMax;
   *pmin = s_camPitchMin; *pmax = s_camPitchMax;
}

static void ra_cam_publish(const ra_cam_t *c)
{
   uint32_t s = atomic_load_explicit(&s_camSeq, memory_order_relaxed);
   atomic_store_explicit(&s_camSeq, s + 1, memory_order_relaxed);
   atomic_thread_fence(memory_order_release);
   s_camSnap = *c;
   atomic_thread_fence(memory_order_release);
   atomic_store_explicit(&s_camSeq, s + 2, memory_order_release);
}

static ra_cam_t ra_cam_read(void)
{
   ra_cam_t idle = { 0.0f, 0.0f, 1.0f, 0.0f, 0.0f, 0 };
   int i;
   for (i = 0; i < 8; i++)
   {
      uint32_t a = atomic_load_explicit(&s_camSeq, memory_order_acquire);
      ra_cam_t t;
      uint32_t b;
      if (a == 0 || (a & 1u))
         continue;
      t = s_camSnap;
      atomic_thread_fence(memory_order_acquire);
      b = atomic_load_explicit(&s_camSeq, memory_order_acquire);
      if (a == b)
         return t;
   }
   return idle;
}

void ra_vision_camera_gate(bool on)
{
   atomic_store_explicit(&s_camGate, on ? 1 : 0, memory_order_relaxed);
}

void ra_vision_camera_reset(void)
{
   ra_cam_t c;
   s_camTYaw  = s_camSYaw  = s_camHomeYaw;
   s_camTPitch= s_camSPitch= s_camHomePitch;
   s_camTZoom = s_camSZoom = s_camHomeZoom;
   s_camTPanX = s_camSPanX = 0.0f;
   s_camTPanY = s_camSPanY = 0.0f;
   c.yaw = s_camSYaw; c.pitch = s_camSPitch; c.zoom = s_camSZoom;
   c.panx = 0.0f; c.pany = 0.0f;
   c.moved = (fabsf(c.yaw) > 0.01f || fabsf(c.pitch) > 0.01f
              || fabsf(c.zoom - 1.0f) > 0.001f) ? 1 : 0;
   ra_cam_publish(&c);
}

/* render thread -> integrator, see s_camHomeReq */
static void ra_vision_camera_request_home(float yaw, float pitch, float zoom)
{
   atomic_store_explicit(&s_camHomeReqYaw, yaw, memory_order_relaxed);
   atomic_store_explicit(&s_camHomeReqPitch, pitch, memory_order_relaxed);
   atomic_store_explicit(&s_camHomeReqZoom, zoom, memory_order_relaxed);
   atomic_fetch_add_explicit(&s_camHomeReq, 1u, memory_order_release);
}

void ra_vision_camera_set_home(float yaw, float pitch, float zoom)
{
   s_camHomeYaw   = RA_CLAMP(yaw,   s_camYawMin,   s_camYawMax);
   s_camHomePitch = RA_CLAMP(pitch, s_camPitchMin, s_camPitchMax);
   s_camHomeZoom  = RA_CLAMP(zoom,  s_camZoomMin,  s_camZoomMax);
}

bool ra_vision_camera_moved(void) { return ra_cam_read().moved != 0; }

/* ------------------------------------------------ per-game camera
 * The USER's camera (the integrator's targets less the home pose — the
 * profile's or the Lua-scripted one, — so a scripted LocalCam pose is
 * never baked in) is kept per game in system/3dsen/camera-state.cfg
 * (ra3d_camstore.h), keyed by the matched profile Id, else the ROM's CRC32.
 *
 *   load:  RAVisionLayers names the key when it picks a profile on 3D entry
 *          or a content change (render thread) -> a restore REQUEST, applied
 *          by the integrator on the emulator thread (the only writer of the
 *          targets), exactly like s_camHomeReq.
 *   save:  leaving 3D, a content change/close, and any scene or app
 *          deactivate/background notification (main thread) — the moments
 *          RetroArch itself flushes SRAM (applicationDidEnterBackground ->
 *          CMD_EVENT_SAVE_FILES), so a swipe-kill, which comes after
 *          background, loses nothing. Atomic write (tmp + fsync + rename).
 * s_camPersistLock guards the key and the file; it is held only across this
 * file's own I/O (a few hundred bytes), never across a dispatch. */
static int              s_camPersist = 1;            /* camera_persist knob */
/* RA3D_CAM (the simulator's no-gamepad pose) wins over a restore for this
 * entry; it is still SAVED on exit, which is how the sim exercises the file */
static int              s_camForced  = 0;
static os_unfair_lock   s_camPersistLock = OS_UNFAIR_LOCK_INIT;
static char             s_camKey[RA3D_CAMSTORE_KEY_MAX];
static int              s_camKeyHadEntry = 0;
static _Atomic uint32_t s_camRestoreReq = 0;
static uint32_t         s_camRestoreSeen = 0;        /* emulator thread only */
static _Atomic float    s_camRestore[5];             /* yaw pitch zoom panx pany */

static NSString *ra_cam_persist_path(void)
{
   NSString *docs = [NSSearchPathForDirectoriesInDomains(
                        NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
   return [docs stringByAppendingPathComponent:@"RetroArch/system/3dsen/camera-state.cfg"];
}

static void ra_cam_request_restore(const float off[5])
{
   int i;
   for (i = 0; i < 5; i++)
      atomic_store_explicit(&s_camRestore[i], off[i], memory_order_relaxed);
   atomic_fetch_add_explicit(&s_camRestoreReq, 1u, memory_order_release);
}

/* Lock held. Writes the current key's user camera, unless nothing new can
 * have happened since it was restored (the request is still unconsumed — the
 * camera never ran, e.g. a non-NES core) or the camera sits at home and the
 * file holds nothing for this game. */
static void ra_cam_persist_save_locked(const char *why)
{
   Ra3dCamStore *st;
   Ra3dCamEntry  e;
   NSString     *path;
   int           ok, bad = 0;
   if (!s_camPersist || !s_camKey[0])
      return;
   if (atomic_load_explicit(&s_camRestoreReq, memory_order_acquire) != s_camRestoreSeen)
      return;   /* restore not yet applied: the file already holds the truth */
   memset(&e, 0, sizeof(e));
   strncpy(e.key, s_camKey, sizeof(e.key) - 1);
   /* the integrator's TARGETS (what the user asked for; the smoothed pose
    * may still be gliding) — word-sized floats, a stale read is harmless */
   e.yaw   = s_camTYaw   - s_camHomeYaw;
   e.pitch = s_camTPitch - s_camHomePitch;
   e.zoom  = s_camHomeZoom > 0.0f ? s_camTZoom / s_camHomeZoom : 1.0f;
   e.panx  = s_camTPanX;
   e.pany  = s_camTPanY;
   if (!s_camKeyHadEntry && fabsf(e.yaw) < 0.01f && fabsf(e.pitch) < 0.01f
       && fabsf(e.zoom - 1.0f) < 0.001f && fabsf(e.panx) < 0.001f && fabsf(e.pany) < 0.001f)
      return;   /* never moved, nothing on file: don't grow it with no-ops */
   st = (Ra3dCamStore *)calloc(1, sizeof(*st));
   if (!st) return;
   path = ra_cam_persist_path();
   [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                           withIntermediateDirectories:YES attributes:nil error:NULL];
   ok = ra3d_camstore_load(st, path.fileSystemRepresentation, &bad)
     && ra3d_camstore_put(st, &e)
     && ra3d_camstore_save(st, path.fileSystemRepresentation);
   free(st);
   if (ok) s_camKeyHadEntry = 1;
   RA_BeaconMark([[NSString stringWithFormat:
      @"3dcam: %s yaw %.1f pitch %.1f zoom %.2f pan %.2f,%.2f for %s (%s)%s",
      ok ? "saved" : "save FAILED", (double)e.yaw, (double)e.pitch, (double)e.zoom,
      (double)e.panx, (double)e.pany, s_camKey, why,
      bad ? " — malformed lines dropped" : ""] UTF8String]);
}

/* Render thread: the game the camera now belongs to (an empty id and no crc
 * = none). Saves the previous game's camera first, then restores this one's
 * (or home, so a game never inherits the previous game's orbit). */
void ra_vision_camera_persist_key(const char *profile_id, unsigned crc, int have_crc,
                                  const char *why)
{
   char key[RA3D_CAMSTORE_KEY_MAX];
   if (!ra3d_camstore_key(key, profile_id, crc, have_crc))
      key[0] = 0;
   os_unfair_lock_lock(&s_camPersistLock);
   if (strcmp(key, s_camKey))
   {
      ra_cam_persist_save_locked(why);
      memcpy(s_camKey, key, sizeof(s_camKey));
      s_camKeyHadEntry = 0;
      if (s_camKey[0] && s_camPersist && s_camForced)
         RA_BeaconMark([[NSString stringWithFormat:
            @"3dcam: RA3D_CAM set — %s not restored (will be saved on exit)", s_camKey] UTF8String]);
      else if (s_camKey[0] && s_camPersist)
      {
         Ra3dCamStore *st = (Ra3dCamStore *)calloc(1, sizeof(*st));
         const Ra3dCamEntry *e = NULL;
         int bad = 0;
         if (st && ra3d_camstore_load(st, ra_cam_persist_path().fileSystemRepresentation, &bad))
            e = ra3d_camstore_find(st, s_camKey);
         if (e)
         {
            float off[5] = { e->yaw, e->pitch, e->zoom, e->panx, e->pany };
            s_camKeyHadEntry = 1;
            ra_cam_request_restore(off);
            RA_BeaconMark([[NSString stringWithFormat:
               @"3dcam: restored yaw %.1f pitch %.1f zoom %.2f pan %.2f,%.2f for %s "
                "(offset from home; camera-state.cfg)", (double)off[0], (double)off[1],
               (double)off[2], (double)off[3], (double)off[4], s_camKey] UTF8String]);
         }
         else
         {
            const float home[5] = { 0.0f, 0.0f, 1.0f, 0.0f, 0.0f };
            ra_cam_request_restore(home);
            RA_BeaconMark([[NSString stringWithFormat:
               @"3dcam: no saved camera for %s — home view%s", s_camKey,
               bad ? " (malformed lines in camera-state.cfg ignored)" : ""] UTF8String]);
         }
         free(st);
      }
      else if (s_camKey[0])
         RA_BeaconMark([[NSString stringWithFormat:
            @"3dcam: camera_persist = 0 — %s not restored or saved", s_camKey] UTF8String]);
   }
   os_unfair_lock_unlock(&s_camPersistLock);
}

/* Any thread: write the current game's camera now (deactivate/background). */
void ra_vision_camera_persist_flush(const char *why)
{
   os_unfair_lock_lock(&s_camPersistLock);
   ra_cam_persist_save_locked(why);
   os_unfair_lock_unlock(&s_camPersistLock);
}

static void ra_cam_persist_observe(void)
{
   static dispatch_once_t once;
   dispatch_once(&once, ^{
      NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
      /* queue nil: runs on the posting (main) thread, synchronously, before
       * the system may suspend the process */
      [nc addObserverForName:UISceneWillDeactivateNotification object:nil queue:nil
                  usingBlock:^(NSNotification *n) { ra_vision_camera_persist_flush("scene deactivate"); }];
      [nc addObserverForName:UISceneDidEnterBackgroundNotification object:nil queue:nil
                  usingBlock:^(NSNotification *n) { ra_vision_camera_persist_flush("scene background"); }];
      [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil
                  usingBlock:^(NSNotification *n) { ra_vision_camera_persist_flush("resign active"); }];
      [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil
                  usingBlock:^(NSNotification *n) { ra_vision_camera_persist_flush("background"); }];
   });
}

/* Reads `camera_*` out of the same Documents/RetroArch/system/3dsen/3dsen.cfg
 * the shape knobs come from.  Read HERE rather than in RAVisionLayers' loader
 * because the camera also applies in plain (no-profile) layered 3D, where that
 * loader never runs. */
void ra_vision_camera_load_cfg(void)
{
   NSString *docs = [NSSearchPathForDirectoriesInDomains(
                        NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
   NSString *path = [docs stringByAppendingPathComponent:
                        @"RetroArch/system/3dsen/3dsen.cfg"];
   NSData   *d    = [NSData dataWithContentsOfFile:path];

   s_camMode = 1; s_camOrbitSpeed = 30.0f; s_camPanSpeed = 1.2f;
   s_camZoomSpeed = 1.45f; s_camZoomMin = 0.40f; s_camZoomMax = 2.50f;
   s_camYawMin = -80.0f; s_camYawMax = 80.0f;
   s_camPitchMin = -80.0f; s_camPitchMax = 80.0f;
   s_camPanMax = 1.5f; s_camDead = 0.34f; s_camSmooth = 0.40f; s_camInvertY = 0;
   s_camDigital = 1; s_camSwapZoom = 0; s_camZoomDefault = 1.25f;
   s_camPersist = 1; s_camForced = 0;
   s_lightDir[0] = RA3D_LIGHT_DIR_X; s_lightDir[1] = RA3D_LIGHT_DIR_Y;
   s_lightDir[2] = RA3D_LIGHT_DIR_Z;
   s_lightColor[0] = s_lightColor[1] = s_lightColor[2] = 1.0f;
   s_lightIntensity = RA3D_LIGHT_INTENSITY; s_lightAmbient = RA3D_LIGHT_AMBIENT;
   s_lightProfile = 1;
   s_skyMode = 3; s_viewClip = 1; s_clipCfgSet = 0;
   s_msaaCfg = 4;
   s_shadows = 1; s_shadowStrength = RA3D_SHADOW_STRENGTH;
   s_shadowMapSize = (int)RA3D_SHADOW_MAP_SIZE;
   s_lcCfg = 1; s_lcDist = 1.4f; s_lcHeight = -0.45f;
   s_lcTarget = 1;
   s_lcSize = 1; s_lcNearMin = 0.8f;
   ra3d_fx_cfg_defaults(&s_fxCfg);
   if (d && d.length)
      ra3d_fx_cfg_parse(&s_fxCfg, (const char *)d.bytes, d.length);

   if (d && d.length)
   {
      char *copy = (char *)malloc(d.length + 1);
      if (copy)
      {
         char *line;
         memcpy(copy, d.bytes, d.length);
         copy[d.length] = 0;
         for (line = strtok(copy, "\r\n"); line; line = strtok(NULL, "\r\n"))
         {
            char *eq = strchr(line, '=');
            double v;
            if (!eq)
               continue;
            {  /* comment lines never set a knob (ra3d_knobs_parse agrees) */
               const char *ls = line;
               while (*ls == ' ' || *ls == '\t') ls++;
               if (*ls == '#' || *ls == ';') continue;
            }
            if (strstr(line, "localcam_dist"))   { s_lcDist   = (float)atof(eq + 1); continue; }
            if (strstr(line, "localcam_height")) { s_lcHeight = (float)atof(eq + 1); continue; }
            if (strstr(line, "localcam_target")) { s_lcTarget = atoi(eq + 1); continue; }
            if (strstr(line, "localcam_size"))   { s_lcSize   = atoi(eq + 1); continue; }
            if (strstr(line, "localcam_near_min")) { s_lcNearMin = (float)atof(eq + 1); continue; }
            if (strstr(line, "localcam"))        { s_lcCfg    = atoi(eq + 1); continue; }
            if (strstr(line, "sky_mode"))  { s_skyMode  = atoi(eq + 1); continue; }
            if (strstr(line, "msaa"))      { s_msaaCfg  = atoi(eq + 1); continue; }
            if (strstr(line, "shadow_strength")) { s_shadowStrength = (float)atof(eq + 1); continue; }
            if (strstr(line, "shadow_map_size")) { s_shadowMapSize  = atoi(eq + 1); continue; }
            if (strstr(line, "shadows"))         { s_shadows        = atoi(eq + 1); continue; }
            if (strstr(line, "view_clip")) { s_viewClip = atoi(eq + 1); continue; }
            if (strstr(line, "clipping"))
            {
               const char *val = eq + 1;
               float c[4];
               while (*val == ' ' || *val == '"') val++;
               if (sscanf(val, "%f , %f , %f , %f", &c[0], &c[1], &c[2], &c[3]) == 4)
               { memcpy(s_clipCfg, c, sizeof(c)); s_clipCfgSet = 1; }
               continue;
            }
            if (strstr(line, "light_"))
            {
               /* light_dir / light_color are "x, y, z" (quotes allowed);
                * light_dir is in 3dSen's own frame (+Y up) so a value can be
                * copied straight out of a profile or setting.cfg. */
               const char *val = eq + 1;
               float a = 0, b = 0, c = 0;
               while (*val == ' ' || *val == '"') val++;
               if (strstr(line, "light_dir"))
               { if (sscanf(val, "%f , %f , %f", &a, &b, &c) == 3)
                 { s_lightDir[0] = a; s_lightDir[1] = b; s_lightDir[2] = c; } }
               else if (strstr(line, "light_color"))
               { if (sscanf(val, "%f , %f , %f", &a, &b, &c) == 3)
                 { s_lightColor[0] = a; s_lightColor[1] = b; s_lightColor[2] = c; } }
               else if (strstr(line, "light_intensity")) s_lightIntensity = (float)atof(val);
               else if (strstr(line, "light_ambient"))   s_lightAmbient   = (float)atof(val);
               else if (strstr(line, "light_profile"))   s_lightProfile   = atoi(val);
               continue;
            }
            if (strstr(line, "zoom_default"))  /* also matches camera_zoom_default */
            { s_camZoomDefault = (float)atof(eq + 1); continue; }
            if (strstr(line, "camera_") == NULL)
               continue;
            v = atof(eq + 1);
            if      (strstr(line, "camera_input"))       s_camMode       = (int)v;
            else if (strstr(line, "camera_orbit_speed")) s_camOrbitSpeed = (float)v;
            else if (strstr(line, "camera_pan_speed"))   s_camPanSpeed   = (float)v;
            else if (strstr(line, "camera_zoom_speed"))  s_camZoomSpeed  = (float)v;
            else if (strstr(line, "camera_zoom_min"))    s_camZoomMin    = (float)v;
            else if (strstr(line, "camera_zoom_max"))    s_camZoomMax    = (float)v;
            else if (strstr(line, "camera_yaw_min"))     s_camYawMin     = (float)v;
            else if (strstr(line, "camera_yaw_max"))     s_camYawMax     = (float)v;
            else if (strstr(line, "camera_pitch_min"))   s_camPitchMin   = (float)v;
            else if (strstr(line, "camera_pitch_max"))   s_camPitchMax   = (float)v;
            else if (strstr(line, "camera_pan_max"))     s_camPanMax     = (float)v;
            else if (strstr(line, "camera_deadzone"))    s_camDead       = (float)v;
            else if (strstr(line, "camera_smooth"))      s_camSmooth     = (float)v;
            else if (strstr(line, "camera_invert_y"))    s_camInvertY    = (int)v;
            else if (strstr(line, "camera_digital"))     s_camDigital    = (int)v;
            else if (strstr(line, "camera_swap_zoom"))   s_camSwapZoom   = (int)v;
            else if (strstr(line, "camera_persist"))     s_camPersist    = (int)v;
         }
         free(copy);
      }
   }
   if (s_camZoomMin < 0.05f) s_camZoomMin = 0.05f;
   if (s_camZoomMax < s_camZoomMin) s_camZoomMax = s_camZoomMin;
   s_camDead   = RA_CLAMP(s_camDead,   0.0f, 0.9f);
   s_camSmooth = RA_CLAMP(s_camSmooth, 0.0f, 1.0f);
   if (!(s_camZoomDefault > 0.0f)) s_camZoomDefault = 1.0f;   /* also NaN */
   s_camZoomDefault = RA_CLAMP(s_camZoomDefault, 0.5f, 2.0f);
   s_camZoomDefault = RA_CLAMP(s_camZoomDefault, s_camZoomMin, s_camZoomMax);
   RA_BeaconMark([[NSString stringWithFormat:
      @"3dcam: zoom_default %.2f — wall-panel 3D starts %.0f %% tighter; "
       "LocalCam tables unchanged; R2/L2 effective range [%.2f..%.2f]",
      (double)s_camZoomDefault, (double)((s_camZoomDefault - 1.0f) * 100.0f),
      (double)s_camZoomMin, (double)s_camZoomMax] UTF8String]);

   RA_BeaconMark([[NSString stringWithFormat:
      @"3dcam: cfg — input=%d orbit=%.0f deg/s zoom=%.2f/s [%.2f..%.2f] "
       "pitch [%.0f..%.0f] yaw [%.0f..%.0f] pan=%.2f m/s max %.2f "
       "dead=%.2f smooth=%.3f invert_y=%d digital=%d swap_zoom=%d persist=%d",
      s_camMode, (double)s_camOrbitSpeed, (double)s_camZoomSpeed,
      (double)s_camZoomMin, (double)s_camZoomMax,
      (double)s_camPitchMin, (double)s_camPitchMax,
      (double)s_camYawMin, (double)s_camYawMax,
      (double)s_camPanSpeed, (double)s_camPanMax,
      (double)s_camDead, (double)s_camSmooth, s_camInvertY,
      s_camDigital, s_camSwapZoom, s_camPersist] UTF8String]);
   ra_cam_persist_observe();   /* once; save on deactivate/background */

   {
      Ra3dGeoLight lt;
      ra3d_geo_light(&lt, s_lightDir, s_lightColor, s_lightIntensity,
                     s_lightAmbient, 0);
      RA_BeaconMark([[NSString stringWithFormat:
         @"3dlight: cfg — dir(3dSen) %.3f,%.3f,%.3f -> L(NES world) %.3f,%.3f,%.3f "
          "color %.2f,%.2f,%.2f intensity %.2f -> linear %.3f,%.3f,%.3f ambient %.3f",
         (double)s_lightDir[0], (double)s_lightDir[1], (double)s_lightDir[2],
         (double)lt.dir.x, (double)lt.dir.y, (double)lt.dir.z,
         (double)s_lightColor[0], (double)s_lightColor[1], (double)s_lightColor[2],
         (double)s_lightIntensity, (double)lt.rgb.x, (double)lt.rgb.y, (double)lt.rgb.z,
         (double)lt.ambient] UTF8String]);
   }
   s_skyMode = RA_CLAMP(s_skyMode, 0, 3);
   RA_BeaconMark([[NSString stringWithFormat:
      @"3dsky: cfg — sky_mode=%d (%s) view_clip=%d clipping=%s %.2f,%.2f,%.2f,%.2f",
      s_skyMode, s_skyMode == 3 ? "box: one backdrop-colour box at the clip rect"
               : (s_skyMode == 2 ? "surround: clear to NES backdrop"
               (s_skyMode == 1 ? "passthrough" : "far plane (earlier)")),
      s_viewClip, s_clipCfgSet ? "cfg" : "profile-or-default",
      (double)s_clipCfg[0], (double)s_clipCfg[1], (double)s_clipCfg[2],
      (double)s_clipCfg[3]] UTF8String]);
   s_lcCfg    = RA_CLAMP(s_lcCfg, 0, 2);
   s_lcDist   = RA_CLAMP(s_lcDist, 0.5f, 6.0f);
   s_lcHeight = RA_CLAMP(s_lcHeight, -0.9f * s_lcDist, 0.9f * s_lcDist);
   s_lcNearMin = RA_CLAMP(s_lcNearMin, 0.3f, 3.0f);
   RA_BeaconMark([[NSString stringWithFormat:
      @"3dcam: localcam cfg — localcam=%d (%s) dist %.2f m height %+.2f m "
       "(sight %.1f deg below level) target=%d (%s) size=%d near_min %.2f m",
      s_lcCfg, s_lcCfg == 0 ? "off, only" : (s_lcCfg == 2 ? "forced on" : "profile"),
      (double)s_lcDist, (double)s_lcHeight,
      (double)(asinf(-s_lcHeight / s_lcDist) * (float)(180.0 / M_PI)),
      s_lcTarget, s_lcTarget ? "3dSen Target + clip offset" : "screen centre",
      s_lcSize, (double)s_lcNearMin] UTF8String]);
   RA_BeaconMark([[NSString stringWithFormat:
      @"3dfx: cfg — %s: pixel_shadow=%d groove=%d bend_lr=%.0f bend_tb=%.0f arc_h=%.0f "
       "arc_center=%d bend_tess=%d depth_ao=%d (strength %d radius %d quality %d) ",
      ra3d_fx_cfg_any(&s_fxCfg) ? "ENHANCED terms on" : "Classic (all off)",
      s_fxCfg.pixel_shadow, s_fxCfg.groove, (double)s_fxCfg.bend_lr, (double)s_fxCfg.bend_tb,
      (double)s_fxCfg.arc_h, s_fxCfg.arc_center, s_fxCfg.bend_tess, s_fxCfg.depth_ao,
      s_fxCfg.ao_strength, s_fxCfg.ao_radius, s_fxCfg.ao_quality] UTF8String]);
   {
      Ra3dFxView pv;
      memset(&pv, 0, sizeof(pv));
      ra3d_post_params(&s_fxCfg, &pv);
      RA_BeaconMark([[NSString stringWithFormat:
         @"3dpost: cfg — ao=%d (strength %d radius %d quality %d -> radius %.0f px, intensity %.2f, "
          "%.0f samples, 1/%.0f res) reflection=%d (shine %d clarity %d length %d quality %d -> "
          "length %.0f px, shine %.2f, %.0f steps, refine %.0f, 1/%.0f res) ",
         s_fxCfg.depth_ao, s_fxCfg.ao_strength, s_fxCfg.ao_radius, s_fxCfg.ao_quality,
         (double)pv.ao.x, (double)pv.ao.y, (double)pv.ao.z, (double)pv.ao.w,
         s_fxCfg.reflection, s_fxCfg.ssr_shine, s_fxCfg.ssr_clarity, s_fxCfg.ssr_length,
         s_fxCfg.ssr_quality, (double)pv.ssr.x, (double)pv.ssr.z, (double)pv.ssr.w,
         (double)pv.ssrQ.z, (double)pv.ssrQ.w] UTF8String]);
   }
   s_shadowStrength = RA_CLAMP(s_shadowStrength, 0.0f, 1.0f);
   s_shadowMapSize  = RA_CLAMP(s_shadowMapSize, 256, 8192);
   RA_BeaconMark([[NSString stringWithFormat:
      @"3dshadow: cfg — shadows=%d strength=%.2f map=%d^2 depth32Float, point compare 1 tap, "
       "depth bias %.3f px + raster (1,1), normal bias %.3f x texel",
      s_shadows, (double)s_shadowStrength, s_shadowMapSize,
      (double)RA3D_SHADOW_DEPTH_BIAS, (double)RA3D_SHADOW_NORMAL_BIAS] UTF8String]);
   ra_vision_camera_reset();
   /* Harness knob: drive the camera with no gamepad at all, so the simulator
    * (which has neither a pad nor a steerable viewpoint) can still photograph
    * an orbited, zoomed scene.  "yaw,pitch,zoom" in degrees / multiplier. */
   {
      const char *e = getenv("RA3D_CAM");
      if (e && *e)
      {
         float y = 0.0f, p = 0.0f, z = 1.0f;
         if (sscanf(e, "%f,%f,%f", &y, &p, &z) >= 2)
         {
            ra_cam_t c;
            s_camTYaw  = s_camSYaw  = RA_CLAMP(y, s_camYawMin,   s_camYawMax);
            s_camTPitch= s_camSPitch= RA_CLAMP(p, s_camPitchMin, s_camPitchMax);
            s_camTZoom = s_camSZoom = RA_CLAMP(z, s_camZoomMin,  s_camZoomMax);
            c.yaw = s_camSYaw; c.pitch = s_camSPitch; c.zoom = s_camSZoom;
            c.panx = c.pany = 0.0f; c.moved = 1;
            ra_cam_publish(&c);
            s_camForced = 1;   /* no restore over it */
            {  /* harness: RA3D_CAM_WOBBLE="amp_deg,period_s" sways the
                * forced camera like a head that never holds still, so the
                * simulator can show view-dependent flicker. Inert unless set. */
               const char *w = getenv("RA3D_CAM_WOBBLE");
               float wa = 0.0f, wp = 0.0f;
               if (w && sscanf(w, "%f,%f", &wa, &wp) == 2 && wp > 0.05f)
               {
                  s_camWobAmp = wa; s_camWobPer = wp;
                  s_camWobYaw = s_camTYaw; s_camWobPitch = s_camTPitch;
                  s_camWobT0 = CACurrentMediaTime();
                  RA_BeaconMark([[NSString stringWithFormat:
                     @"3dcam: RA3D_CAM_WOBBLE %.2f deg every %.2f s", (double)wa, (double)wp] UTF8String]);
               }
            }
            RA_BeaconMark([[NSString stringWithFormat:
               @"3dcam: RA3D_CAM forced yaw %.1f pitch %.1f zoom %.2f",
               (double)c.yaw, (double)c.pitch, (double)c.zoom] UTF8String]);
         }
      }
   }
}

/* 3dSen's stick is an on/off switch, not a rate: past 0.34 it counts as
 * fully on and the camera turns at a flat 30 deg/s.  That IS the feel
 * people compare against, so it is the default; `camera_digital
 * = 0` gives the analog ramp instead, which is nicer and is not 3dSen. */
static float ra_cam_dead(float v)
{
   float d = s_camDead;
   if (s_camDigital)
      return (v > d) ? 1.0f : ((v < -d) ? -1.0f : 0.0f);
   if (v >  d) return (v - d) / (1.0f - d);
   if (v < -d) return (v + d) / (1.0f - d);
   return 0.0f;
}

/* Called once per frame from the END of cocoa_input_poll() (overlay 0064), on
 * the emulator thread, with the mfi joypad driver's own port-1 state.
 *   rx, ry  right stick, -1..1, +Y up
 *   l2, r2  analog triggers, 0..1
 *   modPan  L3 held: the right stick pans instead of orbiting
 *   reset   R3 edge: back to the profile's home pose
 * Inert unless the immersive loop is up AND the gate says the scene is an NES
 * four-plane set (or camera_input = 2). */
void ra_vision_camera_input(float rx, float ry, float l2, float r2,
                            bool modPan, bool reset)
{
   static bool  prevReset = false;
   double       now;
   float        dt, a;
   ra_cam_t     c;
   bool         gate;
   float        lymin, lymax, lpmin, lpmax;   /* mode-dependent */

   /* While a light gun is in play the triggers only fire; the grips zoom. */
   ra_vision_gun_zoom_remap(&l2, &r2);

   if (!ra_imm_running || s_camMode == 0)
   {
      s_camLast = 0.0;
      prevReset = false;
      return;
   }
   gate = (s_camMode >= 2)
        || atomic_load_explicit(&s_camGate, memory_order_relaxed) != 0;
   if (!gate)
   {
      s_camLast = 0.0;
      prevReset = false;
      return;
   }

   {  /* the Lua scene camera's new home, glided to */
      uint32_t req = atomic_load_explicit(&s_camHomeReq, memory_order_acquire);
      if (req != s_camHomeSeen)
      {
         float hy = RA_CLAMP(atomic_load_explicit(&s_camHomeReqYaw, memory_order_relaxed),
                             s_camYawMin, s_camYawMax);
         float hp = RA_CLAMP(atomic_load_explicit(&s_camHomeReqPitch, memory_order_relaxed),
                             s_camPitchMin, s_camPitchMax);
         float hz = RA_CLAMP(atomic_load_explicit(&s_camHomeReqZoom, memory_order_relaxed),
                             s_camZoomMin, s_camZoomMax);
         s_camHomeSeen = req;
         s_camTYaw   = RA_CLAMP(s_camTYaw   + (hy - s_camHomeYaw),   s_camYawMin,   s_camYawMax);
         s_camTPitch = RA_CLAMP(s_camTPitch + (hp - s_camHomePitch), s_camPitchMin, s_camPitchMax);
         s_camTZoom  = RA_CLAMP(s_camTZoom  * (hz / s_camHomeZoom),  s_camZoomMin,  s_camZoomMax);
         s_camHomeYaw = hy; s_camHomePitch = hp; s_camHomeZoom = hz;
      }
   }
   {  /* a saved per-game camera, as an offset from home, snapped to */
      uint32_t req = atomic_load_explicit(&s_camRestoreReq, memory_order_acquire);
      if (req != s_camRestoreSeen)
      {
         float ymin, ymax, pmin, pmax, o[5];
         int i;
         for (i = 0; i < 5; i++)
            o[i] = atomic_load_explicit(&s_camRestore[i], memory_order_relaxed);
         ra_cam_limits(&ymin, &ymax, &pmin, &pmax);
         s_camTYaw   = s_camSYaw   = RA_CLAMP(s_camHomeYaw + o[0],   ymin, ymax);
         s_camTPitch = s_camSPitch = RA_CLAMP(s_camHomePitch + o[1], pmin, pmax);
         s_camTZoom  = s_camSZoom  = RA_CLAMP(s_camHomeZoom * o[2],  s_camZoomMin, s_camZoomMax);
         s_camTPanX  = s_camSPanX  = RA_CLAMP(o[3], -s_camPanMax, s_camPanMax);
         s_camTPanY  = s_camSPanY  = RA_CLAMP(o[4], -s_camPanMax, s_camPanMax);
         s_camRestoreSeen = req;
      }
   }

   now = CACurrentMediaTime();
   dt  = (s_camLast > 0.0) ? (float)(now - s_camLast) : 0.0f;
   s_camLast = now;
   if (dt <= 0.0f || dt > 0.25f)      /* first frame, or a stall: no integration */
      dt = 0.0f;

   if (reset && !prevReset)
   {
      ra_vision_camera_reset();
      prevReset = true;
      return;
   }
   prevReset = reset;

   {
      float ymin, ymax, pmin, pmax;
      ra_cam_limits(&ymin, &ymax, &pmin, &pmax);
      lymin = ymin; lymax = ymax; lpmin = pmin; lpmax = pmax;
   }
   rx = ra_cam_dead(RA_CLAMP(rx, -1.0f, 1.0f));
   ry = ra_cam_dead(RA_CLAMP(ry, -1.0f, 1.0f));
   if (s_camInvertY) ry = -ry;
   l2 = RA_CLAMP(l2, 0.0f, 1.0f);
   r2 = RA_CLAMP(r2, 0.0f, 1.0f);

   if (dt > 0.0f)
   {
      if (modPan)
      {
         s_camTPanX = RA_CLAMP(s_camTPanX + rx * s_camPanSpeed * dt,
                               -s_camPanMax, s_camPanMax);
         s_camTPanY = RA_CLAMP(s_camTPanY + ry * s_camPanSpeed * dt,
                               -s_camPanMax, s_camPanMax);
      }
      else
      {
         /* Push the stick RIGHT and the scene turns so you see its right side,
          * i.e. the camera walks left.  That is 3dSen's sense and every orbit
          * control's: the object follows the stick. */
         s_camTYaw   = RA_CLAMP(s_camTYaw   + rx * s_camOrbitSpeed * dt,
                                lymin, lymax);
         s_camTPitch = RA_CLAMP(s_camTPitch + ry * s_camOrbitSpeed * dt,
                                lpmin, lpmax);
      }
      /* Triggers are a RATE, not a position: R2 in, L2 out, exponential so a
       * step of zoom feels the same at 0.6x as at 2.5x. */
      if (r2 > 0.02f || l2 > 0.02f)
      {
         /* R2 in, L2 out — the brief's sense.  3dSenVR itself is the OTHER way
          * round (zoom-in is the LEFT trigger there); `camera_swap_zoom
          * = 1` is that, for anyone comparing the two side by side. */
         float rate = (s_camSwapZoom ? (l2 - r2) : (r2 - l2)) * dt;
         /* on the wall panel the matrix multiplies by zoom_default,
          * so bound the USER zoom so the effective one spans exactly
          * [min..max] — no dead trigger travel at either end. */
         float zs = (!atomic_load_explicit(&s_lcActive, memory_order_relaxed)
                     && atomic_load_explicit(&s_camGate, memory_order_relaxed))
                  ? s_camZoomDefault : 1.0f;   /* same condition as the matrix */
         s_camTZoom = RA_CLAMP(s_camTZoom * powf(s_camZoomSpeed, rate),
                               s_camZoomMin / zs, s_camZoomMax / zs);
      }
   }

   if (s_camWobPer > 0.0f)
   {  /* harness (RA3D_CAM_WOBBLE): a slow Lissajous sway, unsmoothed */
      double ph = (now - s_camWobT0) * 2.0 * M_PI / s_camWobPer;
      s_camTYaw   = s_camSYaw   = s_camWobYaw   + s_camWobAmp * (float)sin(ph);
      s_camTPitch = s_camSPitch = s_camWobPitch + 0.5f * s_camWobAmp * (float)sin(ph * 1.7 + 0.5);
   }
   a = (s_camSmooth > 0.001f && dt > 0.0f)
     ? (1.0f - expf(-dt / s_camSmooth)) : 1.0f;
   s_camSYaw   += (s_camTYaw   - s_camSYaw)   * a;
   s_camSPitch += (s_camTPitch - s_camSPitch) * a;
   s_camSZoom  += (s_camTZoom  - s_camSZoom)  * a;
   s_camSPanX  += (s_camTPanX  - s_camSPanX)  * a;
   s_camSPanY  += (s_camTPanY  - s_camSPanY)  * a;

   c.yaw   = s_camSYaw;   c.pitch = s_camSPitch; c.zoom = s_camSZoom;
   c.panx  = s_camSPanX;  c.pany  = s_camSPanY;
   c.moved = (fabsf(c.yaw) > 0.01f || fabsf(c.pitch) > 0.01f
           || fabsf(c.zoom - 1.0f) > 0.001f
           || fabsf(c.panx) > 0.001f || fabsf(c.pany) > 0.001f) ? 1 : 0;
   ra_cam_publish(&c);
}

static simd_float4x4 ra_axis_rotation(simd_float3 axis, float radians)
{
   simd_float4x4 m = matrix_identity_float4x4;
   float c = cosf(radians), s = sinf(radians), t = 1.0f - c;
   float x = axis.x, y = axis.y, z = axis.z;
   m.columns[0] = simd_make_float4(t*x*x + c,   t*x*y + s*z, t*x*z - s*y, 0.0f);
   m.columns[1] = simd_make_float4(t*x*y - s*z, t*y*y + c,   t*y*z + s*x, 0.0f);
   m.columns[2] = simd_make_float4(t*x*z + s*y, t*y*z - s*x, t*z*z + c,   0.0f);
   return m;
}

static simd_float4x4 ra_translation(simd_float3 v)
{
   simd_float4x4 m = matrix_identity_float4x4;
   m.columns[3] = simd_make_float4(v, 1.0f);
   return m;
}

/* The camera matrix for this frame, and (optionally) the rotation half alone —
 * the Zapper needs the rotation to turn the panel's axes and the full matrix to
 * move its centre, and must never see them disagree. */
static simd_float4x4 ra_camera_matrix(simd_float4x4 head, float *zoom_o,
                                      simd_float4x4 *rot_o)
{
   ra_cam_t      c = ra_cam_read();
   simd_float3   pos, right, up, normal;
   simd_float4x4 R, S, M;

   if (zoom_o) *zoom_o = 1.0f;
   if (rot_o)  *rot_o  = matrix_identity_float4x4;

   /* LocalCam — the panel becomes a tabletop. Built in the panel's
    * own axes (x right, y up = NES top, z = normal toward the head = the
    * extrusion side):
    *   Bp^T          world -> panel axes
    *   Rs  about z   the user's yaw spins the floor about its own normal
    *                 (3dSen's R(+Z, Rot.y)); -yaw for our camera's sense
    *   Rt  about x   -(90 - e): e = 90 leaves it facing the eye (3dSen's
    *                 Rot.x = 0, "straight down"), e = 35 lays it back so the
    *                 sight line meets it at 35 deg with the NES bottom edge
    *                 nearest, exactly 3dSen's Rot.x = -55
    *   Bl            panel axes -> the sight frame of the table centre
    * and a uniform scale about the centre, so the light and the shadow map
    * ("the centre" is 3dSen's camera target on the NES screen,
    * s_lcTx/Ty, which need not be the screen centre)
    * (both in the diorama frame) tilt with it untouched. */
   if (atomic_load_explicit(&s_lcActive, memory_order_acquire))
   {
      float e0    = atomic_load_explicit(&s_lcElev0, memory_order_relaxed);
      float frame = atomic_load_explicit(&s_lcFrame, memory_order_relaxed);
      float e     = RA_CLAMP(e0 + c.pitch, RA_LC_ELEV_MIN, 90.0f);
      simd_float3 headPos = head.columns[3].xyz, fwd = -head.columns[2].xyz, tgt, sd, nl, ul;
      float len, horiz, k;
      simd_float4x4 Bp = matrix_identity_float4x4, Bl = matrix_identity_float4x4, Rt, Rs;

      ra_plane_basis(head, s_dist, s_dist, &pos, &right, &up, &normal, NULL);
      {  /* the panel point of 3dSen's camera target is what
          * lands on the line of sight, not the panel centre */
         float hw = 1.0f, hh = 1.0f;
         float tx = atomic_load_explicit(&s_lcTx, memory_order_relaxed);
         float ty = atomic_load_explicit(&s_lcTy, memory_order_relaxed);
         ra_panel_half(&hw, &hh);
         pos = pos + right * (hw * (tx / 128.0f - 1.0f)) + up * (hh * (1.0f - ty / 120.0f));
      }
      fwd.y = 0.0f;
      len   = simd_length(fwd);
      fwd   = (len < 1e-4f) ? simd_make_float3(0, 0, -1) : fwd / len;
      horiz = sqrtf(fmaxf(s_lcDist * s_lcDist - s_lcHeight * s_lcHeight, 0.01f));
      tgt   = headPos + fwd * horiz + simd_make_float3(0.0f, s_lcHeight, 0.0f);
      sd    = simd_normalize(tgt - headPos);
      nl    = -sd;                                  /* toward the head        */
      ul    = simd_normalize(simd_cross(nl, right)); /* right is level already */

      Bp.columns[0] = simd_make_float4(right,  0.0f);
      Bp.columns[1] = simd_make_float4(up,     0.0f);
      Bp.columns[2] = simd_make_float4(normal, 0.0f);
      Bl.columns[0] = simd_make_float4(right,  0.0f);
      Bl.columns[1] = simd_make_float4(ul,     0.0f);
      Bl.columns[2] = simd_make_float4(nl,     0.0f);
      Rt = ra_axis_rotation(simd_make_float3(1, 0, 0),
                            -(90.0f - e) * (float)(M_PI / 180.0));
      Rs = ra_axis_rotation(simd_make_float3(0, 0, 1),
                            -c.yaw * (float)(M_PI / 180.0));
      R  = simd_mul(Bl, simd_mul(Rt, simd_mul(Rs, simd_transpose(Bp))));
      if (s_lcSize)
      {  /* 3dSen's own framing — the camera is Distance px from
          * its target, so one NES px is localcam_dist / Distance metres
          * (frame = 189.65 / Distance) and the table subtends what 3dSen's
          * view does (2 atan(128 / Distance): 68 deg Hockey, 60 deg
          * Punch-Out). Comfort floor: the near visible edge (s_lcNear, NES
          * y) never comes closer to the eye than localcam_near_min. */
         float hw = 1.0f, hh = 1.0f, mpp, L, Ld = s_lcDist, ce, se, f = s_lcNearMin;
         float ny = atomic_load_explicit(&s_lcNear, memory_order_relaxed);
         float ty = atomic_load_explicit(&s_lcTy, memory_order_relaxed);
         ra_panel_half(&hw, &hh);
         mpp = s_lcDist * frame / RA_LC_DEFAULT_DISTANCE;        /* metres per NES px */
         L   = fmaxf(ny - ty, 0.0f) * mpp;                         /* target -> near edge */
         ce  = cosf(e0 * (float)(M_PI / 180.0)); se = sinf(e0 * (float)(M_PI / 180.0));
         if (L > 0.0f && f > Ld * se && L * L + Ld * Ld - 2.0f * L * Ld * ce < f * f)
         {
            float Lmax = Ld * ce - sqrtf(fmaxf(f * f - Ld * Ld * se * se, 0.0f));
            if (Lmax > 0.0f) mpp *= Lmax / L;
         }
         k = mpp * 128.0f / hw * c.zoom;       /* panel: 256 px = 2 hw metres */
      }
      else  /* the user's panel's angular width at the table
             * distance, times 3dSen's Distance ratio */
         k = (s_lcDist / s_dist) * frame * c.zoom;
      S  = ra_scale(k, k, k);
      M  = simd_mul(ra_translation(tgt + right * c.panx + ul * c.pany),
                    simd_mul(R, simd_mul(S, ra_translation(-pos))));
      if (zoom_o) *zoom_o = k;
      if (rot_o)  *rot_o  = R;
      return M;
   }

   /* the wall panel's default framing is zoom_default tighter, only
    * while the NES camera gate is on (3dSen / four-plane NES 3D); SNES and
    * other layered content keep the exact identity. */
   {
      float zd = atomic_load_explicit(&s_camGate, memory_order_relaxed)
               ? s_camZoomDefault : 1.0f;
      c.zoom = RA_CLAMP(c.zoom * zd, s_camZoomMin, s_camZoomMax);
      if (fabsf(c.zoom - 1.0f) > 0.001f)
         c.moved = 1;
   }
   if (!c.moved)
      return matrix_identity_float4x4;

   ra_plane_basis(head, s_dist, s_dist, &pos, &right, &up, &normal, NULL);

   /* NEGATED on purpose.  `yaw` is the CAMERA's azimuth to the right and
    * `pitch` its elevation above the scene, which is how a person describes
    * an orbit; rotating the SCENE by the same signed angle would send the
    * near edge the wrong way (push the stick right, the right-hand side of
    * the picture must swing TOWARD you, i.e. the scene turns left). */
   R = simd_mul(ra_axis_rotation(simd_make_float3(0, 1, 0),
                                 -c.yaw * (float)(M_PI / 180.0)),
                ra_axis_rotation(right, -c.pitch * (float)(M_PI / 180.0)));
   S = ra_scale(c.zoom, c.zoom, c.zoom);

   M = simd_mul(ra_translation(pos + right * c.panx + up * c.pany),
                simd_mul(R, simd_mul(S, ra_translation(-pos))));

   if (zoom_o) *zoom_o = c.zoom;
   if (rot_o)  *rot_o  = R;
   return M;
}

/* decide LocalCam for this frame — render thread, once per frame,
 * before ra_camera_matrix(). Only a 3dSen shape-mode session (four-plane NES
 * set + a live profile) can be a floor; everything else is unchanged.
 *
 * the camera COMFORT RULE once the profile's Lua drives it:
 *   1. LocalCam may now change per scene (Punch-Out: floor only in the fight,
 *      Ice Hockey: only on the rink) — but a flip is applied only after the
 *      scripts' verdict has held for RA_LC_DEBOUNCE consecutive frames, so a
 *      one-frame scene misdetection never swings the world;
 *   2. the scripts' Camera.Rot / Distance become a HOME pose, and only when
 *      they CHANGE it (the scripts write it at scene changes): the floor's
 *      elevation and size glide there with 3dSen's own 0.4 s smoothing, the
 *      wall camera's home is moved under the user's own orbit offset
 *      (ra_vision_camera_request_home) — never a snap, never mid-scene;
 *   3. anything the user did with the stick is kept across all of it.
 * Without Lua (`lua = 0`, or no scripts) the verdict is the static
 * scrape, constant per load, exactly as before. */
#define RA_LC_DEBOUNCE 30
static void ra_lc_update(bool nesSet)
{
   static int s_lcLogged = -1, s_lcLogN = 0;
   static int s_lcHeld = -1, s_lcCand = -1, s_lcCandN = 0;
   static float s_lcE0g = -1.0f, s_lcFrameg = -1.0f, s_lcTxg = 128.0f, s_lcTyg = 120.0f;
   static uint32_t s_luaCamGen = 0xFFFFFFFFu;
   static double s_lcT = 0.0;
   int   on = 0, f = 0, want;
   float e0 = 90.0f, frame = 1.0f, rx = 0.0f, dd = 0.0f, tx = 128.0f, ty = 120.0f;
   int   lua = ra_vision_scene_lua_active();

   if (nesSet && s_lcCfg != 0 && ra_vision_scene_mode_on())
   {
      f = ra_vision_scene_profile_localcam(&rx, &dd);
      if ((f & 1) || s_lcCfg == 2)
      {
         on    = 1;
         /* a declared floor pose wins; a profile that turns LocalCam on with
          * no pose gets 3dSen's Rot.x = 0 (straight down); `localcam = 2` on
          * a profile with neither gets Ice Hockey's 35 deg */
         e0    = (rx < -1.0f) ? 90.0f + rx : ((f & 1) ? 90.0f : 35.0f);
         e0    = RA_CLAMP(e0, RA_LC_ELEV_MIN, 90.0f);
         frame = (dd > 1.0f) ? RA_LC_DEFAULT_DISTANCE / dd : 1.0f;
         if (s_lcTarget)
         {  /* 3dSen's camera target, from the SAME clip the
             * `_View` uses (cfg > scripts/profile > default; ra_geo_view_now) */
            float c[4], pc[4];
            memcpy(c, s_clipCfg, sizeof(c));
            if (!s_clipCfgSet && ra_vision_scene_profile_clipping(pc)) memcpy(c, pc, sizeof(c));
            tx = 128.0f + 0.5f * (c[0] - c[2]);
            ty = (float)(RA3D_UNITY_H - 120) - 0.5f * (c[1] - c[3]);
            tx = RA_CLAMP(tx, -256.0f, 512.0f);
            ty = RA_CLAMP(ty, -240.0f, 480.0f);
            atomic_store_explicit(&s_lcNear, fminf(240.0f, (float)RA3D_UNITY_H - c[1]),
                                  memory_order_relaxed);
         }
      }
   }
   /* (1) debounce a Lua-driven flip; entering/leaving the game is immediate */
   want = on;
   if (!lua || !nesSet || s_lcHeld < 0) { s_lcHeld = want; s_lcCandN = 0; }
   else if (want != s_lcHeld)
   {
      if (want != s_lcCand) { s_lcCand = want; s_lcCandN = 0; }
      if (++s_lcCandN >= RA_LC_DEBOUNCE) { s_lcHeld = want; s_lcCandN = 0; }
   }
   else s_lcCandN = 0;
   on = s_lcHeld;
   /* (2) the floor's pose glides (0.4 s) when the scripts move it */
   {
      double now = CACurrentMediaTime();
      float dt = (s_lcT > 0.0) ? (float)(now - s_lcT) : 0.0f, a;
      s_lcT = now;
      if (dt > 0.25f) dt = 0.25f;
      a = (lua && dt > 0.0f) ? 1.0f - expf(-dt / 0.4f) : 1.0f;
      if (!on || s_lcE0g < 0.0f || !lua)
      { s_lcE0g = e0; s_lcFrameg = frame; s_lcTxg = tx; s_lcTyg = ty; }
      else
      {
         s_lcE0g += (e0 - s_lcE0g) * a; s_lcFrameg += (frame - s_lcFrameg) * a;
         s_lcTxg += (tx - s_lcTxg) * a; s_lcTyg += (ty - s_lcTyg) * a;
      }
      e0 = s_lcE0g; frame = s_lcFrameg; tx = s_lcTxg; ty = s_lcTyg;
   }
   /* no scripts (lua = 0, other content): back to the plain identity home */
   if (!lua && s_luaCamGen != 0xFFFFFFFFu)
   {
      s_luaCamGen = 0xFFFFFFFFu;
      ra_vision_camera_request_home(0.0f, 0.0f, 1.0f);
   }
   /* (2) the wall camera's home from the scripts, applied only on a change */
   if (lua && nesSet)
   {
      float cr[3], cd = 0.0f; uint32_t gen = 0;
      if (ra_vision_scene_lua_camera(cr, &cd, &gen) && gen != s_luaCamGen)
      {
         s_luaCamGen = gen;
         if (!(f & 1))
         {  /* 3dSen's reset pose (0.81, 0.81, 189.65) is our identity */
            float hp = cr[0] - 0.81f, hy = -(cr[1] - 0.81f);
            float hz = (cd > 1.0f) ? RA_LC_DEFAULT_DISTANCE / cd : 1.0f;
            ra_vision_camera_request_home(hy, hp, hz);
            if (s_lcLogN < 32)
            {
               s_lcLogN++;
               RA_BeaconMark([[NSString stringWithFormat:
                  @"3dcam: lua home — Camera.Rot %.1f,%.1f Distance %.1f -> yaw %.1f pitch %.1f "
                   "zoom %.3f (gliding, user offset kept)", (double)cr[0], (double)cr[1],
                  (double)cd, (double)hy, (double)hp, (double)hz] UTF8String]);
            }
         }
      }
   }
   if (on)
   {
      atomic_store_explicit(&s_lcElev0, e0,    memory_order_relaxed);
      atomic_store_explicit(&s_lcFrame, frame, memory_order_relaxed);
      atomic_store_explicit(&s_lcTx,    tx,    memory_order_relaxed);
      atomic_store_explicit(&s_lcTy,    ty,    memory_order_relaxed);
   }
   atomic_store_explicit(&s_lcActive, on, memory_order_release);
   ra_vision_scene_set_localcam(on);

   if (on != s_lcLogged && s_lcLogN < 16)
   {
      s_lcLogged = on; s_lcLogN++;
      RA_BeaconMark([[NSString stringWithFormat:
         @"3dcam: localcam %s — profile flags 0x%02x Rot.x %.1f -> elevation %.1f deg, "
          "Distance %.1f -> frame x%.3f, table %.2f m / %+.2f m, target NES %.1f,%.1f",
         on ? "ON" : "off", f, (double)rx, (double)e0, (double)dd, (double)frame,
         (double)s_lcDist, (double)s_lcHeight, (double)tx, (double)ty] UTF8String]);
   }
}

/* The panel the light gun aims at: always the plane at s_dist, which is where
 * the background sits and where the 3dSen extrusion is based.  Never the nearest sprite plane — Mesen's light
 * sensor tests a 2D pixel, and this plane is the one that does not move when
 * the Stereo Depth slider does. */
void ra_vision_panel_plane(simd_float4x4 head,
                           simd_float3 *pos, simd_float3 *right,
                           simd_float3 *up,  simd_float3 *normal,
                           float *halfW, float *halfH)
{
   simd_float3   p, r, u, n;
   float         hw, hh, zoom = 1.0f;
   simd_float4x4 rot, cam;

   ra_plane_basis(head, s_dist, s_dist, &p, &r, &u, &n, NULL);
   ra_panel_half(&hw, &hh);

   /* the scene camera moves this plane exactly as it moves the picture,
    * or the reticle points at a lie the moment the diorama is orbited.  The
    * rotation turns the axes, the full matrix moves the centre, and the zoom
    * is uniform so the half-extents just scale. */
   cam = ra_camera_matrix(head, &zoom, &rot);
   p   = simd_mul(cam, simd_make_float4(p, 1.0f)).xyz;
   r   = simd_mul(rot, simd_make_float4(r, 0.0f)).xyz;
   u   = simd_mul(rot, simd_make_float4(u, 0.0f)).xyz;
   n   = simd_mul(rot, simd_make_float4(n, 0.0f)).xyz;
   hw *= zoom;
   hh *= zoom;

   if (pos)    *pos    = p;
   if (right)  *right  = r;
   if (up)     *up     = u;
   if (normal) *normal = n;
   if (halfW)  *halfW  = hw;
   if (halfH)  *halfH  = hh;
}

/* the light gun on a bent world. As in 3dSen, the gun raycasts the BENT
 * plane and reads the unbent point, so the aim follows the picture. Room ray -> panel-local -> NES world
 * (the frame's Q) -> ra3d_bend_raycast against z = 0 (the background plane
 * the gun already uses). */
static uint32_t s_geoInstTotal;   /* defined with the geo state below */
/* s_fx is refreshed only while 3dSen geometry is uploaded; once the scene goes
 * flat, closes or leaves 3D it would keep the last frame's bend,
 * so the gun and reticle follow the bend only while bent geometry is live. */
bool ra_vision_fx_bend_active(void) { return s_fx.bend != 0u && s_geoInstTotal != 0u; }

static void ra_bend_room_to_nes(simd_float4x4 head, simd_float3 P, int isDir, float out[3])
{
   simd_float3 pos, right, up, normal;
   float hw, hh, hw0 = 1.0f, hh0 = 1.0f, zoom;
   ra_vision_panel_plane(head, &pos, &right, &up, &normal, &hw, &hh);
   ra_panel_half(&hw0, &hh0);
   zoom = hw0 > 1e-6f ? hw / hw0 : 1.0f;
   {
      simd_float3 rel = isDir ? P : P - pos;
      simd_float4 pl = simd_make_float4(simd_dot(rel, right) / (hw > 1e-6f ? hw : 1.0f),
                                        simd_dot(rel, up) / (hh > 1e-6f ? hh : 1.0f),
                                        simd_dot(rel, normal) / (zoom > 1e-6f ? zoom : 1.0f),
                                        isDir ? 0.0f : 1.0f);
      simd_float4 n = simd_mul(s_fx.Qi, pl);
      out[0] = n.x; out[1] = n.y; out[2] = n.z;
   }
}

int ra_vision_bend_ray(simd_float4x4 head, simd_float3 o, simd_float3 d, float plane_z,
                       float *u, float *v)
{
   float on[3], dn[3], flat[3], r;
   if (!ra_vision_fx_bend_active()) return 0;
   ra_bend_room_to_nes(head, o, 0, on);
   ra_bend_room_to_nes(head, d, 1, dn);
   r = sqrtf((on[0] - 128.0f) * (on[0] - 128.0f) + (on[1] - 120.0f) * (on[1] - 120.0f)
             + on[2] * on[2]);
   if (!ra3d_bend_raycast(&s_fx, on, dn, plane_z, 2.0f * r + 512.0f, flat)) return 0;
   *u = flat[0] / 256.0f;
   *v = flat[1] / 240.0f;
   return 1;
}

/* The reticle: where the unbent NES point (u, v) at z = 0 is drawn, as panel
 * su, sv in [-1, 1] and the depth along the panel normal in half-widths. */
int ra_vision_bend_reticle(float u, float v, float *su, float *sv, float *sz)
{
   float p[3] = { u * 256.0f, v * 240.0f, 0.0f }, hw0 = 1.0f, hh0 = 1.0f;
   simd_float4 q;
   if (!ra_vision_fx_bend_active()) return 0;
   ra3d_bend_forward(&s_fx, p);
   q = simd_mul(s_fx.Q, simd_make_float4(p[0], p[1], p[2], 1.0f));
   ra_panel_half(&hw0, &hh0);
   *su = q.x; *sv = q.y; *sz = hw0 > 1e-6f ? q.z / hw0 : 0.0f;
   return 1;
}

/* ---------------------------------------------------------------- pipelines */

static NSString *const kRAShader =
   @"#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct VOut { float4 pos [[position]]; float2 uv; };\n"
    /* Exact sRGB curves, shared by the planes and the 3dSen geometry (
     *). */
    "static float3 ra_srgb_dec(float3 c) {\n"
    "  return select(pow((c + 0.055) / 1.055, float3(2.4)), c / 12.92, c <= 0.04045);\n"
    "}\n"
    "static float3 ra_srgb_enc(float3 c) {\n"
    "  c = saturate(c);\n"
    "  return select(1.055 * pow(c, float3(1.0 / 2.4)) - 0.055, c * 12.92, c <= 0.0031308);\n"
    "}\n"
    /* 3dSenVR v2's Enhanced style (Ra3dGeoFx, ra3d_geo_gpu.h).
     * All zero = Classic, and every Enhanced term below is skipped. */
    "struct GeoFx { float4x4 Q; float4x4 Qi; float4 K; float4 fitScale; float4 fitShift;\n"
    "               float4 pivot; float zscale; float groove; float pixelShadow; uint bend;\n"
    "               uint backdrop; uint tess; uint pad0; uint pad1; };\n"
    /* the world-bend arc, matching 3dSen v2's curvature: sin(a)/k and (1-cos a)/k in
     * sinc form, 1 - x^2/6 under 1e-3; the depth clamped where w k > 0.95.
     * The normal turns by the arc angle a in the (u, w) plane. */
    "static float ra3d_sinc(float x) { return abs(x) < 0.001 ? 1.0 - x * x / 6.0 : sin(x) / x; }\n"
    "static void ra3d_arc(float k, float fs, float fsh, thread float& u, thread float& w,\n"
    "                     thread float& nu, thread float& nw) {\n"
    "  if (k == 0.0) return;\n"
    "  float a = u * k, h = 0.5 * a, sh = ra3d_sinc(h);\n"
    "  float wc = (w * k > 0.95) ? 0.95 / k : w;\n"
    "  float s = sin(a), c = cos(a);\n"
    "  float x = (1.0 - wc * k) * u * ra3d_sinc(a);\n"
    "  float z = u * h * sh * sh + wc * c;\n"
    "  u = fs * x; w = fs * (z - fsh);\n"
    "  float n0 = c * nu - s * nw; nw = s * nu + c * nw; nu = n0;\n"
    "}\n"
    /* the forward bend of a NES-world point and its normal. Bend space =
     * 3dSen's frame (+Y up, +Z in) about the screen centre, (128, 120, 0)
     * there = NES (128, 128, 0), depth scaled as displayed. */
    "static float3 ra3d_bend(constant GeoFx& fx, float3 p, thread float3& n) {\n"
    "  float bx = p.x - 128.0, by = 128.0 - p.y, bz = -p.z * fx.zscale;\n"
    "  float mx = n.x, my = -n.y, mz = -n.z / fx.zscale;\n"
    "  ra3d_arc(fx.K.x, fx.fitScale.x, fx.fitShift.x, bx, bz, mx, mz);\n"
    "  ra3d_arc(fx.K.y, fx.fitScale.y, fx.fitShift.y, by, bz, my, mz);\n"
    "  float w2 = fx.pivot.x - by, nw2 = -my;\n"
    "  ra3d_arc(fx.K.z, fx.fitScale.z, fx.fitShift.z, bx, w2, mx, nw2);\n"
    "  by = fx.pivot.x - w2; my = -nw2;\n"
    "  w2 = fx.pivot.y - bx; nw2 = -mx;\n"
    "  ra3d_arc(fx.K.w, fx.fitScale.w, fx.fitShift.w, by, w2, my, nw2);\n"
    "  bx = fx.pivot.y - w2; mx = -nw2;\n"
    "  n = float3(mx, -my, -mz * fx.zscale);\n"
    "  return float3(bx + 128.0, 128.0 - by, -bz / fx.zscale);\n"
    "}\n"
    "vertex VOut ra_vs(uint vid [[vertex_id]], constant float4x4& mvp [[buffer(0)]]) {\n"
    "  const float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };\n"
    "  VOut o; o.pos = mvp * float4(p[vid], 0.0, 1.0);\n"
    "  o.uv = float2((p[vid].x+1.0)*0.5, 1.0-(p[vid].y+1.0)*0.5);\n"
    "  return o;\n"
    "}\n"
    /* Game planes sample NEAREST: these are 256x240 NES images blown up onto a
     * wall-sized screen, and linear filtering turns crisp pixel art to mush.
     * Alpha 0 means the layer drew nothing there, so discard rather than blend
     * — blending would leave a dark fringe around every sprite.
     * the plane texture is BGRA8Unorm holding the frontend's sRGB-
     * ENCODED pixels; when the drawable takes linear (_sRGB/float — the same
     * ra_format_takes_linear() check uses) they are linearised here, or
     * the hardware encodes them a second time (SMB's sky went lavender). */
    /* `key` = (on, 0x00RRGGBB). With the sky as background (sky_mode
     * 1/2) the backdrop plane's pixels that ARE the frame's backdrop colour
     * are dropped — the sky is the clear colour / passthrough now, not a wall
     * — while any pixel that differs (a mid-frame backdrop change) still
     * draws. The comparison is on the 8-bit values the core wrote. */
    "fragment float4 ra_plane_fs(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],\n"
    "                            constant uint& decode [[buffer(0)]],\n"
    "                            constant uint2& key [[buffer(1)]]) {\n"
    "  constexpr sampler s(filter::nearest, address::clamp_to_edge);\n"
    "  float4 c = tex.sample(s, in.uv);\n"
    "  if (c.a < 0.5) discard_fragment();\n"
    "  if (key.x != 0u) {\n"
    "    uint3 k = uint3((key.y >> 16) & 0xFFu, (key.y >> 8) & 0xFFu, key.y & 0xFFu);\n"
    "    uint3 t = uint3(round(saturate(c.rgb) * 255.0));\n"
    "    if (all(t == k)) discard_fragment();\n"
    "  }\n"
    "  if (decode != 0u) c.rgb = ra_srgb_dec(c.rgb);\n"
    "  return float4(c.rgb, 1.0);\n"
    "}\n"
    /* The flat composite is the opposite case — a 3840-wide image minified onto
     * the panel — so it wants trilinear + anisotropic off its mip chain. */
    "fragment float4 ra_flat_fs(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]],\n"
    "                           constant float& srgbDecode [[buffer(0)]]) {\n"
    "  constexpr sampler s(filter::linear, mip_filter::linear, max_anisotropy(16),\n"
    "                      address::clamp_to_edge);\n"
    "  float4 c = tex.sample(s, in.uv);\n"
    "  if (srgbDecode > 0.5) c.rgb = pow(c.rgb, float3(2.2));\n"
    "  return float4(c.rgb, 1.0);\n"
    "}\n"
    "vertex float4 ra_dim_vs(uint vid [[vertex_id]]) {\n"
    "  const float2 p[3] = { float2(-1,-3), float2(3,1), float2(-1,1) };\n"
    /* reverse-Z: the far plane is 0, so the room dimmer sits at
       0.0001, not 0.9999 — it must be BEHIND everything the pass draws. */
    "  return float4(p[vid], 0.0001, 1.0);\n"
    "}\n"
    "fragment float4 ra_dim_fs(constant float& dim [[buffer(0)]]) {\n"
    "  return float4(0.0, 0.0, 0.0, dim);\n"
    "}\n"
    /* the sky box. Panel-local corners (float4, w = 1) in
     * buffer 1, the panel's MVP in buffer 0; the colour is stored exactly as
     * the sky-2 clear colour is (linear when the target takes linear). */
    "vertex float4 ra_sky_vs(uint vid [[vertex_id]], constant float4x4& mvp [[buffer(0)]],\n"
    "                        constant float4* p [[buffer(1)]]) {\n"
    "  return mvp * p[vid];\n"
    "}\n"
    /* alpha is the caller's — 1.0, or 254/255 to mark the box for the
     * AO / SSR post passes, which restore it to 1. */
    "fragment float4 ra_sky_fs(constant float4& c [[buffer(0)]]) {\n"
    "  return c;\n"
    "}\n"
    /* the sky box while bending — the same box (ALL six faces, panel-
     * local corners c0..c3 per face in buffer 1, the face's outward axis in
     * the order of ra_sky_box_build), subdivided T x T per face and bent with
     * the geometry, so it still frames it. Which faces are 'far' is no longer
     * one plane test per face (a bent face curves), so each vertex carries
     * dot(outward normal, eye - p) and the fragment keeps only the inside
     * (far) side. `eye` is the eye in panel-local space. */
    "struct SkyTV { float4 pos [[position]]; float facing; };\n"
    "vertex SkyTV ra_sky_tess_vs(uint vid [[vertex_id]], uint face [[instance_id]],\n"
    "                            constant float4x4& mvp [[buffer(0)]],\n"
    "                            constant float4* cs [[buffer(1)]],\n"
    "                            constant float4& eye [[buffer(2)]],\n"
    "                            constant GeoFx& fx [[buffer(11)]]) {\n"
    "  const uint2 kc[6] = { uint2(0,0), uint2(1,0), uint2(1,1), uint2(0,0), uint2(1,1), uint2(0,1) };\n"
    "  uint T = max(fx.tess, 1u), q = vid / 6u; uint2 c = kc[vid % 6u];\n"
    "  float s = float(q % T + c.x) / float(T), t = float(q / T + c.y) / float(T);\n"
    "  uint f = min(face, 5u);\n"
    "  float4 a = mix(cs[f * 4u + 0u], cs[f * 4u + 1u], s);\n"
    "  float4 b = mix(cs[f * 4u + 3u], cs[f * 4u + 2u], s);\n"
    "  float4 p = mix(a, b, t);\n"
    "  float3 on = float3(0.0); on[f >> 1] = (f & 1u) != 0u ? 1.0 : -1.0;\n"
    /* panel-local normal -> NES (Q^T), bend, -> panel (Qi^T) */
    "  float3 n = (transpose(fx.Q) * float4(on, 0.0)).xyz;\n"
    "  float3 q3 = ra3d_bend(fx, (fx.Qi * p).xyz, n);\n"
    "  float4 pb = fx.Q * float4(q3, 1.0);\n"
    "  float3 nb = (transpose(fx.Qi) * float4(n, 0.0)).xyz;\n"
    "  SkyTV o; o.pos = mvp * pb; o.facing = dot(nb, eye.xyz - pb.xyz);\n"
    "  return o;\n"
    "}\n"
    "fragment float4 ra_sky_tess_fs(SkyTV in [[stage_in]], constant float4& c [[buffer(0)]]) {\n"
    "  if (in.facing > 0.0) discard_fragment();\n"
    "  return c;\n"
    "}\n"
    /* ---- 3dSen shape mode (voxels) ---------------------
     * 3dSen's construction: every 8x8 tile is an 8x8xZ voxel grid, greedy-
     * meshed into boundary faces with flat normals (ra3d_vox.h). Meshes are
     * cached per tile content (or per region for the pattern-level fills) and
     * drawn as instanced PIECES: one instanced draw per distinct mesh, each
     * piece naming its instance (matrix, alpha), its cell (palette group) and
     * its origin inside the instance box. Colour-0 pixels are holes IN THE
     * MESH, so nothing here discards.
     *
     * Quads are 3dSen's mono-greedy merges: a vertex carries the PIXEL
     * coordinate of its corner in the instance's image (plus the quad's pixel
     * rectangle, flat), and the fragment shader point-samples the NES pixel
     * under the interpolated uv exactly as the old extrusion did — cell from
     * the uv, CHR from the cell, colour index from the atlas.
     *
     * LIGHTING is 3dSen's: Lambert with one directional light plus a
     * flat ambient, in LINEAR space — the palette entry is sRGB, linearised
     * before it is lit, and the result is encoded once on the way out (by the
     * hardware when the target is _sRGB/float, here when it is UNORM). The
     * normal is the face's flat normal carried into NES world by the
     * instance's normal matrix, so the light is fixed to the diorama and
     * turns with it under the scene camera, exactly as 3dSen's world light
     * does under its orbiting camera. */
    /* `invariant` — the translucent depth pre-pass and its colour
     * pass run this vertex function in two pipelines, and the colour pass's
     * GreaterEqual test must see bit-identical depth (preserveInvariance is
     * set on the library) */
    /* `lp` is the object-space voxel position (per-Tile3D, centred on the
     * tile, 3dSen's axes), `ln` its object-space normal; the Enhanced terms read
     * them, Classic ignores them. */
    "struct GeoV { float4 pos [[position, invariant]]; float2 uv; float3 n [[flat]];\n"
    "              float4 rect [[flat]]; uint iid [[flat]]; float2 wxy; float3 sc;\n"
    "              float3 lp; float3 ln [[flat]]; };\n"
    /* 3dSen's `_View` clip. `wxy` is the fragment's NES-world xy (px,
     * +Y down) — the diorama's own frame, before the panel transform and the
     * scene camera. ra3d_panel_to_nes_xy undoes ra3d_geo_world_to_panel's Q
     * (x/128 - 1, 1 - y/120); ra3d_view_outside is THE test, shared by the
     * colour pass and (next) the shadow pass, against the same GeoView. */
    "struct GeoView { float4 rect; uint on; uint3 pad; };\n"
    "static float2 ra3d_panel_to_nes_xy(float4 p) {\n"
    "  return float2((p.x + 1.0) * 128.0, (1.0 - p.y) * 120.0);\n"
    "}\n"
    "static bool ra3d_view_outside(float2 w, constant GeoView& vw) {\n"
    "  return vw.on != 0u && (w.x < vw.rect.x || w.y < vw.rect.y ||\n"
    "                         w.x > vw.rect.z || w.y > vw.rect.w);\n"
    "}\n"
    "struct GeoInst { float4x4 model; float alpha; uint cellOffset;\n"
    "                 uint gw; uint gh; float3x3 normal;\n"
    "                 uint flags; uint pad0; uint pad1; uint pad2; };\n"
    /* 3dSen's shadow map (Ra3dGeoShadow, ra3d_geo_gpu.h). The map
     * lives in the diorama frame: panel -> NES world (panelToNes) -> light
     * clip (nesToLight), so it is untouched by the camera. */
    "struct GeoShadow { float4x4 panelToNes; float4x4 nesToLight; float4 L;\n"
    "                   float depthBias; float normalBias; float strength; uint on;\n"
    "                   float4 pad; };\n"
    "struct VoxVert { packed_float3 p; uint packed; packed_float2 uv;\n"
    "                 packed_ushort4 rect; };\n"
    "struct VoxPiece { uint inst; uint cell; float ox; float oy; };\n"
    /* a vertex's unit-box normal. Greedy faces carry an axis
     * index (bits 0-2); a MARCHING triangle sets bit 3 and carries its own
     * normal as snorm8 x/y/z in bits 8-15/16-23/24-31 (ra3d_vox.h). */
    "static float3 ra3d_vox_normal(uint p) {\n"
    "  if ((p & 8u) != 0u)\n"
    "    return float3(float(int(p << 16) >> 24), float(int(p << 8) >> 24),\n"
    "                  float(int(p) >> 24)) / 127.0;\n"
    "  const float3 kN[6] = { float3(1,0,0), float3(-1,0,0), float3(0,1,0),\n"
    "                         float3(0,-1,0), float3(0,0,1), float3(0,0,-1) };\n"
    "  return kN[min(p & 7u, 5u)];\n"
    "}\n"
    "struct GeoLight { float4 dir; float4 rgb; float ambient; uint encode;\n"
    "                  float2 pad; };\n"
    "struct GeoCounts { uint inst; uint cell; };\n"
    "vertex GeoV ra_geo_vs(uint vid [[vertex_id]], uint iid [[instance_id]],\n"
    "                      const device VoxVert *verts [[buffer(0)]],\n"
    "                      const device GeoInst *insts [[buffer(1)]],\n"
    "                      constant float4x4* base [[buffer(2)]],\n"
    "                      const device VoxPiece *pieces [[buffer(3)]],\n"
    "                      constant GeoCounts& cnt [[buffer(4)]],\n"
    "                      constant GeoShadow& sh [[buffer(5)]],\n"
    "                      constant GeoFx& fx [[buffer(11)]]) {\n"
    /* a `device` read past the end is a GPU fault, and a GPU fault on
     * visionOS kills the process with nothing in the beacon. The draw ranges
     * and every index are exact by construction (ra3d_vox_build skips any
     * instance whose cells overrun); these clamps can only fire if a future
     * change breaks that, in which case a face is misplaced instead of the
     * app being gone. */
    "  VoxVert v = verts[vid]; VoxPiece pc = pieces[iid]; GeoV o;\n"
    "  uint ii = min(pc.inst, cnt.inst - 1u);\n"
    "  GeoInst gi = insts[ii];\n"
    "  float3 u = float3((pc.ox + v.p[0]) / float(gi.gw * 8u),\n"
    "                    (pc.oy + v.p[1]) / float(gi.gh * 8u), v.p[2]);\n"
    "  float4 pp = gi.model * float4(u, 1.0);\n"
    "  float3 vn = ra3d_vox_normal(v.packed);\n"
    "  o.wxy = ra3d_panel_to_nes_xy(pp);\n"
    "  o.n = gi.normal * vn;\n"
    /* 3dSen's object frame — x - 4 and 4 - y (Tile3D Center 4, y
     * flipped by SetUV's ~y & 7; the tile's offset is a multiple of 8, which
     * no groove size can see), z = voxels toward the screen; the Backdrop's
     * is its px offset from the video root (objPos x Size + Offset) */
    "  o.lp = float3(pc.ox + v.p[0] - 4.0, 4.0 - (pc.oy + v.p[1]),\n"
    "                -v.p[2] * float(gi.flags >> 16) * 0.0625);\n"
    "  if (fx.backdrop == ii + 1u) {\n"
    "    float3 q = (fx.Qi * pp).xyz;\n"
    "    o.lp = float3(q.x - 128.0, 128.0 - q.y, -q.z);\n"
    "  }\n"
    "  o.ln = float3(vn.x, -vn.y, -vn.z);\n"
    /* the bend on every non-UI vertex, `_View` (wxy) left unbent */
    "  if (fx.bend != 0u && (gi.flags & 8u) == 0u) {\n"
    "    float3 nn = o.n;\n"
    "    float3 q = ra3d_bend(fx, (fx.Qi * pp).xyz, nn);\n"
    "    o.n = nn; pp = fx.Q * float4(q, 1.0);\n"
    "  }\n"
    "  o.pos = base[(gi.flags & 8u) != 0u ? 1 : 0] * pp;\n"
    "  float2 org = float2(pc.ox, pc.oy);\n"
    "  o.uv = float2(v.uv) + org;\n"
    "  o.rect = float4(ushort4(v.rect)) + float4(org, org);\n"
    "  o.iid = ii;\n"
    /* receivers carry their light-clip position, no bias (only the
     * casters are biased); shadow-only/hidden instances are culled */
    "  o.sc = (sh.nesToLight * (sh.panelToNes * pp)).xyz;\n"
    "  if ((gi.flags & 4u) != 0u) o.pos = float4(0.0, 0.0, -1.0, 1.0);\n"
    /* a bent Backdrop is drawn by ra_geo_tess_vs (subdivided) */
    "  if (fx.bend != 0u && fx.backdrop == ii + 1u) o.pos = float4(0.0, 0.0, -1.0, 1.0);\n"
    "  return o;\n"
    "}\n"
    /* the Lua Backdrop while bending. Ours is ONE solid 8x8 tile
     * stretched to the backdrop's size (6 quads); 3dSen bends a 32x32-
     * subdivided cube. This draws the same unit box as
     * fx.tess x fx.tess quads per face (instance = face), through the same
     * fragment function: the uv lands inside the one solid tile, the rect is
     * that tile. */
    "vertex GeoV ra_geo_tess_vs(uint vid [[vertex_id]], uint face [[instance_id]],\n"
    "                           const device GeoInst *insts [[buffer(1)]],\n"
    "                           constant float4x4* base [[buffer(2)]],\n"
    "                           constant GeoCounts& cnt [[buffer(4)]],\n"
    "                           constant GeoShadow& sh [[buffer(5)]],\n"
    "                           constant GeoFx& fx [[buffer(11)]]) {\n"
    "  GeoV o;\n"
    "  uint ii = min(fx.backdrop - 1u, cnt.inst - 1u), T = max(fx.tess, 1u);\n"
    "  GeoInst gi = insts[ii];\n"
    "  const uint2 kc[6] = { uint2(0,0), uint2(1,0), uint2(1,1), uint2(0,0), uint2(1,1), uint2(0,1) };\n"
    "  uint q = vid / 6u; uint2 c = kc[vid % 6u];\n"
    "  float s = float(q % T + c.x) / float(T), t = float(q / T + c.y) / float(T);\n"
    "  uint ax = min(face >> 1, 2u); float sg = (face & 1u) != 0u ? -1.0 : 1.0;\n"
    "  float3 lo = float3(0.0, 0.0, -0.5), hi = float3(1.0, 1.0, 0.5), u;\n"
    "  uint a1 = (ax + 1u) % 3u, a2 = (ax + 2u) % 3u;\n"
    "  u[ax] = sg > 0.0 ? hi[ax] : lo[ax];\n"
    "  u[a1] = mix(lo[a1], hi[a1], s); u[a2] = mix(lo[a2], hi[a2], t);\n"
    "  float3 vn = float3(0.0); vn[ax] = sg;\n"
    "  float4 pp = gi.model * float4(u, 1.0);\n"
    "  o.wxy = ra3d_panel_to_nes_xy(pp);\n"
    "  o.n = gi.normal * vn;\n"
    "  { float3 q3 = (fx.Qi * pp).xyz; o.lp = float3(q3.x - 128.0, 128.0 - q3.y, -q3.z); }\n"
    "  o.ln = float3(vn.x, -vn.y, -vn.z);\n"
    "  if (fx.bend != 0u) {\n"
    "    float3 nn = o.n;\n"
    "    float3 q3 = ra3d_bend(fx, (fx.Qi * pp).xyz, nn);\n"
    "    o.n = nn; pp = fx.Q * float4(q3, 1.0);\n"
    "  }\n"
    "  o.pos = base[0] * pp;\n"
    "  o.uv = clamp(u.xy * 8.0, 0.5, 7.5);\n"
    "  o.rect = float4(0.0, 0.0, 8.0, 8.0);\n"
    "  o.iid = ii;\n"
    "  o.sc = (sh.nesToLight * (sh.panelToNes * pp)).xyz;\n"
    "  if (fx.backdrop == 0u || (gi.flags & 4u) != 0u) o.pos = float4(0.0, 0.0, -1.0, 1.0);\n"
    "  return o;\n"
    "}\n"
    /* the caster pass, as 3dSen's: casters (no NOCAST)
     * only, normal offset = normalBias x sin(N, L) against the normal,
     * then the 0.02 px linear depth bias in light-clip z; the raster slope
     * bias is on the encoder. The `_View` clip discards here too (3dSen's
     * casters do), so off-screen voxels cast nothing. */
    "struct ShV { float4 pos [[position]]; float2 wxy; };\n"
    "vertex ShV ra_shadow_vs(uint vid [[vertex_id]], uint iid [[instance_id]],\n"
    "                        const device VoxVert *verts [[buffer(0)]],\n"
    "                        const device GeoInst *insts [[buffer(1)]],\n"
    "                        const device VoxPiece *pieces [[buffer(3)]],\n"
    "                        constant GeoCounts& cnt [[buffer(4)]],\n"
    "                        constant GeoShadow& sh [[buffer(5)]],\n"
    "                        constant GeoFx& fx [[buffer(11)]]) {\n"
    "  VoxVert v = verts[vid]; VoxPiece pc = pieces[iid]; ShV o;\n"
    "  uint ii = min(pc.inst, cnt.inst - 1u);\n"
    "  GeoInst gi = insts[ii];\n"
    "  if ((gi.flags & 1u) != 0u) { o.pos = float4(0.0, 0.0, -1.0, 1.0); o.wxy = float2(0.0); return o; }\n"
    "  float3 u = float3((pc.ox + v.p[0]) / float(gi.gw * 8u),\n"
    "                    (pc.oy + v.p[1]) / float(gi.gh * 8u), v.p[2]);\n"
    "  float4 pp = gi.model * float4(u, 1.0);\n"
    "  float3 nes = (sh.panelToNes * pp).xyz;\n"
    "  float3 N = normalize(gi.normal * ra3d_vox_normal(v.packed));\n"
    /* v2's shadow casters bend too (every Enhanced vertex
     * program carries the arc) */
    "  if (fx.bend != 0u && (gi.flags & 8u) == 0u) { nes = ra3d_bend(fx, nes, N); N = normalize(N); }\n"
    "  float c = dot(N, sh.L.xyz);\n"
    "  nes -= N * (sh.normalBias * sqrt(saturate(1.0 - c * c)));\n"
    "  float4 lc = sh.nesToLight * float4(nes, 1.0);\n"
    "  lc.z += sh.depthBias;\n"
    "  o.pos = lc;\n"
    "  o.wxy = ra3d_panel_to_nes_xy(pp);\n"
    "  return o;\n"
    "}\n"
    "fragment void ra_shadow_fs(ShV in [[stage_in]], constant GeoView& vw [[buffer(5)]]) {\n"
    "  if (ra3d_view_outside(in.wxy, vw)) discard_fragment();\n"
    "}\n"
    "fragment float4 ra_geo_fs(GeoV in [[stage_in]],\n"
    "                          const device GeoInst *insts [[buffer(0)]],\n"
    "                          const device uint2 *cells [[buffer(1)]],\n"
    "                          constant uint *pal [[buffer(2)]],\n"
    "                          constant uint& cellCount [[buffer(3)]],\n"
    "                          constant GeoLight& lt [[buffer(4)]],\n"
    "                          constant GeoView& vw [[buffer(5)]],\n"
    "                          constant GeoShadow& sh [[buffer(6)]],\n"
    "                          const device uint *dtex [[buffer(7)]],\n"
    "                          constant uint& dtexCount [[buffer(8)]],\n"
    "                          const device uchar *atlas [[buffer(9)]],\n"
    "                          constant uint& atlasTiles [[buffer(10)]],\n"
    "                          constant GeoFx& fx [[buffer(11)]],\n"
    "                          depth2d<float> smap [[texture(1)]]) {\n"
    "  if (ra3d_view_outside(in.wxy, vw)) discard_fragment();\n"
    "  GeoInst gi = insts[in.iid];\n"
    "  float2 uv = clamp(in.uv, in.rect.xy + 0.01, in.rect.zw - 0.01);\n"
    "  uint ux = min(uint(max(uv.x, 0.0)), gi.gw * 8u - 1u);\n"
    "  uint uy = min(uint(max(uv.y, 0.0)), gi.gh * 8u - 1u);\n"
    /* exact by construction; the clamp only ever turns a future bug
     * into a wrong pixel instead of a GPU fault */
    "  uint2 c = cells[min(gi.cellOffset + (uy >> 3) * gi.gw + (ux >> 3), cellCount - 1u)];\n"
    "  uint chr = c.y & 0xFFFFu, ci = 0u;\n"
    "  uint flip = (c.x >> 24) & 0xFFu, palg = (c.x >> 16) & 0xFFu;\n"
    "  if (chr != 0xFFFFu && chr < atlasTiles) {\n"
    "    uint tx = ux & 7u, ty = uy & 7u;\n"
    "    if (flip & 1u) tx = 7u - tx;\n"
    "    if (flip & 2u) ty = 7u - ty;\n"
    "    ci = uint(atlas[chr * 64u + ty * 8u + tx]) & 3u;\n"
    "  }\n"
    "  if (gi.pad0 != 0u) palg = gi.pad0 - 1u;\n"
    "  uint e = pal[min(palg * 4u + ci, 67u)];\n"
    "  float3 rgb = float3(float((e >> 16) & 0xFFu), float((e >> 8) & 0xFFu),\n"
    "                      float(e & 0xFFu)) / 255.0;\n"
    /* a Pattern3D with a Direct-colour texture draws its
     * authored ARGB texel, not the palette, as 3dSen does.
     * 0 = no texel there: keep the palette. */
    /* with pad2 = the texture's width in tiles, the texel
     * comes from the texture tile the CELL names (c.y >> 16 = 1 + tile), so
     * a clipped or partial region reads the right block */
    "  if (gi.pad1 != 0u) {\n"
    "    uint di = gi.pad1 - 1u + uy * (gi.gw * 8u) + ux, d = 0u;\n"
    "    if (gi.pad2 != 0u) {\n"
    "      uint tc = c.y >> 16;\n"
    "      di = tc != 0u ? gi.pad1 - 1u + (((tc - 1u) / gi.pad2) * 8u + (uy & 7u)) * (gi.pad2 * 8u)\n"
    "                      + ((tc - 1u) % gi.pad2) * 8u + (ux & 7u) : 0xFFFFFFFFu;\n"
    "    }\n"
    "    d = di < dtexCount ? dtex[di] : 0u;\n"
    "    if (d != 0u) rgb = float3(float((d >> 16) & 0xFFu), float((d >> 8) & 0xFFu),\n"
    "                              float(d & 0xFFu)) / 255.0;\n"
    "  }\n"
    "  float3 N = normalize(in.n);\n"
    /* as in 3dSen: ONE tap, POINT comparison, no PCF, so
     * a shadow is binary per texel; outside the map counts as lit.
     * atten = lerp(1 - strength, 1, lit) scales the direct term only. */
    "  float atten = 1.0;\n"
    /* 3dSen's translucent material has NO shadow term — translucent (alpha < 1)
     * instances are lit, never shadowed */
    /* v2's Enhanced shading runs on OPAQUE non-UI shapes only (translucent
     * and UI shapes keep the Classic look) */
    "  bool spl = gi.alpha >= 0.999 && (gi.flags & 8u) == 0u;\n"
    "  if (sh.on != 0u && (gi.flags & 2u) == 0u && gi.alpha >= 0.999) {\n"
    "    float3 sc = in.sc;\n"
    /* pixel shadows (matching v2's Enhanced style): the
     * lookup moves to the voxel centre, floor(p) + 0.5, on the axes the face
     * does not face (|n| < 0.5), x fx.pixelShadow; the object-space shift
     * goes through objectToWorld, unbent, onto the (bent) world position.
     * Ours: 3dSen frame -> our voxel axes (x, -y, -z) -> unit box -> NES
     * world (panelToNes . model) -> light clip. The Backdrop's shader has
     * no such term. */
    "    if (fx.pixelShadow >= 0.5 && spl && fx.backdrop != in.iid + 1u) {\n"
    "      float3 an = abs(normalize(in.ln));\n"
    "      float3 dl = (floor(in.lp) + 0.5 - in.lp) * fx.pixelShadow;\n"
    "      dl = select(dl, float3(0.0), an >= 0.5);\n"
    "      float dz = float(gi.flags >> 16) * 0.0625;\n"
    "      float3 du = float3(dl.x / float(gi.gw * 8u), -dl.y / float(gi.gh * 8u),\n"
    "                         dz > 0.0 ? -dl.z / dz : 0.0);\n"
    "      float4 dn = sh.panelToNes * (gi.model * float4(du, 0.0));\n"
    "      sc += (sh.nesToLight * float4(dn.xyz, 0.0)).xyz;\n"
    "    }\n"
    "    float2 suv = float2(sc.x * 0.5 + 0.5, 0.5 - sc.y * 0.5);\n"
    "    if (all(suv >= 0.0) && all(suv <= 1.0) && sc.z <= 1.0) {\n"
    "      constexpr sampler ss(coord::normalized, filter::nearest, mip_filter::none,\n"
    "                           address::clamp_to_edge, compare_func::less_equal);\n"
    "      float s1 = smap.sample_compare(ss, suv, sc.z, level(0));\n"
    "      atten = mix(1.0 - sh.strength, 1.0, s1);\n"
    "    }\n"
    "  }\n"
    "  float3 alb = ra_srgb_dec(rgb);\n"
    /* voxel grooves (matching v2's Enhanced style; the Backdrop takes the
     * same N): fract(p / N) on the face's two
     * tangent axes (mask saturate(4 (1 - |n|))) gives the distance to the
     * cell edge, e; a 0.035 groove anti-aliased by the coarse derivative
     * (>= 0.002), a 0.035-0.2 bevel band, and a +-0.04..0.16 edge term that
     * lights the low edge and shades the high one. Faces with |n.z| >= 0.9
     * (object z = depth: the FRONT and back faces) take (0.38, 0.1), side
     * faces (0.62, 0.2). It scales the linear albedo, so the light,
     * shadow and ambient all see it. */
    "  if (fx.groove >= 0.5 && spl) {\n"
    "    float3 an = abs(normalize(in.ln));\n"
    "    float3 tm = saturate((1.0 - an) * 4.0);\n"
    "    float3 f = fract(in.lp / max(fx.groove, 1.0));\n"
    "    float3 d = tm * (min(f, 1.0 - f) - 1.0) + 1.0;\n"
    "    float e = min(min(d.x, d.y), d.z);\n"
    "    float w = max(abs(dfdx(e)) + abs(dfdy(e)), 0.002);\n"
    "    float groove = 1.0 - smoothstep(0.035 - w, 0.035 + w, e);\n"
    "    float bevel = smoothstep(0.035, 0.1, e) * (1.0 - smoothstep(0.1, 0.2, e));\n"
    "    float3 el = tm * (1.0 - smoothstep(0.04, 0.16, f));\n"
    "    float3 eh = tm * (1.0 - smoothstep(0.0, 0.12, 0.96 - f));\n"
    "    float edge = max(max(el.x, el.y), el.z) - max(max(eh.x, eh.y), eh.z);\n"
    "    float2 kk = an.z >= 0.9 ? float2(0.38, 0.1) : float2(0.62, 0.2);\n"
    "    alb *= (1.0 - groove * kk.x) + bevel * kk.y + edge * kk.y;\n"
    "  }\n"
    "  float3 lit = alb * (lt.rgb.xyz * atten * max(0.0, dot(N, lt.dir.xyz)) + lt.ambient);\n"
    "  if (lt.encode != 0u) lit = ra_srgb_enc(lit);\n"
    "  return float4(lit, gi.alpha);\n"
    "}\n";

static id<MTLRenderPipelineState> s_planePipe, s_flatPipe, s_dimPipe;
static id<MTLRenderPipelineState> s_skyPipe;
static id<MTLRenderPipelineState> s_skyTessPipe, s_geoTessPipe;
static id<MTLDepthStencilState>   s_depthWrite, s_depthAlways;

static void ra_geo_build_pipelines(id<MTLDevice> dev, id<MTLLibrary> lib,
                                   MTLPixelFormat color, MTLPixelFormat depth);
static bool ra_format_takes_linear(MTLPixelFormat f);
/* 1 when the drawable takes linear, so ra_plane_fs must linearise the
 * sRGB-encoded plane texels. Decided from the real format at pipeline build. */
static uint32_t s_planeDecode = 0;

/* ------------------------------------------------- MSAA
 * The eye pass renders into multisampled colour + depth and resolves into the
 * CompositorServices drawable's own textures (colour AND depth: the compositor
 * reprojects on the depth). The MSAA targets are memoryless where the device
 * allows it (they live in tile memory only: load = clear, store = resolve), so
 * one pair serves every view in turn; else private. They are sized to the
 * drawable's PHYSICAL texture, which is what a rasterization rate map renders
 * into. Depth resolves to the NEAREST sample — MAX under reverse-Z —
 * where supported, else sample 0. */
static id<MTLTexture>                 s_msaaColor, s_msaaDepth;
static BOOL                           s_msaaMemoryless = NO;
static MTLMultisampleDepthResolveFilter s_msaaDepthFilter = MTLMultisampleDepthResolveFilterSample0;

static void ra_msaa_resolve_config(id<MTLDevice> dev, MTLPixelFormat color, MTLPixelFormat depth)
{
   NSUInteger want = s_msaaCfg >= 4 ? 4 : (s_msaaCfg >= 2 ? 2 : 1);
   NSUInteger got  = want;
   while (got > 1 && ![dev supportsTextureSampleCount:got]) got >>= 1;
   s_msaaSamples = got;
   s_msaaColor = nil; s_msaaDepth = nil;
   s_msaaMemoryless = NO;
   if (@available(visionOS 1.0, *))
      s_msaaMemoryless = [dev supportsFamily:MTLGPUFamilyApple4];
   s_msaaDepthFilter = [dev supportsFamily:MTLGPUFamilyApple3]
                     ? MTLMultisampleDepthResolveFilterMax
                     : MTLMultisampleDepthResolveFilterSample0;
   RA_BeaconMark([[NSString stringWithFormat:
      @"3dmsaa: cfg msaa=%d -> %lu samples (%s; colour fmt %lu, depth fmt %lu, depth resolve %s)",
      s_msaaCfg, (unsigned long)got,
      got <= 1 ? "off, single-sample eye pass as before"
               : (s_msaaMemoryless ? "memoryless targets" : "private targets"),
      (unsigned long)color, (unsigned long)depth,
      s_msaaDepthFilter == MTLMultisampleDepthResolveFilterMax ? "max (nearest, reverse-Z)" : "sample 0"]
      UTF8String]);
}

/* The pair for this view's drawable textures; (re)made when the size or the
 * format changes. A memoryless texture that cannot be made falls back to
 * private once, for the rest of the session. nil => draw single-sample. */
static BOOL ra_msaa_targets(id<MTLDevice> dev, id<MTLTexture> color, id<MTLTexture> depth)
{
   if (s_msaaSamples <= 1 || !color) return NO;
   if (s_msaaColor && s_msaaColor.width == color.width && s_msaaColor.height == color.height
       && s_msaaColor.pixelFormat == color.pixelFormat
       && (!depth || (s_msaaDepth && s_msaaDepth.pixelFormat == depth.pixelFormat)))
      return YES;
   for (int attempt = 0; attempt < 2; attempt++)
   {
      MTLStorageMode sm = s_msaaMemoryless ? MTLStorageModeMemoryless : MTLStorageModePrivate;
      MTLTextureDescriptor *td = [MTLTextureDescriptor
         texture2DDescriptorWithPixelFormat:color.pixelFormat
                                      width:color.width height:color.height mipmapped:NO];
      td.textureType = MTLTextureType2DMultisample;
      td.sampleCount = s_msaaSamples;
      td.usage       = MTLTextureUsageRenderTarget;
      td.storageMode = sm;
      s_msaaColor = [dev newTextureWithDescriptor:td];
      s_msaaDepth = nil;
      if (s_msaaColor && depth)
      {
         td.pixelFormat = depth.pixelFormat;
         s_msaaDepth = [dev newTextureWithDescriptor:td];
      }
      if (s_msaaColor && (!depth || s_msaaDepth))
      {
         s_msaaColor.label = @"RA3D eye MSAA colour";
         s_msaaDepth.label = @"RA3D eye MSAA depth";
         RA_BeaconMark([[NSString stringWithFormat:
            @"3dmsaa: targets %lux%lu x%lu %s",
            (unsigned long)color.width, (unsigned long)color.height,
            (unsigned long)s_msaaSamples, s_msaaMemoryless ? "memoryless" : "private"] UTF8String]);
         return YES;
      }
      if (!s_msaaMemoryless) break;
      s_msaaMemoryless = NO;   /* retry once as private */
   }
   s_msaaColor = nil; s_msaaDepth = nil;
   RA_BeaconMark("3dmsaa: target allocation FAILED");
   return NO;
}

static void ra_post_build_pipelines(id<MTLDevice> dev, MTLPixelFormat color, MTLPixelFormat depth);

static void ra_build_pipelines(id<MTLDevice> dev, MTLPixelFormat color, MTLPixelFormat depth)
{
   NSError       *err = nil;
   MTLCompileOptions *co = [MTLCompileOptions new];
   co.preserveInvariance = YES;   /* GeoV.pos is [[invariant]] */
   id<MTLLibrary> lib = [dev newLibraryWithSource:kRAShader options:co error:&err];
   if (!lib) { NSLog(@"[RA3D] shader compile FAILED: %@", err.localizedDescription); return; }

   ra_msaa_resolve_config(dev, color, depth);   /* before any eye-pass pipeline */

   MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
   pd.rasterSampleCount               = s_msaaSamples;
   pd.vertexFunction                  = [lib newFunctionWithName:@"ra_vs"];
   pd.fragmentFunction                = [lib newFunctionWithName:@"ra_plane_fs"];
   pd.colorAttachments[0].pixelFormat = color;
   pd.depthAttachmentPixelFormat      = depth;
   s_planePipe = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
   if (!s_planePipe) NSLog(@"[RA3D] plane pipeline FAILED: %@", err.localizedDescription);
   s_planeDecode = ra_format_takes_linear(color) ? 1u : 0u;
   {
      MTLRenderPipelineDescriptor *sd = [MTLRenderPipelineDescriptor new];
      sd.vertexFunction                  = [lib newFunctionWithName:@"ra_sky_vs"];
      sd.fragmentFunction                = [lib newFunctionWithName:@"ra_sky_fs"];
      sd.colorAttachments[0].pixelFormat = color;
      sd.depthAttachmentPixelFormat      = depth;
      sd.rasterSampleCount               = s_msaaSamples;
      s_skyPipe = [dev newRenderPipelineStateWithDescriptor:sd error:&err];
      if (!s_skyPipe) NSLog(@"[RA3D] sky box pipeline FAILED: %@", err.localizedDescription);
      sd.vertexFunction   = [lib newFunctionWithName:@"ra_sky_tess_vs"];
      sd.fragmentFunction = [lib newFunctionWithName:@"ra_sky_tess_fs"];
      s_skyTessPipe = [dev newRenderPipelineStateWithDescriptor:sd error:&err];
      if (!s_skyTessPipe) NSLog(@"[RA3D] bent sky box pipeline FAILED: %@", err.localizedDescription);
   }
   RA_BeaconMark([[NSString stringWithFormat:
      @"3dplanes: colour target fmt %lu -> %s", (unsigned long)color,
      s_planeDecode ? "linear-in, plane shader decodes sRGB texels" : "UNORM, texels pass through"]
      UTF8String]);

   pd.fragmentFunction = [lib newFunctionWithName:@"ra_flat_fs"];
   s_flatPipe = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
   if (!s_flatPipe) NSLog(@"[RA3D] flat pipeline FAILED: %@", err.localizedDescription);

   MTLRenderPipelineDescriptor *dp = [MTLRenderPipelineDescriptor new];
   dp.vertexFunction                                  = [lib newFunctionWithName:@"ra_dim_vs"];
   dp.fragmentFunction                                = [lib newFunctionWithName:@"ra_dim_fs"];
   dp.colorAttachments[0].pixelFormat                 = color;
   dp.colorAttachments[0].blendingEnabled             = YES;
   dp.colorAttachments[0].sourceRGBBlendFactor        = MTLBlendFactorSourceAlpha;
   dp.colorAttachments[0].destinationRGBBlendFactor   = MTLBlendFactorOneMinusSourceAlpha;
   dp.colorAttachments[0].sourceAlphaBlendFactor      = MTLBlendFactorOne;
   dp.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOne;
   dp.depthAttachmentPixelFormat                      = depth;
   dp.rasterSampleCount                               = s_msaaSamples;
   s_dimPipe = [dev newRenderPipelineStateWithDescriptor:dp error:&err];
   if (!s_dimPipe) NSLog(@"[RA3D] dim pipeline FAILED: %@", err.localizedDescription);

   /* Real depth compare for the planes: a near sprite layer must occlude the
    * background where it overlaps.  Depth is written either way — the
    * compositor reprojects on it and silently drops frames it cannot.
    *
    * GREATER-EQUAL, NOT LESS-EQUAL, AND THE CLEAR IS 0.
    * `cp_drawable_compute_projection()` hands back a REVERSED-Z projection:
    * the near plane maps to depth 1 and the far plane to 0, which is what the
    * compositor's own reprojection wants. With LessEqual + clearDepth 1.0 the
    * test therefore keeps the FARTHEST fragment, and since the NES backdrop
    * plane is opaque over all 256x240 and is drawn first (it is the farthest
    * layer), it claimed the whole depth buffer and every nearer thing — the
    * background layer, the sprite layers, and the entire 3dSen geometry pass —
    * failed against it. Layered NES 3D was a flat rectangle of the backdrop
    * colour: a "giant white/cyan slab" on device. */
    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
   dd.depthCompareFunction = MTLCompareFunctionGreaterEqual;
   dd.depthWriteEnabled    = YES;
   s_depthWrite = [dev newDepthStencilStateWithDescriptor:dd];

   MTLDepthStencilDescriptor *da = [MTLDepthStencilDescriptor new];
   da.depthCompareFunction = MTLCompareFunctionAlways;
   da.depthWriteEnabled    = YES;
   s_depthAlways = [dev newDepthStencilStateWithDescriptor:da];

   ra_geo_build_pipelines(dev, lib, color, depth);
   ra_post_build_pipelines(dev, color, depth);   /* no-op unless ao / reflection */

   NSLog(@"[RA3D] pipelines built (color=%lu depth=%lu)", (unsigned long)color, (unsigned long)depth);
}

/* ------------------------------------------------------- plane texture cache */

static id<MTLTexture> s_planeTex[RA_VISION_MAX_PLANES];
static uint32_t       s_planeFrame = 0xFFFFFFFFu;

static void ra_upload_planes(id<MTLDevice> dev, const ra_vision_planes_t *p)
{
   int i;
   if (p->frame == s_planeFrame)
      return;                     /* emulator has not advanced — reuse */
   for (i = 0; i < p->count; i++)
   {
      if (!s_planeTex[i] || s_planeTex[i].width != p->width || s_planeTex[i].height != p->height)
      {
         MTLTextureDescriptor *td =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                               width:p->width
                                                              height:p->height
                                                           mipmapped:NO];
         td.usage       = MTLTextureUsageShaderRead;
         td.storageMode = MTLStorageModeShared;
         s_planeTex[i]  = [dev newTextureWithDescriptor:td];
         s_planeTex[i].label = [NSString stringWithFormat:@"RA3D plane %d", i];
      }
      [s_planeTex[i] replaceRegion:MTLRegionMake2D(0, 0, p->width, p->height)
                       mipmapLevel:0
                         withBytes:p->plane[i]
                       bytesPerRow:p->width * 4];
   }
   s_planeFrame = p->frame;
}

/* =========================================================== 3dSen shape mode
 * The scene stream's instance array, drawn as six instanced primitives
 * INSIDE the same per-eye pass as the depth planes — same depth buffer, so a
 * plane in front of an extruded block occludes it without any sorting on our
 * side, and the geometry is genuinely stereoscopic rather than a picture of
 * depth. Mesh space is a unit patch; everything per-object rides in the
 * per-instance matrix (see the shaders in kRAShader).
 *
 * The +Y-DOWN TRAP: the scene's world is NES
 * screen order, +Y down. Nothing here builds a look_at — the panel basis comes
 * from ra_plane_transform, which is built for +Y UP — so the world-to-panel
 * matrix flips Y explicitly, in one place, below. That is the same bug the
 * Python rasteriser hit as a mirrored render; here it would be a scene that
 * looks right until something is asymmetric.
 */

/* ra3d_geo_gpu.h's implementation is included at the top of the file (
 * the light defaults are needed by the cfg loader, which comes first). */

#define RA3D_VOX_IMPLEMENTATION
#include "ra3d_vox.h"

static id<MTLRenderPipelineState> s_geoPipe, s_geoBlendPipe, s_geoDepthPipe;
static id<MTLDepthStencilState>   s_depthTestNoWrite;
static id<MTLBuffer>              s_geoInstBuf, s_geoCellBuf, s_geoPalBuf;
static id<MTLBuffer>              s_geoDtexBuf;
static uint32_t                   s_geoDtexGen = 0xFFFFFFFFu, s_geoDtexCount = 0;
static id<MTLBuffer>              s_geoAtlasBuf;   /* a buffer, 64 B per tile —
                                                    * a 8-wide texture capped the
                                                    * atlas at 1024 tiles (8192 rows) */
static uint32_t                   s_geoAtlasTiles;
/* the voxel mesh cache (CPU) and its GPU mirror. The mirror only ever
 * GROWS by appending — bytes an in-flight frame may be reading are never
 * rewritten; a cache flush (new generation) gets a brand-new buffer. */
static Ra3dVoxCache              *s_vox;
static id<MTLBuffer>              s_voxVB, s_voxPieceBuf;
static uint32_t                   s_voxVBCount = 0, s_voxVBGen = 0xFFFFFFFFu;
static Ra3dVoxFrame               s_voxFrame;
static uint32_t                  *s_voxSlotOf;
static uint32_t                   s_voxSlotCap = 0;
static double                     s_voxMs = 0.0, s_voxMeshMs = 0.0;
/* worst single frame since the last beacon line, and how many misses */
static double                     s_voxPeakMs = 0.0;
static uint32_t                   s_voxMissSum = 0;
static uint32_t                   s_voxDeferSum = 0;
/* MARCHING evidence for the beacon — the most MARCHING instances in
 * one frame since the last line, and a one-shot line naming the first one
 * (a forced `rm = 2` shape may be on screen for less than a beacon window). */
static uint32_t                   s_voxMarchPeak = 0;
static int                        s_voxMarchLogged = 0;
static uint32_t                   s_geoFrame = 0xFFFFFFFFu;
static Ra3dGeoBuckets             s_geoBuckets;
static uint32_t                   s_tranPeak = 0;   /* alpha < 1 instances, peak per beacon line */
static uint32_t                   s_geoInstTotal = 0;
/* Deepest panel-local z of this frame's geometry, in METRES (negative = behind
 * the panel). uses it to keep the backdrop plane behind every shape. */
static float                      s_geoMinZ      = 0.0f;
/* panel-local AABB of this frame's drawn (non-UI, colour)
 * geometry — the sky box's z range and, with the `_View` rect, its xy. */
static simd_float3                s_geoBoxMin, s_geoBoxMax;
static int                        s_geoBoxOk     = 0;
static int                        s_skyBoxFaces  = 0;   /* last view's, for the beacon */
static float                      s_fxNearPx     = 0.0f;   /* bend's comfort delta */
static uint32_t                   s_geoCellCount = 0;
static double                     s_geoBuildMs = 0.0, s_geoUploadMs = 0.0;
/* the light. Knobs are `light_*` in 3dsen.cfg (read with the camera's);
 * `s_lightEncode` is decided from the drawable's ACTUAL colour format when the
 * pipelines are built — never assumed. */
static int                        s_lightEncode    = 0;
/* the shadow map, its caster pipeline, and this frame's fit. The map
 * is re-rendered only when what it depends on changed (geometry frame, light,
 * clip, cfg) — the light is fixed to the diorama, so the camera never
 * dirties it. Rendered in its own command buffer ahead of the eye passes on
 * the same queue, so its GPU time can be read on its own. */
static id<MTLRenderPipelineState> s_shadowPipe;
static id<MTLDepthStencilState>   s_shadowDepth;
static id<MTLTexture>             s_shadowTex, s_shadowDummy;
static simd_float4x4              s_geoQ;
static Ra3dGeoShadow              s_shadow;          /* bound this frame      */
static Ra3dGeoShadow              s_shadowDrawn;     /* what the map holds    */
static uint32_t                   s_shadowDrawnFrame = 0xFFFFFFFFu;
static Ra3dGeoShadowFit           s_shadowFit;
static double                     s_shadowCpuMs = 0.0, s_shadowCpuPeak = 0.0;
static _Atomic uint64_t           s_shadowGpuUsSum = 0, s_shadowGpuUsPeak = 0;
static _Atomic uint32_t           s_shadowGpuN = 0;
static uint32_t                   s_shadowRenders = 0;
/* the whole eye-pass command buffer's GPU time, 3dSen frames only — the
 * before/after for the receiver-side cost of the map lookup */
static _Atomic uint64_t           s_frameGpuUsSum = 0, s_frameGpuUsPeak = 0;
static _Atomic uint32_t           s_frameGpuN = 0;

/* True when writing a LINEAR value into this format is correct: the hardware
 * encodes on store (_sRGB) or the format is float and the compositor treats
 * it as linear. Anything else is UNORM and the shader must encode itself. */
static bool ra_format_takes_linear(MTLPixelFormat f)
{
   switch (f)
   {
      case MTLPixelFormatRGBA8Unorm_sRGB:
      case MTLPixelFormatBGRA8Unorm_sRGB:
      case MTLPixelFormatRGBA16Float:
      case MTLPixelFormatRGBA32Float:
      case MTLPixelFormatRG11B10Float:
      case MTLPixelFormatRGB9E5Float:
      case MTLPixelFormatBGRA10_XR_sRGB:
      case MTLPixelFormatBGR10_XR_sRGB:
         return true;
      default:
         return false;
   }
}

static void ra_geo_build_pipelines(id<MTLDevice> dev, id<MTLLibrary> lib,
                                   MTLPixelFormat color, MTLPixelFormat depth)
{
   NSError *err = nil;
   MTLRenderPipelineDescriptor *gd = [MTLRenderPipelineDescriptor new];
   gd.vertexFunction                  = [lib newFunctionWithName:@"ra_geo_vs"];
   gd.fragmentFunction                = [lib newFunctionWithName:@"ra_geo_fs"];
   gd.colorAttachments[0].pixelFormat = color;
   gd.depthAttachmentPixelFormat      = depth;
   gd.rasterSampleCount               = s_msaaSamples;
   s_geoPipe = [dev newRenderPipelineStateWithDescriptor:gd error:&err];
   if (!s_geoPipe) { NSLog(@"[RA3D] geo pipeline FAILED: %@", err.localizedDescription); return; }
   gd.vertexFunction = [lib newFunctionWithName:@"ra_geo_tess_vs"];   /* bent Backdrop */
   s_geoTessPipe = [dev newRenderPipelineStateWithDescriptor:gd error:&err];
   if (!s_geoTessPipe) NSLog(@"[RA3D] bent backdrop pipeline FAILED: %@", err.localizedDescription);
   gd.vertexFunction = [lib newFunctionWithName:@"ra_geo_vs"];

   s_lightEncode = ra_format_takes_linear(color) ? 0 : 1;
   RA_BeaconMark([[NSString stringWithFormat:
      @"3dlight: colour target fmt %lu -> %s", (unsigned long)color,
      s_lightEncode ? "UNORM, shader encodes sRGB" : "linear-in (sRGB/float), hardware encodes"]
      UTF8String]);

   gd.colorAttachments[0].blendingEnabled             = YES;
   gd.colorAttachments[0].sourceRGBBlendFactor        = MTLBlendFactorSourceAlpha;
   gd.colorAttachments[0].destinationRGBBlendFactor   = MTLBlendFactorOneMinusSourceAlpha;
   gd.colorAttachments[0].sourceAlphaBlendFactor      = MTLBlendFactorOne;
   gd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
   s_geoBlendPipe = [dev newRenderPipelineStateWithDescriptor:gd error:&err];
   if (!s_geoBlendPipe) NSLog(@"[RA3D] geo blend pipeline FAILED: %@", err.localizedDescription);

   /* translucent first pass — depth written, no colour. Same vertex
    * and fragment functions (the fragment still runs for the `_View`
    * discard), no colour written. */
   gd.colorAttachments[0].blendingEnabled = NO;
   gd.colorAttachments[0].writeMask       = MTLColorWriteMaskNone;
   s_geoDepthPipe = [dev newRenderPipelineStateWithDescriptor:gd error:&err];
   if (!s_geoDepthPipe) NSLog(@"[RA3D] geo depth pre-pass pipeline FAILED: %@", err.localizedDescription);

   /* Translucent instances (3dSen's water, Zelda's waterfall) test depth but
    * must not write it, or whichever one is drawn first hides the rest. */
   MTLDepthStencilDescriptor *dt = [MTLDepthStencilDescriptor new];
   dt.depthCompareFunction = MTLCompareFunctionGreaterEqual;   /* reverse-Z, */
   dt.depthWriteEnabled    = NO;
   s_depthTestNoWrite = [dev newDepthStencilStateWithDescriptor:dt];

   if (!s_vox) s_vox = ra3d_vox_cache_new();

   /* the caster pass — depth only, biased (1, 1) raster units (this map
    * is forward-Z, 0 nearest the light, so +1/+1). No culling: our greedy
    * meshes carry no winding contract, and a light-facing face's own depth
    * is biased behind it anyway. */
   {
      MTLRenderPipelineDescriptor *sd = [MTLRenderPipelineDescriptor new];
      sd.vertexFunction             = [lib newFunctionWithName:@"ra_shadow_vs"];
      sd.fragmentFunction           = [lib newFunctionWithName:@"ra_shadow_fs"];
      sd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
      s_shadowPipe = [dev newRenderPipelineStateWithDescriptor:sd error:&err];
      if (!s_shadowPipe) NSLog(@"[RA3D] shadow pipeline FAILED: %@", err.localizedDescription);
      MTLDepthStencilDescriptor *sdd = [MTLDepthStencilDescriptor new];
      sdd.depthCompareFunction = MTLCompareFunctionLessEqual;
      sdd.depthWriteEnabled    = YES;
      s_shadowDepth = [dev newDepthStencilStateWithDescriptor:sdd];
      if (!s_shadowDummy)
      {  /* bound whenever the map is off, so texture(1) is never unbound */
         MTLTextureDescriptor *td = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                         width:1 height:1 mipmapped:NO];
         td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
         td.storageMode = MTLStorageModePrivate;
         s_shadowDummy = [dev newTextureWithDescriptor:td];
      }
      memset(&s_shadow, 0, sizeof(s_shadow));
      s_shadowDrawnFrame = 0xFFFFFFFFu;
   }
}

static double ra_geo_ms(void)
{
   return (double)CACurrentMediaTime() * 1000.0;
}

/* the per-frame GPU resources, ring-buffered. `busy` counts the
 * command buffers that reference the slot and have not completed; a slot is
 * reused only at zero. RA_GEO_SLOTS covers frames in flight with room to
 * spare; if every slot is still busy (a GPU stall), a new one is appended. */
typedef struct
{
   id<MTLBuffer>  piece, inst, cell, pal;
   id<MTLBuffer>  atlas;
   _Atomic int    busy;
} RaGeoSlot;
#define RA_GEO_SLOTS_MAX 8
static RaGeoSlot s_geoSlots[RA_GEO_SLOTS_MAX];
static int       s_geoSlotN = 4, s_geoSlotCur = -1;
static uint32_t  s_geoSlotStalls = 0;

static RaGeoSlot *ra_geo_slot_acquire(void)
{
   int i;
   for (i = 1; i <= s_geoSlotN; i++)
   {
      int k = (s_geoSlotCur + i + s_geoSlotN) % s_geoSlotN;
      if (k != s_geoSlotCur && atomic_load(&s_geoSlots[k].busy) == 0)
      { s_geoSlotCur = k; return &s_geoSlots[k]; }
   }
   s_geoSlotStalls++;
   if (s_geoSlotN < RA_GEO_SLOTS_MAX)
   { s_geoSlotCur = s_geoSlotN++; return &s_geoSlots[s_geoSlotCur]; }
   /* all eight busy (the GPU is far behind): never block the render
    * thread — take the next slot and accept the old race for this frame */
   s_geoSlotCur = (s_geoSlotCur + 1) % s_geoSlotN;
   return &s_geoSlots[s_geoSlotCur];
}

/* Marks the current slot in use by `cb` until it completes. Call for every
 * command buffer that encodes geometry from the current slot. */
static void ra_geo_slot_retain(id<MTLCommandBuffer> cb)
{
   RaGeoSlot *sl;
   if (s_geoSlotCur < 0) return;
   sl = &s_geoSlots[s_geoSlotCur];
   atomic_fetch_add(&sl->busy, 1);
   [cb addCompletedHandler:^(id<MTLCommandBuffer> b) {
      (void)b;
      atomic_fetch_sub(&sl->busy, 1);
   }];
}

/* Builds this frame's draw list: one model matrix per instance (opaque
 * first), then the voxel pieces — cached meshes, so a steady-state
 * frame meshes nothing and uploads only matrices, pieces and cells. */
static void ra_geo_upload(id<MTLDevice> dev, const Ra3dGeoFrame *g)
{
   static Ra3dGeoInst *tmp = NULL;
   static uint32_t     tmp_cap = 0;
   uint32_t            n = g->instance_count;
   float               halfW = 1.0f, halfH = 1.0f;
   double              t0 = ra_geo_ms();
   unsigned            atlasN = 0;
   const uint8_t      *atlas  = ra_vision_scene_atlas(&atlasN);

   if (!n || !g->cell_count || !atlas || !atlasN || !s_vox)
   { s_geoInstTotal = 0; s_geoCellCount = 0; s_geoMinZ = 0.0f; return; }
   if (n > tmp_cap || n > s_voxSlotCap)
   {
      Ra3dGeoInst *np = (Ra3dGeoInst *)realloc(tmp, (size_t)n * sizeof(Ra3dGeoInst));
      uint32_t    *ns;
      if (!np) { s_geoInstTotal = 0; s_geoCellCount = 0; s_geoMinZ = 0.0f; return; }
      tmp = np; tmp_cap = n;
      ns = (uint32_t *)realloc(s_voxSlotOf, (size_t)n * sizeof(uint32_t));
      if (!ns) { s_geoInstTotal = 0; s_geoCellCount = 0; s_geoMinZ = 0.0f; return; }
      s_voxSlotOf = ns; s_voxSlotCap = n;
   }

   ra_panel_half(&halfW, &halfH);
   s_geoQ = ra3d_geo_world_to_panel(halfW, ra_vision_scene_depth_scale());
   ra3d_geo_instances(g, s_geoQ, tmp, s_voxSlotOf, &s_geoBuckets);
   {  /* the frame's Enhanced constants; the Lua Backdrop is the one
       * instance whose cell uses palette group 16 (ra3d_lua.h) */
      int bd = -1;
      uint32_t i;
      for (i = 0; i < n && bd < 0; i++)
         if (g->instances[i].cell_count == 1 && g->instances[i].cell_offset < g->cell_count
             && g->cells[g->instances[i].cell_offset].pal == 16)
            bd = (int)s_voxSlotOf[i];
      ra3d_geo_fx(&s_fx, &s_fxCfg, s_geoQ, ra_vision_scene_depth_scale(), bd);
   }
   if (s_geoBuckets.blend_count > s_tranPeak) s_tranPeak = s_geoBuckets.blend_count;

   /* The furthest point any shape reaches behind the panel.  Each instance's
    * model column 3 is its box origin and column 2 its depth axis, both in
    * panel metres; the box is centred in z, so the extremes are
    * origin -/+ half the depth. */
   {
      uint32_t i;
      float minz = 0.0f;
      for (i = 0; i < n; i++)
      {
         float z0 = tmp[i].model.columns[3].z - 0.5f * tmp[i].model.columns[2].z;
         float z1 = tmp[i].model.columns[3].z + 0.5f * tmp[i].model.columns[2].z;
         if (z0 < minz) minz = z0;
         if (z1 < minz) minz = z1;
      }
      s_geoMinZ = minz;
   }
   {  /* the drawn geometry's panel-local bounds, all 8 corners
       * of every colour instance's unit box. UI shapes stay OUT: they float
       * on the camera-less panel well in front of the diorama, and taking
       * their z in pushed the box's front opening so far forward that dead-on
       * it framed the scene with a wide empty margin (the geometry no longer
       * reached the box edges). The HUD is a floating overlay, as in 3dSen. */
      uint32_t i;
      int c;
      simd_float3 lo = simd_make_float3( 1e9f,  1e9f,  1e9f);
      simd_float3 hi = simd_make_float3(-1e9f, -1e9f, -1e9f);
      s_geoBoxOk = 0;
      for (i = 0; i < n; i++)
      {
         if (tmp[i].flags & (RA3D_GEO_UI | RA3D_GEO_NOCOLOR)) continue;
         for (c = 0; c < 8; c++)
         {
            simd_float4 q = simd_mul(tmp[i].model,
               simd_make_float4((float)(c & 1), (float)((c >> 1) & 1),
                                (c & 4) ? 0.5f : -0.5f, 1.0f));
            lo = simd_min(lo, q.xyz); hi = simd_max(hi, q.xyz);
         }
         s_geoBoxOk = 1;
      }
      s_geoBoxMin = lo; s_geoBoxMax = hi;
      if (s_fx.bend && s_geoBoxOk)
      {  /* a bulge pushes the edges back — the backdrop push
          * must clear the BENT geometry (the sky box bends with it) */
         simd_float4 a = simd_mul(s_fx.Qi, simd_make_float4(lo, 1.0f));
         simd_float4 b = simd_mul(s_fx.Qi, simd_make_float4(hi, 1.0f));
         float bl[3] = { fminf(a.x, b.x), fminf(a.y, b.y), fminf(a.z, b.z) };
         float bh[3] = { fmaxf(a.x, b.x), fmaxf(a.y, b.y), fmaxf(a.z, b.z) };
         ra3d_bend_aabb(&s_fx, bl, bh);
         {
            float zb = simd_mul(s_fx.Q, simd_make_float4(bl[0], bl[1], bl[2], 1.0f)).z;
            if (zb < s_geoMinZ) s_geoMinZ = zb;
            /* comfort: how much nearer the viewer the bent geometry reaches
             * (NES px). Measured in the sim: ~+16 px at +30/+30 too,
             * since the bulge's centre comes forward with FitShift; up to
             * ~+90 px at -30/-30 on Punch-Out (the wide Backdrop's corners) */
            s_fxNearPx = bh[2] - 1.0f - fmaxf(a.z, b.z);
         }
      }
   }

   if (!ra3d_vox_build(s_vox, g, s_voxSlotOf, atlas, atlasN, &s_voxFrame))
   { s_geoInstTotal = 0; s_geoCellCount = 0; return; }
   s_voxMs     = s_voxFrame.total_ms;
   s_voxMeshMs = s_voxFrame.mesh_ms;
   if (s_voxMs > s_voxPeakMs) s_voxPeakMs = s_voxMs;
   s_voxMissSum += s_voxFrame.meshed;
   s_voxDeferSum += s_voxFrame.deferred;
   if (s_voxFrame.marching > s_voxMarchPeak) s_voxMarchPeak = s_voxFrame.marching;
   if (s_voxFrame.marching && s_voxMarchLogged < 4)
   {
      uint32_t k;
      for (k = 0; k < g->instance_count; k++)
         if ((g->instances[k].flags & RA3D_INST_MARCHING)
             && !(g->instances[k].flags & RA3D_INST_HIDDEN))
         {
            RA_BeaconMark([[NSString stringWithFormat:
               @"3dsen: MARCHING instance on screen — pattern %d, %u this frame (geo %u, z %.0f)",
               (int)g->instances[k].pattern, s_voxFrame.marching,
               (unsigned)g->instances[k].geo, (double)g->instances[k].size[2]] UTF8String]);
            s_voxMarchLogged++;
            break;
         }
   }

   s_geoBuildMs = ra_geo_ms() - t0;
   t0 = ra_geo_ms();

   /* vertex mirror: append-only within a generation */
   {
      uint32_t nv = 0, gen = 0;
      const Ra3dVoxVert *vv = ra3d_vox_verts(s_vox, &nv, &gen);
      NSUInteger need = (NSUInteger)nv * sizeof(Ra3dVoxVert);
      if (gen != s_voxVBGen || !s_voxVB || s_voxVB.length < need)
      {
         NSUInteger cap = need * 2;
         if (cap < 65536u * sizeof(Ra3dVoxVert)) cap = 65536u * sizeof(Ra3dVoxVert);
         s_voxVB = [dev newBufferWithLength:cap options:MTLResourceStorageModeShared];
         s_voxVB.label = @"RA3D voxel meshes";
         if (nv) memcpy(s_voxVB.contents, vv, need);
         s_voxVBGen = gen;
      }
      else if (nv > s_voxVBCount)
         memcpy((uint8_t *)s_voxVB.contents + (size_t)s_voxVBCount * sizeof(Ra3dVoxVert),
                vv + s_voxVBCount, (size_t)(nv - s_voxVBCount) * sizeof(Ra3dVoxVert));
      s_voxVBCount = nv;
   }

   /* every per-frame resource lives in a SLOT of a small ring,
    * and a slot is only rewritten once no command buffer that read it is
    * still on the GPU. They used to be rewritten in place while the command
    * buffers of the previous render frames (the shadow pass and both eyes)
    * could still be reading them — on device, with frames in flight, a piece
    * then met the NEXT frame's instance matrix, cells and CHR: shapes drawn
    * with another shape's transform and colours. (The voxel VB stays shared:
    * it is append-only between rebuilds, and a rebuild allocates anew.) */
   {
      RaGeoSlot *sl = ra_geo_slot_acquire();
      size_t pieceLen = (size_t)(s_voxFrame.piece_count + 1) * sizeof(Ra3dVoxPiece);
      size_t instLen  = (size_t)n * sizeof(Ra3dGeoInst);
      size_t cellLen  = (size_t)(g->cell_count + 1) * 8;
      if (!sl->piece || sl->piece.length < pieceLen)
         sl->piece = [dev newBufferWithLength:pieceLen * 2 options:MTLResourceStorageModeShared];
      if (!sl->inst || sl->inst.length < instLen)
         sl->inst = [dev newBufferWithLength:instLen * 2 options:MTLResourceStorageModeShared];
      if (!sl->cell || sl->cell.length < cellLen)
         sl->cell = [dev newBufferWithLength:cellLen * 2 options:MTLResourceStorageModeShared];
      if (!sl->pal)
         sl->pal = [dev newBufferWithLength:RA3D_GEO_PALETTE_ENTRIES * sizeof(uint32_t)
                                    options:MTLResourceStorageModeShared];
      if (!sl->atlas || sl->atlas.length < (NSUInteger)atlasN * 64)
      {
         sl->atlas = [dev newBufferWithLength:(NSUInteger)atlasN * 64 * 2
                                      options:MTLResourceStorageModeShared];
         sl->atlas.label = @"RA3D CHR atlas";
      }
      if (s_voxFrame.piece_count)
         memcpy(sl->piece.contents, s_voxFrame.pieces,
                (size_t)s_voxFrame.piece_count * sizeof(Ra3dVoxPiece));
      memcpy(sl->inst.contents, tmp, instLen);
      memcpy(sl->cell.contents, g->cells, (size_t)g->cell_count * 8);
      memcpy(sl->pal.contents, ra_vision_scene_palette(),
             RA3D_GEO_PALETTE_ENTRIES * sizeof(uint32_t));   /* 16 groups + Backdrop */
      memcpy(sl->atlas.contents, atlas, (size_t)atlasN * 64);
      s_voxPieceBuf = sl->piece;
      s_geoInstBuf  = sl->inst;
      s_geoCellBuf  = sl->cell;
      s_geoPalBuf   = sl->pal;
      s_geoAtlasBuf   = sl->atlas;
      s_geoAtlasTiles = atlasN;
   }

   /* the profile's Direct-colour textures, re-uploaded only
    * when the frame says they changed (a new profile). A fresh buffer each
    * time, so a frame still in flight keeps reading the old one. */
   if (!s_geoDtexBuf || g->dtex_gen != s_geoDtexGen)
   {
      NSUInteger len = (NSUInteger)(g->dtex_n ? g->dtex_n : 1) * sizeof(uint32_t);
      s_geoDtexBuf = [dev newBufferWithLength:len options:MTLResourceStorageModeShared];
      s_geoDtexBuf.label = @"RA3D direct textures";
      if (g->dtex_n && g->dtex) memcpy(s_geoDtexBuf.contents, g->dtex, (size_t)g->dtex_n * sizeof(uint32_t));
      else memset(s_geoDtexBuf.contents, 0, len);
      s_geoDtexCount = g->dtex_n;
      s_geoDtexGen   = g->dtex_gen;
   }

   s_geoCellCount = g->cell_count;
   s_geoInstTotal = n;
   s_geoUploadMs  = ra_geo_ms() - t0;
}

/* this frame's `_View` clip — cfg `clipping` > the profile's static
 * _Setting_.Clipping > 3dSen's default. ONE function so the shadow pass binds
 * exactly what the colour pass does. */
static void ra_geo_view_now(Ra3dGeoView *vw)
{
   float c[4];
   memcpy(c, s_clipCfg, sizeof(c));
   if (!s_clipCfgSet)
   {
      float pc[4];
      if (ra_vision_scene_profile_clipping(pc)) memcpy(c, pc, sizeof(c));
   }
   ra3d_geo_view(vw, c, s_viewClip);
}

/* The light as ra_geo_fs sees it: the profile's static Light.Direction /
 * Color override the cfg's, intensity is always the user's. ONE
 * function so the shadow fit uses exactly the shaded light. */
static void ra_geo_light_now(Ra3dGeoLight *lt)
{
   float pd[3], pcol[3];
   const float *dir = s_lightDir, *col = s_lightColor;
   int pf = s_lightProfile ? ra_vision_scene_profile_light(pd, pcol) : 0;
   if ((pf & 1) && (pd[0] != 0.0f || pd[1] != 0.0f || pd[2] != 0.0f)) dir = pd;
   if (pf & 2) col = pcol;
   ra3d_geo_light(lt, dir, col, s_lightIntensity, s_lightAmbient, s_lightEncode);
}

/* fit this frame's shadow map and (re-)render it if anything it
 * depends on changed. Runs once per frame, before the eye passes. */
static void ra_geo_shadow_prepare(id<MTLDevice> dev, id<MTLCommandQueue> queue)
{
   static int s_logged = 0;
   double t0 = ra_geo_ms();
   Ra3dGeoLight lt;
   Ra3dGeoView  vw;
   Ra3dGeoShadow nsh;
   uint32_t size = (uint32_t)s_shadowMapSize;

   memset(&nsh, 0, sizeof(nsh));
   if (!s_shadows || !s_shadowPipe || !s_geoInstTotal || !s_geoInstBuf || !s_voxVB
       || !s_voxPieceBuf || !s_voxFrame.run_count)
   { s_shadow = nsh; return; }

   ra_geo_light_now(&lt);
   ra_geo_view_now(&vw);
   if (!ra3d_geo_shadow_fit_fx(&nsh, &s_shadowFit, (const Ra3dGeoInst *)s_geoInstBuf.contents,
                               s_geoInstTotal, s_geoQ, &lt, &vw, size, s_shadowStrength,
                               &s_fx))   /* fitted to the bent casters */
   { memset(&s_shadow, 0, sizeof(s_shadow)); return; }

   if (!s_shadowTex || s_shadowTex.width != size)
   {
      MTLTextureDescriptor *td = [MTLTextureDescriptor
         texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                      width:size height:size mipmapped:NO];
      td.usage       = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
      td.storageMode = MTLStorageModePrivate;
      s_shadowTex = [dev newTextureWithDescriptor:td];
      s_shadowTex.label = @"RA3D shadow map";
      s_shadowDrawnFrame = 0xFFFFFFFFu;
   }
   s_shadow = nsh;
   if (s_shadowDrawnFrame == s_geoFrame && !memcmp(&nsh, &s_shadowDrawn, sizeof(nsh)))
   { s_shadowCpuMs = ra_geo_ms() - t0; return; }

   {
      id<MTLCommandBuffer> cb = [queue commandBuffer];
      MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
      uint32_t r, counts[2] = { s_geoInstTotal, s_geoCellCount };
      cb.label = @"RA3D shadow";
      ra_geo_slot_retain(cb);
      rp.depthAttachment.texture     = s_shadowTex;
      rp.depthAttachment.loadAction  = MTLLoadActionClear;
      rp.depthAttachment.storeAction = MTLStoreActionStore;
      rp.depthAttachment.clearDepth  = 1.0;
      id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
      [enc setRenderPipelineState:s_shadowPipe];
      [enc setDepthStencilState:s_shadowDepth];
      [enc setCullMode:MTLCullModeNone];
      [enc setDepthBias:1.0f slopeScale:1.0f clamp:0.0f];
      [enc setVertexBuffer:s_voxVB       offset:0 atIndex:0];
      [enc setVertexBuffer:s_geoInstBuf  offset:0 atIndex:1];
      [enc setVertexBuffer:s_voxPieceBuf offset:0 atIndex:3];
      [enc setVertexBytes:counts length:sizeof(counts) atIndex:4];
      [enc setVertexBytes:&nsh length:sizeof(nsh) atIndex:5];
      [enc setVertexBytes:&s_fx length:sizeof(s_fx) atIndex:11];
      [enc setFragmentBytes:&vw length:sizeof(vw) atIndex:5];
      for (r = 0; r < s_voxFrame.run_count; r++)
      {
         const Ra3dVoxRun *run = &s_voxFrame.runs[r];
         if (run->first + run->count > s_voxVBCount) continue;
         [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:run->first
                 vertexCount:run->count instanceCount:run->piece_count
                baseInstance:run->piece_first];
      }
      [enc endEncoding];
      [cb addCompletedHandler:^(id<MTLCommandBuffer> b) {
         double g = b.GPUEndTime - b.GPUStartTime;
         if (g > 0.0 && g < 1.0)
         {
            uint64_t us = (uint64_t)(g * 1e6);
            atomic_fetch_add(&s_shadowGpuUsSum, us);
            atomic_fetch_add(&s_shadowGpuN, 1u);
            if (us > atomic_load(&s_shadowGpuUsPeak)) atomic_store(&s_shadowGpuUsPeak, us);
         }
      }];
      [cb commit];
   }
   s_shadowDrawn = nsh;
   s_shadowDrawnFrame = s_geoFrame;
   s_shadowRenders++;
   s_shadowCpuMs = ra_geo_ms() - t0;
   if (s_shadowCpuMs > s_shadowCpuPeak) s_shadowCpuPeak = s_shadowCpuMs;
   if (s_logged < 3)
   {
      uint8_t lc[6], lr[6];
      int lua = ra_vision_scene_profile_layer_shadow(lc, lr);
      s_logged++;
      RA_BeaconMark([[NSString stringWithFormat:
         @"3dshadow: fit box %.1f x %.1f x %.1f px -> %.2f x %.2f texels/px (map %u^2), "
          "receivers %u casters %u, recv AABB x %.1f..%.1f y %.1f..%.1f z %.1f..%.1f, "
          "L %.3f,%.3f,%.3f depthBias %.6f normalBias %.4f px; layer cast %d%d%d%d%d%d "
          "recv %d%d%d%d%d%d (lua mask 0x%x)",
         (double)s_shadowFit.w, (double)s_shadowFit.h, (double)s_shadowFit.range,
         1.0 / (double)s_shadowFit.texel_w, 1.0 / (double)s_shadowFit.texel_h, size,
         s_shadowFit.receivers, s_shadowFit.casters,
         (double)s_shadowFit.recv_min[0], (double)s_shadowFit.recv_max[0],
         (double)s_shadowFit.recv_min[1], (double)s_shadowFit.recv_max[1],
         (double)s_shadowFit.recv_min[2], (double)s_shadowFit.recv_max[2],
         (double)nsh.L.x, (double)nsh.L.y, (double)nsh.L.z,
         (double)nsh.depthBias, (double)nsh.normalBias,
         lc[0], lc[1], lc[2], lc[3], lc[4], lc[5], lr[0], lr[1], lr[2], lr[3], lr[4], lr[5],
         lua] UTF8String]);
   }
}

/* `base` carries the scene camera; `baseUI` the same panel without it — 3dSen
 * draws UI shapes on a camera-locked container. */
/* the sky box (sky_mode 3). Its xy is the `_View` rect the
 * geometry's fragments are clipped to (ra_geo_view_now, the same numbers the
 * shader tests), cut down to the screen plus whatever geometry lies inside a
 * widened rect (Punch-Out's Lua widens it by 128 px either side; an empty
 * 384-px band of sky there would be a wall, not a window). A quarter NES
 * pixel of margin keeps the walls off the geometry's faces that lie exactly
 * on the clip edge (no z-fight). Its z spans the geometry plus 2 mm and
 * always includes the panel plane.
 *
 * Only the faces the eye sees from INSIDE are drawn (eye behind the face's
 * plane w.r.t. its outward normal) — for a convex box those are exactly the
 * far faces, which lie behind every point inside it along each ray. So the
 * box never occludes the diorama, yet its far faces together cover the
 * box's whole silhouette: one opaque convex outline, the same from any orbit,
 * a plain rectangle dead-on. Decided per view on the CPU (6 plane tests), so
 * no winding/cull-mode convention can get it backwards.
 * `mv` = eyeFromOrigin * cam * panel (panel-local -> eye), `mvp` = proj * mv. */
/* Fills v[36] with the far faces for this view; returns the vertex count
 * (0 = nothing to draw: empty clip rect, or the eye inside the box).
 * built BEFORE the pass so a frame/eye with no box falls back to
 * sky 2's opaque clear instead of a transparent one. */
/* with `all` (24) and `eye` set it also returns every face's four
 * corners in face order (f = 2 axis + (outward +)) and the eye in panel-local
 * space, for the bent box (ra_sky_tess_vs), which culls per fragment. */
static int ra_sky_box_build_ex(simd_float4x4 mv, simd_float4 v[36], simd_float4 *all,
                               simd_float4 *eyeOut);
static int ra_sky_box_build(simd_float4x4 mv, simd_float4 v[36])
{
   return ra_sky_box_build_ex(mv, v, NULL, NULL);
}

static int ra_sky_box_build_ex(simd_float4x4 mv, simd_float4 v[36], simd_float4 *all,
                               simd_float4 *eyeOut)
{
   Ra3dGeoView vw;
   float x0, x1, y0, y1, z0, z1;
   const float m = 0.25f;              /* NES px */
   int nv = 0, f;
   if (!s_skyPipe) return 0;
   ra_geo_view_now(&vw);
   {
      /* screen in NES px (x 0..256, y 8..248: 3dSen's 248-px frame) */
      float sx0 = 0.0f, sx1 = 256.0f, sy0 = (float)(RA3D_UNITY_H - 240), sy1 = (float)RA3D_UNITY_H;
      float bx0 = sx0, bx1 = sx1, by0 = sy0, by1 = sy1;
      if (s_geoBoxOk)
      {  /* geometry bounds, panel -> NES px (x = 128(p+1), y = 120(1-p)) */
         float gx0 = 128.0f * (s_geoBoxMin.x + 1.0f), gx1 = 128.0f * (s_geoBoxMax.x + 1.0f);
         float gy0 = 120.0f * (1.0f - s_geoBoxMax.y), gy1 = 120.0f * (1.0f - s_geoBoxMin.y);
         bx0 = fminf(bx0, gx0); bx1 = fmaxf(bx1, gx1);
         by0 = fminf(by0, gy0); by1 = fmaxf(by1, gy1);
      }
      if (vw.on)
      {
         bx0 = fmaxf(bx0, vw.rect.x); bx1 = fminf(bx1, vw.rect.z);
         by0 = fmaxf(by0, vw.rect.y); by1 = fminf(by1, vw.rect.w);
      }
      if (!(bx1 > bx0 && by1 > by0)) return 0;
      bx0 -= m; bx1 += m; by0 -= m; by1 += m;
      x0 = bx0 / 128.0f - 1.0f; x1 = bx1 / 128.0f - 1.0f;
      y0 = 1.0f - by1 / 120.0f; y1 = 1.0f - by0 / 120.0f;     /* panel +Y up */
   }
   z0 = s_geoBoxOk ? fminf(s_geoBoxMin.z, 0.0f) : 0.0f;
   z1 = s_geoBoxOk ? fmaxf(s_geoBoxMax.z, 0.0f) : 0.0f;
   z0 -= 0.002f; z1 += 0.002f;
   {
      simd_float4x4 inv = simd_inverse(mv);
      simd_float4   e4  = simd_mul(inv, simd_make_float4(0, 0, 0, 1));
      simd_float3   e   = e4.xyz / e4.w;
      const float lo[3] = { x0, y0, z0 }, hi[3] = { x1, y1, z1 };
      if (eyeOut) *eyeOut = simd_make_float4(e, 1.0f);
      for (f = 0; f < 6; f++)
      {
         int   ax = f >> 1, sgn = (f & 1) ? 1 : -1;
         float pl = sgn > 0 ? hi[ax] : lo[ax];
         float ev = ax == 0 ? e.x : (ax == 1 ? e.y : e.z);
         int   a1 = (ax + 1) % 3, a2 = (ax + 2) % 3, k;
         simd_float4 q[4];
         for (k = 0; k < 4; k++)
         {
            float c[3];
            c[ax] = pl;
            c[a1] = (k == 1 || k == 2) ? hi[a1] : lo[a1];
            c[a2] = (k >= 2)           ? hi[a2] : lo[a2];
            q[k] = simd_make_float4(c[0], c[1], c[2], 1.0f);
            if (all) all[f * 4 + k] = q[k];
         }
         /* outward normal = sgn * axis; eye on the inner side -> far face */
         if ((ev - pl) * (float)sgn > 0.0f) continue;
         v[nv++] = q[0]; v[nv++] = q[1]; v[nv++] = q[2];
         v[nv++] = q[0]; v[nv++] = q[2]; v[nv++] = q[3];
      }
   }
   return nv;
}

static int ra_sky_box_draw(id<MTLRenderCommandEncoder> enc, simd_float4x4 mvp,
                           const simd_float4 *v, int nv, simd_float4 colour)
{
   if (!s_skyPipe || nv <= 0) return 0;
   [enc setRenderPipelineState:s_skyPipe];
   [enc setDepthStencilState:s_depthWrite];
   [enc setCullMode:MTLCullModeNone];
   [enc setVertexBytes:&mvp length:sizeof(mvp) atIndex:0];
   [enc setVertexBytes:v length:(NSUInteger)nv * sizeof(simd_float4) atIndex:1];
   [enc setFragmentBytes:&colour length:sizeof(colour) atIndex:0];
   [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:(NSUInteger)nv];
   return nv / 6;
}

/* the box bent with the geometry, all six faces subdivided, inside
 * kept per fragment. */
static int ra_sky_box_draw_bent(id<MTLRenderCommandEncoder> enc, simd_float4x4 mvp,
                                const simd_float4 all[24], simd_float4 eye, simd_float4 colour)
{
   NSUInteger T = s_fx.tess ? s_fx.tess : 1u;
   if (!s_skyTessPipe) return 0;
   [enc setRenderPipelineState:s_skyTessPipe];
   [enc setDepthStencilState:s_depthWrite];
   [enc setCullMode:MTLCullModeNone];
   [enc setVertexBytes:&mvp length:sizeof(mvp) atIndex:0];
   [enc setVertexBytes:all length:24 * sizeof(simd_float4) atIndex:1];
   [enc setVertexBytes:&eye length:sizeof(eye) atIndex:2];
   [enc setVertexBytes:&s_fx length:sizeof(s_fx) atIndex:11];
   [enc setFragmentBytes:&colour length:sizeof(colour) atIndex:0];
   [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:T * T * 6u
         instanceCount:6];
   return 6;
}

/* =====================================================: AO + SSR post
 * 3dSenVR v2's Depth AO and screen-space reflections, both
 * default OFF as in v2 (`ao`, `reflection` in 3dsen.cfg; fixed at 3D entry).
 *
 * When either is on, the eye pass of each view resolves (or renders) into
 * OUR private colour + depth pair instead of the drawable. The post passes
 * then read that pair — still in the eye pass's physical, rate-mapped layout —
 * and a composite pass writes the drawable's colour AND depth (the compositor
 * reprojects on the depth), pixel for pixel. Off, nothing here runs and the
 * eye pass is byte-for-byte the .45 one. Shader + parameter mapping:
 * ra3d_post.h. */

static id<MTLRenderPipelineState> s_linPipe, s_aoPipe, s_aoBlurPipe, s_ssrPipe, s_postCompPipe;
static id<MTLDepthStencilState>   s_postDepthAlways;
static id<MTLTexture>             s_fxColor, s_fxDepth, s_fxLin, s_aoA, s_aoB, s_ssrT;
/* Rate-map decoder parameters: ~24 KB for a 5x5 map on the M4 (far past
 * setFragmentBytes' 4 KB), so they live in buffers. A small ring, each slot
 * marked busy until its command buffer completes; a busy slot means a fresh
 * one-off buffer for that view instead of overwriting one the GPU reads. */
#define RA_POST_RRM_RING 8
static id<MTLBuffer>              s_rrmRing[RA_POST_RRM_RING];
static atomic_uint                s_rrmBusy[RA_POST_RRM_RING];
static unsigned                   s_rrmNext;
static id<MTLRasterizationRateMap> s_fakeRRM;
static int                        s_postOn;        /* pipelines built for this entry */
static int                        s_postFakeRRM;   /* RA3D_FAKE_RRM (sim test)       */
static uint32_t                   s_postDebug;     /* RA3D_POST_DEBUG 1 AO / 2 SSR   */
static uint32_t                   s_postFrames;    /* views composited since the last line */
static char                       s_postLast[256]; /* last view's targets / rate map */

static void ra_post_build_pipelines(id<MTLDevice> dev, MTLPixelFormat color, MTLPixelFormat depth)
{
   NSError *err = nil;
   s_postOn = 0;
   s_linPipe = s_aoPipe = s_aoBlurPipe = s_ssrPipe = s_postCompPipe = nil;
   s_fxColor = s_fxDepth = s_fxLin = s_aoA = s_aoB = s_ssrT = nil;
   s_fakeRRM = nil;
   if (!s_fxCfg.depth_ao && !s_fxCfg.reflection)
      return;   /* default: nothing compiled, nothing allocated */
   {
      const char *e = getenv("RA3D_FAKE_RRM");
      s_postFakeRRM = (e && atoi(e) > 0) ? 1 : 0;
      e = getenv("RA3D_POST_DEBUG");
      s_postDebug = e ? (uint32_t)atoi(e) : 0u;
   }
   if (depth == MTLPixelFormatInvalid)
   {
      RA_BeaconMark("3dpost: no depth attachment — ao/reflection OFF");
      return;
   }
   id<MTLLibrary> lib = [dev newLibraryWithSource:[NSString stringWithUTF8String:kRA3DPostShader]
                                          options:nil error:&err];
   if (!lib)
   {
      RA_BeaconMark([[NSString stringWithFormat:@"3dpost: shader compile FAILED: %@ — ao/reflection OFF",
                      err.localizedDescription] UTF8String]);
      return;
   }
   MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
   pd.vertexFunction = [lib newFunctionWithName:@"ra_post_vs"];
   pd.colorAttachments[0].pixelFormat = MTLPixelFormatR32Float;
   pd.fragmentFunction = [lib newFunctionWithName:@"ra_lin_fs"];
   s_linPipe = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
   pd.colorAttachments[0].pixelFormat = MTLPixelFormatRG16Float;
   pd.fragmentFunction = [lib newFunctionWithName:@"ra_ao_fs"];
   s_aoPipe = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
   pd.fragmentFunction = [lib newFunctionWithName:@"ra_ao_blur_fs"];
   s_aoBlurPipe = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
   pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
   pd.fragmentFunction = [lib newFunctionWithName:@"ra_ssr_fs"];
   s_ssrPipe = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
   pd.colorAttachments[0].pixelFormat = color;
   pd.depthAttachmentPixelFormat      = depth;
   if (depth == MTLPixelFormatDepth32Float_Stencil8)
      pd.stencilAttachmentPixelFormat = depth;
   pd.fragmentFunction = [lib newFunctionWithName:@"ra_post_composite_fs"];
   s_postCompPipe = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
   MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
   dd.depthCompareFunction = MTLCompareFunctionAlways;
   dd.depthWriteEnabled    = YES;
   s_postDepthAlways = [dev newDepthStencilStateWithDescriptor:dd];
   if (!s_linPipe || !s_aoPipe || !s_aoBlurPipe || !s_ssrPipe || !s_postCompPipe)
   {
      RA_BeaconMark([[NSString stringWithFormat:@"3dpost: pipeline FAILED: %@ — ao/reflection OFF",
                      err.localizedDescription] UTF8String]);
      s_linPipe = s_aoPipe = s_aoBlurPipe = s_ssrPipe = s_postCompPipe = nil;
      return;
   }
   s_postOn = 1;
   RA_BeaconMark([[NSString stringWithFormat:
      @"3dpost: pipelines built — ao %d, reflection %d (colour fmt %lu, depth fmt %lu)%s%s",
      s_fxCfg.depth_ao, s_fxCfg.reflection, (unsigned long)color, (unsigned long)depth,
      s_postFakeRRM ? ", RA3D_FAKE_RRM test rate map when the drawable has none" : "",
      s_postDebug == 1 ? ", DEBUG view: AO term" : (s_postDebug == 2 ? ", DEBUG view: SSR" : "")]
      UTF8String]);
}

static id<MTLTexture> ra_post_tex(id<MTLDevice> dev, id<MTLTexture> old, MTLPixelFormat f,
                                  NSUInteger w, NSUInteger h, NSString *label)
{
   if (old && old.width == w && old.height == h && old.pixelFormat == f) return old;
   MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f
                                  width:w height:h mipmapped:NO];
   td.usage       = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
   td.storageMode = MTLStorageModePrivate;
   id<MTLTexture> t = [dev newTextureWithDescriptor:td];
   t.label = label;
   return t;
}

/* Our pair at the drawable texture's size (which is what a rate map renders
 * into), plus the half-res AO ping-pong and the SSR trace target. */
static BOOL ra_post_targets(id<MTLDevice> dev, id<MTLTexture> color, id<MTLTexture> depth,
                            NSUInteger aoDs, NSUInteger ssrDs)
{
   if (!color || !depth) return NO;
   NSUInteger w = color.width, h = color.height;
   BOOL fresh = !(s_fxColor && s_fxColor.width == w && s_fxColor.height == h);
   s_fxColor = ra_post_tex(dev, s_fxColor, color.pixelFormat, w, h, @"RA3D post colour");
   s_fxDepth = ra_post_tex(dev, s_fxDepth, depth.pixelFormat, w, h, @"RA3D post depth");
   s_fxLin   = ra_post_tex(dev, s_fxLin, MTLPixelFormatR32Float, w, h, @"RA3D post linear depth");
   if (s_fxCfg.depth_ao)
   {
      NSUInteger aw = (w + aoDs - 1) / aoDs, ah = (h + aoDs - 1) / aoDs;
      s_aoA = ra_post_tex(dev, s_aoA, MTLPixelFormatRG16Float, aw, ah, @"RA3D AO a");
      s_aoB = ra_post_tex(dev, s_aoB, MTLPixelFormatRG16Float, aw, ah, @"RA3D AO b");
   }
   if (s_fxCfg.reflection)
      s_ssrT = ra_post_tex(dev, s_ssrT, MTLPixelFormatRGBA16Float,
                           (w + ssrDs - 1) / ssrDs, (h + ssrDs - 1) / ssrDs, @"RA3D SSR trace");
   BOOL ok = s_fxColor && s_fxDepth && s_fxLin && (!s_fxCfg.depth_ao || (s_aoA && s_aoB))
          && (!s_fxCfg.reflection || s_ssrT);
   if (fresh || !ok)
      RA_BeaconMark([[NSString stringWithFormat:
         @"3dpost: targets %lux%lu colour+depth, ao %lux%lu, ssr %lux%lu%s",
         (unsigned long)w, (unsigned long)h,
         (unsigned long)s_aoA.width, (unsigned long)s_aoA.height,
         (unsigned long)s_ssrT.width, (unsigned long)s_ssrT.height,
         ok ? "" : " — allocation FAILED, post skipped"] UTF8String]);
   return ok;
}

/* RA3D_FAKE_RRM (dev hook, simulator): the sim's compositor gives no rate
 * map, so the foveated path would never run there. This makes one — a 5x5
 * grid, 0.4 at the edges, 1.0 in the middle — over the drawable's size, so the
 * eye pass is really rate-mapped into our pair and every decoder call in the
 * post shaders is exercised; the composite then un-warps to the screen-space
 * drawable (flags.y). Never set on a device build's launch. */
static id<MTLRasterizationRateMap> ra_post_fake_rrm(id<MTLDevice> dev, NSUInteger w, NSUInteger h)
{
   static int s_logged;
   MTLSize scr = MTLSizeMake(w, h, 0);
   if (s_fakeRRM && s_fakeRRM.screenSize.width == w && s_fakeRRM.screenSize.height == h)
      return s_fakeRRM;
   s_fakeRRM = nil;
   if (![dev supportsRasterizationRateMapWithLayerCount:1])
   {
      if (!s_logged++) RA_BeaconMark("3dpost: RA3D_FAKE_RRM — device has no rasterization rate maps");
      return nil;
   }
   const float rates[5] = { 0.4f, 0.7f, 1.0f, 0.7f, 0.4f };
   MTLRasterizationRateLayerDescriptor *ld = [[MTLRasterizationRateLayerDescriptor alloc]
      initWithSampleCount:MTLSizeMake(5, 5, 0) horizontal:rates vertical:rates];
   MTLRasterizationRateMapDescriptor *md =
      [MTLRasterizationRateMapDescriptor rasterizationRateMapDescriptorWithScreenSize:scr layer:ld];
   s_fakeRRM = [dev newRasterizationRateMapWithDescriptor:md];
   if (s_fakeRRM)
   {
      MTLSize ps = [s_fakeRRM physicalSizeForLayer:0];
      RA_BeaconMark([[NSString stringWithFormat:
         @"3dpost: RA3D_FAKE_RRM test rate map %lux%lu -> physical %lux%lu",
         (unsigned long)w, (unsigned long)h, (unsigned long)ps.width, (unsigned long)ps.height]
         UTF8String]);
   }
   return s_fakeRRM;
}

static void ra_post_bind_rrm(id<MTLRenderCommandEncoder> e, id<MTLBuffer> b, const uint8_t *none)
{
   if (b) [e setFragmentBuffer:b offset:0 atIndex:1];
   else   [e setFragmentBytes:none length:16 atIndex:1];   /* never decoded (flags.x 0) */
}

/* One view's post chain. `fv` is complete except tex/lo/flags.x, filled here.
 * remap: the target is screen space (fake rate map only). */
static void ra_post_encode(id<MTLCommandBuffer> cb, Ra3dFxView *fv, id<MTLRasterizationRateMap> rrm,
                           BOOL remap, id<MTLTexture> colorTex, id<MTLTexture> depthTex,
                           NSUInteger slice)
{
   static const uint8_t kNoMap[16];
   id<MTLBuffer> rmBuf = nil;
   NSUInteger rmLen = 0;
   fv->flags.x = 0u;
   if (rrm)
   {
      MTLSizeAndAlign sa = rrm.parameterBufferSizeAndAlign;
      if (sa.size > 0)
      {
         unsigned k = s_rrmNext++ % RA_POST_RRM_RING;
         if (atomic_load(&s_rrmBusy[k]) == 0u)
         {
            if (!s_rrmRing[k] || s_rrmRing[k].length < sa.size)
               s_rrmRing[k] = [colorTex.device newBufferWithLength:sa.size
                                                           options:MTLResourceStorageModeShared];
            rmBuf = s_rrmRing[k];
            if (rmBuf)
            {
               atomic_store(&s_rrmBusy[k], 1u);
               [cb addCompletedHandler:^(id<MTLCommandBuffer> b) { (void)b; atomic_store(&s_rrmBusy[k], 0u); }];
            }
         }
         else
            rmBuf = [colorTex.device newBufferWithLength:sa.size options:MTLResourceStorageModeShared];
         if (rmBuf)
         {
            [rrm copyParameterDataToBuffer:rmBuf offset:0];   /* CPU write, before commit */
            rmLen = sa.size;
            fv->flags.x = 1u;
         }
      }
   }
   if (rrm && !fv->flags.x)
   {  /* cannot decode the map: copy the eye pass through, effects off */
      static int s_warned;
      if (!s_warned++)
         RA_BeaconMark([[NSString stringWithFormat:
            @"3dpost: rate map parameters (%lu B) not decodable — effects skipped, copy only",
            (unsigned long)rrm.parameterBufferSizeAndAlign.size] UTF8String]);
      fv->flags.z = fv->flags.w = 0u;
      remap = NO;
   }
   (void)rmLen;
   fv->flags.y = remap ? 1u : 0u;
   fv->tex = simd_make_float4((float)s_fxColor.width, (float)s_fxColor.height,
                              1.0f / (float)s_fxColor.width, 1.0f / (float)s_fxColor.height);
   fv->lo  = simd_make_float4(s_aoA ? (float)s_aoA.width : 1.0f, s_aoA ? (float)s_aoA.height : 1.0f,
                              s_ssrT ? (float)s_ssrT.width : 1.0f, s_ssrT ? (float)s_ssrT.height : 1.0f);
   fv->dbg = simd_make_uint4(s_postDebug, 0, 0, 0);

   MTLRenderPassDescriptor *p;
   id<MTLRenderCommandEncoder> e;
   if (fv->flags.z || fv->flags.w)
   {  /* linear depth once (0 = sky / sky box); every later tap reads it */
      p = [MTLRenderPassDescriptor renderPassDescriptor];
      p.colorAttachments[0].texture     = s_fxLin;
      p.colorAttachments[0].loadAction  = MTLLoadActionDontCare;
      p.colorAttachments[0].storeAction = MTLStoreActionStore;
      e = [cb renderCommandEncoderWithDescriptor:p];
      e.label = @"RA3D post linear depth";
      [e setViewport:(MTLViewport){ 0, 0, (double)s_fxLin.width, (double)s_fxLin.height, 0, 1 }];
      [e setRenderPipelineState:s_linPipe];
      [e setFragmentBytes:fv length:sizeof(*fv) atIndex:0];
      ra_post_bind_rrm(e, rmBuf, kNoMap);
      [e setFragmentTexture:s_fxDepth atIndex:0];
      [e setFragmentTexture:s_fxColor atIndex:1];
      [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
      [e endEncoding];
   }
   if (fv->flags.z)
   {
      const simd_int2 sx = { 1, 0 }, sy = { 0, 1 };
      for (int k = 0; k < 3; k++)
      {
         id<MTLTexture> dst = (k == 1) ? s_aoB : s_aoA;
         p = [MTLRenderPassDescriptor renderPassDescriptor];
         p.colorAttachments[0].texture     = dst;
         p.colorAttachments[0].loadAction  = MTLLoadActionDontCare;
         p.colorAttachments[0].storeAction = MTLStoreActionStore;
         e = [cb renderCommandEncoderWithDescriptor:p];
         e.label = k == 0 ? @"RA3D AO" : @"RA3D AO blur";
         [e setViewport:(MTLViewport){ 0, 0, (double)dst.width, (double)dst.height, 0, 1 }];
         [e setRenderPipelineState:k == 0 ? s_aoPipe : s_aoBlurPipe];
         [e setFragmentBytes:fv length:sizeof(*fv) atIndex:0];
         if (k == 0)
         {
            ra_post_bind_rrm(e, rmBuf, kNoMap);
            [e setFragmentTexture:s_fxLin atIndex:0];
         }
         else
         {
            [e setFragmentBytes:(k == 1 ? &sx : &sy) length:sizeof(simd_int2) atIndex:2];
            [e setFragmentTexture:(k == 1 ? s_aoA : s_aoB) atIndex:0];
         }
         [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
         [e endEncoding];
      }
   }
   if (fv->flags.w)
   {
      p = [MTLRenderPassDescriptor renderPassDescriptor];
      p.colorAttachments[0].texture     = s_ssrT;
      p.colorAttachments[0].loadAction  = MTLLoadActionDontCare;
      p.colorAttachments[0].storeAction = MTLStoreActionStore;
      e = [cb renderCommandEncoderWithDescriptor:p];
      e.label = @"RA3D SSR trace";
      [e setViewport:(MTLViewport){ 0, 0, (double)s_ssrT.width, (double)s_ssrT.height, 0, 1 }];
      [e setRenderPipelineState:s_ssrPipe];
      [e setFragmentBytes:fv length:sizeof(*fv) atIndex:0];
      ra_post_bind_rrm(e, rmBuf, kNoMap);
      [e setFragmentTexture:s_fxLin atIndex:0];
      [e setFragmentTexture:s_fxColor atIndex:1];
      [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
      [e endEncoding];
   }
   p = [MTLRenderPassDescriptor renderPassDescriptor];
   p.colorAttachments[0].texture     = colorTex;
   p.colorAttachments[0].slice       = slice;
   p.colorAttachments[0].loadAction  = MTLLoadActionDontCare;
   p.colorAttachments[0].storeAction = MTLStoreActionStore;
   p.depthAttachment.texture         = depthTex;
   p.depthAttachment.slice           = slice;
   p.depthAttachment.loadAction      = MTLLoadActionDontCare;
   p.depthAttachment.storeAction     = MTLStoreActionStore;
   if (depthTex.pixelFormat == MTLPixelFormatDepth32Float_Stencil8)
   {
      p.stencilAttachment.texture     = depthTex;
      p.stencilAttachment.slice       = slice;
      p.stencilAttachment.loadAction  = MTLLoadActionClear;
      p.stencilAttachment.storeAction = MTLStoreActionStore;
   }
   e = [cb renderCommandEncoderWithDescriptor:p];
   e.label = @"RA3D post composite";
   [e setViewport:(MTLViewport){ 0, 0, (double)colorTex.width, (double)colorTex.height, 0, 1 }];
   [e setRenderPipelineState:s_postCompPipe];
   [e setDepthStencilState:s_postDepthAlways];
   [e setFragmentBytes:fv length:sizeof(*fv) atIndex:0];
   ra_post_bind_rrm(e, rmBuf, kNoMap);
   [e setFragmentTexture:s_fxColor atIndex:0];
   [e setFragmentTexture:s_fxDepth atIndex:1];
   [e setFragmentTexture:(fv->flags.z ? s_aoA : s_fxColor) atIndex:2];
   [e setFragmentTexture:(fv->flags.w ? s_ssrT : s_fxColor) atIndex:3];
   [e setFragmentTexture:s_fxLin atIndex:4];
   [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
   [e endEncoding];

   s_postFrames++;
   if (rrm)
   {
      MTLSize ps = [rrm physicalSizeForLayer:0];
      snprintf(s_postLast, sizeof(s_postLast),
               "rate map %s (screen %lux%lu -> physical %lux%lu, %lu B params in a buffer)",
               remap ? "FAKE test" : "compositor", (unsigned long)rrm.screenSize.width,
               (unsigned long)rrm.screenSize.height, (unsigned long)ps.width,
               (unsigned long)ps.height, (unsigned long)rmLen);
   }
   else
      snprintf(s_postLast, sizeof(s_postLast), "no rate map (unfoveated drawable)");
}

/* The view-dependent half of the parameter block. */
static void ra_post_view(Ra3dFxView *fv, simd_float4x4 proj, MTLViewport vp,
                         simd_float4x4 eyeFromOrigin, simd_float4x4 panel)
{
   memset(fv, 0, sizeof(*fv));
   ra3d_post_params(&s_fxCfg, fv);
   fv->proj    = proj;
   fv->invProj = simd_inverse(proj);
   fv->vp      = simd_make_float4((float)vp.originX, (float)vp.originY,
                                  (float)vp.width, (float)vp.height);
   simd_float4x4 vfn = simd_mul(eyeFromOrigin, simd_mul(panel, s_geoQ));
   float mpp = simd_length(vfn.columns[1].xyz);   /* NES y px: square in metres */
   if (!(mpp > 1e-7f)) mpp = 1e-3f;
   fv->rotX = simd_make_float4(simd_normalize(vfn.columns[0].xyz), mpp);
   fv->rotY = simd_make_float4(simd_normalize(vfn.columns[1].xyz), 0.0f);
   fv->rotZ = simd_make_float4(simd_normalize(vfn.columns[2].xyz), 0.0f);
   fv->org  = simd_make_float4(vfn.columns[3].xyz, 1.0f);
   simd_float4 up = simd_mul(eyeFromOrigin, simd_make_float4(0.0f, 1.0f, 0.0f, 0.0f));
   fv->up   = simd_make_float4(simd_normalize(up.xyz), 0.0f);
   fv->flags = simd_make_uint4(0u, 0u, s_fxCfg.depth_ao ? 1u : 0u, s_fxCfg.reflection ? 1u : 0u);
}

static void ra_geo_encode(id<MTLRenderCommandEncoder> enc, simd_float4x4 base,
                          simd_float4x4 baseUI)
{
   simd_float4x4 bases[2] = { base, baseUI };
   uint32_t r, counts[2];
   if (!s_geoInstTotal || !s_geoCellCount || !s_geoPipe || !s_voxVB || !s_voxPieceBuf
       || !s_geoAtlasBuf || !s_voxFrame.run_count || !s_geoDtexBuf)
      return;
   counts[0] = s_geoInstTotal; counts[1] = s_geoCellCount;
   [enc setVertexBuffer:s_voxVB        offset:0 atIndex:0];
   [enc setVertexBuffer:s_geoInstBuf   offset:0 atIndex:1];
   [enc setVertexBytes:bases length:sizeof(bases) atIndex:2];
   [enc setVertexBuffer:s_voxPieceBuf  offset:0 atIndex:3];
   [enc setVertexBytes:counts length:sizeof(counts) atIndex:4];
   [enc setFragmentBuffer:s_geoInstBuf offset:0 atIndex:0];
   [enc setFragmentBuffer:s_geoCellBuf offset:0 atIndex:1];
   [enc setFragmentBuffer:s_geoPalBuf  offset:0 atIndex:2];
   [enc setFragmentBytes:&s_geoCellCount length:sizeof(s_geoCellCount) atIndex:3];
   [enc setFragmentBuffer:s_geoDtexBuf offset:0 atIndex:7];
   [enc setFragmentBytes:&s_geoDtexCount length:sizeof(s_geoDtexCount) atIndex:8];
   [enc setFragmentBuffer:s_geoAtlasBuf offset:0 atIndex:9];
   [enc setFragmentBytes:&s_geoAtlasTiles length:sizeof(s_geoAtlasTiles) atIndex:10];
   {
      Ra3dGeoLight lt;
      ra_geo_light_now(&lt);
      [enc setFragmentBytes:&lt length:sizeof(lt) atIndex:4];
   }
   /* the shadow map (or the 1x1 placeholder with on = 0) */
   [enc setVertexBytes:&s_shadow length:sizeof(s_shadow) atIndex:5];
   [enc setFragmentBytes:&s_shadow length:sizeof(s_shadow) atIndex:6];
   [enc setFragmentTexture:(s_shadow.on && s_shadowTex) ? s_shadowTex : s_shadowDummy
                   atIndex:1];
   {
      Ra3dGeoView vw;
      ra_geo_view_now(&vw);
      [enc setFragmentBytes:&vw length:sizeof(vw) atIndex:5];
   }
   [enc setVertexBytes:&s_fx length:sizeof(s_fx) atIndex:11];
   [enc setFragmentBytes:&s_fx length:sizeof(s_fx) atIndex:11];

   if (s_fx.bend && s_fx.backdrop && s_geoTessPipe)
   {  /* the Backdrop, subdivided so it bends (ra_geo_tess_vs) */
      [enc setRenderPipelineState:s_geoTessPipe];
      [enc setDepthStencilState:s_depthWrite];
      [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0
              vertexCount:(NSUInteger)s_fx.tess * s_fx.tess * 6u instanceCount:6];
   }
   [enc setRenderPipelineState:s_geoPipe];
   [enc setDepthStencilState:s_depthWrite];
   for (r = 0; r < s_voxFrame.run_count; r++)
   {
      const Ra3dVoxRun *run = &s_voxFrame.runs[r];
      if (run->first + run->count > s_voxVBCount) continue;
      if (run->blend)
      {
         /* translucent shapes as 3dSen draws them: after every opaque run, each
          * mesh run as two passes back to back: (1) depth only, depth
          * written, so only the NEAREST
          * surface of a translucent block takes colour and its own back
          * faces never show through; (2) SrcAlpha / OneMinusSrcAlpha, no depth
          * write, GreaterEqual (reverse-Z) passes exactly those fragments. */
         if (!s_geoBlendPipe || !s_geoDepthPipe) break;
         [enc setRenderPipelineState:s_geoDepthPipe];
         [enc setDepthStencilState:s_depthWrite];
         [enc drawPrimitives:MTLPrimitiveTypeTriangle
                 vertexStart:run->first
                 vertexCount:run->count
               instanceCount:run->piece_count
                baseInstance:run->piece_first];
         [enc setRenderPipelineState:s_geoBlendPipe];
         [enc setDepthStencilState:s_depthTestNoWrite];
      }
      [enc drawPrimitives:MTLPrimitiveTypeTriangle
              vertexStart:run->first
              vertexCount:run->count
            instanceCount:run->piece_count
             baseInstance:run->piece_first];
   }
}

/* ------------------------------------------------------- alpha dump (dev)
 *
 * RA3D_ALPHA_DUMP="t1,t2,..." (seconds after the first immersive frame): copy
 * view 0's colour target to the CPU and write two PNGs into Documents —
 * `alpha-dump-<t>.png` (the colour as stored, ALPHA FORCED OPAQUE) and
 * `alpha-viz-<t>.png` (grey = alpha 1 and finite, MAGENTA = alpha < 0.99,
 * GREEN = NaN/Inf in any channel, RED = a channel < 0, YELLOW = a channel > 1
 * on a float target) — plus a beacon line counting each class. This is what
 * the compositor gets: anything not grey is a hole or garbage in mixed
 * immersion. Needs RA3D_COLORFMT's colorUsage (shaderRead) to blit. */
static double s_dumpT0 = 0.0;
static double s_dumpAt[8];
static int    s_dumpN = -1, s_dumpNext = 0;

static void ra_alpha_dump_write(NSData *px, unsigned w, unsigned h, unsigned bpr,
                                MTLPixelFormat f, double t)
{
   const uint8_t *src = (const uint8_t *)px.bytes;
   uint8_t *col = (uint8_t *)malloc((size_t)w * h * 4);
   uint8_t *viz = (uint8_t *)malloc((size_t)w * h * 4);
   unsigned x, y, nAlpha = 0, nNan = 0, nNeg = 0, nOver = 0, nAlphaBlack = 0;
   if (!col || !viz) { free(col); free(viz); return; }
   for (y = 0; y < h; y++)
      for (x = 0; x < w; x++)
      {
         float c[4];
         const uint8_t *p = src + (size_t)y * bpr;
         int k, nan = 0, neg = 0, over = 0;
         uint8_t *o = col + ((size_t)y * w + x) * 4, *v = viz + ((size_t)y * w + x) * 4;
         if (f == MTLPixelFormatRGBA16Float)
         {
            const _Float16 *hp = (const _Float16 *)(p + (size_t)x * 8);
            for (k = 0; k < 4; k++) c[k] = (float)hp[k];
         }
         else if (f == MTLPixelFormatBGRA8Unorm || f == MTLPixelFormatBGRA8Unorm_sRGB)
         {
            const uint8_t *bp = p + (size_t)x * 4;
            c[0] = bp[2] / 255.0f; c[1] = bp[1] / 255.0f; c[2] = bp[0] / 255.0f; c[3] = bp[3] / 255.0f;
         }
         else
         {
            const uint8_t *bp = p + (size_t)x * 4;
            for (k = 0; k < 4; k++) c[k] = bp[k] / 255.0f;
         }
         for (k = 0; k < 4; k++)
         {
            if (!isfinite(c[k])) nan = 1;
            else if (c[k] < -0.001f) neg = 1;
            else if (c[k] > 1.001f) over = 1;
         }
         for (k = 0; k < 3; k++)
         {  /* float targets hold LINEAR values: encode for the PNG */
            float l = isfinite(c[k]) ? fminf(fmaxf(c[k], 0.0f), 1.0f) : 0.0f;
            if (f == MTLPixelFormatRGBA16Float)
               l = l <= 0.0031308f ? l * 12.92f : 1.055f * powf(l, 1.0f / 2.4f) - 0.055f;
            o[k] = (uint8_t)(l * 255.0f + 0.5f);
         }
         o[3] = 255;
         if (nan)                      { nNan++;  v[0] = 0;   v[1] = 255; v[2] = 0;   }
         else if (neg)                 { nNeg++;  v[0] = 255; v[1] = 0;   v[2] = 0;   }
         else if (over)                { nOver++; v[0] = 255; v[1] = 255; v[2] = 0;   }
         else if (c[3] < 0.99f)
         {
            nAlpha++;
            if (c[0] + c[1] + c[2] < 0.03f) nAlphaBlack++;
            v[0] = 255; v[1] = 0; v[2] = 255;
         }
         else { uint8_t g = (uint8_t)(64 + (o[0] + o[1] + o[2]) / 6); v[0] = v[1] = v[2] = g; }
         v[3] = 255;
      }
   {
      NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
      CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
      uint8_t *bufs[2] = { col, viz };
      const char *names[2] = { "alpha-dump", "alpha-viz" };
      int b;
      for (b = 0; b < 2; b++)
      {
         CGContextRef ctx = CGBitmapContextCreate(bufs[b], w, h, 8, (size_t)w * 4, cs,
                                                  kCGImageAlphaNoneSkipLast | kCGBitmapByteOrderDefault);
         CGImageRef img = ctx ? CGBitmapContextCreateImage(ctx) : NULL;
         if (img)
         {
            NSString *path = [docs stringByAppendingPathComponent:
                                 [NSString stringWithFormat:@"%s-%.0f.png", names[b], t]];
            CGImageDestinationRef d = CGImageDestinationCreateWithURL(
               (__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
            if (d) { CGImageDestinationAddImage(d, img, NULL); CGImageDestinationFinalize(d); CFRelease(d); }
            CGImageRelease(img);
         }
         if (ctx) CGContextRelease(ctx);
      }
      CGColorSpaceRelease(cs);
   }
   free(col); free(viz);
   RA_BeaconMark([[NSString stringWithFormat:
      @"alphadump: t=%.0f fmt %lu %ux%u — alpha<0.99 %u (%u of them black), NaN/Inf %u, "
       "negative %u, >1 %u of %u px",
      t, (unsigned long)f, w, h, nAlpha, nAlphaBlack, nNan, nNeg, nOver, w * h] UTF8String]);
}

static void ra_alpha_dump_maybe(id<MTLCommandBuffer> cb, cp_drawable_t drawable)
{
   double now = CACurrentMediaTime();
   if (s_dumpN < 0)
   {
      const char *e = getenv("RA3D_ALPHA_DUMP");
      s_dumpN = 0; s_dumpT0 = now;
      if (e)
      {
         char *dup = strdup(e), *save = NULL, *tok;
         for (tok = strtok_r(dup, ",", &save); tok && s_dumpN < 8; tok = strtok_r(NULL, ",", &save))
            s_dumpAt[s_dumpN++] = atof(tok);
         free(dup);
      }
   }
   if (s_dumpNext >= s_dumpN || now - s_dumpT0 < s_dumpAt[s_dumpNext]) return;
   {
      double t = s_dumpAt[s_dumpNext++];
      cp_view_t view = cp_drawable_get_view(drawable, 0);
      cp_view_texture_map_t tmap = cp_view_get_view_texture_map(view);
      id<MTLTexture> tex = cp_drawable_get_color_texture(drawable,
                              cp_view_texture_map_get_texture_index(tmap));
      size_t slice = cp_view_texture_map_get_slice_index(tmap);
      MTLViewport vp = cp_view_texture_map_get_viewport(tmap);
      unsigned w = (unsigned)vp.width, h = (unsigned)vp.height;
      unsigned bpp = tex.pixelFormat == MTLPixelFormatRGBA16Float ? 8u : 4u;
      unsigned bpr = w * bpp;
      MTLPixelFormat f = tex.pixelFormat;
      id<MTLBuffer> buf;
      id<MTLBlitCommandEncoder> bl;
      if (tex.framebufferOnly || !w || !h)
      {
         RA_BeaconMark("alphadump: colour target is framebufferOnly — cannot read back");
         return;
      }
      buf = [cb.device newBufferWithLength:(NSUInteger)bpr * h options:MTLResourceStorageModeShared];
      bl  = [cb blitCommandEncoder];
      [bl copyFromTexture:tex sourceSlice:slice sourceLevel:0
             sourceOrigin:MTLOriginMake((NSUInteger)vp.originX, (NSUInteger)vp.originY, 0)
               sourceSize:MTLSizeMake(w, h, 1)
                 toBuffer:buf destinationOffset:0
    destinationBytesPerRow:bpr destinationBytesPerImage:(NSUInteger)bpr * h];
      [bl endEncoding];
      [cb addCompletedHandler:^(id<MTLCommandBuffer> b) {
         (void)b;
         NSData *d = [NSData dataWithBytes:buf.contents length:(NSUInteger)bpr * h];
         dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            ra_alpha_dump_write(d, w, h, bpr, f, t);
         });
      }];
   }
}

/* ------------------------------------------------------------- session report */

static bool s_reportWritten = false;

static void ra_write_report(cp_drawable_t drawable, bool layered, unsigned gw, unsigned gh)
{
   if (s_reportWritten)
      return;
   cp_view_t   view = cp_drawable_get_view(drawable, 0);
   MTLViewport vp   = cp_view_texture_map_get_viewport(cp_view_get_view_texture_map(view));
   simd_float4x4 proj = matrix_identity_float4x4;
   if (__builtin_available(visionOS 2.0, *))
      proj = cp_drawable_compute_projection(drawable, cp_axis_direction_convention_right_up_back, 0);
   double m00 = fabs(proj.columns[0].x), m11 = fabs(proj.columns[1].y);
   double fovH = (m00 > 1e-6) ? 2.0 * atan(1.0 / m00) : 0.0;
   double fovV = (m11 > 1e-6) ? 2.0 * atan(1.0 / m11) : 0.0;
   if (vp.width < 1 || fovH < 1e-4 || fovV < 1e-4)
      return;

   double panAngH = 2.0 * atan((s_width  * 0.5) / s_dist);
   double panAngV = 2.0 * atan((s_height * 0.5) / s_dist);
   double footH   = panAngH * (vp.width / fovH);
   double footV   = panAngV * (vp.height / fovV);
   float  spread  = s_stereo * RA_STEREO_SPREAD_FRACTION * s_dist;
   double arcmin  = (s_dist - spread > 0.1)
                  ? 0.063 * (1.0 / (s_dist - spread) - 1.0 / s_dist) * (180.0 / M_PI) * 60.0
                  : 0.0;

   NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
   NSString *report = [NSString stringWithFormat:
      @"RetroArch visionOS stereoscopic 3D — session report\n"
       "==================================================\n"
       "Mode: %@\n"
       "\n"
       "Compositor drawable (per eye): %.0f x %.0f px, FOV %.1f x %.1f deg\n"
       "Source image: %u x %u\n"
       "Screen: %.2f m wide x %.2f m tall at %.2f m  (%.1f x %.1f deg)\n"
       "Screen footprint in drawable: %.0f x %.0f px\n"
       "\n"
       "Stereo Depth %.0f%%  ->  %.2f m between adjacent planes\n"
       "  sprites-behind %.2f m | background %.2f m | sprites-front %.2f m\n"
       "  vergence difference, background to front layer: %.1f arcmin\n"
       "  (~1 arcmin is the threshold of stereo perception; 20-40 is a strong\n"
       "   but comfortable pop; past ~60 the eyes start to fight to fuse.)\n",
      layered ? @"layered stereo — 3 depth planes from the core"
              : @"flat composite — menu is up, or this core has no layer support",
      (double)vp.width, (double)vp.height, fovH * 180.0 / M_PI, fovV * 180.0 / M_PI,
      gw, gh,
      (double)s_width, (double)s_height, (double)s_dist,
      panAngH * 180.0 / M_PI, panAngV * 180.0 / M_PI, footH, footV,
      (double)(s_stereo * 100.0f), (double)spread,
      (double)(s_dist + spread), (double)s_dist, (double)(s_dist - spread), arcmin];

   [report writeToFile:[docs stringByAppendingPathComponent:@"ra-vp3d-report.log"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
   NSLog(@"[RA3D] %s | footprint %.0fx%.0f | stereo %.0f%% (%.1f arcmin)",
         layered ? "layered" : "flat", footH, footV, (double)(s_stereo * 100.0f), arcmin);
   s_reportWritten = true;
}

/* ------------------------------------------------------------------ the loop */

void RA_Immersive_Run(cp_layer_renderer_t layer_renderer)
{
   id<MTLCommandQueue> queue       = nil;
   int                 notifyEnded = 0;
   int                 running     = 1;

   ra_imm_stop = 0; ra_imm_running = 1; ra_imm_frames = 0;
   s_haveAnchor = false; s_reportWritten = false; s_planeFrame = 0xFFFFFFFFu;

   ar_world_tracking_configuration_t wtc = ar_world_tracking_configuration_create();
   ar_world_tracking_provider_t      wtp = ar_world_tracking_provider_create(wtc);
   ar_session_t                      ses = ar_session_create();
   ar_data_providers_t               dps = ar_data_providers_create_with_data_providers(wtp, NULL);
   ar_session_run(ses, dps);

   NSLog(@"[RA3D] stereoscopic loop started (ARKit world tracking running)");

   /* Spatial light gun (RAVisionGun.m). Idempotent, and a
    * complete no-op unless a spatial controller is paired or the mock pose
    * source is on — no accessory, no provider, no per-frame work. */
   ra_vision_camera_load_cfg();   /* also resets to the home pose */
   ra_vision_gun_start();

   while (running)
   {
      if (ra_imm_stop) { NSLog(@"[RA3D] stop requested (frames=%d)", ra_imm_frames); break; }

      switch (cp_layer_renderer_get_state(layer_renderer))
      {
         case cp_layer_renderer_state_paused:
            cp_layer_renderer_wait_until_running(layer_renderer);
            continue;
         case cp_layer_renderer_state_invalidated:
            NSLog(@"[RA3D] layer invalidated (frames=%d)", ra_imm_frames);
            notifyEnded = 1; running = 0;
            continue;
         default:
            break;
      }

      @autoreleasepool
      {
         cp_frame_t frame = cp_layer_renderer_query_next_frame(layer_renderer);
         if (frame == NULL) continue;

         cp_frame_timing_t timing = cp_frame_predict_timing(frame);
         cp_frame_start_update(frame);
         cp_frame_end_update(frame);
         cp_time_wait_until(cp_frame_timing_get_optimal_input_time(timing));
         cp_frame_start_submission(frame);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
         cp_drawable_t drawable = cp_frame_query_drawable(frame);
#pragma clang diagnostic pop
         /* no drawable means the frame is already invalid — the
          * space is being dismissed (Home, another app, Crown). Ending its
          * submission is a client bug that CompositorServices aborts on
          * (SIGABRT "cp_frame_end_submission() failed because the frame is not
          * valid"), which killed the app before the background notifications
          * — and camera save — could run. Apple's sample loop just
          * drops the frame; the state check at the top then sees the
          * invalidated layer and leaves. */
         if (drawable == NULL)
         {
            static int s_noDrawN;
            if (s_noDrawN++ < 4)
               RA_BeaconMark("3dloop: no drawable for the frame (space going away) — dropped, not submitted");
            continue;
         }

         if (queue == nil)
         {
            id<MTLTexture> t0 = cp_drawable_get_color_texture(drawable, 0);
            queue       = [t0.device newCommandQueue];
            queue.label = @"RA 3D compositor";
            ra_build_pipelines(t0.device, t0.pixelFormat,
                               cp_drawable_get_depth_texture(drawable, 0).pixelFormat);
            NSLog(@"[RA3D] drawable %lux%lu views=%zu", (unsigned long)t0.width,
                  (unsigned long)t0.height, cp_drawable_get_view_count(drawable));
         }
         id<MTLDevice> dev = cp_drawable_get_color_texture(drawable, 0).device;
         /* the pipelines were built for s_msaaSamples; if the targets
          * cannot be made, rebuild them single-sample once instead of
          * encoding a sample-count mismatch. */
         if (s_msaaSamples > 1 && !ra_msaa_targets(dev, cp_drawable_get_color_texture(drawable, 0),
                                                   cp_drawable_get_depth_texture(drawable, 0)))
         {
            id<MTLTexture> t0 = cp_drawable_get_color_texture(drawable, 0);
            s_msaaCfg = 0;
            ra_build_pipelines(dev, t0.pixelFormat,
                               cp_drawable_get_depth_texture(drawable, 0).pixelFormat);
         }

         CFTimeInterval presTime = cp_time_to_cf_time_interval(
            cp_frame_timing_get_presentation_time(cp_drawable_get_frame_timing(drawable)));
         ar_device_anchor_t anchor = ar_device_anchor_create();
         ar_device_anchor_query_status_t st =
            ar_world_tracking_provider_query_device_anchor_at_timestamp(wtp, presTime, anchor);
         cp_drawable_set_device_anchor(drawable, anchor);

         /* The gun's pose is predicted to the TRACKABLE-anchor time, which is
          * what the accessory header's own CompositorServices example uses —
          * and every ARKit accessory call is AR_MT_UNSAFE, so this is the only
          * thread that may touch it. */
         {
            CFTimeInterval gunTime = cp_time_to_cf_time_interval(
               cp_frame_timing_get_trackable_anchor_time(
                  cp_drawable_get_frame_timing(drawable)));
            ra_vision_gun_tick((double)gunTime,
                               s_haveAnchor ? s_frozenHead : matrix_identity_float4x4);
         }

         /* Freeze placement only once tracking has CONVERGED — the first frames
          * report success with a near-identity pose, which drops the screen on
          * the floor behind you. */
         if (!s_haveAnchor && st == ar_device_anchor_query_status_success && ra_imm_frames > 30)
         {
            s_frozenHead = ar_device_anchor_get_origin_from_anchor_transform(anchor);
            s_haveAnchor = true;
            NSLog(@"[RA3D] screen anchored at head");
         }

         id<MTLCommandBuffer> cb = [queue commandBuffer];
         cb.label = @"RA 3D frame";

         /* Layered when the core publishes planes AND the menu is not up — the
          * menu is drawn by the frontend, so it only exists in the composite. */
         ra_vision_planes_t planes = {0};
         bool layered = !ra_vision_menu_alive()
                     && ra_vision_layers_fetch(&planes)
                     && planes.count > 0;

         /* 3dSen shape mode. The poll reaches INTO the core — it
          * resolves the loaded ROM's profile and turns the PPU's capture on —
          * so it may only run on a frame where the core has just published a
          * plane set. That single fact is the proof the emulator is alive and
          * running: `layered` is false while the menu is up, while content is
          * being loaded or closed, and for any core without the stream.
          *
          * .28 polled unconditionally, which is how entering 3D from the menu
          * armed the capture against RetroArch's *previous* ROM basename (the
          * frontend keeps RARCH_PATH_BASENAME after content closes) and then
          * held pointers into a PPU that the next content load destroyed. */
         if (!layered)
            ra_vision_scene_suspend();
         else if ((ra_imm_frames % 60) == 0)
            ra_vision_scene_poll();
         const Ra3dGeoFrame *geo = NULL;
         int geoNew = 0;

         void          *borrowed = NULL;
         id<MTLTexture> flatTex  = nil;
         if (layered)
         {
            ra_upload_planes(dev, &planes);
            s_planeAspect = planes.display_aspect;
            if (ra_vision_scene_mode_on())
            {
               geo = ra_vision_scene_fetch(&geoNew);
               if (geo && (geoNew || s_geoFrame != geo->frame))
               { ra_geo_upload(dev, geo); s_geoFrame = geo->frame; }
               else if (!geo)
               { s_geoInstTotal = 0; s_geoFrame = 0xFFFFFFFFu; s_geoMinZ = 0.0f; }
            }
            else
            { s_geoInstTotal = 0; s_geoFrame = 0xFFFFFFFFu; s_geoMinZ = 0.0f; }
            /* the shadow map, committed ahead of this frame's eye
             * passes on the same queue */
            ra_geo_shadow_prepare(dev, queue);
         }
         else
         {
            /* Flat composite: no geometry this frame, and nothing from the
             * previous content may survive into the next. */
            s_geoInstTotal = 0;
            s_geoFrame     = 0xFFFFFFFFu;
            s_geoMinZ      = 0.0f;
            s_planeAspect  = 0.0f;
            borrowed = ra_vision_offscreen_borrow_latest();
            flatTex  = (__bridge id<MTLTexture>)borrowed;
            if (flatTex && flatTex.mipmapLevelCount > 1)
            {
               id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
               [blit generateMipmapsForTexture:flatTex];
               [blit endEncoding];
            }
         }

         simd_float4x4 head            = s_haveAnchor ? s_frozenHead : matrix_identity_float4x4;
         simd_float4x4 originFromDevice = ar_device_anchor_get_origin_from_anchor_transform(anchor);

         /* ONE camera matrix for the whole frame, in front of every
          * world-locked thing the LAYERED path draws.  The flat composite (the
          * menu) is deliberately left alone — a tilted menu would be a bug, and
          * the camera is identity anyway until the user moves it.
          *
          * The gate is the conflict story: the right stick and L2/R2 are dead
          * inputs on an NES pad but are C-buttons and Z on an N64 one, so the
          * camera only claims them while a four-plane NES set is on screen. */
         ra_vision_camera_gate(layered && planes.count >= 4);
         ra_lc_update(layered && planes.count >= 4);
         simd_float4x4 cam = layered ? ra_camera_matrix(head, NULL, NULL)
                                     : matrix_identity_float4x4;

         /* Far to near.  The background sits exactly ON the panel, so moving
          * Stereo Depth never moves the screen the user placed — only the
          * layers around it. */
         float spread = s_stereo * RA_STEREO_SPREAD_FRACTION * s_dist;
         /* Plane distances, far to near.  A core returning THREE planes means
          * NES (sprites-behind / background / sprites-front); TWO means SNES,
          * which has no exposed behind-the-background sprite bit — so its
          * planes are background-then-sprites and must start at the panel, not
          * behind it, or the whole picture would sit too far away. */
         float dists[RA_VISION_MAX_PLANES];
         if (planes.count >= 4)
         {
            /* NES: backdrop, sprites-behind, background, sprites-front.  The
             * backdrop sits a touch beyond the behind-sprites so it never
             * z-fights with them, and the background stays exactly ON the
             * panel the user placed. */
            dists[0] = s_dist + spread * 1.5f;
            dists[1] = s_dist + spread;
            dists[2] = s_dist;
            dists[3] = s_dist - spread;
         }
         else if (planes.count == 3)
         {
            dists[0] = s_dist + spread; dists[1] = s_dist; dists[2] = s_dist - spread;
         }
         else
         {
            /* SNES: background then sprites; the background holds the panel. */
            dists[0] = s_dist; dists[1] = s_dist - spread;
            dists[2] = dists[3] = s_dist - spread;
         }

         if (s_haveAnchor && ra_imm_frames > 60)
            ra_write_report(drawable, layered,
                            layered ? planes.width  : 0,
                            layered ? planes.height : 0);

         float srgbDecode = 0.0f;
         if (flatTex)
         {
            MTLPixelFormat sf = flatTex.pixelFormat;
            MTLPixelFormat df = cp_drawable_get_color_texture(drawable, 0).pixelFormat;
            BOOL srcEncoded = (sf == MTLPixelFormatBGRA8Unorm || sf == MTLPixelFormatRGBA8Unorm);
            BOOL dstLinear  = (df == MTLPixelFormatBGRA8Unorm_sRGB
                            || df == MTLPixelFormatRGBA8Unorm_sRGB
                            || df == MTLPixelFormatRGBA16Float);
            srgbDecode = (srcEncoded && dstLinear) ? 1.0f : 0.0f;
         }

         /* the sky. In 3dSen the NES backdrop colour (palette RAM 0,
          * every frame) is the camera's CLEAR colour — unlit, infinite, never
          * geometry. Only for a 3dSen shape-mode session (NES + profile);
          * the plain depth planes and every other core keep today's path. */
         int      sky    = (layered && planes.count >= 4 && ra_vision_scene_mode_on())
                         ? s_skyMode : 0;
         uint32_t skyRGB = 0, skyKey = 0;
         MTLClearColor skyClear = MTLClearColorMake(0, 0, 0, 0);
         MTLClearColor skyOpaque = skyClear;   /* sky 3's per-eye fallback */
         simd_float4   skyBox   = simd_make_float4(0, 0, 0, 1);
         if (sky)
         {
            const uint32_t *pal = ra_vision_scene_palette();
            skyRGB = pal ? (pal[0] & 0x00FFFFFFu) : 0u;
            /* the backdrop plane holds the CORE's colours, the
             * sky 3dSen's — key on what the plane actually holds */
            skyKey = ra_vision_scene_backdrop_core_rgb();
            if (sky >= 2)
            {
               /* sRGB in; the clear is stored like a shader output, so a
                * linear-in target (_sRGB/float, check) gets the
                * linearised value and the hardware/compositor encodes it */
               double c[3] = { ((skyRGB >> 16) & 0xFF) / 255.0,
                               ((skyRGB >>  8) & 0xFF) / 255.0,
                               ( skyRGB        & 0xFF) / 255.0 };
               for (int k = 0; k < 3; k++)
                  if (s_planeDecode)
                     c[k] = c[k] <= 0.04045 ? c[k] / 12.92
                                            : pow((c[k] + 0.055) / 1.055, 2.4);
               skyOpaque = MTLClearColorMake(c[0], c[1], c[2], 1.0);
               if (sky == 2) skyClear = skyOpaque;
               else          skyBox   = simd_make_float4((float)c[0], (float)c[1], (float)c[2], 1.0f);
            }
         }
         {
            /* on every change of mode or colour, capped: a game that flashes
             * its backdrop must not flood the beacon */
            static int      s_skyLogged = -1, s_skyLogN = 0;
            static uint32_t s_skyLoggedRGB = 0xFFFFFFFFu;
            if ((sky != s_skyLogged || (sky && skyRGB != s_skyLoggedRGB)) && s_skyLogN < 24)
            {
               s_skyLogged = sky; s_skyLoggedRGB = skyRGB; s_skyLogN++;
               RA_BeaconMark([[NSString stringWithFormat:
                  @"3dsky: active sky=%d backdrop rgb %06X (core %06X) clear %.4f,%.4f,%.4f,%.1f%s (%s)",
                  sky, skyRGB, skyKey, skyClear.red, skyClear.green, skyClear.blue, skyClear.alpha,
                  sky == 3 ? " + sky box" : "",
                  s_planeDecode ? "linear-in target" : "UNORM target"] UTF8String]);
            }
         }

         size_t views   = cp_drawable_get_view_count(drawable);
         size_t rmCount = cp_drawable_get_rasterization_rate_map_count(drawable);

         for (size_t v = 0; v < views; v++)
         {
            /* Per-view targeting through the view's texture map.  With
             * foveation each DEDICATED view carries its OWN rate map indexed by
             * texture index — attaching the wrong eye's is the "one eye is a
             * fisheye that warps with head motion" trap. */
            cp_view_t             view  = cp_drawable_get_view(drawable, v);
            cp_view_texture_map_t tmap  = cp_view_get_view_texture_map(view);
            size_t                texIx = cp_view_texture_map_get_texture_index(tmap);
            size_t                slice = cp_view_texture_map_get_slice_index(tmap);
            MTLViewport           vp    = cp_view_texture_map_get_viewport(tmap);

            simd_float4x4 deviceFromEye = cp_view_get_transform(view);
            simd_float4x4 eyeFromOrigin = simd_inverse(simd_mul(originFromDevice, deviceFromEye));

            /* sky 3 only when the box is actually drawn for this eye
             * (geometry present AND a non-empty far-face set). Otherwise
             * this frame/eye behaves exactly like sky 2 — opaque backdrop
             * clear + plane 0 keyed — instead of a transparent clear with
             * the plane's backdrop pixels discarded (passthrough holes). */
            int         skyView = sky;
            int         boxNv   = 0;
            simd_float4 boxV[36];
            simd_float4 boxAll[24], boxEye = simd_make_float4(0, 0, 0, 1);
            if (sky == 3)
            {
               if (s_geoInstTotal && s_skyPipe && s_planePipe)
                  boxNv = ra_sky_box_build_ex(simd_mul(eyeFromOrigin, simd_mul(cam,
                             ra_plane_transform(head, s_dist, s_dist))), boxV, boxAll, &boxEye);
               if (!boxNv) skyView = 2;
               s_skyBoxFaces = boxNv / 6;
               {
                  static int s_fbLogged = -1, s_fbLogN = 0;
                  int fb = (skyView == 2) ? (s_geoInstTotal ? 2 : 1) : 0;
                  if (fb != s_fbLogged && s_fbLogN < 24)
                  {
                     s_fbLogged = fb; s_fbLogN++;
                     RA_BeaconMark(fb == 0 ? "3dsky: sky box drawn (sky 3)"
                                 : fb == 1 ? "3dsky: sky 3 -> sky 2 fallback (no geometry)"
                                           : "3dsky: sky 3 -> sky 2 fallback (box empty)");
                  }
               }
            }

            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
            id<MTLTexture> colorTex = cp_drawable_get_color_texture(drawable, texIx);
            id<MTLTexture> depthTex = cp_drawable_get_depth_texture(drawable, texIx);
            /* with MSAA the pass draws into the multisampled pair and
             * resolves into the drawable's slice; without, exactly as before. */
            BOOL msaa = (s_msaaSamples > 1) && ra_msaa_targets(dev, colorTex, depthTex);
            if (s_msaaSamples > 1 && !msaa)
               continue;   /* never seen: the frame-level check above passed */
            /* with ao / reflection on, the eye pass lands in
             * our own colour + depth pair (same size, same rate map) and the
             * post chain writes the drawable after it. */
            id<MTLRasterizationRateMap> eyeRRM = rmCount > 0
               ? cp_drawable_get_rasterization_rate_map(drawable, texIx < rmCount ? texIx : 0) : nil;
            BOOL post = s_postOn && layered && s_geoInstTotal && depthTex
                     && ra_post_targets(dev, colorTex, depthTex,
                                        (NSUInteger)(s_fxCfg.ao_quality >= 2 ? 1 : 2),
                                        (NSUInteger)(s_fxCfg.ssr_quality == 3 ? 1 : 2));
            BOOL postRemap = NO;
            if (post && !eyeRRM && s_postFakeRRM)
            {
               eyeRRM    = ra_post_fake_rrm(dev, colorTex.width, colorTex.height);
               postRemap = eyeRRM != nil;
            }
            id<MTLTexture> eyeColor = post ? s_fxColor : colorTex;
            id<MTLTexture> eyeDepth = post ? s_fxDepth : depthTex;
            NSUInteger     eyeSlice = post ? 0 : slice;
            if (msaa)
            {
               pass.colorAttachments[0].texture        = s_msaaColor;
               pass.colorAttachments[0].resolveTexture = eyeColor;
               pass.colorAttachments[0].resolveSlice   = eyeSlice;
               pass.colorAttachments[0].storeAction    = MTLStoreActionMultisampleResolve;
            }
            else
            {
               pass.colorAttachments[0].texture     = eyeColor;
               pass.colorAttachments[0].slice       = eyeSlice;
               pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            }
            pass.colorAttachments[0].loadAction  = MTLLoadActionClear;
            pass.colorAttachments[0].clearColor  = skyView == 2 ? skyOpaque : skyClear;   /* (0,0,0,0) unless sky 2 */
            if (eyeRRM)
               pass.rasterizationRateMap = eyeRRM;

            if (depthTex)
            {
               if (msaa)
               {
                  pass.depthAttachment.texture            = s_msaaDepth;
                  pass.depthAttachment.resolveTexture     = eyeDepth;
                  pass.depthAttachment.resolveSlice       = eyeSlice;
                  pass.depthAttachment.storeAction        = MTLStoreActionMultisampleResolve;
                  pass.depthAttachment.depthResolveFilter = s_msaaDepthFilter;
               }
               else
               {
                  pass.depthAttachment.texture     = eyeDepth;
                  pass.depthAttachment.slice       = eyeSlice;
                  pass.depthAttachment.storeAction = MTLStoreActionStore;
               }
               pass.depthAttachment.loadAction  = MTLLoadActionClear;
               /* reverse-Z: 0 is the FAR plane, so that is the clear */
               pass.depthAttachment.clearDepth  = 0.0;
            }

            id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
            [enc setViewport:vp];   /* foveation rasterizes the LOGICAL viewport */

            float dimNow = s_dim;
            /* the surround sky covers the room: dimming it would darken the
             * NES backdrop colour itself */
            if (dimNow > 0.003f && s_dimPipe && skyView != 2)
            {
               [enc setRenderPipelineState:s_dimPipe];
               [enc setDepthStencilState:s_depthAlways];
               [enc setFragmentBytes:&dimNow length:sizeof(dimNow) atIndex:0];
               [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            }

            simd_float4x4 proj = matrix_identity_float4x4;
            if (__builtin_available(visionOS 2.0, *))
               proj = cp_drawable_compute_projection(drawable,
                         cp_axis_direction_convention_right_up_back, (uint32_t)v);

            if (layered && s_planePipe)
            {
               /* With the shape mode on the planes stay up ALONGSIDE the
                * geometry — `plane_mode` in 3dsen.cfg turns that down
                * to the backdrop only, or off, without a rebuild. */
               int planeMode = s_geoInstTotal ? ra_vision_scene_plane_mode() : 2;
               int planeMax  = planeMode >= 2 ? planes.count
                             : (planeMode == 1 ? 1 : 0);
               /* with the sky box the backdrop plane (shell
                * plane 0) is not drawn: the box IS the backdrop, in 3dSen's
                * palette, at the clip rect. Before, the plane drew a second,
                * core-palette sky wall of a different size (its key had
                * stopped matching). */
               int skyBoxOn  = (skyView == 3 && boxNv > 0);
               int planeMin  = skyBoxOn ? 1 : 0;
               /* in backdrop-only mode the backdrop is the ONLY thing
                * behind the shapes, and its normal distance (s_dist + 1.5
                * spread) collapses onto the panel when Stereo Depth is turned
                * down — which would put it in FRONT of every layer below L1
                * and hide the diorama.  Push it past the deepest shape. */
               float backdrop = dists[0];
               if (planeMode == 1 && s_geoInstTotal && s_geoMinZ < 0.0f)
               {
                  float need = s_dist - s_geoMinZ + 0.05f;
                  if (need > backdrop) backdrop = need;
               }
               [enc setRenderPipelineState:s_planePipe];
               [enc setDepthStencilState:s_depthWrite];
               for (int i = planeMin; i < planeMax && i < RA_VISION_MAX_PLANES; i++)
               {
                  if (!s_planeTex[i]) continue;
                  simd_float4x4 model = simd_mul(cam, ra_plane_transform(
                                           head, i == 0 ? backdrop : dists[i], s_dist));
                  simd_float4x4 mvp   = simd_mul(proj, simd_mul(eyeFromOrigin, model));
                  [enc setVertexBytes:&mvp length:sizeof(mvp) atIndex:0];
                  [enc setFragmentTexture:s_planeTex[i] atIndex:0];
                  [enc setFragmentBytes:&s_planeDecode length:sizeof(s_planeDecode) atIndex:0];
                  {
                     uint32_t key[2] = { (sky && i == 0) ? 1u : 0u, skyKey };
                     [enc setFragmentBytes:key length:sizeof(key) atIndex:1];
                  }
                  [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
               }
               if (s_geoInstTotal)
               {
                  /* The panel basis IS the world-to-room transform; Q (inside
                   * ra_geo_upload) carries NES pixels into it. Same depth
                   * buffer as the planes, so occlusion between the two is the
                   * hardware's problem, not ours. */
                  simd_float4x4 panel = simd_mul(cam,
                                           ra_plane_transform(head, s_dist, s_dist));
                  simd_float4x4 base  = simd_mul(proj, simd_mul(eyeFromOrigin, panel));
                  simd_float4x4 baseUI = simd_mul(proj, simd_mul(eyeFromOrigin,
                                            ra_plane_transform(head, s_dist, s_dist)));
                  /* alpha 254/255 marks the box for this view's post
                   * passes (sky to them); the composite restores it to 1 */
                  simd_float4 skyBoxV = skyBox;
                  skyBoxV.w = post ? 254.0f / 255.0f : 1.0f;
                  if (skyBoxOn && s_fx.bend && s_skyTessPipe)   /* bends with it */
                     ra_sky_box_draw_bent(enc, base, boxAll, boxEye, skyBoxV);
                  else if (skyBoxOn)   /* before the geometry, depth-written */
                     ra_sky_box_draw(enc, base, boxV, boxNv, skyBoxV);
                  ra_geo_encode(enc, base, baseUI);
               }
            }
            else if (flatTex && s_flatPipe)
            {
               simd_float4x4 model = ra_plane_transform(head, s_dist, s_dist);
               simd_float4x4 mvp   = simd_mul(proj, simd_mul(eyeFromOrigin, model));
               [enc setRenderPipelineState:s_flatPipe];
               [enc setDepthStencilState:s_depthWrite];
               [enc setVertexBytes:&mvp length:sizeof(mvp) atIndex:0];
               [enc setFragmentBytes:&srgbDecode length:sizeof(srgbDecode) atIndex:0];
               [enc setFragmentTexture:flatTex atIndex:0];
               [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
            }

            /* The virtual Zapper in the hand, then the reticle: everything
             * they need — their own pipelines, the published pose and u,v,
             * the panel plane — lives in RAVisionGun.m; both are no-ops when
             * no light gun is in play.  The model is lit by the scene light,
             * turned from the diorama's frame (+X right, +Y down, +Z toward
             * the viewer) into the room through the same camera and panel
             * basis the geometry is drawn with. */
            {
               Ra3dGeoLight  glt;
               simd_float4x4 pw = simd_mul(cam, ra_plane_transform(head, s_dist, s_dist));
               simd_float3   lr = simd_normalize(pw.columns[0].xyz);
               simd_float3   lu = simd_normalize(pw.columns[1].xyz);
               simd_float3   ln = simd_normalize(pw.columns[2].xyz);
               MTLPixelFormat cf = cp_drawable_get_color_texture(drawable, 0).pixelFormat;
               ra_geo_light_now(&glt);
               ra_vision_gun_draw_model(enc, simd_mul(proj, eyeFromOrigin),
                                        lr * glt.dir.x - lu * glt.dir.y + ln * glt.dir.z,
                                        glt.rgb.xyz, glt.ambient,
                                        !ra_format_takes_linear(cf), cf,
                                        depthTex ? depthTex.pixelFormat : MTLPixelFormatInvalid,
                                        msaa ? s_msaaSamples : 1);
            }
            ra_vision_gun_draw_reticle(enc, simd_mul(proj, eyeFromOrigin), head,
                                       cp_drawable_get_color_texture(drawable, 0).pixelFormat,
                                       depthTex ? depthTex.pixelFormat : MTLPixelFormatInvalid,
                                       msaa ? s_msaaSamples : 1);
            [enc endEncoding];

            if (post)
            {
               Ra3dFxView fv;
               ra_post_view(&fv, proj, vp, eyeFromOrigin,
                            simd_mul(cam, ra_plane_transform(head, s_dist, s_dist)));
               ra_post_encode(cb, &fv, eyeRRM, postRemap, colorTex, depthTex, slice);
            }
         }

         if (borrowed)
            [cb addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull b) {
               (void)b;
               ra_vision_offscreen_release(borrowed);
            }];

         if (s_geoInstTotal)
            [cb addCompletedHandler:^(id<MTLCommandBuffer> b) {
               double g = b.GPUEndTime - b.GPUStartTime;
               if (g > 0.0 && g < 1.0)
               {
                  uint64_t us = (uint64_t)(g * 1e6);
                  atomic_fetch_add(&s_frameGpuUsSum, us);
                  atomic_fetch_add(&s_frameGpuN, 1u);
                  if (us > atomic_load(&s_frameGpuUsPeak)) atomic_store(&s_frameGpuUsPeak, us);
               }
            }];
         if (s_geoInstTotal) ra_geo_slot_retain(cb);
         ra_alpha_dump_maybe(cb, drawable);   /* dev hook, no-op without RA3D_ALPHA_DUMP */
         cp_drawable_encode_present(drawable, cb);
         [cb commit];
         ra_vision_offscreen_credit();

         ra_imm_frames++;
         if (ra_imm_frames == 3 || (ra_imm_frames % 900) == 0)
         {
            /* Everything the framing depends on, in one line, so a wrong
             * picture shape can be read off rather than reasoned about. */
            float bw = s_width * 0.5f, bh = s_height * 0.5f;
            float d  = (s_planeAspect > 0.01f) ? s_planeAspect
                     : ((s_aspect > 0.01f) ? s_aspect : (4.0f / 3.0f));
            float hw = bw, hh = bw / d;
            if (hh > bh) { hh = bh; hw = bh * d; }
            if (ra_vision_scene_mode_on())
            {
               /* Also into the beacon: on an OTA-only headset there is no
                * console, and these three numbers are the whole per-frame
                * cost story. */
               char line[768];
               snprintf(line, sizeof(line),
                        "3dsen: frame %u %u instances match %.2f + build %.2f "
                        "+ upload %.2f ms, coverage %.1f%% (%u pattern, %u fallback,"
                        " +%u variants, %u lua-hidden, %u flat)"
                        " | vox %.2f ms (mesh %.2f, %u new, %u hit) %u pieces "
                        "%u runs %u verts/eye, cache %u meshes %u verts; "
                        "since last: peak %.2f ms, %u meshed, %u deferred; "
                        "geo slots %d, %u stalls, sky box %d faces, "
                        "marching %u (peak %u), compactions %u",
                        s_geoFrame, s_geoInstTotal,
                        geo ? geo->match_ms : 0.0, s_geoBuildMs, s_geoUploadMs,
                        (geo && geo->non_empty)
                           ? 100.0 * geo->covered / geo->non_empty : 0.0,
                        geo ? geo->pattern_instances : 0,
                        geo ? geo->fallbacks : 0,
                        geo ? geo->variants : 0, geo ? geo->lua_hidden : 0,
                        geo ? geo->flattened : 0,
                        s_voxMs, s_voxMeshMs, s_voxFrame.meshed, s_voxFrame.hits,
                        s_voxFrame.piece_count, s_voxFrame.run_count,
                        s_voxFrame.frame_verts, s_voxFrame.entries, s_voxVBCount,
                        s_voxPeakMs, s_voxMissSum, s_voxDeferSum,
                        s_geoSlotN, s_geoSlotStalls, s_skyBoxFaces,
                        s_voxFrame.marching, s_voxMarchPeak,
                        s_voxFrame.compactions);
               s_voxPeakMs = 0.0; s_voxMissSum = 0; s_voxDeferSum = 0;
               s_voxMarchPeak = 0;
               RA_BeaconMark(line);
               if (ra3d_fx_cfg_any(&s_fxCfg))
               {  /* the Enhanced terms in effect this frame */
                  snprintf(line, sizeof(line),
                           "3dfx: groove %.0f pixel_shadow %.0f bend %u K %.5f,%.5f,%.5f rad/px "
                           "fit %.4f,%.4f,%.4f tess %u backdrop slot %d zscale %.2f; bent "
                           "geometry reaches %+.1f px nearer the viewer than flat",
                           (double)s_fx.groove, (double)s_fx.pixelShadow, s_fx.bend,
                           (double)s_fx.K.x, (double)s_fx.K.y, (double)s_fx.K.z,
                           (double)s_fx.fitScale.x, (double)s_fx.fitScale.y,
                           (double)s_fx.fitScale.z, s_fx.tess, (int)s_fx.backdrop - 1,
                           (double)s_fx.zscale, (double)s_fxNearPx);
                  RA_BeaconMark(line);
               }
               if (s_postOn)
               {  /* what the post chain did since the last line */
                  snprintf(line, sizeof(line),
                           "3dpost: ao %d reflection %d — %u views composited since last; "
                           "targets %lux%lu; %s%s",
                           s_fxCfg.depth_ao, s_fxCfg.reflection, s_postFrames,
                           (unsigned long)s_fxColor.width, (unsigned long)s_fxColor.height,
                           s_postLast[0] ? s_postLast : "no view yet",
                           s_postDebug ? " [DEBUG view]" : "");
                  s_postFrames = 0;
                  RA_BeaconMark(line);
               }
               {  /* the shadow pass's cost since the last line */
                  uint32_t gn = atomic_exchange(&s_shadowGpuN, 0u);
                  uint64_t gs = atomic_exchange(&s_shadowGpuUsSum, 0u);
                  uint64_t gp = atomic_exchange(&s_shadowGpuUsPeak, 0u);
                  uint32_t fn = atomic_exchange(&s_frameGpuN, 0u);
                  uint64_t fs = atomic_exchange(&s_frameGpuUsSum, 0u);
                  uint64_t fp = atomic_exchange(&s_frameGpuUsPeak, 0u);
                  snprintf(line, sizeof(line),
                           "3dshadow: on=%u renders %u since last, GPU avg %.3f ms peak %.3f ms "
                           "(n=%u), CPU last %.3f ms peak %.3f ms, box %.0fx%.0fx%.0f px "
                           "%.2fx%.2f texels/px | eye-pass cb GPU avg %.3f ms peak %.3f ms (n=%u) "
                           "| translucent inst now %u peak %u | msaa %lu",
                           s_shadow.on, s_shadowRenders,
                           gn ? (double)gs / gn / 1000.0 : 0.0, (double)gp / 1000.0, gn,
                           s_shadowCpuMs, s_shadowCpuPeak,
                           (double)s_shadowFit.w, (double)s_shadowFit.h,
                           (double)s_shadowFit.range,
                           s_shadowFit.texel_w > 0 ? 1.0 / s_shadowFit.texel_w : 0.0,
                           s_shadowFit.texel_h > 0 ? 1.0 / s_shadowFit.texel_h : 0.0,
                           fn ? (double)fs / fn / 1000.0 : 0.0, (double)fp / 1000.0, fn,
                           s_geoBuckets.blend_count, s_tranPeak,
                           (unsigned long)s_msaaSamples);
                  s_shadowRenders = 0; s_shadowCpuPeak = 0.0; s_tranPeak = 0;
                  RA_BeaconMark(line);
               }
            }
            if (ra_vision_scene_mode_on())
               NSLog(@"[RA3D] 3dsen frame %u — %u instances (%u cells), match "
                      "%.2f ms + build %.2f ms + upload %.2f ms, coverage "
                      "%.1f%% (%u pattern, %u fallback)",
                     s_geoFrame, s_geoInstTotal,
                     geo ? geo->cell_count : 0,
                     geo ? geo->match_ms : 0.0, s_geoBuildMs, s_geoUploadMs,
                     (geo && geo->non_empty)
                        ? 100.0 * geo->covered / geo->non_empty : 0.0,
                     geo ? geo->pattern_instances : 0,
                     geo ? geo->fallbacks : 0);
            NSLog(@"[RA3D] frame %d — %s planes=%d src=%ux%u coreDAR=%.3f raDAR=%.3f "
                   "used=%.3f box=%.2fx%.2f quad=%.2fx%.2f stereo %.0f%% spread %.2fm",
                  ra_imm_frames, layered ? "layered" : "flat", planes.count,
                  planes.width, planes.height, (double)planes.display_aspect,
                  (double)s_aspect, (double)d, (double)(bw*2), (double)(bh*2),
                  (double)(hw*2), (double)(hh*2),
                  (double)(s_stereo * 100.0f), (double)spread);
         }

         cp_frame_end_submission(frame);
      }
   }

   for (int i = 0; i < RA_VISION_MAX_PLANES; i++)
      s_planeTex[i] = nil;
   /* Leaving 3D: stop the core capturing scenes (+4.0 % is only worth
    * paying while something is drawing them). ra_vision_scene_poll re-arms it
    * on the next entry, because stopping clears the remembered content path. */
   ra_vision_gun_stop();
   /* keep this game's camera, then forget the key — the next entry
    * re-picks the profile and restores it */
   ra_vision_camera_persist_key(NULL, 0, 0, "leave 3D");
   ra_vision_camera_gate(false);
   ra_vision_camera_reset();
   ra_vision_scene_stop();
   s_geoInstTotal = 0;
   s_geoFrame     = 0xFFFFFFFFu;
   if (notifyEnded)
      ra_vision_immersive_ended();
   ra_imm_running = 0;
}

#endif /* RA_VISION_3D */
