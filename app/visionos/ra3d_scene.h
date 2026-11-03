/* ra3d_scene.h — the shell side of the 3dSen shape mode.
 *
 * Kept OUT of RAVision.h on purpose: RAVision.h is pulled into Swift through
 * the bridging header (overlay 0030), and none of this belongs there. Only
 * RAVisionLayers.m (which implements it) and RAImmersive.m (which draws it)
 * include this.
 *
 * The mode is OFF unless BOTH hold:
 *   - the loaded core exports the RA3D scene stream (overlay 0059/0060), and
 *   - a `.3dn` profile for the loaded ROM is in
 *     Documents/RetroArch/system/3dsen/.
 * Otherwise the shell behaves exactly as it does today — four depth planes,
 * nothing else, and the core is never asked to capture a scene (which is what
 * makes the +4.0 % of something only a 3dSen session pays).
 */
#ifndef RA3D_SCENE_H
#define RA3D_SCENE_H

#if defined(RA_VISION_3D)

#include "ra3d_shape.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Re-resolves the loaded content against Documents/RetroArch/system/3dsen/ and
 * turns the core's scene capture on or off to match. Cheap enough to call once
 * a second from the render loop; it does real work only when the content path
 * has changed. */
void ra_vision_scene_poll(void);

/* True while the mode is live (core stream + profile + not disabled). */
bool ra_vision_scene_mode_on(void);

/* The most recent frame's geometry, or NULL when the mode is off or the core
 * has not published one. The pointer is owned by this module and stays valid
 * until the next fetch. `*is_new` says whether the emulator advanced, so the
 * caller can skip re-uploading. */
const Ra3dGeoFrame *ra_vision_scene_fetch(int *is_new);

/* The atlas as one byte per pixel of 2-bit colour index (8 x 8*count), plus the
 * 32 palette-RAM entries already resolved to RGBA. Both are rebuilt only when
 * the frame advances. */
const uint8_t  *ra_vision_scene_atlas(unsigned *count);
/* 68 entries — 16 palette groups (3dSen's PaletteIndex, Lua-writable)
 * and group 16 = the Backdrop box's colour. */
const uint32_t *ra_vision_scene_palette(void);
/* the RGB (0x00RRGGBB) the CORE drew this frame's backdrop in
 * (its own palette, palette RAM 0) — what the shell's backdrop plane holds.
 * Since ra_vision_scene_palette() is 3dSen's table, so the plane's
 * backdrop-colour key must compare against this instead. */
uint32_t ra_vision_scene_backdrop_core_rgb(void);

/* The loaded profile's own light: Light.Direction (3dSen frame) and
 * sRGB Light.Color. Returns bit0 / bit1 for each one the profile carries, 0
 * when no profile is live. Render thread only (same thread as poll). */
int ra_vision_scene_profile_light(float dir[3], float col[3]);

/* The loaded profile's static _Setting_.Clipping, 3dSen order
 * [left, bottom, right, top] in NES px. 1 when present, 0 when no profile is
 * live or it carries none. Render thread only. */
int ra_vision_scene_profile_clipping(float clip[4]);

/* The per-ZLayer shadow flags 3dSen ends up with for the loaded profile
 * 3dSen's defaults + the profile's Start() Lua writes. Returns the
 * mask of layers the Lua touched. Render thread only. */
int ra_vision_scene_profile_layer_shadow(uint8_t cast[6], uint8_t recv[6]);

/* the loaded profile's LocalCam verdict (ra3d_profile_localcam):
 * bit0 on, plus the source bit; Rot.x (3dSen degrees) and Camera.Distance
 * (0 = 3dSen's default). 0 when no profile is live. Render thread only. */
int ra_vision_scene_profile_localcam(float *rotx, float *dist);

/* the renderer tells the matcher whether the LocalCam tabletop is
 * engaged (flat_shapes' auto default depends on it). A change forces the next
 * fetch to rebuild. Render thread only. */
void ra_vision_scene_set_localcam(int on);

/* 1 while the loaded profile's Lua runs (cfg `lua`, default 1).
 * Then the profile_* getters above answer with what the SCRIPTS set this
 * frame (Light, Clipping, Setting.LocalCam + Camera, Setting.Layer) instead of
 * the static.. scrapes. Render thread only. */
int ra_vision_scene_lua_active(void);

/* the scripts' Camera.Rot (3dSen degrees) and Distance, and a
 * generation that changes whenever they change them (or the VM is rebuilt).
 * 0 when no VM is live or the scripts never wrote the camera. */
int ra_vision_scene_lua_camera(float rot[3], float *dist, uint32_t *gen);

/* Shuts the stream off (content closed / leaving 3D). Idempotent. */
void ra_vision_scene_stop(void);

/* Same, but for the case where the emulator has merely STOPPED producing
 * frames — the menu is up, or content is being swapped. The renderer calls
 * this instead of poll() on any frame where the core did not just publish a
 * plane set, which is what keeps the shell from reaching into a PPU that is
 * being torn down under it. Idempotent and cheap. */
void ra_vision_scene_suspend(void);

/* What the renderer does with today's four depth planes while the shape mode
 * is on: 0 none, 1 backdrop only, 2 all four (default — the mode draws the
 * geometry ALONGSIDE the planes, it does not replace them). */
int ra_vision_scene_plane_mode(void);

/* World px -> metres multiplier for Z, so the extrusion depth can be tuned
 * from the headset without a rebuild. 1.0 = the same scale as X. */
float ra_vision_scene_depth_scale(void);

#ifdef __cplusplus
}
#endif

#endif /* RA_VISION_3D */
#endif /* RA3D_SCENE_H */
