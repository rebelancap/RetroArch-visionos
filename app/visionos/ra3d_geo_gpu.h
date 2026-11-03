/* ra3d_geo_gpu.h — the GPU-facing half of the 3dSen shape mode.
 *
 * the six extruded primitives are gone. What is drawn now is 3dSen's own
 * construction — per-pixel voxel tiles, greedy-meshed — and lives in
 * ra3d_vox.h; this file keeps the per-instance matrices and the light.
 *
 *   #define RA3D_GEO_GPU_IMPLEMENTATION
 *   #include "ra3d_geo_gpu.h"
 *
 * Everything between `ra3d-geo/1` and a Metal draw call that is NOT Metal: the
 * six primitives' vertex data, and the per-instance model matrices. Split out
 * of RAImmersive.m so a desktop preview can run
 * the SAME mesh and the SAME transforms as the headset — a preview that
 * re-implemented them would prove nothing about the shipped path, which is the
 * whole reason the preview exists while the one Apple Vision Pro simulator is
 * held by another project.
 *
 * Header-only for the same reason as ra3d_shape.h: overlay 0013 is the only
 * patch that touches project.pbxproj and it is hand-written, so a new .c would
 * have to edit inside its hunks.
 *
 * Pure C + <simd/simd.h>. No Metal, no CompositorServices, no Foundation.
 */
#ifndef RA3D_GEO_GPU_H
#define RA3D_GEO_GPU_H

#include <simd/simd.h>
#include "ra3d_shape.h"

#ifdef __cplusplus
extern "C" {
#endif


/* One draw instance. 144 bytes; must match `GeoInst` in the Metal source.
 *
 * `normal` is the inverse-transpose of the instance's unit-patch -> NES-world
 * matrix (size, scale, profile rotation — but NOT the panel transform Q and NOT
 * the scene camera). Lighting is done in NES world on purpose: that frame is
 * the DIORAMA, and 3dSen's directional light is fixed in its world while the
 * camera orbits it, so the light has to turn with the scene when our camera
 * turns the scene. */
typedef struct
{
   simd_float4x4 model;      /* unit box (x, y in [0,1], z in [-0.5, 0.5],
                              * depth CENTRED on the tile plane) -> panel  */
   float         alpha;
   uint32_t      cellOffset; /* into the frame's dense cell array        */
   uint32_t      gw, gh;     /* the front face's cell grid               */
   simd_float3x3 normal;     /* unit-patch normal -> NES-world normal    */
   uint32_t      flags;      /* RA3D_GEO_* below */
   uint32_t      pad[3];     /* scalars, NOT a uint3: Metal aligns uint3 to
                              * 16 and the struct would grow to 160.
                              * pad[0] = palette override (0 none, else
                              * group + 1; 17 = the Backdrop's colour);
                              * pad[1] = Direct texture, 1 + first
                              * texel in the dtex buffer, 0 none */
} Ra3dGeoInst;

/* Ra3dGeoInst.flags, from the instance's RA3D_INST_* shadow bits. */
#define RA3D_GEO_NOCAST   1u   /* skipped by the shadow caster pass        */
#define RA3D_GEO_NORECV   2u   /* never darkened by the shadow map         */
#define RA3D_GEO_NOCOLOR  4u   /* not drawn in colour (shadow-only/hidden) */
#define RA3D_GEO_UI       8u   /* drawn with the camera-less base (3dSen's
                                * camera-locked UI container)               */
/* bits 16-31 carry the instance's DEPTH in voxels, x16 (12.4
 * fixed point), so the Enhanced fragment terms can rebuild 3dSen's
 * object-space voxel z from the unit-box z. Nothing else reads these bits. */
#define RA3D_GEO_DEPTH_SHIFT 16u
/* the palette the fragment shader indexes — 16 groups of 4 (3dSen's
 * PaletteIndex.TableCount, Lua-writable through Palette.SetColorIndex) plus
 * group 16, entry 1 of which is the Backdrop box's colour. */
#define RA3D_GEO_PALETTE_ENTRIES 68u

/* The light, as the fragment shader consumes it. 48 bytes; must match
 * `GeoLight` in the Metal source.
 *   dir      unit vector TOWARD the light, NES world (+X right, +Y down,
 *            +Z toward the viewer)
 *   rgb      linear light colour x intensity
 *   ambient  linear, flat, added on every face
 *   encode   1 => the colour target is UNORM, so the shader sRGB-encodes its
 *            linear result; 0 => the target is _sRGB / float and the hardware
 *            (or the compositor) does it. */
typedef struct
{
   simd_float4 dir;          /* xyz used */
   simd_float4 rgb;          /* xyz used */
   float       ambient;
   uint32_t    encode;
   float       pad[2];
} Ra3dGeoLight;

/* 3dSen's defaults: Light.Direction (1,-1,1) in its
 * own frame (+X right, +Y UP, +Z INTO the screen), white, intensity 1, flat
 * ambient sRGB 118/255 = 0.181 linear. */
#define RA3D_LIGHT_DIR_X      1.0f
#define RA3D_LIGHT_DIR_Y     -1.0f
#define RA3D_LIGHT_DIR_Z      1.0f
#define RA3D_LIGHT_AMBIENT    0.181f
#define RA3D_LIGHT_INTENSITY  1.0f

/* Fills `out` from a 3dSen-frame Direction (the vector the light TRAVELS
 * along, exactly as a profile or setting.cfg writes it), an sRGB light colour,
 * the intensity and the linear ambient. The 3dSen -> NES-world conversion is
 * (x, y, z) -> (x, -y, -z): NES +Y is down and NES +Z
 * comes toward the viewer where 3dSen's goes into the screen. */
void ra3d_geo_light(Ra3dGeoLight *out, const float dir_unity[3],
                    const float color_srgb[3], float intensity, float ambient,
                    int encode);

/* 3dSen's `_View` world-space screen clip, as the shaders consume it.
 * 16 bytes; must match `GeoView` in the Metal source.
 *   rect  (xmin, ymin, xmax, ymax) in NES world px, OUR frame (+Y DOWN),
 *         before the panel transform Q and before the scene camera — i.e. the
 *         diorama's own frame, where 3dSen tests it. A fragment
 *         whose NES-world xy falls outside is discarded (any z: the cut runs
 *         straight through extrusions and side walls).
 *   on    0 disables the test (rect ignored).
 * The SAME struct and the same Metal helper (`ra3d_view_outside`) are meant
 * for the shadow pass, so off-screen geometry neither shows nor casts. */
