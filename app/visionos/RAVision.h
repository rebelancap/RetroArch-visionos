/* RAVision.h — public C surface of the visionOS stereoscopic 3D mode.
 *
 * Everything here is behind RA_VISION_3D, which BaseConfig.xcconfig defines for
 * the xros / xrsimulator slices only — the iOS build never sees any of it.
 *
 * ---------------------------------------------------------------------------
 * How this is stereoscopic on a 2D console
 *
 * The sibling ports (Quake, Doom 3, Zelda, …) are 3D engines: you offset the
 * camera per eye and geometry has depth for free.  The NES has no camera and
 * hands the emulator one flat picture, so there is no second viewpoint to
 * render from — rendering that picture "per eye" twice gives two identical
 * images and a flat screen.
 *
 * What the NES DOES have is layers.  Every pixel is composed from a background
 * plane and a sprite plane, and the sprite carries a bit saying whether it
 * draws in front of or behind the background.  The Mesen core is patched to
 * publish those as three separate images of the SAME frame (it already
 * evaluated both before choosing one, so this costs no emulation), and this
 * shell hangs them at three different distances in the room:
 *
 *        sprites-behind        background          sprites-front
 *        (farthest)            (the panel)         (nearest — pops out)
 *              |                    |                    |
 *   eye L -----+--------------------+--------------------+
 *   eye R -----+--------------------+--------------------+
 *                 each eye sees a different alignment -> real depth
 *
 * Each plane is scaled by its own distance so all three stay registered from
 * the head: at Stereo Depth 0 they collapse onto the panel and the picture is
 * pixel-identical to 2D.  Turning the slider up spreads them.
 *
 * The RetroArch menu is not part of the core's planes, so when the menu is up
 * the shell falls back to the flat composite (ra_vision_offscreen_*), which is
 * the whole RetroArch frame redirected out of the window's drawable.
 */

#ifndef RA_VISION_H
#define RA_VISION_H

#if defined(RA_VISION_3D)

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------- mode state */

bool  ra_vision_3d_active(void);
void  ra_vision_3d_begin(void);
void  ra_vision_3d_end(void);
void  ra_vision_3d_render_size(unsigned *w, unsigned *h);
void  ra_vision_3d_set_aspect(float dar, unsigned rotation);
float ra_vision_3d_aspect(void);

/* --------------------------------------------------------------- core planes
 *
 * Resolved by dlsym against the loaded core, so RetroArch's video path is
 * untouched and any core without the symbol simply falls back to the flat
 * composite.  Planes are ARGB8888, alpha 0 = nothing drawn, ordered far to
 * near.  The frame counter lets the compositor skip re-uploading a frame the
 * emulator has not advanced past. */
#define RA_VISION_MAX_PLANES 4

typedef struct
{
   const uint32_t *plane[RA_VISION_MAX_PLANES];
   int             count;        /* 0 when the core has no layer support */
   unsigned        width, height;
   uint32_t        frame;
   float           display_aspect;   /* 0 = core did not say; use the frontend's */
} ra_vision_planes_t;

bool  ra_vision_layers_available(void);
bool  ra_vision_layers_fetch(ra_vision_planes_t *out);

/* 3dSen-mode run-ahead (`runahead` in 3dsen.cfg, default 0).
 * RAVisionHost.m owns RetroArch's settings and the retro_run wrapper;
 * RAVisionLayers.m (ra3d_runahead.h) owns the visible-frame latch the render
 * thread reads instead of the core's live buffers. All main thread. */
void  ra_vision_latch_set(int on, void *planes_fn, void *scene_fn, void *mem_fn, int frames);
void  ra_vision_latch_after_run(int hidden, double run_ms);
void  ra_vision_latch_note_state(int load, double ms);
void  ra_vision_latch_invalidate(void);
void  ra_vision_runahead_begin(void);   /* entering 3D: read the knob, arm   */
void  ra_vision_runahead_end(void);     /* leaving 3D: restore, unwrap       */
bool  ra_vision_runahead_heal(void);    /* launch: undo an interrupted apply;
                                           false = config not up yet, retry */