typedef struct
{
   simd_float4 rect;
   uint32_t    on;
   uint32_t    pad[3];
} Ra3dGeoView;

/* 3dSen's default Clipping, in its own order [0..3]. */
#define RA3D_CLIP_DEFAULT_0  0.1f
#define RA3D_CLIP_DEFAULT_1  8.1f
#define RA3D_CLIP_DEFAULT_2  8.1f
#define RA3D_CLIP_DEFAULT_3  0.1f

/* 3dSen Clipping -> our rect. 3dSen builds `_View = (c0, c1, 256-c2, 240-c3)`
 * (screen (0,0,256,240)) in its world, where world Y =
 * HeightInPixel - nesY = 248 - nesY (RA3D_UNITY_H): +Y UP. So c1 trims
 * the BOTTOM NES rows and c3 the TOP, and the 8-px gap between 240 and 248
 * always trims the top 8 rows:
 *   x in [c0, 256 - c2],   nesY in [8 + c3, 248 - c1].
 * (Rounds 15-20 used 240 - nesY and trimmed the bottom 8 rows instead.)
 * Negative insets widen the rect past the screen (Punch-Out's Lua). */
void ra3d_geo_view(Ra3dGeoView *out, const float clip3dsen[4], int on);

/* 3dSen's directional shadow map, as the shaders consume it. 224
 * bytes; must match `GeoShadow` in the Metal source.
 *
 * ONE orthographic map along the light, in the DIORAMA frame (NES world px,
 * +Y down, before Q and the camera) — the light is fixed to the diorama
 * so the map does not move when the camera orbits. The box is a
 * close fit of the RECEIVERS (their NES-world AABB, x/y clipped to `_View`),
 * extended toward the light to take in every caster.
 *   panelToNes  panel-local -> NES world px (undoes Q)
 *   nesToLight  NES world px -> light clip: x, y in [-1, 1], z in [0, 1],
 *               0 nearest the light
 *   L           unit vector TOWARD the light, NES world (= GeoLight.dir)
 *   depthBias   light-clip z added to every caster vertex: 0.02 NES px over
 *               the box's depth range (Light.shadowBias 0.02 x SceneScale)
 *   normalBias  NES px a caster vertex moves against its normal, scaled by
 *               sin(N, L) (standard normal-offset shadow bias):
 *               0.02 x the shadow texel's world size
 *   strength    shadowStrength 0.8: atten = mix(1 - strength, 1, lit)
 *   on          0 => every receiver is fully lit, the map is not sampled */
typedef struct
{
   simd_float4x4 panelToNes;
   simd_float4x4 nesToLight;
   simd_float4   L;
   float         depthBias;
   float         normalBias;
   float         strength;
   uint32_t      on;
   float         pad[4];
} Ra3dGeoShadow;

/* What the fit decided, for the beacon. */
typedef struct
{
   float w, h, range;          /* ortho box, NES px                        */
   float texel_w, texel_h;     /* NES px per shadow texel                  */
   float recv_min[3], recv_max[3];   /* receiver AABB, NES world, clipped  */
   uint32_t receivers, casters;
} Ra3dGeoShadowFit;

#define RA3D_SHADOW_STRENGTH     0.8f
#define RA3D_SHADOW_MAP_SIZE     2048u
#define RA3D_SHADOW_DEPTH_BIAS   0.02f   /* NES px           */
#define RA3D_SHADOW_NORMAL_BIAS  0.02f   /* x texel size     */

/* Fits the map to this frame's instances (`insts` from ra3d_geo_instances,
 * `Q` the same world_to_panel matrix). Returns 1 with `o->on` set when there
 * is at least one receiver and one caster; 0 (and `o->on` = 0) otherwise. */
int ra3d_geo_shadow_fit(Ra3dGeoShadow *o, Ra3dGeoShadowFit *info,
                        const Ra3dGeoInst *insts, uint32_t n, simd_float4x4 Q,
                        const Ra3dGeoLight *lt, const Ra3dGeoView *vw,
                        uint32_t map_size, float strength);

/* Instance order: opaque instances first (frame order), then translucent. */
typedef struct
{
   uint32_t opaque_count, blend_count, total;
} Ra3dGeoBuckets;

/* ---- 3dSenVR v2's "Enhanced" style ------------------------
 *
 * v2's Enhanced opaque shading adds three things to Classic's
 * Lambert + SH + one shadow tap, and every v2 vertex shader can bend space:
 *   - voxel grooves   (`spl.voxel_grid`, 0/2/4/8)
 *   - pixel shadows   (`spl.pixel_shadow`, 0/1)
 *   - world curvature (`spl.bend_zx`, `spl.bend_zy`, `spl.arc_yx`,
 *                      `spl.arc_center`)
 * plus the Depth AO post effect. All default OFF, as
 * in v2. The knobs live in 3dsen.cfg (ra3d_fx_cfg_parse); the GPU sees
 * Ra3dGeoFx. With every knob at 0 the shaders take exactly the Classic path. */
typedef struct
{
   int   pixel_shadow;   /* `pixel_shadow` 0/1                              */
   int   groove;         /* `groove` 0/2/4/8 (voxels per groove cell)       */
   float bend_lr;        /* `bend_lr` deg, -180..180 (spl.bend_zx)          */
   float bend_tb;        /* `bend_tb` deg, -180..180 (spl.bend_zy)          */
   float arc_h;          /* `arc_h`   deg, -180..180 (spl.arc_yx)           */
   int   arc_center;     /* `arc_center` 0 screen centre, 1 bottom edge     */
   int   bend_tess;      /* `bend_tess` backdrop / sky-box subdivisions per
                          * face edge while bending (3dSen's Backdrop: 32)  */
   int   depth_ao;       /* `depth_ao` 0/1 (spl.ao = 2, "Depth")            */
   int   ao_strength;    /* `ao_strength` 1..5 (ao.strength, default 3)     */
   int   ao_radius;      /* `ao_radius`   1..5 (ao.radius,   default 3)     */
   int   ao_quality;     /* `ao_quality`  0..2 (ao.quality,  default 1)     */
   /* screen-space reflections (spl.reflections, ssr.*) */
   int   reflection;     /* `reflection` 0/1 (spl.reflections)              */
   int   ssr_shine;      /* `reflection_shine`   1..5 (ssr.shine,   default 3) */
   int   ssr_clarity;    /* `reflection_clarity` 1..5 (ssr.clarity, default 3) */
   int   ssr_length;     /* `reflection_length`  1..5 (ssr.length,  default 3) */
   int   ssr_quality;    /* `reflection_quality` 0..3 (ssr.quality, default 2) */
} Ra3dFxCfg;

void ra3d_fx_cfg_defaults(Ra3dFxCfg *c);
/* `key = value` lines; '#'/';' comments; unknown keys ignored. Exact key
 * match (the renderer's older knobs use strstr, so these names were picked
 * to contain none of theirs). */
void ra3d_fx_cfg_parse(Ra3dFxCfg *c, const char *text, size_t len);
/* 1 when any Enhanced term is on. */
int  ra3d_fx_cfg_any(const Ra3dFxCfg *c);

/* The GPU's view of it. 224 bytes; must match `GeoFx` in the Metal source.
 *
 * Bend space is 3dSen's bend frame: NES px relative to the screen centre,
 * (128, 120, 0) in 3dSen's frame,
 * i.e. our NES world (128, RA3D_UNITY_H - 120, 0), with 3dSen's axes (+Y up,
 * +Z into the screen) and our depth scale applied to z, so the arc is round
 * in the space the user sees. */
typedef struct
{
   simd_float4x4 Q;          /* NES world -> panel (the frame's Q)           */
   simd_float4x4 Qi;         /* panel -> NES world                           */
   simd_float4   K;          /* bend rate, rad per px: LR, TB, arc_h, (0)    */
   simd_float4   fitScale;   /* fit scale                                    */
   simd_float4   fitShift;   /* fit shift, bend-space px                     */
   simd_float4   pivot;      /* arc pivot in xy, bend-space px               */
   float         zscale;     /* NES z -> bend-space depth (depth scale)      */
   float         groove;     /* voxel groove cell size, 0 = off              */
   float         pixelShadow;/* pixel shadows 0/1                            */
   uint32_t      bend;       /* 1 when any K != 0                            */
   uint32_t      backdrop;   /* the Lua Backdrop's instance slot + 1; 0 none */
   uint32_t      tess;       /* backdrop / sky-box subdivisions while bending */
   uint32_t      pad[2];
} Ra3dGeoFx;

/* Fills `o` from the cfg for a frame whose instances used `Q` and whose depth
 * scale is `depth_scale`. `backdrop_slot` = the Backdrop instance's GPU slot,
 * or -1. */
void ra3d_geo_fx(Ra3dGeoFx *o, const Ra3dFxCfg *c, simd_float4x4 Q,
                 float depth_scale, int backdrop_slot);
/* The forward / inverse bend of a NES-world point (in place). No-ops when
 * fx->bend is 0. */
void ra3d_bend_forward(const Ra3dGeoFx *fx, float p[3]);
void ra3d_bend_inverse(const Ra3dGeoFx *fx, float p[3]);
/* Bent-plane raycast in NES world: the ray o + t d (NES px, any
 * length d) against the bent image of the plane z = plane_z. On a hit,
 * `flat` gets the UNBENT point (its z = plane_z) and 1 is returned; 3dSen's
 * InsideScreen gate (|x - cx| <= 144, |y - cy| <= 136) applies. */
int  ra3d_bend_raycast(const Ra3dGeoFx *fx, const float o[3], const float d[3],
                       float plane_z, float max_dist, float flat[3]);
/* The AABB of the bent image of the box [lo, hi] (NES world): its surface
 * sampled 9 x 9 per face, padded 1 px. Unchanged when fx->bend is 0. */
void ra3d_bend_aabb(const Ra3dGeoFx *fx, float lo[3], float hi[3]);

/* ra3d_geo_shadow_fit, with the receivers' / casters' bounds taken AFTER the
 * bend (3dSen bends its casters and receivers alike). fx may be NULL. */
int ra3d_geo_shadow_fit_fx(Ra3dGeoShadow *o, Ra3dGeoShadowFit *info,
                           const Ra3dGeoInst *insts, uint32_t n, simd_float4x4 Q,
                           const Ra3dGeoLight *lt, const Ra3dGeoView *vw,
                           uint32_t map_size, float strength, const Ra3dGeoFx *fx);


/* World px -> panel-local. x/y become the panel quad's [-1, 1] and z becomes
 * METRES along the panel normal, so a 16 px extrusion is as deep as it is
 * wide. `half_w` is the quad's half-width in metres; `depth_scale` is the
 * runtime knob.
 *
 * THE +Y-DOWN FLIP LIVES HERE, once. The scene's world is NES screen order
 * (+Y down) and the panel basis is built +Y up; this is the trap
 * that cost the Python prototype one render, and it
 * would cost Metal one too. Everything downstream can then ignore it. */
simd_float4x4 ra3d_geo_world_to_panel(float half_w, float depth_scale);

/* Fills `out` (>= frame->instance_count entries) with the draw instances,
 * `slot_of[i]` with frame instance i's slot in `out`, and `b` with the counts. */
void ra3d_geo_instances(const Ra3dGeoFrame *frame, simd_float4x4 world_to_panel,
                        Ra3dGeoInst *out, uint32_t *slot_of, Ra3dGeoBuckets *b);

#ifdef __cplusplus
}
#endif

/* ========================================================================== */
#ifdef RA3D_GEO_GPU_IMPLEMENTATION

#include <stdlib.h>
#include <string.h>
#include <math.h>

static float ra3d_srgb_to_linear(float c)
{
   if (c <= 0.04045f) return c / 12.92f;
   return powf((c + 0.055f) / 1.055f, 2.4f);
}