/* True while RetroArch's menu is up: the menu is drawn by the frontend, not by
 * the core, so it only exists in the flat composite.  Defined in
 * ui_cocoatouch.m (overlay 0010) where the menu headers are already in scope. */
bool  ra_vision_menu_alive(void);

/* Remote-diagnosis beacon (ui_cocoatouch.m): appends one timestamped line to
 * Documents/launch-beacon.log. The only diagnostic that survives an OTA-only,
 * no-debugger launch failure, so the shell marks every launch milestone with
 * it — see the 0034 notes for why a dead launch used to say nothing at all. */
void  RA_BeaconMark(const char *stage);

/* Re-send the current 2D window size with UIWindowSceneResizingRestrictionsUniform,
 * so a user corner-drag stays locked to the running core's aspect and can never
 * produce a letterbox (RAVisionHost.m, item 2). Idempotent. */
void  ra_vision_arm_aspect_lock(void);

/* --------------------------------------------------- flat-composite fallback */

void *ra_vision_offscreen_acquire(void *device, unsigned pixel_format, int *out_slot);
void  ra_vision_offscreen_publish(int slot);
void *ra_vision_offscreen_borrow_latest(void);
void  ra_vision_offscreen_release(void *texture);
void  ra_vision_offscreen_credit(void);
void  ra_vision_offscreen_reset(void);

/* ------------------------------------------------------------ panel settings
 *
 * Rows, ranges and defaults follow ~/dev/q2repro-ios/SETTINGS-SPEC-FROM-VKQUAKE.md
 * — the program's reference 3D UX.  Lengths are STORED IN METRES; the units
 * toggle only changes the readout.  Everything applies live while dragging. */
void  ra_vision_panel_set_distance(float m);        /* 1.0 .. 8.0 m,  def 3.6  */
void  ra_vision_panel_set_width(float m);           /* 1.2 .. 8.0 m,  def 5.5  */
void  ra_vision_panel_set_height(float m);          /* 1.0 .. 6.0 m,  def 3.1  */
void  ra_vision_panel_set_position_height(float m); /* -1.5 .. 10.0 m, def 0.0 */
void  ra_vision_panel_set_stereo_depth(float pct);  /* 0 .. 3.2,      def 1.0  */
void  ra_vision_panel_set_dim(float pct);           /* 0 .. 1.0,      def 0.8  */
void  ra_vision_panel_set_units_feet(bool feet);    /* readout only,  def ft   */
void  ra_vision_panel_recenter(void);
void  ra_vision_panel_defaults(void);

float ra_vision_panel_distance(void);
float ra_vision_panel_width(void);
float ra_vision_panel_height(void);
float ra_vision_panel_position_height(void);
float ra_vision_panel_stereo_depth(void);
float ra_vision_panel_dim(void);
bool  ra_vision_panel_units_feet(void);

/* Read-only rows: the live render target and its aspect. */
void  ra_vision_panel_render_size(unsigned *w, unsigned *h);

void  ra_vision_settings_load(void);
void  ra_vision_settings_save(void);

/* ------------------------------------------------------- spatial light gun
 *
 * NES Zapper aimed with a PSVR2 Sense controller.
 * RAVisionGun.m tracks the accessory with ARKit's C accessory-tracking API on
 * the immersive render thread, intersects its aim ray with the panel plane and
 * publishes ONE lock-free snapshot; overlay 0064 reads it at the end of
 * cocoa_input_poll() and writes touches[0] + mouse_buttons, which is exactly
 * what Mesen's Zapper (a POINTER subclass read from port 0) consumes.
 *
 * u,v are 0..1 over the visible picture, +Y DOWN (image space).
 *   valid     — a usable pose exists this frame (0 = no gun: leave input alone)
 *   offscreen — the ray missed the panel; the frontend sets mouse button 2,
 *               which is Mesen's own "point off screen" idiom
 *   u < 0     — the ray did not meet the plane at all (parallel, or behind the
 *               muzzle); offscreen is then also 1 and no reticle is drawn
 *   trigger   — fire (Sense analog trigger)
 *   aux       — grip: force offscreen (reload in Hogan's Alley / Wild Gunman) */