void ra3d_geo_light(Ra3dGeoLight *o, const float d[3], const float col[3],
                    float intensity, float ambient, int encode)
{
   simd_float3 L = simd_make_float3(-d[0], d[1], d[2]);  /* -(x, -y, -z) */
   float len = simd_length(L);
   int i;
   memset(o, 0, sizeof(*o));
   if (!(len > 1e-6f))
   {  /* a zero vector would light nothing; fall back to the default */
      L = simd_make_float3(-RA3D_LIGHT_DIR_X, RA3D_LIGHT_DIR_Y, RA3D_LIGHT_DIR_Z);
      len = simd_length(L);
   }
   L /= len;
   o->dir = simd_make_float4(L, 0.0f);
   /* as 3dSen: colour is multiplied by intensity in GAMMA space and the
    * product linearised. */
   for (i = 0; i < 3; i++)
      o->rgb[i] = ra3d_srgb_to_linear(fmaxf(0.0f, col[i] * intensity));
   o->ambient = fmaxf(0.0f, ambient);
   o->encode  = encode ? 1u : 0u;
}

void ra3d_geo_view(Ra3dGeoView *o, const float c[4], int on)
{
   memset(o, 0, sizeof(*o));
   o->rect = simd_make_float4(c[0], (float)(RA3D_UNITY_H - 240) + c[3], 256.0f - c[2],
                              (float)RA3D_UNITY_H - c[1]);
   o->on   = on ? 1u : 0u;
}

simd_float4x4 ra3d_geo_world_to_panel(float half_w, float depth_scale)
{
   simd_float4x4 Q = matrix_identity_float4x4;
   float mz = (half_w / 128.0f) * depth_scale;
   Q.columns[0].x =  1.0f / 128.0f;
   Q.columns[1].y = -1.0f / 120.0f;      /* <- the +Y-down flip */
   Q.columns[2].z =  mz;
   Q.columns[3]   = simd_make_float4(-1.0f, 1.0f, 0.0f, 1.0f);
   return Q;
}

void ra3d_geo_instances(const Ra3dGeoFrame *g, simd_float4x4 Q,
                        Ra3dGeoInst *out, uint32_t *slot_of, Ra3dGeoBuckets *b)
{
   uint32_t i, fo = 0, fb;

   memset(b, 0, sizeof(*b));
   if (!g || !g->instance_count) return;

   for (i = 0; i < g->instance_count; i++)
      if (g->instances[i].alpha >= 0.999f) b->opaque_count++;
      else                                 b->blend_count++;
   b->total = b->opaque_count + b->blend_count;
   fb = b->opaque_count;

   for (i = 0; i < g->instance_count; i++)
   {
      const Ra3dGeoInstance *in = &g->instances[i];
      uint32_t slot = (in->alpha >= 0.999f) ? fo++ : fb++;
      float w = in->size[0], h = in->size[1], d = in->size[2];
      float rx = in->rot[0] * (float)M_PI / 180.0f;
      float ry = in->rot[1] * (float)M_PI / 180.0f;
      float rz = in->rot[2] * (float)M_PI / 180.0f;
      /* the box's depth is centred on the tile plane ([-d/2, d/2]),
       * so the pivot's z fraction is measured from the box's own centre */
      simd_float3 piv = simd_make_float3(in->pivot[0] * w, in->pivot[1] * h,
                                         (in->pivot[2] - 0.5f) * d);
      simd_float3 org = simd_make_float3(in->pos[0] + in->offset[0],
                                         in->pos[1] + in->offset[1],
                                         in->pos[2] + in->offset[2]) + piv;
      simd_float4x4 R = matrix_identity_float4x4, M;
      {
         float cxr = cosf(rx), sxr = sinf(rx);
         float cyr = cosf(ry), syr = sinf(ry);
         float czr = cosf(rz), szr = sinf(rz);
         /* R * S; R's order per below (legacy: raster3d.py's Rz*Ry*Rx). */
         simd_float3x3 Rx3 = simd_matrix_from_rows(
            simd_make_float3(1, 0, 0),
            simd_make_float3(0, cxr, -sxr),
            simd_make_float3(0, sxr,  cxr));
         simd_float3x3 Ry3 = simd_matrix_from_rows(
            simd_make_float3(cyr, 0, syr),
            simd_make_float3(0, 1, 0),
            simd_make_float3(-syr, 0, cyr));
         simd_float3x3 Rz3 = simd_matrix_from_rows(
            simd_make_float3(czr, -szr, 0),
            simd_make_float3(szr,  czr, 0),
            simd_make_float3(0, 0, 1));
         simd_float3x3 S3 = simd_matrix_from_rows(
            simd_make_float3(in->scale[0], 0, 0),
            simd_make_float3(0, in->scale[1], 0),
            simd_make_float3(0, 0, in->scale[2]));
         /* 3dSen's own order on 3dSen-frame values converted to NES
          * world (ra3d_build_frame); the legacy Rz*Ry*Rx otherwise */
         simd_float3x3 Rr = (in->flags & RA3D_INST_ROT_XYZ)
                          ? simd_mul(simd_mul(Rx3, Ry3), Rz3)
                          : (in->flags & RA3D_INST_ROT_YXZ)
                          ? simd_mul(simd_mul(Ry3, Rx3), Rz3)
                          : simd_mul(simd_mul(Rz3, Ry3), Rx3);
         simd_float3x3 R3 = simd_mul(Rr, S3);
         R.columns[0] = simd_make_float4(R3.columns[0], 0.0f);
         R.columns[1] = simd_make_float4(R3.columns[1], 0.0f);
         R.columns[2] = simd_make_float4(R3.columns[2], 0.0f);
      }
      /* unit patch (u, v, zn) -> box px -> minus pivot -> R*S -> + org */
      M = matrix_identity_float4x4;
      M.columns[0].x = w; M.columns[1].y = h; M.columns[2].z = d;
      M.columns[3]   = simd_make_float4(-piv, 1.0f);
      if (in->flags & RA3D_INST_SPRITE)
      {  /* 3dSen's per-sprite-tile depth order, in the pattern's own frame
          * (before R*S, like a tile's local position); 3dSen's +Z is away
          * from the viewer and ours toward, so the sign flips (RA3D_INST_BEHIND) */
         float ord = (float)((in->flags >> RA3D_INST_ORDER_SHIFT) & 0x3Fu);
         M.columns[3].z -= ord * 0.001f + ((in->flags & RA3D_INST_BEHIND) ? 0.1f : -0.1f);
      }
      M = simd_mul(R, M);
      M.columns[3]  += simd_make_float4(org, 0.0f);

      slot_of[i]           = slot;
      out[slot].model      = simd_mul(Q, M);
      {
         /* inverse-transpose of M's 3x3: normals stay perpendicular through
          * the non-uniform w/h/depth/scale stretch */
         simd_float3x3 M3 = simd_matrix(M.columns[0].xyz, M.columns[1].xyz,
                                        M.columns[2].xyz);
         float det = simd_determinant(M3);
         out[slot].normal = (fabsf(det) > 1e-12f)
                          ? simd_transpose(simd_inverse(M3))
                          : matrix_identity_float3x3;
      }
      out[slot].alpha      = in->alpha;
      out[slot].flags      = ((in->flags & RA3D_INST_NOCAST) ? RA3D_GEO_NOCAST : 0u)
                           | ((in->flags & RA3D_INST_NORECV) ? RA3D_GEO_NORECV : 0u)
                           | ((in->flags & (RA3D_INST_SHADOWONLY | RA3D_INST_HIDDEN))
                              ? RA3D_GEO_NOCOLOR : 0u)
                           | ((in->flags & RA3D_INST_UI) ? RA3D_GEO_UI : 0u)
                           | ((uint32_t)fminf(fmaxf(d * 16.0f + 0.5f, 0.0f), 65535.0f)
                              << RA3D_GEO_DEPTH_SHIFT);
      out[slot].pad[0] = in->pal_override;
      out[slot].pad[1] = in->dtex;   /* Direct texture, 1 + first texel */
      out[slot].pad[2] = in->dtex ? in->dtex_gw : 0u;   /* per-cell texture tiles */
      out[slot].cellOffset = in->cell_offset;
      out[slot].gw         = (uint32_t)(w / 8.0f + 0.5f);
      out[slot].gh         = (uint32_t)(h / 8.0f + 0.5f);
      if (!out[slot].gw) out[slot].gw = 1;
      if (!out[slot].gh) out[slot].gh = 1;
   }
}

int ra3d_geo_shadow_fit(Ra3dGeoShadow *o, Ra3dGeoShadowFit *info,
                        const Ra3dGeoInst *insts, uint32_t n, simd_float4x4 Q,
                        const Ra3dGeoLight *lt, const Ra3dGeoView *vw,
                        uint32_t map_size, float strength)
{
   return ra3d_geo_shadow_fit_fx(o, info, insts, n, Q, lt, vw, map_size, strength, NULL);
}

int ra3d_geo_shadow_fit_fx(Ra3dGeoShadow *o, Ra3dGeoShadowFit *info,
                           const Ra3dGeoInst *insts, uint32_t n, simd_float4x4 Q,
                           const Ra3dGeoLight *lt, const Ra3dGeoView *vw,
                           uint32_t map_size, float strength, const Ra3dGeoFx *fx)
{
   const int bend = fx && fx->bend;
   simd_float3 cmin = simd_make_float3( 1e30f,  1e30f,  1e30f);   /* casters' */
   simd_float3 cmax = simd_make_float3(-1e30f, -1e30f, -1e30f);   /* AABB, bend only */
   simd_float4x4 Qi;
   simd_float3 f, up, r, u;
   simd_float3 rmin = simd_make_float3( 1e30f,  1e30f,  1e30f);
   simd_float3 rmax = simd_make_float3(-1e30f, -1e30f, -1e30f);
   float cz = 1e30f;          /* nearest caster point, along f */
   float x0 = 1e30f, x1 = -1e30f, y0 = 1e30f, y1 = -1e30f, z0 = 1e30f, z1 = -1e30f;
   float w, h, range, sz;
   uint32_t i, k, nrecv = 0, ncast = 0;

   memset(o, 0, sizeof(*o));
   if (info) memset(info, 0, sizeof(*info));
   if (!insts || !n || !lt) return 0;
   if (fabsf(simd_determinant(Q)) < 1e-12f) return 0;
   Qi = simd_inverse(Q);

   f = -simd_normalize(lt->dir.xyz);       /* the direction the light TRAVELS */
   up = simd_make_float3(0.0f, -1.0f, 0.0f);   /* NES world: -Y is up */
   if (fabsf(simd_dot(f, up)) > 0.99f) up = simd_make_float3(0.0f, 0.0f, 1.0f);
   r = simd_normalize(simd_cross(up, f));
   u = simd_cross(f, r);

   for (i = 0; i < n; i++)
   {
      uint32_t fl = insts[i].flags;
      int recv = !(fl & (RA3D_GEO_NORECV | RA3D_GEO_NOCOLOR));
      int cast = !(fl & RA3D_GEO_NOCAST);
      simd_float4x4 M;
      if (!recv && !cast) continue;
      M = simd_mul(Qi, insts[i].model);      /* unit box -> NES world */
      if (recv) nrecv++;
      if (cast) ncast++;
      for (k = 0; k < 8; k++)
      {
         simd_float4 c = simd_mul(M, simd_make_float4((float)(k & 1), (float)((k >> 1) & 1),
                                                      (k & 4) ? 0.5f : -0.5f, 1.0f));
         if (recv) { rmin = simd_min(rmin, c.xyz); rmax = simd_max(rmax, c.xyz); }
         if (cast && bend) { cmin = simd_min(cmin, c.xyz); cmax = simd_max(cmax, c.xyz); }
         else if (cast) { float d = simd_dot(c.xyz, f); if (d < cz) cz = d; }
      }
   }
   if (!nrecv || !ncast) return 0;
   if (vw && vw->on)
   {  /* the `_View` clip: nothing outside it is visible, so nothing there
       * needs shadow texels */
      rmin.x = fmaxf(rmin.x, vw->rect.x); rmax.x = fminf(rmax.x, vw->rect.z);
      rmin.y = fmaxf(rmin.y, vw->rect.y); rmax.y = fminf(rmax.y, vw->rect.w);
      if (rmin.x >= rmax.x || rmin.y >= rmax.y) return 0;
   }
   if (bend)
   {  /* the `_View` clip is tested on the UNBENT position (3dSen's
       * fragment shader), so clip first, then take the bent bounds */
      float lo[3] = { rmin.x, rmin.y, rmin.z }, hi[3] = { rmax.x, rmax.y, rmax.z };
      float cl[3] = { cmin.x, cmin.y, cmin.z }, ch[3] = { cmax.x, cmax.y, cmax.z };
      ra3d_bend_aabb(fx, lo, hi);
      ra3d_bend_aabb(fx, cl, ch);
      rmin = simd_make_float3(lo[0], lo[1], lo[2]);
      rmax = simd_make_float3(hi[0], hi[1], hi[2]);
      for (k = 0; k < 8; k++)
      {
         simd_float3 c = simd_make_float3((k & 1) ? ch[0] : cl[0], (k & 2) ? ch[1] : cl[1],
                                          (k & 4) ? ch[2] : cl[2]);
         float d = simd_dot(c, f);
         if (d < cz) cz = d;
      }
   }
   for (k = 0; k < 8; k++)
   {
      simd_float3 c = simd_make_float3((k & 1) ? rmax.x : rmin.x,
                                       (k & 2) ? rmax.y : rmin.y,
                                       (k & 4) ? rmax.z : rmin.z);
      float a = simd_dot(c, r), b = simd_dot(c, u), d = simd_dot(c, f);
      x0 = fminf(x0, a); x1 = fmaxf(x1, a);
      y0 = fminf(y0, b); y1 = fmaxf(y1, b);
      z0 = fminf(z0, d); z1 = fmaxf(z1, d);
   }
   z0 = fminf(z0, cz) - 1.0f;      /* casters between the light and the box */
   z1 += 1.0f;
   w = fmaxf(x1 - x0, 1.0f); h = fmaxf(y1 - y0, 1.0f); range = z1 - z0;
   sz = (float)(map_size ? map_size : RA3D_SHADOW_MAP_SIZE);

   {
      simd_float4x4 L = matrix_identity_float4x4;
      simd_float4 row0 = simd_make_float4(r * (2.0f / w), -(x0 + x1) / w);
      simd_float4 row1 = simd_make_float4(u * (2.0f / h), -(y0 + y1) / h);
      simd_float4 row2 = simd_make_float4(f / range, -z0 / range);
      simd_float4 row3 = simd_make_float4(0.0f, 0.0f, 0.0f, 1.0f);
      L = simd_transpose(simd_matrix(row0, row1, row2, row3));
      o->nesToLight = L;
   }
   o->panelToNes = Qi;
   o->L          = simd_make_float4(-f, 0.0f);
   o->depthBias  = RA3D_SHADOW_DEPTH_BIAS / range;
   o->normalBias = RA3D_SHADOW_NORMAL_BIAS * fmaxf(w, h) / sz;
   o->strength   = fminf(fmaxf(strength, 0.0f), 1.0f);
   o->on         = 1u;
   if (info)
   {
      info->w = w; info->h = h; info->range = range;
      info->texel_w = w / sz; info->texel_h = h / sz;
      info->recv_min[0] = rmin.x; info->recv_min[1] = rmin.y; info->recv_min[2] = rmin.z;
      info->recv_max[0] = rmax.x; info->recv_max[1] = rmax.y; info->recv_max[2] = rmax.z;
      info->receivers = nrecv; info->casters = ncast;
   }
   return 1;
}