typedef struct
{
   float   u, v;
   uint8_t valid, offscreen, trigger, aux;
} ra_vision_gun_t;

bool  ra_vision_gun_active(void);           /* a gun source is publishing      */
bool  ra_vision_gun_fetch(ra_vision_gun_t *out);
void  ra_vision_gun_set_enabled(bool on);
bool  ra_vision_gun_enabled(void);

/* "is the aim actually WANTED this frame" — written by overlay 0064 on
 * the emulator thread every cocoa_input_poll(): true only while content is
 * running, the RetroArch menu is NOT up, and some port's device type is a
 * light-gun/pointer class (Mesen's Zapper = 262).  Gates the pointer write in
 * 0064 and the reticle here, so a tracked Sense is never a menu pointer and
 * never draws a bullseye over a plain-pad game. */
void  ra_vision_gun_set_wanted(bool on);
bool  ra_vision_gun_wanted(void);

/* While a light gun is in play (the gate above) the triggers only fire and
 * the camera zoom moves to the grips: replaces l2/r2 with pad L/R (left grip
 * out, right grip in) and returns true; otherwise leaves them and returns
 * false.  Emulator thread, from ra_vision_camera_input().  RAVisionGun.m. */
bool  ra_vision_gun_zoom_remap(float *l2, float *r2);

/* Reticle, ra3d.v2.reticle (NSUserDefaults) + `reticle=` in zapper.cfg
 * (default off: the gun model is drawn instead). */
void  ra_vision_panel_set_reticle(bool on);
bool  ra_vision_panel_reticle(void);
float ra_vision_gun_reticle_size(void);   /* half-extent, metres */

/* ---------------------------------------------------- 3dSen scene camera
 *
 * 3dSenVR-style controller camera for the diorama (
 * R6).  ONE world-space matrix in front of everything the layered path draws —
 * the depth planes, the 3dSen geometry, and the Zapper's aim plane — so the
 * scene orbits the picture the user placed instead of swinging round the room.
 *
 *   right stick        orbit (yaw / pitch), clamped
 *   L2 / R2            zoom out / in, exponential, clamped
 *   L3 + right stick   pan
 *   R3                 reset to the home pose
 *
 * Implemented in RAImmersive.m.  `ra_vision_camera_input` is the ONLY entry
 * point on the emulator thread: overlay 0064 calls it at the end of
 * cocoa_input_poll() with the mfi joypad driver's port-1 state, which is why a
 * PSVR2 Sense pair (overlay 0068) drives it for free.  Everything else runs on
 * the render thread; they meet at one seqlock snapshot and nowhere else. */
void ra_vision_camera_input(float rx, float ry, float l2, float r2,
                            bool mod_pan, bool reset);
void ra_vision_camera_gate(bool on);      /* render thread: NES scene on screen */
void ra_vision_camera_reset(void);
void ra_vision_camera_set_home(float yaw_deg, float pitch_deg, float zoom);
void ra_vision_camera_load_cfg(void);
bool ra_vision_camera_moved(void);
/* per-game camera persistence (system/3dsen/camera-state.cfg).
 * persist_key: render thread, the game the camera belongs to now (matched
 * profile Id, else the ROM CRC32; neither = none) — saves the previous game's
 * camera, restores this one's. persist_flush: any thread, save now. */
void ra_vision_camera_persist_key(const char *profile_id, unsigned crc, int have_crc,
                                  const char *why);
void ra_vision_camera_persist_flush(const char *why);

/* ------------------------------------------------------------- immersive loop */

extern volatile int ra_imm_stop;
extern volatile int ra_imm_running;
extern int          ra_imm_frames;

void  ra_vision_immersive_ended(void);
void  ra_vision_enter_3d(bool on);
void  ra_vision_exit_3d_finalize(void);
void  ra_vision_launch(void);

#ifdef __cplusplus
}
#endif