/* ---- Enhanced style ---------------------------------------- */

void ra3d_fx_cfg_defaults(Ra3dFxCfg *c)
{
   memset(c, 0, sizeof(*c));
   c->bend_tess   = 32;   /* 3dSen bends a 32x32-subdivided cube */
   c->ao_strength = 3;    /* v2's Depth AO defaults */
   c->ao_radius   = 3;
   c->ao_quality  = 1;
   c->ssr_shine   = 3;    /* v2's reflection defaults */
   c->ssr_clarity = 3;
   c->ssr_length  = 3;
   c->ssr_quality = 2;
}

void ra3d_fx_cfg_parse(Ra3dFxCfg *c, const char *text, size_t len)
{
   const char *p = text, *end = text + len;
   while (p < end)
   {
      const char *ls = p, *le, *eq, *ke;
      char key[32], val[48];
      size_t kn, vn;
      while (p < end && *p != '\n') p++;
      le = p;
      if (p < end) p++;
      while (ls < le && (*ls == ' ' || *ls == '\t')) ls++;
      if (ls >= le || *ls == '#' || *ls == ';') continue;
      for (eq = ls; eq < le && *eq != '='; eq++) ;
      if (eq >= le) continue;
      for (ke = eq; ke > ls && (ke[-1] == ' ' || ke[-1] == '\t'); ke--) ;
      kn = (size_t)(ke - ls);
      if (!kn || kn >= sizeof(key)) continue;
      memcpy(key, ls, kn); key[kn] = 0;
      for (eq++; eq < le && (*eq == ' ' || *eq == '\t' || *eq == '"'); eq++) ;
      vn = (size_t)(le - eq);
      if (vn >= sizeof(val)) vn = sizeof(val) - 1;
      memcpy(val, eq, vn); val[vn] = 0;
      if      (!strcmp(key, "pixel_shadow")) c->pixel_shadow = atoi(val) ? 1 : 0;
      else if (!strcmp(key, "groove"))
      {  /* v2 offers Off / 2 / 4 / 8 */
         int g = atoi(val);
         c->groove = (g >= 8) ? 8 : (g >= 4) ? 4 : (g >= 2) ? 2 : 0;
      }
      else if (!strcmp(key, "bend_lr"))     c->bend_lr    = (float)atof(val);
      else if (!strcmp(key, "bend_tb"))     c->bend_tb    = (float)atof(val);
      else if (!strcmp(key, "arc_h"))       c->arc_h      = (float)atof(val);
      else if (!strcmp(key, "arc_center"))  c->arc_center = atoi(val) ? 1 : 0;
      else if (!strcmp(key, "bend_tess"))   c->bend_tess  = atoi(val);
      else if (!strcmp(key, "depth_ao")
            || !strcmp(key, "ao"))          c->depth_ao   = atoi(val) ? 1 : 0;
      else if (!strcmp(key, "reflection")
            || !strcmp(key, "reflections")) c->reflection = atoi(val) ? 1 : 0;
      else if (!strcmp(key, "reflection_shine"))   c->ssr_shine   = atoi(val);
      else if (!strcmp(key, "reflection_clarity")) c->ssr_clarity = atoi(val);
      else if (!strcmp(key, "reflection_length"))  c->ssr_length  = atoi(val);
      else if (!strcmp(key, "reflection_quality")) c->ssr_quality = atoi(val);
      else if (!strcmp(key, "ao_strength")) c->ao_strength = atoi(val);
      else if (!strcmp(key, "ao_radius"))   c->ao_radius   = atoi(val);
      else if (!strcmp(key, "ao_quality"))  c->ao_quality  = atoi(val);
   }
   /* v2's bend range: -180..180 */
   c->bend_lr = fminf(fmaxf(c->bend_lr, -180.0f), 180.0f);
   c->bend_tb = fminf(fmaxf(c->bend_tb, -180.0f), 180.0f);
   c->arc_h   = fminf(fmaxf(c->arc_h,   -180.0f), 180.0f);
   if (c->bend_tess < 1)   c->bend_tess = 1;
   if (c->bend_tess > 128) c->bend_tess = 128;
   if (c->ao_strength < 1) c->ao_strength = 1; else if (c->ao_strength > 5) c->ao_strength = 5;
   if (c->ao_radius < 1)   c->ao_radius = 1;   else if (c->ao_radius > 5)   c->ao_radius = 5;
   if (c->ao_quality < 0)  c->ao_quality = 0;  else if (c->ao_quality > 2)  c->ao_quality = 2;
   if (c->ssr_shine < 1)   c->ssr_shine = 1;   else if (c->ssr_shine > 5)   c->ssr_shine = 5;
   if (c->ssr_clarity < 1) c->ssr_clarity = 1; else if (c->ssr_clarity > 5) c->ssr_clarity = 5;
   if (c->ssr_length < 1)  c->ssr_length = 1;  else if (c->ssr_length > 5)  c->ssr_length = 5;
   if (c->ssr_quality < 0) c->ssr_quality = 0; else if (c->ssr_quality > 3) c->ssr_quality = 3;
}

int ra3d_fx_cfg_any(const Ra3dFxCfg *c)
{
   return c->pixel_shadow || c->groove || c->bend_lr != 0.0f || c->bend_tb != 0.0f
       || c->arc_h != 0.0f || c->depth_ao || c->reflection;
}

/* bend extents: 256, 240, 256, 240 px */
static const float ra3d_bend_extent[4] = { 256.0f, 240.0f, 256.0f, 240.0f };
/* the bend centre ((128, 120, 0) in 3dSen's frame) in our NES world */
#define RA3D_BEND_CX  128.0f
#define RA3D_BEND_CY  ((float)(RA3D_UNITY_H - 120))

void ra3d_geo_fx(Ra3dGeoFx *o, const Ra3dFxCfg *c, simd_float4x4 Q,
                 float depth_scale, int backdrop_slot)
{
   const float deg[4] = { c->bend_lr, c->bend_tb, c->arc_h, 0.0f };
   int i;
   memset(o, 0, sizeof(*o));
   o->Q  = Q;
   o->Qi = (fabsf(simd_determinant(Q)) > 1e-20f) ? simd_inverse(Q) : matrix_identity_float4x4;
   o->zscale = fmaxf(depth_scale, 0.01f);
   /* per-axis bend rate and fit, sceneScale = 1 (NES px) */
   for (i = 0; i < 4; i++)
   {
      float th = deg[i] * (float)M_PI / 180.0f;
      float k  = th / ra3d_bend_extent[i];
      float a  = th * 0.25f;                 /* FitFraction 0.25 */
      o->K[i] = k;
      o->fitScale[i] = 1.0f;
      o->fitShift[i] = 0.0f;
      if (fabsf(a) > 1e-5f)
      {
         float s = sinf(0.5f * a);
         o->fitScale[i] = a / sinf(a);
         o->fitShift[i] = 2.0f * s * s / k;
      }
   }
   /* arc from the bottom edge: pivot = (-120, -128) x sceneScale */
   if (c->arc_center) o->pivot = simd_make_float4(-120.0f, -128.0f, 0.0f, 0.0f);
   o->bend        = (o->K[0] != 0.0f || o->K[1] != 0.0f || o->K[2] != 0.0f) ? 1u : 0u;
   o->groove      = (float)c->groove;
   o->pixelShadow = c->pixel_shadow ? 1.0f : 0.0f;
   o->backdrop    = backdrop_slot >= 0 ? (uint32_t)backdrop_slot + 1u : 0u;
   o->tess        = (uint32_t)(c->bend_tess > 0 ? c->bend_tess : 1);
}

/* the arc and its inverse, in doubles */
static void ra3d_arc(double k, double fs, double fsh, double *u, double *w)
{
   double a, wc, x, z;
   if (k == 0.0) return;
   a  = *u * k;
   wc = (*w * k > 0.95) ? 0.95 / k : *w;
   x  = (1.0 - wc * k) * sin(a) / k;
   z  = (1.0 - cos(a)) / k + wc * cos(a);
   *u = fs * x;
   *w = fs * (z - fsh);
}

static void ra3d_arc_inv(double k, double fs, double fsh, double *u, double *w)
{
   double X, R, sg, ang, rad;
   if (k == 0.0) return;
   X   = *u / fs;
   R   = 1.0 / k - (*w / fs + fsh);
   sg  = k > 0.0 ? 1.0 : -1.0;
   ang = atan2(sg * X, sg * R);
   rad = sg * sqrt(X * X + R * R);
   *u  = ang / k;
   *w  = 1.0 / k - rad;
}