#ifdef __OBJC__
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <CompositorServices/CompositorServices.h>

#import <simd/simd.h>

/* The panel quad, factored out of ra_plane_transform() so the gun can
 * intersect it without the ra_scale() the render applies.  pos is the quad's
 * centre, right/up its unit axes, normal points from the panel toward the
 * head, and halfW/halfH are its half-extents in metres (the same aspect fit
 * the render uses).  RAImmersive.m. */
void ra_vision_panel_plane(simd_float4x4 head,
                           simd_float3 *pos, simd_float3 *right,
                           simd_float3 *up,  simd_float3 *normal,
                           float *halfW, float *halfH);

/* 3dSen v2's world curvature (3dsen.cfg bend_lr/bend_tb/
 * arc_h). While it is on, the gun aims at the BENT background plane, as
 * 3dSen's Zapper does: ra_vision_bend_ray returns 1 and the unbent NES
 * position as u, v in [0, 1] (0 = no hit), and ra_vision_bend_reticle places
 * the reticle on the bent plane (panel su, sv in [-1, 1], sz in half-widths
 * along the normal). Render thread. RAImmersive.m. */
bool ra_vision_fx_bend_active(void);
int  ra_vision_bend_ray(simd_float4x4 head, simd_float3 o, simd_float3 d, float plane_z,
                        float *u, float *v);
/* The loaded 3dSen profile's ZapperOffset (3dSen frame px: +Y up, +Z away
 * from the viewer) while its Lua runs, else 0 and zeros. The light-gun
 * profiles move their targets in 3D (Duck Hunt's ducks drift up to 128 px
 * deep) and leave the move here; the gun casts against the plane moved by z
 * and drops x/y from the hit, as 3dSen's Zapper does. Render thread.
 * RAVisionLayers.m. */
int  ra_vision_scene_zapper_offset(float ofs[3]);
float ra_vision_scene_depth_scale(void);   /* also in ra3d_scene.h */
int  ra_vision_bend_reticle(float u, float v, float *su, float *sv, float *sz);

/* RAVisionGun.m — all three are called from the immersive render thread only
 * (ARKit's accessory calls are AR_MT_UNSAFE). */
void ra_vision_gun_start(void);
/* Duck Hunt + Sense -> port 2 = Zapper, in memory, restored on
 * content change.  Main thread; called once at launch.  RAVisionGun.m. */
void ra_vision_zapper_auto_start(void);
void ra_vision_gun_tick(double trackable_time, simd_float4x4 head);
void ra_vision_gun_stop(void);

/* The reticle, drawn by the gun module itself so the immersive loop needs only
 * this one call inside its existing per-eye pass (after the planes/geometry,
 * before endEncoding).  Owns its pipeline, built lazily from the encoder's
 * device on first use; a no-op when the reticle is off or no ray hits. */
void ra_vision_gun_draw_reticle(id<MTLRenderCommandEncoder> enc,
                                simd_float4x4 viewProj, simd_float4x4 head,
                                MTLPixelFormat color, MTLPixelFormat depth,
                                NSUInteger samples);   /* eye-pass MSAA */

/* The virtual Zapper in the hand, at the controller's aim pose (zapper.cfg
 * gun_model, default on).  Same per-eye pass and same gate as the reticle;
 * call it before the reticle.  toLight is the scene light's direction TOWARD
 * the light in room space, lightRgb / ambient linear; encodeSrgb when the
 * colour target is UNORM.  Render thread. */
void ra_vision_gun_draw_model(id<MTLRenderCommandEncoder> enc,
                              simd_float4x4 viewProj,
                              simd_float3 toLight, simd_float3 lightRgb,
                              float ambient, bool encodeSrgb,
                              MTLPixelFormat color, MTLPixelFormat depth,
                              NSUInteger samples);

UIViewController *RA_MakeHostViewController(void);
bool RA_HandleOpenURL(NSURL *url);
void RA_Immersive_Run(cp_layer_renderer_t layer_renderer);
#endif

#endif /* RA_VISION_3D */
#endif /* RA_VISION_H */