void ra3d_bend_forward(const Ra3dGeoFx *fx, float p[3])
{
   double u, u2, w, w2;
   if (!fx || !fx->bend) return;
   /* NES world -> bend space: 3dSen's axes about the screen centre */
   u  = (double)p[0] - RA3D_BEND_CX;
   u2 = RA3D_BEND_CY - (double)p[1];
   w  = -(double)p[2] * fx->zscale;
   /* forward bend */
   ra3d_arc(fx->K[0], fx->fitScale[0], fx->fitShift[0], &u, &w);
   ra3d_arc(fx->K[1], fx->fitScale[1], fx->fitShift[1], &u2, &w);
   w2 = (double)fx->pivot[0] - u2;
   ra3d_arc(fx->K[2], fx->fitScale[2], fx->fitShift[2], &u, &w2);
   u2 = (double)fx->pivot[0] - w2;
   w2 = (double)fx->pivot[1] - u;
   ra3d_arc(fx->K[3], fx->fitScale[3], fx->fitShift[3], &u2, &w2);
   u  = (double)fx->pivot[1] - w2;
   p[0] = (float)(u + RA3D_BEND_CX);
   p[1] = (float)(RA3D_BEND_CY - u2);
   p[2] = (float)(-w / fx->zscale);
}

void ra3d_bend_inverse(const Ra3dGeoFx *fx, float p[3])
{
   double u, u2, w, w2;
   if (!fx || !fx->bend) return;
   u  = (double)p[0] - RA3D_BEND_CX;
   u2 = RA3D_BEND_CY - (double)p[1];
   w  = -(double)p[2] * fx->zscale;
   /* inverse bend */
   w2 = (double)fx->pivot[1] - u;
   ra3d_arc_inv(fx->K[3], fx->fitScale[3], fx->fitShift[3], &u2, &w2);
   u  = (double)fx->pivot[1] - w2;
   w2 = (double)fx->pivot[0] - u2;
   ra3d_arc_inv(fx->K[2], fx->fitScale[2], fx->fitShift[2], &u, &w2);
   u2 = (double)fx->pivot[0] - w2;
   ra3d_arc_inv(fx->K[1], fx->fitScale[1], fx->fitShift[1], &u2, &w);
   ra3d_arc_inv(fx->K[0], fx->fitScale[0], fx->fitShift[0], &u, &w);
   p[0] = (float)(u + RA3D_BEND_CX);
   p[1] = (float)(RA3D_BEND_CY - u2);
   p[2] = (float)(-w / fx->zscale);
}

int ra3d_bend_raycast(const Ra3dGeoFx *fx, const float o[3], const float d[3],
                      float plane_z, float max_dist, float flat[3])
{
   float dl = sqrtf(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
   float dn[3], step, t0 = 0.0f, f0, q[3];
   int i, j;
   if (!(dl > 1e-9f)) return 0;
   dn[0] = d[0] / dl; dn[1] = d[1] / dl; dn[2] = d[2] / dl;
   if (!fx || !fx->bend)
   {  /* the flat plane */
      float t;
      if (fabsf(dn[2]) < 1e-9f) return 0;
      t = (plane_z - o[2]) / dn[2];
      if (t <= 0.0f) return 0;
      flat[0] = o[0] + dn[0] * t; flat[1] = o[1] + dn[1] * t; flat[2] = plane_z;
      return 1;
   }
   /* bent-plane raycast: 256 steps, then 30
    * bisections on the sign of Inverse(p).z - planeZ, InsideScreen gate */
   step = max_dist / 256.0f;
   q[0] = o[0]; q[1] = o[1]; q[2] = o[2];
   ra3d_bend_inverse(fx, q);
   f0 = q[2] - plane_z;
   for (i = 1; i <= 256; i++)
   {
      float t1 = (float)i * step, f1;
      q[0] = o[0] + dn[0] * t1; q[1] = o[1] + dn[1] * t1; q[2] = o[2] + dn[2] * t1;
      ra3d_bend_inverse(fx, q);
      f1 = q[2] - plane_z;
      if ((f0 <= 0.0f) != (f1 <= 0.0f))
      {
         float a = t0, b = t1, fa = f0;
         for (j = 0; j < 30; j++)
         {
            float m = 0.5f * (a + b), fm;
            q[0] = o[0] + dn[0] * m; q[1] = o[1] + dn[1] * m; q[2] = o[2] + dn[2] * m;
            ra3d_bend_inverse(fx, q);
            fm = q[2] - plane_z;
            if ((fa <= 0.0f) == (fm <= 0.0f)) { a = m; fa = fm; }
            else                              b = m;
         }
         {
            float m = 0.5f * (a + b);
            q[0] = o[0] + dn[0] * m; q[1] = o[1] + dn[1] * m; q[2] = o[2] + dn[2] * m;
            ra3d_bend_inverse(fx, q);
         }
         if (fabsf(q[0] - RA3D_BEND_CX) <= 144.0f && fabsf(q[1] - RA3D_BEND_CY) <= 136.0f)
         {
            flat[0] = q[0]; flat[1] = q[1]; flat[2] = plane_z;
            return 1;
         }
      }
      t0 = t1; f0 = f1;
   }
   return 0;
}

void ra3d_bend_aabb(const Ra3dGeoFx *fx, float lo[3], float hi[3])
{
   float nlo[3] = { 1e30f, 1e30f, 1e30f }, nhi[3] = { -1e30f, -1e30f, -1e30f };
   int ax, side, i, j, c;
   if (!fx || !fx->bend) return;
   for (ax = 0; ax < 3; ax++)
      for (side = 0; side < 2; side++)
         for (i = 0; i <= 8; i++)
            for (j = 0; j <= 8; j++)
            {
               int a1 = (ax + 1) % 3, a2 = (ax + 2) % 3;
               float q[3];
               q[ax] = side ? hi[ax] : lo[ax];
               q[a1] = lo[a1] + (hi[a1] - lo[a1]) * (float)i / 8.0f;
               q[a2] = lo[a2] + (hi[a2] - lo[a2]) * (float)j / 8.0f;
               ra3d_bend_forward(fx, q);
               for (c = 0; c < 3; c++)
               { if (q[c] < nlo[c]) nlo[c] = q[c]; if (q[c] > nhi[c]) nhi[c] = q[c]; }
            }
   for (c = 0; c < 3; c++) { lo[c] = nlo[c] - 1.0f; hi[c] = nhi[c] + 1.0f; }
}

#endif /* RA3D_GEO_GPU_IMPLEMENTATION */
#endif /* RA3D_GEO_GPU_H */
